//
//  MsimeHost.swift
//  WoType
//
//  水杉输入法的宿主层（msime_client_*，链在 libwotype_core.a 里，docs/12）。
//  启动时在后台准备一次：校验随包的词库、在用户目录里建工作词库并回放学习记录，
//  得到建会话用的配置（HostOptions）。之后每个输入框用它建一个 MsimeSession。
//

import Foundation
import os

/// msime_client_* 的返回值：{"ok":true,"value":...} 或 {"ok":false,"error":"..."}。
/// 返回的字符串归调用方所有，这里解码后用 msime_client_string_free 释放。
nonisolated enum MsimeCall {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private struct Envelope<Value: Decodable>: Decodable {
        let ok: Bool
        let value: Value?
        let error: String?
    }

    static func decode<Value: Decodable>(_ type: Value.Type, _ raw: UnsafeMutablePointer<CChar>?,
                                         decoder: JSONDecoder = JSONDecoder()) throws -> Value {
        guard let raw else { throw Failure(description: "空返回") }
        defer { msime_client_string_free(raw) }
        let data = Data(bytes: raw, count: strlen(raw))
        let envelope = try decoder.decode(Envelope<Value>.self, from: data)
        guard envelope.ok, let value = envelope.value else {
            throw Failure(description: envelope.error ?? "没有返回值")
        }
        return value
    }

    /// 只要原样的 value（HostOptions 要原样交给 msime_client_create）。
    static func rawValue(_ raw: UnsafeMutablePointer<CChar>?) throws -> Data {
        guard let raw else { throw Failure(description: "空返回") }
        defer { msime_client_string_free(raw) }
        let data = Data(bytes: raw, count: strlen(raw))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(description: "返回的不是对象")
        }
        guard object["ok"] as? Bool == true, let value = object["value"] else {
            throw Failure(description: object["error"] as? String ?? "没有返回值")
        }
        // value 是 null（比如打英文时水杉的在线查询）或者不是对象、数组时，data(withJSONObject:) 会抛 Objective-C 异常，
        // try 接不住，按键处理到一半就断了，键漏给应用（APIAPI？）。先挡掉
        guard JSONSerialization.isValidJSONObject(value) else {
            throw Failure(description: "返回值不是 JSON 对象")
        }
        return try JSONSerialization.data(withJSONObject: value)
    }

    /// 把 JSON 文档交给接收 (bytes, length) 的函数。
    static func withBytes<R>(_ data: Data, _ body: (UnsafePointer<UInt8>, Int) throws -> R) rethrows -> R {
        try data.withUnsafeBytes { buffer in
            try body(buffer.bindMemory(to: UInt8.self).baseAddress!, buffer.count)
        }
    }
}

/// 要交给水杉的 WoType 设置（写进水杉的偏好，MsimeHost.applyPreferences）。
nonisolated struct MsimeSettings: Equatable {
    var fuzzyRules: [String]
    var shuangpin: Bool
    var traditional: Bool
    var typoCorrection: Bool
    var autoPair: Bool
    var asciiPunctAfterDigit: Bool
    var emojiSuggest: Bool
    var slashDunhao: Bool
    var spaceCJK: Bool
    var chaizi: Bool
    var quickPhraseCandidates: Bool
    var cloudCandidates: Bool
    var model: String
    var shuangpinProfile: String

    init(_ config: Config) {
        fuzzyRules = config.fuzzyRules
        shuangpin = config.shuangpin
        traditional = config.traditional
        typoCorrection = config.typoCorrection
        autoPair = config.autoPair
        asciiPunctAfterDigit = config.asciiPunctAfterDigit
        emojiSuggest = config.emojiSuggest
        slashDunhao = config.slashDunhao
        spaceCJK = config.spaceCJKLatin
        chaizi = config.chaizi
        quickPhraseCandidates = config.quickPhraseCandidates
        cloudCandidates = config.cloudCandidates
        model = config.msimeModel
        shuangpinProfile = config.shuangpinProfile
    }

    /// WoType 的模糊音规则 → 水杉的（client-core 的 FuzzyPinyinRule）。水杉只有这 11 条，其余几条用水杉引擎时不生效
    static let fuzzyRuleNames = [
        "z=zh": "z-zh", "c=ch": "c-ch", "s=sh": "s-sh", "n=l": "n-l", "h=f": "f-h", "r=l": "r-l",
        "an=ang": "an-ang", "en=eng": "en-eng", "in=ing": "in-ing", "ian=iang": "ian-iang", "uan=uang": "uan-uang",
    ]
}

