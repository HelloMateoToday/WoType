//
//  InputSourceGuide.swift
//  WoType
//
//  照「系统设置」画的动画（docs/18、19）：怎么添加、移除 WoType 输入法（新手引导「添加输入法」和安装器的教程共用），
//  怎么允许麦克风、辅助功能（新手引导「允许权限」）。安装器经符号链接编这个文件，所以这里只能用 Cocoa 和同目录的 KeyCap.swift。
//

import Cocoa

/// 按固定节拍走的剧本：每一拍调一次 show(beat:)，走完一遍从头再来。系统开了「减弱动态效果」时只画最后一拍。
class GuideDemo: NSView {

    var beats: Int { 1 }
    var interval: TimeInterval { 0.4 }
    private var timer: Timer?
    private var beat = 0

    static var reducedMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    func start() {
        guard timer == nil else { return }
        if Self.reducedMotion {
            show(beat: beats - 1)
            return
        }
        beat = 0
        show(beat: 0)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.beat = (self.beat + 1) % self.beats
                self.show(beat: self.beat)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 子类画第几拍
    func show(beat: Int) {}
}

/// 切换输入法的快捷键，照用户在系统设置里的设置（不一定是 ⌃空格，2026-11-13 这台机器上是 ⌘空格；也可能一个都没有）。
nonisolated enum InputSwitchKeys {

    /// 键帽写法：["{command+space}", "{fn}"]
    static var tokens: [String] {
        var tokens = shortcuts().compactMap(token)
        if globeSwitches { tokens.append("{fn}") }
        return tokens
    }

    /// 「，或按 {command+space}」；没有快捷键就是空的
    static var orPress: String {
        let tokens = tokens
        return tokens.isEmpty ? "" : "，或按 " + tokens.joined(separator: " 或 ")
    }

    /// 「选择上一个 / 下一个输入法」（系统设置 › 键盘 › 键盘快捷键 › 输入法；com.apple.symbolichotkeys 的 60、61 项）：
    /// 虚拟键码和修饰键（NSEvent.ModifierFlags 的原始值）。用户改过的照实给，关掉了就没有；
    /// 从没改过的那一项名单里没有，用系统默认：上一个 ⌃空格（开着），下一个 ⌃⌥空格（关着）
    static func shortcuts() -> [(keyCode: Int, modifiers: UInt)] {
        let domain = "com.apple.symbolichotkeys" as CFString
        CFPreferencesAppSynchronize(domain)
        let hotKeys = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, domain) as? [String: Any] ?? [:]
        let defaults: [(id: String, fallback: (keyCode: Int, modifiers: UInt)?)] = [("60", (49, 1 << 18)), ("61", nil)]
        var shortcuts: [(keyCode: Int, modifiers: UInt)] = []
        for (id, fallback) in defaults {
            guard let entry = hotKeys[id] as? [String: Any] else {
                if let fallback { shortcuts.append(fallback) }
                continue
            }
            guard entry["enabled"] as? Bool == true,
                  let parameters = (entry["value"] as? [String: Any])?["parameters"] as? [Int], parameters.count == 3,
                  !shortcuts.contains(where: { $0.keyCode == parameters[1] && $0.modifiers == UInt(parameters[2]) })
            else { continue }
            shortcuts.append((parameters[1], UInt(parameters[2])))
        }
        return shortcuts
    }

    /// 🌐（fn）键设成了「切换输入法」（系统设置 › 键盘 › 按下 🌐 键时；com.apple.HIToolbox 的 AppleFnUsageType 是 1）
    static var globeSwitches: Bool {
        let domain = "com.apple.HIToolbox" as CFString
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, domain) as? Int == 1
    }

    /// {command+space}。认不出的键（不是空格、Tab、回车这几个）不写
    private static func token(_ shortcut: (keyCode: Int, modifiers: UInt)) -> String? {
        let names: [Int: String] = [49: "space", 48: "tab", 36: "return", 53: "esc"]
        guard let key = names[shortcut.keyCode] else { return nil }
        let flags = NSEvent.ModifierFlags(rawValue: shortcut.modifiers)
        var keys: [String] = []
        if flags.contains(.control) { keys.append("control") }
        if flags.contains(.option) { keys.append("option") }
        if flags.contains(.shift) { keys.append("shift") }
        if flags.contains(.command) { keys.append("command") }
        return "{" + (keys + [key]).joined(separator: "+") + "}"
    }
}

