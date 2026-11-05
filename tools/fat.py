#!/usr/bin/env python3
"""把两个 thin mach-o 合成 fat（替代 lipo：旧 cctools 会认错 arm64e 的 subtype）。

  python3 tools/fat.py out.dylib thin1 thin2 ...
"""
import os
import struct
import sys

ALIGN = 0x4000
FAT_MAGIC = 0xCAFEBABE


def main():
    out, inputs = sys.argv[1], sys.argv[2:]
    blobs = []
    for p in inputs:
        d = open(p, "rb").read()
        magic = struct.unpack("<I", d[:4])[0]
        if magic != 0xFEEDFACF:
            sys.exit(f"{p}: 不是 thin arm64 mach-o（magic {magic:#x}）")
        cpu, sub = struct.unpack("<II", d[4:12])
        blobs.append([cpu, sub, d])
    off = 8 + 20 * len(blobs)
    head = struct.pack(">II", FAT_MAGIC, len(blobs))
    body = b""
    for cpu, sub, d in blobs:
        pad = (-(off + len(body))) % ALIGN
        body += b"\x00" * pad
        start = off + len(body)
        head += struct.pack(">iIIII", cpu, sub, start, len(d), ALIGN.bit_length() - 1)
        body += d
    open(out, "wb").write(head + body)
    print(f"{out}: {len(blobs)} slices, {os.path.getsize(out)} bytes",
          [(hex(c[0]), hex(c[1])) for c in [b[:2] for b in blobs]])


if __name__ == "__main__":
    main()
