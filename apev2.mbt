// apev2.mbt
//
// APEv2 标签的读写。
//
// APEv2 位于文件**尾部**（与 ID3v2 在头部相反），布局：
//   32 字节 footer：  "APETAGEX" + version(u32 LE) + size(u32 LE)
//                     + item_count(u32 LE) + flags(u32 LE) + reserved(8)
//   size 字节的条目区（在 footer 之前）
//
// 每个条目：
//   value_size  u32 LE
//   flags       u32 LE
//   key         ASCII，以 0 结尾
//   value       value_size 字节
//
// 与 ID3v2 的差异：APEv2 的键值语义是"扁平字典"（无帧 ID 分级），
// 且整数/二进制值由 flags 的 bit0 区分。

///|
/// APEv2 中的一个条目。
pub struct ApeItem {
  /// 键名（大写 ASCII）。
  key : String
  /// 是否为二进制值（flags bit0）。
  is_binary : Bool
  /// 值字节；文本值按 UTF-8 解码展示。
  value : Bytes
}

///|
/// 解析出的 APEv2 标签。
pub struct ApeTag {
  /// 条目列表，保持文件内顺序。
  items : Array[ApeItem]
  /// 标签总字节数（条目区 + footer，不含 header）。
  size : Int32
  /// 标签在文件中的起始偏移。
  offset : Int32
}

///|
/// 从文件尾部定位并解析 APEv2 标签；没有则返回 `None`。
pub fn parse_ape(data : BytesView) -> ApeTag? raise TagError {
  // footer 可能紧贴文件尾，也可能在 ID3v1（128 字节）之前
  let candidates = [0, 128]
  for back in candidates {
    let footer_pos = data.length() - 32 - back
    if footer_pos < 0 {
      continue
    }
    if !is_ape_footer(data, footer_pos) {
      continue
    }
    return Some(read_ape_at(data, footer_pos))
  }
  None
}

///|
/// 判断指定位置是否是一个 APEv2 footer。
fn is_ape_footer(data : BytesView, pos : Int32) -> Bool {
  if data.length() < pos + 32 {
    return false
  }
  let magic = "APETAGEX"
  for i in 0..<8 {
    if data.at(pos + i).to_int() != magic.at(i).to_int() {
      return false
    }
  }
  true
}

///|
/// 在已知 footer 位置的前提下解析整个标签。
fn read_ape_at(data : BytesView, footer_pos : Int32) -> ApeTag raise TagError {
  // version 在 magic 之后 4 字节，这里只接受 2000（APEv2）
  let version = read_le32(data, footer_pos + 8)
  if version != 2000 {
    raise Unsupported(what="APEv1（version \{version}）标签")
  }
  let size = read_le32(data, footer_pos + 12)
  let count = read_le32(data, footer_pos + 16)
  // size 包含 footer 自身；条目区在 footer 之前
  if size < 32 || size > footer_pos + 32 {
    raise BadHeader(reason="APEv2 size 字段 \{size} 越界")
  }
  let items_start = footer_pos + 32 - size
  let items_end = footer_pos
  let items : Array[ApeItem] = []
  let mut pos = items_start
  for _ in 0..<count {
    require_range(data, pos, 8)
    let value_size = read_le32(data, pos)
    let flags = read_le32(data, pos + 4)
    pos += 8
    // key 以 0 结尾，长度上限 255（规范限制 2..255）
    let key_start = pos
    let mut key_end = -1
    let mut i = pos
    while i < items_end {
      if data.at(i) == b'\x00' {
        key_end = i
        break
      }
      i += 1
    }
    if key_end < 0 {
      raise BadHeader(reason="APEv2 条目 key 缺少终止符")
    }
    let key = read_ascii(data, key_start, key_end)
    pos = key_end + 1
    require_range(data, pos, value_size)
    let value = slice_bytes(data, pos, pos + value_size)
    pos += value_size
    items.push({ key, is_binary: (flags & 1) != 0, value, })
  }
  { items, size, offset: items_start, }
}

