//
//  CloudPolish.swift
//  WoType
//
//  云端润色：用你自己的 API 密钥调服务商的模型，走和本机一样的润色、翻译流程（VoicePolish）。
//  照 Arion apps/desktop/infrastructure/cloudpolish@d2108fe（AGPL-3.0-only）：
//  - 服务商（provider.go）：OpenAI、Anthropic、Google Gemini、DeepSeek、OpenRouter、OpenAI 兼容、Anthropic 兼容；
//    Arion 还有「用 ChatGPT 订阅登录」，WoType 不做（它冒用 Codex 命令行的登录身份）；
//  - WoType 改成可以添加多个模型（同一个服务商也行），每个模型的密钥存在本机的 cloud-keys.json 里
//    （以前存钥匙串，每次换签名都要输密码，2026-11-12 改成文件，见 moveFromKeychain），
//    润色、语音翻译各选一个；
//  - 连接时拉一次模型列表，拉到了才算连上；没选过模型时默认选快而便宜的那一档（models.go 的 tiers、DefaultModel）；
//  - 关掉推理：先发 none，模型说关不掉、而且允许推理时，再试 minimal、low，记住它接受的最低一档
//    （completion.go 的 chatWithoutThinking）；
//  - 失败分成用户能处理的几类，浮窗提示（errors.go 的 classifyCompletion）。
//  Arion 用 Go 的 republic 库调各家接口，这里用 URLSession 直接调：OpenAI 的 chat/completions 格式
//  （OpenAI、DeepSeek、OpenRouter、Gemini 的 OpenAI 兼容接口、OpenAI 兼容）和 Anthropic 的 messages 格式。
//

import Foundation
import os
import Security

/// 云端服务商（provider.go 的 KeyProviders，名字是 config.go 的 CloudProviders）。
nonisolated enum CloudProvider: String, Codable, CaseIterable, Sendable {
    case openai, anthropic, google, deepseek, openrouter
    case openaiCompatible = "openai-compatible"
    case anthropicCompatible = "anthropic-compatible"

    var title: String {
        switch self {
        case .openai: "OpenAI"
        case .anthropic: "Anthropic"
        case .google: "Google Gemini"
        case .deepseek: "DeepSeek"
        case .openrouter: "OpenRouter"
        case .openaiCompatible: "OpenAI compatible"
        case .anthropicCompatible: "Anthropic compatible"
        }
    }

    /// 要用户填接口地址（NeedsBase）
    var needsBase: Bool { self == .openaiCompatible || self == .anthropicCompatible }

    var anthropicFormat: Bool { self == .anthropic || self == .anthropicCompatible }

    /// 固定的接口地址（兼容类的用用户填的）
    var defaultBase: String {
        switch self {
        case .openai: "https://api.openai.com/v1"
        case .anthropic: "https://api.anthropic.com/v1"
        case .google: "https://generativelanguage.googleapis.com/v1beta/openai"
        case .deepseek: "https://api.deepseek.com/v1"
        case .openrouter: "https://openrouter.ai/api/v1"
        case .openaiCompatible, .anthropicCompatible: ""
        }
    }

    /// 在哪儿创建 API 密钥（设置页的「创建 ↗」；兼容类没有）
    var keyPage: URL? {
        switch self {
        case .openai: URL(string: "https://platform.openai.com/api-keys")
        case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")
        case .google: URL(string: "https://aistudio.google.com/apikey")
        case .deepseek: URL(string: "https://platform.deepseek.com/api_keys")
        case .openrouter: URL(string: "https://openrouter.ai/keys")
        case .openaiCompatible, .anthropicCompatible: nil
        }
    }

    /// 在哪个平台创建（「在 DeepSeek 开放平台创建 ↗」）
    var keyPageName: String {
        switch self {
        case .openai: "OpenAI 平台"
        case .anthropic: "Anthropic 控制台"
        case .google: "Google AI Studio"
        case .deepseek: "DeepSeek 开放平台"
        case .openrouter: "OpenRouter"
        case .openaiCompatible, .anthropicCompatible: ""
        }
    }

    /// 没选过模型时默认用哪一档（models.go 的 tiers）：每档是模型 ID 必须都含的几个词，前面的档优先
    var tiers: [[String]] {
        switch self {
        case .openai, .openaiCompatible: [["luna"], ["mini"]]
        case .anthropic, .anthropicCompatible: [["haiku"]]
        case .google: [["flash-lite"], ["flash"]]
        case .deepseek: [["flash"], ["deepseek-chat"]]
        case .openrouter: [["openai/", "luna"], ["anthropic/", "haiku"], ["deepseek/", "flash"], ["google/", "flash-lite"]]
        }
    }
}

