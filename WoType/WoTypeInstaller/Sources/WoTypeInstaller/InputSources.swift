//
//  InputSources.swift
//  WoType 安装器
//
//  查 WoType 在不在输入法列表里、是不是当前输入法；卸载前把当前输入法从 WoType 切走。
//  注册由 WoType 自己做（WoType --register）；加进输入法列表、切换由用户在系统设置和菜单栏里做（docs/19）。
//
//  卸载时**不停用**（TISDisableInputSource）：停用要改 com.apple.inputsources，第三方进程写不进去
//  （cfprefsd: rejecting write … requires user-preference-write or file-write-data sandbox access），
//  可系统的输入法服务照样收到「停用了」的通知，菜单里把 WoType 拿掉。名单里却还是启用的，
//  重装后 WoType --register 看到「已经启用」什么都不做，菜单里就一直没有它（2026-11-13 实测，docs/19）。
//  代价：卸载后输入法菜单里还留着一项「WoType 拼音」，注销或重启后才消失（结果页告诉用户）；重装后直接是启用的。
//
//  加没加进输入法列表看这份名单，不看 kTISPropertyInputSourceIsEnabled：后者不可靠，
//  用户在系统设置里移除了，它也可能是 true（McBopomofo 安装器也是这么说的）。
//
//  这些都在新起的命令行进程里跑（安装器 --input-sources <命令>，见 Installer.inputSources）：
//  图形界面的进程启动时系统就给它缓存了一份输入法列表，之后装上的 WoType 它看不到。
//  2026-11-13 实测：WoType --register 已经切换成功，安装器进程里切换一直返回 -50、当前输入法也读不到 WoType。
//

import Carbon
import os

nonisolated enum InputSources {

    static let modeID = Installer.bundleID + ".pinyin"

    private static let log = Logger(subsystem: "com.acme.inputmethod.WoTypeInstaller", category: "input-source")

    /// 命令行入口（main.swift）。status 打印「认出 启用 当前」三个 0/1，deselect 打印切没切到 ABC。
    static func perform(_ command: String) -> Int32 {
        switch command {
        case "status":
            let status = status()
            print([status.found, status.enabled, status.selected].map { $0 ? "1" : "0" }.joined(separator: " "))
            return 0
        case "deselect":
            print(deselect() ? "1" : "0")
            return 0
        default:
            return 2
        }
    }

    struct Status: Sendable {
        /// 系统认出 WoType 了（注册过）
        var found: Bool
        /// 拼音模式加进输入法列表了（系统的名单里有）
        var enabled: Bool
        /// 拼音模式是当前输入法
        var selected: Bool
    }

    private static func status() -> Status {
        let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        return Status(found: !sources().isEmpty, enabled: isAdded(), selected: current.map(id(of:)) == modeID)
    }

    /// 系统存的已启用第三方输入法名单（com.apple.inputsources）里有没有拼音模式。
    /// 只有系统设置写得进去（用户点「允许」、手动添加或移除），所以以它为准
    private static func isAdded() -> Bool {
        let domain = "com.apple.inputsources" as CFString
        CFPreferencesAppSynchronize(domain)
        guard let list = CFPreferencesCopyAppValue("AppleEnabledThirdPartyInputSources" as CFString, domain)
                as? [[String: Any]] else { return false }
        return list.contains { $0["Input Mode"] as? String == modeID }
    }

    /// 当前是 WoType 就切到 ABC。返回切没切。
    private static func deselect() -> Bool {
        guard status().selected else { return false }
        let switched = selectKeyboardLayout()
        log.info("切到 ABC：\(switched ? "成功" : "失败", privacy: .public)")
        return switched
    }

    /// 系统的英文键盘（ABC；没有就第一个能选的键盘布局）。
    private static func selectKeyboardLayout() -> Bool {
        let filter = [kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String,
                      kTISPropertyInputSourceIsSelectCapable as String: true] as CFDictionary
        let layouts = (TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource]) ?? []
        guard let layout = layouts.first(where: { id(of: $0) == "com.apple.keylayout.ABC" }) ?? layouts.first else {
            return false
        }
        return TISSelectInputSource(layout) == noErr
    }

    private static func sources() -> [TISInputSource] {
        let filter = [kTISPropertyBundleID as String: Installer.bundleID] as CFDictionary
        return (TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource]) ?? []
    }

    private static func id(of source: TISInputSource) -> String {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "" }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }
}
