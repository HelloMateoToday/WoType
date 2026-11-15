//
//  KeyCap+WoType.swift
//  WoType
//
//  键帽里只有 WoType 用的部分（KeyCap.swift 安装器也编，那边没有 VoiceKey 和 KeyboardShortcuts）。
//

import Cocoa
import KeyboardShortcuts

extension KeyCap {
    /// 语音键对应的键帽（右 ⌥、右 ⌘ 画的是 option、command，「右侧」由调用方另外写）
    static func voiceKey(_ key: VoiceKey) -> KeyCap {
        switch key {
        case .fn: .fn
        case .rightOption: .option
        case .rightCommand: .command
        }
    }
}

extension KeyCaps {
    /// 快捷键 → 键帽：⌃⌥T → [control, option, T]。用户在设置里改过的也对。
    static func keys(for shortcut: KeyboardShortcuts.Shortcut?) -> [KeyCap] {
        guard let shortcut else { return [] }
        var keys: [KeyCap] = []
        let flags = shortcut.modifiers
        if flags.contains(.control) { keys.append(.control) }
        if flags.contains(.option) { keys.append(.option) }
        if flags.contains(.shift) { keys.append(.shift) }
        if flags.contains(.command) { keys.append(.command) }
        let rest = shortcut.description.filter { !"⌃⌥⇧⌘".contains($0) }
        if !rest.isEmpty { keys.append(KeyCap(token: rest) ?? .character(rest)) }
        return keys
    }

    /// 快捷键在 text 模板里的写法：{control+option+T}
    static func token(for shortcut: KeyboardShortcuts.Shortcut?) -> String {
        let keys = keys(for: shortcut)
        guard !keys.isEmpty else { return "" }
        return "{" + keys.map { $0.name ?? $0.symbol }.joined(separator: "+") + "}"
    }
}
