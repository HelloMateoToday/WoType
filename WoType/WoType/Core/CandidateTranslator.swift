//
//  CandidateTranslator.swift
//  WoType
//
//  候选翻译：候选窗开着时单按 ⌃，把高亮的候选（连同已经选好的那段）翻成设置里的语言，显示在候选窗底下的译文条里，
//  ⏎ 上屏译文（docs/14）。翻译用 FreeTranslate（Packages/FreeTranslate），只在主线程用。
//

import Foundation
import FreeTranslate
import os

final class CandidateTranslator {

    static let shared = CandidateTranslator()

    /// 候选窗底下的译文条。
    struct Bar: Equatable {
        enum State: Equatable {
            case translating
            case done(String)
            case failed(String)
        }
        /// 翻的原文
        let source: String
        /// 原文是整句（选它就把拼音用完了）：只有这时译文能上屏
        let complete: Bool
        var state: State

        /// 按 ⏎ 能上屏的译文
        var committable: String? {
            guard complete, case .done(let text) = state else { return nil }
            return text
        }
    }

    /// 现在显示的译文条；nil 是没有
    private(set) var bar: Bar?
    /// 译文条变了（翻完、失败）：InputController 重画候选窗
    var onChange: (() -> Void)?

    /// 引擎、目标语言一样时复用同一个池子（冷却、缓存都在池子里）
    private var pool: (engine: String, pool: TranslationPool)?
    private var task: Task<Void, Never>?

    /// 设置里的引擎：auto 和 FreeTranslate 各家（id、显示名）
    static let engines: [(id: String, name: String)] = [("auto", "自动")]
        + FreeTranslate.defaultProviders().map { ($0.id, $0.name) }

    /// 这家能不能翻成这种语言（设置界面提示用）。auto 总是能
    static func engine(_ id: String, supports target: String) -> Bool {
        guard id != "auto" else { return true }
        return FreeTranslate.defaultProviders().first { $0.id == id }?.supports(from: nil, to: Language(target)) ?? false
    }

    /// 单按 ⌃：翻 source。正在显示同一句的译文时收起；上次失败了就重试。
    func toggle(source: String, complete: Bool) {
        if let bar, bar.source == source {
            switch bar.state {
            case .translating:
                return
            case .done:
                dismiss()
                onChange?()
                return
            case .failed:
                break
            }
        }
        let retry = bar?.source == source
        task?.cancel()
        bar = Bar(source: source, complete: complete, state: .translating)
        let config = Settings.shared.config
        let target = Language(config.translationTarget)
        let pool = pool(for: config.translationEngine)
        task = Task { [weak self] in
            // 指定了一家时，用户再按一次就是想马上再试：不等它冷却完
            if retry, config.translationEngine != "auto" { await pool.resetCooldowns() }
            let state: Bar.State
            do {
                let result = try await pool.translate(source, to: target)
                state = .done(result.text.trimmingCharacters(in: .whitespacesAndNewlines))
                Log.input.debug("候选翻译：\(result.provider, privacy: .public)")
            } catch {
                if Task.isCancelled { return }
                state = .failed(Self.message(error, engine: config.translationEngine))
                Log.input.info("候选翻译失败：\(String(describing: error), privacy: .public)")
            }
            guard let self, !Task.isCancelled, self.bar?.source == source else { return }
            self.bar?.state = state
            self.onChange?()
        }
        onChange?()
    }

    /// 收起译文条（换了高亮、接着打字、Esc、上屏）。
    func dismiss() {
        task?.cancel()
        task = nil
        bar = nil
    }

    private func pool(for engine: String) -> TranslationPool {
        if let pool, pool.engine == engine { return pool.pool }
        let providers = FreeTranslate.defaultProviders()
        let chosen = engine == "auto" ? providers : providers.filter { $0.id == engine }
        // 打字时等不了太久：单次 4 秒，换家总共 8 秒
        let created = TranslationPool(providers: chosen.isEmpty ? providers : chosen,
                                      configuration: .init(attemptTimeout: 4, totalTimeout: 8))
        pool = (engine, created)
        return created
    }

    private static func message(_ error: Error, engine: String) -> String {
        let name = engines.first { $0.id == engine && engine != "auto" }?.name
        switch error as? TranslationError {
        case .unsupported?:
            return "\(name ?? "翻译引擎")不支持翻成这种语言"
        case .timeout?:
            return "\(name ?? "翻译服务")超时了"
        default:
            return name.map { "\($0)暂时用不了" } ?? "翻译服务暂时用不了，检查网络"
        }
    }
}
