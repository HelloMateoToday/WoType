//
//  SelectedText.swift
//  WoType
//
//  划词翻译「翻译并显示」用（docs/16）：读当前应用里选中的文字和它在屏幕上的位置，不要求光标在输入框里
//  （网页正文、PDF 也行）。
//  1. 辅助功能：前台应用里有焦点的元素的 AXSelectedText，位置用 AXBoundsForRange。
//     Chrome、Electron 默认不开辅助功能树，先给应用设一下 AXManualAccessibility（Chromium 认这个）。
//     Chrome 网页正文（AXWebArea）对整个选区只给 0×0 的位置，但下面每一段文字（AXStaticText）
//     能按段内的字取位置：找到选区落在哪段、段内第几个字，再取那一截的位置（webBounds）。
//     按字取位置只对「打开辅助功能以后才加载的网页」有效（之前加载的只给 0×0），所以翻译并显示开着时
//     提前给浏览器打开（enableBrowsers）；之前加载的网页退一步用那一段的外框。
//     网页正文的 AXSelectedText 段落之间没有换行（「four.Tickets」），翻出来会连成一句，
//     所以网页正文的文字用 ⌘C 复制的（段落之间有换行），AX 的只拿来找位置。
//  2. 读不到：光标在输入框里、WoType 正连着它时（Sublime Text 的编辑区），问输入框（IMK）选中了什么、在哪
//     （inputField，SelectionTranslation 给）。
//  3. 还读不到：模拟一次 ⌘C，从剪贴板拿，拿完把剪贴板还原。这时位置用鼠标的（选完文字鼠标一般就停在选区旁边）。
//

import Cocoa
import Carbon.HIToolbox
import os

@MainActor
enum SelectedText {

    struct Picked {
        let text: String
        /// 转圈、气泡放在它下面（屏幕坐标，左下角原点）
        let anchor: NSRect
        /// 选在网页正文里（AXWebArea）
        var web = false
    }

    /// inputField：从当前输入框读（辅助功能读不到时用），没有就返回 nil
    static func read(inputField: () -> Picked?) async -> Picked? {
        guard AXIsProcessTrusted() else {
            Log.input.info("划词翻译：没有辅助功能权限，读不了选中的文字")
            return inputField()
        }
        guard let picked = fromAccessibility() else {
            if let picked = inputField() {
                Log.input.info("划词翻译：选中的文字是从输入框读的")
                return picked
            }
            return await fromCopy()
        }
        // 网页正文：文字换成复制出来的（段落之间有换行），位置还用 AX 找到的
        if picked.web, let copied = await fromCopy() {
            return Picked(text: copied.text, anchor: picked.anchor)
        }
        return picked
    }

