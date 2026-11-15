//
//  InputSource.swift
//  WoType
//
//  把 WoType 注册到系统；查它加进输入法列表没有、是不是当前输入法。
//
//    WoType.app/Contents/MacOS/WoType --register [--select]
//
//  只注册（让系统认得新装的这一份），**不启用、不停用**：加进输入法列表由用户在系统设置里做，
//  安装器装完打开新手引导，照着教程添加（docs/19）。macOS 12 起第三方程序本来也做不了（2026-11-13 实测）：
//  - TISEnableInputSource 会打开「系统设置 › 键盘」，弹「允许"WoType"启用"WoType 拼音"？」，用户点了才算；
//  - TISDisableInputSource 写名单会被拒绝，可系统的输入法服务照样当它停用了，菜单里就没有 WoType，
//    名单里却还是启用的，以后谁也补不回来。**不要调用**；
//  - kTISPropertyInputSourceIsEnabled 不可靠（用户移除了也可能是 true）。加没加进列表看名单（isPersisted）。
//  同一次登录里删掉又重新装上的输入法，系统设置可能认不出来（列表里找不到），要注销重新登录。
//

import Carbon
import Foundation

nonisolated enum InputSource {

    static let bundleID = "com.acme.inputmethod.WoType"
    static let modeID = bundleID + ".pinyin"

    /// 注册；select 时，已经加进输入法列表的话切换过去（开发脚本用）。返回进程退出码。
    static func register(bundleURL: URL, select: Bool) -> Int32 {
        let status = TISRegisterInputSource(bundleURL as CFURL)
        guard status == noErr else {
            print("注册失败：OSStatus \(status)")
            return 1
        }
        guard let mode = sources().first(where: { id(of: $0) == modeID }) else {
            print("系统里还找不到 \(bundleID)；第一次安装有时要注销重新登录才会出现")
            return 1
        }
        guard isPersisted(modeID) else {
            print("已注册，还没加进输入法列表：到「系统设置 › 键盘 › 输入法」添加 WoType")
            return 0
        }
        print("已注册，已经在输入法列表里")
        if select {
            let result = TISSelectInputSource(mode)
            print("切换到 \(modeID)：\(result == noErr ? "成功" : "失败 \(result)")")
        }
        return 0
    }

    /// 拼音模式加进输入法列表没有（看系统的名单）、是不是当前的输入法（新手引导用）。
    static func status() -> (enabled: Bool, selected: Bool) {
        let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        return (isPersisted(modeID), current.map(id(of:)) == modeID)
    }

    /// 切到 WoType 的拼音模式（新手引导试用完切回来）。
    @discardableResult
    static func selectWoType() -> Bool {
        guard let mode = sources().first(where: { id(of: $0) == modeID }) else { return false }
        return TISSelectInputSource(mode) == noErr
    }

    /// 临时切到系统的英文键盘（ABC；没有就第一个能选的键盘布局）：新手引导试用时，
    /// 装好的 WoType 不是当前输入法，就不会和引导窗口抢同一个按键（语音键、⌃⌥T）。
    @discardableResult
    static func selectKeyboardLayout() -> Bool {
        let filter = [kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String,
                      kTISPropertyInputSourceIsSelectCapable as String: true] as CFDictionary
        let layouts = (TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource]) ?? []
        guard let layout = layouts.first(where: { id(of: $0) == "com.apple.keylayout.ABC" }) ?? layouts.first else {
            return false
        }
        return TISSelectInputSource(layout) == noErr
    }

    private static func sources() -> [TISInputSource] {
        let filter = [kTISPropertyBundleID as String: bundleID] as CFDictionary
        return (TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource]) ?? []
    }

    private static func id(of source: TISInputSource) -> String {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "" }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    /// 系统存的已启用第三方输入法名单（com.apple.inputsources 的 AppleEnabledThirdPartyInputSources，
    /// 系统自带的在 com.apple.HIToolbox 里）里有没有它。父级按 Bundle ID 认，输入模式按 Input Mode 认。
    /// 这份名单只有系统设置（用户点「允许」、手动添加或移除）写得进去，加没加进列表以它为准
    private static func isPersisted(_ id: String) -> Bool {
        let domain = "com.apple.inputsources" as CFString
        CFPreferencesAppSynchronize(domain)
        guard let list = CFPreferencesCopyAppValue("AppleEnabledThirdPartyInputSources" as CFString, domain)
                as? [[String: Any]] else { return false }
        return list.contains { entry in
            id == modeID ? entry["Input Mode"] as? String == id
                : entry["Bundle ID"] as? String == id && entry["Input Mode"] == nil
        }
    }
}
