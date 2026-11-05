#!/bin/bash
# 用系统 clang(18)+ld64.lld 直接编译 VCam，绕开 theos 自带的老工具链：
#   - L1ghtmann 工具链是 clang 11，产出的 arm64e ObjC 元数据在 iOS 18 上 load 期 readClass trap
#   - 现代 clang 的 arm64e 代码/元数据是对的，但 SDK 里的 libc++ 太老，所以整个 TU 按纯 ObjC 编译
set -euo pipefail

THEOS=${THEOS:-$HOME/theos}
export PATH="/usr/bin:/usr/local/bin:$PATH"
export PATH="$PATH:$THEOS/toolchain/linux/iphone/bin:$THEOS/bin"   # lipo/otool 从这里来，clang 仍是系统的 18
SDK=${SDK:-$THEOS/sdks/iPhoneOS16.5.sdk}
OUT=${OUT:-build}
MIN=${MIN:-15.0}
CLANG=${CLANG:-/usr/bin/clang}

SUBINC=include                     # 自带的最小 substrate.h
echo "SDK=$SDK"; echo "substrate=$SUBINC/substrate.h"
"$CLANG" --version | head -1

rm -rf "$OUT"; mkdir -p "$OUT"
perl "$THEOS/bin/logos.pl" Tweak.xm > "$OUT/Tweak.m"
head -5 "$OUT/Tweak.m"

for A in arm64 arm64e; do
  mkdir -p "$OUT/$A"
  for SRC in "$OUT/Tweak.m" MediaManager.m; do
    OBJ="$OUT/$A/$(basename "${SRC%.*}").o"
    echo "==> $A $(basename "$SRC")"
    "$CLANG" -target "$A-apple-ios$MIN" -isysroot "$SDK" \
      -fobjc-arc -fblocks -O2 -fmodules -fmodules-cache-path="$OUT/modcache" \
      -I"$SUBINC" -I. -I"$OUT" \
      -c "$SRC" -o "$OBJ"
  done
  echo "==> link $A"
  "$CLANG" -target "$A-apple-ios$MIN" -isysroot "$SDK" -dynamiclib -fuse-ld=lld \
    -framework UIKit -framework AVFoundation -framework CoreMedia -framework CoreImage \
    -framework CoreVideo -framework ImageIO -framework QuartzCore -framework MobileCoreServices \
    -install_name /Library/MobileSubstrate/DynamicLibraries/VCam.dylib \
    -undefined dynamic_lookup \
    "$OUT/$A"/*.o -o "$OUT/$A/VCam.dylib"
done

echo "==> fat + sign"
python3 - <<'PY'
import struct, glob
for p in sorted(glob.glob("build/*/VCam.dylib")):
    d = open(p, "rb").read(12)
    print("  ", p, "cpu", hex(struct.unpack("<I", d[4:8])[0]), "sub", hex(struct.unpack("<I", d[8:12])[0]))
PY
python3 tools/fat.py "$OUT/VCam.dylib" "$OUT/arm64/VCam.dylib" "$OUT/arm64e/VCam.dylib"
LDid=$(command -v ldid || command -v "$THEOS/bin/ldid" || true)
[ -n "$LDid" ] && "$LDid" -S"$OUT/VCam.dylib" || echo "warn: ldid not found, skip signing"
python3 tools/fix_abi.py --dylib "$OUT/VCam.dylib"
ls -l "$OUT/VCam.dylib"
