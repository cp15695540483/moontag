// id3_compress_wbtest.mbt
//
// 帧头"格式标志位组合"的判据：压缩帧（v2.3 $80 / v2.4 $08+$01）、分组帧
// （v2.3 $20 / v2.4 $40）、只有数据长度指示的帧（v2.4 $01）。
//
// 这些标志位都在规范内（id3v2.3.0 §3.3.1、id3v2.4.0-structure §4.1.2），
// 因此判据是两条：
//   1. 读取：不能因为某一帧的标志位组合而让**整个标签**读不出来；
//   2. 写入：额外头字段（组号 / 解压后尺寸 / DLI）与标志位必须保持一致，
//      只跳过不补回会让帧载荷整体错位——这类损坏是静默的，最难发现。
//
// 压缩数据的来源有两处，刻意不单一：
//   • "GroupedTitle" 的 zlib 字节由 Python `zlib.compress` 生成后硬编码在测试里
//     （与本库的解压实现完全独立）；
//   • 其余用 `@moon_yazi.compress` 现场生成，并由 tools/samples 下 Python 造的
//     真实夹具与 ffmpeg 对拍兜底。

///|
/// 用 zlib（RFC 1950）压缩；失败即测试环境问题，直接 abort。
fn tb_zlib(data : Bytes) -> Bytes {
  Bytes::from_array(
    @moon_yazi.compress(
      data,
      @moon_yazi.Format::Zlib,
      @moon_yazi.CompressionLevel::Default,
    ) catch {
      e => abort("测试用 zlib 压缩失败: \{e.to_string()}")
    },
  )
}

///|
/// v2.4 压缩帧的载荷：synchsafe DLI（值 = 解压后长度）+ zlib 流。
fn tb_cpayload_v24(plain : Bytes) -> Bytes {
  let out = @buffer.Buffer()
  tb_put_synchsafe(out, plain.length())
  out.write_bytes(tb_zlib(plain))
  out.to_bytes()
}

///|
/// v2.3 压缩帧的载荷：普通大端 u32 解压后长度 + zlib 流。
fn tb_cpayload_v23(plain : Bytes) -> Bytes {
  let out = @buffer.Buffer()
  for b in tb_u32be(plain.length()) {
    out.write_byte(b)
  }
  out.write_bytes(tb_zlib(plain))
  out.to_bytes()
}

///|
/// 两个字节串逐字节相等。
fn tb_bytes_eq(a : Bytes, b : Bytes) -> Bool {
  if a.length() != b.length() {
    return false
  }
  for i in 0..<a.length() {
    if a.at(i) != b.at(i) {
      return false
    }
  }
  true
}

///|
/// unsynchronisation 的编码方向（写入侧）：在每个 `$FF` 后插入 `$00`。
///
/// 库里的 `unsynchronise` 是**还原**方向，测试要造"磁盘上的形态"，
/// 所以这里补一个编码方向的小工具。
fn tb_unsync_encode(data : Bytes) -> Bytes {
  let out = @buffer.Buffer()
  for i in 0..<data.length() {
    let b = data.at(i)
    out.write_byte(b)
    if b == b'\xFF' {
      out.write_byte(b'\x00')
    }
  }
  out.to_bytes()
}

///|
/// 字节串里是否含有某个字节值。
fn tb_has_byte(data : Bytes, v : Int32) -> Bool {
  for i in 0..<data.length() {
    if data.at(i).to_int() == v {
      return true
    }
  }
  false
}

///|
/// 长文本（>127 字节，保证 zlib 输出不是"一字节头 + 明文"的假象）。
fn tb_long_text() -> String {
  let mut s = "CompressedTitle-"
  for _ in 0..<20 {
    s = s + "0123456789"
  }
  s
}

///|

