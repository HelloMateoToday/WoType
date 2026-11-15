# 随 App 分发的第三方许可证（不从别处收集的那部分）

`scripts/collect-licenses.py` 把这里的文件和水杉、Rust crate 的许可证一起收进 App 的 `Contents/Resources/Licenses`。

## librime/

万象引擎用的 librime 官方 macOS 发布包（`scripts/fetch-librime.sh`，librime 1.17.0，`rime-33e7814-macOS-universal.tar.bz2`）
不带许可证，这里按发布包 `version-info.txt` 和 librime 锁定的版本从 GitHub 取的原文（2026-11-15）：

| 文件 | 来源 |
|---|---|
| `librime-BSD-3-Clause.txt` | rime/librime `33e7814` |
| `librime-lua-BSD-3-Clause.txt` | hchunhui/librime-lua `ec52e48` |
| `librime-predict-BSD-3-Clause.txt` | rime/librime-predict `920bd41` |
| `lua-MIT.txt` | librime-lua 的 thirdparty 分支 `9e5bb71` 的 `lua5.4/lua.h` 末尾 |
| `glog-BSD-3-Clause.txt` | google/glog `7b134a5`（librime 的 deps/glog） |
| `leveldb-BSD-3-Clause.txt` | google/leveldb `99b3c03` |
| `marisa-trie-BSD-2-Clause-or-LGPL-2.1.txt` | s-yata/marisa-trie `3e87d53` |
| `yaml-cpp-MIT.txt` | jbeder/yaml-cpp `2f86d13` |
| `boost-BSL-1.0.txt` | boostorg/boost `boost-1.92.0` |

librime-octagram（BSD-3-Clause）和 OpenCC（Apache-2.0）的许可证水杉已经带了（`librime-octagram-BSD-3-Clause.txt`、
`OpenCC-Apache-2.0.txt`），不重复放。升级 librime 时对照新发布包的 `version-info.txt` 和 librime 的 deps 子模块重新取。

## CC-BY-4.0.txt

Creative Commons Attribution 4.0 International 全文（取自 rime-wanxiang 仓库的 LICENSE）。`scripts/copy-data.sh`
把它接在万象方案的出处说明后面，生成 `rime-wanxiang-scheme-CC-BY-4.0.txt`。
