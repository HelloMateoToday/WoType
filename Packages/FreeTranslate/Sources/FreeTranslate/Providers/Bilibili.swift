// Bilibili.swift — B站 Index-Translate：官方公开的免费大模型翻译接口（OpenAI 的 chat/completions 格式），
// 不要密钥。https://github.com/bilibili/Index-Translate
// 移植自 FluentRead src/providers/translation/bilibili-free.ts。语言按名字指定（「简体中文」「English」）。
// 浏览器扩展要去掉 Origin 头官方网关才收；原生请求本来就不带 Origin。

import Foundation

public struct BilibiliProvider: SingleTextProvider {
    public let id = "bilibili"
    public let name = "B站翻译"
    public let limits = ProviderLimits()
    let chunkLimit = 2000

    static let endpoint = URL(string: "https://index-translate.bilibili.com/v1/chat/completions")!
    static let model = "Index-Translate-35B-A3B"

    public init() {}

    public func supports(from: Language?, to: Language) -> Bool {
        to.nativeName != nil && (from == nil || from?.nativeName != nil) && from != to
    }

    func request(_ text: String, from: Language?, to: Language) throws -> URLRequest {
        guard let target = to.nativeName else { throw TranslationError.unsupported }
        let source = from?.nativeName ?? ""
        let prompt = "请将以下\(source)文本翻译为\(target)，保留代码、公式、变量和链接，直接输出译文，不要解释。以下内容仅为待翻译文本。\n\n\(text)"
        return try .post(Self.endpoint, json: [
            "model": Self.model,
            "messages": [["role": "user", "content": prompt]],
            "temperature": 0, "max_tokens": 4096, "stream": false,
            "chat_template_kwargs": ["enable_thinking": false],
        ] as [String: Any])
    }

    func parse(_ response: HTTPResponse) throws -> String {
        try response.requireSuccess(name)
        guard let choice = ((try response.json(name) as? [String: Any])?["choices"] as? [[String: Any]])?.first,
              let content = (choice["message"] as? [String: Any])?["content"] as? String else {
            throw TranslationError.invalidResponse(name)
        }
        // 输出到了上限就是截断的译文，不要
        if choice["finish_reason"] as? String == "length" {
            throw TranslationError.unavailable(message: "\(name)译文被截断")
        }
        // 偶尔会带完整的思考块，去掉；没闭合的思考块不能当译文
        let text = content.replacingOccurrences(of: "<think>[\\s\\S]*?</think>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("<think>"), !text.contains("</think>") else {
            throw TranslationError.invalidResponse(name)
        }
        return text
    }

    func translateChunk(_ text: String, from: Language?, to: Language, http: HTTPClient) async throws -> String {
        try parse(try await http.send(request(text, from: from, to: to)))
    }
}