    /// Chromium 系浏览器：默认不开辅助功能树，设 AXManualAccessibility 打开。
    /// 只对浏览器做：VS Code 等 Electron 应用发现辅助功能打开了会切成读屏优化模式
    private static let chromiumBrowsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.brave.Browser",
        "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    static func enableAccessibility(_ app: NSRunningApplication) {
        guard let id = app.bundleIdentifier, chromiumBrowsers.contains(id) else { return }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.3)
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// 给正在运行的浏览器都打开辅助功能（翻译并显示打开时、WoType 启动时）。之后加载的网页才能按字取位置
    static func enableBrowsers() {
        guard AXIsProcessTrusted() else { return }
        NSWorkspace.shared.runningApplications.forEach(enableAccessibility)
    }

    /// 鼠标位置当成一个小矩形（读不到选区位置时用）
    static func mouseAnchor() -> NSRect {
        let mouse = NSEvent.mouseLocation
        return NSRect(x: mouse.x - 1, y: mouse.y - 10, width: 2, height: 20)
    }

    // MARK: - 辅助功能

    private static func fromAccessibility() -> Picked? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        enableAccessibility(app)
        guard let focused = element(appElement, kAXFocusedUIElementAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(focused, 0.3)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString, &value) == .success,
              let text = value as? String, usable(text) else { return nil }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(focused, kAXRoleAttribute as CFString, &role)
        let web = role as? String == "AXWebArea"
        let rect = bounds(of: focused) ?? webBounds(in: appElement, root: focused, selected: text)
        Log.input.info("划词翻译：选中的文字是辅助功能读到的（\(web ? "网页" : "应用", privacy: .public)），\(rect == nil ? "位置读不到，用鼠标的" : "有位置", privacy: .public)")
        return Picked(text: text, anchor: rect ?? mouseAnchor(), web: web)
    }

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// 选区在屏幕上的矩形（AX 给的是左上角原点，换成 AppKit 的左下角原点）。拿不到、不在屏幕上返回 nil。
    /// 输入框用 AXSelectedTextRange + AXBoundsForRange；网页正文（Chrome、Safari）没有这个，
    /// 用 AXSelectedTextMarkerRange + AXBoundsForTextMarkerRange
    private static func bounds(of element: AXUIElement) -> NSRect? {
        let pairs = [(kAXSelectedTextRangeAttribute, kAXBoundsForRangeParameterizedAttribute),
                     ("AXSelectedTextMarkerRange", "AXBoundsForTextMarkerRange")]
        for (rangeAttribute, boundsAttribute) in pairs {
            if let rect = bounds(of: element, range: rangeAttribute, bounds: boundsAttribute) { return rect }
        }
        return nil
    }

    private static func bounds(of element: AXUIElement, range rangeAttribute: String, bounds boundsAttribute: String) -> NSRect? {
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, rangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue else { return nil }
        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, boundsAttribute as CFString,
                                                         rangeValue, &boundsValue) == .success,
              let boundsValue, CFGetTypeID(boundsValue) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect), rect.width > 0, rect.height > 0 else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let flipped = NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
        guard NSScreen.screens.contains(where: { $0.frame.intersects(flipped) }) else { return nil }
        return flipped
    }

    // MARK: - 网页正文的位置

    /// 选中的文字落在哪段 AXStaticText 里、段内第几个字，取那一截的位置。
    /// 先看鼠标下面那段（刚用鼠标选完，鼠标一般就停在选区上），整段包含选区就是它；
    /// 不然从网页开头找最多 400 个元素，选区跨段时把开头那截和结尾那截合起来（气泡放在整个选区下面）；
    /// 网页太长找不到，就用鼠标下面那段里属于选区的那一截
    private static func webBounds(in app: AXUIElement, root: AXUIElement, selected: String) -> NSRect? {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let mouse = NSEvent.mouseLocation
        var partial: NSRect?
        var hit: AXUIElement?
        if AXUIElementCopyElementAtPosition(app, Float(mouse.x), Float(primaryHeight - mouse.y), &hit) == .success, let hit {
            for leaf in staticTexts(under: hit, limit: 20) {
                guard let (rect, part) = bounds(of: selected, in: leaf) else { continue }
                if part == .whole { return rect }
                partial = partial ?? rect
            }
        }
        var start: NSRect?, end: NSRect?
        for leaf in staticTexts(under: root, limit: 400) {
            guard let (rect, part) = bounds(of: selected, in: leaf) else { continue }
            switch part {
            case .whole: return rect
            case .start: if start == nil { start = rect }
            case .end: if start != nil { end = rect }
            }
            if start != nil, end != nil { break }
        }
        switch (start, end) {
        case let (start?, end?): return start.union(end)
        case let (start?, nil): return start
        default: return partial
        }
    }

    /// 一段文字里属于选区的是哪一截
    private enum Part { case whole, start, end }

    /// element 自己是 AXStaticText 就是它，否则往下找（广度优先，最多看 limit 个元素）
    private static func staticTexts(under element: AXUIElement, limit: Int) -> [AXUIElement] {
        var queue = [element], found: [AXUIElement] = [], seen = 0
        while !queue.isEmpty, seen < limit {
            let current = queue.removeFirst()
            seen += 1
            AXUIElementSetMessagingTimeout(current, 0.1)
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &role)
            if role as? String == kAXStaticTextRole {
                found.append(current)
                continue
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(current, kAXChildrenAttribute as CFString, &children) == .success,
               let children = children as? [AXUIElement] {
                queue += children
            }
        }
        return found
    }

    /// 选区在这段文字里的那一截的位置：整段包含选区（whole）；或者选区从这段中间开始，这段的结尾是选区的开头（start）；
    /// 或者选区在这段中间结束，这段的开头是选区的结尾（end）
    private static func bounds(of selected: String, in leaf: AXUIElement) -> (NSRect, Part)? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(leaf, kAXValueAttribute as CFString, &value) == .success,
              let leafText = value as? String, !leafText.isEmpty else { return nil }
        let leafString = leafText as NSString
        let target = selected.trimmingCharacters(in: .whitespacesAndNewlines) as NSString
        var range = leafString.range(of: target as String)
        var part = Part.whole
        if range.location == NSNotFound {
            // 选区跨段（网页的选中文字段落之间可能没有分隔，不能按换行切）：
            // 这段的结尾和选区的开头重合（start），或者这段的开头和选区的结尾重合（end）。至少重合 3 个字才算
            let trimmed = leafText.trimmingCharacters(in: .whitespacesAndNewlines) as NSString
            let offset = leafString.range(of: trimmed as String).location
            if let length = overlap(suffixOf: trimmed as String, prefixOf: target as String) {
                range = NSRange(location: offset + trimmed.length - length, length: length)
                part = .start
            } else if let length = overlap(suffixOf: target as String, prefixOf: trimmed as String) {
                range = NSRange(location: offset, length: length)
                part = .end
            }
        }
        guard range.location != NSNotFound, range.length > 0 else { return nil }
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(leaf, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         rangeValue, &boundsValue) == .success,
              let boundsValue, CFGetTypeID(boundsValue) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        if !AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect) || rect.width <= 0 || rect.height <= 0 {
            // 打开辅助功能之前加载的网页按字只给 0×0：退一步用这一段的外框
            var frameValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(leaf, "AXFrame" as CFString, &frameValue) == .success, let frameValue,
                  CFGetTypeID(frameValue) == AXValueGetTypeID(),
                  AXValueGetValue(frameValue as! AXValue, .cgRect, &rect), rect.width > 0, rect.height > 0 else { return nil }
            Log.input.info("划词翻译：这个网页按字取不到位置（打开辅助功能之前加载的），用那一段的外框")
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let flipped = NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
        return NSScreen.screens.contains(where: { $0.frame.intersects(flipped) }) ? (flipped, part) : nil
    }

    /// a 的结尾和 b 的开头最多重合多少个（UTF-16）字，不到 3 个算没有
    private static func overlap(suffixOf a: String, prefixOf b: String) -> Int? {
        let a = a as NSString, b = b as NSString
        let longest = min(a.length, b.length)
        guard longest >= 3 else { return nil }
        for length in stride(from: longest, through: 3, by: -1)
        where a.substring(from: a.length - length) == b.substring(to: length) {
            return length
        }
        return nil
    }

    // MARK: - 复制

    /// 模拟 ⌘C，等剪贴板变了取文字，再把原来的剪贴板放回去。最多等 0.5 秒
    private static func fromCopy() async -> Picked? {
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
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
        Log.input.info("划词翻译：选中的文字是复制出来的")
        return Picked(text: text, anchor: mouseAnchor())
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
