//
//  VoicePolish.swift
//  WoType
//
//  润色：清理口语（规则）→ 润色模型按场景整理 → 检查结果 → 场景收尾。
//  照 Arion@d2108fe（AGPL-3.0-only）：
//  - 流程：packages/core/application/live.go 的 rewriteFinal、deliverableRewrite，dictation.go 的 deliver；
//    apps/desktop/infrastructure/llm/rewrite/pipeline.go 的 Run：清理口语 → 选同音词 → 整理；
//  - 选同音词：pipeline.go 的 forcedAmbiguousSelection，prompt/selected.go 的 Selected、Selection，
//    例子是 Resources/polish-selection.json（Arion 的 selection.json）。Arion 用 JSON schema 约束模型的输出，
//    MLX 没有这个，模型的回答不合规矩时这一步不换（Arion 那时整个润色算失败），接着整理；
//  - 提示词：apps/desktop/infrastructure/llm/prompt/selected.go 的 Format、systemPrompt、formatBudget，
//    内容是 Resources/polish-format.json（Arion 的 format.json，去掉了翻译）。
//  规则（清理口语、场景、检查）在 Rust 引擎里（engine/core/src/polish）。
//  润色失败、超时、结果不能用时，上屏清理过口语的原文，不提示（和 Arion 一样）。
//

import AppKit
import ApplicationServices
import os

/// 润色用的场景（engine/core/src/polish/scene.rs 的顺序）。
nonisolated enum VoiceScene: Int32 {
    case chat, email, work, prompt, search

    var key: String {
        switch self {
        case .chat, .search: "chat"  // 搜索用日常输入的整理，收尾时再去掉句末标点（Format）
        case .email: "email"
        case .work: "work"
        case .prompt: "prompt"
        }
    }

    static let all: [VoiceScene] = [.chat, .email, .work, .prompt, .search]

    /// 存设置用的名字（scene.rs 的 name）
    var name: String {
        switch self {
        case .chat: "chat"
        case .email: "email"
        case .work: "work"
        case .prompt: "prompt"
        case .search: "search"
        }
    }

    init?(name: String) {
        guard let scene = Self.all.first(where: { $0.name == name }) else { return nil }
        self = scene
    }

    /// 用户指定场景时存的键（SceneKey）：App 的 bundle ID；在搜索框里是「search@」加 bundle ID，只管这个 App 的搜索框。
    static func overrideKey(app: String, searchField: Bool) -> String {
        searchField ? "search@" + app : app
    }

    var title: String {
        switch self {
        case .chat: "日常输入"
        case .email: "邮件"
        case .work: "工作消息"
        case .prompt: "编程指令"
        case .search: "搜索"
        }
    }

    /// 输入框所在的 App 和它是不是搜索框决定场景（DecideScene；网页的域名以后读）：用户给这个 App 指定过的最优先。
    @MainActor
    static func decide(app: String?, searchField: Bool) -> VoiceScene {
        if let app, !app.isEmpty,
           let chosen = Settings.shared.config.voiceSceneOverrides[overrideKey(app: app, searchField: searchField)],
           let scene = VoiceScene(name: chosen) {
            return scene
        }
        return automatic(app: app, searchField: searchField)
    }

    /// 内置规则选的场景（不管用户指定的）。
    static func automatic(app: String?, searchField: Bool) -> VoiceScene {
        let scene = (app ?? "").withCString { app in
            "".withCString { site in wotype_polish_scene(app, site, searchField ? 1 : 0) }
        }
        return VoiceScene(rawValue: scene) ?? .chat
    }

    /// 焦点在不在搜索框（要辅助功能权限；没有就当不是）。只看角色，不读框里的字。
    /// 不能在处理按键时调：那时前台 App 正等着输入法回话，回答不了辅助功能的询问，两边互相等到超时
    /// （按 fn 后浮窗晚出来就是这个）。要在后台线程、按键处理完以后调，最多等 0.2 秒。
    static func focusedSearchField() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID() else { return false }
        var subrole: CFTypeRef?
        AXUIElementSetMessagingTimeout(element as! AXUIElement, 0.2)
        AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSubroleAttribute as CFString, &subrole)
        return subrole as? String == kAXSearchFieldSubrole
    }
}

@MainActor
enum VoicePolish {

    /// 等润色多久，超时就上屏清理过的原文
    static let timeout: Duration = .seconds(20)

