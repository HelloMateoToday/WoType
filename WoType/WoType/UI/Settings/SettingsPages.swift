//
//  SettingsPages.swift
//  WoType
//
//  设置窗口右边的各页。标题和说明由窗口固定在顶上（SettingsHeader），页面只管下面能滚动的内容。
//  文案沿用 WowType 在 Linux 上的设置界面。改了设置立即生效（Settings.update）；
//  设置变了整页重画，保证显示和配置一致。
//

import Cocoa
import FreeTranslate

/// 一页设置：可以上下滚动的一列内容。
class SettingsPage: NSViewController {

    /// 窗口顶上显示的标题和说明。
    var pageTitle: String { "" }
    var pageSubtitle: String { "" }
    /// 对应侧边栏的哪一项。
    var sectionID = ""

    private let stack = NSStackView()
    private var observers: [NSObjectProtocol] = []

    /// 子类返回这一页的全部内容（从上到下）。
    func build() -> [NSView] { [] }

    /// 设置变了是否整页重画（有输入框的页自己管刷新）。
    var rebuildsOnChange: Bool { true }

    /// 固定在页面最上面、不跟着滚动的内容（首页的演示卡片：往下指功能时也看得到演示）。
    var pinnedView: NSView? { nil }

    /// 页面的滚动区域（窗口据此在内容滚到标题下面时画分隔线）。
    let scrollView = OverlayScrollView()

    override func loadView() {
        let scroll = scrollView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 6, left: SettingsKit.contentInset,
                                        bottom: SettingsKit.contentInset, right: SettingsKit.contentInset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        if let pinned = pinnedView {
            let container = NSView()
            for item in [pinned, scroll] {
                item.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(item)
            }
            NSLayoutConstraint.activate([
                pinned.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
                pinned.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: SettingsKit.contentInset),
                pinned.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -SettingsKit.contentInset),
                scroll.topAnchor.constraint(equalTo: pinned.bottomAnchor, constant: 10),
                scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            view = container
        } else {
            view = scroll
        }
        reload()
        // 权限变了也重画：顶上的提醒、「系统权限」页的状态跟着变
        if rebuildsOnChange {
            observers = [Settings.didChange, Permissions.didChange].map {
                NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in self?.reload() }
            }
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func reload() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, item) in build().enumerated() {
            // 分组标题和上一张卡片之间多空一点
            if i > 0, item is NSTextField || item is SectionHeader, let last = stack.arrangedSubviews.last {
                stack.setCustomSpacing(26, after: last)
            }
            stack.addArrangedSubview(item)
            if item is CardView || item is SectionHeader || item is WrappingLabel || item is NoticeBanner {
                item.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                            constant: -SettingsKit.contentInset * 2).isActive = true
            }
        }
    }

    var config: Config { Settings.shared.config }

    func update(_ change: (inout Config) -> Void) { Settings.shared.update(change) }
}

/// 滚动条一直用 macOS 的悬浮样式（细的、滚动时才出来），不管接没接鼠标：
/// 系统设置的「显示滚动条」是「自动」时，接着鼠标 AppKit 会换成一直显示、带轨道的粗滚动条，样式变了还会再设一遍，这里都改回悬浮
final class OverlayScrollView: NSScrollView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        super.scrollerStyle = .overlay
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 分组标题右边带一个控件（比如搜索框）。
final class SectionHeader: NSView {
    init(title: String, accessory: NSView) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let label = SettingsKit.sectionTitle(title)
        for view in [label, accessory] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            accessory.trailingAnchor.constraint(equalTo: trailingAnchor),
            accessory.topAnchor.constraint(equalTo: topAnchor),
            accessory.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - 皮肤预览

/// 皮肤预览：文本框里打着拼音，下面是用当前皮肤画的候选窗。外观可以单独切成亮色 / 暗色 / 跟系统，
/// 不用改系统设置就能看两种模式下的样子（只影响预览）。
final class SkinPreview: NSView {

    enum Mode: Int { case light, dark, system }

    var mode = Mode.system {
        didSet {
            switch mode {
            case .light: appearance = NSAppearance(named: .aqua)
            case .dark: appearance = NSAppearance(named: .darkAqua)
            case .system: appearance = nil
            }
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 112) }

    override func draw(_ dirtyRect: NSRect) {
        // 动态色按这个视图的外观取：切到暗色时整块预览（连底板）都是暗色
        let palette = Theme.palette
        Theme.settingsArt.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()

        // 文本框：已上屏的字 + 带下划线的拼音 + 光标
        let field = NSRect(x: 14, y: 14, width: bounds.width - 28, height: 30)
        Theme.settingsCard.setFill()
        NSBezierPath(roundedRect: field, xRadius: 6, yRadius: 6).fill()
        let typed = NSMutableAttributedString(string: "今天", attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor,
        ])
        typed.append(NSAttributedString(string: "ni'hao", attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]))
        let typedSize = typed.size()
        typed.draw(at: NSPoint(x: field.minX + 10, y: field.midY - typedSize.height / 2))
        NSColor.controlAccentColor.setFill()
        NSRect(x: field.minX + 11 + typedSize.width, y: field.midY - 8, width: 1.5, height: 16).fill()

