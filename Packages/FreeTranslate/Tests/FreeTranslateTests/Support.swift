// Support.swift — 测试用的假网络、假翻译服务、读固定回包。

import Foundation
@testable import FreeTranslate

/// 记下发出去的请求，按 handler 回包
final class FakeHTTP: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private let handler: @Sendable (URLRequest, Int) async throws -> HTTPResponse

    init(handler: @escaping @Sendable (URLRequest, Int) async throws -> HTTPResponse) {
        self.handler = handler
    }

    convenience init(_ responses: [HTTPResponse]) {
        self.init { _, index in responses[min(index, responses.count - 1)] }
    }

    var requests: [URLRequest] { lock.withLock { _requests } }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let index = lock.withLock { () -> Int in
            _requests.append(request)
            return _requests.count - 1
        }
        return try await handler(request, index)
    }
}

/// 读 Fixtures 里的真实回包
func fixture(_ name: String, status: Int = 200) -> HTTPResponse {
    let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
    return HTTPResponse(status: status, body: try! Data(contentsOf: url))
}

func response(_ json: String, status: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
    HTTPResponse(status: status, headers: headers, body: Data(json.utf8))
}

extension URLRequest {
    var bodyJSON: Any? { httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } }
    var bodyText: String { httpBody.map { String(decoding: $0, as: UTF8.self) } ?? "" }

    /// 表单或查询串里某个字段的值（解码后）
    func field(_ name: String) -> String? {
        let source = (httpMethod == "GET" ? url?.query : bodyText) ?? ""
        for pair in source.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.first == name {
                return parts.count > 1 ? parts[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding : ""
            }
        }
        return nil
    }
}

/// 假的翻译服务：handler 决定返回什么
struct FakeProvider: TranslationProvider {
    let id: String
    var name: String { id }
    var limits = ProviderLimits(maxConcurrent: 4, minInterval: 0)
    var supported: @Sendable (Language?, Language) -> Bool = { _, _ in true }
    let handler: @Sendable ([String]) async throws -> [String]

    init(_ id: String, supported: @escaping @Sendable (Language?, Language) -> Bool = { _, _ in true },
         handler: @escaping @Sendable ([String]) async throws -> [String]) {
        self.id = id
        self.supported = supported
        self.handler = handler
    }

    func supports(from: Language?, to: Language) -> Bool { supported(from, to) }

    func translate(_ texts: [String], from: Language?, to: Language, http: HTTPClient) async throws -> [String] {
        try await handler(texts)
    }
}

/// 数一个假服务被调了几次
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}
