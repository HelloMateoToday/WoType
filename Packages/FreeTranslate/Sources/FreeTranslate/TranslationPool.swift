// TranslationPool.swift — 多家备选的翻译池（照 FluentRead 的免费翻译池 free-translation.ts、freeRoutingPolicy.ts）：
// 按权重随机挑一家，失败换下一家；失败按类别冷却；每家有自己的并发数和请求间隔；单次超时、整次超时；结果缓存。

import Foundation

public actor TranslationPool {

    public struct Configuration: Sendable {
        /// 各家的权重（没写的按 1），越大越常被先挑
        public var weights: [String: Double]
        /// 每家一次尝试最多等多久
        public var attemptTimeout: TimeInterval
        /// 一次调用（含换家）最多等多久
        public var totalTimeout: TimeInterval
        /// 缓存多少条（0 不缓存）
        public var cacheCapacity: Int

        public init(weights: [String: Double] = FreeTranslate.defaultWeights, attemptTimeout: TimeInterval = 5,
                    totalTimeout: TimeInterval = 20, cacheCapacity: Int = 512) {
            self.weights = weights
            self.attemptTimeout = attemptTimeout
            self.totalTimeout = totalTimeout
            self.cacheCapacity = cacheCapacity
        }
    }

    public struct ProviderStatus: Sendable {
        public let id: String
        public let name: String
        /// 冷却到什么时候（nil 是可用）
        public let cooldownUntil: Date?
        /// 最近一次失败的原因
        public let lastFailure: String?
    }

    private let providers: [TranslationProvider]
    private let http: HTTPClient
    private let configuration: Configuration
    private let now: @Sendable () -> Date
    private let random: @Sendable () -> Double

    private var cooldowns: [String: (until: Date, strikes: Int)] = [:]
    private var lastFailure: [String: String] = [:]
    private var inFlight: [String: Int] = [:]
    private var lastStart: [String: Date] = [:]
    private var cache: [String: Translation] = [:]
    private var cacheOrder: [String] = []

    public init(providers: [TranslationProvider] = FreeTranslate.defaultProviders(),
                configuration: Configuration = Configuration(),
                http: HTTPClient = URLSessionHTTPClient(),
                now: @escaping @Sendable () -> Date = { Date() },
                random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }) {
        self.providers = providers
        self.configuration = configuration
        self.http = http
        self.now = now
        self.random = random
    }

    /// 翻一条。from 是 nil 表示自动识别。
    public func translate(_ text: String, from: Language? = nil, to: Language) async throws -> Translation {
        try await translate([text], from: from, to: to)[0]
    }

    /// 翻多条：缓存里有的直接用，其余一起交给同一家。
    public func translate(_ texts: [String], from: Language? = nil, to: Language) async throws -> [Translation] {
        var results = [Translation?](repeating: nil, count: texts.count)
        var missing: [Int] = []
        for (index, text) in texts.enumerated() {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                results[index] = Translation(text: text, provider: "")
            } else if let cached = cache[cacheKey(text, from: from, to: to)] {
                results[index] = cached
            } else {
                missing.append(index)
            }
        }
        if !missing.isEmpty {
            let pending = missing.map { texts[$0] }
            let translated = try await translateWithFallback(pending, from: from, to: to)
            for (index, translation) in zip(missing, translated) {
                results[index] = translation
                remember(translation, for: cacheKey(texts[index], from: from, to: to))
            }
        }
        return results.map { $0! }
    }

    /// 各家现在的状态（检查工具、设置界面用）
    public func status() -> [ProviderStatus] {
        let current = now()
        return providers.map { provider in
            let until = cooldowns[provider.id].flatMap { $0.until > current ? $0.until : nil }
            return ProviderStatus(id: provider.id, name: provider.name, cooldownUntil: until, lastFailure: lastFailure[provider.id])
        }
    }

    /// 清掉冷却（比如网络恢复了）
    public func resetCooldowns() {
        cooldowns = [:]
    }

    // MARK: - 换家

    private func translateWithFallback(_ texts: [String], from: Language?, to: Language) async throws -> [Translation] {
        let deadline = now().addingTimeInterval(configuration.totalTimeout)
        var failures: [String: String] = [:]
        let candidates = orderedCandidates(from: from, to: to)
        guard !candidates.isEmpty else {
            throw providers.contains(where: { $0.supports(from: from, to: to) })
                ? TranslationError.allFailed(Dictionary(uniqueKeysWithValues: providers.compactMap { p in
                    lastFailure[p.id].map { (p.name, "冷却中：\($0)") } }))
                : TranslationError.unsupported
        }
        for provider in candidates {
            try Task.checkCancellation()
            let remaining = deadline.timeIntervalSince(now())
            guard remaining > 0 else {
                failures[provider.name] = "没来得及试（整次超时）"
                break
            }
            guard (inFlight[provider.id] ?? 0) < provider.limits.maxConcurrent else {
                failures[provider.name] = "正忙"
                continue
            }
            // 两次请求之间的间隔
            if let last = lastStart[provider.id] {
                let wait = provider.limits.minInterval - now().timeIntervalSince(last)
                if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
            }
            lastStart[provider.id] = now()
            inFlight[provider.id, default: 0] += 1
            let http = self.http
            let timeout = min(configuration.attemptTimeout, deadline.timeIntervalSince(now()))
            let outcome: Result<[String], Error>
            do {
                outcome = .success(try await withTimeout(timeout) {
                    try await provider.translate(texts, from: from, to: to, http: http)
                })
            } catch {
                outcome = .failure(error)
            }
            inFlight[provider.id] = max((inFlight[provider.id] ?? 1) - 1, 0)
            do {
                let output = try outcome.get()
                try validate(output, texts: texts, to: to, provider: provider.name)
                cooldowns[provider.id] = nil
                lastFailure[provider.id] = nil
                return output.map { Translation(text: $0, provider: provider.id) }
            } catch {
                if error is CancellationError || Task.isCancelled { throw TranslationError.cancelled }
                let failure: TranslationError
                if let validation = error as? ValidationFailure {
                    // 结果检查不过（原样返回、空译文）当暂时不可用
                    failure = .unavailable(message: validation.message)
                } else {
                    failure = error as? TranslationError ?? .unavailable(message: "\(error)")
                }
                if case .cancelled = failure { throw failure }
                record(failure, for: provider)
                failures[provider.name] = failure.description
            }
        }
        throw TranslationError.allFailed(failures)
    }

    /// 可用、支持这个方向的几家，按权重随机排序（权重大的大概率排前面）
    private func orderedCandidates(from: Language?, to: Language) -> [TranslationProvider] {
        let current = now()
        let usable = providers.filter { provider in
            provider.supports(from: from, to: to) && (cooldowns[provider.id].map { $0.until <= current } ?? true)
        }
        // 加权随机排序（Efraimidis–Spirakis）：键 = u^(1/w)，从大到小
        return usable.map { provider -> (TranslationProvider, Double) in
            let weight = max(configuration.weights[provider.id] ?? 1, 0.001)
            return (provider, pow(max(random(), 1e-12), 1 / weight))
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }

    /// 结果检查：条数对、不空；中文原样返回（目标不是中文时）算没翻
    private func validate(_ output: [String], texts: [String], to: Language, provider: String) throws {
        guard output.count == texts.count else { throw ValidationFailure(message: "\(provider)返回条数不对") }
        for (source, result) in zip(texts, output) {
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ValidationFailure(message: "\(provider)返回空译文") }
            if !to.isChinese, containsHan(source), trimmed == source.trimmingCharacters(in: .whitespacesAndNewlines) {
                throw ValidationFailure(message: "\(provider)原样返回了中文")
            }
        }
    }

    // MARK: - 冷却

    /// 照 FluentRead 的 freeRoutingPolicy：请求错不冷却；额度 24 小时；被封 6 小时起翻倍到 24 小时；
    /// 限流 5 分钟起翻倍到 6 小时（有 Retry-After 用它）；暂时不可用、超时 60 秒起翻倍到 30 分钟。再加最多 20% 的抖动。
    private func record(_ failure: TranslationError, for provider: TranslationProvider) {
        lastFailure[provider.id] = failure.description
        let strikes = (cooldowns[provider.id]?.strikes ?? 0) + 1
        let base: TimeInterval?
        switch failure {
        case .request, .unsupported, .cancelled, .allFailed: base = nil
        case .quota: base = 24 * 3600
        case .blocked: base = min(6 * 3600 * pow(2, Double(strikes - 1)), 24 * 3600)
        case .rateLimited(let retryAfter): base = retryAfter ?? min(300 * pow(2, Double(strikes - 1)), 6 * 3600)
        case .unavailable, .timeout: base = min(60 * pow(2, Double(strikes - 1)), 1800)
        }
        guard let base else { return }
        cooldowns[provider.id] = (now().addingTimeInterval(base * (1 + 0.2 * random())), strikes)
    }

    // MARK: - 缓存

    private func cacheKey(_ text: String, from: Language?, to: Language) -> String {
        "\(from?.code ?? "auto")>\(to.code)|\(text)"
    }

    private func remember(_ translation: Translation, for key: String) {
        guard configuration.cacheCapacity > 0 else { return }
        if cache[key] == nil { cacheOrder.append(key) }
        cache[key] = translation
        while cacheOrder.count > configuration.cacheCapacity {
            cache[cacheOrder.removeFirst()] = nil
        }
    }
}

/// 结果检查没过：当这家暂时不可用
struct ValidationFailure: Error {
    let message: String
}

/// 超时就抛 TranslationError.timeout，并取消还在跑的那个
func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    guard seconds > 0 else { throw TranslationError.timeout }
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TranslationError.timeout
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw TranslationError.timeout }
        return result
    }
}
