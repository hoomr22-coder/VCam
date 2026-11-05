#!/usr/bin/env python3
"""把 deb 里 arm64e 切片的 cpusubtype 从 2 改成 0x80000002（ABI v2）。

Linux 上的 cctools 把 ptrauth 代码（clang 生成的 pacibsp）标成 ABI v1，
iOS 18 的 dyld/objc 会按 ABI v1 处理这套代码，在 map_images/readClass 直接 trap。
打包后统一改头部最省事，不受 make 重新链接的影响。

  python fix_abi.py path/to/x.deb [more.deb ...]
"""
import io
import lzma
import struct
import sys
import tarfile

ARM64E_ABI2 = 0x80000002


def patch_macho(blob: bytes) -> tuple[bytes, int]:
    d = bytearray(blob)
    if len(d) < 32:
        return blob, 0
    fixed = 0
    if struct.unpack(">I", d[:4])[0] == 0xCAFEBABE:          # fat
        n = struct.unpack(">I", d[4:8])[0]
        for i in range(n):
            base = 8 + i * 20
            if struct.unpack(">I", d[base + 4:base + 8])[0] == 2:
                d[base + 4:base + 8] = struct.pack(">I", ARM64E_ABI2)
                fixed += 1
        # 切片内的 mach_header 也要一致
        for i in range(n):
            base = 8 + i * 20
            off, size = struct.unpack(">II", d[base + 8:base + 16])
            if size > 32 and off + 12 <= len(d):
                if struct.unpack("<I", d[off:off + 4])[0] == 0xFEEDFACF and \
                        struct.unpack("<I", d[off + 8:off + 12])[0] == 2:
                    d[off + 8:off + 12] = struct.pack("<I", ARM64E_ABI2)
                    fixed += 1
    elif struct.unpack("<I", d[:4])[0] == 0xFEEDFACF:        # thin
        if struct.unpack("<I", d[8:12])[0] == 2:
            d[8:12] = struct.pack("<I", ARM64E_ABI2)
            fixed += 1
    return bytes(d), fixed


def read_ar(blob: bytes):
    assert blob[:8] == b"!<arch>\n", "not an ar archive"
    pos = 8
    members = []
    while pos + 60 <= len(blob):
        head = blob[pos:pos + 60]
        name = head[:16].decode().strip().rstrip("/")
        size = int(head[48:58].decode().strip())
        data = blob[pos + 60:pos + 60 + size]
        members.append([name, head, data])
        pos += 60 + size + (size % 2)
    return members


def write_ar(members) -> bytes:
    out = bytearray(b"!<arch>\n")
    for name, head, data in members:
        h = bytearray(head)
        h[48:58] = f"{len(data):<10}".encode()
        out += bytes(h) + data
        if len(data) % 2:
            out += b"\n"
    return bytes(out)


def patch_deb(path: str) -> int:
    blob = open(path, "rb").read()
    members = read_ar(blob)
    total = 0
    for m in members:
        name, _, data = m
        if not name.startswith("data.tar"):
            continue
        if name.endswith(".xz"):
            raw = lzma.decompress(data, format=lzma.FORMAT_XZ)
        elif name.endswith(".lzma"):
            raw = lzma.decompress(data, format=lzma.FORMAT_ALONE)
        elif name.endswith(".gz"):
            import gzip
            raw = gzip.decompress(data)
        else:
            raw = data
        src = tarfile.open(fileobj=io.BytesIO(raw))
        buf = io.BytesIO()
        dst = tarfile.open(fileobj=buf, mode="w", format=src.format or tarfile.GNU_FORMAT)
        for ti in src.getmembers():
            payload = src.extractfile(ti).read() if ti.isfile() else None
            if payload is not None and ti.name.endswith("VCam.dylib"):
                payload, n = patch_macho(payload)
                total += n
                ti.size = len(payload)
            dst.addfile(ti, io.BytesIO(payload) if payload is not None else None)
        dst.close()
        newraw = buf.getvalue()
        if name.endswith(".xz"):
            m[2] = lzma.compress(newraw, format=lzma.FORMAT_XZ)
        elif name.endswith(".lzma"):
            m[2] = lzma.compress(newraw, format=lzma.FORMAT_ALONE)
        elif name.endswith(".gz"):
            import gzip
            m[2] = gzip.compress(newraw, mtime=0)
        else:
            m[2] = newraw
        break
    open(path, "wb").write(write_ar(members))
    return total


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    for p in sys.argv[1:]:
        n = patch_deb(p)
        print(f"{p}: patched {n} header(s)")
