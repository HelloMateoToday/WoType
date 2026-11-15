//
//  SettingsKit.swift
//  WoType
//
//  设置窗口用的小部件，照 screenshots/v1.mp4 的样子：分组标题、白色圆角卡片、
//  每行左边（可选的彩色图标）标题和说明、右边是开关 / 下拉框 / 快捷键徽标 / 箭头，
//  以及带插图的选项卡片。
//

import Cocoa

enum SettingsKit {

    /// 内容区左右留白。
    static let contentInset: CGFloat = 24
    static let rowInset: CGFloat = 16
    static let cardRadius: CGFloat = 10
    /// 行右边的下拉框、录键框都是这个宽度：同一张卡片里上下对齐，长的名字截掉后面
    static let controlWidth: CGFloat = 200

    /// 一行里文字的左边缘：图标（22）加两边的空。没有图标的内容（插图等）也从这里开始，各页对齐。
    static let textInset: CGFloat = rowInset + 22 + 12

    /// 卡片上方的分组标题：小号灰字（照系统设置），不和行标题抢。
    static func sectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// 现在用不了的设置（当前引擎没有的功能）：控件都不能点，文字和图标变淡；「?」说明照样能点。
    static func setInactive(_ view: NSView) {
        for sub in view.subviews {
            if let control = sub as? NSControl, !(sub is NSTextField) {
                if !(control is HelpButton) { control.isEnabled = false }
                continue
            }
            if sub is NSTextField || sub is SettingsIcon || sub is NSProgressIndicator {
                sub.alphaValue = 0.45
                continue
            }
            setInactive(sub)
        }
    }

    static func wrappingLabel(_ text: String, size: CGFloat, color: NSColor = .labelColor,
                              weight: NSFont.Weight = .regular) -> NSTextField {
        let label = WrappingLabel(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.isSelectable = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    /// 标题和说明叠在一起。help 不为空时标题右边多一个「?」，点了弹出详细说明（行里的说明只留一句）。
    static func texts(title: String, detail: String?, help: String? = nil) -> NSStackView {
        // 标题常规粗细、说明小一号灰色（照系统设置）：整页不显得重，层次靠字号和颜色
        let titleView: NSView
        if let help, !help.isEmpty {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 13)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let line = NSStackView()
            line.spacing = 4
            line.addView(label, in: .leading)
            line.addView(HelpButton(help), in: .leading)
            titleView = line
        } else {
            titleView = wrappingLabel(title, size: 13)
        }
        var views: [NSView] = [titleView]
        if let detail, !detail.isEmpty {
            views.append(wrappingLabel(detail, size: 11.5, color: .secondaryLabelColor))
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        for view in views {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    /// 一行：左边图标、标题和说明，右边控件。所有页面的行都用它，文字左边缘、行高、控件位置一致。
    ///
    /// 文字的宽度由约束定死（左贴卡片、右贴控件），不靠文字自己的宽度，多行说明的高度才算得准。
    /// 右边是开关时，点这一行的任何地方都能切换。
    static func row(title: String, detail: String? = nil, help: String? = nil, icon: NSView? = nil,
                    accessory: NSView? = nil) -> NSView {
        let row = SettingRowView()
        row.toggle = accessory as? NSSwitch
        row.translatesAutoresizingMaskIntoConstraints = false
        let textStack = texts(title: title, detail: detail, help: help)
        textStack.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(textStack)

        var leading = row.leadingAnchor
        var leadingGap = rowInset
        var constraints: [NSLayoutConstraint] = []
        if let icon {
            row.addSubview(icon)
            constraints += [
                icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: rowInset),
                icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            ]
            leading = icon.trailingAnchor
            leadingGap = 12
        }
        // 行高统一：有说明的 52，没说明的 40；说明换行时跟着长高
        let hasDetail = !(detail ?? "").isEmpty
        constraints += [
            textStack.leadingAnchor.constraint(equalTo: leading, constant: leadingGap),
            textStack.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            textStack.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 9),
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: hasDetail ? 52 : 40),
        ]
        if let accessory {
            accessory.translatesAutoresizingMaskIntoConstraints = false
            if accessory is NSPopUpButton {
                constraints.append(accessory.widthAnchor.constraint(equalToConstant: controlWidth))
            }
            accessory.setContentHuggingPriority(.required, for: .horizontal)
            accessory.setContentCompressionResistancePriority(.required, for: .horizontal)
            (accessory as? NSStackView)?.setHuggingPriority(.required, for: .horizontal)
            row.addSubview(accessory)
            constraints += [
                accessory.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -rowInset),
                accessory.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                accessory.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 8),
                textStack.trailingAnchor.constraint(lessThanOrEqualTo: accessory.leadingAnchor, constant: -16),
            ]
            // 文字尽量占满左边，换行时不会留一大块空
            let fill = textStack.trailingAnchor.constraint(equalTo: accessory.leadingAnchor, constant: -16)
            fill.priority = .defaultHigh
            constraints.append(fill)
        } else {
            constraints.append(textStack.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -rowInset))
        }
        NSLayoutConstraint.activate(constraints)
        return row
    }

    /// 右边的快捷键徽标 + 箭头（能点进去的行用）。
    ///
    /// 宽度完全由徽标和箭头决定（两者都不许拉伸），箭头才能贴着右边对齐。
    static func trailing(badge: String?, chevron: Bool = true) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        var right = container.trailingAnchor
        var gap: CGFloat = 0
        var constraints: [NSLayoutConstraint] = []
        if chevron {
            let image = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)!
                .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))!)
            image.contentTintColor = .tertiaryLabelColor
            image.translatesAutoresizingMaskIntoConstraints = false
            // 不许拉伸：行里「文字占满左边」的约束会把这块往左拉，图片一拉宽，箭头就画到中间去了
            image.setContentHuggingPriority(.required, for: .horizontal)
            container.addSubview(image)
            constraints += [
                image.trailingAnchor.constraint(equalTo: right),
                image.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            ]
            right = image.leadingAnchor
            gap = 10
        }
        var leftmost: NSView?
        if let badge {
            let key = KeyBadge(badge)
            key.setContentHuggingPriority(.required, for: .horizontal)
            container.addSubview(key)
            constraints += [
                key.trailingAnchor.constraint(equalTo: right, constant: -gap),
                key.topAnchor.constraint(equalTo: container.topAnchor),
                key.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ]
            leftmost = key
        }
        if let leftmost {
            constraints.append(leftmost.leadingAnchor.constraint(equalTo: container.leadingAnchor))
        } else if let image = container.subviews.first {
            constraints += [
                image.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                container.heightAnchor.constraint(equalToConstant: 22),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        return container
    }

    /// 白色圆角卡片，行与行之间画细分隔线（左右各缩进一点）。
    static func card(_ rows: [NSView], separatorInset: CGFloat = textInset) -> NSView {
        let card = CardView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        for (i, row) in rows.enumerated() {
            if i > 0 {
                let line = SeparatorLine()
                stack.addArrangedSubview(line)
                line.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: separatorInset).isActive = true
                line.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -rowInset).isActive = true
            }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return card
    }
}

