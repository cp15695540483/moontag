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
for s in v24.mp3 v23.mp3 noid3.mp3 base.flac base.m4a faststart.m4a cover.png test.ogg test.opus; do
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
grep -q "title.*新标题" <<< "$tag_out" && pass "ffmpeg 读回 title" || bad "ffmpeg 读不到 title"
grep -q "artist.*新艺术家" <<< "$tag_out" && pass "ffmpeg 读回 artist" || bad "ffmpeg 读不到 artist"

echo "== MP3 音频零损失 =="
"$FFMPEG" -loglevel error -i "$SAMPLES/v24.mp3" -f s16le -ac 1 -ar 44100 "$tmp/a.pcm" -y
"$FFMPEG" -loglevel error -i "$tmp/t24.mp3" -f s16le -ac 1 -ar 44100 "$tmp/b.pcm" -y
if cmp -s "$tmp/a.pcm" "$tmp/b.pcm"; then
  pass "改写前后 PCM 逐字节相同"
else
  bad "音频数据被改动"
fi

echo "== ID3v2 帧级压缩（zlib：v2.4 DLI / v2.3 4 字节尺寸） =="
# 压缩帧是规范内的合法帧头形态（id3v2.3.0 §3.3.1、id3v2.4.0-structure §4.1.2），
# 夹具由 tools/make_cframe_fixtures.py 生成后提交，来源写在 tools/samples/README.md。
for s in cframe_v24.mp3 cframe_v24_tit2.mp3 cframe_v24_txxx.mp3 cframe_v23.mp3 control_v24.mp3 control_v23.mp3; do
  if [ ! -f "$SAMPLES/$s" ]; then
    echo "缺少测试样本 $SAMPLES/$s（用 tools/make_cframe_fixtures.py 生成）"
    exit 1
  fi
done
# 断言辅助：纯 bash 子串判断，不经过管道。
#
# 为什么不用 `cmd | grep -q`：`grep -q` 一命中就退出，而写端（moon run）仍在输出
# 一个约 50 KB 的超长字段时会收到 SIGPIPE(141)；本脚本开了 `set -o pipefail`，
# 整条管道因此被判为失败 → 断言误报。这个竞态在 CI 上真的发生过：同一提交重跑，
# 两次失败的断言还不一样（一次「对照组」，一次「v2.3 压缩帧」），本地却全绿。
contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
cfshow() { "$MOON" run cmd/tag --target wasm-gc -- show "$1" 2>&1; }
contains "$(cfshow "$SAMPLES/cframe_v24.mp3")" "CompressedArtist-" &&
  pass "v2.4 压缩帧（zlib + DLI）读出文本" || bad "v2.4 压缩帧读不出文本"
contains "$(cfshow "$SAMPLES/cframe_v23.mp3")" "CompressedArtist-" &&
  pass "v2.3 压缩帧（4 字节解压后尺寸）读出文本" || bad "v2.3 压缩帧读不出文本"
# 连坐判据：只有一个无关帧（TXXX）被压缩时，其余字段必须照常读出
contains "$(cfshow "$SAMPLES/cframe_v24_txxx.mp3")" "PlainTitle" &&
  pass "被压缩的无关帧不影响其它字段" || bad "压缩帧连坐：其它字段丢失"
# 对照组（同布局、不设压缩位）：证明差异确实来自压缩标志，而不是夹具本身
contains "$(cfshow "$SAMPLES/control_v24.mp3")" "CompressedArtist-" &&
  pass "对照组（不设压缩位）读出同一字段" || bad "对照组读不出字段：夹具布局有问题"