    /// 润色开着、润色选的引擎也能用。
    static var enabled: Bool { Settings.shared.config.voicePolish && ready(polishEngine, for: .polish) }

    /// 润色、翻译各自选的引擎（翻译和润色分开选，WoType 加的；Arion 翻译跟着润色走）
    static var polishEngine: PolishEngine { Settings.shared.config.voicePolishEngine }
    static var translateEngine: PolishEngine { Settings.shared.config.voiceTranslateEngine }

    /// 这个引擎能用：本机是润色模型装好了，云端是润色（翻译）选的云端模型还在、有密钥。
    /// 语音翻译不管润色开没开（Arion：「无需先开启润色」）。
    static func ready(_ engine: PolishEngine, for use: CloudUse) -> Bool {
        switch engine {
        case .local: VoiceService.polishReady
        case .cloud: CloudPolish.shared.ready(use)
        }
    }

    /// 开始说话时调：先载入润色模型，把这个场景的系统提示算好（按中文的；说的是英文时到时候再算）。
    /// 开了上下文时，选同音词的例子也算好（没有上下文就列不出候选，不用这一步）。
    /// 翻译时算的是翻译的提示词（系统提示加例子）。只有本机模型要预热。
    static func prepare(scene: VoiceScene, withContext: Bool, translating target: TranslationLanguage? = nil) {
        // 云端不用预热，只要先载入选同音词的读音表
        if (target == nil ? polishEngine : translateEngine) == .cloud {
            if withContext, SpellingSelection.loaded == nil { SpellingSelection.load() }
            return
        }
        guard let prompt = PolishPrompt.shared else { return }
        if let target {
            guard ready(.local, for: .translate) else { return }
            VoiceService.shared.preparePolish(messages: prompt.translationHead(scene: scene.key, target: target))
        } else {
            guard enabled else { return }
            VoiceService.shared.preparePolish(messages: [["role": "system", "content": prompt.system(route: "han", scene: scene.key)]])
        }
        guard withContext else { return }
        if let selection = SpellingSelection.loaded {
            VoiceService.shared.preparePolish(messages: selection.examples)
        } else {
            SpellingSelection.load()
        }
    }

    /// 云端润色失败时的提示（上屏的是本机清理过口语的文字；Arion 的 PolishNote）。每次润色前清掉。
    private(set) static var lastNote: Notice?

    /// 等多久（Arion：云端 15 秒）
    private static func limit(_ engine: PolishEngine) -> Duration { engine == .cloud ? .seconds(15) : timeout }

    /// 润色一段识别结果（已经整理过空格、换过错误写法）。返回要上屏的文字。
    /// context 是参考的上下文（没开就是空的）：只帮着拼对专有名词、衔接前后文，整理的对象始终是 source。
    /// terms 是识别结果里出现过的词条的正确写法（VocabularyIndex.terms），给选同音词当参考。
    static func polish(_ source: String, scene: VoiceScene, context: VoiceContext = VoiceContext(),
                       terms: [String] = []) async -> String {
        // 清理口语：润色失败时上屏的也是它
        lastNote = nil
        let cleaned = clean(source)
        guard enabled, let prompt = PolishPrompt.shared, !cleaned.isEmpty else { return finish(cleaned, scene: scene) }
        let started = ContinuousClock.now
        let engine = polishEngine
        do {
            let output = try await withTimeout(limit(engine)) {
                let edited = await selectSpelling(cleaned, scene: scene.key, context: context, terms: terms,
                                                  engine: engine, use: .polish)
                let request = prompt.request(edited, scene: scene.key, context: context)
                return try await generate(request, engine: engine, use: .polish)
            }
            let elapsed = ContinuousClock.now - started
            guard deliverable(output) else {
                Log.input.info("润色结果不能用，上屏清理过的原文（\(elapsed)）")
                return finish(cleaned, scene: scene)
            }
            Log.input.info("润色好了（\(scene.key, privacy: .public)，\(elapsed)）")
            return finish(output.trimmingCharacters(in: .whitespacesAndNewlines), scene: scene)
        } catch {
            Log.input.error("润色失败：\(String(describing: error), privacy: .public)")
            if engine == .cloud {
                lastNote = (error as? CloudFailure)?.notice ?? (error is Timeout ? CloudFailure.timeout.notice : CloudFailure.outage.notice)
            }
            return finish(cleaned, scene: scene)
        }
    }