/// 照 macOS 的「系统设置」画的演示的公共部分：版面（菜单栏、系统设置窗口、侧边栏、内容区）、画法（左边带搜索框和彩色图标的
/// 侧边栏、右边灰底上的白色分组、白底细边的按钮，只有默认按钮是蓝的）、鼠标指针和底下一句说明。
/// 安装器把动画缩小放，说明另外用正常字号显示（showsCaption = false，captionChanged）。
class SettingsSketch: GuideDemo {

    /// 说明换了（安装器自己显示说明时用）
    var captionChanged: ((String) -> Void)?

    /// 画面的大小：说明在 y = 390 左右，不显示说明时只要上面 350
    static let designSize = NSSize(width: 440, height: 440)
    static let pictureHeight: CGFloat = 350

    private let pointer = NSImageView(image: NSCursor.arrow.image)
    private let label = NSTextField(labelWithString: "")
    private var caption = ""

    init(showsCaption: Bool = true) {
        super.init(frame: NSRect(origin: .zero, size: Self.designSize))
        pointer.imageScaling = .scaleNone
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isHidden = !showsCaption
        addSubview(label)
        addSubview(pointer)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 170),
            label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var interval: TimeInterval { 0.6 }

    /// 换说明（{…} 画成键帽）
    func setCaption(_ caption: String) {
        label.attributedStringValue = KeyCaps.text(caption, font: .systemFont(ofSize: 12),
                                                   color: .secondaryLabelColor, alignment: .center)
        if caption != self.caption {
            self.caption = caption
            captionChanged?(caption)
        }
    }

