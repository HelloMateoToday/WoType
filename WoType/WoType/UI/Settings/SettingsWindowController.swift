//
//  SettingsWindowController.swift
//  WoType
//
//  设置窗口，照 screenshots/v1.mp4：左边是从上到下一整条实色侧边栏（搜索框、分组的彩色图标导航），
//  右边是固定在顶上的标题和说明，下面的内容可以滚动（滚动后标题下面出现分隔线）。
//
//  不用 NSSplitViewItem(sidebarWithViewController:)：macOS 26 上它是带圆角、内缩的玻璃侧边栏，
//  颜色和内容区对不上。
//
//  输入法进程平时是后台进程（LSBackgroundOnly），开窗口时临时切成普通 App 才能拿到键盘，
//  关窗口后切回去（和 fcitx5-macos 的做法一样）。
//

import Cocoa

/// 侧边栏里的一项。
struct SettingsSection {
    let id: String
    let title: String
    let symbol: String
    let color: NSColor
    /// 侧边栏里第几组（组之间空一段）。
    let group: Int
    /// 搜索时能匹配上的词（这一页里的设置项）。
    let keywords: [String]
    let makePage: () -> SettingsPage

    static let all: [SettingsSection] = [
        SettingsSection(id: "home", title: "功能介绍", symbol: "sparkles", color: .systemPink, group: 0,
                        keywords: ["功能", "演示", "整句", "纠错", "简拼", "快捷键"],
                        makePage: { HomePage() }),
        SettingsSection(id: "appearance", title: "候选外观", symbol: "paintpalette.fill", color: .systemCyan, group: 1,
                        keywords: ["皮肤", "外观", "预览", "候选", "拼音", "表情", "emoji"],
                        makePage: { AppearancePage() }),
        SettingsSection(id: "habits", title: "输入习惯", symbol: "keyboard.fill", color: .systemGray, group: 1,
                        keywords: ["shift", "中英", "大写", "标点", "顿号", "句号", "数字", "空格", "补全", "括号"],
                        makePage: { HabitsPage() }),
        SettingsSection(id: "engine", title: "拼音引擎", symbol: "cpu.fill", color: .systemIndigo, group: 1,
                        keywords: ["引擎", "水杉", "万象", "整句模型", "大模型", "小模型", "语法模型", "词库", "更新", "云候选", "Google", "联网"],
                        makePage: { EnginePage() }),
        SettingsSection(id: "pinyin", title: "拼音设置", symbol: "character.textbox", color: .systemBlue, group: 1,
                        keywords: ["模糊音", "纠错", "按错", "双拼", "小鹤", "自然码", "繁体", "颜文字", "符号", "拆字", "部件", "删词", "学错", "调频"],
                        makePage: { PinyinPage() }),
        SettingsSection(id: "words", title: "自定义词", symbol: "text.book.closed.fill", color: .systemOrange, group: 1,
                        keywords: ["自定义", "人名", "公司", "词库", "添加"],
                        makePage: { CustomWordsPage() }),
        SettingsSection(id: "phrases", title: "快捷短语", symbol: "text.quote", color: .systemGreen, group: 1,
                        keywords: ["快捷短语", "短语", "地址", "邮箱", "常用语", "编码"],
                        makePage: { QuickPhrasesPage() }),
        SettingsSection(id: "translate", title: "翻译设置", symbol: "character.bubble.fill", color: .systemBlue, group: 1,
                        keywords: ["翻译", "候选翻译", "划词", "选中", "替换", "快捷键", "AI", "智能方向", "语音翻译"],
                        makePage: { TranslatePage() }),
        SettingsSection(id: "voice", title: "语音输入", symbol: "mic.fill", color: .systemRed, group: 1,
                        keywords: ["语音", "说话", "fn", "option", "润色", "场景", "上下文", "提示音"],
                        makePage: { VoicePage() }),
        SettingsSection(id: "microphone", title: "录音设备", symbol: "mic.circle.fill", color: .systemOrange, group: 1,
                        keywords: ["麦克风", "输入设备", "增益", "音量", "距离"],
                        makePage: { MicrophonePage() }),
        SettingsSection(id: "models", title: "模型管理", symbol: "shippingbox.fill", color: .systemTeal, group: 1,
                        keywords: ["模型", "下载", "本机", "Qwen", "云端", "API", "密钥", "OpenAI", "Claude", "Anthropic", "Gemini", "DeepSeek", "OpenRouter"],
                        makePage: { ModelsPage() }),
        SettingsSection(id: "permissions", title: "系统权限", symbol: "lock.shield.fill", color: .systemGreen, group: 2,
                        keywords: ["权限", "麦克风", "辅助功能", "授权", "隐私"],
                        makePage: { PermissionsPage() }),
        SettingsSection(id: "about", title: "关于软件", symbol: "info", color: .systemGray, group: 2,
                        keywords: ["版本", "关于", "数据", "rime", "许可", "开源", "更新", "升级", "新版本"],
                        makePage: { AboutPage() }),
        SettingsSection(id: "onboarding", title: "新手引导", symbol: "figure.wave", color: .systemPurple, group: 2,
                        keywords: ["引导", "新手", "教程", "首次", "onboarding", "演示"],
                        makePage: { OnboardingPage() }),
    ]

