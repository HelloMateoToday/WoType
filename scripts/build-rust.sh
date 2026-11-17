#!/usr/bin/env bash
# 编译 Rust 核心静态库，给 Xcode 链接。
#
#   scripts/build-rust.sh [Debug|Release]
#
# 产物：build/rust/<配置>/libwotype_core.a
#   Debug    只编本机架构
#   Release  只编 arm64（App 只发 Apple 芯片版：语音服务只有 arm64）
# 两种配置的 Rust 都用 release 档编译：debug 档载入 55 万条词库太慢，没法试打。
#
# Xcode 的「Build Rust core」脚本阶段会调用它（CONFIGURATION 由 Xcode 传入）。
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=${1:-${CONFIGURATION:-Debug}}
OUT="build/rust/$CONFIG"
mkdir -p "$OUT"

# Xcode 的脚本阶段继承的 PATH 里没有 cargo；Xcode 设的 SDK 变量会干扰 Rust 的链接，清掉
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
unset SDKROOT MACOSX_DEPLOYMENT_TARGET LIBRARY_PATH
# 水杉的依赖里有 C 代码（ring、SQLite），编译要找得到 macOS SDK 的头文件
SDKROOT=$(xcrun --sdk macosx --show-sdk-path)
export SDKROOT
# 不设 MACOSX_DEPLOYMENT_TARGET：它同时管着本机跑的 proc-macro 动态库，设成 13 及以上时
# Xcode 27 的 ld（ld-27106）链出来的动态库 dyld 加载不了（mis-aligned LINKEDIT string pool），
# 编译报 can't find crate for `zerofrom_derive` 之类（2026-11-17）。不设时 Rust 默认 11.0，
# 比工程的 14.0 低，静态库照样链得进 App

host=$(uname -m)
case "$host" in
  arm64) host_target=aarch64-apple-darwin ;;
  x86_64) host_target=x86_64-apple-darwin ;;
  *) echo "不认识的架构 $host" >&2; exit 1 ;;
esac

if [[ "$CONFIG" == "Release" ]]; then
  targets=(aarch64-apple-darwin)
else
  targets=("$host_target")
fi

libs=()
for target in "${targets[@]}"; do
  rustup target list --installed | grep -qx "$target" || rustup target add "$target"
  cargo build --manifest-path engine/Cargo.toml --release -p wotype-core --lib --target "$target"
  libs+=("engine/target/$target/release/libwotype_core.a")
done

if (( ${#libs[@]} == 1 )); then
  cp -f "${libs[0]}" "$OUT/libwotype_core.a"
else
  lipo -create "${libs[@]}" -output "$OUT/libwotype_core.a"
fi
echo "Rust 核心 -> $OUT/libwotype_core.a（${targets[*]}）"

# 水杉宿主层的头文件在 cargo 拉下来的 git 依赖里，按锁定的版本复制出来给 Swift 用（桥接头文件 include 它）
host_api=$(cargo metadata --manifest-path engine/Cargo.toml --format-version 1 --locked |
  /usr/bin/python3 -I -c 'import json,sys; print(next(p["manifest_path"] for p in json.load(sys.stdin)["packages"] if p["name"] == "msime-host-api"))')
mkdir -p build/rust/include
cp -f "$(dirname "$host_api")/include/msime_client.h" build/rust/include/
echo "水杉头文件 -> build/rust/include/msime_client.h"

# 随 App 分发的许可证：WoType 自己的、水杉的、链接进来的 Rust crate 的（copy-data.sh 拷进 App 包）
/usr/bin/python3 -I scripts/collect-licenses.py engine/Cargo.toml build/rust/Licenses