    /// 语音翻译失败的几种（Arion dictation.go 的 failTranslation）
    enum TranslationFailure: Error {
        /// 本机模型没装好、也没连云端
        case unavailable
        case timeout
        /// 模型出错、结果不能用
        case failed
        /// 云端出错：浮窗说清楚原因（和润色一样）
        case cloud(CloudFailure)

        @MainActor var notice: Notice {
            switch self {
            case .unavailable: Notice(title: "翻译模型尚未就绪",
                                      hint: VoicePolish.translateEngine == .cloud ? "请在设置 › 语音 › 翻译用中选择云端模型" : "请在设置 › 语音中下载润色模型")
            case .timeout: Notice(title: "翻译超时")
            case .failed: Notice(title: "翻译失败")
            case .cloud(let failure):
                switch failure {
                case .refused: Notice(title: "此模型无法翻译", hint: failure.notice.hint)
                // 翻译失败不插原文，不说「文本已在本机整理」
                case .outage, .network, .notConnected: Notice(title: failure.notice.title, hint: "稍后再试")
                default: failure.notice
                }
            }
        }
    }

    /// 语音翻译（Arion 的 rewriteFinal 带 TargetLanguage）：清理口语 → 选同音词 → 按翻译的提示词写成目标语言 →
    /// 检查 → 场景收尾。失败时不上屏（不插原文），由浮窗提示。
    static func translate(_ source: String, scene: VoiceScene, target: TranslationLanguage,
                          context: VoiceContext = VoiceContext(), terms: [String] = []) async -> Result<String, TranslationFailure> {
        let engine = translateEngine
        guard ready(engine, for: .translate), let prompt = PolishPrompt.shared else { return .failure(.unavailable) }
        let cleaned = clean(source)
        guard !cleaned.isEmpty else { return .failure(.failed) }
        let started = ContinuousClock.now
        do {
            let output = try await withTimeout(limit(engine)) {
                let edited = await selectSpelling(cleaned, scene: scene.key, context: context, terms: terms,
                                                  engine: engine, use: .translate)
                return try await generate(prompt.translationRequest(edited, scene: scene.key, target: target, context: context),
                                          engine: engine, use: .translate)
            }
            guard deliverable(output) else {
                Log.input.info("翻译结果不能用")
                return .failure(.failed)
            }
            Log.input.info("翻译好了（\(target.rawValue, privacy: .public)，\(ContinuousClock.now - started)）")
            return .success(finish(output.trimmingCharacters(in: .whitespacesAndNewlines), scene: scene))
        } catch is Timeout {
            return .failure(.timeout)
        } catch CloudFailure.timeout {
            return .failure(.timeout)
        } catch CloudFailure.notConnected {
            return .failure(.unavailable)
        } catch let failure as CloudFailure {
            Log.input.error("翻译失败：\(String(describing: failure), privacy: .public)")
            return .failure(.cloud(failure))
        } catch {
            Log.input.error("翻译失败：\(error.localizedDescription, privacy: .public)")
            return .failure(.failed)
        }
    }

    /// 交给选的引擎生成（本机：WoType Voice 里的润色模型）。
    private static func generate(_ request: PolishPrompt.Request, engine: PolishEngine, use: CloudUse) async throws -> String {
        if engine == .cloud {
            return try await CloudPolish.shared.complete(messages: request.messages, maxTokens: request.maxTokens, for: use)
        }
        return try await VoiceService.shared.polish(messages: request.messages, maxTokens: request.maxTokens)
    }

