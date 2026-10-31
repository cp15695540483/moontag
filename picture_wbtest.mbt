// picture_wbtest.mbt
//
// Base64 与 FLAC PICTURE 载荷（Ogg 封面 METADATA_BLOCK_PICTURE）的单元测试。
//
// 判据来源：
//   • Base64 向量取自 RFC 4648 §10（"f"/"fo"/"foo"/"foob"/"fooba"/"foobar"）；
//   • PICTURE 布局取自 xiph.org 的 picture 规范（与 FLAC 块类型 6 同一格式）。

///|
/// 造一段带 PNG 头的数据：签名 + IHDR 长度 + "IHDR" + 宽 + 高。
/// 只为让宽度/高度解析有据可依，后面接的字节代表图片体。
fn tb_png_bytes(w : Int32, h : Int32) -> Bytes {
  let b = @buffer.Buffer()
  b.write_bytes(
    Bytes::from_array([
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49,
      0x48, 0x44, 0x52,
    ]),
  )
  b.write_bytes(write_u32be(w))
  b.write_bytes(write_u32be(h))
  // IHDR 余下 5 字节（位深/颜色类型/压缩/滤波/隔行）+ 假图片数据
  b.write_bytes(Bytes::from_array([0x08, 0x02, 0x00, 0x00, 0x00]))
  b.write_bytes(Bytes::from_array([0xDE, 0xAD, 0xBE, 0xEF]))
  b.to_bytes()
}

///|
test "Base64：RFC 4648 标准向量" {
  let cases = [
    ("", ""),
    ("f", "Zg=="),
    ("fo", "Zm8="),
    ("foo", "Zm9v"),
    ("foob", "Zm9vYg=="),
    ("fooba", "Zm9vYmE="),
    ("foobar", "Zm9vYmFy"),
  ]
  for c in cases {
    let (plain, expect) = c
    let bytes = @utf8.encode(plain)
    @test.assert_eq(base64_encode(bytes.exact_view()), expect)
    let back = base64_decode(expect) catch {
      e => abort("解码失败: \{e.message()}")
    }
    @test.assert_eq(tb_bytes_eq(back, bytes), true)
  }
}

///|
test "Base64：0..255 全字节往返" {
  let b = @buffer.Buffer()
  for i in 0..<256 {
    b.write_byte(i.to_byte())
  }
  let raw = b.to_bytes()
  let text = base64_encode(raw.exact_view())
  let back = base64_decode(text) catch {
    e => abort("解码失败: \{e.message()}")
  }
  @test.assert_eq(tb_bytes_eq(back, raw), true)
}

///|
test "Base64：忽略折行与空白（Vorbis comment 里常被工具折行）" {
  let raw = @utf8.encode("foobar")
  let wrapped = "Zm9v\r\nYmFy\n"
  let back = base64_decode(wrapped) catch {
    e => abort("解码失败: \{e.message()}")
  }
  @test.assert_eq(tb_bytes_eq(back, raw), true)
}

///|
test "Base64：非法字符与截断长度都报错，不静默产出半个结果" {
  let bad_char = try {
    let _ = base64_decode("Zm9v!!!!")
    false
  } catch {
    _ => true
  }
  @test.assert_eq(bad_char, true)
  // 有效字符数对 4 取余为 1 → 截断
  let truncated = try {
    let _ = base64_decode("Zm9vY")
    false
  } catch {
    _ => true
  }
  @test.assert_eq(truncated, true)
}

///|
test "FLAC PICTURE 载荷往返：MIME/类型/描述/图片数据都不丢" {
  let img = tb_png_bytes(300, 200)
  let pic = picture("image/png", FrontCover, "封面说明", img)
  let payload = serialize_flac_picture(pic)
  let back = parse_flac_picture(payload.exact_view()) catch {
    e => abort("解析失败: \{e.message()}")
  }
  @test.assert_eq(back.mime, "image/png")
  @test.assert_eq(back.raw_type, 3)
  @test.assert_eq(back.description, "封面说明")
  @test.assert_eq(tb_bytes_eq(back.data, img), true)
}

