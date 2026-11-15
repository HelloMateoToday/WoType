//
//  KeyCap.swift
//  WoType
//
//  键帽：照 Mac 键盘画（screenshots/2.png）——修饰键右上角是符号、左下角是英文名，字母键字在中间，
//  fn 左下角是地球、右上角是 fn。白色圆角键面，底下一条深一点的边，像凸起来的键；深色模式跟着变。
//
//  新手引导、设置和安装器共用（docs/18、19；安装器经符号链接编这个文件，只能用 Cocoa），画法只有一份（KeyCap.draw）：
//  - KeyCapView：一个键帽；大号的能按下去（插图里跟着真实按键下沉、变色）；
//  - KeyCaps.combo：组合键几个键帽并排（⌃⌥T）；
//  - KeyCaps.text：一句话里夹着键帽（"单按 {control}，再按 {return}"），键帽是文本附件；
//  - KeyCaps.token(for:)：用户改过的快捷键（KeyboardShortcuts）换成 {control+option+T}（只有 WoType 用，在 KeyCap+WoType.swift）。
//

import Cocoa

nonisolated enum KeyCap: Hashable {
    case control, option, command, shift, fn, returnKey, escape, space, tab, delete
    /// 字母、数字等：字在中间
    case character(String)

    /// 右上角的符号；字母键是中间的字
    var symbol: String {
        switch self {
        case .control: "⌃"
        case .option: "⌥"
        case .command: "⌘"
        case .shift: "⇧"
        case .fn: "fn"
        case .returnKey: "↩"
        case .escape: "⎋"
        case .space: ""
        case .tab: "⇥"
        case .delete: "⌫"
        case .character(let text): text.uppercased()
        }
    }

    /// 左下角的英文名；字母键、fn 没有（fn 左下角画地球）
    var name: String? {
        switch self {
        case .control: "control"
        case .option: "option"
        case .command: "command"
        case .shift: "shift"
        case .returnKey: "return"
        case .escape: "esc"
        case .space: "space"
        case .tab: "tab"
        case .delete: "delete"
        case .fn, .character: nil
        }
    }

    /// 宽键（修饰键、return 这些）；字母键和 fn 是方的
    var isWide: Bool {
        switch self {
        case .character, .fn: false
        default: true
        }
    }

    /// 比较用：字母不分大小写
    var normalized: KeyCap {
        if case .character(let text) = self { return .character(text.uppercased()) }
        return self
    }

    /// 读屏念的名字
    var spokenName: String { name ?? (self == .fn ? "fn" : symbol) }

    /// {control}、{⌃}、{T} 里的写法
    init?(token: String) {
        switch token.lowercased() {
        case "control", "ctrl", "⌃": self = .control
        case "option", "opt", "alt", "⌥": self = .option
        case "command", "cmd", "⌘": self = .command
        case "shift", "⇧": self = .shift
        case "fn", "globe": self = .fn
        case "return", "enter", "↩", "⏎": self = .returnKey
        case "esc", "escape", "⎋": self = .escape
        case "space", "空格": self = .space
        case "tab", "⇥": self = .tab
        case "delete", "⌫": self = .delete
        default:
            guard !token.isEmpty, token.count <= 3 else { return nil }
            self = .character(token)
        }
    }
}

/// 键帽的大小。
enum KeyCapSize {
    /// 夹在 13pt 正文里
    case inline
    /// 一行设置里、选键的按钮
    case regular
    /// 插图里
    case large

    var height: CGFloat {
        switch self {
        case .inline: 24
        case .regular: 34
        case .large: 96
        }
    }

    func width(_ key: KeyCap) -> CGFloat {
        guard key.isWide else { return height }
        switch self {
        case .inline: return 52
        case .regular: return 70
        case .large: return 168
        }
    }

    func size(_ key: KeyCap) -> NSSize { NSSize(width: width(key), height: height) }

