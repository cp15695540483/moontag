# Demo 演示

[`docs/demo.mp4`](demo.mp4) 展示 moontag 的完整工作流（终端实录渲染，约 1 分钟）：

1. 读取 MP3 标签（统一视图：标题/艺术家/专辑/封面）
2. 写入 ID3v2 标签（padding 复用，文件长度不变）
3. ffmpeg 独立读回（第三方验证）
4. 嵌入封面并验证 `attached pic`
5. FLAC 标签改写 + metaflac 对拍
6. Ogg Opus 标签改写 + ffmpeg 读回

演示素材生成方式：`ffmpeg` 合成正弦波音频；标签写入由 `moontag` CLI 完成；
每步都有独立工具读回验证（不做自证）。
