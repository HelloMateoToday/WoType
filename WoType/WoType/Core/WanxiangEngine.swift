//
//  WanxiangEngine.swift
//  WoType
//
//  万象拼音引擎（engine/core 的 wotype_engine_*，docs/15）的 Swift 包装：词库、语法模型、用户数据。
//  全进程一份，只在主线程用；载入在后台线程做。2026-11-11 删掉、11-12 从 76a9241 的 Engine.swift 取回，
//  会话见 WanxiangSession.swift。
//

import AppKit
import CoreText
import Foundation
import os

final class WanxiangEngine {

    static let shared = WanxiangEngine()

    /// 载入完成前为 nil；这时会话为 nil，按键交给应用。
    private(set) var handle: OpaquePointer?
    private var loading = false
    /// 距离上次保存用户词库的上屏次数。
    private var unsavedCommits = 0
    /// 上次交给引擎、会话的设置：设置页改的不是这几项就不用重来
    private var appliedSettings: WanxiangSettings?

    /// 随包的词库、英文词表、混合编码词表、简繁表（scripts/copy-data.sh）。
    nonisolated static var bundledData: URL { Paths.bundledData.appendingPathComponent("wanxiang", isDirectory: true) }

    nonisolated static func bundled(_ name: String) -> URL? {
        let url = bundledData.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 万象自己的用户数据：学到的词、输入习惯、语法模型、在线更新的词库（docs/15）。
    /// 换水杉之前这些直接放在 Application Support/WoType/ 下，第一次载入时挪进来（moveLegacyData）
    nonisolated static var dataDirectory: URL {
        let url = Paths.userData.appendingPathComponent("wanxiang", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    nonisolated static var userDict: URL { dataDirectory.appendingPathComponent("user.tsv") }
    nonisolated static var history: URL { dataDirectory.appendingPathComponent("history.tsv") }
    /// 记住的邮箱后缀（上屏过的、不在内置表里的，一行一个，只存 @ 后面的部分）
    nonisolated static var mailDomains: URL { dataDirectory.appendingPathComponent("mail-domains.txt") }

    /// 旧版放在 Application Support/WoType/ 下的万象数据挪进 wanxiang/（已经有了就不动）。
    nonisolated static func moveLegacyData() {
        let fm = FileManager.default
        for name in ["user.tsv", "history.tsv", WanxiangGrammarModel.fileName, "lexicon"] {
            let old = Paths.userData.appendingPathComponent(name)
            let new = dataDirectory.appendingPathComponent(name)
            guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { continue }
            do {
                try fm.moveItem(at: old, to: new)
                Log.engine.info("万象的 \(name, privacy: .public) 挪进 wanxiang/")
            } catch {
                Log.engine.error("挪不动 \(name, privacy: .public)：\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// 后台载入词库、语言模型、英文词表和用户数据，完成后在主线程启用。
    func loadInBackground() {
        wanted = true
        guard handle == nil, !loading else { return }
        loading = true
        let grammar = Self.wantedGrammar
        DispatchQueue.global(qos: .userInitiated).async {
            let core = Self.load(grammar: grammar)
            DispatchQueue.main.async {
                self.loading = false
                self.loadedGrammar = grammar != nil
                // 载入期间切回了水杉：不用了，放掉
                guard self.wanted else {
                    if let core { wotype_engine_free(core) }
                    return
                }
                self.install(core)
            }
        }
    }

    /// 换了词库或语法模型（在线更新、下载、删除）：先存用户数据，后台载入新引擎，好了再换下旧的。
    /// 载入期间旧引擎照常用；会话不持有引擎，换掉是安全的。
    func reload() {
        guard handle != nil, !loading else {
            if wanted { loadInBackground() }
            return
        }
        save()
        loading = true
        let grammar = Self.wantedGrammar
        DispatchQueue.global(qos: .userInitiated).async {
            let core = Self.load(grammar: grammar)
            DispatchQueue.main.async {
                self.loading = false
                guard let core else { return }
                self.loadedGrammar = grammar != nil
                guard self.wanted else {
                    wotype_engine_free(core)
                    return
                }
                let old = self.handle
                self.install(core)
                if let old { wotype_engine_free(old) }
            }
        }
    }

    /// 要不要用：loadInBackground 时设上，unload（切回水杉）时清掉。载入期间切走了，载入好的就放掉
    private var wanted = false

    private func install(_ core: OpaquePointer?) {
        handle = core
        conversionLoaded = false
        appliedSettings = nil
        apply(Settings.shared.config)
        reloadCustomWords()
        reloadQuickPhrases()
        NotificationCenter.default.post(name: Self.didLoad, object: self)
    }

    /// 载入好了、换了词库（设置页据此刷新）
    static let didLoad = Notification.Name("WoTypeWanxiangEngineDidLoad")

    /// 切到水杉：存好用户数据，放掉会话和词库（几百 MB）
    func unload() {
        wanted = false
        session = nil
        save()
        if let handle { wotype_engine_free(handle) }
        handle = nil
        appliedSettings = nil
    }

    /// 要用的语法模型：设置里开着、文件也有效才用（默认关，docs/15）
    private static var wantedGrammar: URL? {
        moveLegacyData()
        guard Settings.shared.config.wanxiangGrammar, WanxiangGrammarModel.isValid(WanxiangGrammarModel.fileURL) else {
            return nil
        }
        return WanxiangGrammarModel.fileURL
    }

    /// 现在载入的引擎带没带语法模型（设置里开关一变就重新载入）
    private(set) var loadedGrammar = false

    private nonisolated static func load(grammar: URL?) -> OpaquePointer? {
        let started = Date()
        // 快照必须写到缓存目录：写进 App 包会破坏代码签名
        wotype_set_cache_dir(Paths.caches.path)

        guard let bundled = bundled("lexicon.tsv") else {
            Log.engine.fault("App 包里没有万象词库：\(bundledData.path, privacy: .public)")
            return nil
        }
        func open(_ lexicon: URL) -> OpaquePointer? {
            buildLexiconCacheIfNeeded(lexicon)
            if let core = wotype_engine_new(lexicon.path, grammar?.path) { return core }
            guard grammar != nil else { return nil }
            // 语法模型坏了不该让输入法整个用不了：不带它再试一次
            Log.engine.error("语法模型载入失败，不用它：\(lastError, privacy: .public)")
            return wotype_engine_new(lexicon.path, nil)
        }
        // 在线更新过词库就用更新的那份（WanxiangLexiconUpdater），它坏了就退回 App 包里的
        var english = Self.bundled("english.txt")
        var mixed = Self.bundled("mixed.txt")
        var core: OpaquePointer?
        if let updated = WanxiangLexiconUpdater.installedLexicon {
            core = open(updated)
            if core == nil {
                Log.engine.error("更新的词库载入失败，改用内置词库：\(lastError, privacy: .public)")
            } else {
                if let updatedEnglish = WanxiangLexiconUpdater.installedEnglish { english = updatedEnglish }
                if let updatedMixed = WanxiangLexiconUpdater.installedMixed { mixed = updatedMixed }
            }
        }
        if core == nil { core = open(bundled) }
        guard let core else {
            Log.engine.fault("万象引擎初始化失败：\(lastError, privacy: .public)")
            return nil
        }

        // 前两页之后把同音词、句首词、单字全补上，翻页能翻到生僻字
        wotype_engine_set_max_candidates(core, 300)
        if let english {
            let loaded = wotype_engine_load_english(core, english.path)
            Log.engine.info("英文词 \(loaded) 个")
        }
        // 系统字体里没有的字（扩展区的生僻字，一万五千多个）不出候选，否则候选窗里是缺字方框
        wotype_engine_set_glyph_check(core) { codepoint in
            guard let scalar = Unicode.Scalar(codepoint) else { return false }
            return WanxiangEngine.hasGlyph(scalar)
        }
        // 编码里有字母的词（Azuo → A座），主词库放不下，单独一张表
        if let mixed {
            let loaded = wotype_engine_load_mixed(core, mixed.path)
            Log.engine.info("混合编码词 \(loaded) 个")
        }
        if FileManager.default.fileExists(atPath: Self.userDict.path) {
            let loaded = wotype_engine_load_user_dict(core, Self.userDict.path)
            Log.engine.info("用户词 \(loaded) 条")
        }
        if FileManager.default.fileExists(atPath: Self.history.path) {
            let loaded = wotype_engine_load_history(core, Self.history.path)
            Log.engine.info("输入习惯 \(loaded) 条")
        }

        let ms = Int(Date().timeIntervalSince(started) * 1000)
        Log.engine.info("万象词库载入完成，用时 \(ms) ms，语法模型 \(grammar == nil ? "无" : "有", privacy: .public)")
        return core
    }

    /// 系统字体（连同回退字体）里有没有这个字。没有的话系统拿 LastResort 字体顶上，画出来是缺字方框。
    nonisolated static func hasGlyph(_ scalar: Unicode.Scalar) -> Bool {
        let text = String(Character(scalar)) as NSString
        let base = CTFontCreateUIFontForLanguage(.system, 15, nil) ?? CTFontCreateWithName("PingFangSC-Regular" as CFString, 15, nil)
        let font = CTFontCreateForString(base, text, CFRange(location: 0, length: text.length))
        return !(CTFontCopyPostScriptName(font) as String).hasPrefix("LastResort")
    }

    /// 词库还没有快照（装好或升级后第一次启动）：起一个子进程去建，等它做完。
    ///
    /// 在本进程里建的话，解析用掉的一百多 MB 释放后系统收不回去，内存占用会一直停在高位。
    /// 子进程没建成也没关系：wotype_engine_new 会自己解析，只是这一次多占内存。
    private nonisolated static func buildLexiconCacheIfNeeded(_ lexicon: URL) {
        guard wotype_lexicon_cache_ready(lexicon.path) == 0, let executable = Bundle.main.executableURL else { return }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--build-cache", lexicon.path]
        do {
            try process.run()
            process.waitUntilExit()
            Log.engine.info("词库快照由子进程建好，退出码 \(process.terminationStatus)")
        } catch {
            Log.engine.error("起不了建快照的子进程：\(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated static var lastError: String {
        wotype_last_error().map { String(cString: $0) } ?? "unknown"
    }

    /// 简繁表只在第一次打开繁体时载入。
    private var conversionLoaded = false

    /// 把设置里和引擎、会话有关的开关交给它们。会话的设置是全局的，引擎还没载入好时也先设上。
    func apply(_ config: Config) {
        let settings = WanxiangSettings(config)
        guard settings != appliedSettings else { return }
        appliedSettings = handle == nil ? nil : settings
        // 打拼音途中按 . @ 进原样输入（a. → a.、g@qq.com），照微信输入法；不给关
        var options = UInt32(WOTYPE_OPT_URL_PUNCT)
        if config.slashDunhao { options |= UInt32(WOTYPE_OPT_SLASH_DUNHAO) }
        // 自动补全：引擎把右括号随上屏一起送出，WanxiangSession 把它留在编辑区末尾、光标前面（照水杉）
        if config.autoPair { options |= UInt32(WOTYPE_OPT_AUTO_PAIR) }
        if config.spaceCJKLatin {
            options |= UInt32(WOTYPE_OPT_SPACE_CJK_LATIN) | UInt32(WOTYPE_OPT_SPACE_CJK_DIGIT)
        }
        if config.vNumber { options |= UInt32(WOTYPE_OPT_V_NUMBER) }
        // 每页个数不给用户选：按候选窗宽度分页（最多 9 个）
        wotype_session_configure(5, config.emojiSuggest ? 1 : 0, config.asciiPunctAfterDigit ? 1 : 0, options)
        wotype_session_set_row_width(UInt32(CandidateView.rowWidth / Theme.candidateFont.pointSize * 100))
        // 展开时每个候选占几列：和候选窗画的用同一个量法（照水杉的展开候选，长词跨列）
        wotype_session_set_grid_span { text in
            guard let text else { return 1 }
            let string = String(cString: text)
            return UInt32(MainActor.assumeIsolated { CandidateView.gridSpan(string, cloud: false) })
        }
        // riqi / sj 等的日期、时间候选：格式按本地时区和农历在这边排好，每行一种写进引擎给的缓冲区
        wotype_session_set_date_formats { kind, buffer, length in
            guard let buffer else { return 0 }
            let bytes = Array(DateCandidates.formats(kind: kind).joined(separator: "\n").utf8.prefix(length))
            bytes.withUnsafeBufferPointer { source in
                buffer.withMemoryRebound(to: UInt8.self, capacity: length) { $0.update(from: source.baseAddress!, count: bytes.count) }
            }
            return bytes.count
        }
        guard let handle else { return }
        wotype_set_fuzzy_rules(config.wanxiangFuzzyRules.joined(separator: ","))
        wotype_engine_set_fuzzy(handle, config.wanxiangFuzzyRules.isEmpty ? 0 : 1)
        wotype_engine_set_typo_correction(handle, config.typoCorrection ? 1 : 0)
        wotype_engine_set_shuangpin(handle, config.shuangpin ? 1 : 0)
        if config.traditional && !conversionLoaded, let s2t = Self.bundled("s2t.tsv") {
            let loaded = wotype_engine_load_conversion(handle, s2t.path)
            conversionLoaded = loaded > 0
            Log.engine.info("简繁表 \(loaded) 条")
        }
        wotype_engine_set_traditional(handle, config.traditional && conversionLoaded ? 1 : 0)
        reloadQuickPhrases(config)
    }

    /// 重新交一份快捷短语（quick-phrases.tsv 原样交过去，引擎自己解析）。设置里关了「打编码时出现在候选里」就清空：
    /// 万象没有水杉的 ⇧K 快捷短语模式，关了就打不出来。
    func reloadQuickPhrases(_ config: Config = Settings.shared.config) {
        guard let handle else { return }
        let text = config.quickPhraseCandidates ? (try? String(contentsOf: QuickPhrases.fileURL, encoding: .utf8)) ?? "" : ""
        let loaded = wotype_engine_set_quick_phrases(handle, text)
        Log.engine.info("快捷短语 \(loaded) 条")
    }

    /// 重新载入自定义词（文件不存在就清空）。
    func reloadCustomWords() {
        guard let handle else { return }
        let loaded = wotype_engine_load_custom_words(handle, CustomWords.fileURL.path)
        if loaded < 0 {
            Log.engine.error("自定义词载入失败：\(Self.lastError, privacy: .public)")
        }
    }

    /// 会话报告学了几次选词：攒够 20 次存一次用户词库。
    func didLearn(_ count: Int) {
        unsavedCommits += count
        if unsavedCommits >= 20 {
            save()
        }
    }

    /// 用户词库和输入习惯落盘。
    func save() {
        guard let handle, unsavedCommits > 0 else { return }
        if wotype_engine_save_user_dict(handle, Self.userDict.path) != 0
            || wotype_engine_save_history(handle, Self.history.path) != 0 {
            Log.engine.error("保存用户数据失败：\(Self.lastError, privacy: .public)")
            return
        }
        unsavedCommits = 0
    }

    // MARK: - 会话（整个进程一个，切输入框只清空）

    private(set) var session: WanxiangSession?

    var onSettled: ((Snapshot) -> Void)?
}

/// 交给万象的设置：变了才重新设一遍。
private struct WanxiangSettings: Equatable {
    var emojiSuggest, asciiPunctAfterDigit, slashDunhao, autoPair, spaceCJKLatin, vNumber: Bool
    var fuzzyRules: [String]
    var typoCorrection, shuangpin, traditional, quickPhrases: Bool

    init(_ config: Config) {
        emojiSuggest = config.emojiSuggest
        asciiPunctAfterDigit = config.asciiPunctAfterDigit
        slashDunhao = config.slashDunhao
        autoPair = config.autoPair
        spaceCJKLatin = config.spaceCJKLatin
        vNumber = config.vNumber
        fuzzyRules = config.wanxiangFuzzyRules
        typoCorrection = config.typoCorrection
        shuangpin = config.shuangpin
        traditional = config.traditional
        quickPhrases = config.quickPhraseCandidates
    }
}

extension WanxiangEngine: PinyinEngine {
    func prepare() {
        wotype_session_set_mail_domains_path(Self.mailDomains.path)
        apply(Settings.shared.config)
        loadInBackground()
        WanxiangLexiconUpdater.shared.startAutoUpdate()
    }

    func settingsChanged(_ config: Config) {
        apply(config)
        // 语法模型开关变了：换一个带（或不带）它的引擎
        if handle != nil, (Self.wantedGrammar != nil) != loadedGrammar {
            reload()
        }
        // 刚切到万象：还没载入就开始载入（载入好了是空操作）
        loadInBackground()
    }

    var openSession: PinyinSession? { session }

    func stop() {
        unload()
    }

    func session(idle: Bool) -> PinyinSession? {
        guard handle != nil else { return nil }
        if session == nil { session = WanxiangSession() }
        return session
    }
}