        // 候选窗：和真的一样的字号、配色、圆角
        let candidateFont = Theme.candidateFont
        let labelFont = Theme.labelFont
        var cells: [(NSAttributedString, NSAttributedString, NSRect)] = []
        var x: CGFloat = 4
        let rowHeight = ceil(candidateFont.ascender - candidateFont.descender + candidateFont.leading) + 8
        let maxWidth = field.width - 8
        for (i, word) in ["你好", "拟", "泥", "你", "逆", "腻", "妮"].enumerated() {
            let selected = i == 0
            let label = NSAttributedString(string: "\(i + 1)", attributes: [
                .font: labelFont,
                .foregroundColor: selected ? palette.highlightText.withAlphaComponent(0.85) : palette.secondaryText,
            ])
            let text = NSAttributedString(string: word, attributes: [
                .font: candidateFont, .foregroundColor: selected ? palette.highlightText : palette.text,
            ])
            let width = ceil(label.size().width) + 5 + ceil(text.size().width) + 16
            guard x + width <= maxWidth - 4 else { break }
            cells.append((label, text, NSRect(x: x, y: 4, width: width, height: rowHeight)))
            x += width + 2
        }
        let panel = NSRect(x: field.minX, y: field.maxY + 8, width: x + 2, height: rowHeight + 8)
        let outline = NSBezierPath(roundedRect: panel, xRadius: Theme.cornerRadius, yRadius: Theme.cornerRadius)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = Theme.panelShadow
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        palette.background.setFill()
        outline.fill()
        NSGraphicsContext.restoreGraphicsState()
        palette.border.setStroke()
        let border = NSBezierPath(roundedRect: panel.insetBy(dx: 0.5, dy: 0.5),
                                  xRadius: Theme.cornerRadius, yRadius: Theme.cornerRadius)
        border.lineWidth = 1
        border.stroke()

        for (i, (label, text, rect)) in cells.enumerated() {
            let cell = rect.offsetBy(dx: panel.minX, dy: panel.minY)
            if i == 0 {
                palette.highlight.setFill()
                NSBezierPath(roundedRect: cell, xRadius: Theme.highlightRadius, yRadius: Theme.highlightRadius).fill()
            }
            // 序号和候选文字底部对齐（和候选窗一样按基线）
            let textY = cell.midY - text.size().height / 2
            label.draw(at: NSPoint(x: cell.minX + 8, y: textY + candidateFont.ascender - labelFont.ascender))
            text.draw(at: NSPoint(x: cell.minX + 8 + ceil(label.size().width) + 5, y: textY))
        }
    }
}

// MARK: - 一行开关

extension SettingsPage {
    /// 一行开关。
    func switchRow(_ title: String, _ detail: String?, _ key: WritableKeyPath<Config, Bool>,
                   _ symbol: String, _ color: NSColor, help: String? = nil) -> NSView {
        SettingsKit.row(title: title, detail: detail, help: help, icon: SettingsIcon(symbol: symbol, color: color),
                        accessory: SettingSwitch(isOn: config[keyPath: key]) { [weak self] on in
                            self?.update { $0[keyPath: key] = on }
                        })
    }

    /// 卡片下面的一句小字说明。
    func footnote(_ text: String) -> NSView {
        SettingsKit.wrappingLabel(text, size: 11.5, color: .secondaryLabelColor)
    }
}

// MARK: - 候选外观

final class AppearancePage: SettingsPage {
    override var pageTitle: String { "候选外观" }
    override var pageSubtitle: String { "候选窗的皮肤和显示内容。" }

    override func build() -> [NSView] {
        let skins = Skin.allCases
        let skinRow = SettingsKit.row(
            title: "皮肤", detail: "候选窗的配色，跟着系统浅色、深色模式变。",
            help: "macOS 经典照鼠须管的「Mac 仿原生」皮肤（作者一方）。",
            icon: SettingsIcon(symbol: "paintpalette.fill", color: .systemCyan),
            accessory: SettingPopUp(items: skins.map(\.title), selected: skins.firstIndex(of: config.skin) ?? 0) {
                [weak self] index in self?.update { $0.skin = skins[index] }
            })
        return [
            SettingsKit.sectionTitle("皮肤"),
            SettingsKit.card([skinRow, skinPreviewRow()]),
            SettingsKit.sectionTitle("候选窗"),
            SettingsKit.card([
                switchRow("显示拼音", "在候选词上方显示正在打的拼音。", \.showPinyinInPanel,
                          "character.cursor.ibeam", .systemIndigo),
                switchRow("推荐表情", "打「开心」时候选里带上 😄。", \.emojiSuggest,
                          "face.smiling.inverse", .systemYellow),
            ]),
        ]
    }
}

extension AppearancePage {
    /// 预览外观（亮色 / 暗色 / 系统）：换皮肤时页面会重建，记在这里才不会跳回「系统」
    private static var previewMode = SkinPreview.Mode.system

    /// 皮肤预览：上面一行标题和亮色 / 暗色 / 系统的切换，下面是预览图（从文字的左边缘开始）。
    func skinPreviewRow() -> NSView {
        let preview = SkinPreview()
        preview.mode = Self.previewMode
        let segments = SettingSegments(labels: ["亮色", "暗色", "系统"], selected: Self.previewMode.rawValue) { index in
            Self.previewMode = SkinPreview.Mode(rawValue: index) ?? .system
            preview.mode = Self.previewMode
        }
        let header = SettingsKit.row(title: "预览", detail: "不改系统设置，看看浅色、深色模式下的样子。",
                                     icon: SettingsIcon(symbol: "eye.fill", color: .systemGray), accessory: segments)
        let row = NSView()
        for view in [header, preview] {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: row.topAnchor),
            header.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            preview.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
            preview.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: SettingsKit.textInset),
            preview.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -SettingsKit.rowInset),
            preview.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -14),
        ])
        return row
    }
}

// MARK: - 输入习惯

final class HabitsPage: SettingsPage {
    override var pageTitle: String { "输入习惯" }
    override var pageSubtitle: String { "中英切换、标点和空格。" }

