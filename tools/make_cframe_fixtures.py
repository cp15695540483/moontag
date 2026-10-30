#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""生成 ID3v2.3 / v2.4「合法压缩帧」测试夹具（纯 Python；不依赖 moontag，不调用 moon）。

输入（仓库内已有文件，保证仓库单独可复现）：
    tools/samples/v24.mp3   （ID3v2.4 基准）→ v2.4 夹具的音频体
    tools/samples/v23.mp3   （ID3v2.3 基准）→ v2.3 夹具的音频体

输出（脚本只写这 6 个文件，均落在 tools/samples/ 下）：
    control_v24.mp3  control_v23.mp3
    cframe_v24.mp3   cframe_v24_tit2.mp3  cframe_v24_txxx.mp3  cframe_v23.mp3

规范依据（id3.org 原文）：
    ID3v2.3.0 §3.3.1
        帧头 = ID(4) + 普通大端 u32 尺寸(4) + 状态标志(1) + 格式标志(1)
        格式标志位序 %ijk00000：i=$80 压缩、j=$40 加密、k=$20 分组
        若 i=1，则帧头之后追加 4 字节 **普通大端 u32** = decompressed size
        压缩算法 = zlib（RFC 1950）
        压缩帧的帧尺寸字段值 = 磁盘上的附加头 + 压缩后的数据
    ID3v2.4.0 §4.1.2
        帧头 = ID(4) + **synchsafe** u32 尺寸(4) + 状态标志(1) + 格式标志(1)
        格式标志位序 %0h00kmnp：h=$40 分组、k=$08 压缩、m=$04 加密、p=$01 数据长度指示
        数据长度指示(DLI) = 4 字节 **synchsafe** u32，
        语义 = "所有 format flags 归零时应写的 Frame length"，即解压后的载荷长度
        压缩时必须同时置位 DLI（$08 与 $01 同置 → 0x09）
    附加头顺序（本夹具不加密、不分组，因此组号/加密方法字节不出现）：
        v2.3 = [尺寸指示 4B][加密方法 1B][组号 1B]
        v2.4 = [组号 1B][加密方法 1B][DLI 4B]
    标签头（10 字节）的尺寸字段在 v2.3 与 v2.4 中**都是** synchsafe；只有帧尺寸字段不同。

用法：
    python tools/make_cframe_fixtures.py            # 生成 + 回读自检 + 打印字节数与 sha256
    python tools/make_cframe_fixtures.py --verify    # 只读校验（独立解析 + 与重新构造的字节比对）

