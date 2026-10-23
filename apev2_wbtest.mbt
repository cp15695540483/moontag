// apev2_wbtest.mbt
//
// F5 判据：APEv2 尾部标签的解析、写入与定位（含 ID3v1 之前的 footer）。

///|
/// 拼 APEv2 条目。
fn tb_ape_item(key : String, value : Bytes) -> Bytes {
  let buf = @buffer.Buffer()
  for b in tb_le32(value.length()) {
    buf.write_byte(b)
  }
  for b in tb_le32(0) {
    buf.write_byte(b)
  }
  for c in key {
    buf.write_byte(c.to_int().to_byte())
  }
  buf.write_byte(b'\x00')
  buf.write_bytes(value)
  buf.to_bytes()
}

///|
/// 拼完整 APEv2 标签（条目区 + footer）。
fn tb_ape(items : Array[Bytes]) -> Bytes {
  let body = @buffer.Buffer()
  for it in items {
    body.write_bytes(it)
  }
  let item_bytes = body.to_bytes()
  let total = item_bytes.length() + 32
  let out = @buffer.Buffer()
  out.write_bytes(item_bytes)
  for c in "APETAGEX" {
    out.write_byte(c.to_int().to_byte())
  }
  for b in tb_le32(2000) {
    out.write_byte(b)
  }
  for b in tb_le32(total) {
    out.write_byte(b)
  }
  for b in tb_le32(items.length()) {
    out.write_byte(b)
  }
  for b in tb_le32(0) {
    out.write_byte(b)
  }
  for _ in 0..<8 {
    out.write_byte(b'\x00')
  }
  out.to_bytes()
}

///|
test "F5 解析 APEv2：条目顺序、键名、文本值" {
  let tag_bytes = tb_ape([
    tb_ape_item("Title", @utf8.encode("歌曲名")),
    tb_ape_item("Artist", @utf8.encode("歌手")),
  ])
  let file = Bytes::make(100, 0x55).add(tag_bytes)
  let tag = match parse_ape(file.exact_view()) {
    Some(t) => t
    None => abort("没有解析到 APEv2")
  }
  @test.assert_eq(tag.items.length(), 2)
  @test.assert_eq(tag.items[0].key, "Title")
  @test.assert_eq(tag.items[1].key, "Artist")
  @test.assert_eq(tag.text("title"), Some("歌曲名"))
  @test.assert_eq(tag.text("ARTIST"), Some("歌手"))
  // 标签起点 = 文件长度 - 标签总长
  @test.assert_eq(tag.offset, 100)
}

///|
test "F5 没有 APEv2 的文件返回 None" {
  let file = Bytes::make(200, 0x55)
  @test.assert_eq(parse_ape(file.exact_view()) is None, true)
}

///|
test "F5 尾部有 ID3v1（128 字节）时仍能定位 APEv2" {
  let tag_bytes = tb_ape([tb_ape_item("Title", @utf8.encode("T"))])
  // 音频 + APEv2 + ID3v1
  let id3v1 = Bytes::from_array([0x54, 0x41, 0x47]).add(Bytes::make(125, 0x00))
  let file = Bytes::make(100, 0x55).add(tag_bytes).add(id3v1)
  let tag = match parse_ape(file.exact_view()) {
    Some(t) => t
    None => abort("ID3v1 之后的 APEv2 未被定位")
  }
  @test.assert_eq(tag.text("title"), Some("T"))
}

///|
test "F5 二进制值（flags bit0）被标记" {
  // 手工拼一个 flags=1 的条目
  let buf = @buffer.Buffer()
  for b in tb_le32(4) {
    buf.write_byte(b)
  }
  for b in tb_le32(1) {
    buf.write_byte(b)
  }
  for c in "Cover" {
    buf.write_byte(c.to_int().to_byte())
  }
  buf.write_byte(b'\x00')
  buf.write_bytes(Bytes::from_array([0xDE, 0xAD, 0xBE, 0xEF]))
  let tag_bytes = tb_ape([buf.to_bytes()])
  let file = Bytes::make(50, 0x55).add(tag_bytes)
  let tag = match parse_ape(file.exact_view()) {
    Some(t) => t
    None => abort("未解析")
  }
  @test.assert_eq(tag.items[0].is_binary, true)
  @test.assert_eq(tag.items[0].value.length(), 4)
  @test.assert_eq(tag.items[0].value.at(0).to_int(), 0xDE)
}

