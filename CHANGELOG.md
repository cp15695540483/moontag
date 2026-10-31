# 更新日志

版本号以 mooncakes.io 上 `cp15695540483/moontag` 的发布记录为准；日期为发布时间（+08:00）。

## 0.2.1（2026-10-31）

- README 新增「可运行示例」一节，给出 `examples/read_tag` 与 CLI 的可复制命令（此前 README 未指向示例工程）。
- CI 新增「可运行示例」步骤：每次构建实际执行 `examples/read_tag`（MP3 / FLAC / M4A 各一次），
  让「示例可执行」成为构建检查项而不只是文档承诺。
- 补充本更新日志与版本 tag（v0.1.0 / v0.1.1 / v0.2.0）。
- **新增 Ogg 封面**（`METADATA_BLOCK_PICTURE`）：Base64 编解码（RFC 4648）、FLAC PICTURE 载荷
  编解码、宽高从 PNG/JPEG 头自动解析；`cover` / `apic` 子命令按容器自动分派
  （MP3 → ID3v2 APIC，Ogg → Vorbis Comment 的 METADATA_BLOCK_PICTURE）。
- **新增 FLAC 原生 PICTURE 块读取**（块类型 6）：`flac_picture()` 解析类型/MIME/描述/
  宽高/数据；统一视图对 FLAC 同时认原生块与 comment 键；`apic` 可按 FLAC 提取封面。
  实测改写标签后 PICTURE 块原样保留（metaflac 复核）。
- 测试：单测 132 → 142，e2e 37 → 45（新增 Ogg 封面 5 条、FLAC 封面 3 条）。
- CI 新增「测试（警告即失败）」步骤：`moon test --target wasm-gc --deny-warn`。
- **更正 `docs/demo.mp4` 的描述**：该视频由 AI 视频工具生成，是流程示意渲染而非终端录屏。
  `docs/README.md` 与 0.1.1 条目此前写作「终端实录渲染」「完整读写流程实录」，属不实描述，
  已按实际情况改正。真实可复现的证据仍是 `tools/e2e.sh`（CI 每次构建执行，42 项断言）。

## 0.2.0（2026-10-31）

ID3v2 帧级压缩与帧头标志位，这是本次修复的核心增量。

- **压缩帧可读**：v2.3（`$80` + 帧头后 4 字节普通大端「解压后尺寸」）与 v2.4（`$08` + DLI `$01`，
  4 字节 synchsafe）都按规范解压；压缩算法由规范点名 zlib（RFC 1950），依赖纯 MoonBit 的
  `Milky2018/moon_yazi@0.1.3`（Apache-2.0）。
- **不再连坐**：此前任一帧带压缩标志会让整个标签读不出来；现改为逐帧处理，无关帧被压缩不影响其它字段。
- **写回不再静默错位**：补回分组字节（v2.3 `$20` / v2.4 `$40`）、清压缩位与 unsync 位、
  DLI 值按新载荷重算。此前「只跳过不补回」会让载荷整体错位一字节。
- **附加头顺序显式分支**：两版顺序相反（v2.3 `[尺寸][加密][组号]`、v2.4 `[组号][加密][DLI]`）。
- **坏标签不再伪装成功**：文件有 ID3 头但解析失败时，`set_fields` / `set_picture` 报错而不是
  在原文前再插一个标签（此前会产出双标签且报「写入成功」）。
- **CLI 失败退出码非 0**：读取 / 解析 / 写入 / 保存 / 参数格式 / 未知子命令统一为 1。
- **解压上限是硬的**：按声明尺寸预置固定缓冲交给 `Decoder::stream_into_buf`，越界即抛 `Overflow`，
  内存上界 = 声明尺寸 ≤ 64 MiB。
- 测试：单测 112 → 132（新增压缩帧 v2.3/v2.4、分组、DLI、unsync 组合、连坐、上限与负例）；
  e2e 25 → 37 项断言；新增 6 个字节级压缩帧夹具与可复现生成脚本 `tools/make_cframe_fixtures.py`。

## 0.1.1（2026-10-27）

- **MP4 faststart 媒体定位**：`moov` 前置且标签增长导致 `mdat` 后移时，按 `delta` 平移全部
  `trak` 的 `stco`/`co64`；修复前播放器定位错乱（实测 ffmpeg 报
  `Error submitting packet to decoder`）。
- 统一视图覆盖 Ogg Vorbis/Opus 与 APEv2（MP3 缺失字段回退到尾部 APEv2）；fMP4 写入显式报
  `Unsupported`，不静默损坏。
- 添加演示视频 `docs/demo.mp4`（约 1 分钟；**AI 生成的流程示意渲染，非终端录屏**）。

## 0.1.0（2026-10-23）

首次发布。

- ID3v2.3/2.4 读取与写入（文本四种编码、多值、APIC 封面、padding 复用）。
- FLAC Vorbis Comment 读写；APEv2 读写；MP4/M4A ilst 读写（含封面）。
- 统一标签模型 `read_track_info` 与 CLI（`show` / `dump` / `set` / 分格式子命令 / `apic` / `cover`）。
- 可运行示例 `examples/read_tag`、GitHub Actions CI、端到端对拍脚本 `tools/e2e.sh`。