/// 资源包下载进度的回调（经 C 函数指针的 context 交给水杉）。
nonisolated final class ResourcePackProgress: @unchecked Sendable {
    let report: (Double) -> Void
    init(_ report: @escaping (Double) -> Void) { self.report = report }
}

final class MsimeHost {

    static let shared = MsimeHost()

    /// 准备好了（options 可用）。
    static let didBecomeReady = Notification.Name("WoTypeMsimeHostDidBecomeReady")

    /// 建会话用的配置；还没准备好、或者准备失败时为 nil（这时按键交给应用）。
    private(set) var options: Data?

    /// 每准备好一次加一。词库更新后重新准备，会话看到代次变了就用新配置重建（InputController）。
    private(set) var generation = 0

    private var preparing = false
    private var prepareAgain = false
    /// 上次准备时交给水杉的设置：设置页改的不是这几项就不用重来
    private(set) var preparedSettings: MsimeSettings?

    /// 随包的词库和逐键小模型（scripts/fetch-msime-data.sh、copy-data.sh）。
    static var resources: URL { Paths.bundledData.appendingPathComponent("msime/resources", isDirectory: true) }

    /// 工作词库、学习记录、偏好、下载的资源包都在这里。
    static var stateRoot: URL { Paths.userData.appendingPathComponent("msime", isDirectory: true) }

