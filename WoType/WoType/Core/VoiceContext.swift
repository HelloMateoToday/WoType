//
//  VoiceContext.swift
//  WoType
//
//  润色时参考的上下文：光标前后的文字、窗口里看得到的文字、这个 App 最近几次的听写。都只放在内存里，不保存。
//  照 Arion@d2108fe（AGPL-3.0-only）：
//  - packages/core/domain/context.go：RewriteContext 的上限（Bounded）、去掉提示词标记（sanitizeContext）、
//    不读的 App（contextDenied）；
//  - packages/core/application/context.go：最近的听写（History，30 分钟过期）；
//  - apps/desktop/infrastructure/macos/accessibility.m：读窗口里看得到的文字（ax_collect，ObjC 改成 Swift）；
//  - apps/desktop/infrastructure/llm/prompt/selected.go 的 formatInput：上下文放在用户消息里，JSON 编码。
//  和 Arion 不同：光标前后的文字问输入框（IMKTextInput），不用辅助功能。
//

import AppKit
import ApplicationServices
import InputMethodKit

nonisolated struct VoiceContext: Sendable {
    var screen = ""
    var before = ""
    var after = ""
    var history: [String] = []

    // 上限，按 Unicode 字符数（domain/context.go）
    static let maxCursor = 200
    static let maxHistoryItems = 5
    static let maxHistory = 200

    var isEmpty: Bool {
        screen.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && history.isEmpty
    }

    /// 去掉标记、压掉空行，再截到上限：光标前取最后的，光标后取最前的，听写留最近的几条（Bounded）。
    func bounded() -> VoiceContext {
        var out = VoiceContext()
        out.screen = Self.sanitize(screen)
        out.before = Self.tail(Self.sanitize(before), Self.maxCursor)
        out.after = Self.head(Self.sanitize(after), Self.maxCursor)
        out.history = history.map { Self.head(Self.sanitize($0), Self.maxHistory) }.filter { !$0.isEmpty }
        if out.history.count > Self.maxHistoryItems {
            out.history.removeFirst(out.history.count - Self.maxHistoryItems)
        }
        return out
    }

    /// 用户消息（formatInput）：有上下文时在 <source> 前面加 <context>，里面是 JSON（转义了 < > &，
    /// 上下文里的字关不掉标签）。
    func userMessage(source: String) -> String {
        let source = "<source>" + source + "</source>"
        let c = bounded()
        if c.isEmpty { return source }
        var fields: [String] = []
        if !c.screen.isEmpty { fields.append("\"screen\":" + Self.json(c.screen)) }
        if !c.before.isEmpty { fields.append("\"before_cursor\":" + Self.json(c.before)) }
        if !c.after.isEmpty { fields.append("\"after_cursor\":" + Self.json(c.after)) }
        if !c.history.isEmpty { fields.append("\"history\":[" + c.history.map(Self.json).joined(separator: ",") + "]") }
        return "<context>\n{" + fields.joined(separator: ",") + "}\n</context>\n\n" + source
    }

    // MARK: - 规则

    private static let tags = ["<context>", "</context>", "<screen>", "</screen>", "<before_cursor>", "</before_cursor>",
                               "<after_cursor>", "</after_cursor>", "<history>", "</history>", "<dictation>", "</dictation>"]

    static func sanitize(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "<|", with: "").replacingOccurrences(of: "|>", with: "")
        for tag in tags {
            s = s.replacingOccurrences(of: tag, with: "", options: .caseInsensitive)
        }
        return s.components(separatedBy: "\n")
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    static func head(_ s: String, _ n: Int) -> String {
        let scalars = s.unicodeScalars
        guard scalars.count > n else { return s }
        let cut = String(String.UnicodeScalarView(scalars.prefix(n)))
        return String(cut.reversed().drop(while: \.isWhitespace).reversed())
    }

    static func tail(_ s: String, _ n: Int) -> String {
        let scalars = s.unicodeScalars
        guard scalars.count > n else { return s }
        let cut = String(String.UnicodeScalarView(scalars.suffix(n)))
        return String(cut.drop(while: \.isWhitespace))
    }

    /// Go 的 json.Marshal：字符串加引号，转义控制字符、引号、反斜杠和 < > &。
    static func json(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "<": out += "\\u003c"
            case ">": out += "\\u003e"
            case "&": out += "\\u0026"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// 密码管理器、钥匙串：不管哪个框都不读（contextDenied）。
    static func denied(_ app: String?) -> Bool {
        guard let app else { return false }
        return [
            "com.apple.keychainaccess", "com.apple.Passwords", "com.1password.1password", "com.agilebits.onepassword7",
            "com.bitwarden.desktop", "org.keepassxc.keepassxc", "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal",
        ].contains(app)
    }

    // MARK: - 读

    /// 光标前后的文字：问输入框（开始说话时调，那时还没插入）。取的 UTF-16 长度是上限的两倍，截的时候按字符。
    @MainActor
    static func cursor(_ client: IMKTextInput) -> (before: String, after: String) {
        let selection = client.selectedRange()
        guard selection.location != NSNotFound else { return ("", "") }
        let span = maxCursor * 2
        let from = max(0, selection.location - span)
        let before = client.attributedSubstring(from: NSRange(location: from, length: selection.location - from))?.string ?? ""
        let end = selection.location + selection.length
        let total = client.length()
        let after = total > end
            ? client.attributedSubstring(from: NSRange(location: end, length: min(span, total - end)))?.string ?? ""
            : ""
        return (before, after)
    }

    /// 窗口里看得到的文字（accessibility.m 的 arion_accessibility_window）：从焦点所在的窗口往下走，
    /// 只读看得到的文字控件和标签；文本框只读看得到的那段，不读整篇文档；密码框跳过。
    /// 要辅助功能权限；在后台线程调，最多 timeout 秒，超了就不要。
    static func windowText(timeout: TimeInterval = 1.5) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let start = Date()
        let deadline = start.addingTimeInterval(timeout)
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        guard let focused = element(system, kAXFocusedUIElementAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(focused, 0.05)
        guard let window = element(focused, kAXWindowAttribute), let frame = frame(window) else { return nil }
        var walk = Walk(deadline: deadline)
        guard walk.collect(window, clip: frame, depth: 0) else { return nil }
        return walk.lines.isEmpty ? nil : walk.lines.joined(separator: "\n")
    }

    private struct Walk {
        let deadline: Date
        var count = 0
        var length = 0
        var lines: [String] = []

        static let maxNodes = 4096
        static let maxDepth = 64
        static let maxText = 32768

        /// 走完返回 true；超时、太深、太多返回 false（这次不要窗口文字）。
        mutating func collect(_ element: AXUIElement, clip: CGRect, depth: Int) -> Bool {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, depth <= Self.maxDepth else { return false }
            count += 1
            guard count <= Self.maxNodes else { return false }
            AXUIElementSetMessagingTimeout(element, Float(min(0.05, remaining)))
            if VoiceContext.string(element, kAXSubroleAttribute) == kAXSecureTextFieldSubrole { return true }
            if VoiceContext.value(element, "AXHidden") as? Bool == true { return true }
            guard let frame = VoiceContext.frame(element) else { return true }
            let visible = clip.intersection(frame)
            guard !visible.isNull, !visible.isEmpty else { return true }
            let role = VoiceContext.string(element, kAXRoleAttribute)
            var text: String?
            if role == kAXTextAreaRole || role == kAXTextFieldRole || role == kAXComboBoxRole {
                if let rangeValue = VoiceContext.value(element, kAXVisibleCharacterRangeAttribute),
                   CFGetTypeID(rangeValue) == AXValueGetTypeID() {
                    var range = CFRange()
                    guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0
                    else { return false }
                    guard range.length <= Self.maxText - length else { return false }
                    var result: CFTypeRef?
                    AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                               rangeValue, &result)
                    text = result as? String
                }
            } else if role == kAXStaticTextRole {
                // Qt 之类把标签放在 AXTitle 里
                text = VoiceContext.string(element, kAXValueAttribute).flatMap { $0.isEmpty ? nil : $0 }
                    ?? VoiceContext.string(element, kAXTitleAttribute)
            }
            if let text, !text.isEmpty {
                guard length + text.utf16.count <= Self.maxText else { return false }
                lines.append(text)
                length += text.utf16.count
                // 文字控件的内容不再从它的子节点重复读
                return deadline.timeIntervalSinceNow > 0
            }
            guard let children = VoiceContext.value(element, kAXChildrenAttribute) as? [AXUIElement] else { return true }
            for child in children where !collect(child, clip: visible, depth: depth + 1) {
                return false
            }
            return deadline.timeIntervalSinceNow > 0
        }
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let v = value(element, attribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let p = value(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
              let s = value(element, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        let rect = CGRect(origin: point, size: size)
        return rect.isEmpty ? nil : rect
    }
}

/// 最近的听写，按 App 分开，只在内存里；30 分钟过期，每个 App 留最近 5 条（application/context.go 的 History）。
@MainActor
final class VoiceHistory {
    static let shared = VoiceHistory()
    static let ttl: TimeInterval = 30 * 60

    private var items: [String: [(text: String, at: Date)]] = [:]

    func add(_ text: String, place: String?) {
        guard let place, !place.isEmpty, !text.isEmpty else { return }
        var list = items[place, default: []]
        list.append((text, Date()))
        if list.count > VoiceContext.maxHistoryItems { list.removeFirst(list.count - VoiceContext.maxHistoryItems) }
        items[place] = list
    }

    /// 这个 App 没过期的听写，旧的在前。
    func recent(place: String?) -> [String] {
        guard let place, !place.isEmpty else { return [] }
        let kept = items[place, default: []].filter { Date().timeIntervalSince($0.at) <= Self.ttl }
        items[place] = kept.isEmpty ? nil : kept
        return kept.map(\.text)
    }

    func clear() { items = [:] }

    /// 改过的一条（撤销时按它改回去）
    struct Revision {
        let place: String
        let at: Date
        let old: String
        let new: String
    }

    /// 学到了「错误写法 → 正确写法」：最近的听写里也换掉。历史存的是插入时的字，不换的话下次润色参考历史，
    /// 又会把用户改好的词改回去（WoType 加的）。返回改了哪几条。
    @discardableResult
    func revise(from: String, to: String) -> [Revision] {
        var revisions: [Revision] = []
        for (place, list) in items {
            items[place] = list.map { item in
                let text = item.text.replacingOccurrences(of: from, with: to)
                if text != item.text { revisions.append(Revision(place: place, at: item.at, old: item.text, new: text)) }
                return (text, item.at)
            }
        }
        return revisions
    }

    /// 撤销学到的词时：把那几条改回原样（之后没再变过的才改）。
    func restore(_ revisions: [Revision]) {
        for r in revisions {
            guard var list = items[r.place], let i = list.firstIndex(where: { $0.at == r.at && $0.text == r.new }) else { continue }
            list[i].text = r.old
            items[r.place] = list
        }
    }
}
