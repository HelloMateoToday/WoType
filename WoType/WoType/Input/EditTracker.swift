//
//  EditTracker.swift
//  WoType
//
//  改错学习：语音插入以后看着这个输入框，用户改完了就比一比改了哪些词，记成错误写法 → 正确写法。
//  照 Arion packages/core/application/learning.go@d2108fe（AGPL-3.0-only）的 EditTracker：
//  每 0.4 秒读一次；插入的字 2 秒内没出现在框里就不跟了；15 秒没再改、框失去焦点、清空了（消息发出去了）、
//  开始下一次听写、最多 60 秒，就算改完了；连着读不出来 3 次就放弃。改了什么由 Rust 判断
//  （engine/core/src/polish/learning.rs），分词用 CFStringTokenizer（Arion 的 wordseg 也是它）。
//  和 Arion 不同：读输入框问的是 IMKTextInput，不用辅助功能；框里超过 5000 个字的不跟（不读整篇长文档）。
//  学到新词或改了旧词时，浮窗显示「已记住」5 秒，可以撤销（bootstrap/learning.go 的 learnEdit、showLearned，
//  actions.go 的 UndoLearned）。
//

import Foundation
import InputMethodKit
import os

@MainActor
final class EditTracker {
    static let shared = EditTracker()

    static let poll: TimeInterval = 0.4
    static let idle: TimeInterval = 15
    static let maxTrack: TimeInterval = 60
    static let baselineWait: TimeInterval = 2
    static let readFailures = 3
    /// 框里的字超过这么多（UTF-16）就不跟
    static let maxField = 5000

    private struct Tracking {
        let client: ObjectIdentifier
        let inserted: String
        let start: Date
        var baseline = ""
        var last = ""
        var changed = Date()
        var failures = 0
    }

    private var tracking: Tracking?
    private var timer: Timer?
    /// 「已记住」提示的那条：撤销时删掉它，最近的听写改回去
    private var undo: (id: String, revisions: [VoiceHistory.Revision])?

    private init() {
        VoiceCapsule.shared.onUndo = { id in EditTracker.shared.undoLearned(id) }
    }

    /// 撤销刚学到的词（UndoLearned）。
    private func undoLearned(_ id: String) {
        VoiceVocabulary.shared.removeLearned(id: id)
        if let undo, undo.id == id { VoiceHistory.shared.restore(undo.revisions) }
        undo = nil
        Log.input.info("改错学习：撤销了刚学到的词")
    }

    /// 插入以后开始跟（之前在跟的先算改完了）。
    func track(client: IMKTextInput, inserted: String) {
        settle(reason: "next")
        guard Settings.shared.config.voiceLearnEdits, !inserted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        tracking = Tracking(client: ObjectIdentifier(client as AnyObject), inserted: inserted, start: Date())
        timer = Timer.scheduledTimer(withTimeInterval: Self.poll, repeats: true) { _ in
            MainActor.assumeIsolated { EditTracker.shared.tick() }
        }
    }

    /// 开始下一次听写时：在跟的算改完了。
    func next() {
        settle(reason: "next")
    }

    private func tick() {
        guard var t = tracking else { return }
        let now = Date()
        // 现在的输入框不是插入的那个了：失去焦点
        guard let client = InputController.current?.client(), ObjectIdentifier(client as AnyObject) == t.client else {
            return settle(reason: t.baseline.isEmpty ? "baseline" : "focus")
        }
        guard let text = Self.read(client) else {
            t.failures += 1
            tracking = t
            if t.failures >= Self.readFailures { settle(reason: "abandon") }
            return
        }
        t.failures = 0
        if t.baseline.isEmpty {
            if text.contains(t.inserted) {
                t.baseline = text
                t.last = text
                t.changed = now
            } else if now.timeIntervalSince(t.start) > Self.baselineWait {
                tracking = t
                return settle(reason: "baseline")
            }
            tracking = t
            return
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tracking = t
            return settle(reason: "cleared")
        }
        if text != t.last {
            t.last = text
            t.changed = now
        }
        tracking = t
        if now.timeIntervalSince(t.changed) >= Self.idle {
            settle(reason: "idle")
        } else if now.timeIntervalSince(t.start) >= Self.maxTrack {
            settle(reason: "max")
        }
    }

