// HTTP.swift — 网络层。各家的实现只拼 URLRequest、解析回包；真正发请求的是 HTTPClient，测试时换成假的。
// 默认的 URLSessionHTTPClient：临时会话、不存不带 Cookie（这些接口都是按无 Cookie 的匿名请求写的）、
// 走系统代理（URLSession 默认就读系统设置）、回包有大小上限。

import Foundation

public struct HTTPResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// Retry-After（秒数写法），最多 7 天（照 FluentRead）
    var retryAfter: TimeInterval? {
        guard let value = headers.first(where: { $0.key.lowercased() == "retry-after" })?.value,
              let seconds = TimeInterval(value.trimmingCharacters(in: .whitespaces)), seconds >= 0 else { return nil }
        return min(seconds, 7 * 24 * 3600)
    }

    /// 非 2xx 时抛出分类好的错误
    func requireSuccess(_ provider: String) throws {
        guard (200..<300).contains(status) else {
            throw TranslationError.http(status, retryAfter: retryAfter, message: "\(provider) HTTP \(status)")
        }
    }

    func json(_ provider: String) throws -> Any {
        guard let value = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) else {
            throw TranslationError.invalidResponse(provider)
        }
        return value
    }

    var text: String { String(decoding: body, as: UTF8.self) }
}

public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession
    private let maxBodyBytes: Int

    public init(timeout: TimeInterval = 10, maxBodyBytes: Int = 2 << 20) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        session = URLSession(configuration: configuration)
        self.maxBodyBytes = maxBodyBytes
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw TranslationError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw TranslationError.cancelled
        } catch let error as URLError where error.code == .timedOut {
            throw TranslationError.timeout
        } catch {
            throw TranslationError.unavailable(message: "网络错误：\(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else { throw TranslationError.unavailable(message: "不是 HTTP 回包") }
        guard data.count <= maxBodyBytes else { throw TranslationError.unavailable(message: "回包太大") }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        return HTTPResponse(status: http.statusCode, headers: headers, body: data)
    }
}

extension URLRequest {
    static func post(_ url: URL, json: Any, headers: [String: String] = [:]) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpShouldHandleCookies = false
        return request
    }

    static func post(_ url: URL, form: [(String, String)], headers: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(formEncode(form).utf8)
        request.setValue("application/x-www-form-urlencoded;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpShouldHandleCookies = false
        return request
    }

    static func get(_ url: URL, headers: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpShouldHandleCookies = false
        return request
    }
}

/// application/x-www-form-urlencoded（和 JS 的 URLSearchParams 一样：空格写成 +）
func formEncode(_ fields: [(String, String)]) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._*")
    func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: allowed)?.replacingOccurrences(of: "%20", with: "+") ?? s
    }
    return fields.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
}

func url(_ base: String, query: [(String, String)]) -> URL {
    let separator = base.contains("?") ? "&" : "?"
    return URL(string: base + (query.isEmpty ? "" : separator + formEncode(query)))!
}
