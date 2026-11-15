#!/usr/bin/env bash
# 打安装包：Release 构建 → 签名 → 包成「安装 WoType.app」→ 做成 DMG（docs/19）。
#
#   scripts/make-installer.sh [--no-build] [--notarize]
#
# 产物：build/Installer/WoType-<版本>-<构建号>.dmg，里面只有「安装 WoType.app」，要装的 WoType.app 在它的 Contents/Library/ 里。
# 构建号是编译时的时间（年月日时分，如 202611132050），写进 WoType 和安装器的 CFBundleVersion：
# 同一个版本号打了好几次包，看文件名就知道哪个新，安装器也按它判断「更新」。旧的安装包不覆盖
# --no-build  不重新编译，用上次编好的（构建号也是上次的）
# --notarize  提交公证并 staple。要先存好凭据：xcrun notarytool store-credentials "WoType-notary"
#             （profile 名字可用 WOTYPE_NOTARY_PROFILE 改）
# WOTYPE_SIGN_IDENTITY 可指定证书，默认钥匙串里第一张 Developer ID Application。
# 没有 Developer ID 证书也能打包：改用临时签名（ad-hoc），不能公证。
#
# 不公证的 DMG 在本机打开没问题（不是下载来的，系统不拦）；发给别人的话，对方下载后要先去掉隔离属性：
#   xattr -cr ~/Downloads/WoType-*.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD=1
NOTARIZE=
for arg in "$@"; do
  case "$arg" in
    --no-build) BUILD= ;;
    --notarize) NOTARIZE=1 ;;
    *) echo "不认识的参数 $arg" >&2; exit 2 ;;
  esac
done
NOTARY_PROFILE=${WOTYPE_NOTARY_PROFILE:-WoType-notary}

