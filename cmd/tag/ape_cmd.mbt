// cmd/tag/ape_cmd.mbt
//
// APEv2 子命令：show / set。

///|
fn cmd_ape_show(path : String) -> Unit {
  let data = @fs.read_file_to_bytes(path) catch {
    _ => {
      println("读取失败：\{path}")
      return
    }
  }
  let tag = @moontag.parse_ape(data.exact_view()) catch {
    e => {
      println("解析失败: \{e.message()}")
      return
    }
  }
  match tag {
    None => println("没有 APEv2 标签")
    Some(t) => {
      println(
        "APEv2  条目数=\{t.items.length()}  标签起点=\{t.offset}  标签长度=\{t.size}",
      )
      for it in t.items {
        if it.is_binary {
          println("  \{it.key} = <二进制 \{it.value.length()} 字节>")
        } else {
          println("  \{it.key} = \{@utf8.decode_lossy(it.value.exact_view())}")
        }
      }
    }
  }
}

///|
/// 改写 APEv2 字段（`KEY=value`，空值表示删除）。
fn cmd_ape_set(path : String, specs : Array[String]) -> Unit {
  let data = @fs.read_file_to_bytes(path) catch {
    _ => {
      println("读取失败：\{path}")
      return
    }
  }
  let existing = @moontag.parse_ape(data.exact_view()) catch {
    e => {
      println("读取失败: \{e.message()}")
      return
    }
  }
  let mut tag = match existing {
    Some(t) => t
    None => @moontag.empty_ape_tag()
  }
  for spec in specs {
    match spec.split_once("=") {
      None => {
        println("参数格式错误：\{spec}（应为 KEY=value）")
        return
      }
      Some((k, v)) =>
        tag = tag.set(k.to_owned(), @utf8.encode(v)) catch {
          e => {
            println("设置失败: \{e.message()}")
            return
          }
        }
    }
  }
  let out = @moontag.set_ape_tag(data.exact_view(), tag) catch {
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