/// 老版本存的一个服务商的凭据（升级时读一次，换成按模型存的密钥）。
nonisolated struct CloudCredential: Codable, Sendable {
    var apiKey: String
    var baseURL: String
}

/// 添加的一个云端模型：服务商、接口地址（兼容类才有）、模型名。密钥按 id 单独存在钥匙串里。
nonisolated struct CloudModel: Codable, Equatable, Sendable {
    var id: String
    var provider: CloudProvider
    var model: String
    var baseURL: String

    /// 调接口用的地址
    var base: String { provider.needsBase ? baseURL : provider.defaultBase }

    /// 设置里的名字：「DeepSeek · deepseek-chat」（供应商在前，前面不放图标）
    var title: String { provider.title + " · " + model }
}

/// 云端模型用在哪儿：润色、语音翻译、划词翻译各选各的。
nonisolated enum CloudUse: Sendable {
    case polish, translate, selection
}

/// 云端出错的几类（errors.go；浮窗的提示照 Arion 的 PolishNote 文案）。
nonisolated enum CloudFailure: Error, Sendable {
    case reasoning, refused, rateLimited, quota, credential, outage, notFound, timeout, network
    /// 接口地址不是 http(s)
    case address
    /// 没连上、没选模型
    case notConnected

    var notice: Notice {
        switch self {
        case .reasoning: Notice(title: "模型需要推理", hint: "在设置 › 云端模型 › 高级中允许")
        case .refused: Notice(title: "此模型无法润色", hint: "在设置 › 云端模型中更换模型")
        case .rateLimited: Notice(title: "云端模型被限流", hint: "稍等片刻，或更换模型")
        case .quota: Notice(title: "云端额度已用完", hint: "请为服务商充值，或更换模型")
        case .credential: Notice(title: "云端密钥被拒绝", hint: "在设置 › 云端模型中重新连接")
        case .outage, .network, .notConnected: Notice(title: "云端模型不可用", hint: "稍后再试；文本已在本机整理")
        case .notFound: Notice(title: "找不到云端模型", hint: "在设置 › 云端模型中更换模型")
        case .timeout: Notice(title: "云端模型超时", hint: "请重试，或更换更快的模型")
        case .address: Notice(title: "请输入 http 或 https 地址")
        }
    }

    /// 设置页里连接、获取模型失败时的说法（CloudFail* 文案）
    var connectMessage: String {
        switch self {
        case .credential: "服务商拒绝了此密钥。"
        case .address: "请输入 http 或 https 地址。"
        case .network, .outage, .timeout: "无法连接服务商。"
        default: "无法加载模型列表。"
        }
    }
}

@MainActor
final class CloudPolish {
    static let shared = CloudPolish()

    /// 添加、删除、改了云端模型（设置页刷新）
    static let didChange = Notification.Name("WoTypeCloudDidChange")

    /// 以前存密钥的钥匙串条目（只在 moveFromKeychain 里读一次；改名前的 ID，不跟着改）
    private static let keychainService = "com.hereorcode.inputmethod.WowType.cloud"
    /// 密钥文件：{账户: 密钥}，账户是 model.<模型 id>（老版本还有按服务商名存的）。权限 600
    private static var keysURL: URL { Paths.userData.appendingPathComponent("cloud-keys.json") }
    /// 读进来的密钥（第一次用到时读文件）
    private var keys: [String: String]?
    /// 每个模型接受的最低推理档（"" 是不支持这个参数）
    private var reasoningFloor: [String: String] = [:]

    // MARK: - 状态