///|
/// 从序列化字节里扫描某个帧，返回 `(格式标志, DLI 值)`；无 DLI 时为 `None`。
///
/// 用来直接校验**磁盘上的 DLI 字节**——只断言"载荷长度"抓不到"DLI 恒写 0"
/// 这类错误（写入值和读回值都自洽，但字段本身是错的）。
fn tb_scan_dli(data : Bytes, id : String) -> (Int32, Int32?) raise TagError {
  let view = data.exact_view()
  let major = data.at(3).to_int()
  let mut pos = 10
  let mut found : (Int32, Int32?) = (0, None)
  while pos + 10 <= view.length() {
    if view.at(pos) == b'\x00' {
      break
    }
    let fid = read_frame_id(view, pos)
    let size = if major == 4 {
      read_synchsafe32(view, pos + 4)
    } else {
      read_u32be(view, pos + 4)
    }
    let flags = view.at(pos + 9).to_int()
    if fid == id {
      let mut extra = 0
      if major == 4 {
        if (flags & 0x40) != 0 {
          extra += 1
        }
        if (flags & 0x04) != 0 {
          extra += 1
        }
        let dli = if (flags & 0x01) != 0 {
          Some(read_synchsafe32(view, pos + 10 + extra))
        } else {
          None
        }
        found = (flags, dli)
      } else {
        if (flags & 0x80) != 0 {
          extra += 4
        }
        if (flags & 0x40) != 0 {
          extra += 1
        }
        if (flags & 0x20) != 0 {
          extra += 1
        }
        found = (flags, None)
      }
      break
    }
    pos += 10 + size
  }
  found
}

///|
test "压缩帧（v2.4）：DLI + zlib 载荷可解出文本" {
  // Python 3.14 `zlib.compress(bytes([3]) + b"GroupedTitle")` 的原始字节
  // （含文本帧的编码字节 $03）。
  let zlib_bytes = Bytes::from_array([
    0x78, 0x9C, 0x63, 0x76, 0x2F, 0xCA, 0x2F, 0x2D, 0x48, 0x4D, 0x09, 0xC9, 0x2C,
    0xC9, 0x49, 0x05, 0x00, 0x1F, 0x5D, 0x04, 0xDC,
  ])
  let plain = tb_text(3, @utf8.encode("GroupedTitle"))
  let payload = @buffer.Buffer()
  tb_put_synchsafe(payload, plain.length())
  payload.write_bytes(zlib_bytes)
  let tag = parse(
    tb_tag(4, 0, [tb_frame(4, "TIT2", 0x09, payload.to_bytes())], 0).exact_view(),
  )
  @test.assert_eq(tag.text("TIT2"), Some("GroupedTitle"))
}

///|
test "压缩帧（v2.3）：4 字节解压后尺寸 + zlib 载荷可解出文本" {
  let plain = tb_text(0, @utf8.encode("GroupedV23"))
  let tag = parse(
    tb_tag(3, 0, [tb_frame(3, "TIT2", 0x80, tb_cpayload_v23(plain))], 0).exact_view(),
  )
  @test.assert_eq(tag.text("TIT2"), Some("GroupedV23"))
}

///|
test "压缩帧：长文本（>127 字节）解压后逐字节一致" {
  let value = tb_long_text()
  let plain = tb_text(3, @utf8.encode(value))
  let tag = parse(
    tb_tag(4, 0, [tb_frame(4, "TIT2", 0x09, tb_cpayload_v24(plain))], 0).exact_view(),
  )
  @test.assert_eq(tag.text("TIT2"), Some(value))
}

///|
test "压缩帧（v2.3）长文本：尺寸字段是大端 u32，不能按 synchsafe 读" {
  // 219 字节的声明值：大端 u32 是 00 00 00 DB，synchsafe 会是 00 00 01 5B。
  // 两者不同，这条用例才钉得住"v2.3 用普通 u32"这个版本差异。
  let value = tb_long_text()
  let plain = tb_text(0, @utf8.encode(value))
  @test.assert_eq(plain.length() > 127, true)
  let tag = parse(
    tb_tag(3, 0, [tb_frame(3, "TIT2", 0x80, tb_cpayload_v23(plain))], 0).exact_view(),
  )
  @test.assert_eq(tag.text("TIT2"), Some(value))
}