    /// 键面下面那条边的厚度（按下去时键面往下走这么多）
    var edge: CGFloat {
        switch self {
        case .inline: 1.5
        case .regular: 2
        case .large: 6
        }
    }

    var radius: CGFloat { height * 0.2 }
    var symbolSize: CGFloat { self == .large ? height * 0.3 : height * 0.36 }
    /// 真键盘上名字比符号小得多；小号的不能再小，再小就看不清
    var nameSize: CGFloat { self == .large ? height * 0.17 : max(8, height * 0.27) }
    var characterSize: CGFloat { height * 0.48 }
}

extension KeyCap {

    /// 画一个键帽（rect 是整个键帽，坐标朝下）。pressed 0～1：按下去的程度。
    static func draw(_ key: KeyCap, size: KeyCapSize, in rect: NSRect, pressed: CGFloat = 0, highlighted: Bool = false) {
        let dark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let edge = size.edge
        let radius = size.radius
        // 底下的边：深一点的颜色，键面按下去时露得少
        let base = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        let shadow = NSShadow()
        shadow.shadowBlurRadius = size == .large ? 8 : 1.5
        shadow.shadowOffset = NSSize(width: 0, height: size == .large ? -3 : -0.5)
        shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.5 : 0.12 * (1 - pressed * 0.6))
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        NSColor(white: dark ? 0.16 : 0.78, alpha: 1).setFill()
        base.fill()
        NSGraphicsContext.restoreGraphicsState()

        var face = rect
        face.size.height -= edge
        face.origin.y += edge * pressed
        let facePath = NSBezierPath(roundedRect: face, xRadius: radius, yRadius: radius)
        var faceColor = NSColor(white: dark ? 0.29 : 1, alpha: 1)
        if highlighted || pressed > 0 {
            let amount = highlighted ? 0.16 : 0.22 * pressed
            faceColor = faceColor.blended(withFraction: amount, of: .controlAccentColor) ?? faceColor
        }
        faceColor.setFill()
        facePath.fill()
        NSColor(white: dark ? 0.38 : 0.86, alpha: 1).setStroke()
        facePath.lineWidth = size == .large ? 1 : 0.5
        facePath.stroke()

        let ink = NSColor(white: dark ? 0.9 : 0.24, alpha: 1)
        let insetX = size.height * 0.16
        let insetY = size.height * 0.12
        switch key {
        case .character(let text):
            let label = NSAttributedString(string: text.uppercased(), attributes: [
                .font: NSFont.systemFont(ofSize: size.characterSize, weight: .regular), .foregroundColor: ink,
            ])
            let s = label.size()
            label.draw(at: NSPoint(x: face.midX - s.width / 2, y: face.midY - s.height / 2))
        case .fn:
            let fn = NSAttributedString(string: "fn", attributes: [
                .font: NSFont.systemFont(ofSize: size.nameSize, weight: .regular), .foregroundColor: ink,
            ])
            fn.draw(at: NSPoint(x: face.maxX - insetX - fn.size().width, y: face.minY + insetY))
            if let globe = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: size.nameSize, weight: .regular)) {
                let s = globe.size
                let tinted = NSImage(size: s, flipped: false) { r in
                    globe.draw(in: r)
                    ink.set()
                    r.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: NSRect(x: face.minX + insetX, y: face.maxY - insetY - s.height, width: s.width, height: s.height),
                            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        default:
            let symbol = NSAttributedString(string: key.symbol, attributes: [
                .font: NSFont.systemFont(ofSize: size.symbolSize, weight: .regular), .foregroundColor: ink,
            ])
            // 符号的中线放在键面上方约 1/3 处（字形在行框里偏上，按行框贴边会顶到上沿；小号的键帽再往下一点）
            let s = symbol.size()
            let center = size == .large ? 0.32 : (size == .inline ? 0.44 : 0.38)
            symbol.draw(at: NSPoint(x: face.maxX - insetX - s.width, y: face.minY + face.height * center - s.height / 2))
            if let name = key.name {
                let label = NSAttributedString(string: name, attributes: [
                    .font: NSFont.systemFont(ofSize: size.nameSize, weight: .regular), .foregroundColor: ink,
                ])
                let s = label.size()
                label.draw(at: NSPoint(x: face.minX + insetX, y: face.maxY - insetY - s.height))
            }
        }
    }
}

