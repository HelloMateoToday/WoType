//
//  VoiceController.swift
//  WoType
//
//  一次语音输入，从按键到上屏。会话的状态和走法照 Arion packages/core/application/dictation.go@d2108fe
//  （AGPL-3.0-only）的 Coordinator：准备 → 录音 → 识别 → 定稿 → 插入 → 完成 / 失败 / 取消；
//  录音时每一帧算音量、交给分段识别（pump）；识别出的草稿变了就更新浮窗（acceptDraft）；
//  松开后把没定稿的识别完（finalize），没字算没说话，有字就插入（deliver、commit）。
//  按键手势用 HoldGesture（hold.go），分段识别用 StreamingRecognizer（asr/recognizer.go），
//  浮窗由 VoiceCapsule 按这些状态画（capsule.go）。
//
//  和 Arion 不同：
//  - Arion 有两条路（全局快捷键往任何应用粘贴、自己的输入法往输入框插入）；WoType 只有输入法这一条，
//    结果用 insertText 插进开始说话时的那个输入框，输入框不在了就放进剪贴板；
//  - 清理规则、词库、润色、改错学习还没接（阶段 3、4）。
//

import AppKit
import InputMethodKit
import os

@MainActor
final class VoiceController {

    static let shared = VoiceController()

    /// 一次最长录多久（Arion 的 defaultMaxAudio）
    static let maxAudio = 5 * 60 * 16_000

    private var gesture = HoldGesture()
    private var sessionNumber = 0
    /// 开始说话时的输入框：结果只插进它
    private var target: ObjectIdentifier?
    private var recognizer: SpeechRecognizer?
    private var captured = 0
    private var lastDraft = ""
    /// 这次听写用的错误写法
    private var vocabulary = VocabularyIndex([])
    /// 这次听写的润色场景（开始说话时按输入框所在的 App 定）
    private var scene = VoiceScene.chat
    /// 这次听写的 App（场景、最近的听写按它分）
    private var app: String?
    /// 窗口里看得到的文字（开始说话时到后台去读，润色前等它）
    private var screenTask: Task<String?, Never>?
    /// 这次听写已经预热过润色模型
    private var polishPrepared = false
    private var finalizeTask: Task<Void, Never>?

    private init() {
        VoiceRecorder.shared.onFrame = { [weak self] frame in self?.pump(frame) }
    }

    private var state: SessionState { VoiceCapsule.shared.dictation.state }

    private var session: String { VoiceCapsule.shared.dictation.sessionID }
    /// 现在的手势是哪个键按的（语音键或翻译键）
    private var gestureKey: VoiceKey?
    /// 按下的是翻译键（会话开始时用）
    private var pendingTranslate = false
    /// 这次是语音翻译：翻成哪种语言（nil 是普通听写）
    private var translating: TranslationLanguage?

    private var holdSession: HoldSession {
        switch state {
        case .preparing, .capturing: .capturing
        case .finalizing, .reviewing, .committing: .busy
        default: .idle
        }
    }

    /// 有进行中的会话（输入法据此决定 Esc 等按键给不给它）
    var isActive: Bool { VoiceCapsule.shared.dictation.isActive }

    // MARK: - 按键

    /// 语音键或翻译键按下。composing：正在打拼音（这时语音键交给应用，不抢）。
    /// translate：按的是翻译键（照 Arion，两个键共用一套按住、点按的手势，会话开始时记下这次是不是翻译）。
    func keyDown(client: IMKTextInput, composing: Bool, key: VoiceKey, translate: Bool = false) {
        if holdSession == .idle && composing { return }
        // 会话由另一个键开着：不管（按着它再按这个键，是组合键，由 handleKey 那条路作废）
        if holdSession != .idle, let gestureKey, key != gestureKey { return }
        if holdSession == .idle {
            gestureKey = key
            pendingTranslate = translate
        }
        let action = gesture.press(Date(), session: holdSession)
        VoiceCapsule.shared.update { $0.holding = true }
        perform(action, client: client)
    }

    /// 语音键或翻译键松开（不是开着会话的那个键就不管）。
    func keyUp(key: VoiceKey) {
        if let gestureKey, key != gestureKey { return }
        let action = gesture.release(Date())
        if isActive { VoiceCapsule.shared.update { $0.holding = false } }
        perform(action, client: nil)
    }

