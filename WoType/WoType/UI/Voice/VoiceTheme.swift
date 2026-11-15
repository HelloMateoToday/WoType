//
//  VoiceTheme.swift
//  WoType
//
//  移植自 Arion apps/desktop/ui/shared/theme/theme.go@d2108fe（AGPL-3.0-only）：
//  只搬浮窗用到的颜色、字号和两种弹簧动画（Settle、Pop）。
//

import AppKit

/// 浮窗的配色（Arion 的 Tokens 里胶囊用到的那几个），深色模式有几项不同。
struct VoiceTokens {
    var pillSurface: NSColor
    var pillText: NSColor
    var pillMuted: NSColor
    var pillBorder: NSColor
    var live: NSColor
    var success: NSColor
    var warning: NSColor
    var onFill: NSColor
    var shade: NSColor

    static func resolve(dark: Bool) -> VoiceTokens {
        var t = VoiceTokens(
            pillSurface: VoicePalette.substrate.withAlphaComponent(0.94),
            pillText: VoicePalette.ink50,
            pillMuted: VoicePalette.ink50.withAlphaComponent(0.62),
            pillBorder: VoicePalette.substrateLine,
            live: VoicePalette.danger500,
            success: VoicePalette.success500,
            warning: VoicePalette.warning500,
            onFill: .white,
            shade: VoicePalette.ink900)
        if dark {
            t.live = VoicePalette.danger400
            t.success = VoicePalette.success400
            t.warning = VoicePalette.warning400
            t.shade = .black
            t.pillSurface = VoicePalette.substrate.withAlphaComponent(0.96)
            t.pillBorder = NSColor(hex: 0x3a342a)
        }
        return t
    }
}

enum VoicePalette {
    static let ink50 = NSColor(hex: 0xfaf8f5)
    static let ink900 = NSColor(hex: 0x14110f)
    static let success500 = NSColor(hex: 0x1f9e5e)
    static let success400 = NSColor(hex: 0x31c47a)
    static let danger500 = NSColor(hex: 0xe03f1f)
    static let danger400 = NSColor(hex: 0xeb6347)
    static let warning500 = NSColor(hex: 0xe6780a)
    static let warning400 = NSColor(hex: 0xf29233)
    static let substrate = NSColor(hex: 0x161410)
    static let substrateLine = NSColor(hex: 0x2d2820)
}

/// 字号和动画（theme.go 的 Body、Caption、RadiusSM、Settle、Pop）。
enum VoiceStyle {
    static let body: CGFloat = 13
    static let caption: CGFloat = 11.5
    static let radiusSM: CGFloat = 4
    /// 按钮（theme.go 的 RadiusControl = RadiusLG）
    static let radiusControl: CGFloat = 10
    /// Settle：移动布局，不回弹
    static let settle = SpringCurve(duration: 0.42, bounce: 0)
    /// Pop：小东西进场，略微回弹
    static let pop = SpringCurve(duration: 0.38, bounce: 0.18)
}

/// 弹簧（质量 1）。duration / bounce 的换算和 SwiftUI、MyGo 的 Spring 一样：
/// 刚度 = (2π / duration)²，阻尼 = 4π(1 − bounce) / duration。
struct SpringCurve {
    var stiffness: Double
    var damping: Double

    init(duration: Double, bounce: Double) {
        stiffness = pow(2 * .pi / duration, 2)
        damping = 4 * .pi * (1 - bounce) / duration
    }

    init(stiffness: Double, damping: Double) {
        self.stiffness = stiffness
        self.damping = damping
    }

    /// 往 target 走 dt 秒（切成小步积分，帧率掉了也稳）。
    func update(value: inout Double, velocity: inout Double, target: Double, deltaTime dt: Double) {
        var left = dt
        while left > 0 {
            let step = min(left, 1.0 / 240)
            let acceleration = -stiffness * (value - target) - damping * velocity
            velocity += acceleration * step
            value += velocity * step
            left -= step
        }
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                  green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}