// MARK: - 现在按着的键

/// 现在按着的键：新手引导窗口的按键监视器更新（update(with:)），画面上所有键帽据此画成按下去的样子，
/// 包括正文里的键帽（文本附件每次重画都来问）。重画时可能不在主线程，用锁。
nonisolated enum KeyCapPresses {

    /// 按着的键变了
    static let didChange = Notification.Name("WoTypeKeyCapPressesDidChange")

    private static let lock = NSLock()
    nonisolated(unsafe) private static var down: Set<KeyCap> = []

    static func isDown(_ key: KeyCap) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return down.contains(key.normalized)
    }

    /// 按键、修饰键事件：记下按着哪些键
    @MainActor
    static func update(with event: NSEvent) {
        var next = snapshot()
        switch event.type {
        case .flagsChanged:
            let modifiers: [(NSEvent.ModifierFlags, KeyCap)] = [
                (.control, .control), (.option, .option), (.command, .command), (.shift, .shift), (.function, .fn),
            ]
            for (flag, key) in modifiers {
                if event.modifierFlags.contains(flag) { next.insert(key) } else { next.remove(key) }
            }
        case .keyDown, .keyUp:
            guard let key = key(for: event) else { return }
            if event.type == .keyDown { next.insert(key) } else { next.remove(key) }
        default:
            return
        }
        set(next)
    }

    /// 窗口不在前台了：全部松开（松开的事件收不到了）
    @MainActor
    static func clear() {
        set([])
    }

    private static func snapshot() -> Set<KeyCap> {
        lock.lock()
        defer { lock.unlock() }
        return down
    }

    @MainActor
    private static func set(_ keys: Set<KeyCap>) {
        lock.lock()
        let changed = keys != down
        down = keys
        lock.unlock()
        if changed { NotificationCenter.default.post(name: didChange, object: nil) }
    }

    private static func key(for event: NSEvent) -> KeyCap? {
        switch Int(event.keyCode) {
        case 36, 76: return .returnKey
        case 53: return .escape
        case 49: return .space
        case 48: return .tab
        case 51: return .delete
        default:
            guard let text = event.charactersIgnoringModifiers, text.count == 1,
                  let scalar = text.unicodeScalars.first, scalar.value > 0x20, scalar.value < 0x7F else { return nil }
            return .character(text.uppercased())
        }
    }
}

// MARK: - 一个键帽

/// 一个键帽。setPressed 让它按下去、弹回来（Arion keyfigure 的节奏：80 ms 下去，220 ms 回来）。
final class KeyCapView: NSView {