确定性：不写时间戳、随机数、主机路径；同样输入重复运行产出逐字节一致。
zlib 输出取决于 Python 内置 zlib 版本，换 Python 大版本重新生成时 sha256 可能变化
（仓库里提交的是生成好的夹具，跑脚本只为复现/复查）。
"""

import hashlib
import os
import struct
import sys
import zlib

sys.stdout.reconfigure(encoding="utf-8")

HERE = os.path.dirname(os.path.abspath(__file__))
SAMPLES = os.path.join(HERE, "samples")
BASE_V24 = os.path.join(SAMPLES, "v24.mp3")
BASE_V23 = os.path.join(SAMPLES, "v23.mp3")

ENCODING_BYTE = 0x03  # 所有文本帧载荷 = 编码字节 0x03(UTF-8) + UTF-8 文本
# 长文本 = `0123456789` 重复 5000 次。重复单元自身高度可压缩，只有把重复次数拉到这个量级，
# zlib 流才会超过 127 字节（实测 152 字节），使压缩帧的帧尺寸字段 ≥ 128
# —— 只有 ≥128 时 v2.4 的 synchsafe 与 v2.3 的普通大端 u32 才会写出**不同**的字节。
REPS = 5000
TEXT_ROWS = "0123456789" * REPS

PLAIN_TITLE = "PlainTitle"
PLAIN_ARTIST = "PlainArtist"
COMP_ARTIST = "CompressedArtist-" + TEXT_ROWS  # 50017 字符（期望载荷 50018 字节）
COMP_TITLE = "CompressedTitle-" + TEXT_ROWS  # 50016 字符（期望载荷 50017 字节）
TXXX_DESC = "probe"
# TXXX 值：短值 irrelevant-value 压缩后远不足 128 字节，故按重复单元加长到同一量级。
TXXX_VALUE = "irrelevant-value-" + TEXT_ROWS  # 50017 字符（TXXX 载荷 50024 字节）

V24_COMP_FLAGS = 0x09  # $08 压缩 + $01 DLI（v2.4 压缩帧必须同时置 DLI）
V23_COMP_FLAGS = 0x80  # $80 压缩


# ------------------------------------------------------------------ 基础编解码
def synchsafe(n):
    """synchsafe u32：每字节只用低 7 位（ID3v2.4 帧尺寸 / DLI / 标签尺寸）。"""
    assert 0 <= n < (1 << 28), n
    return bytes([(n >> 21) & 0x7F, (n >> 14) & 0x7F, (n >> 7) & 0x7F, n & 0x7F])


def read_synchsafe(b, off):
    return (b[off] << 21) | (b[off + 1] << 14) | (b[off + 2] << 7) | b[off + 3]


def decode_synchsafe(raw):
    """4 字节 synchsafe → int。"""
    assert len(raw) == 4, raw
    return read_synchsafe(raw, 0)


def read_u32(b, off):
    return struct.unpack(">I", b[off : off + 4])[0]


def decode_u32(raw):
    """4 字节普通大端 u32 → int。"""
    assert len(raw) == 4, raw
    return read_u32(raw, 0)


def describe_synchsafe_misread(raw):
    """把一段普通大端字节误当 synchsafe 读时，如实描述会发生什么。

    synchsafe 每字节只允许低 7 位：某个字节最高位为 1 时，synchsafe 读法本身就是**非法**的，
    不能含糊地说"得某个数"。非法时同时给出按低 7 位强行解码的结果。
    """
    bad = [i + 1 for i, b in enumerate(raw) if b & 0x80]
    val = 0
    for b in raw:
        val = (val << 7) | (b & 0x7F)
    if bad:
        return f"按 synchsafe 误读非法（第 {'/'.join(map(str, bad))} 字节最高位为 1）；强行按低 7 位解码得 {val}"
    return f"按 synchsafe 误读得 {val}"


def text_payload(text):
    """文本帧载荷 = 1 字节编码 + UTF-8 文本（TXXX 的描述/值分隔符是文本里的 \\x00）。"""
    return bytes([ENCODING_BYTE]) + text.encode("utf-8")


# ------------------------------------------------------------------ 帧 / 标签组装
def frame_bytes(major, fid, payload_disk, fmt_flags):
    """按版本写帧头：v2.4 尺寸=synchsafe，v2.3 尺寸=普通大端 u32。"""
    assert len(fid) == 4
    if major == 4:
        size_field = synchsafe(len(payload_disk))
    else:
        size_field = struct.pack(">I", len(payload_disk))
    return fid.encode("ascii") + size_field + bytes([0x00, fmt_flags]) + payload_disk


def compressed_disk_payload(major, payload):
    """压缩帧的磁盘载荷 = 长度指示 + zlib(RFC1950) 流（不含帧头）。"""
    if major == 4:
        return synchsafe(len(payload)) + zlib.compress(payload, 9)
    return struct.pack(">I", len(payload)) + zlib.compress(payload, 9)


def tag_bytes(major, body):
    """完整标签 = 10 字节头 + body；标签头尺寸字段两个版本都用 synchsafe。"""
    return b"ID3" + bytes([major, 0x00, 0x00]) + synchsafe(len(body)) + body


def split_mp3(path):
    """返回 (标签字节, 音频字节)；只处理带 ID3v2 头的文件。"""
    data = open(path, "rb").read()
    assert data[:3] == b"ID3", f"{path} 没有 ID3v2 头"
    size = read_synchsafe(data, 6)
    footer = 10 if (data[3] == 4 and (data[5] & 0x10)) else 0
    total = 10 + size + footer
    return data[:total], data[total:]


def audio_of(base_path):
    return split_mp3(base_path)[1]


# ------------------------------------------------------------------ 夹具规格（唯一事实来源）
def fixture_specs():
    """每个夹具 = 版本 + 基准文件 + 帧序列；帧描述里带期望载荷与期望文本。

    comp=True 的帧写压缩标志 + 长度指示 + zlib 流；comp=False 直接写载荷。
    """
    v24_plain_pair = [
        dict(id="TIT2", payload=text_payload(PLAIN_TITLE), comp=False, flags=0x00, text=PLAIN_TITLE),
        dict(id="TPE1", payload=text_payload(COMP_ARTIST), comp=False, flags=0x00, text=COMP_ARTIST),
    ]
    txxx = TXXX_DESC + "\x00" + TXXX_VALUE  # \x00 分隔描述与值（UTF-8 里就是单字节 0x00）
    return [
        dict(name="control_v24.mp3", major=4, base=BASE_V24, note="对照组：与 cframe_v24 同文本，全未压缩", frames=v24_plain_pair),
        dict(name="control_v23.mp3", major=3, base=BASE_V23, note="对照组：与 cframe_v23 同文本，全未压缩", frames=v24_plain_pair),
        dict(
            name="cframe_v24.mp3",
            major=4,
            base=BASE_V24,
            note="v2.4：TIT2 普通 + TPE1 压缩($09，带 DLI)",
            frames=[
                dict(id="TIT2", payload=text_payload(PLAIN_TITLE), comp=False, flags=0x00, text=PLAIN_TITLE),
                dict(id="TPE1", payload=text_payload(COMP_ARTIST), comp=True, flags=V24_COMP_FLAGS, text=COMP_ARTIST),
            ],
        ),
        dict(
            name="cframe_v24_tit2.mp3",
            major=4,
            base=BASE_V24,
            note="v2.4：TIT2 压缩($09) + TPE1 普通（压缩帧排在第一位）",
            frames=[
                dict(id="TIT2", payload=text_payload(COMP_TITLE), comp=True, flags=V24_COMP_FLAGS, text=COMP_TITLE),
                dict(id="TPE1", payload=text_payload(PLAIN_ARTIST), comp=False, flags=0x00, text=PLAIN_ARTIST),
            ],
        ),
        dict(
            name="cframe_v24_txxx.mp3",
            major=4,
            base=BASE_V24,
            note="v2.4：TIT2/TPE1 普通 + TXXX 压缩($09) 且排在最后一帧",
            frames=[
                dict(id="TIT2", payload=text_payload(PLAIN_TITLE), comp=False, flags=0x00, text=PLAIN_TITLE),
                dict(id="TPE1", payload=text_payload(PLAIN_ARTIST), comp=False, flags=0x00, text=PLAIN_ARTIST),
                dict(id="TXXX", payload=text_payload(txxx), comp=True, flags=V24_COMP_FLAGS, text=txxx),
            ],
        ),
        dict(
            name="cframe_v23.mp3",
            major=3,
            base=BASE_V23,
            note="v2.3：TIT2 普通 + TPE1 压缩($80，帧头后 4 字节大端 decompressed size)",
            frames=[
                dict(id="TIT2", payload=text_payload(PLAIN_TITLE), comp=False, flags=0x00, text=PLAIN_TITLE),
                dict(id="TPE1", payload=text_payload(COMP_ARTIST), comp=True, flags=V23_COMP_FLAGS, text=COMP_ARTIST),
            ],
        ),
    ]


def build(spec):
    """返回 (完整文件字节, 标签体字节, 音频字节)。"""
    body = b"".join(
        frame_bytes(
            spec["major"],
            f["id"],
            compressed_disk_payload(spec["major"], f["payload"]) if f["comp"] else f["payload"],
            f["flags"],
        )
        for f in spec["frames"]
    )
    audio = audio_of(spec["base"])
    return tag_bytes(spec["major"], body) + audio, body, audio


# ------------------------------------------------------------------ 独立校验（自写解析器，不依赖 moontag）
def show_payload(payload):
    """文本帧载荷 → 可读串（长文本截断显示）。"""
    enc = payload[0]
    body = payload[1:].decode("utf-8")
    shown = body if len(body) <= 60 else f"{body[:60]}...(共 {len(body)} 字符)"
    return f"编码字节 0x{enc:02X}  文本={shown!r}"


def check_text(name, fid, raw, f):
    """(c) 帧的最终文本（压缩帧为解压后）必须等于期望值。"""
    assert raw[0] == ENCODING_BYTE, f"{name}: 帧 {fid} 编码字节应为 0x03"
    assert raw[1:].decode("utf-8") == f["text"], f"{name}: 帧 {fid} 文本与期望值不一致"


def verify(spec, data, verbose=True):
    """逐帧独立回读并断言：(a) 尺寸编码方式 (b) 长度指示与解压长度一致 (c) 文本 (d) 音频体。"""
    name, major = spec["name"], spec["major"]
    assert data[:3] == b"ID3", f"{name}: 缺少 ID3 头"
    assert data[3] == major, f"{name}: 标签版本 {data[3]} != {major}"
    assert data[4] == 0 and data[5] == 0, f"{name}: revision/flags 非 0"
    tag_size_raw = data[6:10]
    tag_size = decode_synchsafe(tag_size_raw)
    body = data[10 : 10 + tag_size]
    assert len(body) == tag_size, f"{name}: 标签体被截断"
    audio = data[10 + tag_size :]
    base_audio = audio_of(spec["base"])
    assert audio == base_audio, f"{name}: 音频体与基准 {os.path.basename(spec['base'])} 不一致"
    # 标签头尺寸字段在 v2.3/v2.4 都是 synchsafe（与帧尺寸字段不同）
    assert synchsafe(tag_size) == tag_size_raw, f"{name}: 标签尺寸字段不是 synchsafe 编码"

    if verbose:
        print(f"[写出] {name}  {len(data)} 字节（标签体 {len(body)} + 音频 {len(audio)}）")
        print(
            f"  标签头 ID3v2.{major}.0 flags=0x00 尺寸字段=0x{tag_size_raw.hex()}"
            f"（synchsafe）={tag_size}  音频与 {os.path.basename(spec['base'])} 逐字节一致 ✓"
        )

    pos = 0
    for n, f in enumerate(spec["frames"], 1):
        assert pos + 10 <= len(body), f"{name}: 帧 #{n} 头越界"
        fid = body[pos : pos + 4].decode("ascii")
        assert fid == f["id"], f"{name}: 帧 #{n} ID={fid} != {f['id']}"
        size_raw = body[pos + 4 : pos + 8]
        size = decode_synchsafe(size_raw) if major == 4 else decode_u32(size_raw)
        status, fmt = body[pos + 8], body[pos + 9]
        assert status == 0x00, f"{name}: 帧 {fid} 状态标志非 0"
        assert fmt == f["flags"], f"{name}: 帧 {fid} 格式标志 0x{fmt:02X} != 0x{f['flags']:02X}"
        payload = body[pos + 10 : pos + 10 + size]
        assert len(payload) == size, f"{name}: 帧 {fid} 尺寸超出标签体"
        pos += 10 + size

        scheme = "synchsafe" if major == 4 else "普通大端 u32"
        assert size == len(payload), f"{name}: 帧 {fid} 尺寸字段 != 磁盘载荷长度"
        if major == 4:
            # 规范形式：v2.4 帧尺寸必须是 synchsafe 编码，不能只是"解码后数值恰好相等"
            assert synchsafe(size) == size_raw, f"{name}: 帧 {fid} 尺寸字段不是 synchsafe 规范编码"
        if verbose:
            if major == 4:
                disc = f"；若误读为普通大端 u32 则得 {decode_u32(size_raw)}"
            else:
                disc = f"；{describe_synchsafe_misread(size_raw)}"
            print(
                f"  帧#{n} {fid} 尺寸字段=0x{size_raw.hex()}（{scheme}）={size} 字节{disc}"
                f"  状态=0x00 格式=0x{fmt:02X} ({fmt:08b})"
            )

        if major == 4:
            if f["comp"]:
                assert fmt & 0x08 and fmt & 0x01, f"{name}: 帧 {fid} 压缩帧必须同时置 DLI"
                dli_raw = payload[:4]
                dli = decode_synchsafe(dli_raw)
                assert synchsafe(dli) == dli_raw, f"{name}: 帧 {fid} DLI 不是 synchsafe 规范编码"
                assert dli == len(f["payload"]), f"{name}: 帧 {fid} DLI {dli} != 期望载荷 {len(f['payload'])}"
                zstream = payload[4:]
                raw = zlib.decompress(zstream)
                assert raw == f["payload"], f"{name}: 帧 {fid} 解压结果与期望载荷不一致"
                assert len(raw) == dli, f"{name}: 帧 {fid} DLI != 实际解压长度"
                assert len(zstream) > 127, f"{name}: 帧 {fid} zlib 流仅 {len(zstream)} 字节，未超过 127"
                assert size >= 128, f"{name}: 帧 {fid} 帧尺寸字段仅 {size}，未达到 128"
                check_text(name, fid, raw, f)
                if verbose:
                    print(
                        f"      [压缩] DLI=0x{dli_raw.hex()}（synchsafe，规范形式 ✓）={dli}"
                        f"；若误读为普通大端 u32 则得 {decode_u32(dli_raw)}"
                    )
                    print(
                        f"      [压缩] zlib 流 {len(zstream)} 字节（>127 ✓）-> 解压 {len(raw)} 字节；"
                        f"DLI == len(zlib.decompress(payload)) == len(期望载荷) ✓"
                    )
                    print(f"      [文本] {show_payload(raw)}")
            else:
                assert fmt == 0x00, f"{name}: 帧 {fid} 不该有格式标志"
                assert payload == f["payload"], f"{name}: 帧 {fid} 载荷与期望不一致"
                check_text(name, fid, payload, f)
                if verbose:
                    print(f"      [未压缩] 载荷 {len(payload)} 字节；[文本] {show_payload(payload)}")
        else:
            if f["comp"]:
                assert fmt & 0x80, f"{name}: 帧 {fid} 缺少 v2.3 压缩标志"
                dsize_raw = payload[:4]
                dsize = decode_u32(dsize_raw)
                assert dsize == len(f["payload"]), f"{name}: 帧 {fid} decompressed size {dsize} != 期望载荷 {len(f['payload'])}"
                zstream = payload[4:]
                raw = zlib.decompress(zstream)
                assert raw == f["payload"], f"{name}: 帧 {fid} 解压结果与期望载荷不一致"
                assert len(raw) == dsize, f"{name}: 帧 {fid} decompressed size != 实际解压长度"
                assert len(zstream) > 127, f"{name}: 帧 {fid} zlib 流仅 {len(zstream)} 字节，未超过 127"
                assert size >= 128, f"{name}: 帧 {fid} 帧尺寸字段仅 {size}，未达到 128"
                check_text(name, fid, raw, f)
                if verbose:
                    print(
                        f"      [压缩] decompressed size=0x{dsize_raw.hex()}（普通大端 u32）={dsize}"
                        f"；{describe_synchsafe_misread(dsize_raw)}"
                    )
                    print(
                        f"      [压缩] zlib 流 {len(zstream)} 字节（>127 ✓）-> 解压 {len(raw)} 字节；"
                        f"decompressed size == len(zlib.decompress(payload)) == len(期望载荷) ✓"
                    )
                    print(f"      [文本] {show_payload(raw)}")
            else:
                assert fmt == 0x00, f"{name}: 帧 {fid} 不该有格式标志"
                assert payload == f["payload"], f"{name}: 帧 {fid} 载荷与期望不一致"
                check_text(name, fid, payload, f)
                if verbose:
                    print(f"      [未压缩] 载荷 {len(payload)} 字节；[文本] {show_payload(payload)}")

    assert pos == len(body), f"{name}: 标签体尾部有 {len(body) - pos} 字节未消费（本夹具不含 padding）"
    return len(data)


# ------------------------------------------------------------------ 主流程
def main(argv):
    verify_only = "--verify" in argv
    specs = fixture_specs()
    manifest = []
    for spec in specs:
        path = os.path.join(SAMPLES, spec["name"])
        data, _body, _audio = build(spec)
        if verify_only:
            assert os.path.exists(path), f"缺少夹具文件：{path}"
            on_disk = open(path, "rb").read()
            assert on_disk == data, f"{path}: 磁盘字节与重新构造的字节不一致"
            verify(spec, on_disk, verbose=False)
            digest = hashlib.sha256(on_disk).hexdigest()
            print(f"[PASS] {spec['name']}  {len(on_disk)} 字节  sha256={digest}  （磁盘==重新构造，独立解析通过）")
        else:
            verify(spec, data, verbose=True)
            with open(path, "wb") as fp:
                fp.write(data)
            reread = open(path, "rb").read()
            assert reread == data, f"{path}: 写盘后回读不一致"
            manifest.append((spec["name"], len(data), hashlib.sha256(data).hexdigest()))
            print()
    if verify_only:
        print(f"全部夹具校验通过（{len(specs)}/{len(specs)}）。")
    else:
        print("夹具清单：")
        for name, size, digest in sorted(manifest):
            print(f"  {name:22s} {size:6d} 字节  sha256={digest}")
        print(f"全部夹具生成并自检通过（{len(specs)}/{len(specs)}）。")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as exc:  # 任何校验失败都必须非零退出
        print(f"[FAIL] 自检失败：{type(exc).__name__}: {exc}")
        sys.exit(1)
