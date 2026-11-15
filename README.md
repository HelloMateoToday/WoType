<div align="center">

<img src="WoType/WoType/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" alt="WoType">

# WoType

**macOS 拼音输入法 · 语音输入 · 翻译**

[![License](https://img.shields.io/badge/license-AGPL--3.0-blue)](LICENSE)
[![macOS](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)](#系统要求)
[![Apple 芯片](https://img.shields.io/badge/Apple%20%E8%8A%AF%E7%89%87-arm64-0EAF76)](#系统要求)
[![Release](https://img.shields.io/github/v/release/HelloMateoToday/WoType)](https://github.com/HelloMateoToday/WoType/releases)

[官网](https://hellomateotoday.github.io/WoType/) · [下载](https://github.com/HelloMateoToday/WoType/releases) · [安装](#安装) · [问题反馈](https://github.com/HelloMateoToday/WoType/issues)

</div>

https://github.com/user-attachments/assets/3e77675f-39f7-4965-93e8-7f06e90a6e84

## 简介

WoType 是一个开源、免费的 macOS 原生输入法，把拼音打字、语音输入和翻译放在一起：

- **两个拼音引擎**：默认用[水杉输入法](https://github.com/metasequoiaime/msime)的引擎、词库和整句模型；也可以切到 [librime](https://github.com/rime/librime) + [万象拼音](https://github.com/amzxyz/rime-wanxiang)。设置里随时切换。
- **语音输入**：按住一个键说话，边说边出字，松开就上屏，口头禅和语气词自动清掉。可以用本机模型识别，录音不出电脑。
- **翻译**：打字时翻译候选、选中文字翻译、说中文直接输入英文。

界面照 macOS 原生的样子用 AppKit 写，候选窗、设置、新手引导都是原生窗口。

## 功能

### 打字

| 功能 | 说明 |
|---|---|
| 整句输入 | 一口气打完一整句，按空格整句上屏 |
| 简拼 | 只打声母：`bjdx` → 北京大学 |
| 按错键也能认出来 | `zhognguo` 也能打出「中国」 |
| 打英文不用切换 | 直接打 `github`，候选里就有 GitHub，大小写按词表来 |
| 长句分段选 | 第一个候选不对时，先按数字选开头的词，剩下的接着选 |
| 打字推荐 emoji | 打「开心」，候选里跟着出 😄 |
| 其他 | 模糊音、双拼、自定义词、快捷短语、繁体输出、候选外观（几套皮肤，跟着浅色 / 深色模式） |

### 语音输入

| 功能 | 说明 |
|---|---|
| 按住说话 | 按住语音键（默认右 ⌘）说话，松开上屏；点一下开始、再点一下结束也行 |
| 边说边出字 | 屏幕底部的胶囊里实时显示识别的文字 |
| 口语清理 | 「呃，那个，我想问一下……」上屏成「我想问一下……」 |
| AI 润色 | 本机模型（Qwen3.5）或你自己的云端模型（OpenAI、Anthropic、Gemini、DeepSeek、OpenRouter 等，自备密钥） |
| 语音翻译 | 按住翻译键（默认右 ⌥）说中文，松开直接输入英文 |

### 翻译

| 功能 | 说明 |
|---|---|
| 候选翻译 | 打中文时单按 ⌃，候选窗下面出译文，按 ⏎ 上屏译文 |
| 划词翻译 · 显示 | 任何地方选中文字，按 ⌃⌥T，在下面的气泡里看译文 |
| 划词翻译 · 替换 | 在输入框里选中文字，按 ⌃⌥I，直接换成译文 |

翻译默认用免费翻译接口（Google、微软等，自动挑能用的），不用申请密钥。候选翻译和划词翻译默认关闭，在「设置 › 翻译设置」里打开。

### 常用按键

| 按键 | 作用 |
|---|---|
| ⇧（单按） | 中 / 英切换，已经打的字母原样上屏 |
| 右 ⌘（按住） | 语音输入 |
| 右 ⌥（按住） | 语音翻译 |
| ⌃（单按） | 翻译高亮的候选 |
| ⌃⌥T / ⌃⌥I | 划词翻译：显示 / 替换 |
| ⇧⌫ | 删掉学错的词 |
| 1–9、空格 | 选候选 |

快捷键可以在设置里改。

## 安装

### 系统要求

- macOS 14 或更新
- Apple 芯片（M 系列）。只有 arm64 版本：本机语音模型用的 [MLX](https://github.com/ml-explore/mlx-swift) 只能在 Apple 芯片上运行

### 步骤

1. 从 [Releases](https://github.com/HelloMateoToday/WoType/releases) 下载 `WoType-<版本>.dmg`。
2. 如果打开时提示「无法验证开发者」，先去掉 DMG 的隔离属性再打开：

   ```sh
   xattr -dr com.apple.quarantine ~/Downloads/WoType-*.dmg
   ```

3. 打开 DMG，双击「安装 WoType.app」，点「安装」。
4. 照着安装器里的动画，到「系统设置 › 键盘 › 输入法 › 编辑… › ＋ › 简体中文」里选 WoType，点「添加」。
   如果列表里找不到 WoType，注销或重启后再添加。
5. 点「开始使用」，新手引导会带你试打字、选语音识别方式、给需要的权限。

### 权限

| 权限 | 用来做什么 |
|---|---|
| 麦克风 | 语音输入、语音翻译 |
| 辅助功能 | 划词翻译读选中的文字；语音润色参考光标前后的文字和屏幕内容（默认关闭，在设置里打开） |

不用语音和划词翻译的话，这两个权限都不用给。

### 更新和卸载

- **更新**：在「设置 › 关于软件」里点「检查更新」，有新版时打开发布页下载 DMG，用安装器覆盖安装，词库和设置都保留。WoType 不会自动联网检查。
- **卸载**：再打开「安装 WoType.app」点「卸载」（可以勾选同时删除词库、设置和下载的模型），然后在「系统设置 › 键盘 › 输入法」里把 WoType 移除。

## 语音识别方式

在「设置 › 语音输入」里选：

| 方式 | 说明 | 录音去哪 |
|---|---|---|
| 本机模型 | Qwen3-ASR（MLX 运行），在「模型管理」里下载一次 | 不出电脑 |
| 云端识别 | xAI 的官方接口，自备密钥 | xAI |
| 免费体验渠道 | 豆包输入法、微信输入法、千问输入法，不用密钥 | 对应厂商的服务器 |

> [!WARNING]
> **免费体验渠道的来源和免责声明**
>
> - 豆包输入法（字节跳动）、微信输入法（腾讯）、千问输入法（阿里巴巴）这三个渠道，调用的是这些输入法**客户端内部使用的语音识别接口，不是厂商公开提供的开放接口**。
> - 通信协议参考了 [Setem](https://github.com/zcyoung2000/Setem) 的分析，WoType 的代码是自己写的，没有复制 Setem 的代码。
> - WoType 和字节跳动、腾讯、阿里巴巴没有任何关系，没有得到它们的授权或认可。相关名称和商标归各自的所有者。
> - 这些渠道**仅供体验和学习研究**，厂商随时可能更改或关闭接口，渠道随时可能失效，WoType 不保证可用。
> - 使用时，你说话的录音会发送到对应厂商的服务器，受该厂商的服务条款和隐私政策约束。是否使用、是否符合相关条款，由你自己判断，风险自负。
> - 长期使用或对隐私有要求，请用本机模型或官方云端接口。第一次选用体验渠道时，App 里也会弹出同样的提示，需要你确认。

## 隐私

| 内容 | 在本机处理 | 会发到网上 |
|---|---|---|
| 打字、候选、学到的词 | ✅ 全部在本机 | — |
| 语音识别 | 选本机模型时 | 选云端识别或体验渠道时，录音发给对应服务 |
| 语音润色、语音翻译 | 选本机模型时 | 选云端模型时，识别出的文字（以及你允许的上下文）发给你配置的服务商 |
| 候选翻译、划词翻译 | — | 要翻译的文字发给免费翻译接口 |
| 检查更新 | — | 访问 GitHub Releases |

WoType 没有自己的服务器，不收集使用数据。词库、设置和下载的模型都在 `~/Library/Application Support/WoType/`。

## 技术架构

```
┌──────────────────────────── WoType.app（输入法进程）────────────────────────────┐
│  InputMethodKit 外壳（Swift / AppKit）                                           │
│  按键处理 · 候选窗 · 设置 · 新手引导 · 语音浮窗 · 划词翻译                        │
│                                                                                  │
│   ┌─ 拼音引擎（二选一）──────────────────┐   ┌─ 翻译 ──────────────────────┐    │
│   │ 水杉：msime-host-api                  │   │ FreeTranslate（Swift 包）   │    │
│   │   → libwotype_core.a（Rust 静态库）   │   │ 多家免费翻译接口，自动备选   │    │
│   │ 万象：librime 官方包（运行时载入）    │   └─────────────────────────────┘    │
│   │   + 万象拼音方案（打包时预编译）      │                                      │
│   └───────────────────────────────────────┘   语音润色规则：Rust（libwotype_core）│
│                                                                                  │
│   语音识别：本机 → wotype-voice 子进程 │ 云端 / 体验渠道 → WebSocket / HTTP       │
└──────────────────────────────────────────────────────────────────────────────────┘
        │ 管道通信，闲置 5 分钟自动退出
┌───────▼──────────────────────────────┐
│ wotype-voice（Swift + MLX）           │
│ Qwen3-ASR 识别 · Qwen3.5 润色 / 翻译   │
└───────────────────────────────────────┘
```

| 目录 | 内容 |
|---|---|
| `WoType/WoType` | 输入法 App：输入控制、候选窗、设置、新手引导、语音输入、翻译 |
| `WoType/VoiceService` | 语音服务 `wotype-voice`：用 MLX 跑识别和润色模型 |
| `WoType/WoTypeInstaller` | DMG 里的「安装 WoType.app」：安装、更新、卸载 |
| `WoType/WoTypeTests` | 单元测试 |
| `engine/core` | Rust 核心 `libwotype_core.a`：接水杉引擎、语音润色规则。里面还有早期的 Rust 版万象引擎，现在不参与编译（`wanxiang` 特性） |
| `Packages/FreeTranslate` | 免费翻译库（GPL-3.0） |
| `scripts` | 编译、下载数据、打包脚本 |
| `licenses` | 随 App 分发的第三方许可证（其余的在编译时收集） |
| `docs` | 官网（GitHub Pages）：落地页、功能演示动画、演示视频 |

## 从源码编译

需要：

- Xcode（带 macOS SDK）和它的 Metal 工具链：`xcodebuild -downloadComponent MetalToolchain`
- Rust（[rustup](https://rustup.rs)，1.80 或更新）
- 能访问 GitHub：第一次编译会下载水杉词库、librime 和万象方案（这些数据不放在仓库里）

打安装包：

```sh
git clone https://github.com/HelloMateoToday/WoType.git
cd WoType
./scripts/make-installer.sh
```

产物在 `build/Installer/WoType-<版本>-<构建号>.dmg`。第一次要编 Rust 核心和语音服务，大约 15 分钟，过程中会显示进度，完整的编译日志在 `build/Installer/xcodebuild.log`。

| 参数 | 作用 |
|---|---|
| `--no-build` | 不重新编译，用上次编好的重新签名、打包 |
| `--notarize` | 提交公证并 staple，要先 `xcrun notarytool store-credentials "WoType-notary"` 存好凭据 |

**签名**：钥匙串里有 Developer ID Application 证书就用它签（可以用 `WOTYPE_SIGN_IDENTITY` 指定哪一张）；没有证书就用临时签名（ad-hoc），照样能打包和安装，但不能公证，而且每次更新后麦克风、辅助功能权限要重新授权。

也可以用 Xcode 打开 `WoType/WoType.xcodeproj` 直接编译运行。

### 发布新版本

推送 `v` 开头的标签时，GitHub Actions（[`.github/workflows/release.yml`](.github/workflows/release.yml)）会在 Mac 虚拟机上自动打包，创建 Release 并上传 DMG：

1. 在 Xcode 工程里把版本号（`MARKETING_VERSION`）改成新版本，比如 `0.2.0`，提交。
2. 打标签并推送，标签要和版本号一样：

   ```sh
   git tag v0.2.0 && git push origin v0.2.0
   ```

3. 等 Actions 跑完（约 30 分钟），Release 页面就有新版本，官网的下载按钮也会自动指向它。

- 标签和工程版本号不一样时，工作流直接失败，不会发出错误版本（App 的「检查更新」拿两者比较）。
- 在 Actions 页面手动运行（Run workflow）只打包、不发布，用来检查能不能编译成功。
- 虚拟机上没有开发者证书，用临时签名打包；发布说明里写了 `xattr` 的步骤。
- 不上传 artifacts、不用缓存，编译产物随虚拟机销毁，不占仓库存储。

## 致谢

WoType 用到了下面这些项目的代码或数据，各自保留原来的版权和许可证。详细的出处、版本和改动见 [NOTICE](NOTICE)；App 里的许可证全文在「设置 › 关于软件」和 `WoType.app/Contents/Resources/Licenses`。

### 代码

| 项目 | 许可证 | 用在哪里 |
|---|---|---|
| [Arion](https://github.com/AstraFoundry/Arion) | AGPL-3.0-only | 语音输入（浮窗、听写流程、按键处理、识别和分段、热词、口语清理、场景、润色提示词）照它移植，每个移植的文件开头写着出处 |
| [水杉输入法 msime](https://github.com/metasequoiaime/msime) | GPL-3.0-only（引擎 MPL-2.0） | 默认拼音引擎：`msime-host-api` 链进 Rust 核心 |
| [librime](https://github.com/rime/librime) | BSD-3-Clause | 万象引擎：App 里带官方 macOS 发布包（含 [librime-lua](https://github.com/hchunhui/librime-lua)、[librime-octagram](https://github.com/lotem/librime-octagram)、[librime-predict](https://github.com/rime/librime-predict) 插件），没有改动 |
| [FluentRead](https://github.com/FluentRead/FluentRead) | GPL-3.0 | `Packages/FreeTranslate` 照它移植各家免费翻译接口的调用方式、备选池和冷却规则 |
| [WowType](https://github.com/Gloridust/WowType) | MIT OR Apache-2.0 | 项目最早从这个 Linux 输入法移植 |
| [mlx-swift](https://github.com/ml-explore/mlx-swift)、[mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm)、[mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift)、[swift-transformers](https://github.com/huggingface/swift-transformers) | MIT | 语音服务运行识别和润色模型 |
| [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) | MIT | 录制划词翻译的快捷键 |
| Rust crate（[regex](https://github.com/rust-lang/regex) 等） | MIT / Apache-2.0 等 | Rust 核心的依赖，完整清单在编译时生成到 `Licenses/rust-crates.txt` |

### 数据和模型

| 项目 | 许可证 | 用在哪里 |
|---|---|---|
| [msime-dictionary](https://github.com/metasequoiaime/msime-dictionary) | GPL-3.0（含[雾凇拼音](https://github.com/iDvel/rime-ice)）；词频表 CC BY-SA 4.0 | 水杉词库，随 App 分发，可以在线更新 |
| [chinese-ime-lm](https://github.com/metasequoiaime/chinese-ime-lm) | Apache-2.0 | 水杉整句模型 |
| [万象拼音 rime-wanxiang](https://github.com/amzxyz/rime-wanxiang)、[rime-wanxiang-data](https://github.com/amzxyz/rime-wanxiang-data)、[RIME-LMDG](https://github.com/amzxyz/RIME-LMDG)（作者 amzxyz） | CC BY 4.0 | 万象方案和词库（打包时预编译）、在线更新的词库、语法模型（用户自己下载） |
| [pypinyin](https://github.com/mozillazg/python-pinyin) | MIT | 汉字读音表（经 Arion） |
| [CMU Pronouncing Dictionary](https://github.com/cmusphinx/cmudict) | BSD-2-Clause 类 | 英文发音词典（经 Arion） |
| [Qwen3-ASR](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-8bit)、[Qwen3.5](https://huggingface.co/mlx-community/Qwen3.5-2B-4bit) | Apache-2.0 | 本机语音识别和润色模型，用户在设置里下载，不随 App 分发 |

### 旧的 Rust 万象引擎

`engine/core` 里还保留着早期的 Rust 版万象引擎（`wanxiang` 特性，现在不参与编译），它用到：

| 项目 | 许可证 | 用在哪里 |
|---|---|---|
| [WowType](https://github.com/Gloridust/WowType) | MIT OR Apache-2.0 | 引擎代码复制自它（提交 `1e31c67`），在这个基础上做了大量修改 |
| [librime-octagram](https://github.com/lotem/librime-octagram) | BSD-3-Clause | `gram.rs` 读取和打分 `.gram` 语法模型的方式 |
| [万象拼音](https://github.com/amzxyz/rime-wanxiang) | CC BY 4.0 | 词库和语法模型的格式（数据不在仓库里） |
| [OpenCC](https://github.com/BYVoid/OpenCC) | Apache-2.0 | 简繁对照表 `data/s2t.tsv` |
| [Unicode CLDR](https://cldr.unicode.org/) | Unicode License v3 | emoji 关键词 `src/emoji/cldr.tsv` |

### 参考过的项目

只参考了做法，没有复制代码：

| 项目 | 参考了什么 |
|---|---|
| [Setem](https://github.com/zcyoung2000/Setem) | 豆包、微信、千问三个语音体验渠道的通信协议分析（见上面的[免责声明](#语音识别方式)） |
| [fcitx5-macos](https://github.com/fcitx/fcitx5-macos) | InputMethodKit 外壳的踩坑经验 |
| [McBopomofo 小麦注音](https://github.com/openvanilla/McBopomofo) | 安装器：第三方程序启用、停用输入法的限制 |
| [鼠须管 Squirrel](https://github.com/rime/squirrel) | 候选窗「macOS 经典」皮肤的配色 |
| 微信输入法 | 交互：中英切换、候选窗按键、原样输入、安装器流程 |

## 免责声明

- WoType 按「现状」提供，不附带任何明示或暗示的担保，详见 [LICENSE](LICENSE)。
- 输入法能读到你打的字。WoType 的打字处理都在本机，代码全部公开，可以自己审查和编译。
- 用到云端识别、体验渠道、云端润色、免费翻译接口时，相关内容会发给对应的第三方服务，受它们的条款和隐私政策约束，见上面的[隐私](#隐私)和[语音识别方式](#语音识别方式)。
- 文中提到的产品名称和商标归各自的所有者，WoType 与它们没有关联。

## 许可证

WoType 用 [GNU Affero General Public License v3.0 only](LICENSE)（AGPL-3.0-only）发布：语音输入照搬了 Arion（AGPL-3.0-only）的代码。水杉（GPL-3.0）、FluentRead（GPL-3.0）按 GPLv3 第 13 条和本作品合在一起；MIT、Apache-2.0、BSD 的代码和 CC BY 的数据保留原来的版权声明。

`Packages/FreeTranslate` 单独按 [GPL-3.0](Packages/FreeTranslate/LICENSE) 发布。

修改后对外分发，或者通过网络提供服务，要按 AGPL-3.0 公开对应的源代码。

Copyright (C) 2026 HelloMateoToday
