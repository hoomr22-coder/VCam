#!/usr/bin/env python3
"""把 8899 的出片推到 iPhone 的 DCIM，相机里点「载入 DCIM 最新片段」即可用。

  python push_clip.py            # 默认 blink
  python push_clip.py nod        # 换动作
  python push_clip.py --file x.mp4

走 AFC（/var/mobile/Media/DCIM），不需要局域网、不需要 App 有网络权限。
"""
import argparse
import os
import subprocess
import sys
import tempfile
import urllib.request

STUDIO = os.environ.get("VCAM_STUDIO", "http://127.0.0.1:8899")
PYMOB = os.environ.get("VCAM_PYMOB", r"C:\Users\222\hermes-tmp\iosjb\pyidev\Scripts\python.exe")
REMOTE = "/DCIM/VCamVirtual.mp4"


def fetch(key: str, out: str) -> int:
    url = f"{STUDIO}/clip/{key}.mp4"
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(url, timeout=600) as r:
        data = r.read()
    if len(data) < 10_000:
        raise SystemExit(f"studio 返回过小：{len(data)}B（key={key} 可能不在 actions.json 里）")
    with open(out, "wb") as f:
        f.write(data)
    return len(data)


def push(local: str, remote: str = REMOTE) -> None:
    cmd = [PYMOB, "-m", "pymobiledevice3", "afc", "push", local, remote]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit("afc push 失败：\n" + (r.stderr or r.stdout)[-600:])


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("key", nargs="?", default="blink")
    ap.add_argument("--file", help="已有文件，跳过 8899 下载")
    ap.add_argument("--remote", default=REMOTE)
    a = ap.parse_args()

    if a.file:
        n = os.path.getsize(a.file)
        local = a.file
    else:
        local = os.path.join(tempfile.gettempdir(), "vcam_push.mp4")
        n = fetch(a.key, local)
    push(local, a.remote)
    print(f"pushed {n} B -> {a.remote}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
