// id3_tag.mbt
//
// ID3v2 标签解析（读取侧）。
//
// 结构：10 字节标签头 → 可选扩展头 → 帧序列 → 可选 padding → 可选 footer。
// 两个大版本的差异必须分别处理：
//   • v2.3 的帧尺寸是普通 u32，标签级 unsynchronisation 作用于整个标签体；
//   • v2.4 的帧尺寸是 synchsafe，且 unsynchronisation 按帧作用于帧载荷。
// 把两者混用是 ID3v2 实现最常见的 bug，这里用 `major` 分支显式区分。

///|
/// 一个 ID3v2 帧。
pub struct Frame {
  /// 4 字符帧 ID（如 `TIT2`）。
  id : String
  /// 帧载荷（已完成 unsynchronisation 还原与 zlib 解压）。
  data : Bytes
  /// 帧头第一字节（状态标志）。
  status_flags : Int32
  /// 帧头第二字节（格式标志）。
  format_flags : Int32
  /// 分组标识字节（v2.3 `$20` / v2.4 `$40`）；无分组时为 `None`。
  ///
  /// 这个字节夹在帧头与载荷之间，读的时候必须跳过、写的时候必须补回，
  /// 只跳过不补回会让读者把载荷首字节当成组号，整帧静默错位。
  group : Int32?
}

///|
/// 解析出的 ID3v2 标签。
pub struct Id3Tag {
  /// 主版本号（3 或 4）。
  major : Int32
  /// 修订号。
  revision : Int32
  /// 标签头原始 flags 字节。
  flags : Int32
  /// 帧序列（保持文件内顺序）。
  frames : Array[Frame]
  /// 标签（含头/扩展头/padding/footer）占用的总字节数，即音频数据起点。
  total_size : Int32
}

///|
/// 解析 ID3v2 标签。数据必须从文件起点开始。
///
/// 没有 ID3 标签时抛 `NotTagged`；被截断时抛 `Truncated`。
pub fn parse(data : BytesView) -> Id3Tag raise TagError {
  if data.length() < 10 {
    raise Truncated(offset=0, need=10, actual=data.length())
  }
  if data.at(0) != b'I' || data.at(1) != b'D' || data.at(2) != b'3' {
    raise NotTagged(format="id3v2")
  }
  let major = data.at(3).to_int()
  let revision = data.at(4).to_int()
  if major != 3 && major != 4 {
    raise UnsupportedVersion(version=major)
  }
  let flags = data.at(5).to_int()
  // flags 的低 4 位必须为 0（v2.4 定义了 bit4 = footer，v2.3 未定义 bit4）。
  let size = read_synchsafe32(data, 6)
  let has_footer = major == 4 && (flags & 0x10) != 0
  let total_size = 10 + size + (if has_footer { 10 } else { 0 })
  // 标签体按声明尺寸切片；文件里音频数据不足不影响读取标签。
  let body_end = 10 + size
  if body_end > data.length() {
    raise Truncated(offset=10, need=size, actual=data.length() - 10)
  }
  let raw_body = data.exact_view(start=10, end=body_end)
  // v2.3：unsynchronisation 作用于整个标签体，先整体还原再切帧。
  // v2.4：作用于帧载荷，帧尺寸仍按磁盘上的字节数计算，所以不能整体还原。
  let tag_unsync = (flags & 0x80) != 0
  let body = if major == 3 && tag_unsync {
    unsynchronise(raw_body).exact_view()
  } else {
    raw_body
  }
  let mut pos = 0
  if (flags & 0x40) != 0 {
    pos += extended_header_len(body, major)
  }
  let frames = parse_frames(body, pos, major, tag_unsync)
  { major, revision, flags, frames, total_size, }
}

///|
/// 跳过扩展头，返回其字节长度。
fn extended_header_len(body : BytesView, major : Int32) -> Int32 raise TagError {
  if major == 3 {
    // v2.3：4 字节普通 u32，值**不含自身**（6 或 10）。
    let ext_size = read_u32be(body, 0)
    if ext_size != 6 && ext_size != 10 {
      raise BadHeader(
        reason="v2.3 扩展头尺寸 \{ext_size} 非法（应为 6 或 10）",
      )
    }
    4 + ext_size
  } else {
    // v2.4：4 字节 synchsafe，值**包含自身**，最小 6。
    let ext_size = read_synchsafe32(body, 0)
    if ext_size < 6 {
      raise BadHeader(reason="v2.4 扩展头尺寸 \{ext_size} 小于 6")
    }
    ext_size
  }
}