///|
/// 读一段 ASCII 为字符串。
fn read_ascii(data : BytesView, start : Int32, end : Int32) -> String {
  let buf = StringBuilder()
  for i in start..<end {
    buf.write_char(Int32::unsafe_to_char(data.at(i).to_int()))
  }
  buf.to_string()
}

///|
/// 取某个键的值（不区分 ASCII 大小写）；不存在返回 `None`。
pub fn ApeTag::get(self : ApeTag, key : String) -> Bytes? {
  for item in self.items {
    if item.key.equal_ignore_ascii_case(key) {
      return Some(item.value)
    }
  }
  None
}

///|
/// 取某个键的文本值。
pub fn ApeTag::text(self : ApeTag, key : String) -> String? {
  match self.get(key) {
    None => None
    Some(v) => Some(@utf8.decode_lossy(v.exact_view()))
  }
}

///|
/// 设置一个键：替换同名的全部旧条目，或追加。
///
/// `value` 为空表示删除该键。
pub fn ApeTag::set(
  self : ApeTag,
  key : String,
  value : Bytes,
) -> ApeTag raise TagError {
  let upper = key.to_upper()
  if !is_valid_ape_key(upper) {
    raise BadFrameData(frame_id="APEv2", reason="非法的键名：\{key}")
  }
  let kept : Array[ApeItem] = []
  for item in self.items {
    if !item.key.equal_ignore_ascii_case(key) {
      kept.push(item)
    }
  }
  if value.length() > 0 {
    kept.push({ key: upper, is_binary: false, value, })
  }
  { items: kept, size: self.size, offset: self.offset, }
}

///|
/// APEv2 键名规则：2..255 字符，ASCII 0x20..0x7E，不含 '='。
fn is_valid_ape_key(key : String) -> Bool {
  let n = key.char_length()
  if n < 2 || n > 255 {
    return false
  }
  for c in key {
    let cp = c.to_int()
    if cp < 0x20 || cp > 0x7E || c == '=' {
      return false
    }
  }
  true
}

///|
/// 构造空的 APEv2 标签。
pub fn empty_ape_tag() -> ApeTag {
  { items: [], size: 0, offset: 0, }
}

///|
/// 序列化条目区 + footer。
fn serialize_ape(tag : ApeTag) -> Bytes raise TagError {
  let items = @buffer.Buffer()
  for item in tag.items {
    write_le32(items, item.value.length())
    write_le32(items, if item.is_binary { 1 } else { 0 })
    for c in item.key {
      let cp = c.to_int()
      if cp > 0x7E {
        raise BadFrameData(frame_id="APEv2", reason="键名含非 ASCII 字符")
      }
      items.write_byte(cp.to_byte())
    }
    items.write_byte(b'\x00')
    items.write_bytes(item.value)
  }
  let item_bytes = items.to_bytes()
  let total = item_bytes.length() + 32
  let out = @buffer.Buffer()
  out.write_bytes(item_bytes)
  // footer：magic + version + size + count + flags + reserved(8)
  for c in "APETAGEX" {
    out.write_byte(c.to_int().to_byte())
  }
  write_le32(out, 2000) // version
  write_le32(out, total) // size（含 footer）
  write_le32(out, tag.items.length()) // item count
  // flags：bit31 = 含 header（本实现写纯 footer 形态，不置位）
  write_le32(out, 0)
  for _ in 0..<8 {
    out.write_byte(b'\x00')
  }
  out.to_bytes()
}

///|
/// 用新的 APEv2 标签重写文件：去掉旧的 APEv2（若有），再追加新标签。
///
/// 文件其余部分（含 ID3v2 头部标签与音频）原样保留。
pub fn set_ape_tag(data : BytesView, tag : ApeTag) -> Bytes raise TagError {
  let existing = parse_ape(data)
  // 原 APEv2 占据的尾部区间
  let cut_end = match existing {
    None => data.length()
    Some(t) => t.offset
  }
  let body = slice_bytes(data, 0, cut_end)
  let ape = serialize_ape(tag)
  body.add(ape)
}
