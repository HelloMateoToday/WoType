//
//  VoiceVocabulary.swift
//  WoType
//
//  语音输入的词库：每个词的正确写法（识别时当热词给 Qwen3-ASR）和它的错误写法（识别完换成正确写法）。
//  照 Arion@d2108fe（AGPL-3.0-only）移植：
//  - 词条：packages/core/domain/memory.go 的 MemoryEntry、Recall、Learn、PruneMemory；apps/desktop/infrastructure/vocabulary/vocabulary.go 的 Entry；
//  - 热词：packages/core/domain/hotwords.go（NormalizeHotword、ASRHotwords）；
//  - 替换：packages/core/domain/vocabulary.go（Vocabulary.Apply）、vocabulary_edit.go（NormalizeVocabularyEdit）。
//  Arion 用钥匙串里的密钥加密保存；WoType 的自定义词、选词记忆都是明文，这里也存明文 JSON
//  （~/Library/Application Support/WoType/vocabulary.json）。
//
//  自定义词页里的每个词都是热词：有拼音的同时写进 custom.tsv 给键盘用（CustomWords），没拼音的只给语音用。
//

import Foundation
import os

/// 一条词条：正确写法 to，加一个错误写法 from（只有正确写法的热词 from 为空）。
nonisolated struct VocabularyEntry: Codable, Equatable {
    enum Origin: String, Codable {
        /// 用户在设置里加的
        case user = "user_approved"
        /// 从用户的修改里学到的（改错学习，以后的阶段）
        case edit = "learned_edit"
    }

    var id: String
    var from: String
    var to: String
    var origin: Origin
    var hotword: Bool
    /// 教会这条的修改次数、它纠正过的听写次数
    var uses: Int
    var recalls: Int
    /// Unix 秒
    var created: Int64
    var used: Int64

    init(from: String, to: String, origin: Origin = .user, hotword: Bool, now: Date = Date()) {
        id = UUID().uuidString.lowercased()
        self.from = from
        self.to = to
        self.origin = origin
        self.hotword = hotword
        uses = 0
        recalls = 0
        created = Int64(now.timeIntervalSince1970)
        used = created
    }

    enum CodingKeys: String, CodingKey { case id, from, to, origin, hotword, uses, recalls, created, used }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        from = try c.decodeIfPresent(String.self, forKey: .from) ?? ""
        to = try c.decode(String.self, forKey: .to)
        origin = (try? c.decode(Origin.self, forKey: .origin)) ?? .user
        hotword = try c.decodeIfPresent(Bool.self, forKey: .hotword) ?? false
        uses = try c.decodeIfPresent(Int.self, forKey: .uses) ?? 0
        recalls = try c.decodeIfPresent(Int.self, forKey: .recalls) ?? 0
        created = try c.decodeIfPresent(Int64.self, forKey: .created) ?? 0
        used = try c.decodeIfPresent(Int64.self, forKey: .used) ?? 0
    }
}

/// 一个替换：from 换成 to（memory.go 的 Replacement）。
nonisolated struct VocabularyReplacement: Equatable {
    let from: String
    let to: String
}

final class VoiceVocabulary {
    static let shared = VoiceVocabulary()

    static var fileURL: URL { Paths.userData.appendingPathComponent("vocabulary.json") }

    // hotwords.go
    static let maxHotwords = 64
    static let maxContextRunes = 2048
    nonisolated static let maxHotwordRunes = 64

    enum EditError: Error {
        /// 空的、有控制字符或模型标记、太长、和正确写法一样
        case invalid
        /// 这个错误写法已经属于另一个词
        case conflict
    }

    private(set) var entries: [VocabularyEntry]
    /// 错误写法的索引（词条变了才重建）
    private(set) var index: VocabularyIndex

    private init() {
        entries = Self.load()
        index = VocabularyIndex(Self.replacements(entries))
        // 早先只在 custom.tsv 里的自定义词：补上热词词条
        let missing = CustomWords.load().map(\.word).filter { word in !entries.contains { $0.from.isEmpty && $0.to == word } }
        if !missing.isEmpty {
            // custom.tsv 里新的在前，词条里新的在后
            entries += missing.reversed().compactMap { word in
                (try? Self.normalizeHotword(word)).map { VocabularyEntry(from: "", to: $0, hotword: true) }
            }
            save()
        }
    }

