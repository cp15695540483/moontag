// mp4_wbtest.mbt
//
// F6 判据：MP4 盒树定位（尤其 meta 是 FullBox 的 +4 偏移）、
// ilst 条目解析、data 盒的 version/flags/type 布局、写入 round-trip。

///|
/// 拼一个 MP4 盒（尺寸自动计算）。
///
/// 类型码按**原始字节**写：`©` 在 MP4 里是单字节 0xA9，不是 UTF-8 的 C2 A9。
fn tb_box_raw(kind_bytes : Bytes, payload : Bytes) -> Bytes {
  let total = payload.length() + 8
  let head = Bytes::from_array([
    ((total >> 24) & 0xFF).to_byte(),
    ((total >> 16) & 0xFF).to_byte(),
    ((total >> 8) & 0xFF).to_byte(),
    (total & 0xFF).to_byte(),
  ])
  head.add(kind_bytes).add(payload)
}

///|
/// 拼一个 ASCII 类型码的盒。
fn tb_box(kind : String, payload : Bytes) -> Bytes {
  tb_box_raw(@utf8.encode(kind), payload)
}

///|
/// 拼一个 ilst 条目。
///
/// 键名以 `©` 开头时（如 `©nam`）按 MP4 惯例写成单字节 0xA9 + 3 个 ASCII；
/// 其余键（如 `covr`、`trkn`）全部是 ASCII。
fn tb_ilst_entry(key : String, data_type : Int32, value : Bytes) -> Bytes {
  let data_payload = Bytes::from_array([
    0x00,
    0x00,
    0x00,
    data_type.to_byte(),
    0x00,
    0x00,
    0x00,
    0x00,
  ]).add(value)
  let key_bytes = if key.has_prefix("©") {
    let mut out = Bytes::from_array([0xA9])
    let mut n = 0
    for c in key {
      if n > 0 {
        out = out.add(Bytes::from_array([c.to_int().to_byte()]))
      }
      n += 1
    }
    out
  } else {
    @utf8.encode(key)
  }
  tb_box_raw(key_bytes, tb_box("data", data_payload))
}

///|
/// 拼一个含 ilst 的完整 M4A 结构。
fn tb_m4a(entries : Array[Bytes], extra_moov : Array[Bytes]) -> Bytes {
  let ilst_inner = @buffer.Buffer()
  for e in entries {
    ilst_inner.write_bytes(e)
  }
  let ilst = tb_box("ilst", ilst_inner.to_bytes())
  // meta 是 FullBox：4 字节 version/flags 之后才是子盒
  let hdlr = tb_box("hdlr", Bytes::make(24, 0x00))
  let meta = tb_box(
    "meta",
    Bytes::from_array([0x00, 0x00, 0x00, 0x00]).add(hdlr).add(ilst),
  )
  let udta = tb_box("udta", meta)
  let moov_inner = @buffer.Buffer()
  for e in extra_moov {
    moov_inner.write_bytes(e)
  }
  moov_inner.write_bytes(udta)
  let moov = tb_box("moov", moov_inner.to_bytes())
  let ftyp = tb_box(
    "ftyp",
    Bytes::from_array([
      0x4D, 0x34, 0x41, 0x20, 0x69, 0x73, 0x6F, 0x6D, 0x4D, 0x34, 0x41, 0x20,
    ]),
  )
  let mdat = tb_box("mdat", Bytes::make(64, 0xAA))
  ftyp.add(moov).add(mdat)
}

///|
test "F6 定位 ilst 并解析条目（含 meta 的 FullBox +4 偏移）" {
  let file = tb_m4a(
    [
      tb_ilst_entry("©nam", 1, @utf8.encode("标题")),
      tb_ilst_entry("©ART", 1, @utf8.encode("艺术家")),
    ],
    [],
  )
  let entries = read_mp4_tags(file.exact_view())
  @test.assert_eq(entries.length(), 2)
  @test.assert_eq(entries[0].key, "©nam")
  @test.assert_eq(entries[0].data_type, 1)
  @test.assert_eq(text_of(entries, "©nam"), Some("标题"))
  @test.assert_eq(text_of(entries, "©ART"), Some("艺术家"))
}

///|
test "F6 data 盒的 type 在 flags 最低字节（不是独立 4 字节）" {
  // 若把 type 当成独立 4 字节读，这里会读到 0 且值前面多出 4 个空字节
  let file = tb_m4a([tb_ilst_entry("©nam", 1, @utf8.encode("X"))], [])
  let entries = read_mp4_tags(file.exact_view())
  @test.assert_eq(entries[0].data_type, 1)
  @test.assert_eq(entries[0].value.length(), 1)
  @test.assert_eq(entries[0].value.at(0).to_int(), 0x58)
}

///|
test "F6 没有 ilst 的文件返回空数组" {
  let ftyp = tb_box(
    "ftyp",
    Bytes::from_array([
      0x4D, 0x34, 0x41, 0x20, 0x69, 0x73, 0x6F, 0x6D, 0x4D, 0x34, 0x41, 0x20,
    ]),
  )
  let moov = tb_box("moov", tb_box("mvhd", Bytes::make(20, 0x00)))
  let file = ftyp.add(moov)
  @test.assert_eq(read_mp4_tags(file.exact_view()).length(), 0)
}

