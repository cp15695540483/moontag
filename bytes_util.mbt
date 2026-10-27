// bytes_util.mbt
//
// 字节读取工具：所有访问都先做边界检查，越界抛 Truncated 而不是 panic。
// ID3 的多字节整数为大端序；v2.4 的尺寸字段是 synchsafe（每字节最高位恒 0），
// v2.3 的帧尺寸则是普通 u32——这是 ID3v2 最常见的实现错误来源。

///|
/// 断言 `[offset, offset + length)` 在数据范围内。
fn require_range(
  data : BytesView,
  offset : Int32,
  length : Int32,
) -> Unit raise TagError {
  if offset < 0 ||
    length < 0 ||
    offset > data.length() ||
    data.length() - offset < length {
    raise Truncated(offset~, need=length, actual=data.length())
  }
}

///|
/// 读 1..4 字节大端序无符号整数。
fn read_be(
  data : BytesView,
  offset : Int32,
  length : Int32,
) -> Int32 raise TagError {
  require_range(data, offset, length)
  let mut v = 0
  for i in 0..<length {
    v = (v << 8) | data.at(offset + i).to_int()
  }
  v
}

///|
/// 读 4 字节大端序无符号整数（普通 u32，用于 ID3v2.3 帧尺寸）。
fn read_u32be(data : BytesView, offset : Int32) -> Int32 raise TagError {
  read_be(data, offset, 4)
}

///|
/// 读 4 字节 synchsafe 整数：每字节只取低 7 位，共 28 位（上限 256MB）。
///
/// 用于 ID3v2.4 的标签尺寸与帧尺寸。
fn read_synchsafe32(data : BytesView, offset : Int32) -> Int32 raise TagError {
  require_range(data, offset, 4)
  let mut v = 0
  for i in 0..<4 {
    let b = data.at(offset + i).to_int()
    // 规范要求最高位为 0；非 0 说明这不是 synchsafe 编码。
    if (b & 0x80) != 0 {
      raise BadHeader(reason="synchsafe 整数字节 \{b} 的最高位不为 0")
    }
    v = (v << 7) | b
  }
  v
}

///|
/// 取 `[start, end)` 的字节拷贝。
fn slice_bytes(
  data : BytesView,
  start : Int32,
  end : Int32,
) -> Bytes raise TagError {
  require_range(data, start, end - start)
  let buf = @buffer.Buffer()
  for i in start..<end {
    buf.write_byte(data.at(i))
  }
  buf.to_bytes()
}

///|
/// 帧 ID 是否合法：4 个字符，取自 `A-Z` 与 `0-9`。
fn is_valid_frame_id(data : BytesView, offset : Int32) -> Bool {
  if offset < 0 || offset > data.length() || data.length() - offset < 4 {
    return false
  }
  for i in 0..<4 {
    let b = data.at(offset + i).to_int()
    let ok = (b >= 0x41 && b <= 0x5A) || (b >= 0x30 && b <= 0x39)
    if !ok {
      return false
    }
  }
  true
}

///|
/// 写 4 字节小端 u32。
///
/// FLAC 的 Vorbis Comment 载荷与 APEv2 的全部多字节字段都是小端，
/// 而 ID3v2 与 FLAC 的块头是大端——同一个库里两种字节序并存。
fn write_le32(buf : @buffer.Buffer, v : Int32) -> Unit {
  buf.write_byte((v & 0xFF).to_byte())
  buf.write_byte(((v >> 8) & 0xFF).to_byte())
  buf.write_byte(((v >> 16) & 0xFF).to_byte())
  buf.write_byte(((v >> 24) & 0xFF).to_byte())
}

///|
/// 读 4 字节小端 u32；同时限制在 2^31 内避免长度字段溢出。
fn read_le32(data : BytesView, offset : Int32) -> Int32 raise TagError {
  require_range(data, offset, 4)
  let b0 = data.at(offset).to_int()
  let b1 = data.at(offset + 1).to_int()
  let b2 = data.at(offset + 2).to_int()
  let b3 = data.at(offset + 3).to_int()
  if b3 >= 0x80 {
    raise BadHeader(reason="小端长度字段超出范围")
  }
  b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
}

///|
/// 读 4 字节小端 u32（**不**做 2^31 限制）。
///
/// 用于 serial number、页序号这类"随机/大值"的 uint32 字段——
/// 它们不是长度，高位为 1 是常态，与 `read_le32` 的语义必须区分开。
fn read_le32_raw(data : BytesView, offset : Int32) -> Int32 raise TagError {
  require_range(data, offset, 4)
  let b0 = data.at(offset).to_int()
  let b1 = data.at(offset + 1).to_int()
  let b2 = data.at(offset + 2).to_int()
  let b3 = data.at(offset + 3).to_int()
  b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
}

///|
/// 写 4 字节大端 u32（MP4 盒尺寸、ID3v2.3 帧尺寸等）。
fn write_u32be(v : Int32) -> Bytes {
  Bytes::from_array([
    ((v >> 24) & 0xFF).to_byte(),
    ((v >> 16) & 0xFF).to_byte(),
    ((v >> 8) & 0xFF).to_byte(),
    (v & 0xFF).to_byte(),
  ])
}

///|
/// 读 4 字节大端 u64（MP4 co64 的 chunk offset）。
fn read_be64(data : BytesView, offset : Int32) -> Int64 raise TagError {
  require_range(data, offset, 8)
  let mut v : Int64 = 0L
  for i in 0..<8 {
    v = (v << 8) | Int64::from_int(data.at(offset + i).to_int())
  }
  v
}

///|
/// 写 4 字节大端 u64。
fn write_be64(v : Int64) -> Bytes {
  let out = @buffer.Buffer()
  for shift in [56, 48, 40, 32, 24, 16, 8, 0] {
    out.write_byte(((v >> shift) & 0xFFL).to_int().to_byte())
  }
  out.to_bytes()
}