///|
test "压缩帧不再连坐：无关帧（TXXX）被压缩时其余字段照常读出" {
  let title = tb_frame(4, "TIT2", 0, tb_text(3, @utf8.encode("PlainTitle")))
  let artist = tb_frame(4, "TPE1", 0, tb_text(3, @utf8.encode("PlainArtist")))
  // 被压缩的 TXXX 故意放在最后：解析循环已经走完前面两帧。
  let txxx = tb_frame(
    4,
    "TXXX",
    0x09,
    tb_cpayload_v24(tb_text(3, @utf8.encode("irrelevant-value"))),
  )
  let tag = parse(tb_tag(4, 0, [title, artist, txxx], 0).exact_view())
  @test.assert_eq(tag.frames.length(), 3)
  @test.assert_eq(tag.text("TIT2"), Some("PlainTitle"))
  @test.assert_eq(tag.text("TPE1"), Some("PlainArtist"))
}

///|
test "压缩帧 round-trip：改写其它字段后，被压缩的帧内容不丢、压缩位清掉" {
  let value = tb_long_text()
  let plain = tb_text(3, @utf8.encode(value))
  let file = tb_tag(
    4,
    0,
    [tb_frame(4, "TIT2", 0x09, tb_cpayload_v24(plain))],
    8,
  ).add(Bytes::make(32, 0x55))
  let out = set_fields(
    file.exact_view(),
    [field("TCON", "Rock")],
    WriteOptions::default(),
  )
  let tag = parse(out.exact_view())
  @test.assert_eq(tag.text("TIT2"), Some(value))
  @test.assert_eq(tag.text("TCON"), Some("Rock"))
  // 写回的是未压缩帧：帧载荷 = 编码字节 + 文本，压缩位必须已清
  let f = match tag.frame("TIT2") {
    Some(f) => f
    None => abort("TIT2 丢失")
  }
  @test.assert_eq(f.format_flags & 0x08, 0)
  @test.assert_eq(f.data.length(), plain.length())
}

///|
test "分组帧 round-trip（v2.4 $40）：组号字节被补回，文本不错位" {
  let file = tb_tag(
    4,
    0,
    [
      // [组号 0x07][编码字节 + 文本]
      tb_frame(
        4,
        "TIT2",
        0x40,
        Bytes::from_array([0x07]).add(tb_text(3, @utf8.encode("GroupedTitle"))),
      ),
      tb_frame(4, "TPE1", 0, tb_text(3, @utf8.encode("PlainArtist"))),
    ],
    8,
  ).add(Bytes::make(32, 0x55))
  // 先确认读取侧本来就是对的一字节组号语义
  @test.assert_eq(tb_text_of(file, "TIT2"), "GroupedTitle")
  let out = set_fields(
    file.exact_view(),
    [field("TCON", "Rock")],
    WriteOptions::default(),
  )
  let tag = parse(out.exact_view())
  @test.assert_eq(tag.text("TIT2"), Some("GroupedTitle"))
  let f = match tag.frame("TIT2") {
    Some(f) => f
    None => abort("TIT2 丢失")
  }
  @test.assert_eq(f.format_flags & 0x40, 0x40)
  @test.assert_eq(f.group, Some(7))
  @test.assert_eq(f.data.length(), 13)
}

///|
test "分组帧 round-trip（v2.3 $20）：组号字节被补回，文本不错位" {
  let file = tb_tag(
    3,
    0,
    [
      tb_frame(
        3,
        "TIT2",
        0x20,
        Bytes::from_array([0x07]).add(tb_text(0, @utf8.encode("GroupedV23"))),
      ),
    ],
    8,
  ).add(Bytes::make(32, 0x55))
  @test.assert_eq(tb_text_of(file, "TIT2"), "GroupedV23")
  let out = set_fields(
    file.exact_view(),
    [field("TCON", "Rock")],
    WriteOptions::default(),
  )
  let tag = parse(out.exact_view())
  @test.assert_eq(tag.text("TIT2"), Some("GroupedV23"))
  let f = match tag.frame("TIT2") {
    Some(f) => f
    None => abort("TIT2 丢失")
  }
  @test.assert_eq(f.group, Some(7))
}

