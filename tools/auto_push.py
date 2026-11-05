#!/usr/bin/env python3
"""盯住 8899 的出片（或本地文件夹），一变就 USB 推到手机 DCIM。

手机上的 tweak 每 1.5 秒轮询 DCIM，所以推完约 2 秒内相机画面自动换掉，
不用重开相机、不用局域网。

  python auto_push.py                 # 盯 blink
  python auto_push.py blink nod       # 多个 key，哪个变推哪个
  python auto_push.py --dir D:/out    # 盯文件夹里最新的 mp4/mov
  python auto_push.py --once          # 只跑一遍（脚本化用）
  python auto_push.py --interval 2    # 轮询间隔秒
"""
import argparse
import hashlib
import json
import os
import sys
import time
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from push_clip import REMOTE, STUDIO, push  # noqa: E402

CLIP_EXTS = (".mp4", ".mov")


def http_bytes(url: str) -> bytes:
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(url, timeout=120) as r:
        return r.read()


def newest_in(d: str):
    best, best_t = None, 0.0
    for root, _, names in os.walk(d):
        for n in names:
            if not n.lower().endswith(CLIP_EXTS):
                continue
            p = os.path.join(root, n)
            t = os.path.getmtime(p)
            if t > best_t:
                best, best_t = p, t
    return best


def collect(args):
    """返回 [(名字, 取字节的函数)]，每次轮询都重新取。"""
    if args.dir:
        p = newest_in(args.dir)
        if not p:
            return []
        return [(os.path.basename(p), lambda: open(p, "rb").read())]
    return [(k, (lambda kk: lambda: http_bytes(f"{STUDIO}/clip/{kk}.mp4"))(k)) for k in args.keys]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("keys", nargs="*", default=["blink"])
    ap.add_argument("--dir", help="盯本地文件夹里最新的 mp4/mov")
    ap.add_argument("--interval", type=float, default=3.0)
    ap.add_argument("--once", action="store_true")
    ap.add_argument("--state", default=os.path.join(os.environ.get("TEMP", "."), "vcam_push_state.json"),
                    help="记住上次推过的内容，重启脚本也不会重复推")
    a = ap.parse_args()

    try:
        seen = json.load(open(a.state, encoding="utf-8"))
    except Exception:
        seen = {}
    pushed = 0
    while True:
        for name, get in collect(a):
            try:
                data = get()
            except Exception as e:                      # 8899 没起 / 文件被占用
                print(f"[skip] {name}: {e}")
                continue
            digest = hashlib.sha256(data).hexdigest()[:16]
            if seen.get(name) == digest:
                continue
            seen[name] = digest
            try:
                push_bytes(data)
                pushed += 1
                print(f"[{time.strftime('%H:%M:%S')}] pushed {name} {len(data)} B "
                      f"(sha {digest}, #{pushed}) -> {REMOTE}")
                try:
                    with open(a.state, "w", encoding="utf-8") as f:
                        json.dump(seen, f)
                except OSError:
                    pass
            except Exception as e:                      # 设备没插 / afc 失败 / OSError
                print(f"[retry] {name}: {e}")
                seen.pop(name, None)
        if a.once:
            break
        time.sleep(a.interval)
    return 0


def push_bytes(data: bytes) -> None:
    import tempfile
    fd, tmp = tempfile.mkstemp(suffix=".mp4", dir=os.environ.get("TEMP"))
    os.close(fd)
    try:
        with open(tmp, "wb") as f:
            f.write(data)
        push(tmp, REMOTE)
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass


if __name__ == "__main__":
    sys.exit(main())
