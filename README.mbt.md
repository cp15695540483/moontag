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
| MP3 | ID3v2 帧级标志位（压缩/分组/DLI/unsync） | ✅ 按规范处理，压缩帧用 zlib 解压 | ✅ 清压缩位与 unsync 位、补回组号字节、重算 DLI |
| MP3 | APIC 封面 | ✅ MIME/类型/描述/图片数据 | ✅ 嵌入/替换/删除 |
| MP3 | APEv2（尾部） | ✅ 条目 + 二进制标志 | ✅ 改写（不叠加） |
| FLAC | VORBIS_COMMENT | ✅ vendor + 全部条目 | ✅ 改写（含 padding 复用） |
| FLAC | 元数据块链 | ✅ 遍历（含保留类型块）；封面认 PICTURE 块与 `METADATA_BLOCK_PICTURE` | ✅ 原样保留 |
| MP4/M4A | ilst | ✅ 全部条目 + 封面 | ✅ 改写（保留 mdat 与其它盒、**修正 chunk 偏移**） |
| Ogg | Vorbis Comment（Vorbis/Opus） | ✅ vendor + 全部条目 | ✅ 改写（音频页原样保留、PCM 零损失） |
| Ogg | 封面 `METADATA_BLOCK_PICTURE` | ✅ Base64 → FLAC PICTURE 载荷 | ✅ 写入/替换（宽高从 PNG/JPEG 头自动填） |
| FLAC | 封面 PICTURE 块（类型 6） | ✅ 类型/MIME/描述/宽高/图片数据 | 原样保留（不新增块；改写不会丢掉已有块） |

### 统一视图（`read_track_info`）覆盖范围

`read_track_info` 一次调用识别并读取**五种标签场景**：

| 输入 | 识别依据 | 标签来源 |
|---|---|---|
| MP3 | `ID3` 前缀或 MPEG 帧同步 | ID3v2（TIT2/TPE1/…）；**缺失字段回退到文件尾部 APEv2**（Title/Artist/…） |
| FLAC | `fLaC` 魔数 | VORBIS_COMMENT |
| M4A / MP4 | 第 4..8 字节 `ftyp` | `moov/udta/meta/ilst` |
| Ogg Vorbis | `OggS` 页头魔数 | comment packet（`\x03vorbis`） |
| Ogg Opus | `OggS` 页头魔数 | comment packet（`OpusTags`） |

MP3 的字段优先级是 **ID3v2 > APEv2**：只有 APEv2 的文件（ape 生态常见）、
两者并存的文件（转换工具留下的双标签）都能读出内容。封面同时识别
ID3v2 的 APIC 与 APEv2 的 `Cover Art (Front)`。

Ogg 的 comment 接口基于 `Bytes`（页解析需随机访问），统一视图内部会把
`BytesView` 物化一份；需要零拷贝时直接用 `read_ogg_comment`。

### MP4 的媒体定位（改标签为什么必须动样本表偏移）

MP4 把音频数据的**绝对字节偏移**记在 `moov/trak/mdia/minf/stbl` 的
`stco`（32 位）或 `co64`（64 位）里；标签（`udta/meta/ilst`）也在 `moov` 内。
所以标签一变长，`moov` 就变大，其在文件中的后续内容（含 `mdat`）整体后移，
**原有 chunk 偏移全部失效**——播放器会读到错位字节。

本项目的职责划分：

- **不做**：样本表的语义解析与解复用（不重建 `stbl`、不做 demux/mux）；
- **必须做**：当 `moov` 尺寸变化且它位于 `mdat` 之前时，把**全部** `trak` 的
  `stco`/`co64` 内已有偏移按 `delta` 平移（`co64` 的 64 位形式一并处理）。
  这不是可选项，而是"改写文件"的组成部分。

**已验证的硬场景**：faststart 文件（`moov` 在前，其后仅 8 字节 `free`），
写入标题 + 200 字符艺术家使 `moov` 增长 238 字节，预留空间不足 → `mdat` 后移 →
偏移修正后 `ffmpeg` 正常解码，裸 PCM（266240 字节）与改写前逐字节一致；
`tools/e2e.sh` 与单测都覆盖此场景，并有变异测试证明判据有判别力。

**支持的 MP4 布局**：`moov` 前置（faststart）与 `moov` 尾置均可。
`moov` 尾置时 `mdat` 不动，无需修正偏移（这是正确行为而非"勉强成立"）。