# 改写：压缩帧内容不能丢，新增字段要读得回，音频零损失
cp "$SAMPLES/cframe_v24.mp3" "$tmp/cf24.mp3"
cp "$SAMPLES/cframe_v23.mp3" "$tmp/cf23.mp3"
"$MOON" run cmd/tag --target wasm-gc -- set "$tmp/cf24.mp3" "TCON=Rock" >/dev/null 2>&1
"$MOON" run cmd/tag --target wasm-gc -- set "$tmp/cf23.mp3" "TCON=Rock" >/dev/null 2>&1
cf_after=$(cfshow "$tmp/cf24.mp3")
contains "$cf_after" "CompressedArtist-" && pass "改写后 v2.4 压缩帧内容仍在" || bad "改写丢失 v2.4 压缩帧内容"
contains "$cf_after" "Rock" && pass "改写新增字段可读回" || bad "改写新增字段读不到"
contains "$(cfshow "$tmp/cf23.mp3")" "CompressedArtist-" &&
  pass "改写后 v2.3 压缩帧内容仍在" || bad "改写丢失 v2.3 压缩帧内容"
"$FFMPEG" -loglevel error -i "$SAMPLES/cframe_v24.mp3" -f s16le -ac 1 -ar 44100 "$tmp/cf_a.pcm" -y 2>/dev/null
"$FFMPEG" -loglevel error -i "$tmp/cf24.mp3" -f s16le -ac 1 -ar 44100 "$tmp/cf_b.pcm" -y 2>/dev/null
if cmp -s "$tmp/cf_a.pcm" "$tmp/cf_b.pcm"; then
  pass "压缩帧改写后 PCM 逐字节相同"
else
  bad "压缩帧改写破坏了音频"
fi
# 与 ffmpeg 的能力对照：v2.4 双方都能读；v2.3 只有本库能读（ffmpeg 静默丢该帧）
ff24=$("$FFMPEG" -i "$SAMPLES/cframe_v24.mp3" -f null - 2>&1)
contains "$ff24" "CompressedArtist-" &&
  pass "ffmpeg 亦能读 v2.4 压缩帧（夹具正确性对照）" || bad "ffmpeg 读不到 v2.4 压缩帧：夹具可能不合规"
ff23=$("$FFMPEG" -i "$SAMPLES/cframe_v23.mp3" -f null - 2>&1)
if contains "$ff23" "CompressedArtist-"; then
  pass "ffmpeg 亦能读 v2.3 压缩帧"
else
  pass "ffmpeg 读不到 v2.3 压缩帧（本库读出：能力差异，非缺陷）"
fi

echo "== APIC 封面写入与提取 =="
cp "$SAMPLES/v24.mp3" "$tmp/cover.mp3"
"$MOON" run cmd/tag --target wasm-gc -- cover "$tmp/cover.mp3" "$SAMPLES/cover.png" >/dev/null 2>&1
apic_ff=$("$FFMPEG" -i "$tmp/cover.mp3" -f null - 2>&1)
if contains "$apic_ff" "attached pic"; then
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
contains "$tags" "TITLE=改过的标题" && pass "metaflac 读回 TITLE" || bad "metaflac 读不到 TITLE"
contains "$tags" "ALBUM=新专辑" && pass "metaflac 读回 ALBUM" || bad "metaflac 读不到 ALBUM"
if "$FLAC" -t "$tmp/w.flac" >/dev/null 2>&1; then
  pass "flac -t 完整性校验通过"
else
  bad "flac -t 失败（音频被破坏）"
fi

# FLAC 的原生封面是 PICTURE 元数据块（块类型 6），与 Ogg 只能走 comment 不同。
# 用 metaflac 造一个真实块，再验证：本库认得出来、改标签后不丢、能原样提取。
echo "== FLAC 原生 PICTURE 块（封面） =="
cp "$SAMPLES/base.flac" "$tmp/pic.flac"
"$METAFLAC" --import-picture-from="$SAMPLES/cover.png" "$tmp/pic.flac" >/dev/null 2>&1
"$MOON" run cmd/tag --target wasm-gc -- set "$tmp/pic.flac" "TITLE=带封面改标题" >/dev/null 2>&1
pic_show=$("$MOON" run cmd/tag --target wasm-gc -- show "$tmp/pic.flac" 2>&1)
contains "$pic_show" "封面: 有" &&
  pass "FLAC 原生 PICTURE 块被统一视图识别为封面" || bad "FLAC 原生 PICTURE 块未被识别"
