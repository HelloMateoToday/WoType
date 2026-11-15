//
//  OnboardingModel.swift
//  WoType
//
//  新手引导用到的状态，从各处收集成一个 OnboardingState（docs/18）。
//  输入法启用、切换有系统通知；下载有各自的通知；辅助功能权限没有通知，引导窗口开着时每秒查一次
//  （麦克风也一起查，在系统设置里改了不会通知过来）。
//

import Carbon
import Cocoa

final class OnboardingModel {

    /// state 变了（引导窗口据此刷新按钮和页面）。
    static let didChange = Notification.Name("WoTypeOnboardingModelDidChange")

    private(set) var state = OnboardingState()

    /// 下载那一步选了「以后再下」、服务商那一步选了「以后再加」
    var modelsDeferred = false {
        didSet { refresh() }
    }
    var providersDeferred = false {
        didSet { refresh() }
    }

    /// 这次打开引导，语音键已经按默认设成右 ⌘ 了（第一次走到选键那一步时设）
    var voiceKeyDefaulted = false

    /// 调试：不看条件（--mock、设置页的调试开关）
    var ignoresChecks = false {
        didSet { refresh() }
    }

    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        let local = NotificationCenter.default
        let distributed = DistributedNotificationCenter.default()
        let names: [(NotificationCenter, Notification.Name)] = [
            (distributed, Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String)),
            (distributed, Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)),
            (local, Settings.didChange),
            (local, MsimeHost.settledModelDidChange),
            (local, WanxiangGrammarModel.didChange),
            (local, VoiceModels.didChange),
            (local, CloudSpeech.didChange),
        ]
        for (center, name) in names {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            observers.append((center, observer))
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        MsimeHost.shared.refreshSettledModel()
        WanxiangGrammarModel.shared.refresh()
        VoiceModels.shared.refresh()
        refresh()
    }

    func stop() {
        for (center, observer) in observers { center.removeObserver(observer) }
        observers = []
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let config = Settings.shared.config
        var next = OnboardingState()
        (next.inputSourceEnabled, next.inputSourceSelected) = InputSource.status()
        let voice = config.voice
        next.voiceEnabled = voice
        // 要下载的：识别用本机模型；润色或语音翻译用本机模型（两个用的是同一个）
        let translating = config.voiceTranslateKey != nil
        next.needsSpeechModel = voice && config.voiceRecognizer == .local
        next.needsPolishModel = voice && (config.voicePolish && config.voicePolishEngine == .local
                                          || translating && config.voiceTranslateEngine == .local)
        (next.speechModelStarted, next.speechModelInstalled) = Self.modelState(.asr)
        next.polishModelStarted = Self.modelState(.polish).started
        next.modelsDeferred = modelsDeferred
        // 要添加的：选中的云端识别（要有密钥）；润色、语音翻译选的 AI 服务商
        if case .cloud(let id) = config.voiceRecognizer {
            next.needsCloudSpeech = voice
            next.hasCloudSpeech = CloudSpeech.shared.model(id: id).map { CloudSpeech.shared.apiKey($0) != nil } ?? false
        }
        let polishCloud = config.voicePolish && config.voicePolishEngine == .cloud
        let translateCloud = translating && config.voiceTranslateEngine == .cloud
        next.needsAIProvider = voice && (polishCloud || translateCloud)
        let added = Set(config.cloudModels.map(\.id))
        next.hasAIProvider = (!polishCloud || config.voicePolishCloudModel.map(added.contains) == true)
            && (!translateCloud || config.voiceTranslateCloudModel.map(added.contains) == true)
        next.providersDeferred = providersDeferred
        switch config.voiceRecognizer {
        case .local: next.recognitionReady = next.speechModelInstalled
        case .cloud: next.recognitionReady = next.hasCloudSpeech
        case .trial: next.recognitionReady = true
        }
        next.microphoneGranted = Permissions.microphone == .granted
        next.accessibilityGranted = Permissions.accessibility
        next.ignoresChecks = ignoresChecks
        guard next != state else { return }
        state = next
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// 一个语音模型开始下载了（或者已经装好）、装好了
    private static func modelState(_ spec: VoiceModelSpec) -> (started: Bool, installed: Bool) {
        switch VoiceModels.shared.state(spec) {
        case .installed: (true, true)
        case .connecting, .downloading, .verifying: (true, false)
        case .missing, .partial, .failed: (false, false)
        }
    }
}