///|
test "只有数据长度指示（v2.4 $01）的帧：round-trip 不改动文本、DLI 值重算" {
  let text = tb_text(3, @utf8.encode("DLI-Title"))
  let payload = @buffer.Buffer()
  tb_put_synchsafe(payload, text.length())
  payload.write_bytes(text)
  let file = tb_tag(4, 0, [tb_frame(4, "TIT2", 0x01, payload.to_bytes())], 8).add(
    Bytes::make(32, 0x55),
  )
  @test.assert_eq(tb_text_of(file, "TIT2"), "DLI-Title")
  let out = set_fields(
    file.exact_view(),
    [field("TCON", "Rock")],
    WriteOptions::default(),
  )
  let tag = parse(out.exact_view())
  @test.assert_eq(tag.text("TIT2"), Some("DLI-Title"))
  let f = match tag.frame("TIT2") {
    Some(f) => f
    None => abort("TIT2 丢失")
  }
  @test.assert_eq(f.format_flags & 0x01, 0x01)
  @test.assert_eq(f.data.length(), text.length())
  // 磁盘上的 DLI 值必须等于新载荷长度（不是 0、也不是旧值）
  let (scan_flags, dli) = tb_scan_dli(out, "TIT2") catch {
    e => abort("扫描写入结果失败: \{e.message()}")
  }
  @test.assert_eq(scan_flags & 0x01, 0x01)
  @test.assert_eq(dli, Some(text.length()))
}

///|
test "写入负例：ID3 头存在但解析失败时报错，不能悄悄产出双标签" {
  // 坏 zlib 流的压缩帧：整标签读不出来。
  let bad = Bytes::from_array([
    0x78, 0x9C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  ])
  let payload = @buffer.Buffer()
  tb_put_synchsafe(payload, 32)
  payload.write_bytes(bad)
  let file = tb_tag(4, 0, [tb_frame(4, "TIT2", 0x09, payload.to_bytes())], 0).add(
    Bytes::make(64, 0x55),
  )
  // 读取侧：报错
  let mut read_failed = false
  try {
    let _ = parse(file.exact_view())
  } catch {
    _ => read_failed = true
  }
  @test.assert_eq(read_failed, true)
  // 写入侧：必须同样报错——否则会在原文件前再插一个标签，原文件整体变成"音频"
  let mut write_failed = false
  try {
    let _ = set_fields(
      file.exact_view(),
      [field("TIT2", "New")],
      WriteOptions::default(),
    )
  } catch {
    _ => write_failed = true
  }
  @test.assert_eq(write_failed, true)
}

///|
test "写入正例：完全没有 ID3 头的文件仍然正常新建标签" {
  let file = Bytes::make(64, 0x55)
  let out = set_fields(
    file.exact_view(),
    [field("TIT2", "New")],
    WriteOptions::default(),
  )
  let tag = parse(out.exact_view())
  @test.assert_eq(tag.text("TIT2"), Some("New"))
  @test.assert_eq(out.length() - tag.total_size, 64)
}

///|
test "unsync + 压缩组合（v2.4 $02|$08）：先还原 unsync 再解压" {
  // 这段 zlib 流由 Python 3.14 手工构造为单个"存储块"（stored deflate block），
  // 并用 `zlib.decompress` 回读校验过：里面含大量 0xFF 0xE0，
  // 因此 unsynchronise 必然插入 0x00——"先还原 unsync、再解压"这条顺序
  // 只有在这种流上才真正被钉住（普通 zlib 输出里往往一个 0xFF 都没有）。
  let stream = Bytes::from_array([
    0x78, 0x01, 0x01, 0x51, 0x00, 0xAE, 0xFF, 0x03, 0xFF, 0xE0, 0xFF, 0xE0, 0xFF,
    0xE0, 0xFF, 0xE0, 0xFF, 0xE0, 0xFF, 0xE0, 0xFF, 0xE0, 0xFF, 0xE0, 0xFF, 0xE0,
    0xFF, 0xE0, 0xFF, 0xE0, 0xFF, 0xE0, 0xFF, 0xE0, 0xFF, 0xE0, 0xFF, 0xE0, 0xFF,
    0xE0, 0xFF, 0xE0, 0xFF, 0xE0, 0xFF, 0xE0, 0xFF, 0xE0, 0xFF, 0xE0, 0xFF, 0xE0,
    0xFF, 0xE0, 0xFF, 0xE0, 0xFF, 0xE0, 0xFF, 0xE0, 0xFF, 0xE0, 0xFF, 0xE0, 0xFF,
    0xE0, 0xFF, 0xE0, 0xFF, 0xE0, 0xFF, 0xE0, 0xFF, 0xE0, 0xFF, 0xE0, 0xFF, 0xE0,
    0xFF, 0xE0, 0xFF, 0xE0, 0xFF, 0xE0, 0xFF, 0xE0, 0xFF, 0xE0, 0xDB, 0x81, 0x4A,
    0xDC,
  ])
  let pair = Bytes::from_array([0xFF, 0xE0])
  let mut plain = Bytes::from_array([0x03])
  for _ in 0..<40 {
    plain = plain.add(pair)
  }
  @test.assert_eq(plain.length(), 81)
  @test.assert_eq(stream.length(), 92)
  @test.assert_eq(tb_has_byte(stream, 0xFF), true)
  let encoded = tb_unsync_encode(stream)
  @test.assert_eq(encoded.length() > stream.length(), true)
  let out = @buffer.Buffer()
  tb_put_synchsafe(out, plain.length())
  out.write_bytes(encoded)
  // $0B = unsync $02 + compression $08 + DLI $01（规范要求压缩必须配 DLI）
  let tag = parse(
    tb_tag(4, 0, [tb_frame(4, "TIT2", 0x0B, out.to_bytes())], 0).exact_view(),
  )
  let f = match tag.frame("TIT2") {
    Some(f) => f
    None => abort("TIT2 丢失")
  }
  @test.assert_eq(tb_bytes_eq(f.data, plain), true)
}

