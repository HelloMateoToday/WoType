// Google.swift — 谷歌翻译：四个网页端点（非官方公开 API），一个不行换下一个，失败的端点冷却一会儿。
// 移植自 FluentRead src/providers/translation/google.ts。国内要走代理（URLSession 用系统代理）。
// 一次最多 32 条、1 万字。

import Foundation

public struct GoogleProvider: TranslationProvider {
    public let id = "google"
    public let name = "谷歌翻译"
    public let limits = ProviderLimits(maxConcurrent: 2, minInterval: 0.2)

    static let htmlEndpoint = "https://translate-pa.googleapis.com/v1/translateHtml"
    static let listEndpoint = "https://translate.googleapis.com/translate_a/t"
    static let rpcID = "MkEWBc"
    static let batchEndpoints = [
        "https://translate.google.com/_/TranslateWebserverUi/data/batchexecute?rpcids=MkEWBc",
        "https://translate.google.co.uk/_/TranslateWebserverUi/data/batchexecute?rpcids=MkEWBc",
    ]
    /// 谷歌网页翻译组件里的公开协议标识，不是谁的 Google Cloud 密钥
    static let browserKey = "AIzaSyATBXajvzQLTDHEQbcpq0Ihe0vWDHmO520"
    static let maxItems = 32
    static let maxCharacters = 10_000

    enum Endpoint: CaseIterable {
        case html, list, batchPrimary, batchBackup
    }

    private let health = EndpointHealth()

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

    /// 按顺序试端点，冷却中的跳过；都失败就抛最后一个错误
    private func translateBatch(_ texts: [String], from: Language?, to: Language, http: HTTPClient) async throws -> [String] {
        var lastError: Error = TranslationError.unavailable(message: "\(name)所有端点都在冷却")
        for endpoint in Endpoint.allCases where health.available(endpoint) {
            try Task.checkCancellation()
            do {
                let response = try await http.send(request(endpoint, texts, from: from, to: to))
                let result = try parse(endpoint, response, count: texts.count)
                health.succeeded(endpoint)
                return result
            } catch let error as TranslationError {
                if case .cancelled = error { throw error }
                // 请求本身的问题（400 等）换端点也一样，不冷却端点
                if case .request = error {} else { health.failed(endpoint, error) }
                lastError = error
            }
        }
        throw lastError
    }

    static func code(_ language: Language) -> String {
        switch language.code {
        case "zh-Hans": "zh-CN"
        case "zh-Hant": "zh-TW"
        case "nb": "no"
        case "fil": "tl"
        default: language.baseCode  // 谷歌的 pt 是巴西葡萄牙语
        }
    }

    func request(_ endpoint: Endpoint, _ texts: [String], from: Language?, to: Language) throws -> URLRequest {
        let source = from.map(Self.code) ?? "auto", target = Self.code(to)
        switch endpoint {
        case .html:
            // <pre> 保留换行；原文转义成纯文本
            var request = try URLRequest.post(URL(string: Self.htmlEndpoint)!,
                                               json: [[texts.map { "<pre>\(escapeHTML($0))</pre>" }, source, target], "wt_lib"],
                                               headers: ["X-Goog-API-Key": Self.browserKey])
            request.setValue("application/json+protobuf", forHTTPHeaderField: "Content-Type")
            return request
        case .list:
            return .post(url(Self.listEndpoint, query: [("client", "gtx"), ("sl", source), ("tl", target), ("dt", "t")]),
                         form: texts.map { ("q", $0) })
        case .batchPrimary, .batchBackup:
            let calls = try texts.enumerated().map { index, text -> [Any] in
                let inner = String(decoding: try JSONSerialization.data(withJSONObject: [[text, source, target, true], [NSNull()]]), as: UTF8.self)
                return [Self.rpcID, inner, NSNull(), String(index)]
            }
            let request = String(decoding: try JSONSerialization.data(withJSONObject: [calls]), as: UTF8.self)
            return .post(URL(string: Self.batchEndpoints[endpoint == .batchPrimary ? 0 : 1])!, form: [("f.req", request)])
        }
    }