    override func build() -> [NSView] {
        // 万象里 / 是功能前缀（/sj 时间、/sym 符号，docs/22），按 / 输入顿号不起作用
        let wanxiang = config.pinyinEngine == "wanxiang"
        let slash = switchRow("按 / 输入顿号", wanxiang ? "万象里 / 用来打 /sj 时间、/sym 符号，这一项不起作用。" : "按 / 输入「、」。",
                              \.slashDunhao, "ellipsis", .systemOrange)
        if wanxiang { SettingsKit.setInactive(slash) }
        return [
            SettingsKit.sectionTitle("中英切换"),
            SettingsKit.card([
                SettingsKit.row(title: "切换中英文", detail: "单按 ⇧，已输入的字母原样上屏。",
                                help: "打拼音到一半时按 ⇧，已输入的字母原样上屏，然后切到英文。",
                                icon: SettingsIcon(symbol: "arrow.left.arrow.right", color: .systemGray),
                                accessory: KeyBadge("⇧")),
                SettingsKit.row(title: "大写字母", detail: "打开大写锁定后直接输入大写。",
                                icon: SettingsIcon(symbol: "capslock.fill", color: .systemGray),
                                accessory: KeyBadge("⇪")),
            ]),
            SettingsKit.sectionTitle("标点和空格"),
            SettingsKit.card([
                switchRow("数字后用英文标点", "12:00、3.14、2024/1/1 保持原样。", \.asciiPunctAfterDigit,
                          "number", .systemGreen),
                slash,
                switchRow("符号自动补全", "输入左括号、左引号时自动补上右半边。", \.autoPair, "parentheses", .systemPurple,
                          help: "（【《“‘ 都会补上右半边，打完里面的字一起送出。"),
                switchRow("中英文之间加空格", "中文和英文、数字之间自动加一个空格。", \.spaceCJKLatin, "space", .systemTeal,
                          help: "比如「用 GitHub 管理代码，共 3 个」。"),
            ]),
        ]
    }
}

// MARK: - 拼音

final class PinyinPage: SettingsPage {
    override var pageTitle: String { "拼音设置" }
    override var pageSubtitle: String {
        "跟着当前引擎（\(config.pinyinEngine == "wanxiang" ? "万象" : "水杉")）走，两个引擎分开记。"
    }

    override func build() -> [NSView] {
        let wanxiang = config.pinyinEngine == "wanxiang"
        let switchEngine = LinkButton(title: "切换引擎 ›") { SettingsWindowController.shared.navigate(to: "engine") }
        return [
            SectionHeader(title: "输入方式", accessory: switchEngine),
            SettingsKit.card([
                shuangpinRow(wanxiang: wanxiang),
                switchRow("繁体字", "候选词转成繁体（按字转换）。", \.traditional, "character", .systemBrown),
            ]),
            SettingsKit.sectionTitle("纠错和模糊音"),
            SettingsKit.card([
                wanxiang
                    ? switchRow("按错键自动纠正", "zhognguo 也能打出「中国」，整句会没有关着准。", \.wanxiangTypoCorrection,
                                "wand.and.stars", .systemPurple,
                                help: "万象的纠错：按成相邻的键、两个键按反，也能认出你想打的拼音。\n\n"
                                    + "代价是整句首选准确率低一些、打字稍慢，所以默认关。")
                    : switchRow("按错键自动纠正", "zhognguo 也能打出「中国」。", \.typoCorrection, "wand.and.stars", .systemPurple,
                                help: "按成相邻的键、两个键按反、多按或漏按一个键，都能认出你想打的拼音。"),
                SettingsKit.row(title: "模糊音", detail: fuzzySummary(config.pinyinEngine),
                                help: "分不清的两个音当成一样的：开了 z = zh，打 zidao 也能出「知道」。\n\n"
                                    + "水杉有 11 条规则，万象有 10 条；两个引擎开的规则分开记，这里改的是当前引擎的。",
                                icon: SettingsIcon(symbol: "ear.fill", color: .systemTeal),
                                accessory: SettingButton(title: "设置…") { [weak self] in
                                    guard let window = self?.view.window else { return }
                                    FuzzyRulesSheet.present(on: window)
                                }),
            ]),
        ] + (wanxiang ? [
            SettingsKit.sectionTitle("学到的词"),
            SettingsKit.card([
                SettingsKit.row(title: "删掉学错的词", detail: "右上角带小圆点的是学出来的词：用 ← → 高亮它，按 ⇧⌫ 删掉。",
                                help: "万象会记住你选过的词，常用的排到前面。一串拼音分几段选（比如 tijiao 先选「提价」再选「哦」），"
                                    + "会记成一个新词「提价哦」，下次排在「提交」前面。\n\n"
                                    + "这种词库里没有、纯学出来的词，候选右上角有个小圆点。按 ⇧⌫（或 ⇧⌦）删掉高亮的这个词，以后就不再出现。\n\n"
                                    + "没有小圆点的是词库里本来就有的词：按 ⇧⌫ 只是把学到的排位清掉，词还在原来的位置。",
                                icon: SettingsIcon(symbol: "delete.backward.fill", color: .systemRed)),
            ]),
        ] : [
            // 万象的 v 加数字是旧引擎的，librime 版用万象自己的 R1234（docs/22），没有专属设置
            SettingsKit.sectionTitle("水杉专属"),
            SettingsKit.card(msimeRows()),
        ])
    }

    /// 双拼：「关闭」加上支持的方案，一个下拉框（配置里还是开关 + 方案两项）。两个引擎都支持这 4 种，共用一份设置
    private func shuangpinRow(wanxiang: Bool) -> NSView {
        let profiles = Self.shuangpinProfiles
        let selected = !config.shuangpin ? 0 : (profiles.firstIndex { $0.0 == config.shuangpinProfile } ?? 0) + 1
        let popUp = SettingPopUp(items: ["关闭"] + profiles.map(\.1), selected: selected) { [weak self] index in
            self?.update { config in
                config.shuangpin = index > 0
                if index > 0 { config.shuangpinProfile = profiles[index - 1].0 }
            }
        }
        return SettingsKit.row(title: "双拼", detail: "用双拼方案打字。",
                               icon: SettingsIcon(symbol: "keyboard.fill", color: .systemIndigo), accessory: popUp)
    }

