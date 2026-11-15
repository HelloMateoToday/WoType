//
//  Permissions.swift
//  WoType
//
//  麦克风、辅助功能两个权限的状态和去要的办法：设置里的「系统权限」页、各页顶上的提醒、新手引导共用。
//  辅助功能变了系统不通知，设置窗口开着时每 2 秒查一次，变了发 didChange。
//

import AVFoundation
import Cocoa

@MainActor
enum Permissions {

    enum Microphone {
        case granted
        /// 还没问过：点「允许」弹系统的授权框
        case notAsked
        /// 拒绝过（或被限制）：系统不会再问，只能去系统设置里开
        case denied
    }

    /// 权限变了（设置窗口开着时才查）
    static let didChange = Notification.Name("WoTypePermissionsDidChange")

    static var microphone: Microphone {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notAsked
        default: .denied
        }
    }

    static var accessibility: Bool { AXIsProcessTrusted() }

    /// 没问过的弹系统的授权框；拒绝过的系统不会再问，打开系统设置的那一页
    static func requestMicrophone() {
        if microphone == .notAsked {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async { check() }
            }
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
    }

    /// 辅助功能：系统弹窗带「打开系统设置」；已经问过、不再弹窗的，直接打开系统设置的那一页
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    // MARK: - 功能缺了哪个权限

    /// 开着的功能缺了权限、用不了（或者少了一部分）时的一句话；都好时是空的。
    /// 侧边栏的红点、各页顶上的提醒都按它。
    static func problems(_ config: Config) -> [Problem] {
        var problems: [Problem] = []
        let ax = accessibility
        if config.voice, microphone != .granted {
            problems.append(Problem(permission: .microphone, pages: ["voice", "microphone"], text: "没有「麦克风」权限，语音输入用不了。"))
        }
        if config.voice, config.voicePolish, config.voiceContextCursor || config.voiceContextScreen, !ax {
            problems.append(Problem(permission: .accessibility, pages: ["voice"],
                                    text: "没有「辅助功能」权限，润色时读不到光标前后的文字和屏幕内容。"))
        }
        if config.selectionReplace || config.selectionShow, !ax {
            problems.append(Problem(permission: .accessibility, pages: ["translate"],
                                    text: "没有「辅助功能」权限，划词翻译读不到选中的文字。"))
        }
        return problems
    }

    struct Problem {
        enum Kind { case microphone, accessibility }
        let permission: Kind
        /// 在哪几页顶上提醒
        let pages: [String]
        let text: String

        @MainActor var buttonTitle: String {
            permission == .accessibility ? "去授权" : Permissions.microphone == .notAsked ? "允许" : "打开系统设置"
        }

        @MainActor func request() {
            if permission == .accessibility { Permissions.requestAccessibility() } else { Permissions.requestMicrophone() }
        }
    }

    // MARK: - 定时查

    private static var timer: Timer?
    private static var last: (Microphone, Bool)?

    /// 设置窗口打开时开始查，关掉时停（不常驻：输入法进程一直在跑）
    static func startWatching() {
        guard timer == nil else { return }
        last = (microphone, accessibility)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { check() }
        }
    }

    static func stopWatching() {
        timer?.invalidate()
        timer = nil
        last = nil
    }

    /// 查一次，变了就通知
    static func check() {
        let now = (microphone, accessibility)
        guard let last, last.0 == now.0, last.1 == now.1 else {
            last = now
            NotificationCenter.default.post(name: didChange, object: nil)
            return
        }
    }
}
