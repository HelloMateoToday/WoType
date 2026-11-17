//
//  SelectedText.swift
//  WoType
//
//  划词翻译「翻译并显示」用（docs/16）：读当前应用里选中的文字，不要求光标在输入框里（网页正文、PDF 也行）。
//  结果显示在翻译窗口里（TranslationWindow），不跟着选区走，所以不用找选区在屏幕上的位置。
//  照 Easydict（SelectionWorkflow）：先问辅助功能，读不到再模拟 ⌘C。
//  1. Chromium 系浏览器（Chrome、Edge、Arc…）：不碰辅助功能，直接 ⌘C。
//     以前为了取选区位置给它们设 AXManualAccessibility，Chrome 就一直开着完整的辅助功能树，
//     整个浏览器变慢（新标签页尤其卡），连带整台机器都卡（2026-11-17）。**不要再给它们开辅助功能**。
//  2. 别的应用：有焦点的元素的 AXSelectedText。Safari 等的网页正文（AXWebArea）段落之间没有换行
//     （「four.Tickets」），翻出来会连成一句，网页正文用 ⌘C 复制的（段落之间有换行），复制不到再用 AX 的。
//  3. 读不到：光标在输入框里、WoType 正连着它时（Sublime Text 的编辑区），问输入框（IMK）选中了什么
//     （inputField，SelectionTranslation 给）。
//  4. 还读不到：模拟一次 ⌘C，从剪贴板拿，拿完把剪贴板还原。
//

import Cocoa
import Carbon.HIToolbox
import os

@MainActor
enum SelectedText {

    /// inputField：从当前输入框读（辅助功能读不到时用），没有就返回 nil
    static func read(inputField: () -> String?) async -> String? {
        guard AXIsProcessTrusted() else {
            Log.input.info("划词翻译：没有辅助功能权限，读不了选中的文字")
            return inputField()
        }
        if let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, chromiumBrowsers.contains(id) {
            return await fromCopy()
        }
        guard let picked = fromAccessibility() else {
            if let text = inputField() {
                Log.input.info("划词翻译：选中的文字是从输入框读的")
                return text
            }
            return await fromCopy()
        }
        // 网页正文：用复制出来的（段落之间有换行）
        if picked.web, let copied = await fromCopy() { return copied }
        return picked.text
    }

    /// Chromium 系浏览器：直接 ⌘C，不问辅助功能（见文件开头）
    private static let chromiumBrowsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.brave.Browser",
        "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    // MARK: - 辅助功能

    /// 前台应用里有焦点的元素选中的文字；web：选在网页正文里（AXWebArea）
    private static func fromAccessibility() -> (text: String, web: Bool)? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        guard let focused = element(appElement, kAXFocusedUIElementAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(focused, 0.3)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString, &value) == .success,
              let text = value as? String, usable(text) else { return nil }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(focused, kAXRoleAttribute as CFString, &role)
        let web = role as? String == "AXWebArea"
        Log.input.info("划词翻译：选中的文字是辅助功能读到的（\(web ? "网页" : "应用", privacy: .public)）")
        return (text, web)
    }

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    // MARK: - 复制

    /// 模拟 ⌘C，等剪贴板变了取文字，再把原来的剪贴板放回去。最多等 0.5 秒。
    /// 剪贴板「变了」但文字和 ⌘C 之前一模一样，当成没选中文字：没选中时有的应用（Chrome 的对话框里）
    /// 或者剪贴板工具会把原来的内容重新写一遍，不然会把剪贴板里原有的东西当成选中的文字去翻（2026-11-17 实测）。
    /// 选中的文字刚好和剪贴板里原有的一样时也会当成没选中，这种情况很少
    private static func fromCopy() async -> String? {
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        let previous = pasteboard.string(forType: .string)
        let before = pasteboard.changeCount
        pressCopy()
        var text: String?
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(50))
            if pasteboard.changeCount != before {
                text = pasteboard.string(forType: .string)
                break
            }
        }
        guard pasteboard.changeCount != before else {
            Log.input.info("划词翻译：⌘C 以后剪贴板没变（没选中文字，或者这个应用不让复制）")
            return nil
        }
        // 还原剪贴板
        pasteboard.clearContents()
        let items = saved.map { pairs -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in pairs { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
        guard let text, usable(text) else {
            Log.input.info("划词翻译：⌘C 以后剪贴板里没有文字")
            return nil
        }
        guard text != previous else {
            Log.input.info("划词翻译：⌘C 以后剪贴板里还是原来的文字（没选中文字）")
            return nil
        }
        Log.input.info("划词翻译：选中的文字是复制出来的")
        return text
    }

    /// 发一次 ⌘C（按物理键位 C）。只带 ⌘：快捷键的 ⌃⌥ 这时可能还按着，不能让应用收到 ⌃⌥⌘C
    private static func pressCopy() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }

    private static func usable(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
