#!/usr/bin/env bash
# 预先编译万象方案的词库，产物在 build/rime/wanxiang/（方案文件 + build/），copy-data.sh 拷进 App 包（docs/22）。
#
#   scripts/prebuild-rime.sh
#
# 在输入法进程里从头编译要 9 秒、峰值 1.1 GB 内存，所以打包时用 librime 的 rime_deployer 编好；
# App 里 librime 发现共享目录的 build/ 是最新的就直接用（首次启动 0.2 秒）。
# 万象和 librime 的版本都没变就跳过。
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -f build/librime/VERSION ]] || scripts/fetch-librime.sh
[[ -f data/rime/wanxiang/.release ]] || scripts/fetch-wanxiang.sh

OUT=build/rime/wanxiang
stamp="$(cat data/rime/wanxiang/.release) / $(cat build/librime/VERSION)"
if [[ -f "$OUT/.prebuilt" && "$(cat "$OUT/.prebuilt")" == "$stamp" ]]; then
  # Lua 不编译，每次照拷：fetch-wanxiang.sh 的修补改了也能带上
  rsync -a --delete data/rime/wanxiang/lua/ "$OUT/lua/"
  exit 0
fi

echo "预编译万象方案（约 10 秒）"
rm -rf "$OUT"
mkdir -p "$OUT"
# 用不上的：示例配置和图片、说明
rsync -a --exclude custom --exclude README.md data/rime/wanxiang/ "$OUT/"
user=$(mktemp -d)
trap 'rm -rf "$user"' EXIT
build/librime/bin/rime_deployer --build "$user" "$OUT" "$OUT/build" >"$user/deployer.log" 2>&1 || {
  echo "error: rime_deployer 编译万象方案失败：" >&2
  tail -20 "$user/deployer.log" >&2
  exit 1
}
[[ -f "$OUT/build/wanxiang.table.bin" ]] || { echo "error: 预编译结果里没有 wanxiang.table.bin" >&2; exit 1; }
echo "$stamp" >"$OUT/.prebuilt"
echo "万象方案预编译好了 → ${OUT}（$(du -sh "$OUT" | cut -f1)）"
