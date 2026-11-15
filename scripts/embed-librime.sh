#!/usr/bin/env bash
# 把 librime 和它的插件放进 App 包（Xcode 的「Embed librime」脚本阶段调用，docs/22）。
#
#   scripts/embed-librime.sh <App 包路径>
#
# 放的位置：Contents/Frameworks/librime.1.dylib，插件在 Contents/Frameworks/rime-plugins/（librime 从自己旁边的
# 这个目录载插件）。RimeEngine 运行时 dlopen，不在编译时链接。
# hardened runtime 下插件要和主程序同一个证书：这里用 Xcode 这次签名的证书签（Debug 是临时签名 -），
# scripts/install-dev.sh 重签时再用开发证书签一遍。
set -euo pipefail
cd "$(dirname "$0")/.."

APP=${1:?用法：embed-librime.sh <App 包路径>}
[[ -f build/librime/VERSION ]] || scripts/fetch-librime.sh

DEST="$APP/Contents/Frameworks"
mkdir -p "$DEST/rime-plugins"
rsync -a build/librime/lib/librime.1.dylib "$DEST/"
rsync -a --delete build/librime/lib/rime-plugins/ "$DEST/rime-plugins/"
# 官方包是通用二进制；Release 只发 arm64（工程的 ARCHS），去掉 x86_64
if [[ "${CONFIGURATION:-}" == Release ]]; then
  for dylib in "$DEST"/rime-plugins/*.dylib "$DEST/librime.1.dylib"; do
    lipo -archs "$dylib" | grep -qw x86_64 && lipo "$dylib" -thin arm64 -output "$dylib.thin" && mv -f "$dylib.thin" "$dylib"
  done
fi

IDENTITY=${EXPANDED_CODE_SIGN_IDENTITY:--}
[[ -n "$IDENTITY" ]] || IDENTITY=-
for dylib in "$DEST"/rime-plugins/*.dylib "$DEST/librime.1.dylib"; do
  codesign --force --sign "$IDENTITY" --timestamp=none "$dylib"
done