    private static func load() -> [VocabularyEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([VocabularyEntry].self, from: data)) ?? []
    }

    private func save() {
        index = VocabularyIndex(Self.replacements(entries))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try FileManager.default.createDirectory(at: Paths.userData, withIntermediateDirectories: true)
            try encoder.encode(entries).write(to: Self.fileURL, options: .atomic)
        } catch {
            Log.engine.error("词库保存失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - 编辑（设置 › 自定义词）

    /// 正确写法（自定义词页的每一行），按加入的先后，新的在前。
    var terms: [String] {
        var seen = Set<String>()
        return entries.reversed().compactMap { entry in
            guard entry.origin == .user, entry.from.isEmpty, seen.insert(entry.to).inserted else { return nil }
            return entry.to
        }
    }

    /// 这个词的错误写法。
    func variants(of term: String) -> [VocabularyEntry] {
        entries.filter { !$0.from.isEmpty && $0.to == term }
    }

    /// 加一个词（Arion 的 AddHotword）。
    @discardableResult
    func addTerm(_ text: String) throws -> String {
        let term = try Self.normalizeHotword(text)
        if !terms.contains(term) {
            entries.append(VocabularyEntry(from: "", to: term, hotword: true))
            save()
        }
        return term
    }

    /// 删掉一个词和它所有的错误写法。
    func removeTerm(_ term: String) {
        entries.removeAll { $0.to == term && $0.origin == .user }
        save()
    }

    /// 给词加一个错误写法（AddReplacementVariants + vocabulary_edit.go 的 NormalizeVocabularyEdit）。
    func addVariant(_ text: String, to term: String) throws {
        guard Self.validText(text) else { throw EditError.invalid }
        let from = text.trimmingCharacters(in: .whitespaces)
        guard from != term else { throw EditError.invalid }
        if let existing = entries.first(where: { Self.sameSource($0.from, from) }) {
            if existing.to == term { return }
            throw EditError.conflict
        }
        entries.append(VocabularyEntry(from: from, to: term, hotword: false))
        save()
    }

    func removeVariant(id: String) {
        entries.removeAll { $0.id == id }
        save()
    }

    // MARK: - 改错学习（memory.go）

    /// 学到的词最多留多少条（超了先删用得少的；用户加的不删）
    static let maxEntries = 2000
    /// 学到的词多久没用过就过期（像豆包那样）
    static let learnedTTL: TimeInterval = 90 * 24 * 3600

    enum LearnOutcome: String {
        case added, reinforced, replaced, reverted, kept
    }

    /// 学到的词，新的在前。
    var learned: [VocabularyEntry] {
        entries.filter { $0.origin == .edit }.sorted { $0.used > $1.used }
    }

    /// 学一对（Learn）：一样的加强；改回去的（A→B 又 B→A）删掉；同一个错误写法改成了别的就换掉；
    /// 用户自己加的不动。
    /// 返回结果和这一条的 id（撤销用）。
    @discardableResult
    func learn(from: String, to: String, now: Date = Date()) -> (outcome: LearnOutcome, id: String?) {
        let time = Int64(now.timeIntervalSince1970)
        var result: (LearnOutcome, String?)
        if let i = entries.firstIndex(where: { Self.sameSource($0.from, from) && $0.to == to }) {
            entries[i].uses += 1
            entries[i].used = time
            result = (.reinforced, entries[i].id)
        } else if let i = entries.firstIndex(where: { Self.sameSource($0.from, to) && $0.to == from }) {
            guard entries[i].origin == .edit else { return (.kept, nil) }
            result = (.reverted, entries[i].id)
            entries.remove(at: i)
        } else if let i = entries.firstIndex(where: { Self.sameSource($0.from, from) }) {
            guard entries[i].origin == .edit else { return (.kept, nil) }
            entries[i].to = to
            entries[i].uses = 1
            entries[i].used = time
            result = (.replaced, entries[i].id)
        } else {
            var entry = VocabularyEntry(from: from, to: to, origin: .edit, hotword: true, now: now)
            entry.uses = 1
            entries.append(entry)
            result = (.added, entry.id)
        }
        prune(now: now)
        save()
        return result
    }

    func removeLearned(id: String) {
        entries.removeAll { $0.id == id && $0.origin == .edit }
        save()
    }

    /// 过期的、超出上限的学到的词删掉（PruneMemory）。
    private func prune(now: Date) {
        let time = Int64(now.timeIntervalSince1970)
        entries.removeAll { $0.origin == .edit && TimeInterval(time - $0.used) > Self.learnedTTL }
        let excess = entries.count - Self.maxEntries
        guard excess > 0 else { return }
        let drop = entries.indices.filter { entries[$0].origin == .edit }.sorted { a, b in
            let (x, y) = (entries[a], entries[b])
            if x.uses + x.recalls != y.uses + y.recalls { return x.uses + x.recalls < y.uses + y.recalls }
            return x.used < y.used
        }.prefix(excess)
        let dropped = Set(drop)
        entries = entries.indices.filter { !dropped.contains($0) }.map { entries[$0] }
    }

    // MARK: - 识别

    /// 这次听写给识别模型的热词（hotwords.go 的 ASRHotwords）：只给正确写法，不给错误写法。
    /// 用户加的在前，学到的在后，再按用过的次数、最近用过的时间排；最多 64 个、连空格 2048 字。
    func hotwords() -> [String] {
        let ranked = entries.filter(Self.hotwordEligible).sorted { a, b in
            let ea = a.origin == .user && a.hotword, eb = b.origin == .user && b.hotword
            if ea != eb { return ea }
            if a.uses + a.recalls != b.uses + b.recalls { return a.uses + a.recalls > b.uses + b.recalls }
            if a.used != b.used { return a.used > b.used }
            if a.to != b.to { return a.to < b.to }
            return a.id < b.id
        }
        var out: [String] = []
        var seen = Set<String>()
        var size = 0
        for entry in ranked where !seen.contains(entry.to) {
            var n = entry.to.unicodeScalars.count
            if !out.isEmpty { n += 1 }
            if size + n > Self.maxContextRunes { continue }
            out.append(entry.to)
            seen.insert(entry.to)
            size += n
            if out.count == Self.maxHotwords { break }
        }
        return out
    }

    /// 替换生效了的词条记一次（memory.go 的 Recall）。
    func recall(_ fired: [VocabularyReplacement]) {
        guard !fired.isEmpty else { return }
        let now = Int64(Date().timeIntervalSince1970)
        for f in fired {
            if let i = entries.firstIndex(where: { Self.sameSource($0.from, f.from) && $0.to == f.to }) {
                entries[i].recalls += 1
                entries[i].used = now
            }
        }
        save()
    }

    // MARK: - 规则

    /// 一个热词：不截断，有控制字符、格式字符、模型标记（<| |>）或超过 64 字就不收（NormalizeHotword）。
    nonisolated static func normalizeHotword(_ text: String) throws -> String {
        guard validText(text), !text.contains("<|"), !text.contains("|>") else { throw EditError.invalid }
        for scalar in text.unicodeScalars {
            if scalar.properties.generalCategory == .format || scalar == "\u{2028}" || scalar == "\u{2029}" {
                throw EditError.invalid
            }
        }
        let term = text.trimmingCharacters(in: .whitespaces)
        guard term.unicodeScalars.count <= maxHotwordRunes else { throw EditError.invalid }
        return term
    }

    nonisolated private static func hotwordEligible(_ entry: VocabularyEntry) -> Bool {
        guard entry.hotword || entry.origin == .edit,
              let term = try? normalizeHotword(entry.to), term == entry.to else { return false }
        return entry.origin != .edit || term.unicodeScalars.count <= 16
    }

    /// 不空、没有控制字符（validVocabularyText）。
    nonisolated static func validText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty
            && !text.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    /// 错误写法按小写比较（SameVocabularySource）。
    static func sameSource(_ a: String, _ b: String) -> Bool { a.lowercased() == b.lowercased() }

    private static func replacements(_ entries: [VocabularyEntry]) -> [VocabularyReplacement] {
        entries.filter { !$0.from.isEmpty }.map { VocabularyReplacement(from: $0.from, to: $0.to) }
    }
}

/// 错误写法的索引（vocabulary.go 的 Vocabulary）：按第一个字（小写）分桶，替换时只扫一遍文字。
/// 建好就不变，可以在别的线程用。
nonisolated struct VocabularyIndex: Sendable {
    private struct Pattern: Sendable {
        let scalars: [Unicode.Scalar]
        let entry: Int
    }

    private var entries: [VocabularyReplacement] = []
    private var from: [Unicode.Scalar: [Pattern]] = [:]
    /// 错误写法和正确写法都索引（Terms 用）
    private var both: [Unicode.Scalar: [Pattern]] = [:]

    init(_ replacements: [VocabularyReplacement]) {
        var seen: [String: Int] = [:]
        for r in replacements {
            let f = r.from.trimmingCharacters(in: .whitespaces), t = r.to.trimmingCharacters(in: .whitespaces)
            if f.isEmpty || t.isEmpty || f == t { continue }
            // 两条的错误写法一样时，后面的算
            if let at = seen[f.lowercased()] {
                entries[at] = VocabularyReplacement(from: f, to: t)
                continue
            }
            seen[f.lowercased()] = entries.count
            entries.append(VocabularyReplacement(from: f, to: t))
        }
        for (i, r) in entries.enumerated() {
            let scalars = Self.lower(Array(r.from.unicodeScalars))
            from[scalars[0], default: []].append(Pattern(scalars: scalars, entry: i))
            both[scalars[0], default: []].append(Pattern(scalars: scalars, entry: i))
            let to = Self.lower(Array(r.to.unicodeScalars))
            both[to[0], default: []].append(Pattern(scalars: to, entry: i))
        }
        // 长的在前：同一个位置最长的匹配算
        for key in from.keys {
            from[key]?.sort { $0.scalars.count > $1.scalars.count }
        }
        for key in both.keys {
            both[key]?.sort { $0.scalars.count > $1.scalars.count }
        }
    }

    var isEmpty: Bool { entries.isEmpty }

    /// 从左到右一遍换掉所有错误写法：英文按整词、不分大小写，中文精确匹配，最长的优先；
    /// 换过的地方不再匹配（不会连着换）。返回生效了的词条，按文字里的先后，不重复。
    func apply(_ s: String) -> (String, [VocabularyReplacement]) {
        guard !entries.isEmpty, !s.isEmpty else { return (s, []) }
        let text = Array(s.unicodeScalars)
        let lower = Self.lower(text)
        var out = String.UnicodeScalarView()
        var fired: [VocabularyReplacement] = []
        var used = Set<Int>()
        var last = 0
        var k = 0
        while k < text.count {
            guard let p = match(text, lower, k) else {
                k += 1
                continue
            }
            out.append(contentsOf: text[last..<k])
            out.append(contentsOf: entries[p.entry].to.unicodeScalars)
            if used.insert(p.entry).inserted { fired.append(entries[p.entry]) }
            k += p.scalars.count
            last = k
        }
        if fired.isEmpty { return (s, []) }
        out.append(contentsOf: text[last...])
        return (String(out), fired)
    }

    /// 文字里出现了错误写法或正确写法的词条，返回它们的正确写法（Terms）：几个错误写法共用一个名额；
    /// 错误写法只是替换的依据，不给模型当拼写候选。
    func terms(_ text: String, limit: Int) -> [String] {
        guard !entries.isEmpty, !text.isEmpty, limit > 0 else { return [] }
        let scalars = Array(text.unicodeScalars)
        let lower = Self.lower(scalars)
        var out: [String] = []
        var used = Set<String>()
        var k = 0
        while k < scalars.count, out.count < limit {
            guard let p = match(scalars, lower, k, in: both) else {
                k += 1
                continue
            }
            let canonical = entries[p.entry].to
            if used.insert(canonical).inserted { out.append(canonical) }
            k += p.scalars.count
        }
        return out
    }

    private func match(_ text: [Unicode.Scalar], _ lower: [Unicode.Scalar], _ k: Int,
                       in index: [Unicode.Scalar: [Pattern]]? = nil) -> Pattern? {
        for p in (index ?? from)[lower[k]] ?? [] {
            let end = k + p.scalars.count
            guard end <= lower.count, Array(lower[k..<end]) == p.scalars else { continue }
            if Self.boundary(text, k, end) { return p }
        }
        return nil
    }

    /// 不拆开英文单词或数字（runeBoundary）。
    private static func boundary(_ text: [Unicode.Scalar], _ start: Int, _ end: Int) -> Bool {
        if start > 0, latinOrDigit(text[start - 1]), latinOrDigit(text[start]) { return false }
        if end < text.count, latinOrDigit(text[end]), latinOrDigit(text[end - 1]) { return false }
        return true
    }

    static func latinOrDigit(_ s: Unicode.Scalar) -> Bool {
        s.isASCII && (s.properties.isAlphabetic || s.properties.numericType != nil)
    }

    private static func lower(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        scalars.map { s in
            let mapped = s.properties.lowercaseMapping.unicodeScalars
            return mapped.count == 1 ? mapped.first! : s
        }
    }
}
