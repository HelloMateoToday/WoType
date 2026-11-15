// WebProviders.swift — 腾讯交互翻译（TranSmart）、火山翻译：网页、浏览器插件用的匿名接口。
// 移植自 FluentRead src/providers/translation/free-web.ts。一块最多 1000 个码点。

import Foundation

/// 腾讯交互翻译 transmart.qq.com：每次带一个随机的 client_key，不要账号。
public struct TransmartProvider: SingleTextProvider {
    public let id = "transmart"
    public let name = "腾讯交互翻译"
    public let limits = ProviderLimits()
    let chunkLimit = 1000

    static let endpoint = URL(string: "https://transmart.qq.com/api/imt")!
    /// 实测不支持的目标语言（2026-11-12：印地语回 Unsupported-Language）
    static let unsupportedTargets: Set<String> = ["hi"]

    public init() {}

    public func supports(from: Language?, to: Language) -> Bool { !Self.unsupportedTargets.contains(to.baseCode) }

    func request(_ text: String, from: Language?, to: Language) throws -> URLRequest {
        let clientKey = "browser-chrome-110.0.0-Mac OS-\(UUID().uuidString.lowercased())-\(Int(Date().timeIntervalSince1970 * 1000))"
        return try .post(Self.endpoint, json: [
            "header": ["fn": "auto_translation", "client_key": clientKey],
            "type": "plain", "model_category": "normal",
            "source": ["text_list": [text], "lang": from.map { Self.code($0, target: false) } ?? "auto"],
            "target": ["lang": Self.code(to, target: true)],
        ] as [String: Any])
    }

    func parse(_ response: HTTPResponse) throws -> String {
        try response.requireSuccess(name)
        guard let object = try response.json(name) as? [String: Any] else { throw TranslationError.invalidResponse(name) }
        let code = (object["header"] as? [String: Any])?["ret_code"] as? String
        guard code == "succ" else {
            if code == "Auth-Failed" { throw TranslationError.blocked(status: 403, message: "\(name)鉴权失败") }
            if code == "Unsupported-Language" { throw TranslationError.unsupported }
            throw TranslationError.unavailable(message: "\(name)返回 \(code ?? "空")")
        }
        guard let parts = object["auto_translation"] as? [String], !parts.isEmpty,
              !parts.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            throw TranslationError.invalidResponse(name)
        }
        return parts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func translateChunk(_ text: String, from: Language?, to: Language, http: HTTPClient) async throws -> String {
        try parse(try await http.send(request(text, from: from, to: to)))
    }

    /// 简体 zh；繁体作源语言是 zh、作目标是 zh-tw
    static func code(_ language: Language, target: Bool) -> String {
        switch language.code {
        case "zh-Hans": "zh"
        case "zh-Hant": target ? "zh-tw" : "zh"
        default: language.baseCode
        }
    }
}

/// 火山翻译 translate.volcengine.com 的浏览器插件接口，不要令牌。
/// 源语言写 auto 时，识别出中文、日文就原样返回不翻（2026-11-12 实测；英文正常），所以写法明显的先猜好再发。
public struct VolcengineProvider: SingleTextProvider {
    public let id = "volcengine"
    public let name = "火山翻译"
    public let limits = ProviderLimits()
    let chunkLimit = 1000

    static let endpoint = URL(string: "https://translate.volcengine.com/crx/translate/v1/")!

    public init() {}

    public func supports(from: Language?, to: Language) -> Bool { true }

    func request(_ text: String, from: Language?, to: Language) throws -> URLRequest {
        try .post(Self.endpoint, json: [
            "source_language": (from ?? guessLanguage(text)).map { Self.code($0, target: false) } ?? "auto",
            "target_language": Self.code(to, target: true),
            "text": text,
        ])
    }

    func parse(_ response: HTTPResponse) throws -> String {
        try response.requireSuccess(name)
        guard let object = try response.json(name) as? [String: Any] else { throw TranslationError.invalidResponse(name) }
        let status = (object["base_resp"] as? [String: Any])?["status_code"] as? Int
        guard status == 0 else { throw TranslationError.unavailable(message: "\(name)返回状态 \(status.map(String.init) ?? "空")") }
        guard let text = object["translation"] as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw TranslationError.invalidResponse(name)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func translateChunk(_ text: String, from: Language?, to: Language, http: HTTPClient) async throws -> String {
        try parse(try await http.send(request(text, from: from, to: to)))
    }

    /// 简体 zh；繁体作源语言是 zh、作目标是 zh-Hant
    static func code(_ language: Language, target: Bool) -> String {
        switch language.code {
        case "zh-Hans": "zh"
        case "zh-Hant": target ? "zh-Hant" : "zh"
        default: language.baseCode
        }
    }
}