/// 设置里的一行。右边是开关时，点这一行的任何地方（文字、空白）都切换它。
final class SettingRowView: NSView {
    weak var toggle: NSSwitch?

    override func mouseDown(with event: NSEvent) {
        if toggle == nil { super.mouseDown(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        guard let toggle else {
            super.mouseUp(with: event)
            return
        }
        if toggle.isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) {
            toggle.performClick(nil)
        }
    }
}

/// 会换行的文字：宽度由外面的约束决定，高度按这个宽度算。
///
/// 不提供自己的宽度（noIntrinsicMetric），宽度一变就重算高度。以前用 preferredMaxLayoutWidth 跟着
/// frame 走，排版顺序不巧时第二遍不重算，多行说明会被截成一行。
final class WrappingLabel: NSTextField {
    override var intrinsicContentSize: NSSize {
        let width = frame.width > 0 ? frame.width : 10_000
        let height = cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height
            ?? super.intrinsicContentSize.height
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(height))
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { invalidateIntrinsicContentSize() }
    }
}

/// 卡片背景：浅色模式近白、深色模式深灰，没有描边。
class CardView: NSView {
    /// 不画背景（放在另一张卡片里时）
    var transparent = false {
        didSet { needsDisplay = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = SettingsKit.cardRadius
        layer?.backgroundColor = transparent ? nil : Theme.settingsCard.cgColor
    }
}

final class SeparatorLine: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 0.5).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.separatorColor.cgColor
    }
}

/// 彩色圆角方块里一个白色的 SF Symbol，上浅下深的渐变（照系统设置）。侧边栏和列表行都用它。
final class SettingsIcon: NSView {
    private let color: NSColor
    private let image: NSImage?
    private let size: CGFloat