    /// 水杉才有的：搜表情和符号、拆字。
    private func msimeRows() -> [NSView] {
        [
            SettingsKit.row(title: "搜表情和符号", detail: "⇧E 表情、⇧M 颜文字、⇧S 符号。",
                            help: "先按 ⇧E（或 ⇧M、⇧S），再打拼音搜索，比如 ⇧E 后打 kaixin 找 😄。",
                            icon: SettingsIcon(symbol: "square.grid.2x2.fill", color: .systemPink),
                            accessory: KeyBadge("⇧E")),
            switchRow("拆字", "按 ⇧C 再打部件的拼音，找不认识的字。", \.chaizi, "square.split.2x1.fill", .systemBrown,
                      help: "按 ⇧C 再打各部件的拼音，比如 mumu 找「林」「相」。\n\n"
                          + "开着时，打大写 C 开头的英文也会进入拆字，打完按 ⏎ 原样上屏。"),
        ]
    }
}

extension PinyinPage {
    /// 双拼方案：水杉的 shuangpin_profile 和设置里显示的名字（照水杉的设置页）
    static let shuangpinProfiles = [("xiaohe", "小鹤"), ("ziranma", "自然码"), ("microsoft", "微软"), ("shoudao", "首道")]

    /// 模糊音那一行的说明：这个引擎开了哪些。
    func fuzzySummary(_ engine: String) -> String {
        let rules = config[keyPath: Config.fuzzyRulesKey(for: engine)]
        if rules.isEmpty { return "没有开启。开了 z = zh，zidao 也能打出「知道」。" }
        let shown = rules.prefix(4).map { $0.replacingOccurrences(of: "=", with: " = ") }.joined(separator: "、")
        return rules.count > 4 ? "已开启 \(rules.count) 项：\(shown) 等" : "已开启：\(shown)"
    }
}

// MARK: - 语音

final class VoicePage: SettingsPage {
    override var pageTitle: String { "语音输入" }
    override var pageSubtitle: String { "按住语音键说话，松开就上屏。" }

    private var modelObserver: NSObjectProtocol?
    private var cloudObserver: NSObjectProtocol?
    private var speechObserver: NSObjectProtocol?

    override func viewDidLoad() {
        super.viewDidLoad()
        // 润色模型装好了、云端模型变了：刷新润色那一行的状态
        modelObserver = NotificationCenter.default.addObserver(
            forName: VoiceModels.didChange, object: nil, queue: .main) { [weak self] _ in self?.reload() }
        cloudObserver = NotificationCenter.default.addObserver(
            forName: CloudPolish.didChange, object: nil, queue: .main) { [weak self] _ in self?.reload() }
        speechObserver = NotificationCenter.default.addObserver(
            forName: CloudSpeech.didChange, object: nil, queue: .main) { [weak self] _ in self?.reload() }
        VoiceModels.shared.refresh()
    }

    deinit {
        if let modelObserver { NotificationCenter.default.removeObserver(modelObserver) }
        if let cloudObserver { NotificationCenter.default.removeObserver(cloudObserver) }
        if let speechObserver { NotificationCenter.default.removeObserver(speechObserver) }
    }