    /// 添加的云端模型
    var models: [CloudModel] { Settings.shared.config.cloudModels }

    /// 润色、翻译选的云端模型（删掉了就是 nil）
    func model(for use: CloudUse) -> CloudModel? {
        let config = Settings.shared.config
        let id = switch use {
        case .polish: config.voicePolishCloudModel
        case .translate: config.voiceTranslateCloudModel
        case .selection: config.selectionCloudModel
        }
        return models.first { $0.id == id }
    }

    /// 选了云端模型、密钥也在
    func ready(_ use: CloudUse) -> Bool { model(for: use).map { apiKey($0) != nil } ?? false }

    /// 这个模型用在哪儿（润色、翻译选的是它，而且选的是云端）
    func uses(_ model: CloudModel) -> [CloudUse] {
        let config = Settings.shared.config
        var uses: [CloudUse] = []
        if config.voicePolishEngine == .cloud, config.voicePolishCloudModel == model.id { uses.append(.polish) }
        if config.voiceTranslateEngine == .cloud, config.voiceTranslateCloudModel == model.id { uses.append(.translate) }
        if config.selectionEngine == "ai.cloud", config.selectionCloudModel == model.id { uses.append(.selection) }
        return uses
    }

    // MARK: - 密钥文件

    func apiKey(_ model: CloudModel) -> String? {
        read(account: "model." + model.id).map { String(decoding: $0, as: UTF8.self) }
    }

    /// 别的云端功能（云端识别）的密钥也存在同一个文件里，按 account 分开
    func key(account: String) -> String? {
        read(account: account).map { String(decoding: $0, as: UTF8.self) }
    }

    func setKey(_ key: String?, account: String) {
        store(key.map { Data($0.utf8) }, account: account)
    }

    private func read(account: String) -> Data? {
        loadKeys()[account].map { Data($0.utf8) }
    }

    private func store(_ data: Data?, account: String) {
        var all = loadKeys()
        all[account] = data.map { String(decoding: $0, as: UTF8.self) }
        keys = all
        writeKeys(all)
    }

    private func loadKeys() -> [String: String] {
        if let keys { return keys }
        let loaded = (try? Data(contentsOf: Self.keysURL))
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        keys = loaded
        return loaded
    }

    /// 写文件，只有自己能读写（600）
    private func writeKeys(_ all: [String: String]) {
        let url = Self.keysURL
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(all).write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            Log.app.error("云端密钥写不进文件：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 以前的密钥存在钥匙串里：第一次启动新版时搬进密钥文件，再从钥匙串删掉，以后不再读钥匙串。
    /// 有了密钥文件就算搬过了（没有密钥也写一个空文件）。只在输入法启动时调（测试里不碰钥匙串）
    func moveFromKeychain() {
        guard !FileManager.default.fileExists(atPath: Self.keysURL.path) else { return }
        let config = Settings.shared.config
        let accounts = config.cloudModels.map { "model." + $0.id } + CloudProvider.allCases.map(\.rawValue)
        var moved: [String: String] = [:]
        for account in accounts {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                        kSecAttrService as String: Self.keychainService,
                                        kSecAttrAccount as String: account, kSecReturnData as String: true]
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { continue }
            moved[account] = String(decoding: data, as: UTF8.self)
        }
        keys = moved
        writeKeys(moved)
        guard FileManager.default.fileExists(atPath: Self.keysURL.path) else { return }
        for account in moved.keys {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                        kSecAttrService as String: Self.keychainService, kSecAttrAccount as String: account]
            SecItemDelete(query as CFDictionary)
        }
        Log.app.info("云端模型：\(moved.count) 条密钥从钥匙串搬进了密钥文件")
    }

