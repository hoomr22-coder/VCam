#!/usr/bin/env python3
"""按 theos rootless 的产物结构打 deb（不依赖 theos 的编译链）。

  python3 tools/make_deb.py --dylib build/VCam.dylib

产物：packages/com.yourname.vcam_<ver>_iphoneos-arm64.deb
布局：layout/* -> var/jb/*，dylib 与 filter 放 DynamicLibraries，脚本 755。
"""
import argparse
import gzip
import io
import lzma
import os
import shutil
import struct
import tarfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DYN = "var/jb/Library/MobileSubstrate/DynamicLibraries"


def add(tar, name, mode, data=None, path=None):
    ti = tarfile.TarInfo(name)
    ti.mode = mode
    ti.mtime = int(time.time())
    ti.uid = ti.gid = 0
    ti.uname = ti.gname = "root"
    if data is not None:
        ti.size = len(data)
        tar.addfile(ti, io.BytesIO(data))
    else:
        ti.size = os.path.getsize(path)
        with open(path, "rb") as f:
            tar.addfile(ti, f)


def build(files, is_dir):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.GNU_FORMAT) as t:
        for name in ("var", "var/jb", "var/jb/Library", "var/jb/Library/MobileSubstrate",
                     "var/jb/Library/MobileSubstrate/DynamicLibraries"):
            add(t, name, 0o755)
        for name, (mode, data) in files.items():
            add(t, name, mode, data=data)
    return buf.getvalue()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dylib", default="build/VCam.dylib")
    ap.add_argument("--out", default="packages")
    a = ap.parse_args()

    version = None
    for line in open(os.path.join(ROOT, "control"), encoding="utf-8"):
        if line.startswith("Version:"):
            version = line.split(":", 1)[1].strip()
    assert version, "control 里没有 Version"

    files = {}
    files[f"{DYN}/VCam.dylib"] = (0o755, open(os.path.join(ROOT, a.dylib), "rb").read())
    files[f"{DYN}/VCam.plist"] = (0o644, open(os.path.join(ROOT, "VCam.plist"), "rb").read())
    files[f"{DYN}/VCam.base"] = (0o644, open(os.path.join(ROOT, "layout/Library/MobileSubstrate/DynamicLibraries/VCam.base"), "rb").read())
    base = os.path.join(ROOT, "layout")
    for dirpath, _, names in os.walk(base):
        for n in names:
            src = os.path.join(dirpath, n)
            rel = os.path.relpath(src, base)
            if rel.startswith("DEBIAN"):
                continue
            mode = 0o755 if os.access(src, os.X_OK) else 0o644
            files[f"var/jb/{rel}"] = (mode, open(src, "rb").read())

    data_tar = build(files, False)
    data_lzma = lzma.compress(data_tar, format=lzma.FORMAT_ALONE)

    ctl = io.BytesIO()
    with tarfile.open(fileobj=ctl, mode="w", format=tarfile.GNU_FORMAT) as t:
        add(t, "./control", 0o644, data=open(os.path.join(ROOT, "control"), "rb").read())
        for s in ("postinst", "postrm", "prerm"):
            p = os.path.join(base, "DEBIAN", s)
            if os.path.exists(p):
                add(t, f"./{s}", 0o755, data=open(p, "rb").read())
    control_gz = gzip.compress(ctl.getvalue(), mtime=0)

    os.makedirs(os.path.join(ROOT, a.out), exist_ok=True)
    out = os.path.join(ROOT, a.out, f"com.yourname.vcam_{version}_iphoneos-arm64.deb")

    def ar_member(name, data):
        hdr = "{:<16}{:<12}{:<6}{:<6}{:<8}{:<10}`\n".format(
            name, int(time.time()), 0, 0, "100644", len(data)).encode()
        return hdr + data + (b"\n" if len(data) % 2 else b"")

    with open(out, "wb") as f:
        f.write(b"!<arch>\n")
        f.write(ar_member("debian-binary", b"2.0\n"))
        f.write(ar_member("control.tar.gz", control_gz))
        f.write(ar_member("data.tar.lzma", data_lzma))
    print(out, os.path.getsize(out), "bytes,", len(files), "files")


if __name__ == "__main__":
    main()