    override func build() -> [NSView] {
        let keyPopUp = SettingPopUp(items: VoiceKey.allCases.map(\.title),
                                    selected: VoiceKey.allCases.firstIndex(of: config.voiceKey) ?? 0) {
            [weak self] index in self?.update { $0.voiceKey = VoiceKey.allCases[index] }
        }
        keyPopUp.isEnabled = config.voice
        // 翻译键占着的那个不能选（Arion：「此快捷键已用于语音翻译，请使用其他快捷键」）
        Self.disable(keyPopUp, key: config.voiceTranslateKey, note: "已用于语音翻译")
        var inputRows: [NSView] = [
            switchRow("语音输入", Self.recognitionSummary(config.voiceRecognizer) + "说话时按 Esc 取消。",
                      \.voice, "mic.fill", .systemRed),
            SettingsKit.row(title: "语音键", detail: "按住说话，松开输入。",
                            help: "按住说话，松开即输入。\n点一下开始持续听写，再点一下结束。\n说话时按 Esc 取消。",
                            icon: SettingsIcon(symbol: "globe", color: .systemGray),
                            accessory: keyPopUp),
        ]
        if config.voiceKey == .fn, let warning = Self.fnWarning() {
            inputRows.append(SettingsKit.row(
                title: "🌐 fn 键会被系统先用掉", detail: "把「按下 🌐 键时」改成「不执行任何操作」。", help: warning,
                icon: SettingsIcon(symbol: "exclamationmark.triangle.fill", color: .systemRed),
                accessory: SettingButton(title: "打开键盘设置") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                }))
        }
        inputRows.append(switchRow("提示音", "开始和结束时播放提示音。", \.voiceSound, "speaker.wave.2.fill", .systemPink))
        return NoticeBanner.banners(page: "voice", config: config) + [
            SettingsKit.sectionTitle("语音键"),
            SettingsKit.card(inputRows),
            SettingsKit.sectionTitle("识别"),
            SettingsKit.card([recognitionRow()]),
            SettingsKit.sectionTitle("润色"),
            SettingsKit.card(polishRows()),
            SettingsKit.sectionTitle("润色参考"),
            SettingsKit.card(contextRows()),
            footnote("只在润色时参考，用完就丢，不保存。"),
        ]
    }

    /// 识别方式（docs/21）：本机、添加的云端识别，或某个体验渠道。体验渠道第一次选时先弹说明。
    private func recognitionRow() -> NSView {
        let choice = config.voiceRecognizer
        let popUp = ActionPopUp()
        popUp.add(VoiceModelSpec.asr.title, selected: choice == .local) { [weak self] in
            self?.update { $0.voiceRecognizer = .local }
        }
        popUp.addSeparator()
        popUp.addHeader("云端识别")
        for model in CloudSpeech.shared.models {
            popUp.add(model.title, selected: choice == .cloud(model.id)) { [weak self] in
                self?.update { $0.voiceRecognizer = .cloud(model.id) }
            }
        }
        popUp.add("添加云端识别…") {
            // 下拉框先收起、这一页还原，再跳过去（跳走时这一页会被拿掉）
            DispatchQueue.main.async { CloudSpeechSheet.presentAdding() }
        }
        popUp.addSeparator()
        popUp.addHeader("体验（随时失效）")
        for channel in TrialChannel.allCases {
            popUp.add(channel.title, selected: choice == .trial(channel)) { [weak self] in self?.pickTrial(channel) }
        }
        popUp.isEnabled = config.voice
        let status: String
        switch choice {
        case .local:
            status = VoiceService.modelReady ? "在本机识别，录音不上传 · 已就绪 ✓" : "先在「模型管理」里下载本机模型。"
        case .cloud(let id):
            if let model = CloudSpeech.shared.model(id: id) {
                status = CloudSpeech.shared.apiKey(model) == nil ? "找不到密钥，请在「模型管理」里编辑它"
                    : "录音会发到 \(model.provider.title)，"
                        + (model.language.isEmpty ? "自动判断语言。" : "识别\(model.spokenLanguage.title)。") + model.provider.summary
            } else {
                status = "这个云端识别已经删掉了"
            }
        case .trial(let channel):
            status = "仅供体验，随时失效。录音会发到\(channel.vendor)的服务器。"
        }
        return SettingsKit.row(
            title: "识别方式", detail: status,
            help: "本机：用「模型管理」里的本机模型，离线，录音不上传。\n\n"
                + "云端识别：用你自己的 API 密钥调服务商的官方接口（在「模型管理」里添加），录音会发给服务商。\n\n"
                + "体验渠道：调用输入法客户端的内部识别接口，不是官方开放接口，仅供体验，随时可能失效；录音会发到对应厂商。"
                + "识别失败时，如果本机模型已下载，会改用本机识别这次的录音。",
            icon: SettingsIcon(symbol: "waveform", color: .systemIndigo),
            accessory: popUp)
    }

    /// 选体验渠道：没同意过的先弹说明，取消就不换（下拉框还原）。
    private func pickTrial(_ channel: TrialChannel) {
        guard !config.voiceTrialAccepted.contains(channel.rawValue) else {
            update { $0.voiceRecognizer = .trial(channel) }
            return
        }
        guard let window = view.window else { return reload() }
        let alert = NSAlert()
        alert.messageText = "用「\(channel.title)」识别？"
        alert.informativeText = "这是体验渠道：调用\(channel.title)客户端的内部识别接口，不是官方开放接口，"
            + "仅供体验，随时可能失效。\n\n说话的录音会发到\(channel.vendor)的服务器。"
            + "识别失败时，如果本机模型已下载，会改用本机识别这次的录音。"
        alert.addButton(withTitle: "使用")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .alertFirstButtonReturn else { return self.reload() }
            self.update { config in
                config.voiceTrialAccepted.append(channel.rawValue)
                config.voiceRecognizer = .trial(channel)
            }
        }
    }

    /// 「语音输入」那一行的说明：在哪儿识别。
    static func recognitionSummary(_ choice: VoiceRecognizer) -> String {
        switch choice {
        case .local: "在本机识别，录音不上传。"
        case .cloud(let id): "用\(CloudSpeech.shared.model(id: id)?.provider.title ?? "云端")识别，录音会上传。"
        case .trial(let channel): "用\(channel.title)识别（体验），录音会上传。"
        }
    }

    /// 润色（照 Arion 的 polish/choice.go 的三选一）：一个下拉框选不润色、本机，或者添加的某个云端模型，
    /// 说明里是这个选项的状态。再下面是场景。
    private func polishRows() -> [NSView] {
        let polishing = config.voicePolish
        let engine = config.voicePolishEngine
        let popUp = ActionPopUp()
        popUp.add("不润色", selected: !polishing) { [weak self] in self?.update { $0.voicePolish = false } }
        popUp.add(VoiceModelSpec.polish.title, selected: polishing && engine == .local) { [weak self] in
            self?.update { config in
                config.voicePolish = true
                config.voicePolishEngine = .local
            }
        }
        Self.addCloudModels(to: popUp, selected: polishing && engine == .cloud ? config.voicePolishCloudModel : nil) {
            [weak self] model in
            self?.update { config in
                config.voicePolish = true
                config.voicePolishEngine = .cloud
                config.voicePolishCloudModel = model.id
            }
        }
        popUp.isEnabled = config.voice
        let status = !polishing ? "按识别结果原样输入。"
            : engine == .local ? Self.localStatus("在本机整理文字") : Self.cloudStatus(.polish)
        var rows: [NSView] = [
            SettingsKit.row(title: "润色", detail: status,
                            help: "自动清理语气词、重复和口头改口。\n\n本机：用「模型管理」里的本机模型，离线。\n"
                                + "云端模型：用你在「模型管理」里添加的模型，润色和翻译可以选不同的。",
                            icon: SettingsIcon(symbol: "sparkles", color: .systemPurple),
                            accessory: popUp),
            SettingsKit.row(title: "场景", detail: "按当前应用自动排版。",
                            help: "邮件分出称呼和落款，搜索框不加句号，编程工具按指令整理，其他应用按日常输入。\n\n"
                                + "要给某个应用指定场景，在那个应用里点菜单栏的输入法图标 › 润色场景。指定过的应用列在下面。",
                            icon: SettingsIcon(symbol: "square.grid.2x2.fill", color: .systemBlue)),
        ]
        rows += sceneOverrideRows()
        return rows
    }

    /// 下拉框后面接上添加的云端模型（「供应商 · 模型」，不带图标），最后是「添加云端模型…」（打开模型管理页的添加窗口）。
    static func addCloudModels(to popUp: ActionPopUp, selected: String?, onPick: @escaping (CloudModel) -> Void) {
        let models = CloudPolish.shared.models
        if !models.isEmpty {
            popUp.addSeparator()
            for model in models {
                popUp.add(model.title, selected: model.id == selected) { onPick(model) }
            }
        }
        popUp.addSeparator()
        popUp.add("添加云端模型…") {
            // 下拉框先收起、这一页还原，再跳过去（跳走时这一页会被拿掉）
            DispatchQueue.main.async { CloudModelSheet.presentAdding() }
        }
    }

    /// 本机模型的状态：润色模型装没装好。
    static func localStatus(_ ready: String) -> String {
        VoiceService.polishReady ? ready + " · 已就绪 ✓" : "先在「模型管理」里下载本机模型（约 1.7 GB）。"
    }

    /// 云端模型的状态：选的模型还在不在、密钥在不在。
    static func cloudStatus(_ use: CloudUse) -> String {
        let cloud = CloudPolish.shared
        guard let model = cloud.model(for: use) else { return "还没选云端模型" }
        guard cloud.apiKey(model) != nil else { return "找不到密钥，请在「模型管理」里编辑它" }
        return "用 " + model.provider.title + " 的云端模型"
    }

    /// 下拉框里另一个功能占着的键不能选，标上用途。
    static func disable(_ popUp: NSPopUpButton, key: VoiceKey?, note: String) {
        guard let key, let index = VoiceKey.allCases.firstIndex(of: key), let item = popUp.item(at: index) else { return }
        popUp.autoenablesItems = false
        item.isEnabled = false
        item.title = key.title + "（" + note + "）"
    }

    /// 指定过场景的应用：图标、名字、场景下拉框（最后一项「改回自动」移除指定）。
    private func sceneOverrideRows() -> [NSView] {
        let overrides = config.voiceSceneOverrides.compactMap { key, value -> (key: String, app: String, search: Bool, scene: VoiceScene)? in
            guard let scene = VoiceScene(name: value) else { return nil }
            let search = key.hasPrefix("search@")
            return (key, search ? String(key.dropFirst("search@".count)) : key, search, scene)
        }.sorted { InputController.appName($0.app) < InputController.appName($1.app) }
        return overrides.map { entry in
            let icon = NSImageView(image: NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.app)
                .map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!)
            icon.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 22), icon.heightAnchor.constraint(equalToConstant: 22)])
            let popUp = ActionPopUp()
            for scene in VoiceScene.all {
                popUp.add(scene.title, selected: scene == entry.scene) { [weak self] in
                    self?.update { $0.voiceSceneOverrides[entry.key] = scene.name }
                }
            }
            popUp.addSeparator()
            popUp.add("改回自动") { [weak self] in self?.update { $0.voiceSceneOverrides[entry.key] = nil } }
            let name = InputController.appName(entry.app) + (entry.search ? "（搜索框）" : "")
            return SettingsKit.row(title: name, icon: icon, accessory: popUp)
        }
    }

    /// 润色参考（照 Arion 的 context 设置；WoType 默认都关）。缺辅助功能权限时页面顶上提醒。
    private func contextRows() -> [NSView] {
        let polishing = config.voice && config.voicePolish && VoiceService.polishReady
        func toggle(_ key: WritableKeyPath<Config, Bool>, onChange: ((Bool) -> Void)? = nil) -> SettingSwitch {
            let control = SettingSwitch(isOn: config[keyPath: key]) { [weak self] on in
                self?.update { $0[keyPath: key] = on }
                onChange?(on)
            }
            control.isEnabled = polishing
            return control
        }
        return [
            SettingsKit.row(title: "光标前后的文字", detail: "准确写出人名、术语，衔接上下文。",
                            icon: SettingsIcon(symbol: "text.cursor", color: .systemBlue),
                            accessory: toggle(\.voiceContextCursor)),
            SettingsKit.row(title: "屏幕内容", detail: "参考窗口里的文字修正专有名词。",
                            icon: SettingsIcon(symbol: "macwindow", color: .systemTeal),
                            accessory: toggle(\.voiceContextScreen)),
            SettingsKit.row(title: "最近的听写", detail: "暂存最近 30 分钟的听写，衔接上下文。",
                            help: "只在内存里暂存各应用最近 30 分钟的听写，不写到磁盘；关掉时立即清空。",
                            icon: SettingsIcon(symbol: "clock.arrow.circlepath", color: .systemOrange),
                            accessory: toggle(\.voiceContextHistory) { on in if !on { VoiceHistory.shared.clear() } }),
        ]
    }

    /// 「按下 🌐 键时」不是「不执行任何操作」时的提示；是的话返回 nil。
    /// 系统设置存在 com.apple.HIToolbox 的 AppleFnUsageType：0 不执行任何操作，1 更改输入法，2 表情与符号，3 开始听写；
    /// 没有这一项时系统按默认处理（不是「不执行任何操作」）。
    static func fnWarning() -> String? {
        let defaults = UserDefaults(suiteName: "com.apple.HIToolbox")
        let action: String
        switch defaults?.object(forKey: "AppleFnUsageType") as? Int {
        case 0: return nil
        case 1: action = "更改输入法"
        case 2: action = "显示表情与符号"
        case 3: action = "开始听写"
        default: action = "系统默认的动作"
        }
        return "「按下 🌐 键时」现在是「\(action)」，按 🌐 fn 时系统也会动作。请在键盘设置里改成「不执行任何操作」。"
    }
}

