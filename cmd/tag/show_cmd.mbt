// cmd/tag/show_cmd.mbt
//
// 统一 `show` 子命令：自动识别格式，用统一模型打印常用字段。

///|
/// 打印统一标签视图。
fn cmd_show_unified(path : String) -> Unit {
  let data = @fs.read_file_to_bytes(path) catch {
    _ => {
      println("读取失败：\{path}")
      @sys.exit(1)
      return
    }
  }
  let info = @moontag.read_track_info(data.exact_view()) catch {
    e => {
      println("解析失败: \{e.message()}")
      @sys.exit(1)
      return
    }
  }
  println("格式: \{info.format.name()}  （\{data.length()} 字节）")
  print_opt("标题", info.title)
  print_opt("艺术家", info.artist)
  print_opt("专辑", info.album)
  print_opt("音轨", info.track)
  print_opt("日期", info.date)
  print_opt("流派", info.genre)
  print_opt("备注", info.comment)
  println("封面: \{if info.has_cover { "有" } else { "无" }}")
}

///|
/// 打印一个可选字段。
fn print_opt(label : String, value : String?) -> Unit {
  match value {
    Some(v) => println("  \{label}: \{v}")
    None => ()
  }
}
