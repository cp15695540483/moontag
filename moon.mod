name = "cp15695540483/moontag"

version = "0.2.0"

readme = "README.mbt.md"

repository = "https://github.com/cp15695540483/moontag"

license = "Apache-2.0"

keywords = [
  "id3",
  "id3v2",
  "metadata",
  "tag",
  "audio",
  "mp3",
  "vorbis",
  "apev2",
]

description = "纯 MoonBit 实现的音频标签元数据读写库（ID3v2 / Vorbis Comment / APEv2 / MP4 ilst），不依赖任何 C 库"

preferred_target = "wasm-gc"

import {
  "moonbitlang/x@0.5.5",
  "Milky2018/moon_yazi@0.1.3",
}
