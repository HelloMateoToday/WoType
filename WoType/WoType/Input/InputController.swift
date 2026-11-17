//
//  InputController.swift
//  WoType
//
//  每个输入框一个控制器：按键交给当前拼音引擎的会话（PinyinEngines.current，水杉或万象，docs/15），
//  再按快照上屏、更新编辑区和候选窗。交互逻辑（选词、翻页、标点、联想）都在引擎里；这里管的是 IMK 这一侧：中英切换、密码框、候选窗的位置。
//  踩过的坑见 docs/02-架构设计.md §6。
//

import Cocoa
import Carbon.HIToolbox
import InputMethodKit
import os

@objc(InputController)
class InputController: IMKInputController {

    /// 收到按键的那个控制器：候选窗的点击交给它。
    /// activateServer 不一定会被调用（Safari 地址栏等），所以每次按键都更新。
    private(set) static weak var current: InputController?

    /// 英文模式（单按 Shift 切换），所有输入框共用，和微信输入法一样。
    private static var asciiMode = false

    /// 当前拼音引擎的会话（整个进程一个，切输入框只切焦点）。
    /// 刚启动还没准备好时为 nil，按键交给应用。打到一半时不重建
    private var session: PinyinSession? {
        PinyinEngines.current.session(idle: lastMode == .idle)
    }
    /// 编辑区里现在有没有内容（没有时不去清，免得有的应用把空的标记文字当成一次输入）。
    private var hasMarkedText = false
    /// 上一次交给应用的编辑区和光标：只移高亮、翻页时编辑区没变，不再设一遍（每键最贵的一步，约 5 ms）
    private var lastMarked: (text: NSAttributedString, caret: Int)?
    /// 上一次快照的模式：idle 时没在组字（可以重建会话、按标点时读光标前的字）。
    private var lastMode: Snapshot.Mode = .idle
    /// 数字后刚上屏的中文「，」「：」：英文写法、上屏后光标在哪。紧接着打数字时换成英文的（照微信输入法）
    private var digitPunctuation: (ascii: String, chinese: String, location: Int)?
    /// 上一次的快照：译文翻好了用它重画候选窗
    private var lastSnapshot: Snapshot?

    /// 单按 Shift 的判断：按下时记下是哪个输入框、选区在哪，松开时中间没按别的键、
    /// 选区也没变（不是 Shift + 点击）才算。
    ///
    /// 这几个是全进程共用的，不跟着输入框走：Chrome 的空白页在按下和松开之间会换一个输入框对象，
    /// 跟着输入框走的话松开那一下就接不上了。
    private struct ShiftPress {
        var client: ObjectIdentifier
        var selection: NSRange
    }
    private static var shiftPress: ShiftPress?
    /// 单按 ⌃（候选翻译）：按下时只有 ⌃ 按着，松开前没按别的键
    private static var controlPress = false
    /// 上一次修饰键变化后的状态。
    private static var lastModifiers: NSEvent.ModifierFlags = []

