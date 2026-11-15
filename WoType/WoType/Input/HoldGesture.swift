//
//  HoldGesture.swift
//  WoType
//
//  移植自 Arion packages/core/application/hold.go@d2108fe（AGPL-3.0-only）的 HoldGesture，逐行翻成 Swift。
//  只搬按键手势；Arion 的快捷键设置（HoldKeysFor、翻译键、第二个听写键）WoType 没有。
//
//  语音键的手势：按住超过门限就一直听写到松开；更短的点按让它一直听写，直到下一次按下。
//  按着语音键时按了别的键是组合键（fn+方向键、Option+字母），由这次按下开始的会话取消，什么都不插入。
//

import Foundation

/// 手势作用在什么状态的会话上
enum HoldSession {
    /// 没有进行中的会话：按下开始一个
    case idle
    /// 会话在准备或录音：按下结束它
    case capturing
    /// 会话在识别或插入：按了也不管
    case busy
}

/// 手势要会话做什么
enum HoldAction {
    case none
    case start
    case stop
    case cancel
}

struct HoldGesture {
    /// 区分按住和点按
    static let defaultThreshold: TimeInterval = 0.3

    var threshold = defaultThreshold
    private(set) var down = false
    private var started = false
    private var pressedAt = Date.distantPast

    /// 按下。按着时系统的自动重复不算。
    mutating func press(_ now: Date, session: HoldSession) -> HoldAction {
        if down { return .none }
        down = true
        started = false
        pressedAt = now
        switch session {
        case .idle:
            started = true
            return .start
        case .capturing:
            return .stop
        case .busy:
            return .none
        }
    }

    /// 松开。
    mutating func release(_ now: Date) -> HoldAction {
        if !down { return .none }
        down = false
        let wasStarted = started
        started = false
        if wasStarted && now.timeIntervalSince(pressedAt) >= threshold {
            return .stop
        }
        return .none
    }

    /// 别的键按下。
    mutating func other() -> HoldAction {
        if !down || !started { return .none }
        started = false
        return .cancel
    }

    /// 忘掉这次按下（比如输入法失去焦点）。
    mutating func reset() {
        down = false
        started = false
    }
}