pic_blocks=$("$METAFLAC" --list --block-type=PICTURE "$tmp/pic.flac" 2>/dev/null)
contains "$pic_blocks" "type: 6" &&
  pass "改标签后 PICTURE 块仍在（metaflac 复核）" || bad "改标签后 PICTURE 块丢失"
"$MOON" run cmd/tag --target wasm-gc -- apic "$tmp/pic.flac" "$tmp/flacpic.png" >/dev/null 2>&1
if cmp -s "$SAMPLES/cover.png" "$tmp/flacpic.png"; then
  pass "FLAC 封面提取与原 PNG 逐字节相同"
else
  bad "FLAC 封面提取不一致"
fi

echo "== MP4 / M4A ilst =="
cp "$SAMPLES/base.m4a" "$tmp/w.m4a"
"$MOON" run cmd/tag --target wasm-gc -- mp4 set "$tmp/w.m4a" "©nam=新标题" "©alb=新专辑" \
  >/dev/null 2>&1
m4a_out=$("$FFMPEG" -i "$tmp/w.m4a" -f null - 2>&1)
grep -q "title.*新标题" <<< "$m4a_out" && pass "ffmpeg 读回 M4A title" || bad "ffmpeg 读不到 M4A title"
grep -q "album.*新专辑" <<< "$m4a_out" && pass "ffmpeg 读回 M4A album" || bad "ffmpeg 读不到 M4A album"

# 硬场景：moov 前置（faststart）+ 标签增长超出预留空间（moov 后仅 8 字节 free）。
# 此时 mdat 整体后移，必须同步修正 stco/co64 的绝对 chunk 偏移，
# 否则播放器定位错乱（修复前实测 ffmpeg 报 "Error submitting packet to decoder"）。
echo "== MP4 faststart（moov 前置）标签增长 =="
cp "$SAMPLES/faststart.m4a" "$tmp/fs.m4a"
"$MOON" run cmd/tag --target wasm-gc -- mp4 set "$tmp/fs.m4a" "©nam=Faststart New Title" \
  "©ART=$(printf 'A%.0s' $(seq 1 200))" >/dev/null 2>&1
# 音频必须仍可解码
"$FFMPEG" -loglevel error -i "$SAMPLES/faststart.m4a" -f s16le "$tmp/fs_orig.pcm" -y 2>/dev/null
if "$FFMPEG" -loglevel error -i "$tmp/fs.m4a" -f s16le "$tmp/fs_new.pcm" -y 2>/dev/null; then
  pass "faststart 标签增长后 ffmpeg 仍能解码"
else
  bad "faststart 标签增长后音频解码失败（stco 偏移未修正）"
fi
if cmp -s "$tmp/fs_orig.pcm" "$tmp/fs_new.pcm"; then
  pass "faststart 改写后 PCM 逐字节相同"
else
  bad "faststart 改写后音频数据错位"
fi
fast_out=$("$FFMPEG" -i "$tmp/fs.m4a" -f null - 2>&1)
grep -q "title.*Faststart New Title" <<< "$fast_out" && pass "faststart 标签可读回" || bad "faststart 标签读不到"

echo "== APEv2 读写（moontag 自读回） =="
cp "$SAMPLES/v24.mp3" "$tmp/ape.mp3"
"$MOON" run cmd/tag --target wasm-gc -- ape set "$tmp/ape.mp3" "Title=APE 标题" "Artist=APE 艺术家" \
  >/dev/null 2>&1