///|
test "分组 + DLI 同时存在（v2.4 $41）：组号在前、DLI 在后的规范顺序" {
  let text = tb_text(3, @utf8.encode("BothFlags"))
  let payload = @buffer.Buffer()
  payload.write_byte(b'\x07')
  tb_put_synchsafe(payload, text.length())
  payload.write_bytes(text)
  let tag = parse(
    tb_tag(4, 0, [tb_frame(4, "TIT2", 0x41, payload.to_bytes())], 0).exact_view(),
  )
  @test.assert_eq(tag.text("TIT2"), Some("BothFlags"))
  let f = match tag.frame("TIT2") {
    Some(f) => f
    None => abort("TIT2 丢失")
  }
  @test.assert_eq(f.group, Some(7))
  @test.assert_eq(f.data.length(), text.length())
  // round-trip：组号与 DLI 都要按规范顺序重发，顺序反了载荷就整体错位。
  let file = tb_tag(4, 0, [tb_frame(4, "TIT2", 0x41, payload.to_bytes())], 8).add(
    Bytes::make(32, 0x55),
  )
  let out = set_fields(
    file.exact_view(),
    [field("TCON", "Rock")],
    WriteOptions::default(),
  )
  let tag2 = parse(out.exact_view())
  @test.assert_eq(tag2.text("TIT2"), Some("BothFlags"))
  @test.assert_eq(tag2.text("TCON"), Some("Rock"))
}

///|
test "解压上限是硬的：声明值比实际小会在解压过程中被挡住" {
  // 32 KB 高度可压缩数据、声明值只写 1 KiB：固定缓冲只有 1 KiB，
  // 解码器越界即抛（实测在 write 阶段就抛），不会先吃满内存再报错。
  let raw = @buffer.Buffer()
  for _ in 0..<8192 {
    raw.write_bytes(Bytes::from_array([0x41, 0x41, 0x41, 0x41]))
  }
  let plain = raw.to_bytes()
  let zlib = tb_zlib(plain)
  let lying = @buffer.Buffer()
  tb_put_synchsafe(lying, 1024)
  lying.write_bytes(zlib)
  let data = tb_tag(4, 0, [tb_frame(4, "TIT2", 0x09, lying.to_bytes())], 0)
  let mut seen = false
  try {
    let _ = parse(data.exact_view())
  } catch {
    BadFrameData(reason~, ..) => {
      @test.assert_eq(
        reason.has_prefix(
          "zlib 解压失败或输出超出声明的 1024 字节",
        ),
        true,
      )
      seen = true
    }
    _ => abort("错误类型应为 BadFrameData")
  }
  @test.assert_eq(seen, true)
  // 对照：声明值正确时同一份数据正常解出
  let honest = @buffer.Buffer()
  tb_put_synchsafe(honest, plain.length())
  honest.write_bytes(zlib)
  let tag = parse(
    tb_tag(4, 0, [tb_frame(4, "TIT2", 0x09, honest.to_bytes())], 0).exact_view(),
  )
  let f = match tag.frame("TIT2") {
    Some(f) => f
    None => abort("TIT2 丢失")
  }
  @test.assert_eq(f.data.length(), plain.length())
}