    var key: KeyCap {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
            setAccessibilityLabel(key.spokenName)
        }
    }
    let size: KeyCapSize
    /// 描一圈强调色（选中的语音键）
    var highlighted = false { didSet { needsDisplay = true } }

    private var pressed: CGFloat = 0
    /// 演示让它按下（插图的剧本）
    private var scripted = false
    private var animation: (from: CGFloat, to: CGFloat, start: CFTimeInterval, duration: CFTimeInterval)?
    private var link: CADisplayLink?

    init(_ key: KeyCap, size: KeyCapSize) {
        self.key = key
        self.size = size
        super.init(frame: NSRect(origin: .zero, size: size.size(key)))
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(key.spokenName)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        // 键盘上真的按下这个键，键帽也按下去（选择器式的观察者，视图释放时系统自己去掉）
        NotificationCenter.default.addObserver(self, selector: #selector(pressesChanged),
                                               name: KeyCapPresses.didChange, object: nil)
    }

    @objc private func pressesChanged() {
        animate(to: scripted || KeyCapPresses.isDown(key))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { size.size(key) }

    override func draw(_ dirtyRect: NSRect) {
        KeyCap.draw(key, size: size, in: bounds, pressed: pressed, highlighted: highlighted)
    }

    /// 演示让它按下、松开；键盘上按着这个键时一直是按下的
    func setPressed(_ down: Bool, animated: Bool = true) {
        scripted = down
        animate(to: down || KeyCapPresses.isDown(key), animated: animated)
    }

    private func animate(to down: Bool, animated: Bool = true) {
        let target: CGFloat = down ? 1 : 0
        if animation == nil, pressed == target { return }
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            pressed = target
            animation = nil
            needsDisplay = true
            return
        }
        animation = (pressed, target, CACurrentMediaTime(), down ? 0.08 : 0.22)
        if link == nil {
            let link = displayLink(target: self, selector: #selector(step))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    @objc private func step() {
        guard let animation else {
            link?.invalidate()
            link = nil
            return
        }
        let t = min(1, (CACurrentMediaTime() - animation.start) / animation.duration)
        // 缓出
        let eased = 1 - pow(1 - t, 3)
        pressed = animation.from + (animation.to - animation.from) * eased
        needsDisplay = true
        if t >= 1 { self.animation = nil }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            link?.invalidate()
            link = nil
        }
    }
}

// MARK: - 组合键、正文里的键帽

enum KeyCaps {

    /// 组合键：几个键帽并排。
    static func combo(_ keys: [KeyCap], size: KeyCapSize, spacing: CGFloat? = nil) -> NSStackView {
        let stack = NSStackView(views: keys.map { KeyCapView($0, size: size) })
        stack.orientation = .horizontal
        stack.spacing = spacing ?? (size == .large ? 12 : 3)
        stack.setHuggingPriority(.required, for: .horizontal)
        return stack
    }

    /// 一个键帽的图（正文里的文本附件用）。按需重画：深浅色切换时跟着变。
    static func image(_ key: KeyCap, size: KeyCapSize = .inline) -> NSImage {
        let image = NSImage(size: size.size(key), flipped: true) { rect in
            KeyCap.draw(key, size: size, in: rect, pressed: KeyCapPresses.isDown(key) ? 1 : 0)
            return true
        }
        // 每次重画都重新画：深浅色、按下松开都跟着变
        image.cacheMode = .never
        image.accessibilityDescription = key.spokenName
        return image
    }

    /// 一句话里夹着键帽：{control}、{control+option+T}、{return}。花括号里认不出的原样留着。
    static func text(_ template: String, font: NSFont, color: NSColor = .labelColor,
                     alignment: NSTextAlignment = .natural) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.alignment = alignment
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        let result = NSMutableAttributedString()
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            result.append(NSAttributedString(string: String(rest[..<open]), attributes: attributes))
            let token = String(rest[rest.index(after: open)..<close])
            let keys = token.split(separator: "+").map { KeyCap(token: String($0)) }
            if !keys.isEmpty, !keys.contains(nil) {
                for (i, key) in keys.compactMap({ $0 }).enumerated() {
                    if i > 0 { result.append(NSAttributedString(string: "\u{2009}", attributes: attributes)) }
                    result.append(attachment(key, font: font, attributes: attributes))
                }
            } else {
                result.append(NSAttributedString(string: "{\(token)}", attributes: attributes))
            }
            rest = rest[rest.index(after: close)...]
        }
        result.append(NSAttributedString(string: String(rest), attributes: attributes))
        return result
    }

    private static func attachment(_ key: KeyCap, font: NSFont, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let size = KeyCapSize.inline
        let attachment = NSTextAttachment()
        attachment.image = image(key, size: size)
        // 键帽的中线和文字的中线对齐
        let s = size.size(key)
        attachment.bounds = NSRect(x: 0, y: (font.capHeight - s.height) / 2, width: s.width, height: s.height)
        let string = NSMutableAttributedString(attachment: attachment)
        string.addAttributes(attributes, range: NSRange(location: 0, length: string.length))
        return string
    }
}
