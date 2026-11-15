//
//  OnboardingFlow.swift
//  WoType
//
//  新手引导的步骤和规则（docs/18），照 Arion apps/desktop/ui/entities/onboarding：
//  「继续」能不能点只看真实状态（ready）；跳过的步骤不显示、不算进度（skipped、progress）；
//  前进后退记下方向，翻页动画据此往哪边滑（move）。只有逻辑，不碰界面，单元测试直接测。
//

import Foundation

nonisolated enum OnboardingStep: Int, CaseIterable {
    case welcome
    /// 启用 WoType 并切换过去
    case enable
    /// 允许麦克风和辅助功能（语音、划词翻译、符号自动补全要用），可以先跳过
    case permissions
    /// 水杉还是万象；所选引擎的模型（水杉的大模型、万象的语法模型）在这一页下载，可下可不下
    case engine
    /// 试用区：打字和候选翻译
    case typing
    /// 划词翻译：翻译并显示（⌃⌥T）
    case selectionShow
    /// 划词翻译：翻译并替换（⌃⌥I）
    case selectionReplace
    /// 要不要语音；要的话选识别方式（本机模型、云端识别、免费体验）和润色、语音翻译用什么（本机模型、AI 服务商）。
    /// 语音相关的几步放在一起：语音输入 → 下载模型 → 添加服务商 → 试试语音 → 语音翻译
    case voice
    /// 下载本机模型（识别、润色和翻译）：上一步选了本机模型才有，可以以后再下
    case voiceModels
    /// 添加服务商（云端识别、AI 服务商）：语音那一步选了云端才有，可以以后再加
    case providers
    /// 选语音键，打开「文本编辑」试一试（放在语音翻译前面：先定语音键，选翻译键时它占着的灰掉）
    case voiceKey
    /// 语音翻译：开关、翻译键、翻译成什么（用什么翻在「语音输入」那一步和润色一起选）
    case voiceTranslate
    /// 更多设置在 WoType 设置里：「打开设置」（完成引导再打开设置窗口），底部「完成」完成引导
    case moreSettings
}

/// 判断能不能继续用到的状态。OnboardingModel 从各处收集，测试直接构造。
nonisolated struct OnboardingState: Equatable {
    var inputSourceEnabled = false
    var inputSourceSelected = false
    /// 设置里的语音开关（Config.voice）
    var voiceEnabled = true
    /// 识别用本机模型、润色或语音翻译用本机模型：要下载的
    var needsSpeechModel = false
    var needsPolishModel = false
    /// 识别模型、润色模型开始下载了（或者已经装好）
    var speechModelStarted = false
    var speechModelInstalled = false
    var polishModelStarted = false
    /// 下载那一步选了「以后再下」
    var modelsDeferred = false
    /// 识别用云端识别、润色或语音翻译用 AI 服务商：要添加的
    var needsCloudSpeech = false
    var needsAIProvider = false
    /// 选中的云端识别加好了（有密钥）、润色和翻译用的 AI 服务商加好了
    var hasCloudSpeech = false
    var hasAIProvider = false
    /// 服务商那一步选了「以后再加」
    var providersDeferred = false
    /// 选的识别方式现在能用：本机模型装好了、云端识别有密钥、或者是免费体验
    var recognitionReady = false
    var microphoneGranted = false
    var accessibilityGranted = false
    /// 调试：不看条件，每一步都能继续（--mock、设置页的调试开关）
    var ignoresChecks = false
}

nonisolated struct OnboardingFlow: Equatable {

    private(set) var step: OnboardingStep
    /// 上一次移动的方向：1 前进，-1 后退，0 刚打开
    private(set) var direction = 0

    init(step: OnboardingStep = .welcome) {
        self.step = step
    }

    /// 这一步的「继续」（最后一步是「完成」）能不能点。
    static func ready(_ step: OnboardingStep, _ state: OnboardingState) -> Bool {
        if state.ignoresChecks { return true }
        switch step {
        case .welcome, .permissions, .voice, .engine, .typing, .selectionShow, .selectionReplace, .voiceTranslate,
             .moreSettings:
            return true
        case .enable:
            return state.inputSourceEnabled && state.inputSourceSelected
        case .voiceModels:
            // 开始下载就能往下走（在后台下），不用等下完
            let started = (!state.needsSpeechModel || state.speechModelStarted)
                && (!state.needsPolishModel || state.polishModelStarted)
            return started || state.modelsDeferred
        case .providers:
            let added = (!state.needsCloudSpeech || state.hasCloudSpeech) && (!state.needsAIProvider || state.hasAIProvider)
            return added || state.providersDeferred
        case .voiceKey:
            // 不在最后了，不拦：模型还在下载、权限没给也能往下走，页面上写清楚现在能不能说
            return true
        }
    }

    /// 不要语音时没有下载、服务商、语音翻译、试试语音这几步；不用本机模型时没有下载，不用云端时没有服务商。
    static func skipped(_ step: OnboardingStep, _ state: OnboardingState) -> Bool {
        switch step {
        case .voiceModels: !state.voiceEnabled || !(state.needsSpeechModel || state.needsPolishModel)
        case .providers: !state.voiceEnabled || !(state.needsCloudSpeech || state.needsAIProvider)
        case .voiceTranslate, .voiceKey: !state.voiceEnabled
        default: false
        }
    }

    /// 用户实际会看到的步骤。
    static func visible(_ state: OnboardingState) -> [OnboardingStep] {
        OnboardingStep.allCases.filter { !skipped($0, state) }
    }

    /// 当前是看得到的第几步（从 0 数），一共几步。
    func progress(_ state: OnboardingState) -> (current: Int, total: Int) {
        let steps = Self.visible(state)
        return (steps.firstIndex(of: step) ?? 0, steps.count)
    }

    /// 这一步是最后一步：按钮是「完成」。
    func isLast(_ state: OnboardingState) -> Bool {
        Self.visible(state).last == step
    }

    var isFirst: Bool { step == OnboardingStep.allCases.first }

    /// 前进（delta > 0）或后退一步，跳过不显示的步骤。前进要这一步 ready；走不动返回 false。
    /// 往前走到「添加输入法」时，已经加好、切过去了就直接跳过（安装器已经教过了，docs/19）；往回走还能看到
    @discardableResult
    mutating func move(_ delta: Int, _ state: OnboardingState) -> Bool {
        let forward = delta > 0
        if forward && !Self.ready(step, state) { return false }
        var index = step.rawValue
        repeat {
            index += forward ? 1 : -1
            guard let next = OnboardingStep(rawValue: index) else { return false }
            let done = forward && next == .enable && Self.ready(.enable, state)
            if !Self.skipped(next, state) && !done {
                step = next
                direction = forward ? 1 : -1
                return true
            }
        } while true
    }
}