    init(symbol: String, color: NSColor, size: CGFloat = 22) {
        self.color = color
        self.size = size
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size * 0.52, weight: .semibold))
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: size * 0.26, yRadius: size * 0.26)
        let base = color.usingColorSpace(.sRGB) ?? color
        let top = base.blended(withFraction: 0.22, of: .white) ?? base
        NSGradient(starting: top, ending: base)?.draw(in: path, angle: -90)
        guard let image else { return }
        let tinted = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let s = tinted.size
        tinted.draw(in: NSRect(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2,
                               width: s.width, height: s.height))
    }
}

/// 快捷键徽标：灰底圆角里的按键符号（⌃.、⇧、右 ⌥）。
final class KeyBadge: NSView {
    private let text: NSAttributedString

    init(_ keys: String) {
        text = NSAttributedString(string: keys, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ])
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        let size = text.size()
        return NSSize(width: ceil(size.width) + 16, height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.settingsBadge.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}

/// 能点的一行：鼠标移上去时浅蓝底（照 v1.mp4），点了跳到对应的设置。
final class NavRow: NSView {
    var onClick: (() -> Void)?
    var onHover: (() -> Void)?
    private var hovering = false {
        didSet {
            guard hovering != oldValue else { return }
            needsDisplay = true
            if hovering {
                // 同一时刻只高亮一行：鼠标停着、内容在滚时「移出」事件会丢，不能只靠它取消高亮
                if Self.hovered !== self { Self.hovered?.hovering = false }
                Self.hovered = self
            } else if Self.hovered === self {
                Self.hovered = nil
            }
        }
    }
    private static weak var hovered: NavRow?

    init(content: NSView) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
        // 重建跟踪区域（滚动、改大小）时鼠标可能已经不在这一行上了，按鼠标现在的位置重新算
        if hovering, let window {
            hovering = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        onHover?()
    }

    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        Theme.settingsRowHover.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 3), xRadius: 8, yRadius: 8).fill()
    }
}

// MARK: - 用闭包回调的控件

final class SettingSwitch: NSSwitch {
    private var onChange: ((Bool) -> Void)?

    convenience init(isOn: Bool, onChange: @escaping (Bool) -> Void) {
        self.init()
        state = isOn ? .on : .off
        // 和系统设置、v2.mp4 一样用迷你号；大号在一列设置里太抢眼
        controlSize = .mini
        self.onChange = onChange
        target = self
        action = #selector(changed)
    }

    @objc private func changed() { onChange?(state == .on) }
}

final class SettingPopUp: NSPopUpButton {
    private var onChange: ((Int) -> Void)?

    convenience init(items: [String], selected: Int, onChange: @escaping (Int) -> Void) {
        self.init(frame: .zero, pullsDown: false)
        addItems(withTitles: items)
        selectItem(at: selected)
        controlSize = .regular
        (cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingTail
        self.onChange = onChange
        target = self
        action = #selector(changed)
    }

    @objc private func changed() { onChange?(indexOfSelectedItem) }
}

/// 每一项带自己动作的下拉框，可以有分隔线、图标（润色、翻译选模型）。太长的名字截掉后面。
final class ActionPopUp: NSPopUpButton {
    private var actions: [() -> Void] = []

    convenience init() {
        self.init(frame: .zero, pullsDown: false)
        autoenablesItems = false
        controlSize = .regular
        (cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingTail
        target = self
        action = #selector(changed)
    }

    func add(_ title: String, image: NSImage? = nil, selected: Bool = false, action: @escaping () -> Void) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = image
        item.tag = actions.count
        actions.append(action)
        menu?.addItem(item)
        if selected { select(item) }
    }

    func addSeparator() { menu?.addItem(.separator()) }

    /// 一组选项上面的小标题（不能选）
    func addHeader(_ title: String) {
        let item = NSMenuItem.sectionHeader(title: title)
        item.tag = -1
        menu?.addItem(item)
    }

    @objc private func changed() {
        guard let item = selectedItem, actions.indices.contains(item.tag) else { return }
        actions[item.tag]()
    }
}

final class SettingSegments: NSSegmentedControl {
    private var onChange: ((Int) -> Void)?

    convenience init(labels: [String], selected: Int, onChange: @escaping (Int) -> Void) {
        self.init(labels: labels, trackingMode: .selectOne, target: nil, action: nil)
        selectedSegment = selected
        controlSize = .regular
        self.onChange = onChange
        target = self
        action = #selector(changed)
    }

    @objc private func changed() { onChange?(selectedSegment) }
}

final class SettingButton: NSButton {
    private var onClick: (() -> Void)?

    convenience init(title: String, symbol: String? = nil, onClick: @escaping () -> Void) {
        self.init(title: title, target: nil, action: nil)
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        }
        bezelStyle = .rounded
        controlSize = .regular
        self.onClick = onClick
        target = self
        action = #selector(clicked)
    }