**fragmented MP4（`moof` / `moov/mvex`）明确拒绝**：fMP4 的 chunk 位置记在
`moof/traf/trun`（以及 `tfhd` 的 `base_data_offset`），不在 `stco`/`co64` 里。
本实现不维护这些偏移，因此**写入时直接报 `Unsupported`**——静默改写会产出
能通过解析、但音频已损坏的文件（实测 ffmpeg 报
`Error submitting packet to decoder`）。读取（`read_mp4_tags`）仍可用。

### ID3v2 帧头标志位（压缩 / 分组 / 数据长度指示）

帧头的格式标志位全部按规范处理，**没有任何一种合法组合会阻断读取或编辑**：

| 标志 | v2.3 | v2.4 | 本实现 |
|---|---|---|---|
| 压缩 | `$80` + 帧头后 4 字节**普通大端 u32**「解压后尺寸」 | `$08` + 必须同时设 DLI `$01`（4 字节 synchsafe） | 读取时用 zlib（RFC 1950）解压；写回时按未压缩帧写出并清压缩位 |
| 分组 | `$20` + 1 字节组号 | `$40` + 1 字节组号 | 组号字节读时保留（`Frame::group`）、写时原样补回 |
| 未同步 | 作用于整个标签体 | `$02`，作用于帧载荷 | 读取时先还原 unsync **再**解压；写回时清位 |
| 数据长度指示 | — | `$01`，4 字节 synchsafe | 保留该位，值按新的载荷长度重算 |
| 加密 | `$40` | `$04` | **明确报 `Unsupported`**：加密方法不在规范内定义，需外部注册表（见「明确不做」） |

两个版本的附加头字段顺序**恰好相反**，规范要求"按标志位出现的顺序"排列
（id3v2.3.0 §3.3.1、id3v2.4.0-structure §4.1）：v2.3 = `[4 字节尺寸][加密方法][组号]`，
v2.4 = `[组号][加密方法][DLI]`。抄错顺序会把载荷整体错位，因此代码里显式分支，
并有单测 + 变异测试钉住（见表）。

写回策略与 mutagen 一致（本机对 1.48.1 源码核实：只有 `zlib.decompress`，
全文件无 `zlib.compress`）：**读时解压、写回未压缩**。这不会丢内容（载荷逐字节
保留），且避免依赖压缩器实现——压缩流里一个字节的差异都会让部分播放器读不到字段。
TagLib 侧未逐行核验，不在此并列引用。

压缩帧声明的解压后尺寸是**不可信输入**：声明值超过 64 MiB、或实际解压长度与
声明不符、或 v2.4 声明压缩却没有 DLI（规范要求 MUST 设 DLI），都会报结构化的
`BadFrameData` / `BadFrameHeader`。

**输出上限是硬的**：按声明尺寸预置一块固定缓冲交给解码器
（`Decoder::stream_into_buf`，越界即抛 `Overflow`，实测在 `write` 阶段就抛），
因此解压产出的内存上界 = 声明尺寸 ≤ 64 MiB；「声明值撒谎」的文件在**解压过程中**
就被挡住，不会先吃满内存再报错。

**CLI 失败语义**：所有失败分支（读取 / 解析 / 写入 / 保存 / 参数格式 / 未知子命令）
退出码均为非 0——失败只打印、不设退出码，会让脚本与 CI 把「没做成」当成成功。

**写入的失败语义**：文件里**没有** ID3 头时正常新建标签；**有** ID3 头却解析不出来时，
`set_fields` / `set_picture` 一律报错（CLI 退出码 1）。否则会在原文件前面再插一个标签、
原文件（含旧标签）被整体当成音频保留，产出双标签——而调用方看到的是"写入成功"
（修复前实测如此：8764 字节的文件被改成 59669 字节且含两处 `ID3`）。

**明确不做**（及理由）：

- **ID3v2.2 写入**：v2.2 帧头是 3 字符 ID，与 v2.3/v2.4 语义互斥；现实文件
  存量占比低。统一视图遇到 v2.2 标签会**明确报 `UnsupportedVersion`**（CLI 退出码 1），
  而不是伪装成"这个文件没有标签"；本库不维护第二条写入路径；
- **音频解码/编码**：生态已有多个解码器，重复实现是内耗；标签库的职责
  边界是元数据，不是媒体数据；
- **加密帧（ENCR）**：加密方法由规范外的注册表定义（规范原文：
  `See description of the ENCR frame for more information about encryption method
  registration`），没有密钥与算法标识就无法还原，遇到时报 `Unsupported`
  而非静默丢弃——静默会丢数据；
- **流式增量编辑**：标签本身在文件头部（ID3v2）或尾部（APEv2），编辑必须
  一次性读入重写；流式只对音频解码有意义；
