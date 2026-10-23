// id3_apic_wbtest.mbt
//
// F3 判据：APIC 帧的读写与 round-trip，重点是"MIME 永远 Latin-1、
// 描述跟随编码"这条容易写错的规则。

///|
/// 造一张最小 PNG（1x1）用于测试。
fn tb_png() -> Bytes {
  Bytes::from_array([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49,
    0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06,
    0x00, 0x00, 0x00, 0x1F,
  ])
}

///|
/// 造一个 Picture。
fn tb_picture(mime : String, desc : String, data : Bytes) -> Picture {
  { mime, picture_type: FrontCover, raw_type: 0x03, description: desc, data, }
}

///|
/// 手工拼 APIC 载荷（v2.4 风格，UTF-8 描述）。
fn tb_apic_payload(
  enc : Int32,
  mime : String,
  pic_type : Int32,
  desc : Bytes,
  data : Bytes,
) -> Bytes {
  let out = @buffer.Buffer()
  out.write_byte(enc.to_byte())
  out.write_bytes(@utf8.encode(mime))
  out.write_byte(b'\x00')
  out.write_byte(pic_type.to_byte())
  out.write_bytes(desc)
  // 终止符
  let term = if enc == 0 || enc == 3 { 1 } else { 2 }
  for _ in 0..<term {
    out.write_byte(b'\x00')
  }
  out.write_bytes(data)
  out.to_bytes()
}

///|
test "F3 解析 APIC：MIME / 类型 / 描述 / 数据" {
  let data = tb_png()
  let payload = tb_apic_payload(
    3,
    "image/png",
    0x03,
    @utf8.encode("front"),
    data,
  )
  let frame = tb_frame(4, "APIC", 0, payload)
  let tag = parse(tb_tag(4, 0, [frame], 0).exact_view())
  let pic = match tag.picture() {
    Some(p) => p
    None => abort("没有 APIC")
  }
  @test.assert_eq(pic.mime, "image/png")
  @test.assert_eq(pic.picture_type is FrontCover, true)
  @test.assert_eq(pic.raw_type, 0x03)
  @test.assert_eq(pic.description, "front")
  @test.assert_eq(pic.data.length(), data.length())
  for i in 0..<data.length() {
    @test.assert_eq(pic.data.at(i).to_int(), data.at(i).to_int())
  }
}

///|
test "F3 MIME 恒为 Latin-1：不受编码字节影响" {
  // 编码字节是 $03(UTF-8)，但 MIME 仍按 Latin-1 读
  let payload = tb_apic_payload(
    3,
    "image/jpeg",
    0x04,
    @utf8.encode(""),
    tb_png(),
  )
  let pic = parse_picture(payload.exact_view())
  @test.assert_eq(pic.mime, "image/jpeg")
  @test.assert_eq(pic.raw_type, 0x04)
  @test.assert_eq(pic.picture_type is BackCover, true)
}

///|
test "F3 描述跟随编码：UTF-16 描述的终止符是 2 字节" {
  // 描述用 UTF-16LE+BOM 编码，若按 1 字节终止符切分会读错数据起点
  let desc = Bytes::from_array([0xFF, 0xFE, 0x41, 0x00])
  let payload = tb_apic_payload(1, "image/png", 0x03, desc, tb_png())
  let pic = parse_picture(payload.exact_view())
  @test.assert_eq(pic.description, "A")
  @test.assert_eq(pic.data.length(), tb_png().length())
  @test.assert_eq(pic.data.at(0).to_int(), 0x89)
}

///|
test "F3 空描述与空 MIME 边界" {
  let payload = tb_apic_payload(3, "", 0x00, @utf8.encode(""), tb_png())
  let pic = parse_picture(payload.exact_view())
  @test.assert_eq(pic.mime, "")
  @test.assert_eq(pic.description, "")
  @test.assert_eq(pic.data.at(0).to_int(), 0x89)
}

///|
test "F3 未定义的图片类型码保留 raw_type" {
  let payload = tb_apic_payload(
    3,
    "image/png",
    0x7F,
    @utf8.encode(""),
    tb_png(),
  )
  let pic = parse_picture(payload.exact_view())
  @test.assert_eq(pic.raw_type, 0x7F)
  @test.assert_eq(pic.picture_type is Other, true)
}

