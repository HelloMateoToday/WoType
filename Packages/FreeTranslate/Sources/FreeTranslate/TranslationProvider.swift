// TranslationProvider.swift — 一家翻译服务。各家只管拼请求、解析回包；换家、冷却、超时、缓存在 TranslationPool。

import Foundation

public protocol TranslationProvider: Sendable {
    /// 稳定的标识：microsoft、transmart、volcengine、youdao、iciba、bilibili、google
    var id: String { get }
    /// 显示名：微软翻译、腾讯交互翻译……
    var name: String { get }
    /// 同时最多几个请求、两次请求至少隔多久（照 FluentRead 的免费池设置）
    var limits: ProviderLimits { get }
    /// from 是 nil 表示自动识别源语言
    func supports(from: Language?, to: Language) -> Bool
    /// 按顺序返回译文，个数和 texts 一样。只接受单条的服务逐条翻。
    func translate(_ texts: [String], from: Language?, to: Language, http: HTTPClient) async throws -> [String]
}

public struct ProviderLimits: Sendable {
    public var maxConcurrent: Int
    public var minInterval: TimeInterval

    public init(maxConcurrent: Int = 1, minInterval: TimeInterval = 0.3) {
        self.maxConcurrent = maxConcurrent
        self.minInterval = minInterval
    }
}

/// 一条译文和翻它的那家
public struct Translation: Sendable, Equatable {
    public let text: String
    public let provider: String

    public init(text: String, provider: String) {
        self.text = text
        self.provider = provider
    }
}

/// 只接受一条文字的服务：逐条、逐块翻
protocol SingleTextProvider: TranslationProvider {
    /// 一块最多多少个码点
    var chunkLimit: Int { get }
    func translateChunk(_ text: String, from: Language?, to: Language, http: HTTPClient) async throws -> String
}

extension SingleTextProvider {
    public func translate(_ texts: [String], from: Language?, to: Language, http: HTTPClient) async throws -> [String] {
        guard supports(from: from, to: to) else { throw TranslationError.unsupported }
        var results: [String] = []
        for text in texts {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                results.append(text)
                continue
            }
            results.append(try await TextChunks.translate(text, limit: chunkLimit) { chunk in
                try Task.checkCancellation()
                return try await translateChunk(chunk, from: from, to: to, http: http)
            })
        }
        return results
    }
}

/// FreeTranslate 自带的各家
public enum FreeTranslate {
    /// 第一期的 7 家，按 FluentRead 的默认权重从高到低
    public static func defaultProviders(clock: @escaping @Sendable () -> Date = { Date() }) -> [TranslationProvider] {
        [MicrosoftProvider(), GoogleProvider(), TransmartProvider(), VolcengineProvider(),
         YoudaoProvider(clock: clock), IcibaProvider(), BilibiliProvider()]
    }

    /// FluentRead 的默认权重（free-translation 池的 defaultWeight）
    public static let defaultWeights: [String: Double] = [
        "microsoft": 5, "google": 3, "transmart": 3, "volcengine": 3, "youdao": 3, "iciba": 3, "bilibili": 2,
    ]
}