    func parse(_ endpoint: Endpoint, _ response: HTTPResponse, count: Int) throws -> [String] {
        if !(200..<300).contains(response.status) {
            // 403、带 xsrf 的 400：多半是被识别成机器人了
            if response.status == 400, response.text.lowercased().contains("xsrf") {
                throw TranslationError.blocked(status: 400, message: "\(name)要求验证")
            }
            try response.requireSuccess(name)
        }
        if response.text.lowercased().hasPrefix("<!doctype html") || response.text.lowercased().hasPrefix("<html") {
            throw TranslationError.blocked(status: response.status, message: "\(name)返回网页（可能要人机验证）")
        }
        let texts: [String]
        switch endpoint {
        case .html:
            guard let first = (try response.json(name) as? [Any])?.first as? [Any] else { throw TranslationError.invalidResponse(name) }
            texts = try first.map { item in
                guard let text = item as? String else { throw TranslationError.invalidResponse(name) }
                return decodeHTML(text.replacingOccurrences(of: "^<pre(?:\\s[^>]*)?>([\\s\\S]*)</pre>$", with: "$1",
                                                            options: [.regularExpression, .caseInsensitive]))
            }
        case .list:
            // 源语言是 auto 时每条是 [译文, 识别出的语言]，否则就是译文字符串
            guard let items = try response.json(name) as? [Any] else { throw TranslationError.invalidResponse(name) }
            texts = try items.map { item in
                if let text = item as? String { return text }
                if let pair = item as? [Any], let text = pair.first as? String { return text }
                throw TranslationError.invalidResponse(name)
            }
        case .batchPrimary, .batchBackup:
            texts = try parseBatch(response.text, count: count)
        }
        guard texts.count == count, !texts.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw TranslationError.invalidResponse(name)
        }
        return texts
    }

    /// batchexecute 的回包：去掉 )]}' 前缀，逐行找 ["wrb.fr","MkEWBc", 载荷, …, 编号]；载荷[1][0][0][5] 是分段，拼每段的 [0]
    private func parseBatch(_ body: String, count: Int) throws -> [String] {
        var results = [String?](repeating: nil, count: count)
        let lines = body.replacingOccurrences(of: "^\\)\\]\\}'\\r?\\n?", with: "", options: .regularExpression)
            .components(separatedBy: .newlines)
        for line in lines where line.trimmingCharacters(in: .whitespaces).hasPrefix("[") {
            guard let records = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [Any] else { continue }
            for case let record as [Any] in records {
                guard record.count > 6, record[0] as? String == "wrb.fr", record[1] as? String == Self.rpcID else { continue }
                guard let id = (record[6] as? String).flatMap(Int.init), results.indices.contains(id), results[id] == nil,
                      let payloadText = record[2] as? String,
                      let payload = try? JSONSerialization.jsonObject(with: Data(payloadText.utf8)) as? [Any],
                      let groups = payload.dropFirst().first as? [Any], let group = groups.first as? [Any],
                      let translation = group.first as? [Any], translation.count > 5,
                      let segments = translation[5] as? [Any] else { throw TranslationError.invalidResponse(name) }
                let text = segments.compactMap { ($0 as? [Any])?.first as? String }.joined()
                guard !text.isEmpty else { throw TranslationError.invalidResponse(name) }
                results[id] = text
            }
        }
        guard !results.contains(where: { $0 == nil }) else { throw TranslationError.invalidResponse(name) }
        return results.map { $0! }
    }
}

/// 谷歌各端点的冷却：失败 30 秒起、每次翻倍、最多 300 秒；被拒（要验证）直接 300 秒
final class EndpointHealth: @unchecked Sendable {
    private let lock = NSLock()
    private var retryAt: [GoogleProvider.Endpoint: Date] = [:]
    private var failures: [GoogleProvider.Endpoint: Int] = [:]

    func available(_ endpoint: GoogleProvider.Endpoint) -> Bool {
        lock.withLock { (retryAt[endpoint] ?? .distantPast) <= Date() }
    }

    func succeeded(_ endpoint: GoogleProvider.Endpoint) {
        lock.withLock {
            retryAt[endpoint] = nil
            failures[endpoint] = nil
        }
    }

    func failed(_ endpoint: GoogleProvider.Endpoint, _ error: TranslationError) {
        lock.withLock {
            let count = (failures[endpoint] ?? 0) + 1
            failures[endpoint] = count
            var delay = min(30 * pow(2, Double(count - 1)), 300)
            if case .blocked = error { delay = 300 }
            if case .rateLimited(let after?) = error { delay = after }
            retryAt[endpoint] = Date().addingTimeInterval(delay)
        }
    }
}
