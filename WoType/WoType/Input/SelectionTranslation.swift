//
//  SelectionTranslation.swift
//  WoType
//
//  划词翻译（docs/16），两个功能分开开关，WoType 是当前输入法时才生效：
//  - 翻译并替换（默认 ⌃⌥I）：只在输入框里。选中了就翻选中的，没选中就翻整个输入框，翻完换成译文。
//    按键在 InputController.handle 里比对。读输入框先问 IMK（选区、全文），读不到再问辅助功能（AX）；
//    写回之前再读一遍，内容变了就不替换，改成气泡显示译文。
//  - 翻译并显示（默认 ⌃⌥T）：任何地方选中的文字（网页、PDF 也行），结果显示在带小三角的气泡里（TranslationPanel）。
//    光标不在输入框里时输入法收不到按键，所以它用 KeyboardShortcuts 注册的全局热键，
//    只在开关开着、WoType 是当前输入法时注册（切到别的输入法就取消，按键还给应用）。
//    选中的文字先问辅助功能，读不到再模拟 ⌘C 从剪贴板拿（拿完把剪贴板还原）。
//  翻译中在选中文字下面转圈（ModeToast，和中英切换提示同一个方块）。
//
//  KeyboardShortcuts 2.4.0 存快捷键时（包括第一次用到名字时存默认值）就会注册 Carbon 全局热键，
//  所以每次存完都要 shortcutsChanged()：翻译并替换的取消注册（不然按键到不了输入法），翻译并显示的按上面的规矩重新定。
//

import Cocoa
import Carbon.HIToolbox
import FreeTranslate
import InputMethodKit
import KeyboardShortcuts
import os

extension KeyboardShortcuts.Name {
    /// 翻译并替换（⌃⌥ 很少被应用占用）
    static let translateReplace = Self("selectionTranslateReplace", default: .init(.i, modifiers: [.control, .option]))
    /// 翻译并显示
    static let translateShow = Self("selectionTranslateShow", default: .init(.t, modifiers: [.control, .option]))

}

@MainActor
final class SelectionTranslation {

    static let shared = SelectionTranslation()

    /// 从输入框读到的一段
    struct Grab: Equatable {
        enum Source {
            /// IMK：range 是在输入框里的范围
            case client
            /// 辅助功能读到的选中文字（替换时直接上屏，应用会换掉选区）
            case axSelection
            /// 辅助功能读到的整个输入框（替换前先把它全选上）
            case axValue
        }
        let text: String
        let range: NSRange
        let selected: Bool
        let source: Source
    }

    private var task: Task<Void, Never>?

    private init() {
        // 第一次用到名字时库会存默认值、顺手注册全局热键
        KeyboardShortcuts.disable(.translateReplace, .translateShow)
    }