    /// 输入法收到一个按键（不是语音键）。返回 true 表示吃掉这个键。
    func handleKey(_ event: NSEvent) -> Bool {
        guard isActive else { return false }
        // Esc：会话进行中都能取消（Arion 在会话可以取消时才接管 Esc）
        if event.keyCode == 53 {
            Log.input.info("语音：Esc 取消")
            cancel()
            return true
        }
        if gesture.down {
            Log.input.info("语音：按着语音键时按了别的键（\(event.keyCode)）")
        }
        // 按着语音键时按了别的键：组合键，这次作废，那个键照常处理
        perform(gesture.other(), client: nil)
        return false
    }

    /// 输入框失去焦点、切走了输入法：照 Arion 丢掉输入法这条路上的会话。
    func focusLost() {
        gesture.reset()
        gestureKey = nil
        if isActive { Log.input.info("语音：输入框失去焦点，取消") }
        cancel()
    }

    private func perform(_ action: HoldAction, client: IMKTextInput?) {
        if action != .none {
            Log.input.info("语音：\(String(describing: action), privacy: .public)（状态 \(String(describing: self.state), privacy: .public)）")
        }
        switch action {
        case .start: if let client { start(client: client) }
        case .stop: stop()
        case .cancel: cancel()
        case .none: break
        }
    }

    // MARK: - 会话

    private func start(client: IMKTextInput) {
        let began = ContinuousClock.now
        // 上一次插入的改错学习：开始下一次听写就算改完了；还在显示的「已记住」收起
        EditTracker.shared.next()
        VoiceCapsule.shared.dismissLearned()
        sessionNumber += 1
        translating = pendingTranslate ? Settings.shared.config.voiceTranslateLanguage : nil
        target = ObjectIdentifier(client as AnyObject)
        captured = 0
        lastDraft = ""
        VoiceCapsule.shared.update {
            $0.sessionID = "s\(sessionNumber)"
            $0.draft = ""
            $0.final = ""
            $0.rewriting = false
            $0.levels = []
            $0.failure = nil
            $0.polishNote = nil
            $0.outcome = DictationCopy.inserted
            $0.keyLegend = Self.legend(gestureKey ?? Settings.shared.config.voiceKey)
            $0.holding = gesture.down
        }
        VoiceCapsule.shared.set(.preparing)
        // 准备：密码框不录；本机识别要模型在；再开麦克风
        if SecureInput.isActive() {
            return fail(DictationCopy.secure)
        }
        let choice = Settings.shared.config.voiceRecognizer
        Log.input.info("语音：识别方式 \(choice.name, privacy: .public)")
        if choice == .local {
            guard VoiceService.modelReady else {
                return fail(DictationCopy.modelMissing)
            }
            VoiceService.shared.prepare()
        }
        // 润色的场景按开始说话时的输入框定，先按 App 定；是不是搜索框在按键处理完以后到后台去查
        // （处理按键时查会和前台 App 互相等，见 VoiceScene.focusedSearchField）
        let app = client.bundleIdentifier()
        self.app = app
        scene = VoiceScene.decide(app: app, searchField: false)
        screenTask = nil
        if VoicePolish.enabled || translating != nil {
            let session = self.session
            // 窗口文字也到后台读（Arion 的 startContext），密码管理器这类 App 不读
            if Settings.shared.config.voiceContextScreen, !VoiceContext.denied(app) {
                screenTask = Task.detached(priority: .userInitiated) { VoiceContext.windowText() }
            }
            Task.detached(priority: .userInitiated) {
                let search = VoiceScene.focusedSearchField()
                await MainActor.run {
                    let controller = VoiceController.shared
                    guard controller.session == session, controller.isActive else { return }
                    controller.scene = VoiceScene.decide(app: app, searchField: search)
                }
            }
        }
        // 热词和错误写法在开始说话时取一份，这次听写都用它（Arion 的 recognitionHotwords、Policy）
        vocabulary = VoiceVocabulary.shared.index
        let recognizer: SpeechRecognizer
        switch choice {
        case .local:
            recognizer = StreamingRecognizer(hotwords: VoiceVocabulary.shared.hotwords())
        case .cloud(let id):
            guard let cloud = CloudSpeech.shared.makeRecognizer(id: id) else {
                return fail(Notice(title: "云端识别不可用", hint: "在设置 › 模型管理里检查密钥"))
            }
            recognizer = cloud
        case .trial(let channel):
            recognizer = channel.makeRecognizer()
        }
        polishPrepared = false
        recognizer.onRevision = { [weak self, weak recognizer] in
            guard let self, let recognizer, recognizer === self.recognizer else { return }
            self.acceptDraft(recognizer.partial)
            self.preparePolish()
        }
        self.recognizer = recognizer
        guard VoiceRecorder.shared.start() else {
            return fail(VoiceRecorder.authorized ? DictationCopy.device : DictationCopy.micDenied)
        }
        VoiceCapsule.shared.set(.capturing)
        VoiceCues.playStart()
        Log.input.info("语音：按下到开始录音用了 \(ContinuousClock.now - began, privacy: .public)")
    }