    /// 老版本：每个服务商存一条（账户名是服务商的名字），升级时给每个模型复制一条。
    func migrate() {
        let config = Settings.shared.config
        guard config.cloudModels.isEmpty, !config.voiceCloudModels.isEmpty else { return }
        var added: [CloudModel] = []
        var active: String?
        for provider in CloudProvider.allCases {
            guard let model = config.voiceCloudModels[provider.rawValue], let data = read(account: provider.rawValue),
                  let credential = try? JSONDecoder().decode(CloudCredential.self, from: data) else { continue }
            let entry = CloudModel(id: UUID().uuidString, provider: provider, model: model, baseURL: credential.baseURL)
            // 老的那条留着：退回老版本时还能用
            store(Data(credential.apiKey.utf8), account: "model." + entry.id)
            added.append(entry)
            if provider.rawValue == config.voiceCloudProvider { active = entry.id }
        }
        Settings.shared.update { config in
            config.cloudModels = added
            config.voicePolishCloudModel = active
            config.voiceTranslateCloudModel = active
            config.voiceCloudProvider = nil
            config.voiceCloudModels = [:]
        }
        Log.app.info("云端模型：老的设置换成了 \(added.count) 个模型")
    }

    // MARK: - 添加、编辑、删除

    /// 用这个密钥获取模型列表（填好密钥时验证用）。兼容类要填接口地址。
    func fetchModels(_ provider: CloudProvider, key: String, baseURL: String) async throws -> [String] {
        let base = try Self.normalizedBase(provider, baseURL)
        return try await Self.listModels(provider, key: key.trimmingCharacters(in: .whitespacesAndNewlines), base: base)
    }

    /// 已添加的模型用存着的密钥再拉一次列表（编辑时）。
    func fetchModels(_ model: CloudModel) async throws -> [String] {
        guard let key = apiKey(model) else { throw CloudFailure.credential }
        return try await Self.listModels(model.provider, key: key, base: model.base)
    }