    /// 选同音词（pipeline.go 的选择那一步）：列出和上下文读音相同的写法，模型选换不换。
    /// 没有候选、全是拿不准的（ambiguous，只能不换）时不问模型。
    private static func selectSpelling(_ source: String, scene: String, context: VoiceContext, terms: [String],
                                       engine: PolishEngine, use: CloudUse) async -> String {
        guard let selection = SpellingSelection.loaded else { return source }
        let c = context.bounded()
        let fields = SpellingSelection.Fields(screen: c.screen, before: c.before, after: c.after,
                                              history: c.history.joined(separator: "\n"), terms: terms.joined(separator: "\n"))
        guard let prepared = SpellingSelection.prepare(source, scene: scene, compounds: true, fields),
              !prepared.hypotheses.isEmpty,
              prepared.hypotheses.contains(where: { $0.status == "unique" }) else { return source }
        do {
            let output = try await generate(PolishPrompt.Request(
                messages: selection.examples + [["role": "user", "content": prepared.text]], maxTokens: 128), engine: engine, use: use)
            guard let data = output.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
                  let choices = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let edited = SpellingSelection.apply(source, scene: scene, fields, choices: choices) else {
                Log.input.info("选同音词：模型的回答不合规矩，不换")
                return source
            }
            if edited != source { Log.input.info("选同音词：换了 \(choices.values.filter { $0 == "replace" }.count) 处") }
            return edited
        } catch {
            return source
        }
    }

    // MARK: - Rust 的规则

    static func clean(_ text: String) -> String {
        call(text) { wotype_polish_clean($0, $1, $2) }
    }

    static func finish(_ text: String, scene: VoiceScene) -> String {
        call(text) { wotype_polish_finish(scene.rawValue, $0, $1, $2) }
    }

    static func deliverable(_ text: String) -> Bool {
        text.withCString { wotype_polish_deliverable($0, 0) } == 1
    }

    nonisolated static func route(_ text: String) -> String {
        switch text.withCString({ wotype_polish_route($0) }) {
        case 0: "han"
        case 1: "latin"
        default: "mixed"
        }
    }

    /// 调一个「写进缓冲区、返回要多大」的接口。
    private static func call(_ text: String, _ body: (UnsafePointer<CChar>, UnsafeMutablePointer<CChar>, Int) -> Int) -> String {
        text.withCString { source in
            var capacity = text.utf8.count + 64
            while true {
                var buffer = [CChar](repeating: 0, count: capacity)
                let needed = buffer.withUnsafeMutableBufferPointer { body(source, $0.baseAddress!, capacity) }
                if needed < capacity { return String(cString: buffer) }
                capacity = needed + 1
            }
        }
    }

    private struct Timeout: Error {}

