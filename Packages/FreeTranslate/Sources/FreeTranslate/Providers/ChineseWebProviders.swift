// ChineseWebProviders.swift — 有道网页翻译、金山词霸网页翻译：只做简体中文 ↔ 英文，请求要签名。
// 移植自 FluentRead src/providers/translation/free-chinese-web.ts。下面的常量是这两家网页前端代码里公开的值。

import Foundation

/// 有道、金山词霸只认简体中文和英文：返回它们自己的代码（zh-CHS / en），不支持就是 nil。
/// 源语言是 auto 时看有没有汉字：有就是中文翻英文，没有就是英文翻中文。
private func chineseEnglishDirection(_ text: String?, from: Language?, to: Language) -> (from: String, to: String)? {
    func code(_ language: Language) -> String? {
        switch language.code {
        case "zh-Hans": "zh-CHS"
        case "en": "en"
        default: nil
        }
    }
    guard let target = code(to) else { return nil }
    let source: String
    if let from {
        guard let explicit = code(from) else { return nil }
        source = explicit
    } else if let text {
        source = containsHan(text) ? "zh-CHS" : "en"
    } else {
        source = target == "en" ? "zh-CHS" : "en"
    }
    return source == target ? nil : (source, target)
}

/// 有道网页翻译 dict.youdao.com/jsonapi_s：MD5 签名，密钥是网页前端里的公开值。
/// 有道会静默截断约 600 字后的内容，所以一块最多 500 个码点。
public struct YoudaoProvider: SingleTextProvider {
    public let id = "youdao"
    public let name = "有道翻译"
    public let limits = ProviderLimits()
    let chunkLimit = 500

    static let endpoint = "https://dict.youdao.com/jsonapi_s?doctype=json&jsonversion=4"
    static let keyfrom = "webfanyi.webmain"
    static let client = "webmain"
    static let secret = "t2he2k4m2g6QKRigK0KAmSpXKgAezyWg"

    private let clock: @Sendable () -> Date

    public init(clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
    }

    public func supports(from: Language?, to: Language) -> Bool {
        chineseEnglishDirection(nil, from: from, to: to) != nil
    }

    /// t = 毫秒时间戳 + (q + keyfrom) 的长度（JS 的 UTF-16 长度）除以 10 的余数
    func timestamp(_ query: String) -> String {
        String(Int(clock().timeIntervalSince1970 * 1000) + (query + Self.keyfrom).utf16.count % 10)
    }

    static func sign(_ query: String, timestamp: String) -> String {
        md5Hex("\(client)\(query)\(timestamp)\(secret)\(md5Hex(query + keyfrom))")
    }

    func request(_ text: String, from: Language?, to: Language) throws -> URLRequest {
        guard let direction = chineseEnglishDirection(text, from: from, to: to) else { throw TranslationError.unsupported }
        let t = timestamp(text)
        return .get(url(Self.endpoint, query: [
            ("q", text), ("from", direction.from), ("to", direction.to), ("t", t), ("client", Self.client),
            ("sign", Self.sign(text, timestamp: t)), ("keyfrom", Self.keyfrom),
        ]))
    }

    func parse(_ response: HTTPResponse, direction: (from: String, to: String)) throws -> String {
        try response.requireSuccess(name)
        guard let fanyi = (try response.json(name) as? [String: Any])?["fanyi"] as? [String: Any] else {
            throw TranslationError.invalidResponse(name)
        }
        // 中英混合的文字有道可能不管 from/to 反着翻：认得出的方向和请求不一样就算失败
        if let type = (fanyi["type"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased(),
           type == "en2zh-chs" || type == "zh-chs2en", type != "\(direction.from)2\(direction.to)".lowercased() {
            throw TranslationError.request(status: nil, message: "\(name)翻译方向和请求不一致")
        }
        guard let text = fanyi["tran"] as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw TranslationError.invalidResponse(name)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func translateChunk(_ text: String, from: Language?, to: Language, http: HTTPClient) async throws -> String {
        guard let direction = chineseEnglishDirection(text, from: from, to: to) else { throw TranslationError.unsupported }
        return try parse(try await http.send(request(text, from: from, to: to)), direction: direction)
    }
}

/// 金山词霸 ifanyi.iciba.com：签名是 MD5 前 16 位再 AES-ECB 加密，回包也是 AES-ECB 加密的。
public struct IcibaProvider: SingleTextProvider {
    public let id = "iciba"
    public let name = "金山词霸"
    public let limits = ProviderLimits()
    let chunkLimit = 1000

    static let endpoint = URL(string: "https://ifanyi.iciba.com/index.php?c=trans&m=fyV2")!
    static let client = "6"
    static let authUser = "key_web_new_fanyi"
    static let signPrefix = "6key_web_new_fanyi6dVjYLFyzfkFkk"
    static let signKey = "L4fBtD5fLC9FQw22"
    static let responseKey = "aahc3TfyfCEmER33"

    public init() {}

    public func supports(from: Language?, to: Language) -> Bool {
        chineseEnglishDirection(nil, from: from, to: to) != nil
    }

    static func sign(_ query: String) -> String {
        let digest = String(md5Hex(signPrefix + query).prefix(16))
        return aesECB(Data(digest.utf8), key: signKey, encrypt: true)?.base64EncodedString() ?? ""
    }

    func request(_ text: String, from: Language?, to: Language) throws -> URLRequest {
        guard let direction = chineseEnglishDirection(text, from: from, to: to) else { throw TranslationError.unsupported }
        func code(_ c: String) -> String { c == "zh-CHS" ? "zh" : c }
        return .post(Self.endpoint, form: [
            ("from", code(direction.from)), ("to", code(direction.to)), ("q", text), ("client", Self.client),
            ("auth_user", Self.authUser), ("sign", Self.sign(text)),
        ])
    }

    func parse(_ response: HTTPResponse) throws -> String {
        try response.requireSuccess(name)
        guard let content = (try response.json(name) as? [String: Any])?["content"] as? String,
              let encrypted = Data(base64Encoded: content),
              let plain = aesECB(encrypted, key: Self.responseKey, encrypt: false),
              let result = try? JSONSerialization.jsonObject(with: plain) as? [String: Any] else {
            throw TranslationError.invalidResponse(name)
        }
        let code = (result["err_no"] as? Int) ?? Int("\(result["err_no"] ?? "")") ?? -1
        guard code == 0 else {
            switch code {
            case 429: throw TranslationError.rateLimited(retryAfter: nil)
            case 403: throw TranslationError.blocked(status: 403, message: "\(name)拒绝")
            case 402: throw TranslationError.quota(message: "\(name)额度用完")
            default: throw TranslationError.request(status: code, message: "\(name)业务错误 \(code)")
            }
        }
        guard let text = result["out"] as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw TranslationError.invalidResponse(name)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func translateChunk(_ text: String, from: Language?, to: Language, http: HTTPClient) async throws -> String {
        try parse(try await http.send(request(text, from: from, to: to)))
    }
}
