// cmd/tag/ogg_cmd.mbt
//
// Ogg 子命令：show / set。

///|
fn cmd_ogg_show(path : String) -> Unit {
  let data = @fs.read_file_to_bytes(path) catch {
    _ => {
      println("读取失败：\{path}")
      return
    }
  }
  let loc = @moontag.read_ogg_comment(data)
  match loc {
    None => println("没有 Vorbis Comment packet")
    Some(l) => {
      let vc = @moontag.parse_ogg_comment_payload(l) catch {
        e => {
          println("comment 解析失败: \{e.message()}")
          return
        }
      }
      println(
        "Ogg \{if l.is_opus { "Opus" } else { "Vorbis" }}  vendor: \{vc.vendor}  条目 \{vc.entries.length()} 个",
      )
      for e in vc.entries {
        println("  \{e}")
      }
    }
  }
}

///|
/// 改写 Ogg 的 Vorbis Comment 字段。
fn cmd_ogg_set(path : String, specs : Array[String]) -> Unit {
  let data = @fs.read_file_to_bytes(path) catch {
    _ => {
      println("读取失败：\{path}")
      return
    }
  }
  let existing = @moontag.read_ogg_comment(data)
  let mut vc = match existing {
    None => @moontag.empty_vorbis_comment("moontag")
    Some(l) =>
      @moontag.parse_ogg_comment_payload(l) catch {
        e => {
          println("读取失败: \{e.message()}")
          return
        }
      }
  }
  for spec in specs {
    match spec.split_once("=") {
      None => {
        println("参数格式错误：\{spec}（应为 KEY=value）")
        return
      }
      Some((k, v)) =>
        vc = vc.set_key(k.to_owned(), v.to_owned()) catch {
          e => {
            println("设置失败: \{e.message()}")
            return
          }
        }
    }
  }
  let out = @moontag.set_ogg_comment(data, vc) catch {
    e => {
      println("写入失败: \{e.message()}")
      return
    }
  }
  @fs.write_bytes_to_file(path, out) catch {
    _ => {
      println("保存失败：\{path}")
      return
    }
  }
  println(
    "已写入 \{specs.length()} 个字段到 \{path}（\{data.length()} → \{out.length()} 字节）",
  )
}