    /// 录音的每一帧：音量给浮窗，声音给分段识别（Arion 的 pump）。
    private func pump(_ frame: [Float]) {
        guard let recognizer, state == .capturing || state == .finalizing else { return }
        VoiceCapsule.shared.level(VoiceRecorder.level(frame))
        do {
            try recognizer.accept(frame)
        } catch {
            if state == .capturing { fail(DictationCopy.generic) }
            return
        }
        captured += frame.count
        if captured >= Self.maxAudio { stop() }
    }

    private func acceptDraft(_ text: String) {
        let text = VoiceCorrection.correct(text, vocabulary: vocabulary).text
        guard state == .capturing, text != lastDraft else { return }
        lastDraft = text
        VoiceCapsule.shared.update { $0.draft = text }
    }

    /// 结束录音；识别完没定稿的部分再插入。
    private func stop() {
        guard state == .capturing else { return }
        VoiceCapsule.shared.set(.finalizing)
        VoiceCues.playStop()
        VoiceRecorder.shared.stop()
        let session = self.session
        // 排在录音线程已经送出的最后几帧后面
        finalizeTask = Task { [weak self] in
            await Task.yield()
            await self?.finalize(session: session)
        }
    }

    private func finalize(session: String) async {
        guard let recognizer, self.session == session, state == .finalizing else { return }
        Log.input.info("录音 \(Double(self.captured) / 16_000, format: .fixed(precision: 1)) 秒，识别没定稿的部分")
        var raw: String
        /// 云端识别没成功、改用了本机：插入后在浮窗里说一声
        var recognitionNote: Notice?
        do {
            raw = try await recognizer.finish()
        } catch {
            guard self.session == session, state == .finalizing else { return }
            Log.input.error("识别失败：\(error.localizedDescription, privacy: .public)")
            // 云端识别失败：本机模型在的话，用留着的整段录音在本机重新识别（docs/21）
            guard let recording = recognizer.recording, VoiceService.modelReady else {
                let hint = recognizer.recording == nil ? error.localizedDescription
                    : error.localizedDescription + "。可以在设置 › 语音输入里改用本机识别"
                return fail(Notice(title: "识别失败", hint: hint))
            }
            Log.input.info("改用本机识别整段录音")
            recognitionNote = Notice(title: "云端识别不可用，已用本机识别", hint: error.localizedDescription)
            do {
                raw = try await StreamingRecognizer.decodeAll(recording, hotwords: VoiceVocabulary.shared.hotwords())
            } catch {
                guard self.session == session, state == .finalizing else { return }
                return fail(Notice(title: "识别失败", hint: error.localizedDescription))
            }
        }
        raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 过期的结果（取消了、已经是下一次了）不能更新浮窗、不能插入
        guard self.session == session, state == .finalizing else { return }
        recognizer.close()
        if let recognitionNote { VoiceCapsule.shared.update { $0.polishNote = recognitionNote } }
        self.recognizer = nil
        // 没识别出字：不插入（SPH-09）
        guard !raw.isEmpty else { return fail(DictationCopy.noSpeech) }
        // 整理：合并空格、拼缩写、换错误写法（correction.go，Arion dictation.go 的 deliver）
        let corrected = VoiceCorrection.correct(raw, vocabulary: vocabulary)
        VoiceVocabulary.shared.recall(corrected.recalled)
        var text = corrected.text
        // 语音翻译（Arion 的 rewriteFinal 带 TargetLanguage）：失败时不插入，浮窗提示
        if let target = translating {
            VoiceCapsule.shared.update { $0.rewriting = true }
            let context = await readContext()
            guard self.session == session, state == .finalizing else { return }
            let result = await VoicePolish.translate(text, scene: scene, target: target, context: context,
                                                     terms: vocabulary.terms(text, limit: 8))
            guard self.session == session, state == .finalizing else { return }
            switch result {
            case .success(let translated) where !translated.isEmpty:
                text = translated
            case .success:
                return fail(VoicePolish.TranslationFailure.failed.notice)
            case .failure(let failure):
                return fail(failure.notice)
            }
        } else if VoicePolish.enabled {
            // 润色（Arion 的 rewriteFinal）：浮窗换成润色的动画；失败时用清理过口语的原文
            VoiceCapsule.shared.update { $0.rewriting = true }
            let context = await readContext()
            guard self.session == session, state == .finalizing else { return }
            // 识别结果里出现过的词条给选同音词当参考（Arion 的 termsForFinal，最多 8 个）
            let terms = vocabulary.terms(text, limit: 8)
            text = await VoicePolish.polish(text, scene: scene, context: context, terms: terms)
            // 云端没成功：上屏的是本机整理的文字，结果之后提示原因
            if let note = VoicePolish.lastNote { VoiceCapsule.shared.update { $0.polishNote = note } }
            // 再按词库换一遍错误写法：选同音词或润色模型参考了上下文（比如最近的听写里改之前的写法），
            // 可能把词库换好的词又改回去；词库是用户认可的写法，以它为准（WoType 加的，Arion 没有这一步）
            text = vocabulary.apply(text).0
            guard self.session == session, state == .finalizing else { return }
            guard !text.isEmpty else { return fail(DictationCopy.noSpeech) }
        }
        VoiceCapsule.shared.update { $0.final = text }
        VoiceCapsule.shared.set(.reviewing)
        commit(text)
    }

