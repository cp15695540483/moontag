# moontag

纯 MoonBit 实现的**音频标签元数据读写库**：ID3v2（MP3）、Vorbis Comment（FLAC）、
APEv2（MP3 尾部）、MP4 ilst（M4A），不依赖任何 C 库、不调用 FFmpeg，
`wasm-gc` / `js` 后端行为一致。

## 为什么需要它

MoonBit 的音频生态已经解决了"**能不能播**"：`Xcsa-ee/moonflac`、`LL728/moonvorbis`、
`enanandesu/mp3` 等纯 MoonBit 解码器覆盖了主流格式，`Milky2018/moon_rodio`
（数千下载，2026-10-21 检索时为 6648）证明播放场景有真实使用者。但"**这是什么音频**"——标题、艺术家、
专辑、封面——以及把这些信息**写回去**，在生态里是断层的：

- `moonvorbis` 附带一个 Vorbis Comment **只读**解析器，但那只是解码 Ogg 时的
  副产品：只能查、不能写，且只覆盖一种容器；
- `moonflac` 能列出 FLAC 元数据块，同样只读；
- `moon_rodio` 与 `mp3` 解码器没有任何标签 API；
- 生态里没有任何包能读写 **ID3v2**、**APEv2** 或 **MP4 ilst**（2026-10-21
  在 mooncakes.io 检索 `id3`、`apev2`、`ilst` 均为零命中）。

这个断层的代价是：任何"音乐库扫描、转码流水线、播客归档、浏览器端媒体管理"
类应用，要么在 MoonBit 之外挂一个 FFI 或子进程，要么干脆绕开 MoonBit——
而 FFI 方案依赖系统动态库，**覆盖不了 wasm-gc 后端**，恰恰放弃了 MoonBit
在多后端上的主要优势。moontag 补的就是这一层：**解码器解决"能不能播"，
moontag 解决"它是什么、怎么改它"**，两者是互补关系而非竞争关系。

## 安装

```bash
moon add cp15695540483/moontag
```

在 `moon.pkg` 里引入：

```
import {
  "cp15695540483/moontag",
}
```

## 支持范围

| 容器 | 格式 | 读 | 写 |
|---|---|---|---|
| MP3 | ID3v2.3 / ID3v2.4 | ✅ 全部帧遍历 + 文本帧解码 | ✅ 文本帧改写/新增/删除 |
| MP3 | APIC 封面 | ✅ MIME/类型/描述/图片数据 | ✅ 嵌入/替换/删除 |
| MP3 | APEv2（尾部） | ✅ 条目 + 二进制标志 | ✅ 改写（不叠加） |
| FLAC | VORBIS_COMMENT | ✅ vendor + 全部条目 | ✅ 改写（含 padding 复用） |
| FLAC | 元数据块链 | ✅ 遍历（含保留类型块） | ✅ 原样保留 |
| MP4/M4A | ilst | ✅ 全部条目 + 封面 | ✅ 改写（保留 mdat 与其它盒） |
| Ogg | Vorbis Comment（Vorbis/Opus） | ✅ vendor + 全部条目 | ✅ 改写（音频页原样保留、PCM 零损失） |

**明确不做**（及理由）：

- **ID3v2.2 写入**：v2.2 帧头是 3 字符 ID，与 v2.3/v2.4 语义互斥；现实文件
  存量占比低，读取时遇到会跳过并报错，不值得为它维护第二条写入路径；
- **音频解码/编码**：生态已有多个解码器，重复实现是内耗；标签库的职责
  边界是元数据，不是媒体数据；
- **加密帧（ENCR）/ zlib 压缩帧**：依赖外部密钥或解压语义，遇到时明确报
  `Unsupported` 而非静默丢弃——静默会丢数据；
- **流式增量编辑**：标签本身在文件头部（ID3v2）或尾部（APEv2），编辑必须
  一次性读入重写；流式只对音频解码有意义；
- **MP4 sample table**：那是容器解复用层，属于另一个生态位；
- **Ogg 的 PICTURE 块（METADATA_BLOCK_PICTURE）**：FLAC 的 PICTURE 语义
  封装进 Ogg comment 的 base64 条目，属下一增量；
- **Ogg 流的 seek/重新封装**：只重建头两页并保持音频页原样，页内字节
  （含 CRC）不改——这是"无损重写"的边界。

## 实现路径

