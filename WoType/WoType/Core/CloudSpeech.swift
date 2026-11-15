//
//  CloudSpeech.swift
//  WoType
//
//  云端识别（docs/21）：用户自己填 API 密钥的官方接口，要能边说边出字（流式）。现在有 xAI；
//  以后加厂商：CloudSpeechProvider 加一项，Input/CloudRecognizers 里加一个识别器。
//  DeepSeek 的接口不流式（整段上传），用户定了不接（2026-11-14）。
//  密钥和云端润色存在同一个 cloud-keys.json 里，account 是「speech.<id>」。
//  语言（2026-11-14 用户定的）：默认中文，可以换别的或「自动识别」。指定了语言才能把说出来的数字写成阿拉伯数字
//  （xAI 的 format=true 要配 language，只有 11 种语言支持）；自动识别时不传 language，中途换语言也跟得上。
//

import Foundation

/// 云端识别的服务商。
nonisolated enum CloudSpeechProvider: String, Codable, CaseIterable, Sendable {
    case xai

    var title: String {
        switch self {
        case .xai: "xAI"
        }
    }

    /// 能选的模型
    var models: [String] {
        switch self {
        case .xai: ["grok-voice-transcribe-2.0"]
        }
    }

    /// 设置里显示的模型名
    func modelTitle(_ model: String) -> String { model }

    var keyPage: URL? {
        switch self {
        case .xai: URL(string: "https://console.x.ai/")
        }
    }

    var keyPageName: String {
        switch self {
        case .xai: "xAI 控制台"
        }
    }

    /// 这家的特点（设置里的说明）
    var summary: String {
        switch self {
        case .xai: "边说边出字。国内一般要开代理。"
        }
    }

    /// 能指定的语言；formats 是能不能把数字写成阿拉伯数字。前面是能写数字的
    var languages: [CloudSpeechLanguage] {
        switch self {
        case .xai: CloudSpeechLanguage.xai
        }
    }
}

/// 识别的语言。code 是空的表示自动识别（不传）。
nonisolated struct CloudSpeechLanguage: Equatable, Sendable {
    let code: String
    let title: String
    let formats: Bool

    static let automatic = CloudSpeechLanguage(code: "", title: "自动识别", formats: false)
    static let defaultCode = "zh"

    /// xAI 文档的 Supported Languages（38 种，能写数字的 11 种在前）
    static let xai: [CloudSpeechLanguage] = [
        ("zh", "中文"), ("en", "英语"), ("ja", "日语"), ("fr", "法语"), ("de", "德语"), ("es", "西班牙语"),
        ("pt", "葡萄牙语"), ("ru", "俄语"), ("ar", "阿拉伯语"), ("sv", "瑞典语"), ("vi", "越南语"),
    ].map { CloudSpeechLanguage(code: $0.0, title: $0.1, formats: true) } + [
        ("yue", "粤语"), ("ko", "韩语"), ("it", "意大利语"), ("th", "泰语"), ("id", "印尼语"), ("ms", "马来语"),
        ("fil", "菲律宾语"), ("hi", "印地语"), ("ur", "乌尔都语"), ("fa", "波斯语"), ("tr", "土耳其语"), ("el", "希腊语"),
        ("nl", "荷兰语"), ("pl", "波兰语"), ("cs", "捷克语"), ("sk", "斯洛伐克语"), ("hu", "匈牙利语"), ("ro", "罗马尼亚语"),
        ("bg", "保加利亚语"), ("hr", "克罗地亚语"), ("bs", "波斯尼亚语"), ("mk", "马其顿语"), ("uk", "乌克兰语"),
        ("da", "丹麦语"), ("nb", "挪威语"), ("fi", "芬兰语"), ("ca", "加泰罗尼亚语"),
    ].map { CloudSpeechLanguage(code: $0.0, title: $0.1, formats: false) }
}

