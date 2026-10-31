// flac_picture.mbt
//
// FLAC PICTURE 块（块类型 6）与 Vorbis Comment 的 `METADATA_BLOCK_PICTURE`
// 共用同一套载荷布局（xiph.org 的 picture 规范）：
//
//   u32be 图片类型（与 ID3v2 APIC 的类型码同源，3 = 封面正面）
//   u32be MIME 长度 + MIME（ASCII；引用外部 URL 时为 "-->"）
//   u32be 描述长度 + 描述（UTF-8）
//   u32be 宽 / 高 / 颜色深度 / 调色板颜色数
//   u32be 图片数据长度 + 图片数据
//
// 与 ID3v2 APIC 的差别是最容易踩的点：这里**没有**文本编码字节，也**没有**
// $00 终止符，全部字段都是长度前缀；因此不能复用 APIC 的解析器。

///|
/// Vorbis Comment 中存封面的标准键名——Ogg Vorbis / Opus 唯一的封面方式。
pub const METADATA_BLOCK_PICTURE : String = "METADATA_BLOCK_PICTURE"

///|
/// 从图片数据里认出宽高（PNG 的 IHDR、JPEG 的 SOFn 段）。
///
/// 拿不到就返回 `None`，调用方写 0 表示"未知"——规范允许 0，
/// 但能让播放器/管理器直接显示尺寸显然更好。
fn image_dimensions(
  mime : String,
  data : BytesView,
) -> (Int32, Int32)? raise TagError {
  let lower = mime.to_lower()
  let is_png = lower == "image/png" || lower == "png"
  let is_jpeg = lower == "image/jpeg" ||
    lower == "image/jpg" ||
    lower == "jpeg" ||
    lower == "jpg"
  if is_png && data.length() >= 24 {
    // 8 字节签名 + 4 字节块长 + "IHDR" + 宽(u32be) + 高(u32be)
    if data.at(12) == b'I' &&
      data.at(13) == b'H' &&
      data.at(14) == b'D' &&
      data.at(15) == b'R' {
      let w = read_u32be(data, 16)
      let h = read_u32be(data, 20)
      return Some((w, h))
    }
    return None
  }
  if is_jpeg && data.length() > 4 {
    if data.at(0).to_int() != 0xFF || data.at(1).to_int() != 0xD8 {
      return None
    }
    let mut pos = 2
    while pos + 9 < data.length() {
      if data.at(pos).to_int() != 0xFF {
        pos = pos + 1
        continue
      }
      let marker = data.at(pos + 1).to_int()
      // SOF0..SOF3、SOF5..SOF7、SOF9..SOF11、SOF13..SOF15 都带尺寸
      let is_sof = (marker >= 0xC0 && marker <= 0xC3) ||
        (marker >= 0xC5 && marker <= 0xC7) ||
        (marker >= 0xC9 && marker <= 0xCB) ||
        (marker >= 0xCD && marker <= 0xCF)
      if is_sof {
        // 段内布局：长度(2) 精度(1) 高(2) 宽(2)
        let h = read_be(data, pos + 5, 2)
        let w = read_be(data, pos + 7, 2)
        return Some((w, h))
      }
      if marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7) {
        pos = pos + 2
        continue
      }
      let seg = read_be(data, pos + 2, 2)
      if seg <= 0 {
        return None
      }
      pos = pos + 2 + seg
    }
    return None
  }
  None
}

///|
/// 解析 FLAC PICTURE 块载荷（同样用于 Base64 解码后的 METADATA_BLOCK_PICTURE）。
pub fn parse_flac_picture(payload : BytesView) -> Picture raise TagError {
  if payload.length() < 8 {
    raise BadFrameData(
      frame_id="PICTURE",
      reason="载荷长度 \{payload.length()} 不足 8 字节",
    )
  }
  let raw_type = read_u32be(payload, 0)
  let mime_len = read_u32be(payload, 4)
  require_range(payload, 8, mime_len)
  let mime = read_ascii(payload, 8, 8 + mime_len)
  let desc_len_off = 8 + mime_len
  require_range(payload, desc_len_off, 4)
  let desc_len = read_u32be(payload, desc_len_off)
  let desc_off = desc_len_off + 4
  require_range(payload, desc_off, desc_len)
  let description = @utf8.decode_lossy(
    payload.exact_view(start=desc_off, end=desc_off + desc_len),
  )
  // 宽/高/深度/调色板四个 u32 必须存在，即使全是 0
  let geom_off = desc_off + desc_len
  require_range(payload, geom_off, 16)
  let data_len_off = geom_off + 16
  require_range(payload, data_len_off, 4)
  let data_len = read_u32be(payload, data_len_off)
  let data_off = data_len_off + 4
  require_range(payload, data_off, data_len)
  let bytes = slice_bytes(payload, data_off, data_off + data_len)
  {
    mime,
    picture_type: PictureType::from_code(raw_type),
    raw_type,
    description,
    data: bytes,
  }
}

