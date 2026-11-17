//
//  TranslationWindowViews.swift
//  WoType
//
//  翻译窗口（TranslationWindow，docs/16）的几块，照 Easydict 的固定窗口（screenshots/3.png）：
//  原文框（EZQueryView）、语言栏（EZSelectLanguageCell）、每个翻译源的结果卡片（EZResultView + EZWordResultView
//  的纯文字部分）、加载点（EZLoadingAnimationView）、悬停按钮（EZHoverButton）。尺寸、颜色、时长都照它的源码，
//  对照表在 docs/16。都是翻转坐标（y 朝下）：layout(width:) 摆好里面的控件、返回自己的高度，窗口从上往下排。
//

import AVFoundation
import Cocoa
import FreeTranslate

// MARK: - 颜色、字体、尺寸

/// Easydict 的 NSColor+MyColors、EZConst.h
enum TranslationStyle {
    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            rgb(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        }
    }

    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    /// 浅色照 screenshots/3.png 的 #F9F9F9（Easydict 源码是白色），深色照 Easydict
    static let windowBackground = dynamic(light: 0xF9F9F9, dark: 0x232325)
    /// 卡片（原文框、语言栏、结果卡片）照 screenshots/3.png 统一一种灰：浅色 #EFEFEF，深色照 Easydict #303132
    static let cardBackground = dynamic(light: 0xEFEFEF, dark: 0x303132)
    static let queryBackground = cardBackground
    static let resultBackground = cardBackground
    /// 结果卡片的标题栏、语言栏：和卡片同色（3.png 不分层）
    static let barBackground = cardBackground
    static let text = dynamic(light: 0x252525, dark: 0xE0E0E0)

    /// 正文颜色加透明度（打字机尾巴的渐变用）。透明度分成 20 档缓存
    static func text(alpha: CGFloat) -> NSColor {
        let level = min(max(Int((alpha * 20).rounded()), 0), 20)
        if let cached = fadedText[level] { return cached }
        let color = NSColor(name: nil) { appearance in
            text.resolved(for: appearance).withAlphaComponent(CGFloat(level) / 20)
        }
        fadedText[level] = color
        return color
    }
    private static var fadedText: [Int: NSColor] = [:]
    static let icon = dynamic(light: .black, dark: .white)
    static let titlebarIcon = dynamic(light: 0x797A7F, dark: 0xC0C1C4)
    static let hover = dynamic(light: 0xE6E6E6, dark: 0x3D3F3F)
    static let pressed = dynamic(light: 0xDADADA, dark: 0x484848)
    static let blue = rgb(0x007AFF)
    /// 加载点：和标题栏图标同一种灰（用户要求；Easydict 是橙色 #FF8E27）
    static let loadingDot = titlebarIcon

    static let cornerRadius: CGFloat = 8
    /// 底部一排按钮：24×24，左边 6，按钮之间 1（EZConst.h 的 ButtonWH、BtnLeft、BtnRightPad）
    static let button: CGFloat = 24
    static let buttonLeft: CGFloat = 6
    static let buttonGap: CGFloat = 1

    /// 原文、译文：14 号字，行距 4（EZTextView、EZLabel）
    static let textFont = NSFont.systemFont(ofSize: 14)

    static func paragraph() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        style.paragraphSpacing = 0
        style.lineBreakMode = .byWordWrapping
        return style
    }

    /// Lucide 图标（Assets.xcassets/Lucide，24 格、2 描边，模板图跟着按钮的颜色）：画成 size×size。
    /// 照 3.png 的图标风格（细描边、圆角、形状简洁），翻译窗口的按钮都用它
    static func lucide(_ name: String, size: CGFloat = 15) -> NSImage {
        let image = (NSImage(named: "lucide-" + name)?.copy() as? NSImage) ?? NSImage()
        image.size = NSSize(width: size, height: size)
        image.isTemplate = true
        return image
    }

    static func symbol(_ name: String, size: CGFloat = 15, weight: NSFont.Weight = .regular) -> NSImage {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
        return image.withSymbolConfiguration(.init(pointSize: size, weight: weight)) ?? image
    }

    /// 一段文字在这个宽度下排出来多高（和 NSTextView 用一样的排版）
    static func height(_ text: NSAttributedString, width: CGFloat, padding: CGFloat) -> CGFloat {
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: max(width, 1), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = padding
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        return ceil(manager.usedRect(for: container).height)
    }

    static func name(_ language: Language) -> String { language.chineseName ?? language.code }
}

extension NSColor {
    /// 动态颜色在某个外观下的实际颜色
    func resolved(for appearance: NSAppearance) -> NSColor {
        var color = self
        appearance.performAsCurrentDrawingAppearance { color = self.usingColorSpace(.sRGB) ?? self }
        return color
    }
}

// MARK: - 按钮

/// 悬停按钮（EZHoverButton）：圆角 5，鼠标移上去、按下各铺一层底。窗口还没成为 key 时第一下点击也算
class HoverButton: NSButton {
    private var hovering = false {
        didSet { needsDisplay = true }
    }

    /// Lucide 图标的按钮
    convenience init(lucide: String, size: CGFloat = 15, tip: String, target: AnyObject?, action: Selector?) {
        self.init(symbol: "circle", tip: tip, target: target, action: action)
        image = TranslationStyle.lucide(lucide, size: size)
    }

    convenience init(symbol: String, size: CGFloat = 15, tip: String, target: AnyObject?, action: Selector?) {
        self.init(frame: NSRect(x: 0, y: 0, width: TranslationStyle.button, height: TranslationStyle.button))
        image = TranslationStyle.symbol(symbol, size: size)
        imagePosition = .imageOnly
        isBordered = false
        toolTip = tip
        contentTintColor = TranslationStyle.icon
        self.target = target
        self.action = action
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = isEnabled }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        if hovering || isHighlighted {
            (isHighlighted ? TranslationStyle.pressed : TranslationStyle.hover).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        super.draw(dirtyRect)
    }
}