///|
test "损坏的 zlib 流报结构化错误，不 panic、也不吞掉" {
  let bad = Bytes::from_array([
    0x78, 0x9C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  ])
  let payload = @buffer.Buffer()
  tb_put_synchsafe(payload, 32)
  payload.write_bytes(bad)
  let data = tb_tag(4, 0, [tb_frame(4, "TIT2", 0x09, payload.to_bytes())], 0)
  let mut seen = false
  try {
    let _ = parse(data.exact_view())
  } catch {
    BadFrameData(frame_id~, ..) => {
      @test.assert_eq(frame_id, "TIT2")
      seen = true
    }
    _ => abort("错误类型应为 BadFrameData")
  }
  @test.assert_eq(seen, true)
}

///|
test "压缩帧缺少 DLI（v2.4）报错：规范要求压缩必须配 Data Length Indicator" {
  let payload = tb_zlib(tb_text(3, @utf8.encode("NoDli")))
  let data = tb_tag(4, 0, [tb_frame(4, "TIT2", 0x08, payload)], 0)
  let mut seen = false
  try {
    let _ = parse(data.exact_view())
  } catch {
    BadFrameHeader(..) => seen = true
    _ => abort("错误类型应为 BadFrameHeader")
  }
  @test.assert_eq(seen, true)
}

///|
test "压缩帧声明尺寸超出上限：拒绝而不是照着数字分配内存" {
  let payload = @buffer.Buffer()
  tb_put_synchsafe(payload, 0x04000001)
  payload.write_bytes(tb_zlib(tb_text(3, @utf8.encode("bomb"))))
  let data = tb_tag(4, 0, [tb_frame(4, "TIT2", 0x09, payload.to_bytes())], 0)
  let mut seen = false
  try {
    let _ = parse(data.exact_view())
  } catch {
    BadFrameData(frame_id~, ..) => {
      @test.assert_eq(frame_id, "TIT2")
      seen = true
    }
    _ => abort("错误类型应为 BadFrameData")
  }
  @test.assert_eq(seen, true)
}

///|
test "解压后长度与声明不符：报错，不静默接受" {
  let text = tb_text(3, @utf8.encode("Mismatch"))
  let payload = @buffer.Buffer()
  tb_put_synchsafe(payload, text.length() + 5)
  payload.write_bytes(tb_zlib(text))
  let data = tb_tag(4, 0, [tb_frame(4, "TIT2", 0x09, payload.to_bytes())], 0)
  let mut seen = false
  try {
    let _ = parse(data.exact_view())
  } catch {
    BadFrameData(reason~, ..) => {
      @test.assert_eq(reason.has_prefix("解压后长度"), true)
      seen = true
    }
    _ => abort("错误类型应为 BadFrameData")
  }
  @test.assert_eq(seen, true)
}

///|
test "加密帧仍然明确报 Unsupported（规范把加密方法留给外部注册表）" {
  let data = tb_tag(
    4,
    0,
    [
      tb_frame(
        4,
        "TIT2",
        0x05,
        Bytes::from_array([0x01]).add(tb_text(3, @utf8.encode("x"))),
      ),
    ],
    0,
  )
  let mut seen = false
  try {
    let _ = parse(data.exact_view())
  } catch {
    Unsupported(..) => seen = true
    _ => abort("错误类型应为 Unsupported")
  }
  @test.assert_eq(seen, true)
}

///|
test "无压缩对照：同布局不设压缩位时压缩路径不参与" {
  let value = tb_long_text()
  let file = tb_tag(
    4,
    0,
    [tb_frame(4, "TIT2", 0, tb_text(3, @utf8.encode(value)))],
    0,
  )
  let tag = parse(file.exact_view())
  let f = match tag.frame("TIT2") {
    Some(f) => f
    None => abort("TIT2 丢失")
  }
  @test.assert_eq(tb_bytes_eq(f.data, tb_text(3, @utf8.encode(value))), true)
}
