//
//  CloudCandidates.swift
//  WoType
//
//  云候选的网络请求（照水杉 macOS 宿主的 platforms/macos/src/cloud/CloudCandidateRequest.mm）：
//  请求的地址、方法、头和体都由水杉给（msime_client_online_query / msime_client_cloud_request_url），
//  这里只负责发出去：临时会话、不带 Cookie、不跟随重定向、只收 2xx、回包最多 256 KiB。
//  走系统代理（URLSession 默认就读系统的代理设置）。
//  另外给设置页用：打开云候选前先试一次能不能连上 Google。
//

import Foundation

enum CloudCandidates {

    /// 水杉的上限（MSIME_CLOUD_REQUEST_TIMEOUT_MS、回包 256 KiB）
    static let defaultTimeout: TimeInterval = 2
    static let maxResponseBytes = 262_144

    /// 发一次请求，回包（失败、超时、非 2xx、太大都是 nil）在主线程交回。返回的任务可以取消。
    @discardableResult
    static func send(_ request: URLRequest, completion: @escaping (Data?) -> Void) -> URLSessionDataTask {
        let task = session.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = error == nil && (200..<300).contains(status) && (data?.count ?? 0) <= maxResponseBytes ? data : nil
            DispatchQueue.main.async { completion(body) }
        }
        task.resume()
        return task
    }

    /// 按水杉给的描述（OnlineQuery.cloud_request，或兼容的 GET 地址）拼请求；不合规矩的不发。
    static func request(url: String, method: String = "GET", headers: [String: String] = [:],
                        body: String? = nil, timeout: TimeInterval = defaultTimeout) -> URLRequest? {
        guard let url = URL(string: url), url.scheme == "https" || isLoopback(url),
              url.user == nil, url.password == nil, url.fragment == nil,
              method == "GET" || method == "POST" else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if method == "POST", let body {
            request.httpBody = Data(body.utf8)
        }
        return request
    }

    /// 自定义服务在本机时可以用 http（水杉的规则）
    private static func isLoopback(_ url: URL) -> Bool {
        url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(url.host ?? "")
    }

    // MARK: - 设置页：打开前先试一次

    /// 用一个固定的拼音问一次 Google input-tools（和水杉拼出来的地址同一个格式），能拿到候选就算能用。
    static func checkGoogle(completion: @escaping (Bool) -> Void) {
        let probe = "https://inputtools.google.com/request?text=nihao&itc=zh-t-i0-pinyin&num=1&ie=utf-8&oe=utf-8"
        guard let request = request(url: probe, timeout: 5) else { return completion(false) }
        send(request) { body in
            let text = body.map { String(decoding: $0, as: UTF8.self) } ?? ""
            completion(text.hasPrefix("[\"SUCCESS\""))
        }
    }

    // MARK: -

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 10
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

    /// 不跟随重定向（照水杉：重定向可能把拼音带到别的地方去）
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