    /// 算改完了：有起点（刚插入后的框）就比一比，学到的记进词库。
    private func settle(reason: String) {
        timer?.invalidate()
        timer = nil
        guard let t = tracking else { return }
        tracking = nil
        guard !t.baseline.isEmpty, reason != "abandon", reason != "baseline" else { return }
        let (verdict, pairs) = Self.extract(inserted: t.inserted, baseline: t.baseline, settled: t.last)
        Log.input.info("改错学习：\(reason, privacy: .public) → \(verdict, privacy: .public)，\(pairs.count) 对")
        guard Settings.shared.config.voiceLearnEdits else { return }
        // 只提示新学到的、改了的最后一对（加强、删掉的不提示）
        var shown: (id: String, from: String, to: String, revisions: [VoiceHistory.Revision])?
        for (from, to) in pairs {
            let result = VoiceVocabulary.shared.learn(from: from, to: to)
            let revisions = VoiceHistory.shared.revise(from: from, to: to)
            if let id = result.id, result.outcome == .added || result.outcome == .replaced {
                shown = (id, from, to, revisions)
            }
        }
        if let shown {
            undo = (shown.id, shown.revisions)
            VoiceCapsule.shared.showLearned(id: shown.id, from: shown.from, to: shown.to)
        }
    }

    /// 读整个框（太长、读不出来返回 nil）。
    private static func read(_ client: IMKTextInput) -> String? {
        let length = client.length()
        guard length >= 0, length <= maxField else { return nil }
        if length == 0 { return "" }
        return client.attributedSubstring(from: NSRange(location: 0, length: length))?.string
    }

    nonisolated static func extract(inserted: String, baseline: String, settled: String) -> (String, [(String, String)]) {
        var capacity = 1024
        while true {
            var buffer = [CChar](repeating: 0, count: capacity)
            let needed = buffer.withUnsafeMutableBufferPointer { out in
                wotype_polish_learn(inserted, baseline, settled, segment, out.baseAddress, capacity)
            }
            if needed < capacity {
                let lines = String(cString: buffer).components(separatedBy: "\n")
                let pairs = lines.dropFirst().compactMap { line -> (String, String)? in
                    let parts = line.components(separatedBy: "\t")
                    return parts.count == 2 ? (parts[0], parts[1]) : nil
                }
                return (lines.first ?? "", pairs)
            }
            capacity = needed + 1
        }
    }
}

/// 分词回调（给 Rust）：CFStringTokenizer 按词切，把 UTF-16 位置换成 Unicode 字符的位置。
nonisolated private let segment: WotypeSegmenter = { text, spans, capacity in
    guard let text, let spans else { return -1 }
    let string = String(cString: text)
    let utf16 = Array(string.utf16)
    // UTF-16 位置 → 字符位置（代理对的后半个是 -1）
    var offsets = [Int](repeating: -1, count: utf16.count + 1)
    var unit = 0
    var point = 0
    for scalar in string.unicodeScalars {
        offsets[unit] = point
        unit += scalar.utf16.count
        point += 1
    }
    offsets[unit] = point
    let cf = string as CFString
    guard let tokenizer = CFStringTokenizerCreate(nil, cf, CFRange(location: 0, length: utf16.count),
                                                  kCFStringTokenizerUnitWord, nil) else { return -1 }
    var count = 0
    while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
        let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
        let end = range.location + range.length
        guard range.location >= 0, range.length > 0, end <= utf16.count,
              offsets[range.location] >= 0, offsets[end] >= 0 else { return -1 }
        guard (count + 1) * 2 <= capacity else { return -1 }
        spans[count * 2] = UInt32(offsets[range.location])
        spans[count * 2 + 1] = UInt32(offsets[end])
        count += 1
    }
    return count
}