做音频标签有三条常见路径，本项目的选择及理由：

| 路径 | 做法 | 取舍 |
|---|---|---|
| ① FFI 包装 TagLib 等 C++ 库 | 直接绑定 | ❌ 依赖系统库，wasm-gc 后端不可用；跨语言边界要复制数据结构 |
| ② 移植 GPL/LGPL 参考实现 | 逐行翻译 | ❌ 许可传染（TagLib LGPL/MPL、mutagen GPL）；且 C++ 的 RAII 与异常模型无法直译 |
| ③ **纯 MoonBit 按公开规范原创实现** | 读规范 + 第三方对拍 | ✅ 选此路径。依据是 ID3v2.3/2.4 非正式标准（id3.org，许可允许衍生）、RFC 9639（FLAC）、ISO/IEC 14496-12 公开派生文档（mp4ra.org） |

**写入侧的架构选择**：不"逐字节打补丁"，而是**重建标签、保留音频**——把
原标签解析成结构化帧，改需要的帧，其余帧原样保留，再把音频区原样拼接回来。
配合"padding 预算"（以原标签体/元数据区大小为上限，装得下就原地复用），
常见的小改写在文件层面**长度不变、音频偏移不动**，等价于原位编辑的效果，
但没有"在二进制中间插字节"的复杂边界条件。

**验证哲学**：解析器对自己的正确性没有裁判权。每个格式都配了独立第三方
对拍（ffmpeg / metaflac / flac -t / 独立 Python 解析器），关键判据再做
**变异测试**（植入已知错误、确认测试变红、再恢复）证明判据有判别力，
而不是"测试全绿就完事"。

## 快速开始

### 统一视图（推荐）

一个函数读任意格式，字段已归一：

```moonbit nocheck
///|
fn example(data : Bytes) -> Unit raise TagError {
  let info = read_track_info(data.exact_view())
  println("格式: \{info.format.name()}")
  match info.title {
    Some(t) => println("标题: \{t}")
    None => ()
  }
  println("有封面: \{info.has_cover}")
}
```

### 分格式读写

读 MP3 的 ID3v2 标签：

```moonbit nocheck
///|
fn read_example(data : Bytes) -> Unit raise TagError {
  let tag = parse(data.exact_view())
  println("版本 \{tag.major}, 帧数 \{tag.frames.length()}")
  match tag.text("TIT2") {
    Some(title) => println("标题: \{title}")
    None => ()
  }
  match tag.picture() {
    Some(pic) => println("封面: \{pic.mime}, \{pic.data.length()} 字节")
    None => ()
  }
}
```

写标签（返回完整的新文件字节，音频数据原样保留）：

```moonbit nocheck
///|
fn write_example(data : Bytes) -> Bytes raise TagError {
  set_fields(
    data.exact_view(),
    [field("TIT2", "新标题"), field("TPE1", "新艺术家")],
    WriteOptions::default(),
  )
}
```

FLAC 的 Vorbis Comment：

```moonbit nocheck
///|
fn flac_example(data : Bytes) -> Bytes raise TagError {
  let vc = match read_vorbis_comment(data.exact_view()) {
    Some(c) => c
    None => empty_vorbis_comment("moontag")
  }
  let vc = vc.set_key("TITLE", "新标题").set_key("ALBUM", "新专辑")
  set_vorbis_comment(data.exact_view(), vc)
}
```

MP4 / M4A：

```moonbit nocheck
///|
fn mp4_example(data : Bytes) -> Bytes raise TagError {
  set_mp4_tags(data.exact_view(), [
    mp4_text_tag("©nam", "新标题"),
    mp4_text_tag("©alb", "新专辑"),
  ])
}
```

## 命令行

```bash
# 统一视图（自动识别 MP3 / FLAC / M4A）
moon run cmd/tag -- show song.mp3

# 原始视图（打印全部帧/条目）
moon run cmd/tag -- dump song.m4a

# 改字段（自动按格式分派；空值表示删除）
moon run cmd/tag -- set song.mp3 "TIT2=新标题" "TPE1=艺术家"
moon run cmd/tag -- set song.flac "TITLE=新标题"
moon run cmd/tag -- set song.m4a "©nam=新标题"

# 封面（ID3v2）
moon run cmd/tag -- cover song.mp3 cover.png   # 嵌入
moon run cmd/tag -- apic  song.mp3 out.png     # 提取
moon run cmd/tag -- apics song.mp3             # 列出全部

# 指定格式的子命令
moon run cmd/tag -- flac show song.flac
moon run cmd/tag -- ape  show song.mp3
moon run cmd/tag -- mp4  show song.m4a
```