    /// 指针移到 target（第一拍、减弱动态效果时直接跳过去）
    func movePointer(to target: NSPoint, animated: Bool) {
        // 箭头的尖在图片左上角附近
        let origin = NSPoint(x: target.x - 4, y: target.y - 3)
        if !animated || Self.reducedMotion {
            pointer.frame = NSRect(origin: origin, size: pointer.image?.size ?? .zero)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.4
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                pointer.animator().setFrameOrigin(origin)
            }
        }
    }

    // MARK: 版面

    var settingsWindow: NSRect { NSRect(x: 16, y: bounds.midY - 180, width: bounds.width - 32, height: 300) }
    var bar: NSRect { NSRect(x: 16, y: settingsWindow.minY - 40, width: bounds.width - 32, height: 24) }
    var sidebarArea: NSRect { NSRect(x: settingsWindow.minX, y: settingsWindow.minY, width: 128, height: settingsWindow.height) }
    var searchField: NSRect { NSRect(x: sidebarArea.minX + 10, y: sidebarArea.minY + 36, width: sidebarArea.width - 20, height: 20) }
    func sidebarRow(_ i: Int) -> NSRect {
        NSRect(x: sidebarArea.minX + 8, y: searchField.maxY + 8 + CGFloat(i) * 26, width: sidebarArea.width - 16, height: 24)
    }
    var content: NSRect {
        NSRect(x: sidebarArea.maxX + 14, y: settingsWindow.minY + 44, width: settingsWindow.maxX - sidebarArea.maxX - 28, height: settingsWindow.height - 56)
    }
    var menuIcon: NSRect { NSRect(x: bar.maxX - 60, y: bar.minY + 3, width: 22, height: 18) }

    // MARK: 画（照系统设置的样子）

    var dark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    /// 右边内容区的灰底、白色分组、侧边栏
    var contentBackground: NSColor { dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1) }
    var groupBackground: NSColor { dark ? NSColor(white: 0.21, alpha: 1) : .white }
    var sidebarBackground: NSColor { dark ? NSColor(white: 0.19, alpha: 1) : NSColor(white: 0.965, alpha: 1) }
    var hairline: NSColor { NSColor.black.withAlphaComponent(dark ? 0.5 : 0.1) }

    func fill(_ rect: NSRect, _ color: NSColor, radius: CGFloat = 5) {
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    func stroke(_ rect: NSRect, _ color: NSColor, radius: CGFloat = 5) {
        color.setStroke()
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius)
        path.lineWidth = 0.5
        path.stroke()
    }

    func text(_ string: String, _ rect: NSRect, size: CGFloat = 12, weight: NSFont.Weight = .regular,
              color: NSColor = .labelColor, center: Bool = false, inset: CGFloat = 8) {
        let s = NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
        let w = s.size()
        s.draw(at: NSPoint(x: center ? rect.midX - w.width / 2 : rect.minX + inset, y: rect.midY - w.height / 2))
    }

    /// 系统的按钮：白底、细边、一点点阴影、黑字；默认按钮是强调色、白字。pressed 时颜色深一点
    func button(_ title: String, _ rect: NSRect, primary: Bool = false, pressed: Bool = false) {
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 1
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.15)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        var color: NSColor = primary ? .controlAccentColor : (dark ? NSColor(white: 0.36, alpha: 1) : .white)
        if pressed { color = color.blended(withFraction: 0.18, of: .black) ?? color }
        fill(rect, color, radius: 5)
        NSGraphicsContext.restoreGraphicsState()
        if !primary { stroke(rect, hairline, radius: 5) }
        text(title, rect, size: 12, color: primary ? .white : .labelColor, center: true)
    }

    /// 侧边栏、列表里的图标：彩色圆角方块里一个白色的 SF Symbol
    func icon(_ symbol: String, _ color: NSColor, at origin: NSPoint, size: CGFloat = 18) {
        let box = NSRect(x: origin.x, y: origin.y, width: size, height: size)
        fill(box, color, radius: size * 0.24)
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size * 0.55, weight: .medium)) else { return }
        let s = image.size
        let tinted = NSImage(size: s, flipped: false) { r in
            image.draw(in: r)
            NSColor.white.set()
            r.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: NSRect(x: box.midX - s.width / 2, y: box.midY - s.height / 2, width: s.width, height: s.height),
                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// 搜索框：浅灰圆角，放大镜加灰字
    func search(_ rect: NSRect) {
        fill(rect, dark ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.05), radius: 6)
        if let glass = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium)) {
            let s = glass.size
            let tinted = NSImage(size: s, flipped: false) { r in
                glass.draw(in: r)
                NSColor.tertiaryLabelColor.set()
                r.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: rect.minX + 7, y: rect.midY - s.height / 2, width: s.width, height: s.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        text("搜索", rect, size: 11, color: .tertiaryLabelColor, inset: 22)
    }

    /// 弹出的窗口（表单、面板、对话框）：白底圆角加阴影
    func sheetBox(_ rect: NSRect) {
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        fill(rect, dark ? NSColor(white: 0.2, alpha: 1) : NSColor(white: 0.97, alpha: 1), radius: 10)
        NSGraphicsContext.restoreGraphicsState()
        stroke(rect, hairline, radius: 10)
    }

    /// 菜单栏：右边一个输入法图标（W 或 A）
    func drawMenuBar(selected: Bool) {
        fill(bar, dark ? NSColor(white: 0.2, alpha: 0.9) : NSColor(white: 1, alpha: 0.85), radius: 6)
        fill(menuIcon, NSColor.labelColor.withAlphaComponent(0.85), radius: 4)
        text(selected ? "W" : "A", menuIcon, size: 11, weight: .bold, color: .windowBackgroundColor, center: true)
    }

    /// 系统设置窗口：整体阴影，右边灰底，左边侧边栏（搜索框、带图标的项，highlighted 那一项选中），工具栏标题
    func drawSettingsWindow(sidebar: [(String, String, NSColor)], highlighted: String?, title: String) {
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 16
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        fill(settingsWindow, contentBackground, radius: 11)
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: settingsWindow, xRadius: 11, yRadius: 11).addClip()
        sidebarBackground.setFill()
        sidebarArea.fill()
        hairline.setFill()
        NSRect(x: sidebarArea.maxX, y: sidebarArea.minY, width: 0.5, height: sidebarArea.height).fill()
        NSGraphicsContext.restoreGraphicsState()
        stroke(settingsWindow, hairline, radius: 11)
        for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: settingsWindow.minX + 12 + CGFloat(i) * 16, y: settingsWindow.minY + 12, width: 10, height: 10)).fill()
        }
        search(searchField)
        for (i, (name, symbol, color)) in sidebar.enumerated() {
            let row = sidebarRow(i)
            let on = name == highlighted
            if on { fill(row, .controlAccentColor, radius: 6) }
            icon(symbol, color, at: NSPoint(x: row.minX + 5, y: row.midY - 9))
            text(name, NSRect(x: row.minX + 24, y: row.minY, width: row.width - 24, height: row.height), size: 12,
                 color: on ? .white : .labelColor, inset: 6)
        }
        text("‹  ›", NSRect(x: content.minX, y: settingsWindow.minY + 8, width: 40, height: 22), size: 14, color: .tertiaryLabelColor, inset: 0)
        text(title, NSRect(x: content.minX + 40, y: settingsWindow.minY + 8, width: 160, height: 22), size: 13, weight: .bold, inset: 0)
    }

    /// 白色分组（几行，行间细线）
    func group(_ rect: NSRect, rows: Int) {
        fill(rect, groupBackground, radius: 8)
        stroke(rect, hairline, radius: 8)
        hairline.setFill()
        for i in 1..<max(rows, 1) {
            NSRect(x: rect.minX + 10, y: rect.minY + rect.height / CGFloat(rows) * CGFloat(i), width: rect.width - 20, height: 0.5).fill()
        }
    }

    /// 点击：指针下面一圈
    func drawClick(at p: NSPoint) {
        guard !Self.reducedMotion else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.3).setFill()
        NSBezierPath(ovalIn: NSRect(x: p.x - 11, y: p.y - 11, width: 22, height: 22)).fill()
    }
}