    /// 添加或者改一个模型（id 已有就是改）。润色、翻译还没选云端模型的，选上它。
    func save(_ model: CloudModel, key: String) throws {
        var model = model
        model.baseURL = model.provider.needsBase ? try Self.normalizedBase(model.provider, model.baseURL) : ""
        store(Data(key.trimmingCharacters(in: .whitespacesAndNewlines).utf8), account: "model." + model.id)
        Settings.shared.update { config in
            if let i = config.cloudModels.firstIndex(where: { $0.id == model.id }) {
                config.cloudModels[i] = model
            } else {
                config.cloudModels.append(model)
            }
            let ids = Set(config.cloudModels.map(\.id))
            if !ids.contains(config.voicePolishCloudModel ?? "") { config.voicePolishCloudModel = model.id }
            if !ids.contains(config.voiceTranslateCloudModel ?? "") { config.voiceTranslateCloudModel = model.id }
            if !ids.contains(config.selectionCloudModel ?? "") { config.selectionCloudModel = model.id }
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// 删掉一个模型和它的密钥。正在用它的润色、翻译改回本机，划词翻译改回机器翻译的「自动」
    /// （还有别的云端模型时，选的换成第一个）。
    func remove(_ model: CloudModel) {
        store(nil, account: "model." + model.id)
        Settings.shared.update { config in
            config.cloudModels.removeAll { $0.id == model.id }
            let next = config.cloudModels.first?.id
            if config.voicePolishCloudModel == model.id {
                config.voicePolishCloudModel = next
                if config.voicePolishEngine == .cloud { config.voicePolishEngine = .local }
            }
            if config.voiceTranslateCloudModel == model.id {
                config.voiceTranslateCloudModel = next
                if config.voiceTranslateEngine == .cloud { config.voiceTranslateEngine = .local }
            }
            if config.selectionCloudModel == model.id {
                config.selectionCloudModel = next
                if config.selectionEngine == "ai.cloud" { config.selectionEngine = "auto" }
            }
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// 测试：用这个模型发一句很短的话，返回用了多久（「测试」按钮）。
    func test(_ model: CloudModel) async throws -> Duration {
        let started = ContinuousClock.now
        let reply = try await complete(messages: [["role": "system", "content": "Reply with the single word OK."],
                                                  ["role": "user", "content": "ping"]], maxTokens: 64, model: model)
        guard !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CloudFailure.refused }
        return ContinuousClock.now - started
    }

    // MARK: - 生成

    /// 润色、翻译选的云端模型发一次对话。
    func complete(messages: [[String: String]], maxTokens: Int, for use: CloudUse) async throws -> String {
        guard let model = model(for: use) else { throw CloudFailure.notConnected }
        return try await complete(messages: messages, maxTokens: maxTokens, model: model)
    }

    /// 发一次对话（润色、选同音词、翻译的每一步），关掉推理。回答没写完（截断、拒绝）算失败。
    func complete(messages: [[String: String]], maxTokens: Int, model entry: CloudModel) async throws -> String {
        guard let apiKey = apiKey(entry) else { throw CloudFailure.notConnected }
        let provider = entry.provider, model = entry.model, base = entry.base
        if provider.anthropicFormat {
            // Claude 默认不推理，不用关
            return try await Self.anthropicChat(base: base, key: apiKey, model: model, messages: messages, maxTokens: maxTokens)
        }
        let key = provider.rawValue + "/" + model
        let fallback = Settings.shared.config.voiceCloudReasoning
        // 记住的那一档只在允许推理时用；关了推理就回到 none
        var efforts: [String?] = ["none", "minimal", "low"]
        if let floor = reasoningFloor[key] {
            if floor.isEmpty {
                efforts = [nil]
            } else if fallback, let i = efforts.firstIndex(of: floor) {
                efforts = Array(efforts[i...])
            }
        }
        var index = 0
        while true {
            let effort = efforts[index]
            do {
                let text = try await Self.openAIChat(base: base, key: apiKey, model: model, messages: messages,
                                                      maxTokens: maxTokens, effort: effort, openAI: provider == .openai)
                if index > 0 || effort == nil { reasoningFloor[key] = effort ?? "" }
                return text
            } catch let error as HTTPError where error.status == 400 && effort != nil {
                let message = error.body.lowercased()
                if message.contains("cannot be disabled") || message.contains("reasoning is mandatory") {
                    // 推理关不掉：允许推理才往下试
                    guard fallback, index + 1 < efforts.count else { throw CloudFailure.reasoning }
                    index += 1
                } else if message.contains("reasoning") {
                    // 这个模型不认推理参数（不是推理模型）：不带它再发
                    efforts = [nil]
                    index = 0
                } else {
                    throw Self.classify(error)
                }
            } catch let error as HTTPError {
                throw Self.classify(error)
            }
        }
    }

    // MARK: - 接口

    nonisolated struct HTTPError: Error {
        let status: Int
        let body: String
    }

    nonisolated private static func normalizedBase(_ provider: CloudProvider, _ raw: String) throws -> String {
        guard provider.needsBase else { return provider.defaultBase }
        var base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil,
              url.user == nil, url.query == nil, url.fragment == nil else { throw CloudFailure.address }
        return base
    }

    nonisolated private static func request(_ url: URL, key: String, anthropic: Bool) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 30)
        if anthropic {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else {
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    nonisolated private static func send(_ request: URLRequest) async throws -> [String: Any] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw CloudFailure.timeout
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw CloudFailure.network
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw HTTPError(status: status, body: String(decoding: data.prefix(4096), as: UTF8.self))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CloudFailure.outage }
        return object
    }

    /// 模型列表：OpenAI 格式的 data[].id；Anthropic 的 data[].id（要翻页时只取前 1000 个）。
    nonisolated private static func listModels(_ provider: CloudProvider, key: String, base: String) async throws -> [String] {
        guard !key.isEmpty, let url = URL(string: base + "/models" + (provider.anthropicFormat ? "?limit=1000" : "")) else {
            throw CloudFailure.credential
        }
        var req = request(url, key: key, anthropic: provider.anthropicFormat)
        req.httpMethod = "GET"
        req.setValue(nil, forHTTPHeaderField: "Content-Type")
        do {
            // OpenRouter 的模型列表不看密钥（假的也能拉到），先用它查密钥的接口验一下（WoType 加的）
            if provider == .openrouter, let check = URL(string: base + "/key") {
                var keyRequest = request(check, key: key, anthropic: false)
                keyRequest.httpMethod = "GET"
                _ = try await send(keyRequest)
            }
            let object = try await send(req)
            let items = object["data"] as? [[String: Any]] ?? object["models"] as? [[String: Any]] ?? []
            let ids = items.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) }
                .map { $0.hasPrefix("models/") ? String($0.dropFirst("models/".count)) : $0 }
            guard !ids.isEmpty else { throw CloudFailure.notFound }
            return Array(Set(ids)).sorted()
        } catch let error as HTTPError {
            throw classify(error)
        }
    }

