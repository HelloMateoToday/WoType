#!/usr/bin/env bash
# 把只读数据和许可证拷进 App 包（Xcode 的「Copy lexicon data」脚本阶段调用）。
#
#   scripts/copy-data.sh <App 包里的 Resources/Data 目录>
#
# 水杉的词库和逐键小模型由 scripts/fetch-msime-data.sh 下载到 data/msime/resources/（docs/12）。
# 万象的方案（librime 的共享目录）由 scripts/prebuild-rime.sh 预编译到 build/rime/wanxiang/，拷到 Data/rime/（docs/22）。
# 旧的万象引擎（docs/15）不编译了，它的词库 data/lexicon.tsv 不再打包；恢复见 docs/22 末尾。
set -euo pipefail
cd "$(dirname "$0")/.."

DEST=${1:?用法：copy-data.sh <目标目录>}
mkdir -p "$DEST"

[[ -f data/msime/resources/msime-pinyin.db ]] || scripts/fetch-msime-data.sh
# 旧版本直接放在 Data/ 下的数据、旧万象的 Data/wanxiang/ 删掉，只留两个引擎各自的目录
find "$DEST" -mindepth 1 -maxdepth 1 ! -name msime ! -name rime -exec rm -rf {} +
# 目录要和水杉的资源锁一一对应，所以整个同步
mkdir -p "$DEST/msime/resources"
rsync -a --delete data/msime/resources/ "$DEST/msime/resources/"

# 万象：方案、词库、Lua 脚本和预编译好的 build/
scripts/prebuild-rime.sh
mkdir -p "$DEST/rime"
rsync -a --delete build/rime/wanxiang/ "$DEST/rime/"

# 许可证放在 Resources/Licenses（scripts/build-rust.sh 收集的）
if [[ ! -f build/rust/Licenses/GPL-3.0.txt ]]; then
  echo "error: 没有 build/rust/Licenses，请先运行 scripts/build-rust.sh" >&2
  exit 1
fi
mkdir -p "$DEST/../Licenses"
rsync -a --delete build/rust/Licenses/ "$DEST/../Licenses/"
# 万象方案（CC BY 4.0）：出处、版本、改了什么和许可证全文放在一起
read -r wanxiang_version wanxiang_asset wanxiang_date < data/rime/wanxiang/.release
{
  echo "万象拼音方案 rime-wanxiang（https://github.com/amzxyz/rime-wanxiang），作者 amzxyz，许可证 CC BY 4.0（全文见下）。"
  echo "版本：${wanxiang_version}（${wanxiang_date} 发布的 ${wanxiang_asset}，标准版）。"
  echo "WoType 的改动：去掉九键方案、小狼毫配置、示例配置和说明（scripts/fetch-wanxiang.sh、scripts/prebuild-rime.sh），"
  echo "打包时用 librime 预编译词库；设置写成 *.custom.yaml 补丁放在用户目录，不改方案文件。"
  echo "改了一行 Lua：lua/wanxiang/auto_phrase.lua 建好 Memory 后断开它自带的事件连接（删候选时不再多删一个）。"
  echo "在线更新的词库下载自 rime-wanxiang-data（https://github.com/amzxyz/rime-wanxiang-data），语法模型"
  echo "wanxiang-lts-zh-hans.gram 下载自 RIME-LMDG（https://github.com/amzxyz/RIME-LMDG），都是 CC BY 4.0，不随 App 分发。"
  echo
  cat licenses/CC-BY-4.0.txt
} > "$DEST/../Licenses/rime-wanxiang-scheme-CC-BY-4.0.txt"