///|
test "F3 写入封面后可读回（v2.4）" {
  let file = Bytes::make(64, 0x55)
  let pic = tb_picture("image/png", "封面", tb_png())
  let out = set_picture(file.exact_view(), Some(pic), WriteOptions::default())
  let tag = parse(out.exact_view())
  let got = match tag.picture() {
    Some(p) => p
    None => abort("写入后读不到 APIC")
  }
  @test.assert_eq(got.mime, "image/png")
  @test.assert_eq(got.description, "封面")
  @test.assert_eq(got.data.length(), tb_png().length())
  for i in 0..<tb_png().length() {
    @test.assert_eq(got.data.at(i).to_int(), tb_png().at(i).to_int())
  }
  // 音频仍在
  @test.assert_eq(out.length() - tag.total_size, 64)
}

///|
test "F3 替换已有封面不产生重复 APIC" {
  let old_payload = tb_apic_payload(
    3,
    "image/jpeg",
    0x03,
    @utf8.encode("old"),
    Bytes::make(8, 0xAA),
  )
  let inner = tb_tag(4, 0, [tb_frame(4, "APIC", 0, old_payload)], 64)
  let file = inner.add(Bytes::make(32, 0x55))
  let new_pic = tb_picture("image/png", "new", tb_png())
  let out = set_picture(
    file.exact_view(),
    Some(new_pic),
    WriteOptions::default(),
  )
  let tag = parse(out.exact_view())
  let pics = tag.pictures()
  @test.assert_eq(pics.length(), 1)
  @test.assert_eq(pics[0].mime, "image/png")
  @test.assert_eq(pics[0].description, "new")
}

///|
test "F3 传 None 删除全部封面" {
  let payload = tb_apic_payload(
    3,
    "image/png",
    0x03,
    @utf8.encode(""),
    tb_png(),
  )
  let inner = tb_tag(4, 0, [tb_frame(4, "APIC", 0, payload)], 32)
  let file = inner.add(Bytes::make(32, 0x55))
  let out = set_picture(file.exact_view(), None, WriteOptions::default())
  let tag = parse(out.exact_view())
  @test.assert_eq(tag.pictures().length(), 0)
  @test.assert_eq(out.length() - tag.total_size, 32)
}

///|
test "F3 round-trip：v2.3 写封面用 UTF-16 描述" {
  let inner = tb_tag(3, 0, [], 16)
  let file = inner.add(Bytes::make(32, 0x55))
  let pic = tb_picture("image/jpeg", "背面", tb_png())
  let out = set_picture(file.exact_view(), Some(pic), WriteOptions::default())
  let tag = parse(out.exact_view())
  @test.assert_eq(tag.major, 3)
  let got = match tag.picture() {
    Some(p) => p
    None => abort("读不到 APIC")
  }
  @test.assert_eq(got.description, "背面")
  @test.assert_eq(got.mime, "image/jpeg")
}

///|
test "F3 负例：APIC 载荷过短报 BadFrameData" {
  try {
    let _ = parse_picture(Bytes::from_array([0x03, 0x69]).exact_view())
    abort("应当报错")
  } catch {
    TagError::BadFrameData(..) => ()
    _ => abort("错误类型不对")
  }
}

///|
test "F3 负例：未知编码字节报 BadFrameData" {
  let payload = tb_apic_payload(
    3,
    "image/png",
    0x03,
    @utf8.encode(""),
    tb_png(),
  )
  // 篡改编码字节为 9
  let buf = @buffer.Buffer()
  buf.write_byte(b'\x09')
  for i in 1..<payload.length() {
    buf.write_byte(payload.at(i))
  }
  try {
    let _ = parse_picture(buf.to_bytes().exact_view())
    abort("应当报错")
  } catch {
    TagError::BadFrameData(..) => ()
    _ => abort("错误类型不对")
  }
}

///|
test "F3 负例：写入空图片数据报错" {
  let file = Bytes::make(32, 0x55)
  let bad = tb_picture("image/png", "", Bytes::new(0))
  try {
    let _ = set_picture(file.exact_view(), Some(bad), WriteOptions::default())
    abort("应当报错")
  } catch {
    TagError::BadFrameData(..) => ()
    _ => abort("错误类型不对")
  }
}