///|
test "FLAC PICTURE：宽高从 PNG 头推出，未知图片写 0" {
  let png = serialize_flac_picture(
    picture("image/png", FrontCover, "", tb_png_bytes(300, 200)),
  )
  // 布局固定：type(4) mimeLen(4) mime(9) descLen(4) desc(0) w(4) h(4)
  let w = read_u32be(png.exact_view(), 4 + 4 + 9 + 4 + 0)
  let h = read_u32be(png.exact_view(), 4 + 4 + 9 + 4 + 0 + 4)
  @test.assert_eq(w, 300)
  @test.assert_eq(h, 200)
  // 认不出的格式：宽高写 0，但数据本身照存
  let unknown = serialize_flac_picture(
    picture("image/webp", FrontCover, "", Bytes::from_array([1, 2, 3])),
  )
  let w2 = read_u32be(unknown.exact_view(), 4 + 4 + 10 + 4 + 0)
  @test.assert_eq(w2, 0)
}

///|
/// 造一个最小合法 FLAC：`fLaC` + 单个 PICTURE 块（标记为最后一块）。
/// 块头是 1 字节「最后块标志 + 类型码」+ 3 字节大端长度。
fn tb_flac_with_picture(payload : Bytes) -> Bytes {
  let b = @buffer.Buffer()
  b.write_bytes(Bytes::from_array([0x66, 0x4C, 0x61, 0x43])) // "fLaC"
  let len = payload.length()
  b.write_byte((0x86).to_byte()) // 0x80 最后块 | 6 PICTURE
  b.write_byte(((len >> 16) & 0xFF).to_byte())
  b.write_byte(((len >> 8) & 0xFF).to_byte())
  b.write_byte((len & 0xFF).to_byte())
  b.write_bytes(payload)
  b.to_bytes()
}

///|
test "FLAC 原生 PICTURE 块：能从块里读出封面" {
  let img = tb_png_bytes(48, 32)
  let payload = serialize_flac_picture(
    picture("image/png", FrontCover, "封", img),
  ) catch {
    e => abort("序列化失败: \{e.message()}")
  }
  let file = tb_flac_with_picture(payload)
  let got : Picture? = flac_picture(file.exact_view()) catch {
    e => abort("读取失败: \{e.message()}")
  }
  let pic = match got {
    Some(p) => p
    None => abort("没有读出 PICTURE 块")
  }
  @test.assert_eq(pic.mime, "image/png")
  @test.assert_eq(pic.raw_type, 3)
  @test.assert_eq(pic.description, "封")
  @test.assert_eq(tb_bytes_eq(pic.data, img), true)
}

///|
test "FLAC 没有 PICTURE 块时返回 None，不报错" {
  // 只有 STREAMINFO 块（类型 0，标记为最后一块，载荷 4 字节）
  let file = Bytes::from_array([
    0x66, 0x4C, 0x61, 0x43, 0x80, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00,
  ])
  let got : Picture? = flac_picture(file.exact_view()) catch {
    e => abort("不该报错: \{e.message()}")
  }
  @test.assert_eq(got is None, true)
}

///|
test "Vorbis Comment 封面：写入后能读回，删除后为空" {
  let img = tb_png_bytes(64, 64)
  let pic = picture("image/png", FrontCover, "", img)
  let vc = empty_vorbis_comment("moontag")
  let with_pic = set_vorbis_picture(vc, Some(pic)) catch {
    e => abort("写入失败: \{e.message()}")
  }
  let got = match vorbis_picture(with_pic) {
    Some(p) => p
    None => abort("写入后读不回来")
  }
  @test.assert_eq(got.mime, "image/png")
  @test.assert_eq(tb_bytes_eq(got.data, img), true)
  let removed = set_vorbis_picture(with_pic, None) catch {
    e => abort("删除失败: \{e.message()}")
  }
  @test.assert_eq(vorbis_picture(removed) is None, true)
}

///|
test "Vorbis Comment 封面：坏 Base64 不连坐，能跳过坏条目取到好条目" {
  let img = tb_png_bytes(8, 8)
  let good = base64_encode(
    serialize_flac_picture(picture("image/png", FrontCover, "", img)).exact_view(),
  )
  let vc = empty_vorbis_comment("moontag")
  let v1 = vc.set_key(METADATA_BLOCK_PICTURE, "这不是Base64") catch {
    _ => abort("set_key 失败")
  }
  let v2 = v1.set_key(METADATA_BLOCK_PICTURE, good) catch {
    _ => abort("set_key 失败")
  }
  // 第一张坏、第二张好：必须取到好的那张
  let got = match vorbis_picture(v2) {
    Some(p) => p
    None => abort("坏条目把好条目连坐了")
  }
  @test.assert_eq(tb_bytes_eq(got.data, img), true)
}
