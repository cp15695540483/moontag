// examples/read_tag/main.mbt
//
// 可运行示例：读取音频文件的标签并打印。
//
// 演示两件事：
//   1. 统一视图 `read_track_info`（推荐用法，自动识别格式）
//   2. 分格式的详细输出（`dump` 子命令式）
//
// 运行：
//   moon run examples/read_tag -- song.mp3
//   moon run examples/read_tag -- song.flac
//   moon run examples/read_tag -- song.m4a

///|
/// 用统一模型打印常用字段。
fn show_unified(data : Bytes) -> Unit {
  let info = @moontag.read_track_info(data.exact_view()) catch {
    e => {
      println("解析失败: \{e.message()}")
      return
    }
  }
  println("== 统一视图 ==")
  println("格式: \{info.format.name()}")
  print_field("标题", info.title)
  print_field("艺术家", info.artist)
  print_field("专辑", info.album)
  print_field("音轨", info.track)
  print_field("日期", info.date)
  print_field("流派", info.genre)
  print_field("备注", info.comment)
  println("封面: \{if info.has_cover { "有" } else { "无" }}")
}

///|
/// 打印一个可选字段。
fn print_field(label : String, value : String?) -> Unit {
  match value {
    Some(v) => println("  \{label}: \{v}")
    None => ()
  }
}

///|
/// 打印 ID3v2 的原始帧。
fn show_id3_detail(data : Bytes) -> Unit {
  let tag = @moontag.parse(data.exact_view()) catch {
    e => {
      println("不是 ID3v2 标签: \{e.message()}")
      return
    }
  }
  println("== ID3v2.\{tag.major}.\{tag.revision} 原始帧 ==")
  for f in tag.frames {
    let text = f.as_text() catch { _ => None }
    match text {
      Some(t) => println("  \{f.id} = \{t}")
      None => println("  \{f.id}（二进制，\{f.data.length()} 字节）")
    }
  }
  let pics = tag.pictures() catch { _ => [] }
  for i, pic in pics {
    println(
      "  封面 #\{i}: \{pic.mime}  \{pic.data.length()} 字节  描述=[\{pic.description}]",
    )
  }
}

///|
/// 打印 FLAC 的 Vorbis Comment。
fn show_flac_detail(data : Bytes) -> Unit {
  let meta = @moontag.parse_meta(data.exact_view()) catch {
    e => {
      println("不是 FLAC: \{e.message()}")
      return
    }
  }
  println("== FLAC 元数据块 ==")
  println("  块数=\{meta.blocks.length()}  音频起点=\{meta.audio_offset}")
  let vc = @moontag.read_vorbis_comment(data.exact_view()) catch {
    e => {
      println("读取 Vorbis Comment 失败: \{e.message()}")
      return
    }
  }
  match vc {
    None => println("  没有 VORBIS_COMMENT 块")
    Some(c) => {
      println("  vendor: \{c.vendor}")
      for e in c.entries {
        println("    \{e}")
      }
    }
  }
}

///|
/// 打印 MP4 的 ilst 条目。
fn show_mp4_detail(data : Bytes) -> Unit {
  let entries = @moontag.read_mp4_tags(data.exact_view()) catch {
    e => {
      println("MP4 解析失败: \{e.message()}")
      return
    }
  }
  println("== MP4 ilst 条目 ==")
  for e in entries {
    if e.key == "covr" {
      println(
        "  covr = <封面 \{e.value.length()} 字节, type=\{e.data_type}>",
      )
    } else {
      println(
        "  \{e.key} = \{@utf8.decode_lossy(e.value.exact_view())}  (type=\{e.data_type})",
      )
    }
  }
}

///|
fn main {
  let args = @env.args()
  let mut base = 1
  if base < args.length() && args[base].has_suffix(".js") {
    base += 1
  }
  if base >= args.length() {
    println("用法: moon run examples/read_tag -- <audio-file>")
    println(
      "  支持 MP3（ID3v2 / APEv2）、FLAC（Vorbis Comment）、M4A（ilst）",
    )
    return
  }
  let path = args[base]
  let data = @fs.read_file_to_bytes(path) catch {
    _ => {
      println("读取失败：\{path}")
      return
    }
  }
  show_unified(data)
  println("")
  match @moontag.detect_format(data.exact_view()) {
    @moontag.AudioFormat::Flac => show_flac_detail(data)
    @moontag.AudioFormat::Mp4 => show_mp4_detail(data)
    _ => show_id3_detail(data)
  }
}
