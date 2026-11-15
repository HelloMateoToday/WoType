// Microsoft.swift — 微软翻译：Edge 浏览器内置翻译用的网页接口（非官方公开 API），不要令牌。
// 移植自 FluentRead src/providers/translation/microsoftTransport.ts。
// 接口总是跑 HTML 标签对齐，纯文本要先转义；一次最多 32 条、4000 字。

import Foundation

public struct MicrosoftProvider: TranslationProvider {
    public let id = "microsoft"
    public let name = "微软翻译"
    public let limits = ProviderLimits(maxConcurrent: 2, minInterval: 0.1)

    static let endpoint = "https://edge.microsoft.com/translate/translatetext"
    static let maxItems = 32
    static let maxCharacters = 4000

    public init() {}

    public func supports(from: Language?, to: Language) -> Bool { true }

    public func translate(_ texts: [String], from: Language?, to: Language, http: HTTPClient) async throws -> [String] {
        var results: [String] = []
        var batch: [String] = []
        var size = 0
        for text in texts {
            if !batch.isEmpty, batch.count >= Self.maxItems || size + text.count > Self.maxCharacters {
                results += try await translateBatch(batch, from: from, to: to, http: http)
                batch = []
                size = 0
            }
            batch.append(text)
            size += text.count
        }
        if !batch.isEmpty { results += try await translateBatch(batch, from: from, to: to, http: http) }
        return results
    }

    func request(_ texts: [String], from: Language?, to: Language) throws -> URLRequest {
        let target = url(Self.endpoint, query: [
            ("from", from.map(Self.code) ?? ""), ("to", Self.code(to)), ("isEnterpriseClient", "false"),
        ])
        return try .post(target, json: texts.map(escapeHTML))
    }

    func parse(_ response: HTTPResponse, count: Int) throws -> [String] {
        try response.requireSuccess(name)
        guard let items = try response.json(name) as? [[String: Any]], items.count == count else {
            throw TranslationError.invalidResponse(name)
        }
        return try items.map { item in
            guard let translations = item["translations"] as? [[String: Any]], translations.count == 1,
                  let text = translations[0]["text"] as? String else { throw TranslationError.invalidResponse(name) }
            return decodeHTML(text)
        }
    }

    private func translateBatch(_ texts: [String], from: Language?, to: Language, http: HTTPClient) async throws -> [String] {
        try parse(try await http.send(request(texts, from: from, to: to)), count: texts.count)
    }

    /// 微软用 zh-Hans / zh-Hant，塞尔维亚语要写 sr-Cyrl
    static func code(_ language: Language) -> String {
        language.code == "sr" ? "sr-Cyrl" : language.baseCode  // 微软的 pt 是巴西葡萄牙语
    }
}

func escapeHTML(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&#39;")
}

/// 一次解码常见实体和数字实体（不会把解出来的 &lt; 再解一遍）
func decodeHTML(_ text: String) -> String {
    guard text.contains("&") else { return text }
    let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}"]
    var output = ""
    var rest = Substring(text)
    while let amp = rest.firstIndex(of: "&") {
        output += rest[..<amp]
        let after = rest[rest.index(after: amp)...]
        if let semi = after.prefix(10).firstIndex(of: ";") {
            let entity = String(after[..<semi]).lowercased()
            var replacement: String?
            if let value = named[entity] {
                replacement = value
            } else if entity.hasPrefix("#x"), let code = UInt32(entity.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(code) {
                replacement = String(scalar)
            } else if entity.hasPrefix("#"), let code = UInt32(entity.dropFirst()), let scalar = Unicode.Scalar(code) {
                replacement = String(scalar)
            }
            if let replacement {
                output += replacement
                rest = after[after.index(after: semi)...]
                continue
            }
        }
        output += "&"
        rest = after
    }
    return output + rest
}