///|
test "F6 写入新条目：round-trip 且不改动 mdat" {
  let file = tb_m4a([tb_ilst_entry("©nam", 1, @utf8.encode("旧"))], [])
  let out = set_mp4_tags(file.exact_view(), [mp4_text_tag("©nam", "新标题")])
  let entries = read_mp4_tags(out.exact_view())
  @test.assert_eq(text_of(entries, "©nam"), Some("新标题"))
  // mdat 载荷必须原样保留
  @test.assert_eq(out.has_suffix(Bytes::make(64, 0xAA)), true)
}

///|
test "F6 同 key 替换不叠加" {
  let file = tb_m4a(
    [
      tb_ilst_entry("©nam", 1, @utf8.encode("旧")),
      tb_ilst_entry("©ART", 1, @utf8.encode("艺术家")),
    ],
    [],
  )
  let out = set_mp4_tags(file.exact_view(), [mp4_text_tag("©nam", "新")])
  let entries = read_mp4_tags(out.exact_view())
  let mut count = 0
  for e in entries {
    if e.key == "©nam" {
      count += 1
    }
  }
  @test.assert_eq(count, 1)
  @test.assert_eq(text_of(entries, "©nam"), Some("新"))
  @test.assert_eq(text_of(entries, "©ART"), Some("艺术家"))
}

///|
test "F6 新增之前不存在的键" {
  let file = tb_m4a([tb_ilst_entry("©nam", 1, @utf8.encode("T"))], [])
  let out = set_mp4_tags(file.exact_view(), [
    mp4_text_tag("©alb", "专辑"),
    mp4_text_tag("©day", "2026"),
  ])
  let entries = read_mp4_tags(out.exact_view())
  @test.assert_eq(entries.length(), 3)
  @test.assert_eq(text_of(entries, "©alb"), Some("专辑"))
  @test.assert_eq(text_of(entries, "©day"), Some("2026"))
  @test.assert_eq(text_of(entries, "©nam"), Some("T"))
}

///|
test "F6 封面：covr 条目与 data type 14（PNG）" {
  let png = Bytes::from_array([0x89, 0x50, 0x4E, 0x47])
  let file = tb_m4a([tb_ilst_entry("©nam", 1, @utf8.encode("T"))], [])
  let out = set_mp4_tags(file.exact_view(), [mp4_cover_tag(png, true)])
  let entries = read_mp4_tags(out.exact_view())
  let cover = match cover_of(entries) {
    Some(c) => c
    None => abort("没有 covr")
  }
  @test.assert_eq(cover.length(), 4)
  @test.assert_eq(cover.at(0).to_int(), 0x89)
  // 找到 covr 的 data_type
  let mut ctype = -1
  for e in entries {
    if e.key == "covr" {
      ctype = e.data_type
    }
  }
  @test.assert_eq(ctype, 14)
}

///|
test "F6 moov 里其他盒（如 mvhd）被保留" {
  let mvhd = tb_box("mvhd", Bytes::make(100, 0x11))
  let file = tb_m4a([tb_ilst_entry("©nam", 1, @utf8.encode("T"))], [mvhd])
  let out = set_mp4_tags(file.exact_view(), [mp4_text_tag("©nam", "New")])
  // mvhd 的 100 字节 0x11 载荷应仍在输出里
  @test.assert_eq(out.find(Bytes::make(100, 0x11)) is Some(_), true)
}

///|
test "F6 负例：盒尺寸越界报 BadHeader" {
  // 声明 9999 字节的 ftyp，实际只有几个字节
  let bad = Bytes::from_array([0x00, 0x00, 0x27, 0x0F, 0x66, 0x74, 0x79, 0x70])
  try {
    let _ = read_mp4_tags(bad.exact_view())
    abort("应当报错")
  } catch {
    TagError::BadHeader(..) => ()
    _ => abort("错误类型不对")
  }
}

///|
test "F6 负例：写不含 moov 的文件报 BadHeader" {
  let ftyp = tb_box(
    "ftyp",
    Bytes::from_array([
      0x4D, 0x34, 0x41, 0x20, 0x69, 0x73, 0x6F, 0x6D, 0x4D, 0x34, 0x41, 0x20,
    ]),
  )
  try {
    let _ = set_mp4_tags(ftyp.exact_view(), [mp4_text_tag("©nam", "X")])
    abort("应当报错")
  } catch {
    TagError::BadHeader(..) => ()
    _ => abort("错误类型不对")
  }
}

///|
test "F6 无 ilst 时写入会新建整条 udta/meta/ilst 路径" {
  let ftyp = tb_box(
    "ftyp",
    Bytes::from_array([
      0x4D, 0x34, 0x41, 0x20, 0x69, 0x73, 0x6F, 0x6D, 0x4D, 0x34, 0x41, 0x20,
    ]),
  )
  let moov = tb_box("moov", tb_box("mvhd", Bytes::make(20, 0x00)))
  let mdat = tb_box("mdat", Bytes::make(32, 0xBB))
  let file = ftyp.add(moov).add(mdat)
  let out = set_mp4_tags(file.exact_view(), [mp4_text_tag("©nam", "新建")])
  let entries = read_mp4_tags(out.exact_view())
  @test.assert_eq(text_of(entries, "©nam"), Some("新建"))
  // mdat 保留
  @test.assert_eq(out.has_suffix(Bytes::make(32, 0xBB)), true)
  // moov 里原有的 mvhd 保留
  @test.assert_eq(out.find(Bytes::make(20, 0x00)) is Some(_), true)
}