    private var notFound: NSRange { NSRange(location: NSNotFound, length: NSNotFound) }

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        Self.connectPanel()
    }

    private static var panelConnected = false

    private static func connectPanel() {
        guard !panelConnected else { return }
        panelConnected = true
        CandidatePanel.shared.onSelect = { index in
            guard let controller = current else { return }
            controller.apply(controller.session?.select(index), to: controller.client())
        }
        CandidatePanel.shared.onToggleGrid = {
            guard let controller = current else { return }
            controller.apply(controller.session?.toggleGrid(), to: controller.client())
        }
        CandidatePanel.shared.onScroll = { rows in
            guard let controller = current else { return }
            controller.apply(controller.session?.scrollGrid(rows), to: controller.client())
        }
        CandidatePanel.shared.onTranslation = {
            current?.commitTranslation()
        }
        // 引擎自己更新了候选（水杉停顿后大模型重排）：只更新候选窗（这时没有上屏）。只认当前的引擎
        for engine in PinyinEngines.all {
            engine.onSettled = { [weak engine] snapshot in
                guard let controller = current, engine === PinyinEngines.current else { return }
                controller.apply(snapshot, to: controller.client())
            }
        }
        // 译文翻好了、翻译失败：用上一次的快照重画候选窗
        CandidateTranslator.shared.onChange = {
            guard let controller = current, let snapshot = controller.lastSnapshot, snapshot.mode != .idle else { return }
            controller.apply(snapshot.withoutCommit, to: controller.client())
        }
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        // 默认只收按下的键；单按 Shift、右 Option 要靠修饰键变化
        Int(NSEvent.EventTypeMask([.keyDown, .flagsChanged]).rawValue)
    }

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        Self.current = self
        Log.input.debug("激活 \(ObjectIdentifier(self).hashValue) app=\((sender as? IMKTextInput)?.bundleIdentifier() ?? "?", privacy: .public)")
        // 会话全进程共用：哪个输入框激活就给哪个焦点（系统可能先激活新的、再停用旧的）
        PinyinEngines.current.openSession?.setFocused(true)
        // 语音：先把录音准备好，按语音键时不丢开头的字
        if Settings.shared.config.voice { VoiceRecorder.shared.prepare() }
        // 按物理键位处理，Dvorak 等布局也能打拼音
        (sender as? IMKTextInput)?.overrideKeyboard(withKeyboardNamed: "com.apple.keylayout.ABC")
    }

    override func deactivateServer(_ sender: Any!) {
        // 失去焦点时清空编辑区，不往别的窗口上屏
        digitPunctuation = nil
        Log.input.debug("停用 \(ObjectIdentifier(self).hashValue) 当前=\(Self.current === self)")
        apply(PinyinEngines.current.openSession?.reset(commitPending: false), to: sender as? IMKTextInput)
        if Self.current === self {
            PinyinEngines.current.openSession?.setFocused(false)
            CandidatePanel.shared.hide()
            SelectionTranslation.shared.focusLost()
        }
        VoiceController.shared.focusLost()
        super.deactivateServer(sender)
    }

    /// 系统要求立即结束输入（比如切到别的输入法）：已选的词和原始字母上屏，不丢字。
    override func commitComposition(_ sender: Any!) {
        apply(PinyinEngines.current.openSession?.reset(commitPending: true), to: sender as? IMKTextInput)
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, let client = sender as? IMKTextInput else { return false }
        Self.current = self

        if event.type == .flagsChanged {
            handleModifiers(event, client: client)
            return false
        }
        guard event.type == .keyDown else { return false }
        Self.shiftPress = nil
        Self.controlPress = false
        // 语音输入中：Esc 取消（吃掉）；别的键让这次语音作废，键照常处理
        if VoiceController.shared.handleKey(event) {
            return true
        }

        // 密码框里不接管（也不读上下文）
        if SecureInput.isActive() {
            return false
        }
        // 划词翻译的快捷键（英文模式下也能用；正在打拼音时不响应），浮窗开着时 Esc 收起它
        if SelectionTranslation.shared.handle(event, client: client, composing: lastMode != .idle) {
            return true
        }
        // 英文模式：按键直接交给应用（照水杉 macOS 宿主：普通英文不经过引擎）
        if Self.asciiMode {
            return false
        }
        guard let session, let mapped = KeyMapper.map(event) else { return false }
        if let handled = translationKey(mapped) {
            return handled
        }
        let plain = mapped.modifiers & UInt32(WOTYPE_MOD_CONTROL | WOTYPE_MOD_OPTION | WOTYPE_MOD_COMMAND) == 0
        let isLetter = mapped.key < 0x80 && Character(UnicodeScalar(UInt8(mapped.key))).isLetter

        // 空编辑区打标点：把光标前一个字交给引擎，数字后的 . 原样输出（3.14）
        var preceding: UInt32 = 0
        if lastMode == .idle, plain, mapped.key > 0x20, mapped.key < 0x7F, !isLetter,
           !(0x30...0x39).contains(mapped.key),
           let before = ClientGeometry.textBeforeCaret(client, count: 1)?.unicodeScalars.last {
            preceding = before.value
        }
        // 数字后的 , :（照微信输入法）：先上屏中文的「，」「：」，紧接着打数字时换成英文的（1,000、12:30），
        // 后面是别的（汉字、空格……）就保持中文
        if let pending = digitPunctuation {
            digitPunctuation = nil
            if lastMode == .idle, plain, (0x30...0x39).contains(mapped.key) { restore(pending, client: client) }
        }
        if Settings.shared.config.asciiPunctAfterDigit, plain, mapped.key == 0x2C || mapped.key == 0x3A,
           let scalar = Unicode.Scalar(preceding), ("0"..."9").contains(Character(scalar)) {
            let ascii = mapped.key == 0x2C ? "," : ":", chinese = mapped.key == 0x2C ? "，" : "："
            client.insertText(chinese, replacementRange: notFound)
            let location = client.selectedRange().location
            if location != NSNotFound { digitPunctuation = (ascii, chinese, location) }
            return true
        }
        // 要上文的引擎（万象）：新输入的第一个字母、空编辑区的 . : 和数字，读一次光标前的文字，排序更准、
        // 数字后的标点原样输出、中英文之间补空格
        if session.wantsContext, lastMode == .idle, plain,
           isLetter || mapped.key == 0x2E || mapped.key == 0x3A || (0x30...0x39).contains(mapped.key),
           let before = ClientGeometry.textBeforeCaret(client) {
            session.setContext(before)
        }

        let started = DispatchTime.now().uptimeNanoseconds
        guard let snapshot = session.key(mapped.key, modifiers: mapped.modifiers, preceding: preceding) else { return false }
        let keyed = DispatchTime.now().uptimeNanoseconds
        apply(snapshot, to: client)
        let now = DispatchTime.now().uptimeNanoseconds
        let ms = Double(now - started) / 1_000_000
        let phases = String(format: "引擎 %.1f，组字区 %.1f，光标 %.1f，候选窗 %.1f",
                            Double(keyed - started) / 1e6, applyTimes.marked, applyTimes.caret, applyTimes.panel)
        if ms > 30 {
            Log.input.info("按键处理慢：\(ms, format: .fixed(precision: 1)) ms（\(phases, privacy: .public)）")
        } else {
            Log.input.debug("按键处理 \(ms, format: .fixed(precision: 1)) ms（\(phases, privacy: .public)）")
        }
        return snapshot.handled
    }

    // MARK: - 输入法菜单

    override func menu() -> NSMenu! {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "WoType 设置…", action: #selector(openSettings(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "自定义词…", action: #selector(openCustomWords(_:)), keyEquivalent: ""))
        // 引导、设置窗口没有 Dock 图标，被挡住了从这里再打开
        menu.addItem(NSMenuItem(title: "新手引导…", action: #selector(openOnboarding(_:)), keyEquivalent: ""))
        if let item = sceneMenuItem() {
            menu.addItem(.separator())
            menu.addItem(item)
        }
        return menu
    }

    /// 「润色场景（微信）」：给当前 App 指定润色场景（照 Arion 菜单栏面板里的「当前应用的场景」）。
    /// 只在语音输入和润色都开着时显示。
    private func sceneMenuItem() -> NSMenuItem? {
        let config = Settings.shared.config
        guard config.voice, VoicePolish.enabled, let app = client()?.bundleIdentifier(), !app.isEmpty else { return nil }
        let name = Self.appName(app)
        let automatic = VoiceScene.automatic(app: app, searchField: false)
        let chosen = config.voiceSceneOverrides[app].flatMap { VoiceScene(name: $0) }
        let submenu = NSMenu()
        let auto = NSMenuItem(title: "自动（\(automatic.title)）", action: #selector(chooseScene(_:)), keyEquivalent: "")
        auto.representedObject = app + "\t"
        auto.state = chosen == nil ? .on : .off
        submenu.addItem(auto)
        submenu.addItem(.separator())
        for scene in VoiceScene.all {
            let item = NSMenuItem(title: scene.title, action: #selector(chooseScene(_:)), keyEquivalent: "")
            item.representedObject = app + "\t" + scene.name
            item.state = chosen == scene ? .on : .off
            submenu.addItem(item)
        }
        let item = NSMenuItem(title: "润色场景（\(name)）", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    /// 查过的 App 名字：系统每激活一次输入框就要一次菜单，每次都问 LaunchServices 太费
    private static var appNames: [String: String] = [:]

    /// App 的名字（没装在本机就用 bundle ID）。
    static func appName(_ bundleID: String) -> String {
        if let name = appNames[bundleID] { return name }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        appNames[bundleID] = name
        return name
    }

    /// 菜单里选了场景：输入法菜单的动作传进来的是一个字典，菜单项在 kIMKCommandMenuItemName 里。
    @objc func chooseScene(_ sender: Any?) {
        let item = (sender as? [String: Any])?[kIMKCommandMenuItemName] as? NSMenuItem ?? sender as? NSMenuItem
        guard let value = item?.representedObject as? String else { return }
        let parts = value.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty else { return }
        Settings.shared.update { config in
            config.voiceSceneOverrides[parts[0]] = parts[1].isEmpty ? nil : parts[1]
        }
    }

    @objc func openSettings(_ sender: Any?) {
        SettingsWindowController.shared.open()
    }

    @objc func openOnboarding(_ sender: Any?) {
        OnboardingWindowController.shared.open()
    }

    @objc func openCustomWords(_ sender: Any?) {
        SettingsWindowController.shared.open(page: "words")
    }

    // MARK: - 中英切换

    private func handleModifiers(_ event: NSEvent, client: IMKTextInput) {
        // 按「哪一位变了」判断是哪个修饰键：模拟出来的按键（System Events 等）keyCode 是 0
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command, .capsLock, .function])
        // 语音键（fn / 右 ⌥ / 右 ⌘）：按下开始录音，松开识别上屏（VoiceController）。
        // 只认单按：按下时还按着别的修饰键（⇧、⌘…）不算
        let voiceKey = Settings.shared.config.voiceKey
        // 翻译键（右 ⌘ 等）：和语音键一样按住说话、点按持续，说完翻成目标语言（Arion 的 TranslateKey）
        let translateKey = Settings.shared.config.voiceTranslateKey
        if Settings.shared.config.voice, event.keyCode == voiceKey.keyCode,
           flags.contains(voiceKey.flag) != Self.lastModifiers.contains(voiceKey.flag) {
            if flags.contains(voiceKey.flag) {
                if flags.subtracting([voiceKey.flag, .capsLock]).isEmpty {
                    VoiceController.shared.keyDown(client: client, composing: lastMode != .idle, key: voiceKey)
                }
            } else {
                VoiceController.shared.keyUp(key: voiceKey)
            }
        } else if Settings.shared.config.voice, let translateKey, event.keyCode == translateKey.keyCode,
                  flags.contains(translateKey.flag) != Self.lastModifiers.contains(translateKey.flag) {
            if flags.contains(translateKey.flag) {
                if flags.subtracting([translateKey.flag, .capsLock]).isEmpty {
                    VoiceController.shared.keyDown(client: client, composing: lastMode != .idle, key: translateKey,
                                                   translate: true)
                }
            } else {
                VoiceController.shared.keyUp(key: translateKey)
            }
        } else if VoiceController.shared.isActive,
                  !flags.subtracting([voiceKey.flag, translateKey?.flag ?? [], .capsLock]).isEmpty {
            // 按着语音键又按了别的修饰键（⌥⇧ 打特殊字符）：这次不算语音
            _ = VoiceController.shared.handleKey(event)
        }
        controlTap(from: Self.lastModifiers, to: flags, client: client)
        let edge = Self.shiftEdge(from: Self.lastModifiers, to: flags)
        Self.lastModifiers = flags
        Log.input.debug("修饰键 flags=\(flags.rawValue, format: .hex) armed=\(Self.shiftPress != nil)")
        switch edge {
        case .repeated:
            // 同一个事件又送来一次（Chrome 网页里的输入框按下、松开各送两次），不算按了别的键。
            // 当成别的键的话，第二次「按下」就把单按作废了，网页里按 Shift 永远切不回来。见 docs/bugs
            return
        case .other:
            Self.shiftPress = nil
            return
        case .down, .up:
            break
        }
        let id = ObjectIdentifier(client as AnyObject)
        if case .down(let alone) = edge {
            // 按下：只有 Shift（大写锁定不算）才可能是单按
            Self.shiftPress = alone ? ShiftPress(client: id, selection: client.selectedRange()) : nil
        } else if let press = Self.shiftPress {
            Self.shiftPress = nil
            // Shift + 点击会改选区。只在同一个输入框、两次选区都有效时才比；
            // 换了输入框（Chrome 空白页）或者拿不到选区，就当没点
            let now = client.selectedRange()
            let comparable = press.client == id && press.selection.location != NSNotFound && now.location != NSNotFound
            if !comparable || now == press.selection {
                toggleASCIIMode(client: client)
            }
        }
    }

    nonisolated enum ShiftEdge: Equatable {
        /// 和上一次一模一样
        case repeated
        /// Shift 按下；alone：按下以后只有 Shift 是按着的
        case down(alone: Bool)
        /// Shift 松开
        case up
        /// 别的修饰键变了
        case other
    }

    /// 这次修饰键事件对 Shift 来说是什么。
    ///
    /// 只看 Shift 自己这一位有没有变，不要求「只有 Shift 变了」：上一次的状态可能是过期的。
    /// 用 ⌥空格 呼出启动器（Tinycast、Raycast）时，Option 按下送到了原来的输入框，
    /// 松开那一下谁也没收到，记着的还是「Option 按着」；接下来按 Shift，看起来是
    /// Option 和 Shift 一起变了，以前就不当成单按，第一下 Shift 没反应。见 docs/bugs/01
    nonisolated static func shiftEdge(from last: NSEvent.ModifierFlags, to flags: NSEvent.ModifierFlags) -> ShiftEdge {
        if flags == last { return .repeated }
        switch (last.contains(.shift), flags.contains(.shift)) {
        case (false, true): return .down(alone: flags.subtracting([.shift, .capsLock]).isEmpty)
        case (true, false): return .up
        default: return .other
        }
    }

    // MARK: - 候选翻译

    /// 单按 ⌃（左右都行）：按下时只有 ⌃，松开前没按别的键、别的修饰键也没动。⌃ 组合键（⌃A 等）不算。
    private func controlTap(from last: NSEvent.ModifierFlags, to flags: NSEvent.ModifierFlags, client: IMKTextInput) {
        if Self.controlTapped(&Self.controlPress, from: last, to: flags) { translateHighlighted() }
    }

    /// 这次修饰键变化是不是单按 ⌃ 的松开。pressed 记着「按下时只有 ⌃」，按别的键时由 handle 清掉。
    nonisolated static func controlTapped(_ pressed: inout Bool, from last: NSEvent.ModifierFlags,
                                          to flags: NSEvent.ModifierFlags) -> Bool {
        guard flags != last else { return false }
        switch (last.contains(.control), flags.contains(.control)) {
        case (false, true):
            pressed = flags.subtracting([.control, .capsLock]).isEmpty
            return false
        case (true, false):
            defer { pressed = false }
            return pressed && flags.subtracting(.capsLock).isEmpty
        default:
            pressed = false
            return false
        }
    }

    /// 翻高亮的候选（设置里开了、在打拼音、候选窗开着时）。
    private func translateHighlighted() {
        guard Settings.shared.config.candidateTranslation, !Self.asciiMode, let snapshot = lastSnapshot,
              snapshot.mode != .idle, let source = snapshot.highlight, CandidatePanel.shared.isVisible else { return }
        CandidateTranslator.shared.toggle(source: source, complete: snapshot.highlightComplete)
    }

    /// 译文条开着时的按键：⏎ 上屏译文，Esc 收起译文条（组字还在），别的键收起译文条再照常处理。
    /// 返回 nil 表示照常交给引擎。
    private func translationKey(_ mapped: KeyMapper.Mapped) -> Bool? {
        guard let bar = CandidateTranslator.shared.bar else { return nil }
        let plain = mapped.modifiers & UInt32(WOTYPE_MOD_CONTROL | WOTYPE_MOD_OPTION | WOTYPE_MOD_COMMAND | WOTYPE_MOD_SHIFT) == 0
        if plain, mapped.key == UInt32(WOTYPE_KEY_RETURN) {
            if bar.committable != nil {
                commitTranslation()
                return true
            }
            // 还在翻：先不动，免得把拼音原样上屏
            if bar.state == .translating { return true }
        }
        CandidateTranslator.shared.dismiss()
        if plain, mapped.key == UInt32(WOTYPE_KEY_ESCAPE) {
            if let snapshot = lastSnapshot { apply(snapshot.withoutCommit, to: client()) }
            return true
        }
        return nil
    }

    /// 上屏译文（⏎ 或点译文条）：撤掉组字，送出译文。
    private func commitTranslation() {
        guard let text = CandidateTranslator.shared.bar?.committable, let session else { return }
        CandidateTranslator.shared.dismiss()
        apply(session.commitText(text), to: client())
    }

    private func toggleASCIIMode(client: IMKTextInput) {
        Self.asciiMode.toggle()
        Log.input.info("单按 Shift：切到\(Self.asciiMode ? "英文" : "中文", privacy: .public)")
        // 打到一半切英文：已输入的字母原样上屏
        if Self.asciiMode { apply(PinyinEngines.current.openSession?.commitRaw(), to: client) }
        ModeToast.shared.show(Self.asciiMode ? "英" : "中", near: ClientGeometry.caretRect(client))
    }

    // MARK: - 编辑区、上屏、候选窗

    /// 上屏后光标往左退 count 个 UTF-16 单位（快捷短语指定了光标位置）。照水杉的 MSIMEPositionCommittedCursor：
    /// 在目标位置放一个空的编辑区再结束它，不用模拟按键，也就不要「辅助功能」权限。
    /// end：上屏后光标该在的位置（上屏前的位置 + 上屏的长度）。不在上屏后读 selectedRange：那时读到的常常还是上屏前的
    /// （2026-11-17 实测：空文档里按 ( 上屏「（）」后读到 0，应该是 2）
    private func moveCaretBack(_ count: Int, end: Int, client: IMKTextInput) {
        guard end >= count else { return }
        client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0),
                             replacementRange: NSRange(location: end - count, length: 0))
        client.insertText("", replacementRange: notFound)
    }

    /// 数字后的「，」「：」换成英文的：光标还在刚上屏的地方、前一个字还是它才换（中间点过别处、删掉了就不换）
    private func restore(_ pending: (ascii: String, chinese: String, location: Int), client: IMKTextInput) {
        guard client.selectedRange().location == pending.location, pending.location > 0,
              ClientGeometry.textBeforeCaret(client, count: 1) == pending.chinese else { return }
        let length = (pending.chinese as NSString).length
        client.insertText(pending.ascii, replacementRange: NSRange(location: pending.location - length, length: length))
    }

    /// 上一次 apply 各段用了多少毫秒（按键处理的日志用）
    private var applyTimes = (marked: 0.0, caret: 0.0, panel: 0.0)

    private func apply(_ snapshot: Snapshot?, to client: (any IMKTextInput)?) {
        guard var snapshot else { return }
        applyTimes = (0, 0, 0)
        var clock = DispatchTime.now().uptimeNanoseconds
        let lap = { () -> Double in
            let now = DispatchTime.now().uptimeNanoseconds
            defer { clock = now }
            return Double(now - clock) / 1e6
        }
        lastMode = snapshot.mode
        snapshot.translation = nil
        // 译文条跟着高亮的候选：高亮换了、组字没了就收起
        if let bar = CandidateTranslator.shared.bar {
            if snapshot.mode == .idle || snapshot.highlight != bar.source {
                CandidateTranslator.shared.dismiss()
            } else {
                snapshot.translation = bar
            }
        }
        lastSnapshot = snapshot
        guard let client else {
            // 拿不到输入框（失去焦点时可能这样）：至少把候选窗收起来，别留在屏幕上
            if snapshot.mode == .idle { CandidatePanel.shared.hide() }
            return
        }
        if !snapshot.commit.isEmpty {
            var text = snapshot.commit
            // 中英文、数字之间加空格：两次上屏之间问引擎要不要补（一次上屏里面的引擎自己加）
            if Settings.shared.config.spaceCJKLatin, let open = PinyinEngines.current.openSession,
               let before = ClientGeometry.textBeforeCaret(client, count: 1)?.unicodeScalars.last {
                text = open.spacedCommit(text, preceding: before.value, application: client.bundleIdentifier() ?? "")
            }
            // 上屏换掉编辑区（有的话），从它的开头起；没有就从光标处起
            let marked = client.markedRange()
            let start = hasMarkedText && marked.location != NSNotFound ? marked.location : client.selectedRange().location
            client.insertText(text, replacementRange: notFound)
            hasMarkedText = false
            lastMarked = nil
            if snapshot.caretBack > 0, start != NSNotFound {
                moveCaretBack(snapshot.caretBack, end: start + (text as NSString).length, client: client)
            }
        }
        guard snapshot.mode != .idle else {
            if hasMarkedText {
                client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0), replacementRange: notFound)
                hasMarkedText = false
            }
            lastMarked = nil
            CandidatePanel.shared.hide()
            return
        }

        // 编辑区：已选的词用粗下划线，还没选的拼音用细下划线
        let marked = NSMutableAttributedString()
        marked.append(NSAttributedString(string: snapshot.selected, attributes: [
            .underlineStyle: NSUnderlineStyle.thick.rawValue, .markedClauseSegment: 0,
        ]))
        marked.append(NSAttributedString(string: snapshot.remaining, attributes: [
            .underlineStyle: NSUnderlineStyle.single.rawValue, .markedClauseSegment: 1,
        ]))
        // 光标：← → 移进拼音里时在中间，否则在拼音末尾
        let caret = (snapshot.selected as NSString).length
            + min(snapshot.caret ?? Int.max, (snapshot.remaining as NSString).length)
        // 和上次一样、应用那边的编辑区也还在（长度对得上，没被应用自己结束掉）就不再设
        let unchanged = hasMarkedText && lastMarked.map { $0.caret == caret && $0.text.isEqual(to: marked) } == true
            && client.markedRange().length == marked.length
        if !unchanged {
            client.setMarkedText(marked, selectionRange: NSRange(location: caret, length: 0),
                                 replacementRange: notFound)
            lastMarked = (marked, caret)
        }
        hasMarkedText = marked.length > 0
        applyTimes.marked = lap()

        if snapshot.candidates.isEmpty {
            CandidatePanel.shared.hide()
        } else {
            let caret = ClientGeometry.caretRect(client)
            applyTimes.caret = lap()
            CandidatePanel.shared.show(snapshot, caret: caret)
            applyTimes.panel = lap()
            // 兼容性测试用：光标位置换成左上角原点的屏幕坐标（和 System Events 的窗口坐标一致）
            let top = (NSScreen.screens.first?.frame.maxY ?? 0) - caret.maxY
            Log.input.debug("光标 x=\(Int(caret.minX)) y=\(Int(top)) h=\(Int(caret.height)) app=\(client.bundleIdentifier() ?? "?", privacy: .public)")
        }
    }
}
