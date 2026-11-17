//
//  SystemTranslation.swift
//  WoType
//
//  翻译窗口的「系统翻译」（docs/16）：macOS 自带的 Translation 框架，离线。
//  macOS 26 起有不经过 SwiftUI 的 TranslationSession(installedSource:target:)（Easydict 在 macOS 15 上靠 SwiftUI 的
//  .translationTask，WoType 不用 SwiftUI），只能用已经下载好的语言，没下载的不弹系统的下载窗，提示去系统设置下载。
//  单独一个文件：Translation 框架也有 TranslationError，和 FreeTranslate 的重名。
//

import Foundation
import os
import Translation

enum SystemTranslation {

    enum Failure: Error {
        /// 支持，但语言还没下载
        case notInstalled
        case unsupported
        case failed
    }

    /// source、target 是语言代码（zh-Hans、en…）
    @available(macOS 26.0, *)
    static func translate(_ text: String, from source: String, to target: String) async throws -> String {
        let from = Locale.Language(identifier: source), to = Locale.Language(identifier: target)
        switch await LanguageAvailability().status(from: from, to: to) {
        case .installed: break
        case .supported: throw Failure.notInstalled
        default: throw Failure.unsupported
        }
        let session = TranslationSession(installedSource: from, target: to)
        do {
            return try await session.translate(text).targetText.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            Log.input.error("系统翻译失败：\(String(describing: error), privacy: .public)")
            throw Failure.failed
        }
    }
}
