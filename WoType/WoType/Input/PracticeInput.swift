//
//  PracticeInput.swift
//  WoType
//
//  新手引导的试用区（docs/18）：引导窗口自己接按键，不经过系统输入法。
//  引导单独运行（--onboarding）时在另一个进程里，替普通文本框打字的会是装好的那份 WoType；
//  从设置打开时又在输入法进程自己里面。两种情况都不靠 IMK：PracticeTextView 不给系统输入法（inputContext 为 nil），
//  按键交给 PracticeInputController，它照 InputController 的做法驱动当前拼音引擎的会话、真的候选窗、
//  候选翻译。InputController 不动。ClientGeometry 要一个 IMKTextInput：PracticeClient 把文本框包成一个。
//  语音不在这里试：引导里打开「文本编辑」，用装好的 WoType 直接说（OnboardingSteps 的「试试语音」）。
//
//  试打的字会照常进引擎的学习记录（引擎没有「这次不学」的开关），只有引导里打的这几个词。
//

import Cocoa
import Carbon.HIToolbox
import InputMethodKit

// MARK: - 文本框

/// 试用区的文本框：按键先给 controller，它不要的再照常处理（英文、⌘ 组合键、方向键）。
final class PracticeTextView: NSTextView {

    var controller: PracticeInputController?
    /// 文字或编辑区变了（试用区据此显示、隐藏提示）
    var onTextChange: (() -> Void)?

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onTextChange?()
    }

    override func unmarkText() {
        super.unmarkText()
        onTextChange?()
    }

    override func didChangeText() {
        super.didChangeText()
        onTextChange?()
    }

    /// 不给系统输入法：按键全由 controller 处理
    override var inputContext: NSTextInputContext? { nil }

    override func keyDown(with event: NSEvent) {
        if controller?.handle(event) == true { return }
        super.keyDown(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        controller?.flagsChanged(event)
        super.flagsChanged(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { controller?.focus(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { controller?.focus(false) }
        return accepted
    }
}

// MARK: - 当成输入框

/// 把试用区的文本框包成 IMKTextInput，交给候选窗定位（ClientGeometry）。
final class PracticeClient: NSObject, IMKTextInput {

    weak var textView: NSTextView?

    init(_ textView: NSTextView) {
        self.textView = textView
    }

    private var notFound: NSRange { NSRange(location: NSNotFound, length: NSNotFound) }

    func insertText(_ string: Any!, replacementRange: NSRange) {
        textView?.insertText(string as Any, replacementRange: replacementRange)
    }

    func setMarkedText(_ string: Any!, selectionRange: NSRange, replacementRange: NSRange) {
        textView?.setMarkedText(string as Any, selectedRange: selectionRange, replacementRange: replacementRange)
    }

    func selectedRange() -> NSRange { textView?.selectedRange() ?? notFound }

    func markedRange() -> NSRange { textView?.markedRange() ?? notFound }

    func attributedSubstring(from range: NSRange) -> NSAttributedString! {
        textView?.attributedSubstring(forProposedRange: range, actualRange: nil)
    }

    func length() -> Int { (textView?.string as NSString?)?.length ?? 0 }

    func characterIndex(for point: NSPoint, tracking mappingMode: IMKLocationToOffsetMappingMode,
                        inMarkedRange: UnsafeMutablePointer<ObjCBool>!) -> Int {
        textView?.characterIndex(for: point) ?? NSNotFound
    }

    /// IMK 的约定：index 从编辑区开头（没有编辑区时从光标）数，lineRect 是那一行的屏幕坐标。
    func attributes(forCharacterIndex index: Int, lineHeightRectangle lineRect: UnsafeMutablePointer<NSRect>!) -> [AnyHashable: Any]! {
        guard let textView else { return [:] }
        let marked = textView.markedRange()
        let base = marked.length > 0 ? marked.location : textView.selectedRange().location
        lineRect?.pointee = textView.firstRect(forCharacterRange: NSRange(location: base + index, length: 0), actualRange: nil)
        return [:]
    }

    func validAttributesForMarkedText() -> [Any]! { [] }

    func overrideKeyboard(withKeyboardNamed keyboardUniqueName: String!) {}

    func selectMode(_ modeIdentifier: String!) {}

    func supportsUnicode() -> Bool { true }

    func bundleIdentifier() -> String! { Bundle.main.bundleIdentifier }

    func windowLevel() -> CGWindowLevel { CGWindowLevel(textView?.window?.level.rawValue ?? 0) }

    func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool { false }

    func uniqueClientIdentifierString() -> String! { "WoTypePractice" }

    func string(from range: NSRange, actualRange: NSRangePointer!) -> String! {
        attributedSubstring(from: range)?.string
    }

    func firstRect(forCharacterRange aRange: NSRange, actualRange: NSRangePointer!) -> NSRect {
        textView?.firstRect(forCharacterRange: aRange, actualRange: actualRange) ?? .zero
    }
}

// MARK: - 按键处理

/// 试用区的「输入法」：照 InputController 处理按键和上屏，但对着 PracticeTextView。
final class PracticeInputController {

    /// 试用区发生的事（引导据此打勾、提示）
    enum Event {
        /// 拼音上屏了一段
        case committed(String)
        /// 单按了 ⌃（candidateOn：候选翻译开着、候选窗也开着，真的翻了）
        case controlTapped(translated: Bool)
        /// 上屏了候选的译文
        case translationCommitted(String)
    }

    var onEvent: ((Event) -> Void)?
    /// 别的快捷键（划词翻译的 ⌃⌥I）：返回 true 是吃掉了
    var keyFilter: ((NSEvent) -> Bool)?

    private weak var textView: PracticeTextView?
    let client: PracticeClient
    private var lastSnapshot: Snapshot?
    private var lastMode: Snapshot.Mode = .idle
    private var controlPress = false
    private var lastModifiers: NSEvent.ModifierFlags = []
    private var focused = false

    /// 候选窗、译文、引擎重排原来交给谁（输入法进程里是 InputController），失去焦点时还回去
    private struct Hooks {
        var onSelect: ((Int) -> Void)?
        var onToggleGrid: (() -> Void)?
        var onScroll: ((Int) -> Void)?
        var onTranslation: (() -> Void)?
        var translatorChange: (() -> Void)?
        var settled: [((Snapshot) -> Void)?]
    }
    private var saved: Hooks?

    /// 单独运行的进程里引擎没人准备：第一次用到时准备一次
    private static var prepared = false

    init(textView: PracticeTextView) {
        self.textView = textView
        client = PracticeClient(textView)
        textView.controller = self
    }

    private var notFound: NSRange { NSRange(location: NSNotFound, length: NSNotFound) }

    private var session: PinyinSession? {
        PinyinEngines.current.session(idle: lastMode == .idle)
    }

    /// 拼音引擎准备好了没有（单独运行时第一次要等一两秒，万象更久）
    var engineReady: Bool { PinyinEngines.current.session(idle: true) != nil || lastMode != .idle }

    static func prepareEngine() {
        guard !prepared, PinyinEngines.current.session(idle: true) == nil else { return }
        prepared = true
        PinyinEngines.current.prepare()
    }

    // MARK: 焦点

    func focus(_ on: Bool) {
        guard on != focused else { return }
        focused = on
        if on {
            Self.prepareEngine()
            takeOverHooks()
            PinyinEngines.current.openSession?.setFocused(true)
        } else {
            apply(PinyinEngines.current.openSession?.reset(commitPending: false))
            PinyinEngines.current.openSession?.setFocused(false)
            CandidateTranslator.shared.dismiss()
            CandidatePanel.shared.hide()
            restoreHooks()
            lastModifiers = []
            controlPress = false
        }
    }

    private func takeOverHooks() {
        guard saved == nil else { return }
        let panel = CandidatePanel.shared
        saved = Hooks(onSelect: panel.onSelect, onToggleGrid: panel.onToggleGrid, onScroll: panel.onScroll,
                      onTranslation: panel.onTranslation, translatorChange: CandidateTranslator.shared.onChange,
                      settled: PinyinEngines.all.map { $0.onSettled })
        panel.onSelect = { [weak self] index in self?.apply(self?.session?.select(index)) }
        panel.onToggleGrid = { [weak self] in self?.apply(self?.session?.toggleGrid()) }
        panel.onScroll = { [weak self] rows in self?.apply(self?.session?.scrollGrid(rows)) }
        panel.onTranslation = { [weak self] in self?.commitTranslation() }
        CandidateTranslator.shared.onChange = { [weak self] in
            guard let self, let snapshot = self.lastSnapshot, snapshot.mode != .idle else { return }
            self.apply(snapshot.withoutCommit)
        }
        for engine in PinyinEngines.all {
            engine.onSettled = { [weak self, weak engine] snapshot in
                guard engine === PinyinEngines.current else { return }
                self?.apply(snapshot)
            }
        }
    }

    private func restoreHooks() {
        guard let saved else { return }
        let panel = CandidatePanel.shared
        panel.onSelect = saved.onSelect
        panel.onToggleGrid = saved.onToggleGrid
        panel.onScroll = saved.onScroll
        panel.onTranslation = saved.onTranslation
        CandidateTranslator.shared.onChange = saved.translatorChange
        for (engine, settled) in zip(PinyinEngines.all, saved.settled) { engine.onSettled = settled }
        self.saved = nil
    }

    // MARK: 按键

    /// 按下的键。返回 true 是处理了，文本框不再处理。
    func handle(_ event: NSEvent) -> Bool {
        controlPress = false
        if lastMode == .idle, keyFilter?(event) == true { return true }
        guard let session, let mapped = KeyMapper.map(event) else { return false }
        if let handled = translationKey(mapped) { return handled }
        let isLetter = mapped.key < 0x80 && Character(UnicodeScalar(UInt8(mapped.key))).isLetter
        let plain = mapped.modifiers & UInt32(WOTYPE_MOD_CONTROL | WOTYPE_MOD_OPTION | WOTYPE_MOD_COMMAND) == 0
        if session.wantsContext, lastMode == .idle, plain, isLetter,
           let before = ClientGeometry.textBeforeCaret(client) {
            session.setContext(before)
        }
        guard let snapshot = session.key(mapped.key, modifiers: mapped.modifiers, preceding: 0) else { return false }
        apply(snapshot)
        return snapshot.handled
    }

    /// 修饰键变了：单按 ⌃。
    func flagsChanged(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command, .capsLock, .function])
        if InputController.controlTapped(&controlPress, from: lastModifiers, to: flags) {
            onEvent?(.controlTapped(translated: translateHighlighted()))
        }
        lastModifiers = flags
    }

    /// 翻高亮的候选（设置里开了、在打拼音、候选窗开着时）。翻了返回 true。
    private func translateHighlighted() -> Bool {
        guard Settings.shared.config.candidateTranslation, let snapshot = lastSnapshot,
              snapshot.mode != .idle, let source = snapshot.highlight, CandidatePanel.shared.isVisible else { return false }
        CandidateTranslator.shared.toggle(source: source, complete: snapshot.highlightComplete)
        return true
    }

    /// 译文条开着时：⏎ 上屏译文，Esc 收起译文条，别的键收起译文条再照常处理（同 InputController）。
    private func translationKey(_ mapped: KeyMapper.Mapped) -> Bool? {
        guard let bar = CandidateTranslator.shared.bar else { return nil }
        let plain = mapped.modifiers & UInt32(WOTYPE_MOD_CONTROL | WOTYPE_MOD_OPTION | WOTYPE_MOD_COMMAND | WOTYPE_MOD_SHIFT) == 0
        if plain, mapped.key == UInt32(WOTYPE_KEY_RETURN) {
            if bar.committable != nil {
                commitTranslation()
                return true
            }
            if bar.state == .translating { return true }
        }
        CandidateTranslator.shared.dismiss()
        if plain, mapped.key == UInt32(WOTYPE_KEY_ESCAPE) {
            if let snapshot = lastSnapshot { apply(snapshot.withoutCommit) }
            return true
        }
        return nil
    }

    private func commitTranslation() {
        guard let text = CandidateTranslator.shared.bar?.committable, let session else { return }
        CandidateTranslator.shared.dismiss()
        apply(session.commitText(text))
        onEvent?(.translationCommitted(text))
    }

    // MARK: 上屏、编辑区、候选窗

    private func apply(_ snapshot: Snapshot?) {
        guard var snapshot, let textView else { return }
        lastMode = snapshot.mode
        snapshot.translation = nil
        if let bar = CandidateTranslator.shared.bar {
            if snapshot.mode == .idle || snapshot.highlight != bar.source {
                CandidateTranslator.shared.dismiss()
            } else {
                snapshot.translation = bar
            }
        }
        lastSnapshot = snapshot
        if !snapshot.commit.isEmpty {
            // 有编辑区时换掉编辑区（拼音上屏不经过 client，免得算成语音插入）
            textView.insertText(snapshot.commit, replacementRange: notFound)
            // 补上的右括号、带光标位置的快捷短语：光标退回去
            let selection = textView.selectedRange()
            if snapshot.caretBack > 0, selection.location >= snapshot.caretBack {
                textView.setSelectedRange(NSRange(location: selection.location - snapshot.caretBack, length: 0))
            }
            onEvent?(.committed(snapshot.commit))
        }
        guard snapshot.mode != .idle else {
            if textView.hasMarkedText() {
                textView.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: notFound)
                textView.unmarkText()
            }
            CandidatePanel.shared.hide()
            return
        }
        let marked = NSMutableAttributedString()
        marked.append(NSAttributedString(string: snapshot.selected, attributes: [
            .underlineStyle: NSUnderlineStyle.thick.rawValue,
        ]))
        marked.append(NSAttributedString(string: snapshot.remaining, attributes: [
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]))
        let caret = (snapshot.selected as NSString).length
            + min(snapshot.caret ?? Int.max, (snapshot.remaining as NSString).length)
        textView.setMarkedText(marked, selectedRange: NSRange(location: caret, length: 0), replacementRange: notFound)
        if snapshot.candidates.isEmpty {
            CandidatePanel.shared.hide()
        } else {
            CandidatePanel.shared.show(snapshot, caret: ClientGeometry.caretRect(client))
        }
    }
}
