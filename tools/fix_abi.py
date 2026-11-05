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
        PAC = b"\x7f\x23\x03\xd5"                            # pacibsp
        for i in range(n):
            base = 8 + i * 20
            cpu, sub, off, size = struct.unpack(">iIII", d[base:base + 16])
            if cpu != 0x0100000C or size > len(d) - off:      # 只改 arm64e
                continue
            if sub not in (2, ARM64E_ABI2):                   # 0 = 普通 arm64，别动
                continue
            # 头部必须和代码一致：带 ptrauth 指令才是 ABI v2，否则是 v1
            want = ARM64E_ABI2 if PAC in d[off:off + size] else 2
            if sub != want:
                d[base + 4:base + 8] = struct.pack(">I", want)
                d[off + 8:off + 12] = struct.pack("<I", want)
                fixed += 1
    elif struct.unpack("<I", d[:4])[0] == 0xFEEDFACF:        # thin
        cur = struct.unpack("<I", d[8:12])[0]
        if cur not in (2, ARM64E_ABI2):                       # 只碰 arm64e；arm64 的 subtype 是 0
            return blob, 0
        want = ARM64E_ABI2 if b"\x7f\x23\x03\xd5" in d else 2
        if cur != want:
            d[8:12] = struct.pack("<I", want)
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
    args = sys.argv[1:]
    if args and args[0] == "--force-arm64e":
        for p in args[1:]:
            blob = bytearray(open(p, "rb").read())
            want = ARM64E_ABI2 if b"#Õ" in blob else 2
            old = struct.unpack("<I", blob[8:12])[0]
            blob[8:12] = struct.pack("<I", want)
            open(p, "wb").write(blob)
            print(f"{p}: subtype {hex(old)} -> {hex(want)}")
        sys.exit(0)
    if args and args[0] == "--dylib":
        for p in args[1:]:
            blob = open(p, "rb").read()
            out, n = patch_macho(blob)
            if n:
                open(p, "wb").write(out)
            print(f"{p}: patched {n} header(s)")
        sys.exit(0)
    if not args:
        sys.exit(__doc__)
    for p in args:
        n = patch_deb(p)
        print(f"{p}: patched {n} header(s)")