///|
/// 序列化 FLAC PICTURE 块载荷。
///
/// 宽/高/深度从图片数据本身推出来（PNG/JPEG），推不出时写 0 表示未知；
/// 调色板颜色数写 0（真彩色图片不适用）。
pub fn serialize_flac_picture(pic : Picture) -> Bytes raise TagError {
  let mime = @utf8.encode(pic.mime)
  let desc = @utf8.encode(pic.description)
  let (w, h) = match image_dimensions(pic.mime, pic.data.exact_view()) {
    Some((w, h)) => (w, h)
    None => (0, 0)
  }
  let depth : Int32 = if w > 0 { 24 } else { 0 }
  let buf = @buffer.Buffer()
  buf.write_bytes(write_u32be(pic.raw_type))
  buf.write_bytes(write_u32be(mime.length()))
  buf.write_bytes(mime)
  buf.write_bytes(write_u32be(desc.length()))
  buf.write_bytes(desc)
  buf.write_bytes(write_u32be(w))
  buf.write_bytes(write_u32be(h))
  buf.write_bytes(write_u32be(depth))
  buf.write_bytes(write_u32be(0))
  buf.write_bytes(write_u32be(pic.data.length()))
  buf.write_bytes(pic.data)
  buf.to_bytes()
}

///|
/// 尝试把一条 Base64 注释值解析成图片；任何一步失败都返回 `None` 而不是抛出。
fn try_picture_from_base64(value : String) -> Picture? {
  let bytes : Bytes? = Some(base64_decode(value)) catch { _ => None }
  match bytes {
    None => None
    Some(b) => Some(parse_flac_picture(b.exact_view())) catch { _ => None }
  }
}

///|
/// 从 FLAC 文件取封面（原生 PICTURE 元数据块，块类型 6）。
///
/// 与 comment 里的 `METADATA_BLOCK_PICTURE` 是两套并存的机制：FLAC 原生用块，
/// Ogg 只能用 comment。这里取第一个 PICTURE 块；没有块返回 `None`。
/// 注意块载荷是**不带块头**的 PICTURE 结构，所以直接喂给同一套解析器。
pub fn flac_picture(data : BytesView) -> Picture? raise TagError {
  let meta = parse_meta(data)
  let block = match meta.block(Picture) {
    None => return None
    Some(b) => b
  }
  let payload = slice_bytes(data, block.offset, block.offset + block.length)
  Some(parse_flac_picture(payload.exact_view())) catch {
    _ => None
  }
}

///|
/// 从 Vorbis Comment 取封面（Ogg 与 FLAC 的 comment 路径共用）。
///
/// 取第一张能解析出来的 `METADATA_BLOCK_PICTURE`；条目存在但解不出来的，
/// 跳过继续找下一张，全都不行才返回 `None`——封面损坏不该让整个标签读不出。
pub fn vorbis_picture(vc : VorbisComment) -> Picture? {
  for v in vc.get_all(METADATA_BLOCK_PICTURE) {
    match try_picture_from_base64(v) {
      Some(p) => return Some(p)
      None => ()
    }
  }
  None
}

///|
/// 写入 / 删除 Vorbis Comment 里的封面。
///
/// `None` 表示删除全部 `METADATA_BLOCK_PICTURE` 条目。
pub fn set_vorbis_picture(
  vc : VorbisComment,
  pic : Picture?,
) -> VorbisComment raise TagError {
  match pic {
    None => vc.set_key(METADATA_BLOCK_PICTURE, "")
    Some(p) => {
      let payload = serialize_flac_picture(p)
      vc.set_key(METADATA_BLOCK_PICTURE, base64_encode(payload.exact_view()))
    }
  }
}