/// 鼠标指针一步步点过去：
/// - 添加：键盘 › 输入法「编辑…」› ＋ › 简体中文 › WoType › 添加 › 完成，最后在菜单栏的输入法菜单里勾上 WoType；
/// - 移除：键盘 › 输入法「编辑…」› 选中 WoType › － › 完成，菜单栏的输入法菜单里就没有它了。
final class InputSourceDemo: SettingsSketch {

    enum Mode { case add, remove }

    let mode: Mode
    private var beat = 0
    /// 每一拍指针指向哪儿、点不点
    private enum Target { case center, keyboard, edit, plus, minus, sheetWoType, chinese, wotype, add, done, menu, menuItem }
    private var script: [(Target, Bool)] {
        switch mode {
        case .add:
            [(.center, false), (.keyboard, false), (.keyboard, true), (.edit, false), (.edit, true),
             (.plus, false), (.plus, true), (.chinese, true), (.wotype, true), (.add, false), (.add, true),
             (.done, true), (.menu, true), (.menuItem, false), (.menuItem, true), (.menuItem, false), (.menuItem, false)]
        case .remove:
            [(.center, false), (.keyboard, false), (.keyboard, true), (.edit, false), (.edit, true),
             (.sheetWoType, false), (.sheetWoType, true), (.minus, false), (.minus, true), (.done, false), (.done, true),
             (.menu, true), (.menu, false), (.menu, false)]
        }
    }
    /// 添加的最后一句快捷键照用户的设置，每次现算
    private var captions: [String] {
        switch mode {
        case .add:
            ["① 打开系统设置 › 键盘，在「输入法」那一行点「编辑…」", "② 点左下角的 ＋",
             "③ 选「简体中文」，再选「WoType」，点「添加」", "④ 在菜单栏切到 WoType\(InputSwitchKeys.orPress)"]
        case .remove:
            ["① 打开系统设置 › 键盘，在「输入法」那一行点「编辑…」", "② 选中「WoType 拼音」，点左下角的 －",
             "③ 点输入法列表右下角的「完成」，菜单栏里就没有 WoType 了"]
        }
    }
    private var captionIndex: Int {
        switch mode {
        case .add: beat < 5 ? 0 : beat < 7 ? 1 : beat < 11 ? 2 : 3
        case .remove: beat < 5 ? 0 : beat < 9 ? 1 : 2
        }
    }
    /// 侧边栏：名字、图标、图标底色（照系统设置）
    private static let sidebar: [(String, String, NSColor)] = [
        ("通用", "gearshape.fill", .systemGray), ("外观", "circle.lefthalf.filled", .black),
        ("辅助功能", "accessibility", .systemBlue), ("显示器", "sun.max.fill", .systemBlue),
        ("键盘", "keyboard.fill", .systemGray), ("鼠标", "computermouse.fill", .systemGray),
        ("触控板", "hand.point.up.left.fill", .systemGray),
    ]

