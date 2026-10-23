#!/usr/bin/env bash
# tools/e2e.sh
#
# 端到端验证：对 tools/samples/ 下**已提交的**真实音频文件做读写，
# 再用第三方工具（ffmpeg / flac / metaflac）读回对拍。
#
# 样本不在此脚本内现场生成，原因：CI 的 ffmpeg 可能不带 libmp3lame 编码器，
# 现场生成会在"还没测到被测代码"时就失败。样本由 tools/make_samples.sh
# 在开发机生成后提交，来源可追溯。
#
# 依赖（PATH 或环境变量）：moon、ffmpeg、flac、metaflac
#   FFMPEG / FLAC / METAFLAC / MOON 环境变量可覆盖路径（Windows 开发机用）
# 用法：bash tools/e2e.sh        （在项目根目录执行）

set -uo pipefail

fail=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

FFMPEG="${FFMPEG:-ffmpeg}"
FLAC="${FLAC:-flac}"
METAFLAC="${METAFLAC:-metaflac}"
MOON="${MOON:-moon}"
SAMPLES="tools/samples"

pass() { printf '  PASS %s\n' "$1"; }
bad() {
  printf '  FAIL %s\n' "$1"
  fail=1
}

# 样本必须在仓库里
for s in v24.mp3 v23.mp3 base.flac base.m4a cover.png; do
  if [ ! -f "$SAMPLES/$s" ]; then
    echo "缺少测试样本 $SAMPLES/$s（用 tools/make_samples.sh 生成）"
    exit 1
  fi
done

echo "== MP3 / ID3v2 写入 =="
cp "$SAMPLES/v24.mp3" "$tmp/t24.mp3"
"$MOON" run cmd/tag --target wasm-gc -- set "$tmp/t24.mp3" "TIT2=新标题" "TPE1=新艺术家" \
  >/dev/null 2>&1
tag_out=$("$FFMPEG" -i "$tmp/t24.mp3" -f null - 2>&1)
echo "$tag_out" | grep -q "title.*新标题" && pass "ffmpeg 读回 title" || bad "ffmpeg 读不到 title"
echo "$tag_out" | grep -q "artist.*新艺术家" && pass "ffmpeg 读回 artist" || bad "ffmpeg 读不到 artist"

echo "== MP3 音频零损失 =="
"$FFMPEG" -loglevel error -i "$SAMPLES/v24.mp3" -f s16le -ac 1 -ar 44100 "$tmp/a.pcm" -y
"$FFMPEG" -loglevel error -i "$tmp/t24.mp3" -f s16le -ac 1 -ar 44100 "$tmp/b.pcm" -y
if cmp -s "$tmp/a.pcm" "$tmp/b.pcm"; then
  pass "改写前后 PCM 逐字节相同"
else
  bad "音频数据被改动"
fi

echo "== APIC 封面写入与提取 =="
cp "$SAMPLES/v24.mp3" "$tmp/cover.mp3"
"$MOON" run cmd/tag --target wasm-gc -- cover "$tmp/cover.mp3" "$SAMPLES/cover.png" >/dev/null 2>&1
if "$FFMPEG" -i "$tmp/cover.mp3" -f null - 2>&1 | grep -q "attached pic"; then
  pass "ffmpeg 识别为 attached pic"
else
  bad "ffmpeg 未识别封面"
fi
"$MOON" run cmd/tag --target wasm-gc -- apic "$tmp/cover.mp3" "$tmp/extracted.png" >/dev/null 2>&1
if cmp -s "$SAMPLES/cover.png" "$tmp/extracted.png"; then
  pass "提取的封面与原始 PNG 逐字节相同"
else
  bad "封面提取不一致"
fi

echo "== FLAC / Vorbis Comment =="
cp "$SAMPLES/base.flac" "$tmp/w.flac"
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
cp "$SAMPLES/base.m4a" "$tmp/w.m4a"
"$MOON" run cmd/tag --target wasm-gc -- mp4 set "$tmp/w.m4a" "©nam=新标题" "©alb=新专辑" \
  >/dev/null 2>&1
m4a_out=$("$FFMPEG" -i "$tmp/w.m4a" -f null - 2>&1)
echo "$m4a_out" | grep -q "title.*新标题" && pass "ffmpeg 读回 M4A title" || bad "ffmpeg 读不到 M4A title"
echo "$m4a_out" | grep -q "album.*新专辑" && pass "ffmpeg 读回 M4A album" || bad "ffmpeg 读不到 M4A album"

echo "== APEv2 读写（moontag 自读回） =="
cp "$SAMPLES/v24.mp3" "$tmp/ape.mp3"
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