    /// 后台准备（复制工作词库、回放学习记录，第一次约一秒）。准备好之前按键交给应用。
    /// again：已经准备过也再来一次（词库更新好了，要换上新版本）。
    func prepareInBackground(again: Bool = false) {
        guard options == nil || again else { return }
        guard !preparing else {
            // 正在准备时设置又改了：这次完了再来一遍
            prepareAgain = prepareAgain || again
            return
        }
        preparing = true
        let resources = Self.resources.path
        let stateRoot = Self.stateRoot.path
        let settings = MsimeSettings(Settings.shared.config)
        DispatchQueue.global(qos: .userInitiated).async {
            let started = Date()
            let result = Result { try Self.prepare(resources: resources, stateRoot: stateRoot, settings: settings) }
            DispatchQueue.main.async {
                self.preparing = false
                defer {
                    if self.prepareAgain {
                        self.prepareAgain = false
                        self.prepareInBackground(again: true)
                    }
                }
                switch result {
                case .success(let options):
                    self.options = options
                    self.preparedSettings = settings
                    self.generation += 1
                    let ms = Int(Date().timeIntervalSince(started) * 1000)
                    Log.app.info("水杉引擎准备好了，用了 \(ms) ms")
                    NotificationCenter.default.post(name: Self.didBecomeReady, object: self)
                    self.refreshSettledModel()
                    self.syncCustomWords(CustomWords.load())
                    self.syncQuickPhrases(QuickPhrases.load())
                    self.refreshLexicon(command: Settings.shared.config.autoUpdateLexicon ? "automatic" : "status")
                case .failure(let error):
                    Log.app.error("水杉引擎准备失败：\(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    // MARK: - 会话（整个进程一个，照水杉的 macOS 宿主；切输入框只切焦点）

    private(set) var session: MsimeSession?

    /// 停顿后重排了候选：交给当前的输入框（InputController 设）
    var onSettled: ((Snapshot) -> Void)?

    /// 当前的会话；还没准备好、或者建不出来时为 nil（这时按键交给应用）。
    /// idle：现在没有组字。词库更新、个人词典改了要重建会话，只在空闲时重建，打到一半不换。
    func currentSession(idle: Bool) -> MsimeSession? {
        guard let options else { return nil }
        if let session, !(idle && (session.hostGeneration != generation || personalDictionaryDirty)) {
            return session
        }
        guard idle || session == nil else { return session }
        // 个人词典的改动要在没有会话时写进词库（msime_client_personal_dictionary_sync）
        session = nil
        if personalDictionaryDirty {
            syncPersonalDictionary(options: options)
        }
        do {
            let created = try MsimeSession(options: options)
            created.onSettled = { [weak self] snapshot in self?.onSettled?(snapshot) }
            session = created
        } catch {
            Log.input.error("水杉会话建不出来：\(String(describing: error), privacy: .public)")
        }
        return session
    }

    // MARK: - 个人词典（自定义词、快捷短语）

    /// 自定义词、快捷短语改了，队列里有没写进词库的改动
    private var personalDictionaryDirty = false

    /// 上次同步给水杉的自定义词（拼音<TAB>词）、快捷短语，用来算这次加了哪些、删了哪些
    private static var syncedWordsURL: URL { stateRoot.appendingPathComponent("custom-synced.tsv") }
    private static var syncedPhrasesURL: URL { stateRoot.appendingPathComponent("quick-phrases-synced.tsv") }

    /// 自定义词的权重：排在同音词前面（水杉的上限是 1 亿）
    private static let customWordWeight = 10_000_000

    /// 自定义词页保存了（或者启动时）：和上次同步的比，加的、删的排进水杉的个人词典队列，空闲时写进词库。
    func syncCustomWords(_ words: [CustomWord]) {
        let entry = { (word: CustomWord) -> [String: Any] in
            // 水杉的拼音编码是隔音符分开的音节（ni'hao）
            ["kind": "pinyin", "key": word.pinyin.split(separator: " ").joined(separator: "'"),
             "value": word.word, "weight": Self.customWordWeight]
        }
        let synced = CustomWords.load(from: Self.syncedWordsURL)
        guard queueEdits(removed: synced.filter { !words.contains($0) }.map(entry),
                         added: words.filter { !synced.contains($0) }.map(entry), label: "自定义词") else { return }
        try? CustomWords.save(words, to: Self.syncedWordsURL, reload: false)
    }

    /// 快捷短语同步给水杉（kind quick_phrase）。水杉新加的快捷短语权重是 10，照它
    func syncQuickPhrases(_ phrases: [QuickPhrase]) {
        let entry = { (phrase: QuickPhrase) -> [String: Any] in
            ["kind": "quick_phrase", "key": phrase.code, "value": phrase.text, "weight": 10]
        }
        let synced = QuickPhrases.load(from: Self.syncedPhrasesURL)
        guard queueEdits(removed: synced.filter { !phrases.contains($0) }.map(entry),
                         added: phrases.filter { !synced.contains($0) }.map(entry), label: "快捷短语") else { return }
        try? QuickPhrases.save(phrases, to: Self.syncedPhrasesURL, reload: false)
    }

    /// 把增删排进水杉的个人词典队列（msime_client_personal_dictionary_request），没有组字时写进词库。
    /// 返回 false：引擎还没准备好，或者没有改动。
    private func queueEdits(removed: [[String: Any]], added: [[String: Any]], label: String) -> Bool {
        guard let options, let hostOptions = try? JSONSerialization.jsonObject(with: options) as? [String: Any] else { return false }
        let actions = removed.map { ["operation": "edit", "previous": $0, "replacement": NSNull()] as [String: Any] }
            + added.map { ["operation": "edit", "previous": NSNull(), "replacement": $0] as [String: Any] }
        guard !actions.isEmpty else { return false }
        var queued = 0
        for (index, var action) in actions.enumerated() {
            action["request_id"] = "wotype-\(UUID().uuidString)-\(index)"
            guard let request = try? JSONSerialization.data(withJSONObject: ["options": hostOptions, "action": action]) else { continue }
            do {
                _ = try MsimeCall.withBytes(request) { bytes, count in
                    try MsimeCall.rawValue(msime_client_personal_dictionary_request(bytes, count))
                }
                queued += 1
            } catch {
                Log.app.error("\(label, privacy: .public)排进水杉词典失败：\(String(describing: error), privacy: .public)")
            }
        }
        Log.app.info("\(label, privacy: .public)同步给水杉：\(queued) 项")
        personalDictionaryDirty = true
        // 没有输入框在组字（比如在设置窗口里改的）：现在就写进去
        if session?.composing != true {
            _ = currentSession(idle: true)
        }
        return true
    }

    private func syncPersonalDictionary(options: Data) {
        do {
            let result = try MsimeCall.withBytes(options) { bytes, count in
                try MsimeCall.rawValue(msime_client_personal_dictionary_sync(bytes, count))
            }
            personalDictionaryDirty = false
            Log.app.info("水杉个人词典已同步：\(String(decoding: result, as: UTF8.self), privacy: .public)")
        } catch {
            // 词库正忙（另一个进程开着会话）：留着，下次空闲再试
            Log.app.error("水杉个人词典同步失败：\(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - 词库更新（水杉自己的在线更新：msime-dictionary 的 dict-v* 发布，按格式版本和 SHA-256 校验）

    /// 水杉词库更新的状态（client-providers 的 UpdateStatus）。
    nonisolated struct LexiconStatus: Decodable, Equatable {
        /// 现在用的词库版本，如 2.1.2
        let version: String
        /// checking、downloading、ready、current、failed、cancelled、interrupted、rolled_back，没做过是空
        let phase: String
        let enabled: Bool
        let downloadedBytes: UInt64
        let totalBytes: UInt64
        let error: String?
        /// 更新过，可以退回随 App 的词库
        let canRollback: Bool
        /// 新版本装好了，重新准备后才用上
        let pendingRestart: Bool

        var busy: Bool { phase == "checking" || phase == "downloading" }
    }

    static let lexiconDidChange = Notification.Name("WoTypeMsimeLexiconDidChange")

    private(set) var lexicon: LexiconStatus?
    private var lexiconPoll: DispatchWorkItem?
    private var restartedFor: String?

    /// command：status（只看）、check（检查并下载）、automatic（自动更新开着且到了一天才查）、
    /// rollback（恢复随 App 的词库）。configure 用 setLexiconAutoUpdate。
    func refreshLexicon(command: String = "status") {
        lexiconRequest(["operation": "updates", "command": command])
    }

    func setLexiconAutoUpdate(_ enabled: Bool) {
        lexiconRequest(["operation": "updates", "command": "configure", "enabled": enabled])
    }

    private func lexiconRequest(_ action: [String: Any]) {
        guard let options else { return }
        DispatchQueue.global(qos: .utility).async {
            let result = Result { () throws -> LexiconStatus in
                guard let hostOptions = try JSONSerialization.jsonObject(with: options) as? [String: Any] else {
                    throw MsimeCall.Failure(description: "HostOptions 不是对象")
                }
                let request = try JSONSerialization.data(withJSONObject: ["options": hostOptions, "action": action])
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                return try MsimeCall.withBytes(request) { bytes, count in
                    try MsimeCall.decode(LexiconStatus.self, msime_client_dictionary(bytes, count), decoder: decoder)
                }
            }
            DispatchQueue.main.async { self.lexiconUpdated(result) }
        }
    }

    private func lexiconUpdated(_ result: Result<LexiconStatus, Error>) {
        lexiconPoll?.cancel()
        lexiconPoll = nil
        switch result {
        case .success(let status):
            lexicon = status
            if status.busy {
                // 下载在水杉自己的后台线程里，隔一秒问一次进度
                let work = DispatchWorkItem { [weak self] in self?.refreshLexicon() }
                lexiconPoll = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
            } else if status.pendingRestart, restartedFor != status.version + status.phase {
                // 新版本装好了（或刚恢复了内置词库）：重新准备，空闲的输入框下次按键就用上。
                // 同一个版本只重来一次，免得状态没变时来回准备
                restartedFor = status.version + status.phase
                Log.app.info("水杉词库换到 \(status.version, privacy: .public)，重新准备")
                prepareInBackground(again: true)
            }
        case .failure(let error):
            Log.app.error("水杉词库更新请求失败：\(String(describing: error), privacy: .public)")
        }
        NotificationCenter.default.post(name: Self.lexiconDidChange, object: self)
    }

    // MARK: - 停顿后重排的大模型（资源包 settled-model，24 MB）

    /// 大模型的状态：missing、installed、outdated（水杉的资源包状态）；下载中是 installing。查不到时为 nil。
    private(set) var settledModelState: String?
    /// 下载进度 0～1（installing 时）
    private(set) var settledModelProgress: Double = 0

    static let settledModelDidChange = Notification.Name("WoTypeMsimeSettledModelDidChange")

    var settledModelInstalled: Bool { settledModelState == "installed" }

    /// 查一下大模型装了没有（不下载）。
    func refreshSettledModel() {
        guard settledModelState != "installing" else { return }
        let stateRoot = Self.stateRoot.path
        DispatchQueue.global(qos: .utility).async {
            let state = Self.settledModelState(stateRoot: stateRoot)
            DispatchQueue.main.async {
                guard self.settledModelState != "installing" else { return }
                self.settledModelState = state
                NotificationCenter.default.post(name: Self.settledModelDidChange, object: self)
            }
        }
    }

    /// 设置页点「下载」：按水杉的资源锁下载并校验大小和 SHA-256，断了下次续传。
    /// 装好以后重新准备，空闲的输入框下次按键就用上。
    func downloadSettledModel() {
        guard settledModelState != "installing" else { return }
        let previous = settledModelState
        settledModelState = "installing"
        settledModelProgress = 0
        NotificationCenter.default.post(name: Self.settledModelDidChange, object: self)
        let stateRoot = Self.stateRoot.path
        let progress = ResourcePackProgress { [weak self] fraction in
            DispatchQueue.main.async {
                guard let self, self.settledModelState == "installing" else { return }
                self.settledModelProgress = fraction
                NotificationCenter.default.post(name: Self.settledModelDidChange, object: self)
            }
        }
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try Self.installSettledModel(stateRoot: stateRoot, progress: progress) }
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.settledModelState = "installed"
                    Log.app.info("水杉的停顿重排模型下载好了")
                    self.prepareInBackground(again: true)
                case .failure(let error):
                    self.settledModelState = previous
                    Log.app.error("水杉的停顿重排模型下载失败：\(String(describing: error), privacy: .public)")
                }
                NotificationCenter.default.post(name: Self.settledModelDidChange, object: self)
            }
        }
    }

    func cancelSettledModelDownload() {
        let pack = Array(Self.settledPack.utf8)
        msime_client_resource_pack_cancel(pack, pack.count)
    }

    /// 设置页点「删除」：卸掉资源包，重新准备（会话不再挂大模型）。
    func removeSettledModel() {
        guard settledModelState == "installed" else { return }
        let stateRoot = Self.stateRoot.path
        DispatchQueue.global(qos: .utility).async {
            let result = Result { () throws -> Void in
                let request = try JSONSerialization.data(withJSONObject: ["state_root": stateRoot, "pack": "settled-model"])
                try MsimeCall.withBytes(request) { bytes, count in
                    _ = try MsimeCall.rawValue(msime_client_resource_pack_remove(bytes, count))
                }
            }
            DispatchQueue.main.async {
                if case .failure(let error) = result {
                    Log.app.error("删除水杉的停顿重排模型失败：\(String(describing: error), privacy: .public)")
                }
                self.settledModelState = Self.settledModelState(stateRoot: stateRoot)
                self.prepareInBackground(again: true)
                NotificationCenter.default.post(name: Self.settledModelDidChange, object: self)
            }
        }
    }

    nonisolated private static let settledPack = "settled-model"

    nonisolated private struct ResourcePack: Decodable {
        let id: String
        let state: String
    }

    nonisolated private static func settledModelState(stateRoot: String) -> String? {
        guard let request = try? JSONSerialization.data(withJSONObject: ["state_root": stateRoot]),
              let packs = try? MsimeCall.withBytes(request, { bytes, count in
                  try MsimeCall.decode([ResourcePack].self, msime_client_resource_packs(bytes, count))
              }) else { return nil }
        return packs.first { $0.id == settledPack }?.state
    }

    nonisolated private static func installSettledModel(stateRoot: String, progress: ResourcePackProgress) throws {
        let request = try JSONSerialization.data(withJSONObject: ["state_root": stateRoot, "pack": settledPack])
        let context = Unmanaged.passRetained(progress)
        defer { context.release() }
        try MsimeCall.withBytes(request) { bytes, count in
            _ = try MsimeCall.rawValue(msime_client_resource_pack_install(bytes, count, { context, _, done, total in
                // 水杉在调用线程上报进度（phase：download、verify、done）
                guard let context, total > 0 else { return }
                Unmanaged<ResourcePackProgress>.fromOpaque(context).takeUnretainedValue()
                    .report(Double(done) / Double(total))
            }, context.toOpaque()))
        }
    }

    nonisolated private static func prepare(resources: String, stateRoot: String, settings: MsimeSettings) throws -> Data {
        try FileManager.default.createDirectory(atPath: stateRoot, withIntermediateDirectories: true)
        // edition pinyin：水杉的拼音版（全拼、双拼），资源锁见 resources/editions/pinyin.lock.json
        let request = try JSONSerialization.data(withJSONObject: [
            "resources": resources, "state_root": stateRoot, "edition": "pinyin",
        ])
        let prepare = {
            try MsimeCall.withBytes(request) { bytes, count in
                try MsimeCall.rawValue(msime_client_prepare_host(bytes, count))
            }
        }
        // 第一次准备时水杉才写出偏好文件；改了偏好要再准备一次，HostOptions 里带的是准备时读到的偏好
        let options = try prepare()
        return try applyPreferences(stateRoot: stateRoot, settings: settings) ? prepare() : options
    }

    /// 把 WoType 的设置写进水杉的偏好（state_root/preferences.json）。有改动返回 true。
    nonisolated private static func applyPreferences(stateRoot: String, settings: MsimeSettings) throws -> Bool {
        let directory = Data(stateRoot.utf8)
        let loaded = try MsimeCall.withBytes(directory) { bytes, count in
            try MsimeCall.rawValue(msime_client_load_preferences(bytes, count))
        }
        guard var snapshot = try JSONSerialization.jsonObject(with: loaded) as? [String: Any],
              var preferences = snapshot["preferences"] as? [String: Any],
              let revision = (snapshot["revision"] as? NSNumber)?.uint64Value else {
            throw MsimeCall.Failure(description: "偏好的格式不认识")
        }
        let before = NSDictionary(dictionary: preferences)
        // 整句模型：小模型逐键重排（「整句联想」的增强），大模型停顿后重排（「桌面神经联想」，要下载）。
        // 流畅优先（fluent）：按键上不跑模型（每键最快），只在停顿时用大模型排
        var sentence = preferences["sentence_association"] as? [String: Any] ?? [:]
        sentence["neural_keyboard"] = settings.model == "small" || settings.model == "large"
        sentence["neural_desktop"] = settings.model == "large" || settings.model == "fluent"
        preferences["sentence_association"] = sentence
        // 匿名使用统计：WoType 不调用水杉的上报接口，这里也关掉，免得以后接了什么顺带发出去
        preferences["usage_reporting"] = false

        // 拼音页：模糊音、双拼方案、繁体、按错键纠正
        // 在原来那项上改：里面的 seeded 是水杉的「已经给过默认规则」标记，丢了它会把规则全部重新填上
        let rules = settings.fuzzyRules.compactMap { MsimeSettings.fuzzyRuleNames[$0] }
        var fuzzy = preferences["fuzzy_pinyin"] as? [String: Any] ?? [:]
        fuzzy["enabled"] = !rules.isEmpty
        fuzzy["rules"] = rules
        fuzzy["seeded"] = true
        preferences["fuzzy_pinyin"] = fuzzy
        preferences["scheme"] = settings.shuangpin ? "shuangpin" : "quanpin"
        preferences["shuangpin_profile"] = settings.shuangpinProfile
        preferences["traditional_chinese_output"] = settings.traditional
        var quanpin = preferences["quanpin"] as? [String: Any] ?? [:]
        quanpin["autocorrect_neighbor"] = settings.typoCorrection
        quanpin["autocorrect_transposition"] = settings.typoCorrection
        preferences["quanpin"] = quanpin
        // 通用页：符号自动补全、数字后的 . : 原样输出、/ 输入顿号、中英文数字之间加空格、推荐表情
        // 候选窗横排：水杉按它决定左右键到头了改成选候选（不再有竖排）
        preferences["candidate_layout"] = "horizontal"
        preferences["paired_punctuation"] = settings.autoPair
        preferences["smart_punctuation_direct_digit"] = settings.asciiPunctAfterDigit
        preferences["enumeration_comma_slash"] = settings.slashDunhao
        preferences["chinese_english_spacing"] = settings.spaceCJK
        preferences["cross_commit_spacing"] = settings.spaceCJK
        var mixed = preferences["mixed_input"] as? [String: Any] ?? [:]
        mixed["emoji"] = settings.emojiSuggest
        mixed["quick_phrase"] = settings.quickPhraseCandidates
        preferences["mixed_input"] = mixed
        // 云候选：来源用水杉的默认（Google input-tools），不动 cloud_candidate_provider
        preferences["cloud_candidates"] = settings.cloudCandidates
        // ⇧C 拆字
        var localModes = preferences["local_modes"] as? [String: Any] ?? [:]
        localModes["chaizi"] = settings.chaizi
        preferences["local_modes"] = localModes
        guard !before.isEqual(to: preferences) else { return false }

        snapshot["preferences"] = preferences
        let document = try JSONSerialization.data(withJSONObject: snapshot)
        try directory.withUnsafeBytes { dir in
            try MsimeCall.withBytes(document) { bytes, count in
                _ = try MsimeCall.rawValue(msime_client_save_preferences(
                    dir.bindMemory(to: UInt8.self).baseAddress!, dir.count, revision, bytes, count))
            }
        }
        return true
    }
}