/// 朗读按钮（EZAudioButton）：播放时换成暂停图标，再点就停
final class AudioButton: HoverButton {
    /// 读什么、按什么语言读
    var content: (() -> (text: String, language: Language?))?

    convenience init() {
        self.init(lucide: "volume-2", tip: "朗读", target: nil, action: nil)
        target = self
        action = #selector(toggle)
        // 按 selector 注册：按钮释放时自动注销
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: SpeechPlayer.didChange, object: nil)
    }

    @objc private func toggle() {
        guard let content = content?() else { return }
        SpeechPlayer.shared.toggle(content.text, language: content.language)
    }

    @objc private func refresh() {
        let playing = content.map { SpeechPlayer.shared.isSpeaking($0().text) } ?? false
        image = TranslationStyle.lucide(playing ? "circle-pause" : "volume-2")
        toolTip = playing ? "停止朗读" : "朗读"
    }
}

/// 复制按钮（EZCopyButton）：复制到剪贴板。Easydict 没有提示（toast 注释掉了），
/// 这里点了图标变成绿色 ✓、提示「已复制」，0.8 秒后恢复
final class CopyButton: HoverButton {
    var content: (() -> String)?
    private var reset: DispatchWorkItem?

    convenience init() {
        self.init(lucide: "copy", tip: "复制", target: nil, action: nil)
        target = self
        action = #selector(copyText)
    }

    @objc private func copyText() {
        guard let text = content?(), !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        image = TranslationStyle.lucide("check")
        contentTintColor = .systemGreen
        toolTip = "已复制"
        reset?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.image = TranslationStyle.lucide("copy")
            self.contentTintColor = TranslationStyle.icon
            self.toolTip = "复制"
        }
        reset = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }
}

// MARK: - 原文框

/// 原文（EZQueryView）：能改（打中文走 PracticeInputController，WoType 自己的窗口不经过系统输入法），
/// 回车翻译、⇧回车换行。下面一行：朗读、复制、清空、「识别为 英语」（点了可以指定原文语言），最右翻译（⏎）。
/// 固定窗口的高度：文字区最矮 65、最高屏幕高的 30%，再多在框里滚动；整格 = 文字区 + 32
final class QueryView: NSView {

    /// 按了回车
    var onSubmit: (() -> Void)?
    /// 改了原文（停一秒再认语言、重新算高度）
    var onTextChange: (() -> Void)?
    /// 点「识别为」指定了原文的语言
    var onPickLanguage: ((Language) -> Void)?