    init(mode: Mode, showsCaption: Bool = true) {
        self.mode = mode
        super.init(showsCaption: showsCaption)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var beats: Int { script.count }

    // MARK: 版面

    /// 「键盘」页里「文字输入」那一组
    private var inputGroup: NSRect { NSRect(x: content.minX, y: content.minY + 88, width: content.width, height: 34) }
    private var editButton: NSRect { NSRect(x: inputGroup.maxX - 62, y: inputGroup.midY - 10, width: 54, height: 20) }
    private var sheet: NSRect { NSRect(x: settingsWindow.minX + 52, y: settingsWindow.minY + 46, width: settingsWindow.width - 104, height: 210) }
    private var sheetList: NSRect { NSRect(x: sheet.minX + 12, y: sheet.minY + 14, width: 110, height: sheet.height - 62) }
    private func sheetRow(_ i: Int) -> NSRect {
        NSRect(x: sheetList.minX + 4, y: sheetList.minY + 4 + CGFloat(i) * 24, width: sheetList.width - 8, height: 22)
    }
    private var plusButton: NSRect { NSRect(x: sheetList.minX, y: sheetList.maxY, width: 22, height: 18) }
    private var minusButton: NSRect { plusButton.offsetBy(dx: 22, dy: 0) }
    private var doneButton: NSRect { NSRect(x: sheet.maxX - 64, y: sheet.maxY - 32, width: 52, height: 20) }
    private var panel: NSRect { NSRect(x: settingsWindow.minX + 36, y: settingsWindow.minY + 36, width: settingsWindow.width - 72, height: 236) }
    private var languages: [String] { ["English", "简体中文", "繁體中文", "日本語"] }
    private func languageRow(_ i: Int) -> NSRect {
        NSRect(x: panel.minX + 14, y: panel.minY + 16 + CGFloat(i) * 22, width: panel.width / 2 - 20, height: 20)
    }
    private var methods: [String] { ["简体拼音", "双拼", "WoType"] }
    private func methodRow(_ i: Int) -> NSRect {
        NSRect(x: panel.midX + 6, y: panel.minY + 16 + CGFloat(i) * 22, width: panel.width / 2 - 20, height: 20)
    }
    private var addButton: NSRect { NSRect(x: panel.maxX - 62, y: panel.maxY - 32, width: 50, height: 20) }
    private var cancelButton: NSRect { NSRect(x: addButton.minX - 58, y: addButton.minY, width: 50, height: 20) }
    /// 菜单栏的输入法菜单：列表里有几个输入法就几行，再加「打开键盘设置…」
    private var inputMenu: NSRect { NSRect(x: bar.maxX - 170, y: bar.maxY + 4, width: 150, height: CGFloat(listed ? 3 : 2) * 24 + 10) }
    private func menuRow(_ i: Int) -> NSRect {
        NSRect(x: inputMenu.minX + 5, y: inputMenu.minY + 5 + CGFloat(i) * 24, width: inputMenu.width - 10, height: 22)
    }

    private func point(_ target: Target) -> NSPoint {
        let rect: NSRect
        switch target {
        case .center: return NSPoint(x: settingsWindow.midX, y: settingsWindow.midY)
        case .keyboard: rect = sidebarRow(4)
        case .edit: rect = editButton
        case .plus: rect = plusButton
        case .minus: rect = minusButton
        case .sheetWoType: rect = sheetRow(1)
        case .chinese: rect = languageRow(1)
        case .wotype: rect = methodRow(2)
        case .add: rect = addButton
        case .done: rect = doneButton
        case .menu: rect = menuIcon
        case .menuItem: rect = menuRow(1)
        }
        return NSPoint(x: rect.midX, y: rect.midY)
    }

    // MARK: 每一拍的状态

    private var keyboardShown: Bool { beat >= 2 }
    private var editPressed: Bool { beat == 4 }
    private var sheetShown: Bool { mode == .add ? (5...11).contains(beat) : (5...10).contains(beat) }
    /// 输入法列表里有 WoType
    private var listed: Bool { mode == .add ? beat >= 11 : beat < 9 }
    /// 表单里 WoType 那一行高亮：添加完是新加的那一行，移除时是选中要删的那一行
    private var sheetWoTypeHighlighted: Bool { mode == .add ? listed : (beat >= 6 && listed) }
    private var plusPressed: Bool { mode == .add && beat == 6 }
    private var minusPressed: Bool { mode == .remove && beat == 8 }
    private var donePressed: Bool { mode == .add ? beat == 11 : beat == 10 }
    private var panelShown: Bool { mode == .add && (7...10).contains(beat) }
    private var menuShown: Bool { mode == .add ? beat >= 12 : beat >= 11 }
    /// WoType 是当前输入法（菜单栏图标是 W）
    private var selected: Bool { mode == .add && beat >= 14 }

    // MARK: 剧本

    override func show(beat: Int) {
        self.beat = beat
        setCaption(captions[captionIndex])
        movePointer(to: point(script[beat].0), animated: beat != 0)
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        show(beat: beat)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawMenuBar(selected: selected)
        drawSettingsWindow(sidebar: Self.sidebar, highlighted: keyboardShown ? "键盘" : nil, title: keyboardShown ? "键盘" : "通用")
        // 右边：「键盘」页的分组
        if keyboardShown {
            let repeatGroup = NSRect(x: content.minX, y: content.minY, width: content.width, height: 56)
            group(repeatGroup, rows: 2)
            text("按键重复速率", NSRect(x: repeatGroup.minX, y: repeatGroup.minY, width: 160, height: 28), size: 12, inset: 10)
            text("键盘导航", NSRect(x: repeatGroup.minX, y: repeatGroup.minY + 28, width: 160, height: 28), size: 12, inset: 10)
            text("文字输入", NSRect(x: inputGroup.minX, y: inputGroup.minY - 20, width: 100, height: 16), size: 11, weight: .semibold,
                 color: .secondaryLabelColor, inset: 2)
            group(inputGroup, rows: 1)
            text("输入法", inputGroup, size: 12, inset: 10)
            text("ABC 和 \(listed ? "1 个其他" : "0 个其他")", NSRect(x: inputGroup.minX + 64, y: inputGroup.minY, width: 120, height: inputGroup.height),
                 size: 11, color: .secondaryLabelColor, inset: 0)
            button("编辑…", editButton, pressed: editPressed)
        } else {
            for i in 0..<3 {
                group(NSRect(x: content.minX, y: content.minY + CGFloat(i) * 62, width: content.width, height: 52), rows: 1)
            }
        }
        // 「输入法」的表单：左边已有的输入法，下面 ＋ −，右下「完成」
        if sheetShown {
            sheetBox(sheet)
            fill(sheetList, groupBackground, radius: 6)
            stroke(sheetList, hairline, radius: 6)
            var items: [(String, String)] = [("ABC", "A")]
            if listed { items.append(("WoType", "W")) }
            for (i, (name, mark)) in items.enumerated() {
                let row = sheetRow(i)
                let on = name == "WoType" && sheetWoTypeHighlighted
                if on { fill(row, .controlAccentColor, radius: 4) }
                let badge = NSRect(x: row.minX + 5, y: row.midY - 8, width: 16, height: 16)
                fill(badge, on ? .white : NSColor.labelColor.withAlphaComponent(0.75), radius: 3)
                text(mark, badge, size: 10, weight: .bold, color: on ? .controlAccentColor : .windowBackgroundColor, center: true)
                text(name, NSRect(x: row.minX + 22, y: row.minY, width: row.width - 22, height: row.height), size: 12,
                     color: on ? .white : .labelColor, inset: 4)
            }
            button("＋", plusButton, pressed: plusPressed)
            button("−", minusButton, pressed: minusPressed)
            text("在菜单栏中显示输入法菜单", NSRect(x: sheetList.maxX + 12, y: sheetList.minY, width: 200, height: 20), size: 11,
                 color: .secondaryLabelColor, inset: 0)
            button("完成", doneButton, primary: true, pressed: donePressed)
        }
        // 添加输入法的面板：左边语言，右边这个语言下的输入法，右下「取消」「添加」
        if panelShown {
            sheetBox(panel)
            let lists = [NSRect(x: languageRow(0).minX - 4, y: panel.minY + 12, width: panel.width / 2 - 12, height: panel.height - 56),
                         NSRect(x: methodRow(0).minX - 4, y: panel.minY + 12, width: panel.width / 2 - 12, height: panel.height - 56)]
            for list in lists {
                fill(list, groupBackground, radius: 6)
                stroke(list, hairline, radius: 6)
            }
            for (i, language) in languages.enumerated() {
                let row = languageRow(i)
                let on = language == "简体中文"
                if on { fill(row, .controlAccentColor, radius: 4) }
                text(language, row, size: 12, color: on ? .white : .labelColor, inset: 6)
            }
            for (i, method) in methods.enumerated() {
                let row = methodRow(i)
                let on = method == "WoType" && beat >= 8
                if on { fill(row, .controlAccentColor, radius: 4) }
                text(method, row, size: 12, color: on ? .white : .labelColor, inset: 6)
            }
            search(NSRect(x: panel.minX + 12, y: addButton.minY, width: 120, height: 20))
            button("取消", cancelButton)
            // 选中了输入法，「添加」才变成默认按钮
            button("添加", addButton, primary: beat >= 8, pressed: beat == 10)
        }
        // 菜单栏的输入法菜单：添加时勾上 WoType；移除后只剩 ABC
        if menuShown {
            sheetBox(inputMenu)
            let items = listed ? ["ABC", "WoType"] : ["ABC"]
            for (i, item) in items.enumerated() {
                let row = menuRow(i)
                let hover = item == "WoType" && (beat == 13 || beat == 14)
                if hover { fill(row, .controlAccentColor, radius: 4) }
                let checked = item == "WoType" ? selected : !selected
                text((checked ? "✓ " : "    ") + item, row, size: 12, color: hover ? .white : .labelColor)
            }
            text("打开键盘设置…", menuRow(items.count), size: 12, color: .labelColor, inset: 20)
        }
        if script[beat].1 { drawClick(at: point(script[beat].0)) }
    }
}

/// 怎么允许麦克风和辅助功能：系统先弹「"WoType"想访问麦克风」，点「允许」；再打开系统设置 › 隐私与安全性 › 辅助功能，
/// 打开 WoType 旁边的开关。
final class PermissionDemo: SettingsSketch {

