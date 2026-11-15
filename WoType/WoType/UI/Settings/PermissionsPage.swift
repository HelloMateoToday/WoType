//
//  PermissionsPage.swift
//  WoType
//
//  设置 › 系统权限：麦克风、辅助功能现在给没给，没给的有按钮去要；下面列出用到它们的功能能不能用。
//  设置窗口开着时每 2 秒查一次（辅助功能变了系统不通知），从系统设置授权完回来，这里自己变成「已允许」。
//

import Cocoa

final class PermissionsPage: SettingsPage {
    override var pageTitle: String { "系统权限" }
    override var pageSubtitle: String { "语音输入和划词翻译要用到的系统权限。" }

    override func build() -> [NSView] {
        let microphone = Permissions.microphone
        let ax = Permissions.accessibility
        let micAccessory: NSView = switch microphone {
        case .granted: Status("已允许", ok: true)
        case .notAsked: SettingButton(title: "允许") { Permissions.requestMicrophone() }
        case .denied: SettingButton(title: "打开系统设置") { Permissions.requestMicrophone() }
        }
        let axAccessory: NSView = ax ? Status("已允许", ok: true) : SettingButton(title: "去授权") { Permissions.requestAccessibility() }
        return [
            SettingsKit.sectionTitle("权限"),
            SettingsKit.card([
                SettingsKit.row(title: "麦克风",
                                detail: microphone == .denied ? "拒绝过，要在系统设置里打开。" : "语音输入时录音，只在按住语音键时听。",
                                icon: SettingsIcon(symbol: "mic.fill", color: .systemOrange), accessory: micAccessory),
                SettingsKit.row(title: "辅助功能", detail: "读选中的文字、光标前后的文字和屏幕内容。",
                                help: "划词翻译用它读你选中的文字；语音润色用它读光标前后的文字、屏幕内容，判断是不是搜索框。\n\n"
                                    + "系统设置里看着是开的、这里还是显示未允许时（WoType 更新过），"
                                    + "先在系统设置的列表里选中 WoType 点「−」删掉，再点「去授权」重新加上。",
                                icon: SettingsIcon(symbol: "accessibility", color: .systemBlue), accessory: axAccessory),
            ]),
            SettingsKit.sectionTitle("用到它的功能"),
            SettingsKit.card(featureRows(microphone: microphone == .granted, ax: ax)),
        ]
    }

    /// 每个功能：要哪个权限、现在能不能用（没开的显示「没开」，不算问题）。
    private func featureRows(microphone: Bool, ax: Bool) -> [NSView] {
        let voice = config.voice
        let selection = config.selectionReplace || config.selectionShow
        let context = voice && config.voicePolish && (config.voiceContextCursor || config.voiceContextScreen)
        func state(_ on: Bool, missing: String?) -> NSView {
            guard on else { return Self.status("没开", .off) }
            if let missing { return Self.status("缺" + missing, .warning) }
            return Self.status("可以用", .ok)
        }
        return [
            row("语音输入", "要麦克风。", "mic.fill", .systemRed, page: "voice",
                state(voice, missing: microphone ? nil : "麦克风")),
            row("划词翻译", "要辅助功能。", "text.bubble.fill", .systemTeal, page: "translate",
                state(selection, missing: ax ? nil : "辅助功能")),
            row("润色参考", "「光标前后的文字」「屏幕内容」要辅助功能。", "text.cursor", .systemBlue, page: "voice",
                state(context, missing: ax ? nil : "辅助功能")),
        ]
    }

    /// 能点的一行：点了跳到这个功能的设置页。
    private func row(_ title: String, _ detail: String, _ symbol: String, _ color: NSColor, page: String,
                     _ status: NSView) -> NSView {
        let nav = NavRow(content: SettingsKit.row(title: title, detail: detail,
                                                  icon: SettingsIcon(symbol: symbol, color: color), accessory: status))
        nav.onClick = { SettingsWindowController.shared.navigate(to: page) }
        return nav
    }

    private enum Kind { case ok, warning, off }

    /// 行右边的状态：绿勾「可以用」、橙色警告「缺麦克风」、灰色「没开」。
    private static func status(_ text: String, _ kind: Kind) -> NSView {
        let symbol = switch kind {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .off: "minus.circle"
        }
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = switch kind {
        case .ok: .systemGreen
        case .warning: .systemOrange
        case .off: .tertiaryLabelColor
        }
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = kind == .off ? .secondaryLabelColor : .labelColor
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 4
        return stack
    }
}