    let textView = PracticeTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 65))
    private lazy var controller = PracticeInputController(textView: textView)
    private let scroll = OverlayScrollView()
    private let placeholder = NSTextField(labelWithString: "输入内容，Enter 查询，Shift + Enter 换行")
    private let audioButton = AudioButton()
    private let copyButton = CopyButton()
    /// 清空：Lucide 的 brush-cleaning，在复制右边，有字才淡入
    private lazy var clearButton = HoverButton(lucide: "brush-cleaning", tip: "清空", target: self, action: #selector(clear))
    /// 翻译（和回车一样）：改了原文点它重新翻；回车符号，颜色和朗读、复制一样，在最右边，没字时变灰
    private lazy var translateButton = HoverButton(lucide: "corner-down-left", tip: "翻译（Enter）",
                                                   target: self, action: #selector(submit))
    private let detectButton = DetectButton()

    private static let inset = NSSize(width: 6, height: 8)
    private static let minTextHeight: CGFloat = 65
    private static let bottomArea: CGFloat = 32

    override var isFlipped: Bool { true }

    var text: String {
        get { textView.string }
        set {
            textView.string = newValue
            refreshPlaceholder()
        }
    }

    /// 认出的原文语言（nil 不显示「识别为」）
    var detected: Language? {
        didSet { detectButton.language = detected }
    }

    /// 语言栏里指定了原文语言时「识别为」点不了
    var detectEnabled = true {
        didSet { detectButton.isEnabled = detectEnabled }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = TranslationStyle.cornerRadius
        layer?.masksToBounds = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = TranslationStyle.textFont
        textView.textColor = TranslationStyle.text
        textView.defaultParagraphStyle = TranslationStyle.paragraph()
        textView.typingAttributes = Self.attributes
        textView.textContainerInset = Self.inset
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = .width
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.onTextChange = { [weak self] in
            guard let self else { return }
            self.refreshPlaceholder()
            self.onTextChange?()
        }
        // 没在打拼音时的回车：翻译（⇧回车照常换行）
        controller.keyFilter = { [weak self] event in
            guard event.keyCode == 36 || event.keyCode == 76,
                  event.modifierFlags.isDisjoint(with: [.shift, .option, .command, .control]) else { return false }
            self?.onSubmit?()
            return true
        }
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.hasHorizontalScroller = false
        placeholder.font = TranslationStyle.textFont
        placeholder.textColor = .placeholderTextColor
        audioButton.content = { [weak self] in (self?.text ?? "", self?.detected) }
        copyButton.content = { [weak self] in self?.text ?? "" }
        detectButton.onPick = { [weak self] language in self?.onPickLanguage?(language) }
        for view in [scroll, placeholder, audioButton, copyButton, detectButton, translateButton, clearButton] as [NSView] {
            addSubview(view)
        }
        refreshPlaceholder()
    }

    required init?(coder: NSCoder) { fatalError() }

    private static var attributes: [NSAttributedString.Key: Any] {
        [.font: TranslationStyle.textFont, .foregroundColor: TranslationStyle.text,
         .paragraphStyle: TranslationStyle.paragraph()]
    }

    override func draw(_ dirtyRect: NSRect) {
        TranslationStyle.queryBackground.setFill()
        bounds.fill()
    }

    private func refreshPlaceholder() {
        placeholder.isHidden = !textView.string.isEmpty || textView.hasMarkedText()
        let empty = textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        audioButton.isEnabled = !empty
        copyButton.isEnabled = !empty
        translateButton.isEnabled = !empty
        translateButton.contentTintColor = empty ? .tertiaryLabelColor : TranslationStyle.icon
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            clearButton.animator().alphaValue = textView.string.isEmpty ? 0 : 1
        }
    }

    /// 光标放进原文框（窗口出现时）
    func focus() {
        window?.makeFirstResponder(textView)
    }

    /// 窗口收起：交出焦点（候选窗、引擎的钩子还回去）
    func stopEditing() {
        if window?.firstResponder === textView { window?.makeFirstResponder(nil) }
        controller.focus(false)
    }

    /// 整格的高度（文字区 + 下面的按钮行）
    func layout(width: CGFloat) -> CGFloat {
        let padding = textView.textContainer?.lineFragmentPadding ?? 5
        let used = TranslationStyle.height(NSAttributedString(string: textView.string.isEmpty ? " " : textView.string,
                                                              attributes: Self.attributes),
                                           width: width - Self.inset.width * 2, padding: padding)
        let maxText = (NSScreen.main?.frame.height ?? 900) * 0.3
        let full = used + Self.inset.height * 2
        let textHeight = ceil(min(max(full, Self.minTextHeight), maxText))
        scroll.frame = NSRect(x: 0, y: 0, width: width, height: textHeight)
        textView.frame = NSRect(x: 0, y: 0, width: width, height: max(full, textHeight))
        // 放得下时文字一直贴着顶：换行时文本框先往上滚一行、框长高后又落回来，看着抖
        if full <= maxText, scroll.contentView.bounds.origin.y != 0 {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        placeholder.sizeToFit()
        placeholder.frame.origin = NSPoint(x: Self.inset.width + padding - 2, y: Self.inset.height)

        let row = textHeight + Self.bottomArea - 4 - TranslationStyle.button
        audioButton.frame.origin = NSPoint(x: TranslationStyle.buttonLeft, y: row)
        copyButton.frame.origin = NSPoint(x: audioButton.frame.maxX + TranslationStyle.buttonGap, y: row)
        clearButton.frame.origin = NSPoint(x: copyButton.frame.maxX + TranslationStyle.buttonGap, y: row)
        let detectSize = detectButton.fittingSize
        detectButton.frame = NSRect(x: clearButton.frame.maxX + 6.5, y: row + (TranslationStyle.button - 20) / 2 - 0.5,
                                    width: detectSize.width, height: 20)
        detectButton.isHidden = detected == nil || textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        translateButton.frame.origin = NSPoint(x: width - 4 - TranslationStyle.button, y: row)
        return textHeight + Self.bottomArea
    }

    @objc private func submit() {
        onSubmit?()
    }

    @objc private func clear() {
        text = ""
        onTextChange?()
        focus()
    }
}

/// 「识别为 英语」（EZDetectLanguageButton）：高 20、圆角 10，10 号字，语言名蓝色；点了弹出语言菜单
final class DetectButton: NSButton {
    var onPick: ((Language) -> Void)?
    var language: Language? {
        didSet { refresh() }
    }

    private var hovering = false {
        didSet { needsDisplay = true }
    }
    private static let background = TranslationStyle.dynamic(light: 0xE3E4E6, dark: 0x3D3E3F)
    private static let hoverBackground = TranslationStyle.dynamic(light: 0xDCDCDC, dark: 0x47494A)
    private static let pressedBackground = TranslationStyle.dynamic(light: 0xCCCCCC, dark: 0x585A5C)

    convenience init() {
        self.init(frame: .zero)
        isBordered = false
        target = self
        action = #selector(showMenu)
        toolTip = "点击指定原文的语言"
        refresh()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func refresh() {
        let title = NSMutableAttributedString(string: "识别为 ", attributes: [
            .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.gray,
        ])
        title.append(NSAttributedString(string: language.map { TranslationStyle.name($0) } ?? "", attributes: [
            .font: NSFont.systemFont(ofSize: 10), .foregroundColor: TranslationStyle.blue,
        ]))
        attributedTitle = title
    }

    override var fittingSize: NSSize {
        NSSize(width: ceil(attributedTitle.size().width) + 16, height: 20)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = isEnabled }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        let fill = isHighlighted ? Self.pressedBackground : hovering ? Self.hoverBackground : Self.background
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        let size = attributedTitle.size()
        attributedTitle.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }

    @objc private func showMenu() {
        let menu = NSMenu()
        for candidate in SelectionTranslator.targets {
            let item = NSMenuItem(title: TranslationStyle.name(candidate), action: #selector(picked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = candidate.code
            item.state = candidate == language ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }

    @objc private func picked(_ item: NSMenuItem) {
        guard let code = item.representedObject as? String else { return }
        onPick?(Language(code))
    }
}

// MARK: - 语言栏

/// 「自动检测 ▾   ⇄   自动选择 ▾」（screenshots/3.png、EZSelectLanguageCell）：高 35，左右各在半边居中。
/// 选了就重新翻译（只对这个窗口，关了恢复成设置里的）
final class LanguageBar: NSView {

    /// 选了原文 / 目标语言（nil 是自动）
    var onChange: (() -> Void)?
    var onSwap: (() -> Void)?

    private(set) var source: Language?
    private(set) var target: Language?
    /// 自动时实际用的语言（鼠标停在按钮上提示）
    private var resolvedSource: Language?
    private var resolvedTarget: Language?

    private let sourceButton = LanguageButton()
    private let targetButton = LanguageButton()
    private lazy var swapButton = HoverButton(lucide: "arrow-right-left", tip: "交换翻译语言",
                                              target: self, action: #selector(swap))
    static let height: CGFloat = 35

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = TranslationStyle.cornerRadius
        layer?.masksToBounds = true
        swapButton.frame.size = NSSize(width: 26, height: 26)
        for button in [sourceButton, targetButton] {
            button.target = self
            button.action = #selector(choose(_:))
            addSubview(button)
        }
        addSubview(swapButton)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        TranslationStyle.barBackground.setFill()
        bounds.fill()
    }

    func set(source: Language?, target: Language?) {
        self.source = source
        self.target = target
        refresh()
    }

    /// 自动检测、自动选择实际是哪种语言
    func resolve(source: Language?, target: Language?) {
        resolvedSource = source
        resolvedTarget = target
        refresh()
    }

    private func refresh() {
        sourceButton.set(title: source.map { TranslationStyle.name($0) } ?? "自动检测",
                         tip: source == nil ? resolvedSource.map { "认出的是" + TranslationStyle.name($0) } : nil)
        targetButton.set(title: target.map { TranslationStyle.name($0) } ?? "自动选择",
                         tip: target == nil ? resolvedTarget.map { "翻成" + TranslationStyle.name($0) } : nil)
        needsLayout = true
    }

    func layout(width: CGFloat) -> CGFloat {
        let half = width / 2
        // 两个按钮一样宽、宽度固定（最长的名字也放得下）：换语言时按钮不伸缩、不挪位置
        let buttonWidth = min(LanguageButton.fixedWidth, half - 26 / 2 - 4)
        for (button, offset) in [(sourceButton, CGFloat(0)), (targetButton, half)] {
            button.frame = NSRect(x: offset + (half - buttonWidth) / 2, y: (Self.height - 26) / 2,
                                  width: buttonWidth, height: 26)
        }
        swapButton.frame.origin = NSPoint(x: (width - 26) / 2, y: (Self.height - 26) / 2)
        return Self.height
    }

    /// 点语言：弹菜单，第一项是自动
    @objc private func choose(_ sender: NSButton) {
        let isSource = sender === sourceButton
        let current = isSource ? source : target
        let menu = NSMenu()
        let auto = NSMenuItem(title: isSource ? "自动检测" : "自动选择", action: #selector(picked(_:)), keyEquivalent: "")
        auto.target = self
        auto.representedObject = Pick(isSource: isSource, language: nil)
        auto.state = current == nil ? .on : .off
        menu.addItem(auto)
        for language in SelectionTranslator.targets {
            let item = NSMenuItem(title: TranslationStyle.name(language), action: #selector(picked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = Pick(isSource: isSource, language: language)
            item.state = current == language ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    private final class Pick: NSObject {
        let isSource: Bool
        let language: Language?
        init(isSource: Bool, language: Language?) {
            self.isSource = isSource
            self.language = language
        }
    }

    @objc private func picked(_ item: NSMenuItem) {
        guard let pick = item.representedObject as? Pick else { return }
        let current = pick.isSource ? source : target
        guard current != pick.language else { return }
        if pick.isSource { source = pick.language } else { target = pick.language }
        refresh()
        onChange?()
    }

    @objc private func swap() {
        onSwap?()
    }
}

/// 语言按钮（screenshots/3.png）：13 号字的语言名，右边隔 5 一个 8×8 的 ▼，在固定宽度的按钮里居中
final class LanguageButton: NSButton {
    private var hovering = false {
        didSet { needsDisplay = true }
    }
    private var label = NSAttributedString()

    convenience init() {
        self.init(frame: .zero)
        isBordered = false
        title = ""
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func set(title: String, tip: String?) {
        label = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: TranslationStyle.text,
        ])
        toolTip = tip
        needsDisplay = true
    }

    override var fittingSize: NSSize {
        NSSize(width: Self.width(of: label), height: 26)
    }

    private static func width(of label: NSAttributedString) -> CGFloat {
        8 + ceil(label.size().width) + 5 + 8 + 8
    }

    /// 固定宽度：「自动检测」「自动选择」和所有语言名里最宽的那个
    static let fixedWidth: CGFloat = {
        let names = ["自动检测", "自动选择"] + SelectionTranslator.targets.map { TranslationStyle.name($0) }
        return names.map { width(of: NSAttributedString(string: $0, attributes: [.font: NSFont.systemFont(ofSize: 13)])) }
            .max() ?? 100
    }()

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        if hovering || isHighlighted {
            (isHighlighted ? TranslationStyle.pressed : TranslationStyle.hover).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        let arrow = TranslationStyle.symbol("arrowtriangle.down.fill", size: 7)
        let tinted = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            arrow.draw(in: rect)
            TranslationStyle.icon.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        // 文字 + ▼ 在固定宽度里居中
        let size = label.size()
        let x = (bounds.width - (ceil(size.width) + 5 + 8)) / 2
        label.draw(at: NSPoint(x: x, y: (bounds.height - size.height) / 2))
        tinted.draw(in: NSRect(x: x + ceil(size.width) + 5, y: (bounds.height - 8) / 2, width: 8, height: 8))
    }
}

// MARK: - 加载点

/// 名字右边的加载动画（EZLoadingAnimationView）：5 个 4×4 的橙点，间隔 6、两边各 4（宽 52）；
/// 第 i 个点在 i×0.12 秒时出现，0.5 秒里放大到 2 倍再缩回，再过 0.5 秒藏起来；一轮 1.28 秒
final class LoadingDots: NSView {
    private var dots: [NSView] = []
    private var timer: Timer?
    static let width: CGFloat = 52

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for _ in 0..<5 {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 2
            dot.isHidden = true
            addSubview(dot)
            dots.append(dot)
        }
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 灰色分浅色、深色：外观变了重新取
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let color = TranslationStyle.loadingDot.resolved(for: effectiveAppearance).cgColor
        dots.forEach { $0.layer?.backgroundColor = color }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        viewDidChangeEffectiveAppearance()
    }

    override func layout() {
        super.layout()
        for (i, dot) in dots.enumerated() {
            dot.frame = NSRect(x: 4 + CGFloat(i) * 10, y: (bounds.height - 4) / 2, width: 4, height: 4)
        }
    }

    var animating: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        isHidden = false
        let timer = Timer(timeInterval: 4 * 0.12 + 0.5 + 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.cycle() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        cycle()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isHidden = true
        dots.forEach {
            $0.isHidden = true
            $0.layer?.removeAllAnimations()
        }
    }

    private func cycle() {
        for (i, dot) in dots.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.12) { [weak self, weak dot] in
                guard let self, self.timer != nil, let dot, let layer = dot.layer else { return }
                dot.isHidden = false
                // 以点的中心缩放
                let frame = layer.frame
                layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                layer.frame = frame
                let scale = CAKeyframeAnimation(keyPath: "transform.scale")
                scale.values = [1, 2, 1]
                scale.duration = 0.5
                scale.calculationMode = .linear
                scale.fillMode = .forwards
                layer.add(scale, forKey: "scale")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak dot] in dot?.isHidden = true }
            }
        }
    }
}

// MARK: - 结果卡片

/// 一个翻译源的结果（EZResultView + EZWordResultView 的纯文字部分）。
/// 标题栏高 30：名字、加载点、警告图标、重试、折叠箭头；点标题栏任何地方折叠 / 展开。
/// 翻译中、没展开时只有标题栏；有译文或出错了才有正文：译文（能选中），下面朗读、复制、替换
final class ResultCard: NSView {

    enum State {
        /// 还没问（折叠着的源）
        case idle
        case loading
        /// AI 生成中（到目前为止的译文；还在想、一个字都没有时是空的，和 loading 一样只有标题栏 + 加载点）
        case streaming(String)
        case done(String)
        /// 停了（用户点停止，原因是 nil）或者中途出错：已经生成的照样显示，下面一行灰字写原因
        case interrupted(String, SelectionTranslator.Failure?)
        case failed(SelectionTranslator.Failure)
    }

    let source: SelectionTranslator.Source
    var state = State.idle
    /// 正文展开着（result.isShowing）
    var showing: Bool
    /// 用户手动展开过（没有结果时不再自动收起）
    var manualShow = false
    /// 能不能替换（选中的文字在输入框里，还没替换过）
    var replaceable = false
    /// 目标语言（朗读用）
    var language: Language?
    /// 打字机（AI 源，照 Easydict，screenshots/4.mp4）：一个字一个字出来，最新的几个字从浅到深。设了就从头开始
    var typewriter = false {
        didSet { revealed = typewriter ? 0 : nil }
    }
    /// 正文变高了（打到新的一行）、打完字了（按钮要出来）：窗口重新排
    var onContentResize: (() -> Void)?

    var onToggle: (() -> Void)?
    var onRetry: (() -> Void)?
    var onStop: (() -> Void)?
    var onReplace: ((String) -> Void)?

    private let header = HeaderView()
    private let nameLabel = NSTextField(labelWithString: "")
    /// AI 源名字旁边的 ⓘ：点开看用的模型（名字只写供应商）
    private lazy var infoButton = HoverButton(lucide: "info", size: 13, tip: "模型", target: self,
                                              action: #selector(showModel))
    private var modelPopover: NSPopover?
    private let dots = LoadingDots()
    private let warningImage = NSImageView()
    private lazy var retryButton = HoverButton(lucide: "rotate-cw", size: 14, tip: "重试", target: self,
                                               action: #selector(retry))
    /// 停止生成（Easydict 的 stop.circle）：AI 生成中才有，和重试在同一个位置
    private lazy var stopButton = HoverButton(lucide: "circle-stop", size: 14, tip: "停止", target: self,
                                              action: #selector(stop))
    /// 折叠箭头也是按下就响应（和点标题栏一样）
    private lazy var arrowButton = PressButton(symbol: "chevron.down", size: 12, tip: "隐藏", target: self,
                                               action: #selector(toggle))
    /// 箭头图形：展开朝下，折叠时转 90° 朝左（Easydict 直接换图，这里转过去）
    private let arrowIcon = PassThroughImageView()
    private var arrowShowing: Bool?
    /// 正文、底部按钮该不该显示（淡出结束时看它，免得把又展开的藏掉）
    private var bodyVisible = false
    /// 折叠、展开、正文淡入淡出的时长（和窗口里卡片的过渡一样）
    static let transition: TimeInterval = 0.25
    private let body = NSTextView()
    /// 打字机：已经显示到第几个字（带小数，尾巴按它渐变）；nil 是整段显示
    private var revealed: Double?
    private var revealLink: CADisplayLink?
    private var lastReveal: CFTimeInterval?
    /// 尾巴几个字从浅到深
    private static let tail: Double = 6
    private let audioButton = AudioButton()
    private let copyButton = CopyButton()
    private lazy var replaceButton = HoverButton(lucide: "log-in", tip: "替换选中的文字",
                                                 target: self, action: #selector(replace))

    /// 标题栏高（EZResultViewMiniHeight）
    static let headerHeight: CGFloat = 30
    /// 正文左右 8，上 9；下面按钮行上 6、下 4
    private static let margin: CGFloat = 8
    private static let topMargin: CGFloat = 9
    private static let textPadding: CGFloat = 2

    override var isFlipped: Bool { true }

    init(source: SelectionTranslator.Source, showing: Bool) {
        self.source = source
        self.showing = showing
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = TranslationStyle.cornerRadius
        layer?.masksToBounds = true
        header.onClick = { [weak self] in self?.toggle() }
        nameLabel.stringValue = source.cardName
        nameLabel.toolTip = source.cardName
        infoButton.frame.size = NSSize(width: 20, height: 20)
        infoButton.contentTintColor = TranslationStyle.titlebarIcon
        if case .ai = source.kind {} else { infoButton.isHidden = true }
        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.textColor = TranslationStyle.text
        nameLabel.lineBreakMode = .byTruncatingTail
        warningImage.image = TranslationStyle.lucide("ban", size: 14)
        warningImage.contentTintColor = .secondaryLabelColor
        arrowButton.frame.size = NSSize(width: 22, height: 22)
        arrowButton.image = nil
        arrowIcon.image = TranslationStyle.lucide("chevron-down", size: 15)
        arrowIcon.imageScaling = .scaleNone
        arrowIcon.contentTintColor = TranslationStyle.icon
        arrowIcon.frame = arrowButton.bounds
        arrowIcon.wantsLayer = true
        arrowButton.addSubview(arrowIcon)
        retryButton.frame.size = NSSize(width: 22, height: 22)
        stopButton.frame.size = NSSize(width: 22, height: 22)
        body.isEditable = false
        body.isSelectable = true
        body.drawsBackground = false
        body.textContainerInset = .zero
        body.textContainer?.lineFragmentPadding = Self.textPadding
        body.textContainer?.widthTracksTextView = true
        audioButton.content = { [weak self] in (self?.shownText ?? "", self?.language) }
        copyButton.content = { [weak self] in self?.shownText ?? "" }
        for view in [nameLabel, infoButton, dots, warningImage, retryButton, stopButton, arrowButton] as [NSView] {
            header.addSubview(view)
        }
        for view in [header, body, audioButton, copyButton, replaceButton] as [NSView] { addSubview(view) }
        // 一开始没有正文：先藏起来（不然新卡片还没排版时，它们在左上角淡出一下）
        for view in [body, audioButton, copyButton, replaceButton] as [NSView] { view.isHidden = true }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        TranslationStyle.resultBackground.setFill()
        bounds.fill()
    }

    /// 翻好了的译文（中断了的算已经生成的那些）：替换、回译用
    var translation: String? {
        switch state {
        case .done(let text): text
        case .interrupted(let text, _): text.isEmpty ? nil : text
        default: nil
        }
    }

    /// 现在显示的译文（生成中的也算）：朗读、复制用
    private var shownText: String {
        if case .streaming(let text) = state { return text }
        return translation ?? ""
    }

    /// 有正文可显示（hasShowingResult）：有译文（生成中的有字了也算）或出错了
    var hasShowingResult: Bool {
        switch state {
        case .done, .failed, .interrupted: true
        case .streaming(let text): !text.isEmpty
        case .idle, .loading: false
        }
    }

    /// 打字机要打的全文（出错的原因不逐字打）
    private var fullText: String {
        switch state {
        case .streaming(let text), .done(let text), .interrupted(let text, _): text
        default: ""
        }
    }

    /// 不会再有新的字了
    private var finished: Bool {
        if case .streaming = state { return false }
        return true
    }

    /// 打字机还在打：生成中，或者生成完了字（连尾巴）还没出完
    private var typing: Bool {
        guard let revealed else { return false }
        if !finished { return true }
        if case .failed = state { return false }
        return revealed < Double(fullText.count) + Self.tail
    }

    /// 生成中来了新的字：接着打
    func textArrived() {
        startTyping()
    }

    func layout(width: CGFloat) -> CGFloat {
        let height = Self.headerHeight
        header.frame = NSRect(x: 0, y: 0, width: width, height: height)
        if arrowShowing != showing {
            // 标题栏是翻转坐标，正角度是顺时针：朝下的箭头转 90° 朝左
            let angle: CGFloat = showing ? 0 : 90
            if arrowShowing == nil || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                arrowIcon.frameCenterRotation = angle
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = Self.transition
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    arrowIcon.animator().frameCenterRotation = angle
                }
            }
            arrowShowing = showing
        }
        arrowButton.toolTip = showing ? "隐藏" : "显示"
        arrowButton.frame.origin = NSPoint(x: width - 5 - 22, y: (height - 22) / 2)
        retryButton.frame.origin = NSPoint(x: arrowButton.frame.minX - 22, y: (height - 22) / 2)
        stopButton.frame.origin = retryButton.frame.origin
        // 名字最宽 127 × 窗口比例（Easydict：卡片宽 / 340）
        // 标签两边各有 2 点边距，按文字宽 + 4 算
        let nameWidth = min(ceil(nameLabel.attributedStringValue.size().width) + 4, 127 * width / 340)
        nameLabel.frame = NSRect(x: 8, y: (height - 17) / 2, width: nameWidth, height: 17)
        infoButton.frame.origin = NSPoint(x: nameLabel.frame.maxX, y: (height - 20) / 2)
        // 加载点、警告图标跟在名字后面（AI 的跟在 ⓘ 后面）
        let nameEnd = infoButton.isHidden ? nameLabel.frame.maxX : infoButton.frame.maxX - 2

        var warning = false
        var retry = false
        var stoppable = false
        switch state {
        case .loading:
            dots.start()
        case .streaming:
            // 生成中加载点一直转（4.mp4 里 Easydict 是这样），打完字才停
            dots.start()
            stoppable = true
        case .failed(let failure):
            dots.stop()
            warning = failure.warning
            retry = !failure.warning
        case .interrupted:
            if typing { dots.start() } else { dots.stop() }
            retry = true
        case .idle, .done:
            if typing { dots.start() } else { dots.stop() }
        }
        stopButton.isHidden = !stoppable
        dots.frame = NSRect(x: nameEnd + 3, y: 0, width: LoadingDots.width, height: height)
        warningImage.isHidden = !warning
        warningImage.frame = NSRect(x: nameEnd + 5, y: (height - 16) / 2, width: 16, height: 16)
        retryButton.isHidden = !retry

        let toolbar = [audioButton, copyButton, replaceButton]
        guard showing, hasShowingResult else {
            // 折叠：正文、按钮淡出（卡片同时收起），不立刻藏
            setBody(visible: false, [body] + toolbar)
            return Self.headerHeight
        }
        let attributed = bodyText()
        if body.attributedString() != attributed { body.textStorage?.setAttributedString(attributed) }
        let textWidth = width - Self.margin * 2
        let textHeight = TranslationStyle.height(attributed, width: textWidth, padding: Self.textPadding)
        body.frame = NSRect(x: Self.margin, y: Self.headerHeight + Self.topMargin, width: textWidth, height: textHeight)
        startTyping()

        var y = body.frame.maxY
        // 打字中没有按钮（4.mp4：字全出来按钮才出来）
        guard shownText.isEmpty == false, !typing else {
            // 出错：只有正文（原因），没有按钮
            toolbar.forEach { $0.isHidden = true }
            setBody(visible: true, [body])
            return y + 8
        }
        y += 6
        // 替换要等翻完（生成中只有朗读、复制）
        let canReplace = replaceable && translation != nil
        let shown = canReplace ? toolbar : [audioButton, copyButton]
        if !canReplace { replaceButton.isHidden = true }
        // 展开、译文回来：正文、按钮淡入（卡片同时长高）
        setBody(visible: true, [body] + shown)
        var x = TranslationStyle.buttonLeft
        for button in shown {
            button.frame.origin = NSPoint(x: x, y: y)
            x += TranslationStyle.button + TranslationStyle.buttonGap
        }
        return y + TranslationStyle.button + 4
    }

    /// 正文：译文（打字中只到 revealed，最后几个字从浅到深），中断的下面一行灰字写原因（打完才出）；出错的是原因
    private func bodyText() -> NSAttributedString {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: TranslationStyle.textFont, .foregroundColor: TranslationStyle.text,
            .paragraphStyle: TranslationStyle.paragraph(), .kern: 0.2,
        ]
        if case .failed(let failure) = state { return NSAttributedString(string: failure.message, attributes: attributes) }
        let text = fullText
        let result = NSMutableAttributedString()
        if let revealed, typing {
            let characters = Array(text)
            let shown = min(characters.count, Int(revealed.rounded(.up)))
            let tailStart = max(0, min(shown, Int(revealed - Self.tail)))
            result.append(NSAttributedString(string: String(characters[..<tailStart]), attributes: attributes))
            for index in tailStart..<shown {
                var faded = attributes
                let alpha = min(1, max(0.15, (revealed - Double(index)) / Self.tail))
                faded[.foregroundColor] = TranslationStyle.text(alpha: CGFloat(alpha))
                result.append(NSAttributedString(string: String(characters[index]), attributes: faded))
            }
        } else {
            result.append(NSAttributedString(string: text, attributes: attributes))
        }
        if case .interrupted(_, let failure) = state, !typing {
            let note = failure.map { "翻译中断：" + $0.message } ?? "已停止"
            result.append(NSAttributedString(string: (text.isEmpty ? "" : "\n") + note, attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: TranslationStyle.paragraph(),
            ]))
        }
        return result
    }

    // MARK: 打字机

    /// 还有字没出完就开始逐帧打（已经在打、折叠着、窗口没开着的不用）
    private func startTyping() {
        guard revealLink == nil, typing, showing, window?.isVisible == true,
              let revealed, revealed < Double(fullText.count) + (finished ? Self.tail : 0) else { return }
        let link = displayLink(target: self, selector: #selector(revealTick(_:)))
        link.add(to: .main, forMode: .common)
        revealLink = link
        lastReveal = nil
    }

    private func stopTyping() {
        revealLink?.invalidate()
        revealLink = nil
    }

    /// 每帧往前打几个字：平时每秒 35 个字，落后多了就快（半秒内追上），不会比网络慢太多。
    /// 追上了还在生成：停下等新的字；生成完了：尾巴走完、按钮出来
    @objc private func revealTick(_ link: CADisplayLink) {
        guard var revealed, showing else { return stopTyping() }
        let now = link.timestamp
        let dt = lastReveal.map { min(max(now - $0, 1.0 / 240), 1.0 / 20) } ?? 1.0 / 60
        lastReveal = now
        let full = Double(fullText.count)
        let limit = full + (finished ? Self.tail : 0)
        let speed = max(35, (full - revealed) / 0.5)
        revealed = min(limit, revealed + speed * dt)
        self.revealed = revealed
        if revealed >= limit { stopTyping() }
        let attributed = bodyText()
        body.textStorage?.setAttributedString(attributed)
        let height = TranslationStyle.height(attributed, width: body.frame.width, padding: Self.textPadding)
        if height != body.frame.height || !typing {
            // 打到新的一行、或者打完了（按钮出来）：窗口重新排，卡片平滑长高
            body.frame.size.height = height
            onContentResize?()
        }
    }

    /// 正文、按钮淡入淡出：显示时从透明淡入，隐藏时淡出后再藏（中途又显示了就不藏）
    private func setBody(visible: Bool, _ views: [NSView]) {
        bodyVisible = visible
        let animate = window?.isVisible == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if visible {
            let appearing = views.filter { $0.isHidden || $0.alphaValue < 1 }
            guard !appearing.isEmpty else { return }
            appearing.forEach {
                if $0.isHidden { $0.alphaValue = animate ? 0 : 1 }
                $0.isHidden = false
            }
            guard animate else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.transition
                appearing.forEach { $0.animator().alphaValue = 1 }
            }
        } else {
            let leaving = views.filter { !$0.isHidden }
            guard !leaving.isEmpty else { return }
            guard animate else {
                leaving.forEach { $0.isHidden = true }
                return
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.transition
                leaving.forEach { $0.animator().alphaValue = 0 }
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.bodyVisible else { return }
                    leaving.forEach { $0.isHidden = true }
                }
            }
        }
    }

    @objc private func toggle() {
        onToggle?()
    }

    @objc private func retry() {
        onRetry?()
    }

    @objc private func stop() {
        onStop?()
    }

    @objc private func replace() {
        guard let translation else { return }
        onReplace?(translation)
    }

    /// ⓘ：弹出用的模型；再点一下收起
    @objc private func showModel() {
        if let modelPopover, modelPopover.isShown {
            modelPopover.close()
            return
        }
        guard case .ai(let model) = source.kind else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.hasFullSizeContent = true
        popover.appearance = window?.effectiveAppearance
        popover.contentViewController = ModelInfoController(model: model)
        popover.show(relativeTo: infoButton.bounds, of: infoButton, preferredEdge: .maxY)
        modelPopover = popover
    }
}

/// AI 卡片 ⓘ 弹出的小窗：模型（兼容接口再加地址）。底色、字号、颜色和翻译窗口一样（标签灰 #797A7F，内容正文色，13 号）
private final class ModelInfoController: NSViewController {
    private let model: CloudModel

    init(model: CloudModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        var rows = [("模型", model.model)]
        if model.provider.needsBase { rows.append(("接口", model.baseURL)) }
        let grid = NSGridView(views: rows.map { label, value in
            let name = NSTextField(labelWithString: label)
            name.font = .systemFont(ofSize: 12)
            name.textColor = TranslationStyle.titlebarIcon
            let content = NSTextField(labelWithString: value)
            content.font = .systemFont(ofSize: 13)
            content.textColor = TranslationStyle.text
            content.isSelectable = true
            content.lineBreakMode = .byTruncatingMiddle
            content.preferredMaxLayoutWidth = 260
            return [name, content]
        })
        grid.columnSpacing = 10
        grid.rowSpacing = 6
        grid.rowAlignment = .firstBaseline
        grid.translatesAutoresizingMaskIntoConstraints = false
        let view = ModelInfoBackground()
        view.addSubview(grid)
        // 弹窗的箭头算在内容里（hasFullSizeContent），四周再留 10 / 12
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            grid.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            grid.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            grid.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
            grid.widthAnchor.constraint(lessThanOrEqualToConstant: 300),
        ])
        self.view = view
    }
}