    /// 第一行草稿出来以后再预热润色模型（载入模型、把提示词算进缓存）。和开始说话同时做的话，
    /// 辅助进程刚启动时会和识别抢 GPU，第一行草稿从 1.3 秒推迟到 3 秒（docs/10）。
    /// 辅助进程开着时提示词已经缓存了，预热什么都不做。
    private func preparePolish() {
        if let translating {
            guard !polishPrepared else { return }
            polishPrepared = true
            let config = Settings.shared.config
            VoicePolish.prepare(scene: scene, withContext: config.voiceContextCursor || config.voiceContextScreen
                || config.voiceContextHistory, translating: translating)
            return
        }
        guard !polishPrepared, VoicePolish.enabled else { return }
        polishPrepared = true
        let config = Settings.shared.config
        VoicePolish.prepare(scene: scene, withContext: config.voiceContextCursor
            || config.voiceContextScreen || config.voiceContextHistory)
    }

    /// 润色要参考的上下文（照设置）：光标前后的文字这时候读（还没插入，也不在处理按键）；
    /// 窗口文字等开始说话时就去读的那个；最近的听写从内存里拿。
    private func readContext() async -> VoiceContext {
        let config = Settings.shared.config
        var context = VoiceContext()
        guard !VoiceContext.denied(app) else { return context }
        if config.voiceContextCursor, let client = InputController.current?.client(),
           ObjectIdentifier(client as AnyObject) == target {
            (context.before, context.after) = VoiceContext.cursor(client)
        }
        if config.voiceContextHistory {
            context.history = VoiceHistory.shared.recent(place: app)
        }
        if let screenTask {
            context.screen = await screenTask.value ?? ""
        }
        return context
    }

    /// 插入：只插进开始说话时的那个输入框；它不在了就不插，文字放进剪贴板。
    private func commit(_ text: String) {
        VoiceCapsule.shared.set(.committing)
        if let client = InputController.current?.client(), ObjectIdentifier(client as AnyObject) == target {
            client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
            if Settings.shared.config.voiceContextHistory { VoiceHistory.shared.add(text, place: app) }
            // 翻译出来的字不学（改的是译文，不是识别错的词）
            if translating == nil { EditTracker.shared.track(client: client, inserted: text) }
            VoiceCapsule.shared.update { $0.outcome = DictationCopy.inserted }
            VoiceCapsule.shared.set(.completed)
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            fail(DictationCopy.targetChanged)
        }
        target = nil
    }

    private func cancel() {
        guard isActive else { return }
        let wasRecording = state == .preparing || state == .capturing
        VoiceCapsule.shared.set(.cancelled)
        end(recording: wasRecording)
    }

    private func fail(_ notice: Notice) {
        let wasRecording = state == .preparing || state == .capturing
        VoiceCapsule.shared.update { $0.failure = notice }
        VoiceCapsule.shared.set(.failed)
        end(recording: wasRecording)
    }

    /// 会话结束：停录音、丢掉识别（还在跑的草稿、最终识别都取消）。
    private func end(recording: Bool) {
        if recording { VoiceRecorder.shared.stop() }
        finalizeTask?.cancel()
        finalizeTask = nil
        screenTask = nil
        recognizer?.close()
        recognizer = nil
        target = nil
    }

    /// 键帽上的字（Arion holdkey.Legend：fn、⌥、⌘）
    static func legend(_ key: VoiceKey) -> String {
        switch key {
        case .fn: "fn"
        case .rightOption: "⌥"
        case .rightCommand: "⌘"
        }
    }
}
