// cmd/tag/mp4_cmd.mbt
//
// MP4/M4A 的 ilst 子命令。

///|
fn cmd_mp4_show(path : String) -> Unit {
  let data = @fs.read_file_to_bytes(path) catch {
    _ => {
      println("读取失败：\{path}")
      return
    }
  }
  let entries = @moontag.read_mp4_tags(data.exact_view()) catch {
    e => {
      println("解析失败: \{e.message()}")
      return
    }
  }
  println("ilst 条目数=\{entries.length()}")
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
/// 改写 MP4 文本标签（`KEY=value`，空值表示删除）。
fn cmd_mp4_set(path : String, specs : Array[String]) -> Unit {
  let data = @fs.read_file_to_bytes(path) catch {
    _ => {
      println("读取失败：\{path}")
      return
    }
  }
  let updates : Array[@moontag.Mp4Tag] = []
  let to_remove : Array[String] = []
  for spec in specs {
    match spec.split_once("=") {
      None => {
        println("参数格式错误：\{spec}（应为 KEY=value）")
        return
      }
      Some((k, v)) =>
        if v.is_empty() {
          to_remove.push(k.to_owned())
        } else {
          updates.push(@moontag.mp4_text_tag(k.to_owned(), v.to_owned()))
        }
    }
  }
  // 删除通过"不保留该 key"实现：先读出全部，再过滤
  let existing = @moontag.read_mp4_tags(data.exact_view()) catch {
    e => {
      println("读取失败: \{e.message()}")
      return
    }
  }
  let kept : Array[@moontag.Mp4Tag] = []
  for e in existing {
    let mut drop = false
    for d in to_remove {
      if e.key == d {
        drop = true
      }
    }
    for u in updates {
      if e.key == u.key {
        drop = true
      }
    }
    if !drop {
      kept.push(e)
    }
  }
  for u in updates {
    kept.push(u)
  }
  let out = @moontag.set_mp4_tags(data.exact_view(), kept) catch {
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
    "已更新 \{specs.length()} 个字段到 \{path}（\{data.length()} → \{out.length()} 字节）",
  )
}
