// cmd/tag/main.mbt
//
// 命令行入口。用法：
//   moon run cmd/tag -- show <file>
//   moon run cmd/tag -- set  <file> <FRAME_ID>=<value> [<FRAME_ID>=<value> ...]

///|
fn cmd_show(data : Bytes) -> Unit {
  try {
    let tag = @moontag.parse(data.exact_view())
    println(
      "ID3v2.\{tag.major}.\{tag.revision}  frames=\{tag.frames.length()}  tag_bytes=\{tag.total_size}",
    )
    for f in tag.frames {
      let text = f.as_text() catch { _ => None }
      match text {
        Some(t) => println("  \{f.id} = \{t}")
        None => println("  \{f.id} (binary, \{f.data.length()} bytes)")
      }
    }
  } catch {
    e => {
      println("解析失败: \{e.message()}")
      @sys.exit(1)
    }
  }
}

///|
/// 把 `ID=value` 形式的参数解析成字段；格式错误返回 None。
fn parse_field(spec : String) -> @moontag.TagField? {
  match spec.split_once("=") {
    None => None
    Some((id, value)) => Some(@moontag.field(id.to_owned(), value.to_owned()))
  }
}

///|
/// 写字段：把结果覆盖回原文件。
fn cmd_set(path : String, specs : Array[String]) -> Unit {
  let fields : Array[@moontag.TagField] = []
  for s in specs {
    match parse_field(s) {
      Some(f) => fields.push(f)
      None => {
        println("参数格式错误：\{s}（应为 ID=value）")
        @sys.exit(1)
        return
      }
    }
  }
  let data = @fs.read_file_to_bytes(path) catch {
    _ => {
      println("读取失败：\{path}")
      @sys.exit(1)
      return
    }
  }
  let out = @moontag.set_fields(
    data.exact_view(),
    fields,
    @moontag.WriteOptions::default(),
  ) catch {
    err => {
      println("写入失败: \{err.message()}")
      @sys.exit(1)
      return
    }
  }
  @fs.write_bytes_to_file(path, out) catch {
    _ => {
      println("保存失败：\{path}")
      @sys.exit(1)
      return
    }
  }
  println(
    "已写入 \{fields.length()} 个字段到 \{path}（\{data.length()} → \{out.length()} 字节）",
  )
}

///|
fn main {
  let args = @env.args()
  let mut base = 1
  if base < args.length() && args[base].has_suffix(".js") {
    base += 1
  }
  if base + 1 >= args.length() {
    println("用法:")
    println(
      "  moon run cmd/tag -- show  <file>                统一视图（自动识别格式）",
    )
    println("  moon run cmd/tag -- dump  <file>                原始视图")
    println(
      "  moon run cmd/tag -- set   <file> ID=value ...   写入（自动识别格式）",
    )
    println("  moon run cmd/tag -- flac|ape|ogg|mp4 show <file>")
    println("  moon run cmd/tag -- flac|ape|ogg|mp4 set  <file> KEY=value ...")
    println("  moon run cmd/tag -- apic  <file> <out-image>    提取封面")
    println("  moon run cmd/tag -- apics <file>                列出封面")
    println("  moon run cmd/tag -- cover <file> <image>        嵌入封面")
    @sys.exit(1)
    return
  }
  let sub = args[base]
  // ape / flac / mp4 / ogg 的语法是 `<子命令> <show|set> <文件> ...`：
  // 动作在文件之前，与其它子命令的 `<sub> <file> ...` 不同，单独解析。
  if sub == "ape" || sub == "flac" || sub == "mp4" || sub == "ogg" {
    if base + 2 >= args.length() {
      println("用法: moon run cmd/tag -- \{sub} show <file>")
      println("      moon run cmd/tag -- \{sub} set  <file> KEY=value ...")
      @sys.exit(1)
      return
    }
    let action = args[base + 1]
    let target = args[base + 2]
    let specs : Array[String] = []
    let mut j = base + 3
    while j < args.length() {
      specs.push(args[j])
      j += 1
    }
    match sub {
      "ape" =>
        match action {
          "show" => cmd_ape_show(target)
          "set" => cmd_ape_set(target, specs)
          _ =>
            println("未知 ape 子命令：\{action}（支持 show / set）")
        }
      "flac" =>
        match action {
          "show" => cmd_flac_show(target)
          "set" => cmd_flac_set(target, specs)
          _ =>
            println("未知 flac 子命令：\{action}（支持 show / set）")
        }
      "ogg" =>
        match action {
          "show" => cmd_ogg_show(target)
          "set" => cmd_ogg_set(target, specs)
          _ =>
            println("未知 ogg 子命令：\{action}（支持 show / set）")
        }
      _ =>
        match action {
          "show" => cmd_mp4_show(target)
          "set" => cmd_mp4_set(target, specs)
          _ =>
            println("未知 mp4 子命令：\{action}（支持 show / set）")
        }
    }
    return
  }
  let path = args[base + 1]
  let rest : Array[String] = []
  let mut i = base + 2
  while i < args.length() {
    rest.push(args[i])
    i += 1
  }
  match sub {
    // 统一视图：自动识别格式并打印常用字段
    "show" => cmd_show_unified(path)
    // 原始视图：按格式打印全部帧/条目
    "dump" => {
      let data = @fs.read_file_to_bytes(path) catch {
        _ => {
          println("读取失败：\{path}")
          @sys.exit(1)
          return
        }
      }
      match @moontag.detect_format(data.exact_view()) {
        @moontag.AudioFormat::Flac => cmd_flac_show(path)
        @moontag.AudioFormat::Mp4 => cmd_mp4_show(path)
        _ => cmd_show(data)
      }
    }
    "set" => {
      let data = @fs.read_file_to_bytes(path) catch {
        _ => {
          println("读取失败：\{path}")
          @sys.exit(1)
          return
        }
      }
      match @moontag.detect_format(data.exact_view()) {
        @moontag.AudioFormat::Flac => cmd_flac_set(path, rest)
        @moontag.AudioFormat::Mp4 => cmd_mp4_set(path, rest)
        _ => cmd_set(path, rest)
      }
    }
    "apic" =>
      if rest.length() < 1 {
        println("用法: moon run cmd/tag -- apic <mp3> <out-image>")
      } else {
        cmd_apic(path, rest[0])
      }
    "apics" => cmd_apics(path)
    "cover" =>
      if rest.length() < 1 {
        println("用法: moon run cmd/tag -- cover <mp3> <image>")
      } else {
        cmd_cover(path, rest[0])
      }
    _ =>
      println(
        "未知子命令：\{sub}（支持 show / dump / set / flac / ape / mp4 / ogg / apic / apics / cover）",
      )
  }
}
