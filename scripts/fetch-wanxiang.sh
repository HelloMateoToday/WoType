#!/usr/bin/env bash
# 下载万象拼音官方发布的标准版方案（rime-wanxiang-base.zip），解到 data/rime/wanxiang/（docs/22）。
# 这是 librime 的共享数据目录：方案、词库、Lua 脚本都在里面，App 打包时拷进 Resources/Data/rime/。
#
#   scripts/fetch-wanxiang.sh
#
# 版本和校验值写死在下面，升级时一起改。可以重复运行：已经解好、版本对得上就跳过。
# 语法模型（wanxiang-lts-zh-hans.gram，约 400 MB）不在这里，App 里按需下载。
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=v18.1.13
# 发布日期：App 里判断在线词库（万象数据仓库每天发布）比随包的新没有（RimeLexiconUpdater）
DATE=2026-11-14
ASSET=rime-wanxiang-base.zip
SHA256=2a94c48aa51eab2de20b4fdc89e065c05c828875b2bb3336a680f7c140ef088d
URL="https://github.com/amzxyz/rime-wanxiang/releases/download/$VERSION/$ASSET"
DEST=data/rime/wanxiang

# 修补万象的 Lua（每次都跑，改过的不再改）：
# auto_phrase.lua 在开着用户词库时另建一个 Memory 指向同一个 wanxiang 词库，librime 的 Memory 建好就接上删词事件，
# 删一个候选会处理两遍：第二遍删掉删完后排第一的那个（2026-11-15 用 rime-probe 实测，见 docs/22）。
# 它只拿这个 Memory 写词（学词靠自己接的上屏事件），断开 Memory 自带的连接就好。升级后对不上就报错，要重新看一遍
patch_lua() {
  local file="$DEST/lua/wanxiang/auto_phrase.lua"
  local line='        env.memory = Memory(env.engine, env.engine.schema)'
  grep -q 'env.memory:disconnect() -- WoType' "$file" && return
  [ "$(grep -cxF "$line" "$file")" = 1 ] || { echo "auto_phrase.lua 对不上，修补没打上（万象升级后要重新看）" >&2; exit 1; }
  awk -v line="$line" '{ print } $0 == line { print "        env.memory:disconnect() -- WoType：删词时别再删一遍" }' "$file" >"$file.tmp"
  mv "$file.tmp" "$file"
  echo "修补 auto_phrase.lua：删词不再多删一个"
}

if [ -f "$DEST/.release" ] && [ "$(cat "$DEST/.release")" = "$VERSION $ASSET $DATE" ]; then
  patch_lua
  echo "万象 $VERSION 已在 $DEST"
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

rm -rf "$DEST"
mkdir -p "$DEST"
unzip -q "$tmp/$ASSET" -d "$DEST"
# 用不上的：九键方案、小狼毫（Windows）的配置、给 AI 助手看的说明
rm -f "$DEST"/*_t9*.yaml "$DEST/weasel.yaml" "$DEST/AGENTS.md"
patch_lua
echo "$VERSION $ASSET $DATE" >"$DEST/.release"
echo "万象 $VERSION → ${DEST}（$(du -sh "$DEST" | cut -f1)）"
