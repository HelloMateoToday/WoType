//
//  KeyMapper.swift
//  WoType
//
//  NSEvent → 会话的按键码和修饰键位（wotype_core.h 的 WOTYPE_KEY_* / WOTYPE_MOD_*）。
//  功能键按物理键码映射；可打印字符取事件里的字符（底层布局已固定成 ABC）。
//

import Cocoa
import Carbon.HIToolbox

nonisolated enum KeyMapper {

    struct Mapped: Equatable {
        let key: UInt32
        let modifiers: UInt32
    }

    private static let functionKeys: [Int: UInt32] = [
        kVK_Delete: UInt32(WOTYPE_KEY_BACKSPACE),
        kVK_Return: UInt32(WOTYPE_KEY_RETURN),
        kVK_ANSI_KeypadEnter: UInt32(WOTYPE_KEY_RETURN),
        kVK_Escape: UInt32(WOTYPE_KEY_ESCAPE),
        kVK_Tab: UInt32(WOTYPE_KEY_TAB),
        kVK_ForwardDelete: UInt32(WOTYPE_KEY_DELETE),
        kVK_LeftArrow: UInt32(WOTYPE_KEY_LEFT),
        kVK_RightArrow: UInt32(WOTYPE_KEY_RIGHT),
        kVK_UpArrow: UInt32(WOTYPE_KEY_UP),
        kVK_DownArrow: UInt32(WOTYPE_KEY_DOWN),
        kVK_PageUp: UInt32(WOTYPE_KEY_PAGE_UP),
        kVK_PageDown: UInt32(WOTYPE_KEY_PAGE_DOWN),
        kVK_Home: UInt32(WOTYPE_KEY_HOME),
        kVK_End: UInt32(WOTYPE_KEY_END),
        kVK_Space: 0x20,
    ]

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.shift) { mods |= UInt32(WOTYPE_MOD_SHIFT) }
        if flags.contains(.control) { mods |= UInt32(WOTYPE_MOD_CONTROL) }
        if flags.contains(.option) { mods |= UInt32(WOTYPE_MOD_OPTION) }
        if flags.contains(.command) { mods |= UInt32(WOTYPE_MOD_COMMAND) }
        if flags.contains(.capsLock) { mods |= UInt32(WOTYPE_MOD_CAPSLOCK) }
        return mods
    }

    /// 按下的键；认不出的（F1 等）返回 nil，交还给应用。
    static func map(keyCode: UInt16, characters: String?, charactersIgnoringModifiers: String?,
                    flags: NSEvent.ModifierFlags) -> Mapped? {
        let mods = modifiers(flags)
        if let key = functionKeys[Int(keyCode)] {
            return Mapped(key: key, modifiers: mods)
        }
        // 没有 ⌃⌥⌘ 时用实际打出的字符（带上 Shift 和大写锁定），否则用不带修饰键的字符
        let plain = flags.isDisjoint(with: [.control, .option, .command])
        guard let scalar = (plain ? characters : charactersIgnoringModifiers)?.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar),
              // 方向键等功能键的字符落在 Unicode 私用区
              !(0xF700...0xF8FF).contains(scalar.value) else {
            return nil
        }
        return Mapped(key: scalar.value, modifiers: mods)
    }

    static func map(_ event: NSEvent) -> Mapped? {
        map(keyCode: event.keyCode, characters: event.characters,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers, flags: event.modifierFlags)
    }
}