    private var beat = 0
    private enum Target { case center, allow, privacy, accessibilityRow, toggle }
    private static let script: [(Target, Bool)] = [
        (.center, false), (.allow, false), (.allow, true), (.center, false),
        (.privacy, false), (.privacy, true), (.accessibilityRow, false), (.accessibilityRow, true),
        (.toggle, false), (.toggle, true), (.toggle, false), (.toggle, false),
    ]
    private static let captions = [
        "① 系统问能不能用麦克风时，点「允许」",
        "② 打开系统设置 › 隐私与安全性 › 辅助功能",
        "③ 打开 WoType 旁边的开关",
    ]
    private var captionIndex: Int { beat < 4 ? 0 : beat < 8 ? 1 : 2 }
    private static let sidebar: [(String, String, NSColor)] = [
        ("通用", "gearshape.fill", .systemGray), ("外观", "circle.lefthalf.filled", .black),
        ("辅助功能", "accessibility", .systemBlue), ("显示器", "sun.max.fill", .systemBlue),
        ("隐私与安全性", "hand.raised.fill", .systemBlue), ("键盘", "keyboard.fill", .systemGray),
        ("鼠标", "computermouse.fill", .systemGray),
    ]
    /// 「辅助功能」页里的 App 列表
    private static let apps = ["Rex", "WoType", "微信"]

