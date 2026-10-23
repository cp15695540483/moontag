#!/usr/bin/env bash
# tools/make_samples.sh
#
# 重新生成 tools/samples/ 下的测试样本（开发机用，产物提交到仓库）。
# 样本内容与标签是固定的，变更样本需要同时说明理由。
#
# 依赖：ffmpeg（含 libmp3lame、aac、flac 编码器）
# 用法：bash tools/make_samples.sh

set -euo pipefail

FFMPEG="${FFMPEG:-ffmpeg}"
DIR="$(cd "$(dirname "$0")" && pwd)/samples"
mkdir -p "$DIR"

"$FFMPEG" -loglevel error -f lavfi -i "sine=frequency=440:duration=1" \
  -c:a libmp3lame -b:a 64k -id3v2_version 4 \
  -metadata title="SampleTitle" -metadata artist="SampleArtist" -metadata album="SampleAlbum" \
  "$DIR/v24.mp3" -y
"$FFMPEG" -loglevel error -f lavfi -i "sine=frequency=440:duration=1" \
  -c:a libmp3lame -b:a 64k -id3v2_version 3 \
  -metadata title="SampleTitle" \
  "$DIR/v23.mp3" -y
"$FFMPEG" -loglevel error -f lavfi -i "sine=frequency=440:duration=1" \
  -c:a flac -metadata title="SampleTitle" -metadata artist="SampleArtist" \
  "$DIR/base.flac" -y
"$FFMPEG" -loglevel error -f lavfi -i "sine=frequency=440:duration=1" \
  -c:a aac -metadata title="SampleTitle" \
  "$DIR/base.m4a" -y
"$FFMPEG" -loglevel error -f lavfi -i "color=c=red:s=32x32:d=1" -frames:v 1 \
  "$DIR/cover.png" -y

echo "样本已生成到 $DIR"