///|
/// 遍历帧直到 padding（全零）或标签体结束。
fn parse_frames(
  body : BytesView,
  start : Int32,
  major : Int32,
  tag_unsync : Bool,
) -> Array[Frame] raise TagError {
  let out : Array[Frame] = []
  let mut pos = start
  while pos + 10 <= body.length() {
    // padding：剩余的字节全是 0
    if body.at(pos) == b'\x00' {
      break
    }
    if !is_valid_frame_id(body, pos) {
      // 非零且非合法帧 ID：规范上属于损坏数据，但真实文件里常见
      // （尤其 v2.2 帧混入、尾部残留）。按 padding 处理更宽容。
      break
    }
    let id = read_frame_id(body, pos)
    // v2.3 普通 u32，v2.4 synchsafe —— 混用会让后续帧全部错位。
    let size = if major == 4 {
      read_synchsafe32(body, pos + 4)
    } else {
      read_u32be(body, pos + 4)
    }
    let status_flags = body.at(pos + 8).to_int()
    let format_flags = body.at(pos + 9).to_int()
    let payload_start = pos + 10
    if size == 0 {
      // 规范要求帧至少 1 字节；size 0 视为数据损坏。
      raise BadFrameHeader(reason="帧 \{id} 的尺寸为 0")
    }
    if payload_start + size > body.length() {
      raise FrameOutOfBounds(
        frame_id=id,
        size~,
        available=body.length() - payload_start,
      )
    }
    // 解析帧头的附加字段：分组字节要保留（写回时必须补回），
    // 加密帧没有可用语义——规范把加密方法留给外部注册表，这里明确报不支持。
    let compressed = if major == 4 {
      (format_flags & 0x08) != 0
    } else {
      (format_flags & 0x80) != 0
    }
    let encrypted = if major == 4 {
      (format_flags & 0x04) != 0
    } else {
      (format_flags & 0x40) != 0
    }
    if encrypted {
      raise Unsupported(what="帧 \{id} 已加密")
    }
    let (extra, group_pos) = frame_extra_layout(major, format_flags)
    let data_start = payload_start + extra
    let data_end = payload_start + size
    if data_start > data_end {
      raise BadFrameHeader(reason="帧 \{id} 的附加头字段超出帧尺寸")
    }
    let group = if group_pos >= 0 {
      Some(body.at(payload_start + group_pos).to_int())
    } else {
      None
    }
    // 压缩帧的解压上限（与 TagLib 的 maxCompressedFrameOutputSize 同量级）。
    // 音频文件是不可信输入：一个几百字节的帧可以声明成 GB 级输出，
    // 没有上限就等于把内存交给文件里的数字。
    let declared = if compressed {
      let d = if major == 4 {
        if (format_flags & 0x01) == 0 {
          // 规范原文：压缩帧 MUST 带 Data Length Indicator，缺了就没有可信的
          // 解压后尺寸可用，明确报错而不是猜。
          raise BadFrameHeader(
            reason="帧 \{id} 声明压缩但缺少 Data Length Indicator",
          )
        }
        read_synchsafe32(
          body,
          payload_start + (if group_pos >= 0 { 1 } else { 0 }),
        )
      } else {
        read_u32be(body, payload_start)
      }
      if d > MAX_COMPRESSED_FRAME_OUTPUT {
        raise BadFrameData(
          frame_id=id,
          reason="声明的解压后尺寸 \{d} 超出上限 \{MAX_COMPRESSED_FRAME_OUTPUT}",
        )
      }
      Some(d)
    } else {
      None
    }
    let raw = body.exact_view(start=data_start, end=data_end)
    // v2.4：帧级 unsync（或标签级 unsync 表示所有帧都还原）
    let frame_unsync = major == 4 && (tag_unsync || (format_flags & 0x02) != 0)
    let restored = if frame_unsync {
      unsynchronise(raw)
    } else {
      slice_bytes(body, data_start, data_end)
    }
    // unsync 还原在解压之前——顺序反了会让 zlib 流被"还原"坏掉。
    let data = if compressed {
      inflate_frame(id, restored, declared)
    } else {
      restored
    }
    out.push({ id, data, status_flags, format_flags, group, })
    pos = data_end
  }
  out
}

///|
/// 解析帧头的附加字段布局，返回 `(附加头字节数, 组号字节的相对偏移)`，
/// 无分组时偏移为 `-1`。
///
/// 规范要求附加字段"按标志位出现的顺序"排列（id3v2.4.0-structure §4.1、
/// id3v2.3.0 §3.3.1），两个版本恰好相反：
///   • v2.3 `%ijk00000` → [4 字节解压后尺寸][1 字节加密方法][1 字节组号]；
///   • v2.4 `%0h00kmnp` → [1 字节组号][1 字节加密方法][4 字节 DLI]。
/// 抄错顺序会把载荷整体错位，是这里唯一值得显式分支的地方。
fn frame_extra_layout(major : Int32, format_flags : Int32) -> (Int32, Int32) {
  if major == 3 {
    let mut len = 0
    if (format_flags & 0x80) != 0 {
      len += 4
    }
    if (format_flags & 0x40) != 0 {
      len += 1
    }
    let grouped = (format_flags & 0x20) != 0
    let group_pos = if grouped { len } else { -1 }
    if grouped {
      len += 1
    }
    (len, group_pos)
  } else {
    let grouped = (format_flags & 0x40) != 0
    let group_pos = if grouped { 0 } else { -1 }
    let mut len = if grouped { 1 } else { 0 }
    if (format_flags & 0x04) != 0 {
      len += 1
    }
    if (format_flags & 0x01) != 0 {
      len += 4
    }
    (len, group_pos)
  }
}

