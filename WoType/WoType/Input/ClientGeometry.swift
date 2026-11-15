//
//  ClientGeometry.swift
//  WoType
//
//  跟应用打交道的几件小事：光标在屏幕上的位置、当前是不是在输密码、光标前的文字。
//

import Cocoa
import Carbon
import InputMethodKit

enum ClientGeometry {

    /// 上一次取到的有效光标位置，和它属于哪个应用。
    private static var lastCaret: (app: String, rect: NSRect)?

    /// 编辑区开头的矩形（屏幕坐标）。有的应用给 (0,0) 或空矩形：同一个应用里用上一次的，
    /// 换了应用就用鼠标位置（别把候选窗画到别的应用那边去）。
    static func caretRect(_ client: IMKTextInput) -> NSRect {
        var rect = NSRect.zero
        client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        let app = client.bundleIdentifier() ?? ""
        let onScreen = NSScreen.screens.contains { $0.frame.intersects(rect.insetBy(dx: -1, dy: -1)) }
        if rect.origin != .zero, onScreen {
            lastCaret = (app, rect)
            return rect
        }
        if let lastCaret, lastCaret.app == app {
            return lastCaret.rect
        }
        let mouse = NSEvent.mouseLocation
        return NSRect(x: mouse.x, y: mouse.y - 18, width: 1, height: 18)
    }

    /// 光标前最多 count 个字（UTF-16 单位），读不到返回 nil。
    /// 有编辑区时从编辑区开头往前读：编辑区里的拼音、补上的后半个符号不算已经写进去的字。
    static func textBeforeCaret(_ client: IMKTextInput, count: Int = 8) -> String? {
        let marked = client.markedRange()
        let selection = marked.location != NSNotFound && marked.length > 0 ? marked : client.selectedRange()
        guard selection.location != NSNotFound else { return nil }
        // 光标在最前面：前面确实没有字
        guard selection.location > 0 else { return "" }
        let length = min(count, selection.location)
        let range = NSRange(location: selection.location - length, length: length)
        return client.attributedSubstring(from: range)?.string
    }
}

enum SecureInput {

    /// 当前应用是不是正在输密码（打开了安全输入）。
    ///
    /// 有的应用开了安全输入却不关，所以不能只看 IsSecureEventInputEnabled：
    /// 还要看开启它的进程是不是前台应用，不是的话照常输入。
    static func isActive() -> Bool {
        guard IsSecureEventInputEnabled() else { return false }
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let pid = session["kCGSSessionSecureInputPID"] as? Int32 else {
            return true
        }
        return pid == NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
}
