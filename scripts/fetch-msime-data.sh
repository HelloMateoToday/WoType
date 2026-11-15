#!/usr/bin/env bash
# 下载随 App 打包的水杉词库和逐键小模型，放进 data/msime/resources/（docs/12）。
#
#   scripts/fetch-msime-data.sh
#
# 清单不写死在这里：读 engine/Cargo.lock 锁定的水杉源码里的 resources/editions/pinyin.lock.json
# （水杉「拼音版」的资源锁，只有全拼和双拼），所以升级水杉的 commit 后重跑一次，词库版本自动跟着变。
# macOS 上可以缺席的五笔码表和日文词典不下载（水杉的 on_demand_artifacts("macos")）。
# 可以重复运行：已经下好且校验通过的文件跳过。
set -euo pipefail
cd "$(dirname "$0")/.."

# curl 不读系统代理：没设 https_proxy 时用系统设置里的 HTTPS 代理（GitHub 的发布文件服务器直连常常不通）
if [ -z "${https_proxy:-}${HTTPS_PROXY:-}" ]; then
  proxy=$(scutil --proxy | awk '/HTTPSEnable : 1/{on=1} /HTTPSProxy :/{h=$3} /HTTPSPort :/{p=$3} END{if (on && h && p) print "http://" h ":" p}')
  if [ -n "$proxy" ]; then
    export https_proxy=$proxy http_proxy=$proxy
  fi
fi

export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
host_api=$(cargo metadata --manifest-path engine/Cargo.toml --format-version 1 --locked |
  /usr/bin/python3 -I -c 'import json,sys; print(next(p["manifest_path"] for p in json.load(sys.stdin)["packages"] if p["name"] == "msime-host-api"))')
lock="$(dirname "$host_api")/../../resources/editions/pinyin.lock.json"
[ -f "$lock" ] || { echo "找不到水杉的资源锁 $lock" >&2; exit 1; }

DEST=data/msime/resources
mkdir -p "$DEST"

# 每行：文件名 sha256 下载地址
/usr/bin/python3 -I - "$lock" <<'EOF' >"$DEST/.manifest"
import json, sys
skip = {"msime-wubi.db", "msime-japanese.dat", "msime-mozc_dictionary_oss_README.txt", "msime-mozc_LICENSE.txt"}
for artifact in json.load(open(sys.argv[1]))["artifacts"]:
    if artifact["name"] not in skip:
        print(artifact["name"], artifact["sha256"], artifact["url"])
EOF

failed=0
while read -r name sha url; do
  path="$DEST/$name"
  if [ -f "$path" ] && [ "$(shasum -a 256 "$path" | cut -d' ' -f1)" = "$sha" ]; then
    echo "已有 $name"
    continue
  fi
  echo "下载 $name"
  curl -fL -# --retry 3 -o "$path.part" "$url"
  mv "$path.part" "$path"
  if [ "$(shasum -a 256 "$path" | cut -d' ' -f1)" != "$sha" ]; then
    echo "校验失败 $name" >&2
    failed=1
  fi
done <"$DEST/.manifest"

# 锁里没有的旧文件删掉：水杉校验资源目录时要求和锁一一对应
for path in "$DEST"/*; do
  name=$(basename "$path")
  grep -q "^$name " "$DEST/.manifest" || { echo "删除锁外文件 $name"; rm -f "$path"; }
done
rm -f "$DEST/.manifest"

[ "$failed" -eq 0 ] || { echo "有文件校验失败，重新运行会重下" >&2; exit 1; }
echo "水杉数据 -> $DEST"