    override var beats: Int { Self.script.count }

    // MARK: 版面

    /// 麦克风对话框（系统的样子：标题、一句说明、「不允许」「允许」并排）
    private var alert: NSRect { NSRect(x: bounds.midX - 110, y: settingsWindow.minY + 60, width: 220, height: 132) }
    private var allowButton: NSRect { NSRect(x: alert.midX + 4, y: alert.maxY - 34, width: alert.width / 2 - 16, height: 22) }
    private var denyButton: NSRect { NSRect(x: alert.minX + 12, y: allowButton.minY, width: alert.width / 2 - 16, height: 22) }
    private var privacyRow: NSRect { sidebarRow(4) }
    /// 「隐私与安全性」页：一组（定位服务、通讯录、日历、辅助功能…）
    private func privacyGroupRow(_ i: Int) -> NSRect {
        NSRect(x: content.minX, y: content.minY + CGFloat(i) * 30, width: content.width, height: 30)
    }
    private static let privacyItems = [("定位服务", "location.fill", NSColor.systemBlue), ("通讯录", "person.crop.circle.fill", .systemBrown),
                                       ("麦克风", "mic.fill", .systemOrange), ("辅助功能", "accessibility", .systemBlue)]
    private func appRow(_ i: Int) -> NSRect {
        NSRect(x: content.minX, y: content.minY + 36 + CGFloat(i) * 30, width: content.width, height: 30)
    }
    private var wotypeToggle: NSRect { NSRect(x: appRow(1).maxX - 44, y: appRow(1).midY - 9, width: 32, height: 18) }

