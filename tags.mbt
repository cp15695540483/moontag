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
  /// Ogg（Vorbis / Opus 的 comment packet）
  Ogg
  /// 无法识别
  Unknown
}

///|
/// 按文件魔数识别格式。
pub fn detect_format(data : BytesView) -> AudioFormat {
  // Ogg：页头魔数 OggS
  if data.length() >= 4 &&
    data.at(0) == b'O' &&
    data.at(1) == b'g' &&
    data.at(2) == b'g' &&
    data.at(3) == b'S' {
    return Ogg
  }
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
    Ogg => read_ogg_info(data)
    Unknown => empty_info(Unknown)
  }
}

///|
/// Ogg（Vorbis / Opus）的统一视图。
///
/// Ogg 的 comment 读取接口基于 `Bytes`（页解析需要随机访问），这里一次性
/// 物化视图——调用方本就把整个文件读进了内存，`read_track_info` 是便利入口，
/// 需要零拷贝时请直接用 `read_ogg_comment`。
fn read_ogg_info(data : BytesView) -> TrackInfo raise TagError {
  let raw = slice_bytes(data, 0, data.length())
  let loc = match read_ogg_comment(raw) {
    Some(l) => l
    None => return empty_info(Ogg)
  }
  let vc = parse_ogg_comment_payload(loc)
  {
    format: Ogg,
    title: vc.get("TITLE"),
    artist: vc.get("ARTIST"),
    album: vc.get("ALBUM"),
    track: vc.get("TRACKNUMBER"),
    date: vc.get("DATE"),
    genre: vc.get("GENRE"),
    comment: vc.get("COMMENT"),
    has_cover: match vorbis_picture(vc) {
      Some(_) => true
      None => false
    },
  }
}

///|
/// FLAC 的统一视图。
///
/// 封面的来源有两条且都要看：FLAC 原生的 PICTURE 块（类型 6），
/// 以及 Vorbis Comment 里的 `METADATA_BLOCK_PICTURE`（后者与 Ogg 同源）。
fn read_flac_info(data : BytesView) -> TrackInfo raise TagError {
  let vc = match read_vorbis_comment(data) {
    Some(c) => c
    None => return empty_info(Flac)
  }
  let from_comment = match vorbis_picture(vc) {
    Some(_) => true
    None => false
  }
  // FLAC 原生 PICTURE 块（块类型 6）与 comment 里的 METADATA_BLOCK_PICTURE
  // 是两套并存的机制，都要看；块解析失败不该让整个视图失败。
  let cover_block : Picture? = flac_picture(data) catch { _ => None }
  let from_block = match cover_block {
    Some(_) => true
    None => false
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
    has_cover: from_comment || from_block,
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
/// MP3 的统一视图：ID3v2 优先，缺失的字段逐项回退到文件尾部的 APEv2。
///
/// 现实中两类文件都存在——只有 ID3v2 的、只有 APEv2 的（ape 生态）、
/// 以及两者并存的（转换工具留下的双标签）。只看 ID3v2 会漏掉后两种。
fn read_mp3_info(data : BytesView) -> TrackInfo raise TagError {
  let ape : ApeTag? = parse_ape(data) catch { _ => None }
  // "没有标签"与"有标签但读不出来"必须分开：
  //   • 连 ID3v2 标签头都不存在（文件太短或无 "ID3" 魔数）→ 正常的无标签文件；
  //   • 标签头存在、内部结构却读不出来（压缩帧、损坏帧、超版本）→ 必须抛出。
  // 后者一旦被吞掉，"有标签但读不出"就会被伪装成"这个文件没有标签"，
  // 调用方（含 CLI）既拿不到字段，也看不到失败原因。
  let has_id3_header = data.length() >= 10 &&
    data.at(0) == b'I' &&
    data.at(1) == b'D' &&
    data.at(2) == b'3'
  let id3 : Id3Tag? = if has_id3_header {
    // 有 APEv2 兜底时按"双标签文件"继续（ID3 侧坏掉仍有字段可用）
    match ape {
      Some(_) => Some(parse(data)) catch { _ => None }
      None => Some(parse(data))
    }
  } else {
    None
  }
  if id3 is None && ape is None {
    return empty_info(Mp3)
  }
  // v2.3 用 TYER，v2.4 用 TDRC
  let id3_date = match id3 {
    Some(t) =>
      match t.text("TDRC") {
        Some(d) => Some(d)
        None => t.text("TYER")
      }
    None => None
  }
  {
    format: Mp3,
    title: mp3_field(id3, ape, "TIT2", "Title"),
    artist: mp3_field(id3, ape, "TPE1", "Artist"),
    album: mp3_field(id3, ape, "TALB", "Album"),
    track: mp3_field(id3, ape, "TRCK", "Track"),
    date: match id3_date {
      Some(d) => Some(d)
      None => ape_text(ape, "Year")
    },
    genre: mp3_field(id3, ape, "TCON", "Genre"),
    comment: mp3_field(id3, ape, "COMM", "Comment"),
    has_cover: mp3_has_cover(id3, ape),
  }
}

///|
/// ID3v2 帧优先，缺失时回退 APEv2 条目（APEv2 键名大小写不敏感）。
fn mp3_field(
  id3 : Id3Tag?,
  ape : ApeTag?,
  id3_key : String,
  ape_key : String,
) -> String? raise TagError {
  let v = match id3 {
    Some(t) => t.text(id3_key)
    None => None
  }
  match v {
    Some(_) => v
    None =>
      match ape {
        Some(a) => a.text(ape_key)
        None => None
      }
  }
}

///|
/// 取 APEv2 文本字段。
fn ape_text(ape : ApeTag?, key : String) -> String? {
  match ape {
    Some(a) => a.text(key)
    None => None
  }
}

///|
/// 封面：ID3v2 的 APIC 或 APEv2 的 `Cover Art (Front)`。
fn mp3_has_cover(id3 : Id3Tag?, ape : ApeTag?) -> Bool raise TagError {
  let from_id3 = match id3 {
    Some(t) => t.picture() is Some(_)
    None => false
  }
  if from_id3 {
    return true
  }
  match ape {
    Some(a) => a.get("Cover Art (Front)") is Some(_)
    None => false
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
    Ogg => "Ogg / Vorbis Comment"
    Unknown => "未知格式"
  }
}