    func matches(_ query: String) -> Bool {
        let q = query.lowercased()
        return title.lowercased().contains(q) || keywords.contains { $0.lowercased().contains(q) || q.contains($0.lowercased()) }
    }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    /// 设置窗口用到时才建，关掉就放掉（输入法进程常驻，不留着窗口和各页的界面对象，见 docs/07）。
    static var shared: SettingsWindowController {
        if let instance { return instance }
        let controller = SettingsWindowController()
        instance = controller
        return controller
    }
    private static var instance: SettingsWindowController?

    /// 设置窗口开着时是它，没开着是 nil（不会为了问一句话把窗口建出来）。
    static var visibleWindow: NSWindow? {
        guard let window = instance?.window, window.isVisible else { return nil }
        return window
    }

    static let sidebarWidth: CGFloat = 210

    private let sidebar = SettingsSidebar()
    private let header = SettingsHeader()
    private let pageContainer = NSView()
    private var page: SettingsPage?
    private var scrollObserver: NSObjectProtocol?

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "WoType 设置"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 700, height: 480)
        window.isReleasedWhenClosed = false
        window.backgroundColor = Theme.settingsBackground
        super.init(window: window)
        window.delegate = self
        window.contentView = makeContent()
        if !window.setFrameUsingName("WoTypeSettings") {
            window.center()
        }
        window.setFrameAutosaveName("WoTypeSettings")

        sidebar.onSelect = { [weak self] section in self?.show(section) }
        sidebar.select(id: SettingsSection.all[0].id)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func makeContent() -> NSView {
        let root = SettingsBackgroundView()
        let divider = SettingsDivider()
        for view in [sidebar, divider, header, pageContainer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: Self.sidebarWidth),

            divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            // 标题和窗口左上角的红绿灯在同一行
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            pageContainer.topAnchor.constraint(equalTo: header.bottomAnchor),
            pageContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            pageContainer.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            pageContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        return root
    }

    /// 打开设置窗口（可以指定先显示哪一页）。
    func open(page id: String? = nil) {
        if let id { sidebar.select(id: id) }
        // 后台进程拿不到键盘焦点：开窗口时切成辅助 App（.accessory）。不切成普通 App：那样 Dock 上会冒出 WoType 的图标，
        // 点它又按「再次打开」弹设置（2026-11-13 用户反馈）。辅助 App 没有 Dock 图标、不进 ⌘Tab，窗口照样能拿焦点打字，
        // 主菜单的 ⌘C ⌘V 也照常；窗口被挡住了从输入法菜单再打开
        if NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
        }
        Permissions.startWatching()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        // 别一打开就把焦点放在搜索框上
        window?.makeFirstResponder(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 页面里的链接（「打开“通用” ›」）用它跳转。
    func navigate(to id: String) {
        sidebar.select(id: id)
    }

    private func show(_ section: SettingsSection) {
        guard section.id != page?.sectionID else { return }
        page?.view.removeFromSuperview()
        page?.removeFromParent()
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }

        let page = section.makePage()
        page.sectionID = section.id
        self.page = page
        header.set(title: page.pageTitle, subtitle: page.pageSubtitle)
        header.showsDivider = false
        page.view.translatesAutoresizingMaskIntoConstraints = false
        pageContainer.addSubview(page.view)
        NSLayoutConstraint.activate([
            page.view.topAnchor.constraint(equalTo: pageContainer.topAnchor),
            page.view.bottomAnchor.constraint(equalTo: pageContainer.bottomAnchor),
            page.view.leadingAnchor.constraint(equalTo: pageContainer.leadingAnchor),
            page.view.trailingAnchor.constraint(equalTo: pageContainer.trailingAnchor),
        ])
        // 内容滚到标题下面时，标题下面出现分隔线
        let clip = page.scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                self?.header.showsDivider = clip.bounds.minY > 1
            }
    }

    /// 切回设置窗口时马上查一次权限（从系统设置授权完回来）
    func windowDidBecomeKey(_ notification: Notification) {
        Permissions.check()
    }

    func windowWillClose(_ notification: Notification) {
        Permissions.stopWatching()
        // 切回后台进程：没有 Dock 图标、不出现在 ⌘Tab 里（引导窗口也关了才切）
        if OnboardingWindowController.visibleWindow == nil {
            NSApp.setActivationPolicy(.prohibited)
        }
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
        // 等这次关闭走完再放掉窗口和页面；下次打开重新建（窗口位置系统按名字记着）
        DispatchQueue.main.async {
            if Self.instance === self, self.window?.isVisible != true {
                self.page?.view.removeFromSuperview()
                self.page = nil
                self.window?.contentView = nil
                self.window?.delegate = nil
                Self.instance = nil
            }
        }
    }
}