- **MP4 的样本表语义层**：不解复用、不重建 `stbl`、不做 mux；但如上一节所述，
  **会读取并修正已有 `stco`/`co64` 偏移**以维持媒体定位；
- **fragmented MP4**：写入时明确报 `Unsupported`（见上一节），读取可用；
- **64 位 `largesize` 盒**：遇到明确报 `Unsupported`；
- **不做 `moov` 后的 padding 复用**：`moov` 之后的 `free` 空间不保证存在
  （faststart 文件常仅 8 字节），本实现选择通用路径——一律按 `delta` 修正偏移，
  而不是"有 padding 才安全"；
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

### 可运行示例（先跑这个）

仓库自带示例工程，不依赖被测库以外的任何东西：

```bash
moon run examples/read_tag -- tools/samples/v24.mp3   # MP3 / ID3v2
moon run examples/read_tag -- tools/samples/base.flac # FLAC
moon run examples/read_tag -- tools/samples/base.m4a  # M4A
```

CI 每次都会跑上面第一条，所以「示例能执行」不是承诺而是每次构建的检查项。

也可以直接用 CLI：

```bash
moon run cmd/tag -- show tools/samples/v24.mp3        # 统一视图
moon run cmd/tag -- dump tools/samples/v24.mp3        # 原始帧
```

下面各小节的代码片段是 **API 示意（`nocheck`，不参与编译）**，可直接运行的完整实现见
`examples/read_tag/main.mbt`。

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

# 封面：MP3 写 ID3v2 APIC，Ogg 写 Vorbis METADATA_BLOCK_PICTURE（按容器自动分派）
moon run cmd/tag -- cover song.mp3 cover.png   # 嵌入（MP3 / Ogg）
moon run cmd/tag -- apic  song.mp3 out.png     # 提取（MP3 / Ogg / FLAC）
moon run cmd/tag -- apics song.mp3             # 列出全部 APIC（MP3）

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

142 个单元测试，`wasm-gc` 与 `js` 双后端全绿：

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
| 压缩帧解压（取消 inflate） | 6 |
| v2.4 附加头顺序（组号在 DLI 之前） | 1 |
| v2.3 解压后尺寸按大端 u32 读（非 synchsafe） | 1 |
| 写回时补回分组字节 | 2 |
| 写回时重算 DLI 值 | 1 |
| 写路径吞掉解析错误（产出双标签） | 1 |

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
| ID3v2 帧级压缩（v2.4） | `ffmpeg 7.1` | 双方都读出被压缩的 artist；改写后 PCM 逐字节相同 |
| ID3v2 帧级压缩（v2.3） | `ffmpeg 7.1` | ffmpeg **静默丢掉**该帧（本库可读）——用于划清能力边界，不是缺陷对照 |
| FLAC 原生 PICTURE 块 | `metaflac 1.5.0` | `--import-picture-from` 造块后本库读出（类型 3 / image/png / 32×32）；改写标签后块仍在 |
| Ogg 封面（`METADATA_BLOCK_PICTURE`） | 本库往返 + `ffmpeg` 音频校验 | 写入后统一视图显示「有」，提取与原 PNG 逐字节相同，音频 PCM 不变 |

压缩帧夹具（`tools/samples/cframe_*.mp3`、`control_*.mp3`）由
`tools/make_cframe_fixtures.py` 按 id3.org 规范手工构造并自校验（帧尺寸编码、
DLI/解压后尺寸与 `zlib.decompress` 的实际长度一致、音频体与基准样本逐字节一致），
来源与期望值记在 `tools/samples/README.md`。

端到端脚本：`bash tools/e2e.sh`（CI 里同样执行；共 45 项断言）。

## 许可证

Apache-2.0。本项目为原创实现，参考 ID3v2.4.0 与 ID3v2.3.0 非正式标准
（id3.org，其版权声明允许衍生）、RFC 9639（FLAC）与 ISO/IEC 14496-12 的公开派生文档
（mp4ra.org）；未移植任何 GPL/LGPL 项目（如 TagLib、mutagen、Exiv2、GPAC）的源码。

第三方依赖（均为纯 MoonBit，无 C 依赖、无 FFI）：

| 依赖 | 许可证 | 用途 |
|---|---|---|
| `moonbitlang/x` | Apache-2.0 | 文件读写（CLI）、编码工具 |
| `Milky2018/moon_yazi` | Apache-2.0 | RFC 1950/1951 zlib/DEFLATE，用于解压 ID3v2 压缩帧（该包自述为 yazi 的移植，仓库 `moonbit-community/moon_yazi`） |