    /// 输入法启动时调：挂上翻译并显示的全局热键，跟着输入法切换、设置变化注册 / 取消
    func start() {
        KeyboardShortcuts.onKeyDown(for: .translateShow) { [weak self] in self?.translateAndShowAnywhere() }
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateShowHotKey() }
        }
        NotificationCenter.default.addObserver(forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateShowHotKey() }
        }
        // 浏览器启动、切到前台时打开它的辅助功能（翻译并显示开着才做），之后加载的网页才能拿到选中文字的位置
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didActivateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                MainActor.assumeIsolated {
                    guard Settings.shared.config.selectionShow, AXIsProcessTrusted() else { return }
                    SelectedText.enableAccessibility(app)
                }
            }
        }
        updateShowHotKey()
    }

    /// 设置页录了快捷键以后调（库存的时候注册了全局热键）
    func shortcutsChanged() {
        KeyboardShortcuts.disable(.translateReplace)
        updateShowHotKey()
    }

    /// 翻译并显示的全局热键：开关开着、WoType 是当前输入法才注册
    private func updateShowHotKey() {
        let on = Settings.shared.config.selectionShow && Self.woTypeSelected()
        if on {
            KeyboardShortcuts.enable(.translateShow)
            SelectedText.enableBrowsers()
        } else {
            KeyboardShortcuts.disable(.translateShow)
        }
        Log.input.info("划词翻译：翻译并显示的快捷键\(on ? "注册" : "取消", privacy: .public)（\(KeyboardShortcuts.getShortcut(for: .translateShow)?.description ?? "没设", privacy: .public)）")
    }

    private static func woTypeSelected() -> Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return false }
        let id = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        return id.hasPrefix(InputSource.bundleID)
    }

    // MARK: - 按键

    /// InputController.handle 里每个按下的键先给这里。返回 true 是吃掉了。
    /// composing：正在打拼音（候选窗开着），这时快捷键不响应
    func handle(_ event: NSEvent, client: IMKTextInput, composing: Bool) -> Bool {
        let showing = TranslationPanel.shared.isVisible || ModeToast.shared.isLoading
        if showing, event.keyCode == UInt16(kVK_Escape) {
            close()
            return true
        }
        let shortcut = KeyboardShortcuts.Shortcut(event: event)
        if !event.modifierFlags.isDisjoint(with: [.command, .control, .option]) {
            Log.input.debug("划词翻译：收到组合键 \(shortcut?.description ?? "?", privacy: .public)")
        }
        // 翻译并显示走全局热键（start），到不了这里
        if Settings.shared.config.selectionReplace, !composing, let shortcut,
           shortcut == KeyboardShortcuts.getShortcut(for: .translateReplace) {
            return translateAndReplace(client)
        }
        // 按了别的键：收起结果气泡，键照常处理（还在翻的照样翻完）
        TranslationPanel.shared.hide()
        return false
    }

    /// 换了输入框：收起结果气泡（翻译并替换还在翻的，回来时会发现输入框变了，改成气泡显示）
    func focusLost() {
        TranslationPanel.shared.hide()
    }

    /// Esc：不翻了，转圈和气泡都收起
    private func close() {
        task?.cancel()
        task = nil
        ModeToast.shared.hideLoading()
        TranslationPanel.shared.hide()
    }

    // MARK: - 翻译并替换

    private func translateAndReplace(_ client: IMKTextInput) -> Bool {
        if let grab = Self.grab(client, whole: true) {
            replace(grab, client: client)
            return true
        }
        // 读不到整个输入框（Sublime Text 等：IMK 给的长度是 0，辅助功能也读不到内容）：
        // 替用户按一下 ⌘A 全选，等应用选好了再按「选中」的流程翻译、替换
        guard AXIsProcessTrusted() else {
            Log.input.info("划词翻译：没读到输入框的内容，也没有辅助功能权限，按键还给应用")
            return false
        }
        Log.input.info("划词翻译：读不到整个输入框，先全选再读")
        Self.pressSelectAll()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            if let grab = Self.grab(client, whole: false) {
                self?.replace(grab, client: client)
            } else {
                Log.input.info("划词翻译：全选以后还是读不到")
                TranslationPanel.shared.showMessage("这个应用里读不到文字，请先选中再翻译", near: ClientGeometry.caretRect(client))
            }
        }
        return true
    }

    /// 发一次 ⌘A（按物理键位 A，Dvorak 等布局下也一样）
    private static func pressSelectAll() {
        pressKey(kVK_ANSI_A, flags: .maskCommand)
    }

    /// 发一次按键（按下、松开）。flags 明确写上：快捷键的 ⌃⌥ 这时可能还按着，不能带给应用
    private static func pressKey(_ key: Int, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    /// 转圈 → 翻好了换成译文；等的时候改了字、换了输入框就不替换，译文放进气泡（不白翻）；失败气泡里写原因
    private func replace(_ grab: Grab, client: IMKTextInput) {
        let anchor = Self.anchor(client, grab)
        translate(grab.text, near: anchor) { result in
            if Self.write(result.text, over: grab, client: client) {
                ModeToast.shared.hideLoading()
            } else {
                ModeToast.shared.hideLoading(animated: false)
                TranslationPanel.shared.show(result.text, note: "输入框的内容变了，没有替换", near: anchor)
            }
        }
    }

    // MARK: - 翻译并显示

    /// 全局热键：读当前应用里选中的文字 → 转圈 → 翻好了在气泡里显示译文
    private func translateAndShowAnywhere() {
        Log.input.info("划词翻译：翻译并显示的快捷键按下了")
        guard Settings.shared.config.selectionShow else { return }
        Task {
            guard let picked = await SelectedText.read(inputField: Self.pickFromInputField) else {
                Log.input.info("划词翻译：没读到选中的文字")
                TranslationPanel.shared.showMessage("没有选中文字", near: SelectedText.mouseAnchor())
                return
            }
            translate(picked.text, near: picked.anchor) { result in
                ModeToast.shared.hideLoading(animated: false)
                TranslationPanel.shared.show(result.text, near: picked.anchor)
            }
        }
    }

    /// 翻译并显示：光标在前台应用的输入框里、WoType 正连着它、里面选着文字时，从输入框读文字和位置
    /// （Sublime Text 辅助功能什么都不给，只能这样拿到选区的位置）
    private static func pickFromInputField() -> SelectedText.Picked? {
        guard let client = InputController.current?.client() else {
            Log.input.info("划词翻译：没有连着的输入框")
            return nil
        }
        let app = client.bundleIdentifier()
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard app == front else {
            Log.input.info("划词翻译：连着的输入框在 \(app ?? "?", privacy: .public)，前台是 \(front ?? "?", privacy: .public)")
            return nil
        }
        guard let grab = grab(client, whole: false) else {
            Log.input.info("划词翻译：输入框里没读到选中的文字（选区 \(String(describing: client.selectedRange()), privacy: .public)）")
            return nil
        }
        return SelectedText.Picked(text: grab.text, anchor: anchor(client, grab))
    }

    /// 两种都一样的部分：收起上一次的，在 anchor 下面转圈，翻好了交给 done（由它收起转圈），失败了气泡里写原因
    private func translate(_ text: String, near anchor: NSRect, done: @escaping (SelectionTranslator.Result) -> Void) {
        close()
        let target = Self.target(for: text)
        ModeToast.shared.showLoading(near: anchor)
        task = Task {
            do {
                let result = try await SelectionTranslator.shared.translate(text, to: target)
                guard !Task.isCancelled else { return }
                done(result)
            } catch {
                guard !Task.isCancelled else { return }
                ModeToast.shared.hideLoading(animated: false)
                TranslationPanel.shared.showMessage(Self.message(error), near: anchor)
            }
        }
    }

    private static func target(for text: String) -> Language {
        let config = Settings.shared.config
        return SelectionTranslator.direction(for: text, target: Language(config.selectionTarget),
                                             smart: config.selectionSmartDirection)
    }

    private static func message(_ error: Error) -> String {
        (error as? SelectionTranslator.Failure)?.message ?? "翻译失败"
    }

    // MARK: - 读输入框

    /// 读要翻的文字：IMK 的选区 → 辅助功能的选区 → （whole 时）IMK 的全文 → 辅助功能的全文。
    /// 先把两种选区都问过，免得 IMK 说没选中（Electron 等）却其实选着，把整个输入框换掉。
    static func grab(_ client: IMKTextInput, whole: Bool) -> Grab? {
        let selection = client.selectedRange()
        if selection.location != NSNotFound, selection.length > 0,
           let text = client.attributedSubstring(from: selection)?.string, usable(text) {
            return Grab(text: text, range: selection, selected: true, source: .client)
        }
        let element = AX.focusedElement()
        if let element, let text = AX.string(element, kAXSelectedTextAttribute), usable(text) {
            return Grab(text: text, range: AX.selectedRange(element) ?? NSRange(location: 0, length: 0),
                        selected: true, source: .axSelection)
        }
        guard whole else { return nil }
        let length = client.length()
        Log.input.debug("划词翻译：选区 \(String(describing: selection), privacy: .public) 长度 \(length) 有辅助功能元素 \(element != nil)")
        if length > 0, length != NSNotFound,
           let text = client.attributedSubstring(from: NSRange(location: 0, length: length))?.string, usable(text) {
            return Grab(text: text, range: NSRange(location: 0, length: length), selected: false, source: .client)
        }
        if let element, let text = AX.string(element, kAXValueAttribute), usable(text) {
            return Grab(text: text, range: NSRange(location: 0, length: (text as NSString).length), selected: false, source: .axValue)
        }
        return nil
    }

    private static func usable(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 转圈、气泡放在哪：选中文字的那一行。横向用选区的矩形（firstRect），上下用选区开头那一行的行高矩形——
    /// TextEdit 给的 firstRect 底边不到行底，按它放会压住文字。拿不到就用光标的
    private static func anchor(_ client: IMKTextInput, _ grab: Grab) -> NSRect {
        func onScreen(_ rect: NSRect) -> Bool {
            rect.origin != .zero && NSScreen.screens.contains { $0.frame.intersects(rect.insetBy(dx: -1, dy: -1)) }
        }
        if grab.source == .client, grab.selected {
            let rect = client.firstRect(forCharacterRange: grab.range, actualRange: nil)
            var line = NSRect.zero
            client.attributes(forCharacterIndex: grab.range.location, lineHeightRectangle: &line)
            switch (onScreen(rect), onScreen(line)) {
            case (true, true):
                return NSRect(x: rect.minX, y: min(rect.minY, line.minY), width: rect.width,
                              height: max(rect.maxY, line.maxY) - min(rect.minY, line.minY))
            case (true, false): return rect
            case (false, true): return line
            case (false, false): break
            }
        }
        return ClientGeometry.caretRect(client)
    }

    // MARK: - 写回

    /// 用译文换掉读到的那段。输入框换了、内容变了就不换，返回 false。
    static func write(_ text: String, over grab: Grab, client: IMKTextInput) -> Bool {
        guard let live = InputController.current?.client(), (live as AnyObject) === (client as AnyObject),
              let now = Self.grab(client, whole: !grab.selected), now == grab else {
            Log.input.info("划词翻译：输入框变了，不替换")
            return false
        }
        switch grab.source {
        case .client:
            client.insertText(text, replacementRange: grab.range)
        case .axSelection:
            // 和打字一样，上屏会换掉选中的文字
            client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        case .axValue:
            guard let element = AX.focusedElement(), AX.select(element, grab.range) else { return false }
            client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        // Sublime Text 换掉选区以后把译文保持选中：还选着就替用户按一下 →，光标放到译文后面（IMK 没有设选区的接口）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let selection = client.selectedRange()
            guard selection.location != NSNotFound, selection.length > 0 else { return }
            Log.input.info("划词翻译：替换后译文还选着，按 → 取消选中")
            pressKey(kVK_RightArrow)
        }
        return true
    }
}

// MARK: - 辅助功能

private enum AX {

    static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.3)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.3)
        return element
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func selectedRange(_ element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    /// 选中这一段
    static func select(_ element: AXUIElement, _ range: NSRange) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }
}
