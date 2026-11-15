#!/usr/bin/env bash
# 下载 librime 官方 macOS 发布包（含 lua、octagram、predict 三个插件），解到 build/librime/（docs/22）。
#
#   scripts/fetch-librime.sh
#
# 版本和校验值写死在下面，升级时一起改。可以重复运行：已经解好、版本对得上就跳过。
# 解出来的布局：
#   build/librime/include/rime_api.h …
#   build/librime/lib/librime.1.dylib             App 里放 Contents/Frameworks/
#   build/librime/lib/rime-plugins/*.dylib        App 里放 Contents/Frameworks/rime-plugins/（librime 从自己旁边的这个目录载插件）
#   build/librime/bin/rime_deployer               打包时预先编译万象方案
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=1.17.0
ASSET=rime-33e7814-macOS-universal.tar.bz2
SHA256=11d8dc663c6ec06d5ccb6111ba664a9e7b631b703ac6acd07cffbac664021850
URL="https://github.com/rime/librime/releases/download/$VERSION/$ASSET"
DEST=build/librime

# 官方包的 rime_deployer 等工具没写 rpath，找不到旁边 lib/ 里的 librime.1.dylib，一运行就崩（Abort trap: 6）。
# 补上 @executable_path/../lib；改了二进制签名就失效了，重新临时签名（arm64 不认没签名的程序）
fix_rpath() {
  for tool in "$DEST"/bin/*; do
    otool -l "$tool" | grep -q '@executable_path/../lib' && continue
    install_name_tool -add_rpath @executable_path/../lib "$tool"
    codesign --force --sign - "$tool"
  done
}

if [ -f "$DEST/VERSION" ] && [ "$(cat "$DEST/VERSION")" = "$ASSET" ]; then
  fix_rpath
  echo "librime $VERSION 已在 $DEST"
  exit 0
fi

# curl 不读系统代理：没设 https_proxy 时用系统设置里的 HTTPS 代理（GitHub 的发布文件服务器直连常常不通）
if [ -z "${https_proxy:-}${HTTPS_PROXY:-}" ]; then
  proxy=$(scutil --proxy | awk '/HTTPSEnable : 1/{on=1} /HTTPSProxy :/{h=$3} /HTTPSPort :/{p=$3} END{if (on && h && p) print "http://" h ":" p}')
  if [ -n "$proxy" ]; then
    export https_proxy=$proxy http_proxy=$proxy
  fi
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
echo "下载 $URL"
curl -fL --retry 3 -o "$tmp/$ASSET" "$URL"
echo "$SHA256  $tmp/$ASSET" | shasum -a 256 -c - >/dev/null || { echo "$ASSET 校验不对" >&2; exit 1; }
mkdir -p "$tmp/x"
tar xjf "$tmp/$ASSET" -C "$tmp/x"

rm -rf "$DEST"
mkdir -p "$DEST/lib/rime-plugins"
cp -R "$tmp/x/dist/include" "$DEST/"
cp -R "$tmp/x/dist/bin" "$DEST/"
cp "$tmp/x/dist/lib/librime.$VERSION.dylib" "$DEST/lib/librime.1.dylib"
cp "$tmp/x/dist/lib/rime-plugins/"*.dylib "$DEST/lib/rime-plugins/"
cp "$tmp/x/version-info.txt" "$DEST/" 2>/dev/null || true
fix_rpath
echo "$ASSET" >"$DEST/VERSION"
echo "librime $VERSION → $DEST"