IDENTITY=${WOTYPE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application[^"]*\)".*/\1/p' | head -1)}
if [[ -z "$IDENTITY" ]]; then
  IDENTITY=-
  echo "没找到 Developer ID Application 证书，用临时签名（ad-hoc）打包（WOTYPE_SIGN_IDENTITY 可指定证书）"
fi
# 临时签名：不公证，也就不要 hardened runtime 和时间戳（时间戳要连苹果的服务器、只认证书签名）
if [[ "$IDENTITY" == - ]]; then
  if [[ -n "$NOTARIZE" ]]; then
    echo "临时签名不能公证，--notarize 要 Developer ID Application 证书" >&2
    exit 1
  fi
  SIGN_FLAGS=(--timestamp=none)
else
  SIGN_FLAGS=(--options runtime --timestamp)
fi

if [[ -n "$BUILD" ]]; then
  # 限制并行数，别把机器占满。Release 只编 arm64（工程的 ARCHS、build-rust.sh）
  export CARGO_BUILD_JOBS=${CARGO_BUILD_JOBS:-4}
  BUILD_NUMBER=$(date +%Y%m%d%H%M)
  # 词库在 Xcode 的脚本阶段也会准备，先在这里下好：下载进度、失败直接看得到
  echo "==> 准备词库（水杉、万象、librime，已经下好的跳过）"
  scripts/fetch-msime-data.sh
  scripts/prebuild-rime.sh
  echo "==> 编译 WoType（Release；第一次要编 Rust 核心和语音服务，约 15 分钟）"
  # xcodebuild 的原始输出太长：完整的写进日志，终端只显示正在编的文件和各步骤的结果
  mkdir -p build/Installer
  LOG=build/Installer/xcodebuild.log
  # 关掉代码覆盖率：scheme 的测试开着覆盖率，Xcode 编 build 时也会加 -profile-generate，
  # 编出来的 WoType 带插桩（运行变慢，还到处写 default.profraw）
  if ! xcodebuild -project WoType/WoType.xcodeproj -scheme WoType -configuration Release \
      -destination "platform=macOS,arch=arm64" -derivedDataPath build/DerivedData -jobs 4 \
      CLANG_COVERAGE_MAPPING=NO CLANG_ENABLE_CODE_COVERAGE=NO CURRENT_PROJECT_VERSION="$BUILD_NUMBER" build 2>&1 |
      tee "$LOG" | awk '
        /^PhaseScriptExecution / { name = $0; sub(/^PhaseScriptExecution /, "", name); sub(/ \/.*/, "", name)
                                   gsub(/\\ /, " ", name); print "  ▸ " name; fflush(); next }
        /^ *(Compiling|Finished) [^ ]+/ { sub(/^ */, ""); print "    " $0; fflush(); next }   # cargo
        /^(SwiftCompile|CompileC) / && match($0, /[^\/ ]+\.(swift|c|m|mm|cpp) /) {
                                   file = substr($0, RSTART, RLENGTH - 1)     # Xcode 每个文件会报两行，只显示一次
                                   if (!(file in seen)) { seen[file] = 1; print "    编译 " file; fflush() }; next }
        /^[0-9 ]*\|/ { next }                                            # 编译警告里引用的源代码
        /^[^ ].*(-> |→ )|^下载 |预编译/ { print "    " $0; fflush(); next }   # 各脚本自己的提示
        /error:|\*\* BUILD (SUCCEEDED|FAILED) \*\*/ { print "  " $0; fflush() }'; then
    echo "编译失败。错误："
    grep -E "error:" "$LOG" | sort -u | tail -20
    echo "完整日志：$LOG"
    exit 1
  fi
  echo "==> 编译安装器"
  swift build --package-path WoType/WoTypeInstaller -c release --scratch-path build/WoTypeInstaller -j 4
fi

APP=build/DerivedData/Build/Products/Release/WoType.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP/Contents/Info.plist")
OUT=build/Installer
STAGE="$OUT/dmg"
INSTALLER="$STAGE/安装 WoType.app"
PAYLOAD="$INSTALLER/Contents/Library/WoType.app"

echo "==> 签名、打包"
rm -rf "$STAGE"
mkdir -p "$INSTALLER/Contents/MacOS" "$INSTALLER/Contents/Resources" "$INSTALLER/Contents/Library"
cp build/WoTypeInstaller/release/WoTypeInstaller "$INSTALLER/Contents/MacOS/"
cat > "$INSTALLER/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>zh_CN</string>
	<key>CFBundleDisplayName</key>
	<string>安装 WoType</string>
	<key>CFBundleExecutable</key>
	<string>WoTypeInstaller</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>com.acme.inputmethod.WoTypeInstaller</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>安装 WoType</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$BUILD_NUMBER</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.utilities</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
EOF

# 图标用 WoType 的 AppIcon（appiconset 里的文件名正好是 iconutil 要的）
ICONSET="$OUT/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
cp WoType/WoType/Assets.xcassets/AppIcon.appiconset/icon_*.png "$ICONSET/"
iconutil -c icns "$ICONSET" -o "$INSTALLER/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# 要装的 WoType.app。default.profraw 是源码目录里的覆盖率统计残留（跑测试时写的），被同步文件夹带进了 App 包
rsync -a --delete --exclude default.profraw "$APP/" "$PAYLOAD/"

# 签名从里往外：语音小程序 → WoType.app → 安装器 → DMG。公证要 hardened runtime 和时间戳。
# 不写指定要求：Developer ID 默认的是「Bundle ID + 团队」，换版本还是同一个程序，给过的权限不丢
sign() { codesign --force --sign "$IDENTITY" "${SIGN_FLAGS[@]}" "$@"; }
[[ -f "$PAYLOAD/Contents/MacOS/wotype-voice" ]] && sign "$PAYLOAD/Contents/MacOS/wotype-voice"
for dylib in "$PAYLOAD"/Contents/MacOS/*.dylib "$PAYLOAD"/Contents/Frameworks/rime-plugins/*.dylib "$PAYLOAD"/Contents/Frameworks/*.dylib; do
  [[ -f "$dylib" ]] && sign "$dylib"
done
sign --entitlements WoType/WoType/WoType.entitlements "$PAYLOAD"
sign "$INSTALLER"
codesign --verify --deep --strict "$INSTALLER"
if nm "$PAYLOAD/Contents/MacOS/WoType" | grep -q __llvm_profile; then
  echo "WoType 带着覆盖率插桩，不能发布" >&2
  exit 1
fi

DMG="$OUT/WoType-$VERSION-$BUILD_NUMBER.dmg"
rm -f "$DMG"
hdiutil create -volname "WoType $VERSION ($BUILD_NUMBER)" -srcfolder "$STAGE" -fs HFS+ -format ULFO -ov "$DMG" -quiet
[[ "$IDENTITY" == - ]] || codesign --force --sign "$IDENTITY" --timestamp "$DMG"

if [[ -n "$NOTARIZE" ]]; then
  echo "==> 公证"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

echo "==> 完成，用时 $((SECONDS / 60)) 分 $((SECONDS % 60)) 秒"
echo "安装包：${DMG}（$(du -h "$DMG" | cut -f1)，${IDENTITY/#-/临时签名}${NOTARIZE:+，已公证}）"