/// 添加的一个云端识别。
nonisolated struct CloudSpeechModel: Codable, Equatable, Sendable {
    var id: String
    var provider: CloudSpeechProvider
    var model: String
    /// 识别的语言代码，空的是自动识别。老配置里没有这一项的按中文
    var language: String

    init(id: String, provider: CloudSpeechProvider, model: String, language: String = CloudSpeechLanguage.defaultCode) {
        self.id = id
        self.provider = provider
        self.model = model
        self.language = language
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        provider = try c.decode(CloudSpeechProvider.self, forKey: .provider)
        model = try c.decode(String.self, forKey: .model)
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? CloudSpeechLanguage.defaultCode
    }

    /// 选的语言（列表里没有的当自动识别）
    var spokenLanguage: CloudSpeechLanguage {
        provider.languages.first { $0.code == language } ?? .automatic
    }

    /// 「xAI · grok-voice-transcribe-2.0」
    var title: String { provider.title + " · " + provider.modelTitle(model) }
}

/// 云端识别出的错：把 HTTP 状态码、网络错误换成用户看得懂的话。
nonisolated struct CloudSpeechFailure: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }

    /// 按 HTTP 状态码
    static func status(_ code: Int, provider: CloudSpeechProvider, detail: String = "") -> CloudSpeechFailure {
        let name = provider.title
        let text: String = switch code {
        case 401, 403: "\(name) 拒绝了这个密钥"
        // xAI 密钥不对回的是 400（Incorrect API key provided）
        case 400 where provider == .xai: "\(name) 拒绝了请求，多半是密钥不对"
        case 402: "\(name) 的余额不足"
        case 413: "录音太大"
        case 429: "\(name) 请求太多或额度用完，稍后再试"
        case 500...599: "\(name) 暂时不可用（\(code)）"
        default: "\(name) 识别失败（\(code)）"
        }
        return CloudSpeechFailure(detail.isEmpty ? text : text + "：" + detail)
    }

    /// 连不上
    static func network(_ error: Error, provider: CloudSpeechProvider) -> CloudSpeechFailure {
        if let failure = error as? CloudSpeechFailure { return failure }
        let hint = provider == .xai ? "（国内一般要开代理）" : ""
        return CloudSpeechFailure("连不上 \(provider.title)\(hint)：" + error.localizedDescription)
    }
}

@MainActor
final class CloudSpeech {
    static let shared = CloudSpeech()
    static let didChange = Notification.Name("WoTypeCloudSpeechDidChange")

    var models: [CloudSpeechModel] { Settings.shared.config.cloudSpeechModels }

    func model(id: String) -> CloudSpeechModel? { models.first { $0.id == id } }

    func apiKey(_ model: CloudSpeechModel) -> String? { CloudPolish.shared.key(account: "speech." + model.id) }

    /// 正在用于语音输入
    func inUse(_ model: CloudSpeechModel) -> Bool { Settings.shared.config.voiceRecognizer == .cloud(model.id) }

    /// 添加或者改（id 已有就是改）。
    func save(_ model: CloudSpeechModel, key: String) {
        CloudPolish.shared.setKey(key.trimmingCharacters(in: .whitespacesAndNewlines), account: "speech." + model.id)
        Settings.shared.update { config in
            if let i = config.cloudSpeechModels.firstIndex(where: { $0.id == model.id }) {
                config.cloudSpeechModels[i] = model
            } else {
                config.cloudSpeechModels.append(model)
            }
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// 删掉和它的密钥。正在用它的语音输入改回本机。
    func remove(_ model: CloudSpeechModel) {
        CloudPolish.shared.setKey(nil, account: "speech." + model.id)
        Settings.shared.update { config in
            config.cloudSpeechModels.removeAll { $0.id == model.id }
            if config.voiceRecognizer == .cloud(model.id) { config.voiceRecognizer = .local }
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// 一次听写的识别器。模型删了、密钥没了是 nil。
    func makeRecognizer(id: String) -> SpeechRecognizer? {
        guard let model = model(id: id), let key = apiKey(model) else { return nil }
        switch model.provider {
        case .xai: return XAIRecognizer(key: key, model: model.model, language: model.spokenLanguage)
        }
    }

    /// 测试密钥能不能用，返回用了多久。xAI 连上等到 transcript.created（不发声音，不计费）。
    nonisolated static func test(_ provider: CloudSpeechProvider, key: String, model: String,
                                 language: CloudSpeechLanguage) async throws -> Duration {
        let clock = ContinuousClock()
        let began = clock.now
        switch provider {
        case .xai:
            let socket = try await XAIRecognizer.connect(key: key, model: model, language: language)
            socket.cancel(with: .normalClosure, reason: nil)
        }
        return clock.now - began
    }
}
