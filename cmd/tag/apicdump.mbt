// cmd/tag/apicdump.mbt
//
// 封面相关的调试/验证用子命令：把图片数据原样写到文件，
// 便于与原始 PNG/JPEG 做 SHA-256 比对。
//
// 两种容器的封面机制不同，这里按魔数分派：
//   MP3 → ID3v2 的 APIC 帧（二进制帧）
//   Ogg → Vorbis Comment 的 METADATA_BLOCK_PICTURE（Base64 文本）
//
// 用法：moon run cmd/tag -- apic <mp3|ogg> <out-image>

///|
fn cmd_apic(src : String, dst : String) -> Unit {
  let data = @fs.read_file_to_bytes(src) catch {
    _ => {
      println("读取失败：\{src}")
      @sys.exit(1)
      return
    }
  }
  let format = @moontag.detect_format(data.exact_view())
  let pic_opt : @moontag.Picture? = match format {
    @moontag.Mp3 => mp3_picture(data)
    @moontag.Ogg => ogg_picture(data)
    _ => None
  }
  match pic_opt {
    None => {
      println("没有封面（\{format.name()}）")
      @sys.exit(1)
      return
    }
    Some(pic) => {
      @fs.write_bytes_to_file(dst, pic.data) catch {
        _ => {
          println("写入失败：\{dst}")
          @sys.exit(1)
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
      @sys.exit(1)
      return
    }
  }
  let tag = @moontag.parse(data.exact_view()) catch {
    e => {
      println("解析失败: \{e.message()}")
      @sys.exit(1)
      return
    }
  }
  let pics = tag.pictures() catch {
    e => {
      println("图片解析失败: \{e.message()}")
      @sys.exit(1)
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
/// 给 Ogg（Vorbis / Opus）写入封面：改 comment → 重建头部页。
///
/// 解析失败返回 `None`，由调用方统一报错——CLI 层不需要区分"不是 Ogg"与
/// "结构坏了"，库层（`set_vorbis_picture` / `set_ogg_comment`）保留细分错误。
fn ogg_set_cover(data : Bytes, pic : @moontag.Picture) -> Bytes? {
  let loc = match @moontag.read_ogg_comment(data) {
    Some(l) => l
    None => return None
  }
  let vc = @moontag.parse_ogg_comment_payload(loc) catch { _ => return None }
  let vc2 = @moontag.set_vorbis_picture(vc, Some(pic)) catch {
    _ => return None
  }
  Some(@moontag.set_ogg_comment(data, vc2)) catch {
    _ => None
  }
}

///|
/// 从 Ogg 的 `METADATA_BLOCK_PICTURE` 取封面。
fn ogg_picture(data : Bytes) -> @moontag.Picture? {
  let loc = match @moontag.read_ogg_comment(data) {
    Some(l) => l
    None => return None
  }
  let vc = @moontag.parse_ogg_comment_payload(loc) catch { _ => return None }
  @moontag.vorbis_picture(vc)
}

///|
/// 从 ID3v2 的 APIC 帧取封面。
fn mp3_picture(data : Bytes) -> @moontag.Picture? {
  let tag = @moontag.parse(data.exact_view()) catch { _ => return None }
  tag.picture() catch {
    _ => None
  }
}

///|
/// 把一张图片写进文件：MP3 走 ID3v2 的 APIC，Ogg 走 Vorbis Comment 的
/// `METADATA_BLOCK_PICTURE`（Base64 的 FLAC PICTURE 载荷）。
///
/// 两种容器的封面机制完全不同——APIC 是二进制帧，METADATA_BLOCK_PICTURE
/// 是文本注释——所以这里按魔数分派，而不是让调用方自己判断。
fn cmd_cover(src : String, image : String) -> Unit {
  let audio = @fs.read_file_to_bytes(src) catch {
    _ => {
      println("读取失败：\{src}")
      @sys.exit(1)
      return
    }
  }
  let img = @fs.read_file_to_bytes(image) catch {
    _ => {
      println("读取图片失败：\{image}")
      @sys.exit(1)
      return
    }
  }
  let mime = guess_mime(image)
  let pic = @moontag.picture(mime, @moontag.FrontCover, "", img)
  let format = @moontag.detect_format(audio.exact_view())
  let stored_as = match format {
    @moontag.Mp3 => "ID3v2 APIC"
    @moontag.Ogg => "Vorbis METADATA_BLOCK_PICTURE"
    _ => {
      println("封面写入支持 MP3 / Ogg，\{format.name()} 暂不支持")
      @sys.exit(1)
      return
    }
  }
  let out : Bytes? = match format {
    @moontag.Mp3 =>
      Some(
        @moontag.set_picture(
          audio.exact_view(),
          Some(pic),
          @moontag.WriteOptions::default(),
        ),
      ) catch {
        _ => None
      }
    @moontag.Ogg => ogg_set_cover(audio, pic)
    _ => None
  }
  let bytes = match out {
    Some(b) => b
    None => {
      println(
        "写入失败：\{format.name()} 文件无法解析或不支持该操作",
      )
      @sys.exit(1)
      return
    }
  }
  @fs.write_bytes_to_file(src, bytes) catch {
    _ => {
      println("保存失败：\{src}")
      @sys.exit(1)
      return
    }
  }
  println(
    "已嵌入封面 \{image}（\{mime}，\{img.length()} 字节，\{stored_as}）→ \{src}（\{audio.length()} → \{bytes.length()} 字节）",
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