/// 窗口底色（内容区的浅灰）。
final class SettingsBackgroundView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.settingsBackground.cgColor
    }
}

/// 侧边栏和内容区之间的竖线。
final class SettingsDivider: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.settingsDivider.cgColor
    }
}

// MARK: - 标题

/// 右边顶上固定的标题和说明，和红绿灯在同一行；拖它可以移动窗口。
final class SettingsHeader: NSView {

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let line = SeparatorLine()

    var showsDivider = false {
        didSet { line.isHidden = !showsDivider }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        titleLabel.font = .systemFont(ofSize: 17, weight: .bold)
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        for view in [titleLabel, subtitleLabel, line] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        line.isHidden = true
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 64),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsKit.contentInset + 2),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -SettingsKit.contentInset),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func set(title: String, subtitle: String) {
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
    }

    override var mouseDownCanMoveWindow: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.settingsBackground.cgColor
    }
}

// MARK: - 侧边栏

final class SettingsSidebar: NSView, NSSearchFieldDelegate {

    var onSelect: ((SettingsSection) -> Void)?

    private let searchField = NSSearchField()
    private let list = NSStackView()
    private var items: [SidebarItem] = []
    private var observers: [NSObjectProtocol] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        searchField.placeholderString = "搜索设置"
        searchField.controlSize = .large
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        list.translatesAutoresizingMaskIntoConstraints = false

        var lastGroup = SettingsSection.all.first?.group
        for section in SettingsSection.all {
            if section.group != lastGroup, let last = items.last {
                list.setCustomSpacing(18, after: last)
            }
            lastGroup = section.group
            let item = SidebarItem(section: section)
            item.onClick = { [weak self] in self?.select(id: section.id) }
            items.append(item)
            list.addArrangedSubview(item)
            item.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }

        addSubview(searchField)
        addSubview(list)
        NSLayoutConstraint.activate([
            // 红绿灯下面
            searchField.topAnchor.constraint(equalTo: topAnchor, constant: 44),
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            list.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 14),
            list.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            list.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
        // 开着的功能缺了权限：「系统权限」旁边一个红点
        updateBadges()
        observers = [Settings.didChange, Permissions.didChange].map {
            NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateBadges() }
            }
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private func updateBadges() {
        let missing = !Permissions.problems(Settings.shared.config).isEmpty
        items.first { $0.section.id == "permissions" }?.showsBadge = missing
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var mouseDownCanMoveWindow: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.settingsSidebar.cgColor
    }

    func select(id: String) {
        guard let item = items.first(where: { $0.section.id == id }) else { return }
        for other in items { other.isSelected = other === item }
        onSelect?(item.section)
    }

    /// 搜索：只留能匹配上的页，并打开第一个。
    func controlTextDidChange(_ notification: Notification) {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        var first: SidebarItem?
        for item in items {
            let match = query.isEmpty || item.section.matches(query)
            item.isHidden = !match
            if match, first == nil { first = item }
        }
        if !query.isEmpty, let first { select(id: first.section.id) }
    }
}

/// 侧边栏的一项：图标 + 名字，选中时灰色圆角底（文字不变色，照 v1.mp4）。
final class SidebarItem: NSView {

    let section: SettingsSection
    var onClick: (() -> Void)?
    var isSelected = false {
        didSet { needsDisplay = true }
    }
    /// 名字右边的红点（要处理的事）
    var showsBadge = false {
        didSet { badge.isHidden = !showsBadge }
    }
    private let badge = NSView()

    init(section: SettingsSection) {
        self.section = section
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let icon = SettingsIcon(symbol: section.symbol, color: section.color)
        let label = NSTextField(labelWithString: section.title)
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.systemRed.cgColor
        badge.layer?.cornerRadius = 4
        badge.isHidden = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 8),
            badge.heightAnchor.constraint(equalToConstant: 8),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        Theme.settingsSidebarSelection.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }

    /// 侧边栏能拖着移动窗口，但这一项不能：拖窗口的点击松开时窗口会被提到最前，盖住刚打开的引导窗口
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}