    private static func withTimeout<T: Sendable>(_ limit: Duration, _ body: @escaping @Sendable @MainActor () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw Timeout()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

/// 润色的提示词（selected.go 的 Format）：一条系统消息（角色、规则、场景、例子、输出要求）加一条用户消息
/// （<source>原文</source>）。按原文是中文、英文还是混合选中文或英文的版本。
nonisolated struct PolishPrompt: Sendable {
    struct Request {
        let messages: [[String: String]]
        let maxTokens: Int
    }

    private struct Recipe: Decodable {
        struct Example: Decodable {
            let source: String
            let output: String
        }

        struct Scene: Decodable {
            let instruction: String
            let instructionHan: String
        }

        let editingExamples: [Example]
        let formatSystem: String
        let formatSystemHan: String
        let formatRules: String
        let formatRulesHan: String
        let prosePolicy: String
        let prosePolicyHan: String
        let routeInstructions: [String: String]
        let contextRules: String
        let contextRulesHan: String
        let outputRule: String
        let outputRuleHan: String
        let format: [String: Scene]
        let translate: [String: Translation]

        /// 翻成一种语言的提示词（format.json 的 translate）
        struct Translation: Decodable {
            let system: String
            let rules: String
            let route: String
            let editingExamples: [Example]
            let scenes: [String: [Example]]
        }
    }

    private let recipe: Recipe

    static let shared: PolishPrompt? = {
        guard let url = Bundle.main.url(forResource: "polish-format", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let recipe = try? JSONDecoder().decode(Recipe.self, from: data) else {
            Log.input.error("读不出润色的提示词 polish-format.json")
            return nil
        }
        return PolishPrompt(recipe: recipe)
    }()

    func request(_ source: String, scene: String, context: VoiceContext = VoiceContext()) -> Request {
        let route = VoicePolish.route(source)
        let messages = [
            ["role": "system", "content": system(route: route, scene: scene)],
            ["role": "user", "content": context.userMessage(source: source)],
        ]
        // 回答的上限跟着原文长短走：至少 256，最多 2048（formatBudget）
        return Request(messages: messages, maxTokens: min(2048, max(256, source.unicodeScalars.count + 128)))
    }

    // MARK: - 翻译（selected.go 的 FormatTranslation、translationSystemPrompt、rulesBlock、exampleGroups）

    /// 翻译的请求：系统提示、这个场景的例子和通用的整理例子（一问一答）、用户消息。回答上限按原文每字 2 个 token。
    func translationRequest(_ source: String, scene: String, target: TranslationLanguage,
                            context: VoiceContext = VoiceContext()) -> Request {
        let messages = translationHead(scene: scene, target: target) + [["role": "user", "content": context.userMessage(source: source)]]
        return Request(messages: messages, maxTokens: min(2048, max(256, source.unicodeScalars.count * 2 + 128)))
    }

    /// 最后一条用户消息之前的部分（预热用）。
    func translationHead(scene: String, target: TranslationLanguage) -> [[String: String]] {
        let scene = recipe.format[scene] == nil ? "chat" : scene
        guard let tr = recipe.translate[target.rawValue] ?? recipe.translate["en"] else { return [] }
        let han = target == .zhCN
        let sceneRecipe = recipe.format[scene]!
        // rulesBlock：前言，再一个规则列表（规则、场景、排版（列表场景没有）、语言），标点按「智能」不加那一条
        var lines = tr.rules.components(separatedBy: "\n")
        lines.append(han ? sceneRecipe.instructionHan : sceneRecipe.instruction)
        if scene != "list" { lines.append(han ? recipe.prosePolicyHan : recipe.prosePolicy) }
        lines.append(tr.route)
        let system = tr.system + "\n\n<rules>\n" + lines.joined(separator: "\n") + "\n</rules>"
            + "\n\n# Context\n\n" + (han ? recipe.contextRulesHan : recipe.contextRules)
        var messages = [["role": "system", "content": system]]
        // 列表场景先放整理的例子，散文的例子不会盖过列表排版
        var groups = [tr.scenes[scene] ?? [], tr.editingExamples]
        if scene == "list" { groups.swapAt(0, 1) }
        for (group, examples) in groups.enumerated() {
            for e in examples {
                let output = scene == "list" && group == 0 ? "1. " + e.output : e.output
                messages.append(["role": "user", "content": "<source>" + e.source + "</source>"])
                messages.append(["role": "assistant", "content": output])
            }
        }
        return messages
    }

    /// 系统提示（systemPrompt）。标点按模型的（Arion 的「智能」标点，不加标点那一条）。
    func system(route: String, scene: String) -> String {
        let han = route == "han"
        let sceneRecipe = recipe.format[scene] ?? recipe.format["chat"]!
        var sections = [
            han ? recipe.formatSystemHan : recipe.formatSystem,
            han ? recipe.formatRulesHan : recipe.formatRules,
            "# Scene\n\n" + (han ? sceneRecipe.instructionHan : sceneRecipe.instruction),
        ]
        if scene != "list" {
            sections.append(han ? recipe.prosePolicyHan : recipe.prosePolicy)
        }
        sections.append(recipe.routeInstructions[route] ?? "")
        sections.append("# Context\n\n" + (han ? recipe.contextRulesHan : recipe.contextRules))
        let examples = recipe.editingExamples
            .filter { route == "mixed" || VoicePolish.route($0.source) == route }
            .map { han ? "原文：\($0.source)\n输出：\($0.output)" : "Input: \($0.source)\nOutput: \($0.output)" }
        sections.append("# Examples\n\n" + examples.joined(separator: "\n\n"))
        sections.append("# Output\n\n" + (han ? recipe.outputRuleHan : recipe.outputRule))
        return sections.joined(separator: "\n\n")
    }
}

/// 选同音词的读音表和例子（selected.go 的 Selected）。读音表有 4 MB，第一次用到时在后台载入。
@MainActor
final class SpellingSelection {
    /// 载入好了的；还没好时这次不选同音词
    private(set) static var loaded: SpellingSelection?
    private static var loading = false

    /// 系统提示加十条例子（用户消息 + 回答）
    let examples: [[String: String]]

    private init(examples: [[String: String]]) {
        self.examples = examples
    }

    nonisolated struct Fields: Sendable {
        var screen = ""
        var before = ""
        var after = ""
        var history = ""
        var terms = ""
    }

    nonisolated struct Prepared {
        struct Hypothesis: Decodable {
            let id: String
            let status: String
        }
        let text: String
        let hypotheses: [Hypothesis]
    }

    nonisolated private struct Recipe: Decodable {
        struct Example: Decodable {
            let scene: String
            let source: String
            let context: [String: String]
            let choice: String
            let expectHypotheses: Int
        }
        let selectionSystem: String
        let selectionExamples: [Example]
    }

    static func load() {
        guard loaded == nil, !loading else { return }
        loading = true
        Task.detached(priority: .utility) {
            let examples = Self.build()
            await MainActor.run {
                loading = false
                if let examples { loaded = SpellingSelection(examples: examples) }
            }
        }
    }

    /// 载入读音表，拼例子：每条例子按 Arion 的 Prepare 列候选，个数要和例子写的一样（不一样说明读音表不对，不用）。
    nonisolated private static func build() -> [[String: String]]? {
        guard let readings = Bundle.main.url(forResource: "pypinyin-character-readings-v1-readings", withExtension: "json"),
              let dictionary = Bundle.main.url(forResource: "cmudict-pronunciation-v1-cmudict", withExtension: "dict"),
              wotype_polish_spelling_load(readings.path, dictionary.path) == 1,
              let url = Bundle.main.url(forResource: "polish-selection", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let recipe = try? JSONDecoder().decode(Recipe.self, from: data) else {
            Log.input.error("选同音词的读音表或例子读不出来")
            return nil
        }
        var messages = [["role": "system", "content": recipe.selectionSystem]]
        for example in recipe.selectionExamples {
            let fields = Fields(screen: example.context["Screen"] ?? "")
            guard let prepared = prepare(example.source, scene: example.scene, compounds: false, fields),
                  prepared.hypotheses.count == example.expectHypotheses else {
                Log.input.error("选同音词的例子和读音表对不上，不用这一步")
                return nil
            }
            // Go 的 map 序列化按键排序
            let answer = prepared.hypotheses.sorted { $0.id < $1.id }.map { h in
                let choice = example.choice == "replaceUnique" && h.status == "unique" ? "replace" : "keep"
                return "\"\(h.id)\":\"\(choice)\""
            }
            messages.append(["role": "user", "content": prepared.text])
            messages.append(["role": "assistant", "content": "{" + answer.joined(separator: ",") + "}"])
        }
        return messages
    }

    nonisolated static func prepare(_ source: String, scene: String, compounds: Bool, _ fields: Fields) -> Prepared? {
        let json = cStrings([source, scene, fields.screen, fields.before, fields.after, fields.history, fields.terms]) { p in
            readBuffer { wotype_polish_spelling_prepare(p[0], p[1], compounds ? 1 : 0, p[2], p[3], p[4], p[5], p[6], $0, $1) }
        }
        guard let json, !json.isEmpty, let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String,
              let list = try? JSONDecoder().decode([Prepared.Hypothesis].self,
                                                  from: JSONSerialization.data(withJSONObject: object["hypotheses"] ?? [])) else {
            return nil
        }
        return Prepared(text: text, hypotheses: list)
    }

    nonisolated static func apply(_ source: String, scene: String, _ fields: Fields, choices: [String: String]) -> String? {
        let lines = choices.map { "\($0.key)\t\($0.value)" }.joined(separator: "\n")
        return cStrings([source, scene, fields.screen, fields.before, fields.after, fields.history, fields.terms, lines]) { p in
            readBuffer { wotype_polish_spelling_apply(p[0], p[1], 1, p[2], p[3], p[4], p[5], p[6], p[7], $0, $1) }
        }
    }

    /// 几个字符串一起转成 C 字符串。
    nonisolated private static func cStrings<R>(_ strings: [String], _ body: ([UnsafePointer<CChar>]) -> R) -> R {
        let pointers = strings.map { strdup($0)! }
        defer { pointers.forEach { free($0) } }
        return body(pointers.map { UnsafePointer($0) })
    }

    /// 调「写进缓冲区、返回要多大」的接口；返回 SIZE_MAX 是失败。
    nonisolated private static func readBuffer(_ body: (UnsafeMutablePointer<CChar>, Int) -> Int) -> String? {
        var capacity = 4096
        while true {
            var buffer = [CChar](repeating: 0, count: capacity)
            let needed = buffer.withUnsafeMutableBufferPointer { body($0.baseAddress!, capacity) }
            if needed == Int.max || needed == -1 { return nil }
            if needed < capacity { return String(cString: buffer) }
            capacity = needed + 1
        }
    }
}
