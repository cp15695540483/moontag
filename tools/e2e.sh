#!/usr/bin/env bash
# tools/e2e.sh
#
# 端到端验证：用系统 ffmpeg / flac 生成真实样本，验证 moontag 的读写，
# 再用第三方工具读回对拍。CI 与本地都能跑。
#
# 依赖：ffmpeg、flac（含 metaflac）、moon
# 用法：bash tools/e2e.sh        （在项目根目录执行）

set -uo pipefail

fail=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# 允许用环境变量覆盖，便于在非标准 PATH 的环境里跑
FFMPEG="${FFMPEG:-ffmpeg}"
FLAC="${FLAC:-flac}"
METAFLAC="${METAFLAC:-metaflac}"
MOON="${MOON:-moon}"

pass() { printf '  PASS %s\n' "$1"; }
bad() {
  printf '  FAIL %s\n' "$1"
  fail=1
}

echo "== 生成测试样本 =="
"$FFMPEG" -loglevel error -f lavfi -i "sine=frequency=440:duration=1" \
  -c:a libmp3lame -b:a 128k -id3v2_version 4 \
  -metadata title="原题" -metadata artist="原艺术家" \
  "$tmp/v24.mp3" -y || { echo "生成 mp3 失败"; exit 1; }
"$FFMPEG" -loglevel error -f lavfi -i "sine=frequency=440:duration=1" \
  -c:a libmp3lame -b:a 128k -id3v2_version 3 \
  -metadata title="原题" \
  "$tmp/v23.mp3" -y || { echo "生成 mp3 失败"; exit 1; }
"$FFMPEG" -loglevel error -f lavfi -i "color=c=red:s=32x32:d=1" -frames:v 1 \
  "$tmp/cover.png" -y
"$FFMPEG" -loglevel error -f lavfi -i "sine=frequency=440:duration=1" \
  -c:a flac -metadata title="FLAC 原题" "$tmp/base.flac" -y || { echo "生成 flac 失败"; exit 1; }
echo "  样本就绪"

echo "== MP3 / ID3v2 写入 =="
cp "$tmp/v24.mp3" "$tmp/t24.mp3"
"$MOON" run cmd/tag --target wasm-gc -- set "$tmp/t24.mp3" "TIT2=新标题" "TPE1=新艺术家" \
  >/dev/null 2>&1
tag_out=$("$FFMPEG" -i "$tmp/t24.mp3" -f null - 2>&1)
echo "$tag_out" | grep -q "title.*新标题" && pass "ffmpeg 读回 title" || bad "ffmpeg 读不到 title"
echo "$tag_out" | grep -q "artist.*新艺术家" && pass "ffmpeg 读回 artist" || bad "ffmpeg 读不到 artist"

echo "== MP3 音频零损失 =="
"$FFMPEG" -loglevel error -i "$tmp/v24.mp3" -f s16le -ac 1 -ar 44100 "$tmp/a.pcm" -y
"$FFMPEG" -loglevel error -i "$tmp/t24.mp3" -f s16le -ac 1 -ar 44100 "$tmp/b.pcm" -y
if cmp -s "$tmp/a.pcm" "$tmp/b.pcm"; then
  pass "改写前后 PCM 逐字节相同"
else
  bad "音频数据被改动"
fi

echo "== APIC 封面写入与提取 =="
cp "$tmp/v24.mp3" "$tmp/cover.mp3"
"$MOON" run cmd/tag --target wasm-gc -- cover "$tmp/cover.mp3" "$tmp/cover.png" >/dev/null 2>&1
if "$FFMPEG" -i "$tmp/cover.mp3" -f null - 2>&1 | grep -q "attached pic"; then
  pass "ffmpeg 识别为 attached pic"
else
  bad "ffmpeg 未识别封面"
fi
"$MOON" run cmd/tag --target wasm-gc -- apic "$tmp/cover.mp3" "$tmp/extracted.png" >/dev/null 2>&1
if cmp -s "$tmp/cover.png" "$tmp/extracted.png"; then
  pass "提取的封面与原始 PNG 逐字节相同"
else
  bad "封面提取不一致"
fi

echo "== FLAC / Vorbis Comment =="
cp "$tmp/base.flac" "$tmp/w.flac"
"$MOON" run cmd/tag --target wasm-gc -- set "$tmp/w.flac" "TITLE=改过的标题" "ALBUM=新专辑" \
  >/dev/null 2>&1
tags=$("$METAFLAC" --export-tags-to=- "$tmp/w.flac" 2>/dev/null)
echo "$tags" | grep -q "TITLE=改过的标题" && pass "metaflac 读回 TITLE" || bad "metaflac 读不到 TITLE"
echo "$tags" | grep -q "ALBUM=新专辑" && pass "metaflac 读回 ALBUM" || bad "metaflac 读不到 ALBUM"
if "$FLAC" -t "$tmp/w.flac" >/dev/null 2>&1; then
  pass "flac -t 完整性校验通过"
else
  bad "flac -t 失败（音频被破坏）"
fi

echo "== MP4 / M4A ilst =="
"$FFMPEG" -loglevel error -f lavfi -i "sine=frequency=440:duration=1" \
  -c:a aac -metadata title="M4A 原题" "$tmp/base.m4a" -y || { echo "生成 m4a 失败"; exit 1; }
cp "$tmp/base.m4a" "$tmp/w.m4a"
"$MOON" run cmd/tag --target wasm-gc -- mp4 set "$tmp/w.m4a" "©nam=新标题" "©alb=新专辑" \
  >/dev/null 2>&1
m4a_out=$("$FFMPEG" -i "$tmp/w.m4a" -f null - 2>&1)
echo "$m4a_out" | grep -q "title.*新标题" && pass "ffmpeg 读回 M4A title" || bad "ffmpeg 读不到 M4A title"
echo "$m4a_out" | grep -q "album.*新专辑" && pass "ffmpeg 读回 M4A album" || bad "ffmpeg 读不到 M4A album"

echo "== APEv2 读写（moontag 自读回） =="
cp "$tmp/v24.mp3" "$tmp/ape.mp3"
"$MOON" run cmd/tag --target wasm-gc -- ape set "$tmp/ape.mp3" "Title=APE 标题" "Artist=APE 艺术家" \
  >/dev/null 2>&1
ape_out=$("$MOON" run cmd/tag --target wasm-gc -- ape show "$tmp/ape.mp3" 2>&1)
echo "$ape_out" | grep -q "APE 标题" && pass "APEv2 读回 Title" || bad "APEv2 读不到 Title"
echo "$ape_out" | grep -q "APE 艺术家" && pass "APEv2 读回 Artist" || bad "APEv2 读不到 Artist"
# 音频必须仍然完整
"$FFMPEG" -loglevel error -i "$tmp/ape.mp3" -f s16le -ac 1 -ar 44100 "$tmp/c.pcm" -y
if cmp -s "$tmp/a.pcm" "$tmp/c.pcm"; then
  pass "APEv2 写入后音频仍逐字节相同"
else
  bad "APEv2 写入破坏了音频"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "端到端验证全部通过"
else
  echo "存在失败项"
fi
exit "$fail"
