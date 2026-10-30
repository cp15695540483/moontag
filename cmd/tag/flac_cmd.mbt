// cmd/tag/flac_cmd.mbt
//
// FLAC 子命令：show / set。

///|
fn cmd_flac_show(path : String) -> Unit {
  let data = @fs.read_file_to_bytes(path) catch {
    _ => {
      println("读取失败：\{path}")
      @sys.exit(1)
      return
    }
  }
  let meta = @moontag.parse_meta(data.exact_view()) catch {
    e => {
      println("解析失败: \{e.message()}")
      @sys.exit(1)
      return
    }
  }
  println(
    "FLAC  块数=\{meta.blocks.length()}  音频起点=\{meta.audio_offset}",
  )
  for b in meta.blocks {
    println("  块 type=\{b.code} length=\{b.length}")
  }
  let vc = @moontag.read_vorbis_comment(data.exact_view()) catch {
    e => {
      println("读取 Vorbis Comment 失败: \{e.message()}")
      @sys.exit(1)
      return
    }
  }
  match vc {
    None => println("没有 VORBIS_COMMENT 块")
    Some(c) => {
      println("vendor: \{c.vendor}")
      for e in c.entries {
        println("  \{e}")
      }
    }
  }
}

///|
/// 改写 FLAC 的 Vorbis Comment 字段（`KEY=value`，空值表示删除）。
fn cmd_flac_set(path : String, specs : Array[String]) -> Unit {
  let data = @fs.read_file_to_bytes(path) catch {
    _ => {
      println("读取失败：\{path}")
      @sys.exit(1)
      return
    }
  }
  let existing = @moontag.read_vorbis_comment(data.exact_view()) catch {
    e => {
      println("读取失败: \{e.message()}")
      @sys.exit(1)
      return
    }
  }
  let mut vc = match existing {
    Some(c) => c
    None => @moontag.empty_vorbis_comment("moontag")
  }
  for spec in specs {
    match spec.split_once("=") {
      None => {
        println("参数格式错误：\{spec}（应为 KEY=value）")
        @sys.exit(1)
        return
      }
      Some((k, v)) =>
        vc = vc.set_key(k.to_owned(), v.to_owned()) catch {
          e => {
            println("设置失败: \{e.message()}")
            @sys.exit(1)
            return
          }
        }
    }
  }
  let out = @moontag.set_vorbis_comment(data.exact_view(), vc) catch {
    e => {
      println("写入失败: \{e.message()}")
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
    "已写入 \{specs.length()} 个字段到 \{path}（\{data.length()} → \{out.length()} 字节）",
  )
}