    private func point(_ target: Target) -> NSPoint {
        let rect: NSRect
        switch target {
        case .center: return NSPoint(x: settingsWindow.midX, y: settingsWindow.midY)
        case .allow: rect = allowButton
        case .privacy: rect = privacyRow
        case .accessibilityRow: rect = privacyGroupRow(3)
        case .toggle: rect = wotypeToggle
        }
        return NSPoint(x: rect.midX, y: rect.midY)
    }

    // MARK: 每一拍的状态

    private var alertShown: Bool { beat <= 2 }
    private var privacyShown: Bool { beat >= 6 }
    private var accessibilityPage: Bool { beat >= 8 }
    private var toggleOn: Bool { beat >= 10 }

    // MARK: 剧本

    override func show(beat: Int) {
        self.beat = beat
        setCaption(Self.captions[captionIndex])
        movePointer(to: point(Self.script[beat].0), animated: beat != 0)
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        show(beat: beat)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawMenuBar(selected: false)
        let title = accessibilityPage ? "辅助功能" : privacyShown ? "隐私与安全性" : "通用"
        drawSettingsWindow(sidebar: Self.sidebar, highlighted: privacyShown ? "隐私与安全性" : nil, title: title)
        if accessibilityPage {
            text("允许下面的 App 控制你的电脑。", NSRect(x: content.minX, y: content.minY, width: content.width, height: 28), size: 11,
                 color: .secondaryLabelColor, inset: 2)
            let list = NSRect(x: content.minX, y: appRow(0).minY, width: content.width, height: CGFloat(Self.apps.count) * 30)
            group(list, rows: Self.apps.count)
            for (i, app) in Self.apps.enumerated() {
                let row = appRow(i)
                icon(app == "WoType" ? "keyboard.fill" : "app.fill", app == "WoType" ? .systemGreen : .systemGray,
                     at: NSPoint(x: row.minX + 10, y: row.midY - 9))
                text(app, NSRect(x: row.minX + 30, y: row.minY, width: 120, height: row.height), size: 12, inset: 6)
                // 开关：开着是强调色、圆钮在右；关着是灰色、圆钮在左
                let toggle = NSRect(x: row.maxX - 44, y: row.midY - 9, width: 32, height: 18)
                let on = app == "WoType" ? toggleOn : app == "Rex"
                fill(toggle, on ? .controlAccentColor : NSColor.labelColor.withAlphaComponent(0.15), radius: 9)
                NSColor.white.setFill()
                NSBezierPath(ovalIn: NSRect(x: on ? toggle.maxX - 17 : toggle.minX + 1, y: toggle.minY + 1, width: 16, height: 16)).fill()
            }
        } else if privacyShown {
            let list = NSRect(x: content.minX, y: content.minY, width: content.width, height: CGFloat(Self.privacyItems.count) * 30)
            group(list, rows: Self.privacyItems.count)
            for (i, (name, symbol, color)) in Self.privacyItems.enumerated() {
                let row = privacyGroupRow(i)
                if name == "辅助功能", beat == 7 { fill(row.insetBy(dx: 2, dy: 2), NSColor.labelColor.withAlphaComponent(0.08), radius: 6) }
                icon(symbol, color, at: NSPoint(x: row.minX + 10, y: row.midY - 9))
                text(name, NSRect(x: row.minX + 30, y: row.minY, width: 120, height: row.height), size: 12, inset: 6)
                text("›", NSRect(x: row.maxX - 24, y: row.minY, width: 20, height: row.height), size: 13, color: .tertiaryLabelColor, inset: 0)
            }
        } else {
            for i in 0..<3 {
                group(NSRect(x: content.minX, y: content.minY + CGFloat(i) * 62, width: content.width, height: 52), rows: 1)
            }
        }
        // 麦克风的系统对话框：盖在最上面
        if alertShown {
            sheetBox(alert)
            icon("mic.fill", .systemOrange, at: NSPoint(x: alert.midX - 14, y: alert.minY + 12), size: 28)
            text("“WoType”想访问麦克风", NSRect(x: alert.minX, y: alert.minY + 46, width: alert.width, height: 18), size: 12,
                 weight: .bold, center: true)
            text("按住语音键说话时才听。", NSRect(x: alert.minX, y: alert.minY + 66, width: alert.width, height: 16), size: 11,
                 color: .secondaryLabelColor, center: true)
            button("不允许", denyButton)
            button("允许", allowButton, primary: true, pressed: beat == 2)
        }
        if Self.script[beat].1 { drawClick(at: point(Self.script[beat].0)) }
    }
}