ape_out=$("$MOON" run cmd/tag --target wasm-gc -- ape show "$tmp/ape.mp3" 2>&1)
contains "$ape_out" "APE 标题" && pass "APEv2 读回 Title" || bad "APEv2 读不到 Title"
contains "$ape_out" "APE 艺术家" && pass "APEv2 读回 Artist" || bad "APEv2 读不到 Artist"
# 音频必须仍然完整
"$FFMPEG" -loglevel error -i "$tmp/ape.mp3" -f s16le -ac 1 -ar 44100 "$tmp/c.pcm" -y
if cmp -s "$tmp/a.pcm" "$tmp/c.pcm"; then
  pass "APEv2 写入后音频仍逐字节相同"
else
  bad "APEv2 写入破坏了音频"
fi

echo "== Ogg Vorbis / Opus comment =="
cp "$SAMPLES/test.ogg" "$tmp/w.ogg"
cp "$SAMPLES/test.opus" "$tmp/w.opus"
"$MOON" run cmd/tag --target wasm-gc -- ogg set "$tmp/w.ogg" "TITLE=改过的 Ogg 标题" "ALBUM=Ogg 新专辑" \
  >/dev/null 2>&1
"$MOON" run cmd/tag --target wasm-gc -- ogg set "$tmp/w.opus" "TITLE=改过的 Opus 标题" \
  >/dev/null 2>&1
ogg_out=$("$FFMPEG" -i "$tmp/w.ogg" -f null - 2>&1)
grep -q "TITLE.*改过的 Ogg 标题" <<< "$ogg_out" && pass "ffmpeg 读回 Ogg TITLE" || bad "ffmpeg 读不到 Ogg TITLE"
opus_out=$("$FFMPEG" -i "$tmp/w.opus" -f null - 2>&1)
grep -q "TITLE.*改过的 Opus 标题" <<< "$opus_out" && pass "ffmpeg 读回 Opus TITLE" || bad "ffmpeg 读不到 Opus TITLE"
# 音频零损失
"$FFMPEG" -loglevel error -i "$SAMPLES/test.ogg" -f s16le -ac 1 -ar 44100 "$tmp/og1.pcm" -y
"$FFMPEG" -loglevel error -i "$tmp/w.ogg" -f s16le -ac 1 -ar 44100 "$tmp/og2.pcm" -y
if cmp -s "$tmp/og1.pcm" "$tmp/og2.pcm"; then
  pass "Ogg 写入后 PCM 逐字节相同"
else
  bad "Ogg 音频被破坏"
fi

echo "== Ogg 封面（METADATA_BLOCK_PICTURE） =="
# Ogg 的封面不是二进制帧，而是 Vorbis Comment 里一条 Base64 的 FLAC PICTURE 载荷。
# 验证：写入走对路径 → 统一视图认得出 → 提取回来与原 PNG 逐字节一致 → 音频没动。
cp "$SAMPLES/test.ogg" "$tmp/oc.ogg"
oc_write=$("$MOON" run cmd/tag --target wasm-gc -- cover "$tmp/oc.ogg" "$SAMPLES/cover.png" 2>&1)
contains "$oc_write" "METADATA_BLOCK_PICTURE" &&
  pass "Ogg 封面写入走 METADATA_BLOCK_PICTURE" || bad "Ogg 封面写入路径不对"
oc_show=$("$MOON" run cmd/tag --target wasm-gc -- show "$tmp/oc.ogg" 2>&1)
contains "$oc_show" "封面: 有" &&
  pass "Ogg 封面写入后统一视图显示「有」" || bad "Ogg 封面写入后统一视图仍显示无封面"
"$MOON" run cmd/tag --target wasm-gc -- apic "$tmp/oc.ogg" "$tmp/oc.png" >/dev/null 2>&1
if cmp -s "$SAMPLES/cover.png" "$tmp/oc.png"; then
  pass "Ogg 封面提取与原 PNG 逐字节相同"
else
  bad "Ogg 封面提取与原 PNG 不一致"
