// tags_wbtest.mbt
//
// F7 判据：格式自动识别与统一标签模型。

///|
test "F7 格式识别：FLAC 魔数" {
  let file = tb_flac([(0, tb_streaminfo())], Bytes::make(10, 0xAA))
  @test.assert_eq(detect_format(file.exact_view()) is Flac, true)
}

///|
test "F7 格式识别：MP4 ftyp" {
  let file = tb_box(
    "ftyp",
    Bytes::from_array([
      0x4D, 0x34, 0x41, 0x20, 0x69, 0x73, 0x6F, 0x6D, 0x4D, 0x34, 0x41, 0x20,
    ]),
  )
  @test.assert_eq(detect_format(file.exact_view()) is Mp4, true)
}

///|
test "F7 格式识别：ID3v2 前缀" {
  let file = tb_tag(
    4,
    0,
    [tb_frame(4, "TIT2", 0, tb_text(3, @utf8.encode("T")))],
    0,
  )
  @test.assert_eq(detect_format(file.exact_view()) is Mp3, true)
}

///|
test "F7 格式识别：MP3 帧同步（无 ID3 标签）" {
  let file = Bytes::from_array([0xFF, 0xFB, 0x90, 0x00, 0x11, 0x22])
  @test.assert_eq(detect_format(file.exact_view()) is Mp3, true)
}

///|
test "F7 格式识别：无法识别返回 Unknown" {
  let file = Bytes::make(20, 0x00)
  @test.assert_eq(detect_format(file.exact_view()) is Unknown, true)
}

///|
test "F7 统一视图：ID3v2.4 含 TDRC 日期" {
  let file = tb_tag(
    4,
    0,
    [
      tb_frame(4, "TIT2", 0, tb_text(3, @utf8.encode("标题"))),
      tb_frame(4, "TPE1", 0, tb_text(3, @utf8.encode("艺术家"))),
      tb_frame(4, "TALB", 0, tb_text(3, @utf8.encode("专辑"))),
      tb_frame(4, "TDRC", 0, tb_text(3, @utf8.encode("2026"))),
    ],
    0,
  )
  let info = read_track_info(file.exact_view())
  @test.assert_eq(info.format is Mp3, true)
  @test.assert_eq(info.title, Some("标题"))
  @test.assert_eq(info.artist, Some("艺术家"))
  @test.assert_eq(info.album, Some("专辑"))
  @test.assert_eq(info.date, Some("2026"))
  @test.assert_eq(info.has_cover, false)
}

///|
test "F7 统一视图：ID3v2.3 回退到 TYER" {
  let file = tb_tag(
    3,
    0,
    [
      tb_frame(3, "TIT2", 0, tb_text(0, @utf8.encode("T"))),
      tb_frame(3, "TYER", 0, tb_text(0, @utf8.encode("1999"))),
    ],
    0,
  )
  let info = read_track_info(file.exact_view())
  @test.assert_eq(info.date, Some("1999"))
}

///|
test "F7 统一视图：MP3 有封面时 has_cover 为真" {
  let apic = tb_apic_payload(3, "image/png", 0x03, @utf8.encode(""), tb_png())
  let file = tb_tag(
    4,
    0,
    [
      tb_frame(4, "TIT2", 0, tb_text(3, @utf8.encode("T"))),
      tb_frame(4, "APIC", 0, apic),
    ],
    0,
  )
  let info = read_track_info(file.exact_view())
  @test.assert_eq(info.has_cover, true)
}

///|
test "F7 统一视图：FLAC 字段映射" {
  let file = tb_flac(
    [
      (0, tb_streaminfo()),
      (
        4,
        tb_vc("v", [
          "TITLE=标题", "ARTIST=艺术家", "ALBUM=专辑", "DATE=2024",
        ]),
      ),
      (1, Bytes::make(64, 0x00)),
    ],
    Bytes::make(20, 0xAA),
  )
  let info = read_track_info(file.exact_view())
  @test.assert_eq(info.format is Flac, true)
  @test.assert_eq(info.title, Some("标题"))
  @test.assert_eq(info.artist, Some("艺术家"))
  @test.assert_eq(info.album, Some("专辑"))
  @test.assert_eq(info.date, Some("2024"))
}

///|
test "F7 统一视图：MP4 字段映射与封面" {
  let png = tb_png()
  let file = tb_m4a(
    [
      tb_ilst_entry("©nam", 1, @utf8.encode("标题")),
      tb_ilst_entry("©ART", 1, @utf8.encode("艺术家")),
      tb_ilst_entry("©alb", 1, @utf8.encode("专辑")),
      tb_ilst_entry("covr", 14, png),
    ],
    [],
  )
  let info = read_track_info(file.exact_view())
  @test.assert_eq(info.format is Mp4, true)
  @test.assert_eq(info.title, Some("标题"))
  @test.assert_eq(info.artist, Some("艺术家"))
  @test.assert_eq(info.album, Some("专辑"))
  @test.assert_eq(info.has_cover, true)
}

///|
test "F7 统一视图：MP3 没有 ID3 标签时返回空字段而非报错" {
  let file = Bytes::from_array([0xFF, 0xFB, 0x90, 0x00, 0x11, 0x22])
  let info = read_track_info(file.exact_view())
  @test.assert_eq(info.format is Mp3, true)
  @test.assert_eq(info.title is None, true)
}

///|
test "F7 统一视图：Unknown 格式返回空视图" {
  let file = Bytes::make(20, 0x00)
  let info = read_track_info(file.exact_view())
  @test.assert_eq(info.format is Unknown, true)
  @test.assert_eq(info.title is None, true)
}
