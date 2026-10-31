// base64.mbt
//
// 标准 Base64（RFC 4648 §4，含 `=` 填充）。
//
// 用途单一但不可省：Ogg（Vorbis / Opus）的封面存在 Vorbis Comment 的
// `METADATA_BLOCK_PICTURE` 条目里，值是 FLAC PICTURE 块的**Base64 文本**，
// 不是二进制帧。没有这套编解码，Ogg 封面既读不出也写不进。

///|
/// Base64 字母表（RFC 4648 §4 标准表；不是 URL-safe 变体）。
const BASE64_ALPHABET : String = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

///|
/// 字母表的字节形式。表是纯 ASCII，因此字节值即字符。
fn base64_alphabet() -> Bytes {
  @utf8.encode(BASE64_ALPHABET)
}

///|
/// Base64 编码。空输入返回空串。
pub fn base64_encode(data : BytesView) -> String {
  let table = base64_alphabet()
  let n = data.length()
  let buf = @buffer.Buffer()
  let mut i = 0
  while i + 2 < n {
    let a = data.at(i).to_int()
    let b = data.at(i + 1).to_int()
    let c = data.at(i + 2).to_int()
    buf.write_byte(table.at(a >> 2))
    buf.write_byte(table.at(((a & 0x03) << 4) | (b >> 4)))
    buf.write_byte(table.at(((b & 0x0F) << 2) | (c >> 6)))
    buf.write_byte(table.at(c & 0x3F))
    i = i + 3
  }
  let rest = n - i
  if rest == 1 {
    let a = data.at(i).to_int()
    buf.write_byte(table.at(a >> 2))
    buf.write_byte(table.at((a & 0x03) << 4))
    buf.write_byte(b'=')
    buf.write_byte(b'=')
  } else if rest == 2 {
    let a = data.at(i).to_int()
    let b = data.at(i + 1).to_int()
    buf.write_byte(table.at(a >> 2))
    buf.write_byte(table.at(((a & 0x03) << 4) | (b >> 4)))
    buf.write_byte(table.at((b & 0x0F) << 2))
    buf.write_byte(b'=')
  }
  // 注意：这里不能对字节缓冲用 `to_string()`（它按 UTF-16 解释内容），
  // 必须按 UTF-8 解码——字母表是纯 ASCII，解码无损。
  @utf8.decode_lossy(buf.to_bytes().exact_view())
}

///|
/// 反向查表：ASCII 字节 → 6 位值，非法字符为 -1。
///
/// 用 256 项定长表而不是每次扫字母表：封面动辄几十 KB，
/// 逐字符 O(64) 扫描会在真实文件上变成明显的热点。
fn base64_reverse_table() -> FixedArray[Int32] {
  let table = FixedArray::make(256, -1)
  let alpha = base64_alphabet()
  for i in 0..<64 {
    table[alpha.at(i).to_int()] = i
  }
  table
}

///|
/// Base64 解码。
///
/// 忽略空白（空格 / `\t` / `\r` / `\n`）与尾部 `=` 填充——Vorbis Comment
/// 里的这个值经常被编辑器或工具折行，按"非法字符"报错会把能读的文件读死。
pub fn base64_decode(text : String) -> Bytes raise TagError {
  let src = @utf8.encode(text)
  let rev = base64_reverse_table()
  let vals : Array[Int32] = []
  let mut saw_pad = false
  for i in 0..<src.length() {
    let c = src.at(i).to_int()
    if c == 0x20 || c == 0x09 || c == 0x0D || c == 0x0A {
      continue
    }
    if c == 0x3D {
      // '='：填充开始，之后除空白外不允许再有数据
      saw_pad = true
      continue
    }
    if saw_pad {
      raise BadFrameData(
        frame_id="BASE64",
        reason="填充符 '=' 之后仍有有效字符",
      )
    }
    let v = rev[c]
    if v < 0 {
      raise BadFrameData(
        frame_id="BASE64",
        reason="非法的 Base64 字节 0x\{c.to_string(radix=16)}",
      )
    }
    vals.push(v)
  }
  let n = vals.length()
  // 合法长度对 4 取余只能是 0/2/3；余 1 说明数据被截断。
  if n % 4 == 1 {
    raise BadFrameData(
      frame_id="BASE64",
      reason="有效字符数 \{n} 对 4 取余为 1，数据被截断",
    )
  }
  let buf = @buffer.Buffer()
  let mut i = 0
  while i + 3 < n {
    let a = vals[i]
    let b = vals[i + 1]
    let c = vals[i + 2]
    let d = vals[i + 3]
    buf.write_byte(((a << 2) | (b >> 4)).to_byte())
    buf.write_byte((((b & 0x0F) << 4) | (c >> 2)).to_byte())
    buf.write_byte((((c & 0x03) << 6) | d).to_byte())
    i = i + 4
  }
  let rest = n - i
  if rest == 2 {
    let a = vals[i]
    let b = vals[i + 1]
    buf.write_byte(((a << 2) | (b >> 4)).to_byte())
  } else if rest == 3 {
    let a = vals[i]
    let b = vals[i + 1]
    let c = vals[i + 2]
    buf.write_byte(((a << 2) | (b >> 4)).to_byte())
    buf.write_byte((((b & 0x0F) << 4) | (c >> 2)).to_byte())
  }
  buf.to_bytes()
}