    nonisolated private static func openAIChat(base: String, key: String, model: String, messages: [[String: String]],
                                               maxTokens: Int, effort: String?, openAI: Bool) async throws -> String {
        guard let url = URL(string: base + "/chat/completions") else { throw CloudFailure.address }
        var body: [String: Any] = ["model": model, "messages": messages]
        // OpenAI 新的模型只认 max_completion_tokens
        body[openAI ? "max_completion_tokens" : "max_tokens"] = maxTokens
        if let effort { body["reasoning_effort"] = effort }
        var req = request(url, key: key, anthropic: false)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let object = try await send(req)
        guard let choice = (object["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any] else { throw CloudFailure.outage }
        if let refusal = message["refusal"] as? String, !refusal.isEmpty { throw CloudFailure.refused }
        // 没写完（finish_reason 不是 stop）：和本机一样算失败
        guard (choice["finish_reason"] as? String) == "stop" else { throw CloudFailure.refused }
        return message["content"] as? String ?? ""
    }

    nonisolated private static func anthropicChat(base: String, key: String, model: String, messages: [[String: String]],
                                                  maxTokens: Int) async throws -> String {
        guard let url = URL(string: base + "/messages") else { throw CloudFailure.address }
        let system = messages.filter { $0["role"] == "system" }.compactMap { $0["content"] }.joined(separator: "\n\n")
        let turns = messages.filter { $0["role"] != "system" }
        var body: [String: Any] = ["model": model, "max_tokens": maxTokens, "messages": turns]
        if !system.isEmpty { body["system"] = system }
        var req = request(url, key: key, anthropic: true)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        do {
            let object = try await send(req)
            guard (object["stop_reason"] as? String) == "end_turn" else { throw CloudFailure.refused }
            let blocks = object["content"] as? [[String: Any]] ?? []
            return blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        } catch let error as HTTPError {
            throw classify(error)
        }
    }

    /// HTTP 错误分成用户能处理的几类（classifyCompletion）。
    nonisolated static func classify(_ error: HTTPError) -> CloudFailure {
        let body = error.body.lowercased()
        switch error.status {
        case 401, 403: return .credential
        case 402: return .quota
        case 404: return .notFound
        case 408, 504: return .timeout
        case 429: return body.contains("quota") || body.contains("billing") || body.contains("credit") ? .quota : .rateLimited
        case 400 where body.contains("model") && (body.contains("not found") || body.contains("does not exist")): return .notFound
        case 400 where body.contains("api key") || body.contains("api_key"): return .credential
        case 500...: return .outage
        default: return .refused
        }
    }

    /// 没选过模型时默认用的（DefaultModel）：按档找，跳过预览、实验、语音、图片这些不适合的，同一档里取最新的。
    nonisolated static func defaultModel(_ provider: CloudProvider, _ models: [String]) -> String? {
        let unsuited = ["preview", "exp", "realtime", "audio", "tts", "image", "transcribe", "embed", "search", "vision"]
        for tier in provider.tiers {
            let candidates = models.filter { id in
                let lower = id.lowercased()
                return !unsuited.contains { lower.contains($0) } && tier.allSatisfy { lower.contains($0) }
            }
            // 不带日期的别名排在带日期的快照前面，其余按名字取最新
            if let best = candidates.max(by: { a, b in
                let (da, db) = (a.range(of: #"\d{4}-?\d{2}-?\d{2}"#, options: .regularExpression) != nil,
                                b.range(of: #"\d{4}-?\d{2}-?\d{2}"#, options: .regularExpression) != nil)
                if da != db { return da }
                return a.compare(b, options: .numeric) == .orderedAscending
            }) {
                return best
            }
        }
        return nil
    }
}