fi
"$FFMPEG" -loglevel error -i "$SAMPLES/test.ogg" -f s16le -ac 1 -ar 44100 "$tmp/oc1.pcm" -y 2>/dev/null
"$FFMPEG" -loglevel error -i "$tmp/oc.ogg" -f s16le -ac 1 -ar 44100 "$tmp/oc2.pcm" -y 2>/dev/null
if cmp -s "$tmp/oc1.pcm" "$tmp/oc2.pcm"; then
  pass "Ogg 写封面后 PCM 逐字节相同"
else
  bad "Ogg 写封面破坏了音频"
fi
# Opus 走同一条 comment 路径，单独跑一遍（OpusTags 没有 setup packet）
cp "$SAMPLES/test.opus" "$tmp/oc.opus"
"$MOON" run cmd/tag --target wasm-gc -- cover "$tmp/oc.opus" "$SAMPLES/cover.png" >/dev/null 2>&1
"$MOON" run cmd/tag --target wasm-gc -- apic "$tmp/oc.opus" "$tmp/ocopus.png" >/dev/null 2>&1
if cmp -s "$SAMPLES/cover.png" "$tmp/ocopus.png"; then
  pass "Ogg Opus 封面往返一致"
else
  bad "Ogg Opus 封面往返不一致"
fi

# 统一视图必须覆盖五种标签场景（MP3/FLAC/M4A/Ogg Vorbis/Ogg Opus），
# 且 MP3 的标签来源要能回退到 APEv2。
echo "== CLI 失败退出码 =="
# 失败只打印、退出码仍为 0，会让脚本与 CI 把"没做成"当成成功。
if "$MOON" run cmd/tag --target wasm-gc -- show "$tmp/definitely-missing.mp3" \
  >/dev/null 2>&1; then
  bad "show 对不存在的文件返回成功（退出码应为非 0）"
else
  pass "show 对不存在的文件退出码非 0"
fi
if "$MOON" run cmd/tag --target wasm-gc -- cover "$SAMPLES/v24.mp3" "$tmp/missing.png" \
  >/dev/null 2>&1; then
  bad "cover 读不到图片时返回成功（退出码应为非 0）"
else
  pass "cover 读不到图片时退出码非 0"
fi

echo "== 统一视图覆盖范围 =="
uv() { "$MOON" run cmd/tag --target wasm-gc -- show "$1" 2>&1; }
contains "$(uv "$SAMPLES/v24.mp3")" "MP3 / ID3v2" && pass "统一视图识别 MP3" || bad "统一视图不识别 MP3"
contains "$(uv "$SAMPLES/base.flac")" "FLAC / Vorbis Comment" && pass "统一视图识别 FLAC" || bad "统一视图不识别 FLAC"
contains "$(uv "$SAMPLES/base.m4a")" "MP4 / ilst" && pass "统一视图识别 M4A" || bad "统一视图不识别 M4A"
contains "$(uv "$SAMPLES/test.ogg")" "Ogg / Vorbis Comment" && pass "统一视图识别 Ogg Vorbis" || bad "统一视图不识别 Ogg Vorbis"
contains "$(uv "$SAMPLES/test.opus")" "Ogg / Vorbis Comment" && pass "统一视图识别 Ogg Opus" || bad "统一视图不识别 Ogg Opus"
# 无 ID3v2 的 MP3：写入 APEv2 后统一视图应能读出
cp "$SAMPLES/noid3.mp3" "$tmp/apeonly.mp3"
"$MOON" run cmd/tag --target wasm-gc -- ape set "$tmp/apeonly.mp3" "Title=ApeFallback" \
  >/dev/null 2>&1
contains "$(uv "$tmp/apeonly.mp3")" "ApeFallback" && pass "统一视图回退读 APEv2" || bad "统一视图未回退到 APEv2"

echo
if [ "$fail" -eq 0 ]; then
  echo "端到端验证全部通过"
else
  echo "存在失败项"
fi
exit "$fail"