## 设计要点

**两个版本的语义差异必须分开处理。** ID3v2.3 的帧尺寸是普通大端 u32，
ID3v2.4 是 synchsafe（每字节最高位恒 0）；v2.3 的标签级 unsynchronisation 作用于整个标签体，
v2.4 则按帧作用。混用这两套语义是 ID3 实现最常见的 bug，本库用显式分支隔离。

**写 v2.3 时不能用 UTF-8。** v2.3 规范只定义了 `$00`(ISO-8859-1) 与 `$01`(UTF-16)，
写 `$03` 会让老播放器解出乱码。本库按目标版本自动选择编码：v2.3 → UTF-16，v2.4 → UTF-8。

**padding 必须复用。** 标签编辑器改写后若让标签变长，整段音频数据要后移，
破坏播放器的 seek 位置与增量同步工具的假设。moontag 以原标签体/元数据区为预算：
装得下就原地复用（文件长度不变、音频偏移不动），装不下才扩展。

**MIME 字段恒为 Latin-1。** APIC 帧的 MIME 串不受该帧编码字节影响，
只有"描述"跟随编码——这是 APIC 解析最容易写错的地方。

**同一个库里混用两种字节序。** ID3v2 与 FLAC 块头是大端；FLAC 的 Vorbis Comment
载荷与 APEv2 的全部多字节字段是小端。

**MP4 的 `meta` 是 FullBox。** `moov/udta/meta` 的子盒从 `meta` 载荷的 **+4 字节**开始
（前面是 version+flags）；漏掉这 4 字节会让后面全部错位。
`data` 盒的 type 也不在独立 4 字节里，而是在 **flags 的最低字节**。

**iTunes 键名里的 `©` 是单字节 0xA9。** 不是 UTF-8 的 `C2 A9`，
按 UTF-8 写会让 ffmpeg/iTunes 读不到该条目标签。

## 测试

97 个单元测试，`wasm-gc` 与 `js` 双后端全绿：

```bash
moon test --target wasm-gc
moon test --target js
```

关键判据都做过**变异测试**（植入已知错误确认变红再恢复）：

| 判据 | 变异后变红的用例数 |
|---|---|
| v2.4 帧尺寸 synchsafe 语义 | 1 |
| v2.3 必须用 UTF-16 而非 UTF-8 | 1 |
| APIC 描述终止符随编码变化 | 1 |
| FLAC padding 复用 | 1 |
| APEv2 标签起点（含 footer 32 字节） | 7 |
| MP4 `meta` 的 FullBox +4 偏移 | 7 |
| MP4 `data` 盒 type 在 flags 最低字节 | 3 |

## 第三方对拍

每个格式都用独立工具做过端到端验证，而非只跑自己的单测：

| 功能 | 验证工具 | 结果 |
|---|---|---|
| ID3v2 读写 | `ffmpeg 7.1` | 读回的 title/artist/album 与预期一致 |
| 音频无损 | `ffmpeg -f s16le` | 改写前后裸 PCM 的 SHA-256 完全相同 |
| APIC 提取 | `ffmpeg` 嵌入的封面 | 提取结果与原始 PNG SHA-256 相同 |
| APIC 写入 | `ffmpeg -i` | 识别为 `(attached pic)`，尺寸正确 |
| FLAC 读写 | `metaflac 1.5.0` | `--list` / `--export-tags-to` 逐字段一致 |
| FLAC 完整性 | `flac -t` | `ok` |
| APEv2 双向 | 独立 Python 解析器 | 互读结果一致 |
| MP4 ilst 读写 | `ffmpeg -i` | title/album/date 读回一致，音频时长不变 |

端到端脚本：`bash tools/e2e.sh`（CI 里同样执行）。

## 许可证

Apache-2.0。本项目为原创实现，参考 ID3v2.4.0 与 ID3v2.3.0 非正式标准
（id3.org，其版权声明允许衍生）、RFC 9639（FLAC）与 ISO/IEC 14496-12 的公开派生文档
（mp4ra.org）；未移植任何 GPL/LGPL 项目（如 TagLib、mutagen、Exiv2、GPAC）的源码。