// MARK: - 麦克风

/// 照 Arion 设置里单独的「麦克风」页（apps/desktop/ui/pages/settings/settings.go@d2108fe 的 Microphone）：
/// 一张卡片里是输入设备、输入增益和音量表。
final class MicrophonePage: SettingsPage {
    override var pageTitle: String { "录音设备" }
    override var pageSubtitle: String { "选用哪个麦克风、离麦克风多远说话。只在语音输入时使用麦克风。" }

    /// 音量表（整页重建时换成新的那个）
    private weak var meter: LevelMeterView?

    /// 打开这一页时开着麦克风，音量表跟着说话动（照 Arion「说句话测试音量」）；离开就关。
    override func viewDidAppear() {
        super.viewDidAppear()
        VoiceRecorder.shared.onMonitor = { [weak self] level in self?.meter?.push(level) }
        if !VoiceRecorder.shared.isRecording { _ = VoiceRecorder.shared.start() }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        VoiceRecorder.shared.onMonitor = nil
        // 正在语音输入时不关（会话结束时自己关）
        if !VoiceController.shared.isActive { VoiceRecorder.shared.stop() }
    }

    override func build() -> [NSView] {
        let devices = AudioDevices.inputs()
        let names = ["系统默认"] + devices.map(\.name)
        let selected = devices.firstIndex { $0.uid == config.voiceInputDevice }.map { $0 + 1 } ?? 0
        let devicePopUp = SettingPopUp(items: names, selected: selected) { [weak self] index in
            let uid = index == 0 ? "" : devices[index - 1].uid
            self?.update { $0.voiceInputDevice = uid }
            // 换了设备：重开一次麦克风，音量表接上新设备
            if !VoiceController.shared.isActive {
                VoiceRecorder.shared.stop()
                VoiceRecorder.shared.prepare()
                _ = VoiceRecorder.shared.start()
            }
        }
        let gainRow = SettingsKit.row(title: "输入增益", detail: GainStop.describe(config.voiceGain),
                                      icon: SettingsIcon(symbol: "dial.medium.fill", color: .systemOrange))
        let gainDetail = Self.detailLabel(in: gainRow)
        let slider = GainSlider(db: config.voiceGain, onPreview: { db in
            gainDetail?.stringValue = GainStop.describe(db)
        }, onCommit: { [weak self] db in
            self?.update { $0.voiceGain = db }
            // 增益在开始录音时读：重开一次麦克风，音量表马上按新的增益
            if !VoiceController.shared.isActive {
                VoiceRecorder.shared.stop()
                _ = VoiceRecorder.shared.start()
            }
        })
        let meter = LevelMeterView()
        self.meter = meter
        let meterLabel = NSTextField(labelWithString: "说句话测试音量")
        meterLabel.font = .systemFont(ofSize: 12)
        meterLabel.textColor = .secondaryLabelColor
        let meterRow = NSStackView(views: [meter, meterLabel])
        meterRow.orientation = .vertical
        meterRow.spacing = 6
        return NoticeBanner.banners(page: "microphone", config: config) + [
            SettingsKit.sectionTitle("输入设备"),
            SettingsKit.card([
                SettingsKit.row(title: "输入设备", icon: SettingsIcon(symbol: "mic.circle.fill", color: .systemBlue),
                                accessory: devicePopUp),
            ]),
            SettingsKit.sectionTitle("输入增益"),
            SettingsKit.card([
                gainRow,
                Self.padded(slider, height: 50),
                Self.padded(meterRow, height: 72, centered: true),
            ]),
        ]
    }

