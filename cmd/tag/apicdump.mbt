// cmd/tag/apicdump.mbt
//
// 调试/验证用子命令：把 APIC 帧的图片数据原样写到文件，
// 便于与原始 PNG/JPEG 做 SHA-256 比对。
//
// 用法：moon run cmd/tag -- apic <mp3> <out-image>

///|
fn cmd_apic(src : String, dst : String) -> Unit {
  let data = @fs.read_file_to_bytes(src) catch {
    _ => {
      println("读取失败：\{src}")
      return
    }
  }
  let tag = @moontag.parse(data.exact_view()) catch {
    e => {
      println("解析失败: \{e.message()}")
      return
    }
  }
  let pic_opt = tag.picture() catch {
    e => {
      println("图片解析失败: \{e.message()}")
      return
    }
  }
  match pic_opt {
    None => println("没有 APIC 帧")
    Some(pic) => {
      @fs.write_bytes_to_file(dst, pic.data) catch {
        _ => {
          println("写入失败：\{dst}")
          return
        }
      }
      println(
        "MIME=\{pic.mime}  描述=[\{pic.description}]  类型码=0x\{pic.raw_type.to_string(radix=16)}  图片=\{pic.data.length()} 字节 → \{dst}",
      )
    }
  }
}

///|
/// 列出全部 APIC。
fn cmd_apics(src : String) -> Unit {
  let data = @fs.read_file_to_bytes(src) catch {
    _ => {
      println("读取失败：\{src}")
      return
    }
  }
  let tag = @moontag.parse(data.exact_view()) catch {
    e => {
      println("解析失败: \{e.message()}")
      return
    }
  }
  let pics = tag.pictures() catch {
    e => {
      println("图片解析失败: \{e.message()}")
      return
    }
  }
  println("共 \{pics.length()} 张图片")
  for i, pic in pics {
    println(
      "  #\{i} MIME=\{pic.mime} 类型=0x\{pic.raw_type.to_string(radix=16)} 描述=[\{pic.description}] \{pic.data.length()} 字节",
    )
  }
}

///|
/// 把一张图片写进文件的 APIC 帧。
///
/// MIME 由文件扩展名推断（png/jpeg/gif/bmp/webp），其余按 `application/octet-stream`。
fn cmd_cover(src : String, image : String) -> Unit {
  let audio = @fs.read_file_to_bytes(src) catch {
    _ => {
      println("读取失败：\{src}")
      return
    }
  }
  let img = @fs.read_file_to_bytes(image) catch {
    _ => {
      println("读取图片失败：\{image}")
      return
    }
  }
  let mime = guess_mime(image)
  let pic = @moontag.picture(mime, @moontag.FrontCover, "", img)
  let out = @moontag.set_picture(
    audio.exact_view(),
    Some(pic),
    @moontag.WriteOptions::default(),
  ) catch {
    e => {
      println("写入失败: \{e.message()}")
      return
    }
  }
  @fs.write_bytes_to_file(src, out) catch {
    _ => {
      println("保存失败：\{src}")
      return
    }
  }
  println(
    "已嵌入封面 \{image}（\{mime}，\{img.length()} 字节）→ \{src}（\{audio.length()} → \{out.length()} 字节）",
  )
}

///|
/// 按扩展名推断 MIME。
fn guess_mime(path : String) -> String {
  let lower = path.to_lower()
  if lower.has_suffix(".png") {
    "image/png"
  } else if lower.has_suffix(".jpg") || lower.has_suffix(".jpeg") {
    "image/jpeg"
  } else if lower.has_suffix(".gif") {
    "image/gif"
  } else if lower.has_suffix(".bmp") {
    "image/bmp"
  } else if lower.has_suffix(".webp") {
    "image/webp"
  } else {
    "application/octet-stream"
  }
}