/// 弹窗底色用翻译窗口的底色（连箭头），不用系统弹窗的毛玻璃
private final class ModelInfoBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        TranslationStyle.windowBackground.setFill()
        bounds.fill()
    }
}

/// 按下就发动作的悬停按钮（不等松手）
final class PressButton: HoverButton {
    override func mouseDown(with event: NSEvent) {
        sendAction(action, to: target)
    }
}

/// 不接鼠标的图片（放在按钮里，点击交给按钮）
final class PassThroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 结果卡片的标题栏：点任何地方都算点了折叠箭头（Easydict 的 handleTopBarTap）
private final class HeaderView: NSView {
    var onClick: (() -> Void)?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        TranslationStyle.barBackground.setFill()
        bounds.fill()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 不让按住标题栏拖动窗口（点它是折叠）
    override var mouseDownCanMoveWindow: Bool { false }

    /// 按下就折叠 / 展开，不等松手（松手才响应，按住的那 0.1 秒看着像延迟）
    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

// MARK: - 朗读

/// 系统的语音合成（Easydict 可以选 TTS 服务，WoType 只用系统的）。同一段再点一下就停
@MainActor
final class SpeechPlayer: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = SpeechPlayer()
    /// 开始、停止朗读（朗读按钮跟着换图标）
    static let didChange = Notification.Name("WoTypeSpeechPlayerDidChange")

    private let synthesizer = AVSpeechSynthesizer()
    private var speaking: String?

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    func isSpeaking(_ text: String) -> Bool {
        speaking != nil && speaking == text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func toggle(_ text: String, language: Language?) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let same = speaking == text
        stop()
        guard !same, !text.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        let code = (language ?? SelectionTranslator.detect(text)).map(Self.voiceCode)
        if let code, let voice = AVSpeechSynthesisVoice(language: code) { utterance.voice = voice }
        speaking = text
        synthesizer.speak(utterance)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        guard speaking != nil else { return }
        speaking = nil
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard !self.synthesizer.isSpeaking else { return }
            self.speaking = nil
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }

    /// 语音的语言代码：简体用 zh-CN，繁体用 zh-TW
    private static func voiceCode(_ language: Language) -> String {
        switch language.code {
        case "zh-Hans": "zh-CN"
        case "zh-Hant": "zh-TW"
        default: language.code
        }
    }
}