    /// 行里的说明文字（拖增益滑块时跟着改）。
    private static func detailLabel(in row: NSView) -> NSTextField? {
        var labels: [NSTextField] = []
        func walk(_ view: NSView) {
            if let field = view as? NSTextField, !field.isEditable { labels.append(field) }
            view.subviews.forEach(walk)
        }
        walk(row)
        return labels.count >= 2 ? labels[1] : nil
    }

    /// 卡片里一整行放一个控件，左右和行的文字对齐。
    private static func padded(_ view: NSView, height: CGFloat, centered: Bool = false) -> NSView {
        let box = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(view)
        var constraints = [
            box.heightAnchor.constraint(equalToConstant: height),
            view.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ]
        if centered {
            constraints.append(view.centerXAnchor.constraint(equalTo: box.centerXAnchor))
        } else {
            constraints += [
                view.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: SettingsKit.textInset),
                view.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -SettingsKit.rowInset - 4),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        return box
    }

}

// MARK: - 关于

final class AboutPage: SettingsPage {
    override var pageTitle: String { "关于软件" }
    override var pageSubtitle: String { "在 Mac 上打字，像微信输入法一样顺手。" }

    /// 检查更新的状态变了：刷新这一页
    private var observer: NSObjectProtocol?

    override func viewDidLoad() {
        super.viewDidLoad()
        observer = NotificationCenter.default.addObserver(forName: AppUpdater.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// 「检查更新」那一行：查 GitHub 上最新的 Release，有新版时按钮变成「下载」（打开发布页）
    private func updateRow() -> NSView {
        let updater = AppUpdater.shared
        let check = SettingButton(title: "检查更新") { updater.check() }
        let detail: String
        let accessory: NSView
        switch updater.state {
        case .idle:
            detail = "看看有没有新版本。"
            accessory = check
        case .checking:
            detail = "正在检查…"
            accessory = SettingsKit.spinner()
        case .upToDate:
            detail = "已是最新版本。"
            accessory = check
        case .available(let version, let page):
            detail = "有新版本 \(version)，下载后打开安装包更新。"
            accessory = SettingButton(title: "下载") { NSWorkspace.shared.open(page) }
        case .failed(let message):
            detail = "检查失败：\(message)。"
            accessory = SettingButton(title: "重试") { updater.check() }
        }
        return SettingsKit.row(title: "检查更新", detail: detail,
                               icon: SettingsIcon(symbol: "arrow.down.circle.fill", color: .systemBlue), accessory: accessory)
    }

    override func build() -> [NSView] {
        let version = Bundle.main.shortVersion
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        // App 图标占的位置和别的行的图标一样（SettingsIcon 默认 22），文字才对得齐；
        // 图标图片四周有一圈透明边，画大一点（27），看上去才和别的图标一样大
        let appIcon = NSView()
        let image = NSImageView(image: NSApp.applicationIconImage)
        image.imageScaling = .scaleProportionallyUpOrDown
        for view in [appIcon, image] { view.translatesAutoresizingMaskIntoConstraints = false }
        appIcon.addSubview(image)
        NSLayoutConstraint.activate([
            appIcon.widthAnchor.constraint(equalToConstant: 22),
            appIcon.heightAnchor.constraint(equalToConstant: 22),
            image.widthAnchor.constraint(equalToConstant: 27),
            image.heightAnchor.constraint(equalToConstant: 27),
            image.centerXAnchor.constraint(equalTo: appIcon.centerXAnchor),
            image.centerYAnchor.constraint(equalTo: appIcon.centerYAnchor),
        ])
        return [
            SettingsKit.sectionTitle("版本"),
            SettingsKit.card([
                SettingsKit.row(title: "WoType", detail: "版本 \(version)（\(build)），打字在本机处理。", icon: appIcon),
                updateRow(),
                credit("开源许可", "GNU AGPL-3.0，源码公开。", "doc.text.fill", .systemTeal,
                       "https://github.com/HelloMateoToday/WoType"),
            ]),
            SettingsKit.sectionTitle("致谢"),
            SettingsKit.card([
                credit("水杉输入法", "拼音引擎 · GPL-3.0，引擎 MPL-2.0", "leaf.fill", .systemTeal,
                       "https://github.com/metasequoiaime/msime"),
                credit("水杉词库", "GPL-3.0，含雾凇拼音 · 词频表 CC BY-SA 4.0", "text.book.closed.fill", .systemOrange,
                       "https://github.com/metasequoiaime/msime-dictionary",
                       help: "水杉词库 msime-dictionary，GPL-3.0，含雾凇拼音；二元、三元表来自中文维基百科，CC BY-SA 4.0。"),
                credit("水杉整句模型", "chinese-ime-lm · Apache-2.0", "brain.head.profile", .systemPink,
                       "https://github.com/metasequoiaime/chinese-ime-lm"),
                credit("万象拼音", "方案、词库和语法模型 · CC BY 4.0 · amzxyz", "character.book.closed.fill", .systemGreen,
                       "https://github.com/amzxyz/rime-wanxiang",
                       help: "万象引擎用的万象拼音方案和词库 rime-wanxiang（标准版），在线更新的词库 rime-wanxiang-data，"
                           + "语法模型 RIME-LMDG，作者 amzxyz，CC BY 4.0。"),
                credit("Rime 输入法引擎", "librime · 万象引擎 · BSD-3-Clause", "gearshape.2.fill", .systemIndigo,
                       "https://github.com/rime/librime",
                       help: "万象引擎跑在 librime 官方发布包上，带 librime-lua、librime-octagram、librime-predict 三个插件，"
                           + "都是 BSD-3-Clause；它静态链接 Boost、glog、LevelDB、marisa-trie、OpenCC、yaml-cpp，插件带 Lua。"),
                credit("Arion", "语音输入照它移植 · AGPL-3.0", "mic.fill", .systemRed,
                       "https://github.com/AstraFoundry/Arion"),
                credit("Qwen 语音模型", "Qwen3-ASR、Qwen3.5 · Apache-2.0", "waveform", .systemPurple,
                       "https://github.com/Blaizzy/mlx-audio-swift",
                       help: "语音识别 Qwen3-ASR、润色 Qwen3.5，Apache-2.0，用 MLX 在本机运行（mlx-audio-swift）。"),
            ]),
            SettingsKit.sectionTitle("你的数据"),
            SettingsKit.card([
                SettingsKit.row(title: "数据文件夹", detail: "学到的词、自定义词、下载的模型和设置。",
                                help: "都在这个文件夹里：\n" + Paths.userData.path,
                                icon: SettingsIcon(symbol: "folder.fill", color: .systemBlue),
                                accessory: SettingButton(title: "在访达中显示") {
                                    NSWorkspace.shared.activateFileViewerSelecting([Paths.userData])
                                }),
            ]),
        ]
    }

    /// 致谢里的一行：名字、来源和许可，右边点了打开项目主页。
    private func credit(_ title: String, _ detail: String, _ symbol: String, _ color: NSColor,
                        _ link: String, help: String? = nil) -> NSView {
        SettingsKit.row(title: title, detail: detail, help: help, icon: SettingsIcon(symbol: symbol, color: color),
                        accessory: LinkButton(title: "打开 ↗") {
                            if let url = URL(string: link) { NSWorkspace.shared.open(url) }
                        })
    }
}

/// 单选按钮、整行点击的动作（NSButton 的 target 是弱引用，放在这里存着）。
@MainActor
final class ClickTarget: NSObject {
    static let shared = ClickTarget()
    var actions: [ObjectIdentifier: () -> Void] = [:]

    @objc func clicked(_ sender: NSButton) {
        actions[ObjectIdentifier(sender)]?()
    }
}

/// 点一下整行就执行（单选的那一行）。
final class ClickGesture: NSClickGestureRecognizer {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(target: nil, action: nil)
        target = self
        action = #selector(fire)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}
