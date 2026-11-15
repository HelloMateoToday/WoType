//
//  WoType-Bridging-Header.h
//  WoType
//
//  Rust 核心的 C 接口（engine/core/include/wotype_core.h），
//  以及链在同一个静态库里的水杉宿主层（build/rust/include/msime_client.h，由 scripts/build-rust.sh 复制出来）。
//  librime 的 C 接口（Support/librime/rime_api.h，照抄 librime 1.17.0 发布包，BSD-3）：库不在编译时链接，
//  RimeEngine 运行时从 Contents/Frameworks/ 载入（docs/22）。它定义了 Bool 宏，放在最后。
//

#include "wotype_core.h"
#include "msime_client.h"
#include "Support/librime/rime_api.h"
