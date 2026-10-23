// tags.mbt
//
// 统一标签模型（F7）：把四种容器的元数据归一成同一组字段，
// 让调用方不必关心文件格式。
//
// 映射关系（写入时按容器选择对应的帧 ID / 键名）：
//   title      ID3v2 TIT2   | Vorbis TITLE   | APEv2 Title   | MP4 ©nam
//   artist     ID3v2 TPE1   | Vorbis ARTIST  | APEv2 Artist  | MP4 ©ART
//   album      ID3v2 TALB   | Vorbis ALBUM   | APEv2 Album   | MP4 ©alb
//   track      ID3v2 TRCK   | Vorbis TRACKNUMBER | APEv2 Track | MP4 trkn
//   date       ID3v2 TYER/TDRC | Vorbis DATE | APEv2 Year    | MP4 ©day
//   genre      ID3v2 TCON   | Vorbis GENRE   | APEv2 Genre   | MP4 ©gen
//   comment    ID3v2 COMM   | Vorbis COMMENT | APEv2 Comment | MP4 ©cmt

///|
/// 音频文件格式。
pub enum AudioFormat {
  /// MP3（ID3v2 头部标签）
  Mp3
  /// FLAC（Vorbis Comment 元数据块）
  Flac
  /// MP4 / M4A（ilst）
  Mp4
  /// 无法识别
  Unknown
}

///|
/// 按文件魔数识别格式。
pub fn detect_format(data : BytesView) -> AudioFormat {
  if data.length() >= 4 &&
    data.at(0) == b'f' &&
    data.at(1) == b'L' &&
    data.at(2) == b'a' &&
    data.at(3) == b'C' {
    return Flac
  }
  // MP4：第 4..8 字节是 ftyp（部分文件是其他盒，但 ftyp 是绝大多数情况）
  if data.length() >= 12 {
    let k = read_ascii(data, 4, 8)
    if k == "ftyp" {
      return Mp4
    }
  }
  // ID3v2
  if data.length() >= 3 &&
    data.at(0) == b'I' &&
    data.at(1) == b'D' &&
    data.at(2) == b'3' {
    return Mp3
  }
  // MP3 帧同步（0xFF 0xE0 掩码），或尾部有 APEv2
  if data.length() >= 2 &&
    data.at(0) == b'\xFF' &&
    (data.at(1).to_int() & 0xE0) == 0xE0 {
    return Mp3
  }
  Unknown
}

///|
/// 统一的可读标签视图（只含常用字段，缺失为 `None`）。
pub struct TrackInfo {
  /// 格式。
  format : AudioFormat
  title : String?
  artist : String?
  album : String?
  track : String?
  date : String?
  genre : String?
  comment : String?
  /// 是否有封面。
  has_cover : Bool
}

///|
/// 读取任意支持格式的标签（统一视图）。
pub fn read_track_info(data : BytesView) -> TrackInfo raise TagError {
  let format = detect_format(data)
  match format {
    Flac => read_flac_info(data)
    Mp4 => read_mp4_info(data)
    Mp3 => read_mp3_info(data)
    Unknown => empty_info(Unknown)
  }
}

///|
/// FLAC 的统一视图。
fn read_flac_info(data : BytesView) -> TrackInfo raise TagError {
  let vc = match read_vorbis_comment(data) {
    Some(c) => c
    None => return empty_info(Flac)
  }
  {
    format: Flac,
    title: vc.get("TITLE"),
    artist: vc.get("ARTIST"),
    album: vc.get("ALBUM"),
    track: vc.get("TRACKNUMBER"),
    date: vc.get("DATE"),
    genre: vc.get("GENRE"),
    comment: vc.get("COMMENT"),
    has_cover: false,
  }
}

///|
/// MP4 的统一视图。
fn read_mp4_info(data : BytesView) -> TrackInfo raise TagError {
  let entries = read_mp4_tags(data)
  {
    format: Mp4,
    title: text_of(entries, "©nam"),
    artist: text_of(entries, "©ART"),
    album: text_of(entries, "©alb"),
    track: text_of(entries, "trkn"),
    date: text_of(entries, "©day"),
    genre: text_of(entries, "©gen"),
    comment: text_of(entries, "©cmt"),
    has_cover: cover_of(entries) is Some(_),
  }
}

///|
/// MP3 的统一视图。
fn read_mp3_info(data : BytesView) -> TrackInfo raise TagError {
  // 没有 ID3v2 标签时退回空视图（MP3 也可能只有 APEv2）
  let tag_opt : Id3Tag? = Some(parse(data)) catch { _ => None }
  let tag = match tag_opt {
    None => return empty_info(Mp3)
    Some(t) => t
  }
  // v2.3 用 TYER，v2.4 用 TDRC
  let date = match tag.text("TDRC") {
    Some(d) => Some(d)
    None => tag.text("TYER")
  }
  {
    format: Mp3,
    title: tag.text("TIT2"),
    artist: tag.text("TPE1"),
    album: tag.text("TALB"),
    track: tag.text("TRCK"),
    date,
    genre: tag.text("TCON"),
    comment: tag.text("COMM"),
    has_cover: tag.picture() is Some(_),
  }
}

///|
/// 空视图。
fn empty_info(format : AudioFormat) -> TrackInfo {
  {
    format,
    title: None,
    artist: None,
    album: None,
    track: None,
    date: None,
    genre: None,
    comment: None,
    has_cover: false,
  }
}

///|
/// 格式的可读名称。
pub fn AudioFormat::name(self : AudioFormat) -> String {
  match self {
    Mp3 => "MP3 / ID3v2"
    Flac => "FLAC / Vorbis Comment"
    Mp4 => "MP4 / ilst"
    Unknown => "未知格式"
  }
}
