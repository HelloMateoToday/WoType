//
//  Theme.swift
//  WoType
//
//  候选窗的配色和字号。配色分几套皮肤（微信、搜狗橘色、macOS 经典），设置里选，皮肤只换颜色；微信沿用 WoType
//  在 Linux 上的绿色主题（sample/WowType/themes）。颜色都是动态色：跟着系统的浅色 / 深色模式变。
//

import Cocoa

enum Theme {

    private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return rgb(isDark ? dark : light)
        }
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    // 候选窗的颜色跟着设置里选的皮肤走（Palette）；形状、圆角、阴影、描边规则几套皮肤都一样
    static var palette: Palette { Settings.shared.config.skin.palette }
    static var background: NSColor { palette.background }
    static var border: NSColor { palette.border }
    static let panelShadow = NSColor(name: nil) { appearance in
        NSColor.black.withAlphaComponent(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0.45 : 0.16)
    }
    static var text: NSColor { palette.text }
    /// 展开的网格里行与行之间的细线
    static var gridSeparator: NSColor { palette.gridSeparator }
    static var secondaryText: NSColor { palette.secondaryText }
    static var highlight: NSColor { palette.highlight }
    static var highlightText: NSColor { palette.highlightText }
    /// 鼠标悬停时铺的淡色：选中有底色就用底色，不铺底的皮肤用选中的字色
    static var hoverTint: NSColor {
        (palette.highlight == .clear ? palette.highlightText : palette.highlight).withAlphaComponent(0.12)
    }

    static let cornerRadius: CGFloat = 12
    static let highlightRadius: CGFloat = 8

    /// 一套皮肤：只是候选窗的一组颜色。都是动态色，跟着浅色 / 深色模式变。
    struct Palette {
        let background: NSColor
        /// 描边：浅色模式都不描（只靠阴影，照微信输入法），深色模式一圈很淡的，免得和深色背景糊在一起
        let border: NSColor
        let text: NSColor
        /// 序号、候选窗里的拼音、∨
        let secondaryText: NSColor
        let gridSeparator: NSColor
        /// 选中候选的底色和字色（底色是 .clear 时不铺底，只靠字色区分，照搜狗）
        let highlight: NSColor
        let highlightText: NSColor

        /// 微信：沿用 WowType 在 Linux 上的绿色主题
        static let wechat = Palette(
            background: dynamic(light: 0xFFFFFF, dark: 0x25292B),
            border: dynamic(light: .clear, dark: rgb(0x3B4144)),
            text: dynamic(light: 0x333333, dark: 0xE6EAE8),
            secondaryText: dynamic(light: 0x7A8580, dark: 0x8E9894),
            gridSeparator: dynamic(light: 0xE6E6E6, dark: 0x3B4144),
            highlight: dynamic(light: 0x0EAF76, dark: 0x13B57C),
            highlightText: .white)

        /// 搜狗橘色：主色和候选字的颜色取自 screenshots/搜狗-橘.png，深色模式是按浅色推的。
        /// 选中的候选不铺底，字和序号换成橘色
        static let sogouOrange = Palette(
            background: dynamic(light: 0xFFFFFF, dark: 0x2B2D31),
            border: dynamic(light: .clear, dark: rgb(0x3C3F44)),
            text: dynamic(light: 0x555555, dark: 0xE6E6E6),
            secondaryText: dynamic(light: 0x999999, dark: 0x8A8D96),
            gridSeparator: dynamic(light: 0xEDEDED, dark: 0x3C3F44),
            highlight: .clear,
            highlightText: dynamic(light: 0xFF7200, dark: 0xFF8A2E))
        /// macOS 经典：底色和字色照鼠须管的「Mac 仿原生」皮肤（sample/skin.txt，作者一方；原文的色值是 BGR，
        /// 这里换成了 RGB）；选中用系统蓝（不跟强调色变）
        static let macosClassic = Palette(
            background: dynamic(light: 0xFFFFFF, dark: 0x2E2A25),
            border: dynamic(light: .clear, dark: rgb(0x3A3631)),
            text: dynamic(light: 0x3C3C3C, dark: 0xEAE9E9),
            secondaryText: dynamic(light: 0x999999, dark: 0x999999),
            gridSeparator: dynamic(light: 0xE6E6E6, dark: 0x3A3631),
            highlight: .systemBlue,
            highlightText: .white)
    }
    /// 中 / 英指示器：照状态栏图标，浅色模式黑块白字，深色模式反过来
    static let modeIndicator = dynamic(light: 0x111111, dark: 0xF2F2F2)
    static let modeIndicatorText = dynamic(light: 0xFFFFFF, dark: 0x111111)

    // 设置窗口（颜色取自 screenshots/v1.mp4）：实色侧边栏，浅灰内容区上放白卡片
    static let settingsSidebar = dynamic(light: 0xDBDBDB, dark: 0x262628)
    static let settingsSidebarSelection = dynamic(light: 0xC8C8C8, dark: 0x3A3A3D)
    static let settingsBackground = dynamic(light: 0xF3F3F3, dark: 0x1C1C1E)
    static let settingsDivider = dynamic(light: 0xE2E2E2, dark: 0x313134)
    static let settingsCard = dynamic(light: 0xFDFDFD, dark: 0x2C2C2E)
    static let settingsRowHover = dynamic(light: 0xDEECFA, dark: 0x243549)
    static let settingsBadge = dynamic(light: 0xEBEBEB, dark: 0x3A3A3D)
    static let settingsArt = dynamic(light: 0xD8D8D8, dark: 0x3A3A3D)

    static let candidateFont = NSFont.systemFont(ofSize: 15)
    static let labelFont = NSFont.systemFont(ofSize: 13)
    static let preeditFont = NSFont.systemFont(ofSize: 13)
}

extension Skin {
    var palette: Theme.Palette {
        switch self {
        case .wechat: .wechat
        case .sogouOrange: .sogouOrange
        case .macosClassic: .macosClassic
        }
    }
}
