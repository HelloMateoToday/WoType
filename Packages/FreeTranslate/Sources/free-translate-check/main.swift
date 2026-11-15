// free-translate-check：逐家试一遍「能不能用、多快、翻得对不对」，再用备选池翻一次。接口失效时一跑就知道是哪家。
//
//   swift run free-translate-check                     # 中文 → 英语、英语 → 中文，每家都试
//   swift run free-translate-check --to ja             # 中文 → 日语
//   swift run free-translate-check --text "你好世界" --only microsoft,google
//   swift run free-translate-check --matrix            # 每家 × 常用的 16 种目标语言，打一张表
//
// 走系统代理（谷歌在国内要代理）。退出码：每家都能用是 0，有失败的是 1。

import FreeTranslate
import Foundation

var target = Language.english
var chineseText = "我很赞同你的意见，明天上午十点在会议室开会。"
let englishText = "The weather is nice today, let's go for a walk."
var only: Set<String>?
var matrix = false

var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--to": target = Language(arguments.next() ?? "en")
    case "--text": chineseText = arguments.next() ?? chineseText
    case "--only": only = Set((arguments.next() ?? "").split(separator: ",").map(String.init))
    case "--matrix": matrix = true
    default:
        print("用法：free-translate-check [--to <语言>] [--text <中文>] [--only <id,id>]")
        exit(2)
    }
}

let http = URLSessionHTTPClient(timeout: 10)
let providers = FreeTranslate.defaultProviders().filter { only?.contains($0.id) ?? true }
var failed = 0

func pad(_ text: String, _ width: Int) -> String {
    // 中文字算两格
    let cells = text.reduce(0) { $0 + ($1.unicodeScalars.first!.value > 0x2E80 ? 2 : 1) }
    return text + String(repeating: " ", count: max(width - cells, 0))
}

/// 返回要打印的一行，和这次算不算失败（不支持的方向不算）
func attempt(_ provider: TranslationProvider, _ text: String, from: Language?, to: Language) async -> (String, Bool) {
    guard provider.supports(from: from, to: to) else { return ("（不支持 \(from?.code ?? "auto") → \(to.code)）", false) }
    let started = Date()
    do {
        let result = try await provider.translate([text], from: from, to: to, http: http)
        return (String(format: "✓ %.2fs  ", Date().timeIntervalSince(started)) + (result.first ?? ""), false)
    } catch {
        return (String(format: "✗ %.2fs  ", Date().timeIntervalSince(started)) + "\(error)", true)
    }
}

/// 粗看译文是不是目标语言的文字（拉丁字母的几种只查没有汉字）
func looksLike(_ text: String, _ language: Language) -> Bool {
    let scalars = text.unicodeScalars
    func has(_ range: ClosedRange<UInt32>) -> Bool { scalars.contains { range.contains($0.value) } }
    let han = has(0x4E00...0x9FFF)
    switch language.baseCode {
    case "ja": return has(0x3040...0x30FF) || han
    case "ko": return has(0xAC00...0xD7AF)
    case "ar": return has(0x0600...0x06FF)
    case "hi": return has(0x0900...0x097F)
    case "th": return has(0x0E00...0x0E7F)
    case "ru": return has(0x0400...0x04FF)
    case "zh-Hant", "zh-Hans": return han
    default: return !han && !text.isEmpty
    }
}

if matrix {
    let sample = "我很赞同你的意见"
    print("「\(sample)」→ 各语言（✓ 对、✗ 失败或不像、- 不支持）")
    print(pad("", 18) + providers.map { pad($0.name, 13) }.joined())
    for language in Language.translationTargets {
        var row = pad("\(language.chineseName ?? language.code)（\(language.code)）", 18)
        for provider in providers {
            guard provider.supports(from: nil, to: language) else {
                row += pad("-", 13)
                continue
            }
            do {
                let text = try await provider.translate([sample], from: nil, to: language, http: http)[0]
                row += pad(looksLike(text, language) ? "✓" : "✗ 不像", 13)
                if !looksLike(text, language) { failed += 1; print("   \(provider.name) \(language.code)：\(text)") }
            } catch {
                row += pad("✗", 13)
                failed += 1
                print("   \(provider.name) \(language.code)：\(error)")
            }
        }
        print(row)
    }
    exit(failed == 0 ? 0 : 1)
}

print("中文 → \(target.code)：\(chineseText)")
for provider in providers {
    let (line, failure) = await attempt(provider, chineseText, from: nil, to: target)
    print(pad(provider.name, 14), line)
    if failure { failed += 1 }
}
print("\n英语 → 简体中文：\(englishText)")
for provider in providers {
    let (line, failure) = await attempt(provider, englishText, from: nil, to: .simplifiedChinese)
    print(pad(provider.name, 14), line)
    if failure { failed += 1 }
}

print("\n备选池（中文 → \(target.code)）：")
let pool = TranslationPool(providers: providers, http: http)
do {
    let started = Date()
    let translation = try await pool.translate(chineseText, to: target)
    print(String(format: "✓ %.2fs  [%@] ", Date().timeIntervalSince(started), translation.provider) + translation.text)
} catch {
    failed += 1
    print("✗ \(error)")
}
exit(failed == 0 ? 0 : 1)
