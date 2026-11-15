# FreeTranslate

把各家**免费**翻译接口封装成一个 Swift 库：多家备选、失败自动换家、按失败类型冷却、超时、缓存。
WoType 的候选翻译用它，别的 Apple 平台项目（macOS 13+、iOS 16+）也能直接依赖。

> **注意**：除了 B站 Index-Translate，这里的接口都是各家网页、浏览器插件自己用的**内部接口**，不是官方开放的 API：
> 没有服务协议、没有额度承诺，随时可能改版、加验证、封掉，也不一定允许程序调用。仅供个人使用，后果自负。
> 翻译时文字会发给这些公司，涉及隐私的场景请让用户自己决定要不要打开。

## 用法

```swift
import FreeTranslate

let pool = TranslationPool()                       // 默认 7 家，按权重挑，失败换下一家
let result = try await pool.translate("我很赞同你的意见", to: .english)
print(result.text, result.provider)                // I fully agree with your suggestion. microsoft

try await pool.translate("I agree", to: .japanese)  // 目标语言随意（各家支持的范围不同，池子自己挑支持的）
try await pool.translate(["你好", "世界"], from: .simplifiedChinese, to: .french)
await pool.status()                                // 每家：冷却到几点、最近失败原因

// 只用某几家、调权重和超时
let mine = TranslationPool(providers: [MicrosoftProvider(), TransmartProvider()],
                           configuration: .init(weights: ["microsoft": 5, "transmart": 3], attemptTimeout: 3))
```

`from` 不给就是自动识别。语言用 `Language("en")`、`.simplifiedChinese`、`.traditionalChinese`、`.japanese` 等，
`zh`、`zh-CN`、`zh-TW` 这类写法会自动规范成 `zh-Hans` / `zh-Hant`。

## 各家

| id | 名称 | 接口 | 方向 | 一次最长 | 默认权重 |
|---|---|---|---|---|---|
| `microsoft` | 微软翻译 | Edge 内置翻译的网页接口 | 任意 | 32 条 / 4000 字（批量） | 5 |
| `google` | 谷歌翻译 | 4 个网页端点轮换，失败的端点冷却 | 任意（**国内要代理**，走系统代理） | 32 条 / 1 万字（批量） | 3 |
| `transmart` | 腾讯交互翻译 | transmart.qq.com 网页接口，随机 client_key | 任意 | 1000 字 | 3 |
| `volcengine` | 火山翻译 | 浏览器插件接口 | 任意 | 1000 字 | 3 |
| `youdao` | 有道翻译 | 网页接口，MD5 签名 | **只有简体中文 ↔ 英文** | 500 字 | 3 |
| `iciba` | 金山词霸 | 网页接口，MD5 + AES 签名，回包加密 | **只有简体中文 ↔ 英文** | 1000 字 | 3 |
| `bilibili` | B站翻译 | **官方公开**的免费大模型接口（[Index-Translate](https://github.com/bilibili/Index-Translate)） | 有名字的十几种语言 | 2000 字 | 2 |

超过「一次最长」的文字按行、按句切块，逐块翻完再拼回原来的换行。

### 备选池怎么挑

- 按权重随机排序（权重大的大概率先试），跳过冷却中、不支持这个方向的。
- 每家有自己的并发数和请求间隔（多数 1 个、间隔 0.3 秒；微软、谷歌 2 个）。
- 单次尝试默认 5 秒超时，一次调用（含换家）最多 20 秒。
- 结果检查：条数不对、空译文、中文原样返回（目标不是中文时）都算这家失败，换下一家。
- 冷却（照 FluentRead）：请求本身错不冷却；额度用完 24 小时；被拒 6 小时起翻倍到 24 小时；限流 5 分钟起翻倍到 6 小时（有 `Retry-After` 用它）；暂时不可用、超时 60 秒起翻倍到 30 分钟；再加最多 20% 的随机抖动。成功一次清零。
- 缓存最近 512 条（原文 + 方向），同一个词反复翻不再发请求。
- 网络用临时会话，不存不带 Cookie，回包最多 2 MB。

## 检查各家能不能用

```sh
swift run free-translate-check                    # 中文 → 英语、英语 → 中文，每家都试，最后用备选池翻一次
swift run free-translate-check --to ja            # 中文 → 日语
swift run free-translate-check --only youdao,iciba --text "你好世界"
```

某家接口失效时一跑就知道是哪家，退出码 1。

## 测试

```sh
swift test                                        # 不联网：各家的请求拼装（签名对照 Python / openssl 算的值）、
                                                  # 真实回包解析（Tests/.../Fixtures，2026-11-12 录的）、备选池、分块
FREE_TRANSLATE_LIVE=1 swift test --filter LiveTests   # 联网：每家真的翻一句，其他目标语言、长文本分块
```

## 已知情况（2026-11-12 实测）

- 7 家都能用；谷歌要代理。
- 火山的源语言写 `auto` 时，识别出中文、日文会原样返回不翻（英文正常），所以有汉字、假名、韩文时库会先猜好源语言再发。
- 腾讯交互翻译翻日语时偶尔漏句。
- ModernMT（还没接）厂商宣布 2026 年底停用。

## 许可证和来源

GPL-3.0（见 `LICENSE`）。各家接口的调用方式移植自 [FluentRead](https://github.com/FluentRead/FluentRead)
（GPL-3.0，提交 `b8529827cca220421fe5cec35645df45d4fae3f5`）的 `src/providers/translation`，每个文件开头注明了对应的源文件。
用到这个库的项目也要遵守 GPL-3.0（AGPL-3.0 的项目可以合并使用）。