///|
/// 单个压缩帧允许解压出的最大字节数（64 MiB）。
///
/// 压缩帧必须声明解压后尺寸（v2.3 的 4 字节 / v2.4 的 DLI），这个常量给声明值
/// 本身设上限，避免"几百字节的帧声明 GB 级输出"就把内存交出去。
const MAX_COMPRESSED_FRAME_OUTPUT : Int32 = 0x04000000

///|
/// 解压 zlib 压缩的帧载荷。
///
/// 压缩算法由规范点名（v2.3/v2.4 都指向 zlib / RFC 1950），因此这里不是
/// "猜格式"：直接按 zlib 容器解。
///
/// **输出上限是硬的**：按声明尺寸预置一块固定缓冲交给解码器
/// （`Decoder::stream_into_buf` 越界即抛 `Overflow`，实测在 `write` 阶段就抛），
/// 因此解压产出的内存上界 = 声明尺寸 ≤ `MAX_COMPRESSED_FRAME_OUTPUT`。
/// 这样"声明值撒谎"的文件不会先吃满内存再被拒。
///
/// `declared` 是帧头里声明的解压后尺寸。解压结果与声明不符时同样报错：
/// 规范要求这个字段就是解压后长度，对不上说明数据不可信。
fn inflate_frame(
  id : String,
  data : Bytes,
  declared : Int32?,
) -> Bytes raise TagError {
  // 压缩帧一定有声明尺寸（缺失已在解析处报 `BadFrameHeader`）；这里仍防御一次。
  let cap = match declared {
    Some(d) => d
    None =>
      raise BadFrameData(
        frame_id=id,
        reason="压缩帧缺少解压后尺寸声明，无法限定输出上限",
      )
  }
  if cap <= 0 {
    raise BadFrameData(
      frame_id=id,
      reason="声明的解压后尺寸 \{cap} 非法",
    )
  }
  let buf : Array[Byte] = Array::make(cap, b'\x00')
  let decoder = @moon_yazi.Decoder()
  decoder.set_format(@moon_yazi.Format::Zlib)
  let stream = decoder.stream_into_buf(buf)
  stream.write(data) catch {
    e =>
      raise BadFrameData(
        frame_id=id,
        reason="zlib 解压失败或输出超出声明的 \{cap} 字节：\{e.to_string()}",
      )
  }
  let (count, _checksum) = stream.finish() catch {
    e =>
      raise BadFrameData(
        frame_id=id,
        reason="zlib 解压失败或输出超出声明的 \{cap} 字节：\{e.to_string()}",
      )
  }
  if count.to_int() != cap {
    raise BadFrameData(
      frame_id=id,
      reason="解压后长度 \{count.to_int()} 与声明的 \{cap} 不一致",
    )
  }
  Bytes::from_array(buf)
}

///|
/// 读 4 字符帧 ID。
///
/// 注意不能用 `Buffer::to_string`：它按 UTF-16LE 解释字节，会把
/// "TIT2" 变成乱码。这里逐字节转字符再拼。
fn read_frame_id(body : BytesView, pos : Int32) -> String {
  let buf = StringBuilder()
  for i in 0..<4 {
    buf.write_char(Int32::unsafe_to_char(body.at(pos + i).to_int()))
  }
  buf.to_string()
}

///|
/// 取第一个指定 ID 的帧。
pub fn Id3Tag::frame(self : Id3Tag, id : String) -> Frame? {
  for f in self.frames {
    if f.id == id {
      return Some(f)
    }
  }
  None
}

///|
/// 取所有指定 ID 的帧（规范允许多值的帧，如多个 `TXXX`）。
pub fn Id3Tag::frames_with_id(self : Id3Tag, id : String) -> Array[Frame] {
  let out : Array[Frame] = []
  for f in self.frames {
    if f.id == id {
      out.push(f)
    }
  }
  out
}

///|
/// 取某个文本帧的解码字符串；帧不存在或载荷为空时返回 `None`。
pub fn Id3Tag::text(self : Id3Tag, id : String) -> String? raise TagError {
  match self.frame(id) {
    None => None
    Some(f) => f.as_text()
  }
}

///|
/// 把帧当作文本帧解码；非文本帧（ID 不以 `T` 开头）返回 `None`。
///
/// `TXXX` 这类"描述 + 值"的帧只返回第一个字符串（描述）——
/// 需要分别取描述和值时用 `TXXX` 专用接口。
pub fn Frame::as_text(self : Frame) -> String? raise TagError {
  if self.data.length() == 0 {
    return None
  }
  // 文本帧 ID 一律以 T 开头；其他帧首字节不是编码字节，不能按文本解。
  if self.id.length() != 4 || !self.id.has_prefix("T") {
    return None
  }
  let code = self.data.at(0).to_int()
  // 编码字节只允许 0..3；越界说明不是文本帧。
  if code > 3 {
    return None
  }
  let enc = TextEncoding::from_code(code)
  let parts = split_strings(self.data.exact_view(), enc, 1, self.data.length())
  if parts.length() == 0 {
    Some("")
  } else {
    Some(parts[0])
  }
}