    @objc private func clicked() { onClick?() }
}

/// 标题右边的「?」：点了在旁边弹出详细说明（段落之间空一行）。
final class HelpButton: NSButton {
    private let text: String

    init(_ text: String) {
        self.text = text
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: "说明")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        imagePosition = .imageOnly
        isBordered = false
        contentTintColor = .tertiaryLabelColor
        toolTip = "说明"
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        target = self
        action = #selector(clicked)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func clicked() {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.isSelectable = false
        label.preferredMaxLayoutWidth = 280
        label.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            label.widthAnchor.constraint(equalToConstant: 280),
        ])
        let controller = NSViewController()
        controller.view = content
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }
}

/// 蓝色文字链接（「打开“通用” ›」）。
final class LinkButton: NSButton {
    private var onClick: (() -> Void)?

    convenience init(title: String, onClick: @escaping () -> Void) {
        self.init(title: "", target: nil, action: nil)
        isBordered = false
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.linkColor,
        ])
        self.onClick = onClick
        target = self
        action = #selector(clicked)
    }

    @objc private func clicked() { onClick?() }
}

// MARK: - 模型、词库的行

extension SettingsKit {
    /// 模型、词库那一行右边：一个主按钮（下载 / 更新 / 检查更新 / 重试，或者进度条加取消）和「⋯」菜单
    /// （在访达中显示、删除…、恢复内置版本…）。各页规则一样：删除永远在「⋯」里，不会因为有新版就不见了。
    static func resourceAccessory(_ primary: NSView?, more: [(title: String, action: () -> Void)] = []) -> NSView {
        var views: [NSView] = []
        if let primary { views.append(primary) }
        if !more.isEmpty { views.append(MoreButton(more)) }
        let stack = NSStackView(views: views)
        stack.spacing = 8
        return stack
    }

    /// 下载中：进度条 + 取消。
    static func progress(_ fraction: Double?, cancel: @escaping () -> Void) -> NSView {
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = fraction == nil
        if let fraction { bar.doubleValue = fraction * 100 } else { bar.startAnimation(nil) }
        bar.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let stack = NSStackView(views: [bar, SettingButton(title: "取消", onClick: cancel)])
        stack.spacing = 8
        return stack
    }

    /// 正在检查、正在处理：小菊花。
    static func spinner() -> NSView {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        return spinner
    }

    /// 2.3 GB / 850 MB
    static func size(_ bytes: Int64) -> String {
        bytes >= 1_000_000_000
            ? String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
            : "\(max(bytes / 1_000_000, 1)) MB"
    }
}

/// 「⋯」按钮：点了在下面弹出菜单，每一项带自己的动作。
final class MoreButton: NSButton {
    private let items: [(title: String, action: () -> Void)]

    init(_ items: [(title: String, action: () -> Void)]) {
        self.items = items
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "更多")
        imagePosition = .imageOnly
        bezelStyle = .rounded
        controlSize = .regular
        toolTip = "更多"
        target = self
        action = #selector(clicked)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func clicked() {
        let menu = NSMenu()
        for (i, item) in items.enumerated() {
            let entry = NSMenuItem(title: item.title, action: #selector(pick(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = i
            menu.addItem(entry)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard items.indices.contains(sender.tag) else { return }
        // 菜单先收起，再弹确认框
        let action = items[sender.tag].action
        DispatchQueue.main.async { action() }
    }
}

// MARK: - 页面顶上的提醒

/// 页面最上面的一条提醒（开着的功能缺了权限）：浅橙底、警告图标、一句话、右边按钮。权限都在时不放。
final class NoticeBanner: NSView {
    init(text: String, button: String, action: @escaping () -> Void) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)!)
        icon.contentTintColor = .systemOrange
        let label = SettingsKit.wrappingLabel(text, size: 12.5)
        let control = SettingButton(title: button, onClick: action)
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [icon, label, control] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsKit.rowInset + 3),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsKit.textInset),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: control.leadingAnchor, constant: -12),
            control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SettingsKit.rowInset),
            control.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = SettingsKit.cardRadius
        layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.12).cgColor
    }

    /// 这一页要提醒的（各页 build() 最前面放）。
    @MainActor static func banners(page: String, config: Config) -> [NSView] {
        Permissions.problems(config).filter { $0.pages.contains(page) }.map { problem in
            NoticeBanner(text: problem.text, button: problem.buttonTitle) { problem.request() }
        }
    }
}