///|
test "F5 set 替换同名键（不区分大小写）" {
  let tag_bytes = tb_ape([
    tb_ape_item("Title", @utf8.encode("Old")),
    tb_ape_item("Artist", @utf8.encode("A")),
  ])
  let file = Bytes::make(30, 0x55).add(tag_bytes)
  let tag = parse_ape(file.exact_view()).unwrap()
  let tag2 = tag.set("TITLE", @utf8.encode("New"))
  @test.assert_eq(tag2.text("title"), Some("New"))
  @test.assert_eq(tag2.text("artist"), Some("A"))
  // 不应产生重复 Title
  let mut count = 0
  for it in tag2.items {
    if it.key.equal_ignore_ascii_case("title") {
      count += 1
    }
  }
  @test.assert_eq(count, 1)
}

///|
test "F5 set 空值删除键" {
  let tag_bytes = tb_ape([
    tb_ape_item("Title", @utf8.encode("T")),
    tb_ape_item("Artist", @utf8.encode("A")),
  ])
  let file = Bytes::make(30, 0x55).add(tag_bytes)
  let tag = parse_ape(file.exact_view()).unwrap()
  let tag2 = tag.set("Title", Bytes::new(0))
  @test.assert_eq(tag2.text("title") is None, true)
  @test.assert_eq(tag2.text("artist"), Some("A"))
}

///|
test "F5 写入后 round-trip：读回一致且音频不变" {
  let audio = Bytes::make(300, 0xAA)
  let tag = empty_ape_tag()
    .set("Title", @utf8.encode("标题"))
    .set("Artist", @utf8.encode("歌手"))
  let out = set_ape_tag(audio.exact_view(), tag)
  // 音频必须原样在开头
  for i in 0..<audio.length() {
    @test.assert_eq(out.at(i).to_int(), 0xAA)
  }
  let back = parse_ape(out.exact_view()).unwrap()
  @test.assert_eq(back.text("title"), Some("标题"))
  @test.assert_eq(back.text("artist"), Some("歌手"))
  @test.assert_eq(back.items.length(), 2)
}

///|
test "F5 重写已有 APEv2：不叠加标签" {
  let audio = Bytes::make(100, 0xAA)
  // 两次写入用等长值，便于用文件长度判断标签是否被叠加
  let first = set_ape_tag(
    audio.exact_view(),
    empty_ape_tag().set("Title", @utf8.encode("First")),
  )
  let second = set_ape_tag(
    first.exact_view(),
    empty_ape_tag().set("Title", @utf8.encode("Secnd")),
  )
  let back = parse_ape(second.exact_view()).unwrap()
  @test.assert_eq(back.text("title"), Some("Secnd"))
  @test.assert_eq(back.items.length(), 1)
  // 标签区不应重复累加：文件长度与第一次写入相同
  @test.assert_eq(second.length(), first.length())
  // 音频区仍然完整
  for i in 0..<audio.length() {
    @test.assert_eq(second.at(i).to_int(), 0xAA)
  }
}

///|
test "F5 负例：非法键名（过短、含 =、非 ASCII）" {
  let tag = empty_ape_tag()
  for bad in ["A", "A=B", "中文"] {
    try {
      let _ = tag.set(bad, @utf8.encode("x"))
      abort("键名 {bad} 应当被拒绝")
    } catch {
      TagError::BadFrameData(..) => ()
      _ => abort("错误类型不对")
    }
  }
}

///|
test "F5 负例：size 字段越界报 BadHeader" {
  let buf = @buffer.Buffer()
  for c in "APETAGEX" {
    buf.write_byte(c.to_int().to_byte())
  }
  for b in tb_le32(2000) {
    buf.write_byte(b)
  }
  // size 声明 999999，明显越界
  for b in tb_le32(999999) {
    buf.write_byte(b)
  }
  for b in tb_le32(0) {
    buf.write_byte(b)
  }
  for b in tb_le32(0) {
    buf.write_byte(b)
  }
  for _ in 0..<8 {
    buf.write_byte(b'\x00')
  }
  let file = Bytes::make(50, 0x55).add(buf.to_bytes())
  try {
    let _ = parse_ape(file.exact_view())
    abort("应当报错")
  } catch {
    TagError::BadHeader(..) => ()
    _ => abort("错误类型不对")
  }
}

///|
test "F5 负例：APEv1（version 1000）报 Unsupported" {
  let buf = @buffer.Buffer()
  for c in "APETAGEX" {
    buf.write_byte(c.to_int().to_byte())
  }
  for b in tb_le32(1000) {
    buf.write_byte(b)
  }
  for b in tb_le32(32) {
    buf.write_byte(b)
  }
  for b in tb_le32(0) {
    buf.write_byte(b)
  }
  for b in tb_le32(0) {
    buf.write_byte(b)
  }
  for _ in 0..<8 {
    buf.write_byte(b'\x00')
  }
  let file = Bytes::make(50, 0x55).add(buf.to_bytes())
  try {
    let _ = parse_ape(file.exact_view())
    abort("应当报错")
  } catch {
    TagError::Unsupported(..) => ()
    _ => abort("错误类型不对")
  }
}
