//
//  OnboardingFlowTests.swift
//  WoTypeTests
//
//  新手引导的步骤规则（UI/Onboarding/OnboardingFlow.swift）。不载入引擎。
//

import Testing
@testable import WoType

struct OnboardingFlowTests {

    /// #expect 里不能直接调会改值的方法
    private func move(_ flow: inout OnboardingFlow, _ delta: Int, _ state: OnboardingState) -> Bool {
        flow.move(delta, state)
    }

    /// 所有条件都满足、每一步都看得到的状态（识别和润色用本机、另外还要加服务商）。
    private var ready: OnboardingState {
        var state = OnboardingState()
        state.inputSourceEnabled = true
        state.inputSourceSelected = true
        state.needsSpeechModel = true
        state.needsPolishModel = true
        state.speechModelStarted = true
        state.speechModelInstalled = true
        state.polishModelStarted = true
        state.needsAIProvider = true
        state.hasAIProvider = true
        state.recognitionReady = true
        state.microphoneGranted = true
        state.accessibilityGranted = true
        return state
    }

    @Test func enableNeedsEnabledAndSelected() {
        var state = OnboardingState()
        #expect(!OnboardingFlow.ready(.enable, state))
        state.inputSourceEnabled = true
        #expect(!OnboardingFlow.ready(.enable, state))
        state.inputSourceSelected = true
        #expect(OnboardingFlow.ready(.enable, state))
    }

    @Test func voiceStepsAreTogetherBeforeTranslate() {
        // 拼音相关的走完，语音相关的放在一起：语音输入 → 下载模型 → 添加服务商 → 试试语音 → 语音翻译，最后是更多设置
        let steps = Array(OnboardingStep.allCases)
        #expect(Array(steps.suffix(6)) == [.voice, .voiceModels, .providers, .voiceKey, .voiceTranslate, .moreSettings])
        #expect(steps.firstIndex(of: .engine)! < steps.firstIndex(of: .typing)!)
        #expect(OnboardingFlow.ready(.engine, OnboardingState()), "引擎的模型可下可不下")
    }

    @Test func modelsStepOnlyWhenSomethingIsLocal() {
        var state = OnboardingState()
        // 识别、润色都用云端：没有下载这一步
        #expect(OnboardingFlow.skipped(.voiceModels, state))
        state.needsSpeechModel = true
        #expect(!OnboardingFlow.skipped(.voiceModels, state))
        // 开始下载就能继续；不下也能「以后再下」
        #expect(!OnboardingFlow.ready(.voiceModels, state))
        state.speechModelStarted = true
        #expect(OnboardingFlow.ready(.voiceModels, state))
        state.needsPolishModel = true
        #expect(!OnboardingFlow.ready(.voiceModels, state))
        state.modelsDeferred = true
        #expect(OnboardingFlow.ready(.voiceModels, state))
        // 不用语音：什么都不下
        state.voiceEnabled = false
        #expect(OnboardingFlow.skipped(.voiceModels, state))
    }

    @Test func providersStepOnlyWhenSomethingIsCloud() {
        var state = OnboardingState()
        #expect(OnboardingFlow.skipped(.providers, state))
        state.needsCloudSpeech = true
        state.needsAIProvider = true
        #expect(!OnboardingFlow.skipped(.providers, state))
        #expect(!OnboardingFlow.ready(.providers, state))
        state.hasCloudSpeech = true
        #expect(!OnboardingFlow.ready(.providers, state), "两样都要加")
        state.hasAIProvider = true
        #expect(OnboardingFlow.ready(.providers, state))
        state.hasAIProvider = false
        state.providersDeferred = true
        #expect(OnboardingFlow.ready(.providers, state))
    }

    @Test func tryVoiceDoesNotBlock() {
        // 不在最后了：模型还在下载、权限没给也能往下走（页面上写清楚）
        var state = ready
        state.recognitionReady = false
        state.microphoneGranted = false
        #expect(OnboardingFlow.ready(.voiceKey, state))
    }

    @Test func moreSettingsIsAlwaysLast() {
        var state = ready
        #expect(OnboardingFlow.visible(state).last == .moreSettings && OnboardingFlow.ready(.moreSettings, state))
        state.voiceEnabled = false
        #expect(OnboardingFlow.visible(state).last == .moreSettings)
    }

    @Test func permissionsCanBeSkipped() {
        #expect(OnboardingFlow.ready(.permissions, OnboardingState()))
    }

    @Test func forwardSkipsEnableWhenAlreadyAddedAndSelected() {
        var flow = OnboardingFlow()
        #expect(move(&flow, 1, ready))
        #expect(flow.step == .permissions)
        // 往回走还看得到
        #expect(move(&flow, -1, ready))
        #expect(flow.step == .enable)
    }

    @Test func voiceOffSkipsVoiceSteps() {
        var state = ready
        state.voiceEnabled = false
        #expect(OnboardingFlow.ready(.voice, state))
        #expect(OnboardingFlow.visible(state) == [.welcome, .enable, .permissions, .engine, .typing,
                                                  .selectionShow, .selectionReplace, .voice, .moreSettings])
        var flow = OnboardingFlow(step: .voice)
        #expect(move(&flow, 1, state) && flow.step == .moreSettings)
        #expect(flow.isLast(state))
        #expect(!move(&flow, 1, state))
        state.voiceEnabled = true
        #expect(flow.progress(state).total == 13)
    }

    @Test func moveStopsAtUnreadyStepAndRecordsDirection() {
        var flow = OnboardingFlow()
        var state = OnboardingState()
        #expect(flow.direction == 0)
        #expect(move(&flow, 1, state))
        #expect(flow.step == .enable)
        #expect(flow.direction == 1)
        #expect(!move(&flow, 1, state))
        #expect(flow.step == .enable)
        state.inputSourceEnabled = true
        state.inputSourceSelected = true
        #expect(move(&flow, 1, state))
        #expect(flow.step == .permissions)
        #expect(move(&flow, -1, state))
        #expect(flow.step == .enable)
        #expect(flow.direction == -1)
        #expect(move(&flow, -1, state))
        #expect(!move(&flow, -1, state))
        #expect(flow.isFirst)
    }

    @Test func walksAllStepsWhenReady() {
        var flow = OnboardingFlow()
        var seen = [flow.step]
        while flow.move(1, ready) { seen.append(flow.step) }
        // 已经加好、切过去了，「添加输入法」往前走时跳过
        // 没选云端识别（needsCloudSpeech 是 false），但润色用 AI 服务商，服务商那一步还在
        #expect(seen == OnboardingStep.allCases.filter { $0 != .enable })
        #expect(flow.isLast(ready))
        #expect(flow.progress(ready).current == 12)
    }

    @Test func ignoresChecksForDebugging() {
        var state = OnboardingState()
        state.ignoresChecks = true
        for step in OnboardingStep.allCases {
            #expect(OnboardingFlow.ready(step, state))
        }
    }
}
