// Language.swift — 语言代码。库里统一用 BCP 47 风格的代码（en、zh-Hans、zh-Hant、ja……），
// 各家要的写法（zh-CN、zh-CHS、chi……）由各家的实现自己换算。

import Foundation

public struct Language: Hashable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    /// 规范化以后的代码：中文一律是 zh-Hans 或 zh-Hant，其余小写主语言（en、ja、ko……）
    public let code: String

    public init(_ code: String) {
        self.code = Self.normalize(code)
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    public var description: String { code }

    public static let english = Language("en")
    public static let simplifiedChinese = Language("zh-Hans")
    public static let traditionalChinese = Language("zh-Hant")
    public static let japanese = Language("ja")
    public static let korean = Language("ko")
    public static let french = Language("fr")
    public static let german = Language("de")
    public static let spanish = Language("es")
    public static let russian = Language("ru")
    public static let portuguese = Language("pt")
    public static let brazilianPortuguese = Language("pt-BR")
    public static let italian = Language("it")
    public static let arabic = Language("ar")
    public static let hindi = Language("hi")
    public static let indonesian = Language("id")
    public static let turkish = Language("tr")
    public static let vietnamese = Language("vi")
    public static let thai = Language("th")

    /// 常用的翻译目标（照 WhatsApp 用户多的地区挑的），给设置界面列出来
    public static let translationTargets: [Language] = [
        .english, .spanish, .brazilianPortuguese, .italian, .french, .german, .russian, .arabic,
        .hindi, .indonesian, .turkish, .vietnamese, .thai, .japanese, .korean, .traditionalChinese,
    ]

    /// 去掉地区的主语言（pt-BR → pt）；中文的 zh-Hans / zh-Hant 原样
    public var baseCode: String {
        isChinese ? code : String(code.split(separator: "-").first ?? Substring(code))
    }

    public var isChinese: Bool { code == "zh-Hans" || code == "zh-Hant" }

    /// 语言自己的名字（B站的大模型接口按名字指定语言，照 FluentRead 的语言目录）
    public var nativeName: String? { Self.nativeNames[code] }

    /// 中文名（给界面用）
    public var chineseName: String? { Self.chineseNames[code] }

    /// 中文：zh、zh-CN、zh-SG、zh-Hans… → zh-Hans；zh-TW、zh-HK、zh-MO、zh-Hant… → zh-Hant（照 FluentRead 的
    /// normalizeChineseLanguageCode，裸 zh 当简体）。其他只去空白、主语言小写。
    static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "_", with: "-")
        let parts = trimmed.split(separator: "-").map(String.init)
        guard let primary = parts.first?.lowercased(), !primary.isEmpty else { return trimmed }
        if primary == "zh" || primary == "cmn" {
            let rest = parts.dropFirst().map { $0.lowercased() }
            if rest.contains(where: { ["hant", "tw", "hk", "mo"].contains($0) }) { return "zh-Hant" }
            return "zh-Hans"
        }
        guard parts.count > 1 else { return primary }
        return ([primary] + parts.dropFirst()).joined(separator: "-")
    }

    private static let nativeNames: [String: String] = [
        "zh-Hans": "简体中文", "zh-Hant": "繁體中文", "en": "English", "ja": "日本語", "ko": "한국어",
        "fr": "Français", "ru": "Русский", "es": "Español", "de": "Deutsch", "pt": "Português",
        "it": "Italiano", "ar": "العربية", "vi": "Tiếng Việt", "th": "ไทย", "id": "Bahasa Indonesia",
        "pt-BR": "Português (Brasil)", "hi": "हिन्दी", "tr": "Türkçe",
    ]

    private static let chineseNames: [String: String] = [
        "zh-Hans": "简体中文", "zh-Hant": "繁体中文", "en": "英语", "ja": "日语", "ko": "韩语", "fr": "法语",
        "ru": "俄语", "es": "西班牙语", "de": "德语", "pt": "葡萄牙语", "it": "意大利语", "ar": "阿拉伯语",
        "vi": "越南语", "th": "泰语", "id": "印尼语", "pt-BR": "葡萄牙语（巴西）", "hi": "印地语", "tr": "土耳其语",
    ]
}

/// 按文字猜源语言（只认得出写法明显的几种）：有假名是日语、有韩文是韩语、有汉字是中文，其余 nil。
func guessLanguage(_ text: String) -> Language? {
    let scalars = text.unicodeScalars
    if scalars.contains(where: { (0x3040...0x30FF).contains($0.value) }) { return .japanese }
    if scalars.contains(where: { (0xAC00...0xD7AF).contains($0.value) || (0x1100...0x11FF).contains($0.value) }) { return .korean }
    if containsHan(text) { return .simplifiedChinese }
    return nil
}

/// 文本里有没有汉字（有道、金山词霸只做中英，源语言是 auto 时据此判断方向）。
func containsHan(_ text: String) -> Bool {
    text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
}
