// id3_apic.mbt
//
// APIC（Attached picture，附加图片）帧的读写。
//
// v2.3 与 v2.4 的 APIC 载荷布局完全一致：
//    文本编码  1 字节
//    MIME      <text string> $00            （始终 ISO-8859-1，与编码字节无关）
//    图片类型  1 字节
//    描述      <text string according to encoding> $00 (00)
//    图片数据  <binary data>
//
// 陷阱：MIME 串**不受**编码字节影响，永远是 Latin-1；只有"描述"跟随编码。

///|
/// 封面图片类型（APIC 的图片类型字节，ID3v2 规范 §4.15）。
///
/// 用 `pub(all)` 让调用方能直接构造枚举值；否则只能通过 `from_code` 拿。
pub(all) enum PictureType {
  Other
  FileIcon
  OtherIcon
  FrontCover
  BackCover
  LeafletPage
  Media
  LeadArtist
  Artist
  Conductor
  Band
  Composer
  Lyricist
  RecordingLocation
  DuringRecording
  DuringPerformance
  MovieScreenCapture
  BrightColouredFish
  Illustration
  BandLogotype
  PublisherLogotype
}

///|
/// 图片类型 → 规范字节值。
pub fn PictureType::code(self : PictureType) -> Int32 {
  match self {
    Other => 0x00
    FileIcon => 0x01
    OtherIcon => 0x02
    FrontCover => 0x03
    BackCover => 0x04
    LeafletPage => 0x05
    Media => 0x06
    LeadArtist => 0x07
    Artist => 0x08
    Conductor => 0x09
    Band => 0x0A
    Composer => 0x0B
    Lyricist => 0x0C
    RecordingLocation => 0x0D
    DuringRecording => 0x0E
    DuringPerformance => 0x0F
    MovieScreenCapture => 0x10
    BrightColouredFish => 0x11
    Illustration => 0x12
    BandLogotype => 0x13
    PublisherLogotype => 0x14
  }
}

///|
/// 规范字节值 → 图片类型。20 及以上的值规范未定义，归入 `Other`
/// 并保留原始字节（见 `Picture::raw_type`）。
pub fn PictureType::from_code(code : Int32) -> PictureType {
  match code {
    0x01 => FileIcon
    0x02 => OtherIcon
    0x03 => FrontCover
    0x04 => BackCover
    0x05 => LeafletPage
    0x06 => Media
    0x07 => LeadArtist
    0x08 => Artist
    0x09 => Conductor
    0x0A => Band
    0x0B => Composer
    0x0C => Lyricist
    0x0D => RecordingLocation
    0x0E => DuringRecording
    0x0F => DuringPerformance
    0x10 => MovieScreenCapture
    0x11 => BrightColouredFish
    0x12 => Illustration
    0x13 => BandLogotype
    0x14 => PublisherLogotype
    _ => Other
  }
}

///|
/// 一张附加图片。
pub struct Picture {
  /// MIME 类型（如 `image/png`）。
  mime : String
  /// 图片类型枚举。
  picture_type : PictureType
  /// 图片类型原始字节（保留未定义值）。
  raw_type : Int32
  /// 描述文本。
  description : String
  /// 图片二进制数据。
  data : Bytes
}

///|
/// 构造一张附加图片（供调用方使用；结构体字段本身是只读的）。
pub fn picture(
  mime : String,
  picture_type : PictureType,
  description : String,
  data : Bytes,
) -> Picture {
  { mime, picture_type, raw_type: picture_type.code(), description, data, }
}

///|
/// 解析 APIC 帧载荷。
pub fn parse_picture(payload : BytesView) -> Picture raise TagError {
  if payload.length() < 4 {
    raise BadFrameData(
      frame_id="APIC",
      reason="载荷长度 \{payload.length()} 不足",
    )
  }
  let code = payload.at(0).to_int()
  if code > 3 {
    raise BadFrameData(
      frame_id="APIC",
      reason="未知的文本编码字节 \{code}",
    )
  }
  let enc = TextEncoding::from_code(code)
  // MIME：Latin-1，$00 终止
  let mime_end = find_terminator(payload, 1, Latin1, payload.length())
  let mime = latin1_str(payload, 1, mime_end)
  let type_pos = mime_end + 1
  if type_pos >= payload.length() {
    raise BadFrameData(frame_id="APIC", reason="缺少图片类型字节")
  }
  let raw_type = payload.at(type_pos).to_int()
  // 描述：跟随编码，按其终止符长度跳过
  let desc_start = type_pos + 1
  let desc_end = find_terminator(payload, desc_start, enc, payload.length())
  let description = enc.decode(
    payload.exact_view(start=desc_start, end=desc_end),
  )
  let data_start = desc_end + enc.terminator_len()
  if data_start > payload.length() {
    raise BadFrameData(frame_id="APIC", reason="描述终止符超出载荷")
  }
  {
    mime,
    picture_type: PictureType::from_code(raw_type),
    raw_type,
    description,
    data: slice_bytes(payload, data_start, payload.length()),
  }
}

///|
/// Latin-1 切片转字符串。
fn latin1_str(data : BytesView, start : Int32, end : Int32) -> String {
  let buf = StringBuilder()
  for i in start..<end {
    buf.write_char(Int32::unsafe_to_char(data.at(i).to_int()))
  }
  buf.to_string()
}

///|
/// 序列化 APIC 帧载荷（不含帧头）。
///
/// 编码选择与文本帧一致：v2.4 用 UTF-8，v2.3 用 UTF-16。
pub fn serialize_picture(pic : Picture, major : Int32) -> Bytes raise TagError {
  let enc = if major == 4 { Utf8 } else { Utf16Bom }
  let out = @buffer.Buffer()
  out.write_byte(enc.code().to_byte())
  // MIME 恒为 Latin-1
  for c in pic.mime {
    let cp = c.to_int()
    if cp > 0xFF {
      raise BadFrameData(frame_id="APIC", reason="MIME 含非 Latin-1 字符")
    }
    out.write_byte(cp.to_byte())
  }
  out.write_byte(b'\x00')
  out.write_byte(pic.raw_type.to_byte())
  let desc = encode_string(pic.description, enc)
  out.write_bytes(desc)
  // 描述终止符
  for _ in 0..<enc.terminator_len() {
    out.write_byte(b'\x00')
  }
  out.write_bytes(pic.data)
  out.to_bytes()
}

///|
/// 取标签里的第一张图片。
pub fn Id3Tag::picture(self : Id3Tag) -> Picture? raise TagError {
  match self.frame("APIC") {
    None => None
    Some(f) => Some(parse_picture(f.data.exact_view()))
  }
}

///|
/// 取标签里的全部图片（一个标签可以有多张，如正面 + 背面）。
pub fn Id3Tag::pictures(self : Id3Tag) -> Array[Picture] raise TagError {
  let out : Array[Picture] = []
  for f in self.frames {
    if f.id == "APIC" {
      out.push(parse_picture(f.data.exact_view()))
    }
  }
  out
}
