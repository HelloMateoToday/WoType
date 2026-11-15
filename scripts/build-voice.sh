#!/usr/bin/env bash
# 编译语音识别的小程序 WoType Voice（WoType/VoiceService），放进 App 包（docs/10 第 5 节）。
#
#   scripts/build-voice.sh <App 包路径>
#
# Xcode 的「Build WoType Voice」脚本阶段调用它。
# - 只编 arm64：MLX 只支持 Apple Silicon，Intel Mac 上没有语音输入；
# - 必须用 xcodebuild：swift build 编不出 MLX 的 Metal 着色器（default.metallib）；
# - mlx-swift-lm 带宏，命令行编译要 -skipMacroValidation；
# - 放的位置：可执行文件在 Contents/MacOS/wotype-voice，资源包在 Contents/Resources/。
#   MLX 按 ../Resources/mlx-swift_Cmlx.bundle 找着色器，SwiftPM 的资源包按 Bundle.main.resourceURL 找。
set -euo pipefail
cd "$(dirname "$0")/.."

APP=${1:?用法：build-voice.sh <App 包路径>}
DERIVED=build/VoiceService
PRODUCTS="$DERIVED/Build/Products/Release"

# MLX 的着色器用 Metal 工具链编译，它挂在 /var/run/com.apple.security.cryptexd/mnt/…MetalToolchain-<随机后缀>，
# 重启或升级 Xcode 后后缀会变，构建缓存却还记着旧路径（unable to spawn process …/metal）。
# 缓存里的挂载路径和现在的不一样时，删掉构建缓存让 xcodebuild 重新生成（编好的产物还在，不用全部重编）
BUILD_DATA="$DERIVED/Build/Intermediates.noindex/XCBuildData"
METAL_MOUNT=$(xcrun -f metal 2>/dev/null | grep -o 'MobileAsset\.MetalToolchain-[^/]*' || true)
if [[ -n "$METAL_MOUNT" && -d "$BUILD_DATA" ]] &&
   grep -rhoa 'MobileAsset\.MetalToolchain-[A-Za-z0-9.]*' "$BUILD_DATA" 2>/dev/null | grep -qv "^$METAL_MOUNT\$"; then
  echo "Metal 工具链换了挂载位置（现在是 ${METAL_MOUNT}），清掉语音的构建缓存"
  rm -rf "$BUILD_DATA"
fi

# Xcode 的脚本阶段带进来的编译变量（SDKROOT、ARCHS、CONFIGURATION_BUILD_DIR…）会干扰里面这次 xcodebuild，
# 用 env -i 只留最基本的几个
(cd WoType/VoiceService && env -i PATH="/usr/bin:/bin:/usr/sbin:/sbin" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
  xcodebuild -scheme WoTypeVoice -configuration Release \
    -destination "platform=macOS,arch=arm64" -derivedDataPath "../../$DERIVED" -skipMacroValidation build)

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -f "$PRODUCTS/wotype-voice" "$APP/Contents/MacOS/wotype-voice"
for bundle in "$PRODUCTS"/*.bundle; do
  rsync -a --delete "$bundle" "$APP/Contents/Resources/"
done
