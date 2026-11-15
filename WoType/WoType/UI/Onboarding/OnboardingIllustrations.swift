//
//  OnboardingIllustrations.swift
//  WoType
//
//  新手引导左边的插图（docs/18），照 Arion 的 showcase / keyfigure 的做法——用户看到的就是真的界面：
//  候选窗用 CandidateView 画（跟着皮肤，横排，按比例缩小放进左栏），听写浮条用 CapsuleView 画，按键画成键帽（KeyCap）。
//  演示按固定的剧本循环；用户在试用区里按下语音键，键帽跟着往下沉。
//  系统开了「减弱动态效果」时不循环，停在最后一帧。
//

import Cocoa
import KeyboardShortcuts

/// 左边整块：按步骤换演示，换的时候淡入淡出。
final class OnboardingIllustrationView: NSView {

    private var demo: (NSView & OnboardingDemo)?
    private var step: OnboardingStep?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ step: OnboardingStep, state: OnboardingState, animated: Bool) {
        let engine = Settings.shared.config.pinyinEngine
        guard step != self.step else { return }
        self.step = step
        let next: NSView & OnboardingDemo
        switch step {
        case .welcome: next = CandidateDemo(translate: false)
        case .typing: next = CandidateDemo(translate: true)
        case .enable: next = InputSourceDemo(mode: .add)
        case .permissions: next = PermissionDemo()
        case .engine: next = EngineDemo(engine: engine)
        case .selectionShow: next = SelectionDemo()
        case .selectionReplace: next = ReplaceDemo()
        case .voice: next = DictationDemo(mode: .setup)
        case .voiceModels: next = ModelDownloadDemo()
        case .providers: next = ProviderDemo()
        case .voiceTranslate: next = DictationDemo(mode: .translate)
        case .voiceKey: next = DictationDemo(mode: .tryVoice)
        case .moreSettings: next = SettingsTourDemo()
        }
        let old = demo
        demo = next
        next.translatesAutoresizingMaskIntoConstraints = false
        addSubview(next)
        NSLayoutConstraint.activate([
            next.topAnchor.constraint(equalTo: topAnchor),
            next.bottomAnchor.constraint(equalTo: bottomAnchor),
            next.leadingAnchor.constraint(equalTo: leadingAnchor),
            next.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        next.update(state)
        next.start()
        old?.stop()
        guard animated, let old, let layer = next.layer else {
            old?.removeFromSuperview()
            return
        }
        layoutSubtreeIfNeeded()
        layer.add(OnboardingMotion.basic("opacity", from: 0, to: 1, duration: 0.3, timing: .easeOut), forKey: "in")
        CATransaction.begin()
        CATransaction.setCompletionBlock { old.removeFromSuperview() }
        old.layer?.opacity = 0
        old.layer?.add(OnboardingMotion.basic("opacity", from: 1, to: 0, duration: 0.2, timing: .easeIn), forKey: "out")
        CATransaction.commit()
    }

    func update(_ state: OnboardingState) {
        demo?.update(state)
    }

    /// 设置改了（引擎、语音键）：演示里跟着换
    func settingsChanged() {
        demo?.settingsChanged()
    }

    func handle(_ event: PracticeInputController.Event) {
        demo?.handle(event)
    }

    func stopAll() {
        demo?.stop()
    }

    override var mouseDownCanMoveWindow: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.settingsSidebar.cgColor
    }
}

/// 一个演示。
protocol OnboardingDemo: AnyObject {
    func start()
    func stop()
    func update(_ state: OnboardingState)
    func settingsChanged()
    func handle(_ event: PracticeInputController.Event)
}

extension OnboardingDemo {
    func update(_ state: OnboardingState) {}
    func settingsChanged() {}
    func handle(_ event: PracticeInputController.Event) {}
}

// MARK: - 共用的小部件

/// 演示用的假编辑器：白色圆角窗口，标题栏三个小圆点，里面一段字，拼音带下划线，后面是光标。
final class MockEditor: CardView {

    var text = "" { didSet { needsDisplay = true } }
    var marked = "" { didSet { needsDisplay = true } }
    var caretVisible = true { didSet { needsDisplay = true } }
    /// 标题栏上的文件名（「文本编辑」的样子）；空的不画
    var title = "" { didSet { needsDisplay = true } }

    static let font = NSFont.systemFont(ofSize: 15)
    static let textOrigin = NSPoint(x: 16, y: 40)

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { false }

    private var line: NSAttributedString {
        let line = NSMutableAttributedString(string: text, attributes: [.font: Self.font, .foregroundColor: NSColor.labelColor])
        line.append(NSAttributedString(string: marked, attributes: [
            .font: Self.font, .foregroundColor: NSColor.labelColor, .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]))
        return line
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
        Theme.settingsCard.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 0.5
        path.stroke()
        for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            color.withAlphaComponent(0.8).setFill()
            NSBezierPath(ovalIn: NSRect(x: 12 + CGFloat(i) * 14, y: 12, width: 8, height: 8)).fill()
        }
        if !title.isEmpty {
            let name = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor,
            ])
            name.draw(at: NSPoint(x: (bounds.width - name.size().width) / 2, y: 9))
            NSColor.separatorColor.setFill()
            NSRect(x: 0, y: 30, width: bounds.width, height: 0.5).fill()
        }
        let line = self.line
        let box = NSRect(x: Self.textOrigin.x, y: Self.textOrigin.y, width: bounds.width - 32, height: bounds.height - 48)
        line.draw(with: box, options: [.usesLineFragmentOrigin])
        if caretVisible {
            let end = position(of: line.length, in: line)
            NSColor.controlAccentColor.setFill()
            NSRect(x: end.x + 1, y: end.y + 1, width: 2, height: Self.lineHeight - 2).fill()
        }
    }

    static var lineHeight: CGFloat { font.ascender - font.descender + font.leading }

    /// 第 index 个字（UTF-16）前面的位置：x 是横坐标，y 是那一行的顶（视图坐标）
    private func position(of index: Int, in line: NSAttributedString) -> NSPoint {
        let width = bounds.width - 32
        let storage = NSTextStorage(attributedString: line)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        guard line.length > 0 else { return Self.textOrigin }
        if index >= line.length {
            let glyph = layout.glyphIndexForCharacter(at: line.length - 1)
            let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            return NSPoint(x: Self.textOrigin.x + rect.maxX, y: Self.textOrigin.y + rect.minY)
        }
        let glyph = layout.glyphIndexForCharacter(at: index)
        let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        return NSPoint(x: Self.textOrigin.x + rect.minX, y: Self.textOrigin.y + rect.minY)
    }

    /// 编辑区（拼音）开头的左下角（候选窗挂在它下面）
    func markedOrigin() -> NSPoint {
        let line = self.line
        let start = position(of: (text as NSString).length, in: line)
        return NSPoint(x: start.x, y: start.y + Self.lineHeight)
    }
}

/// 演示用的一页候选（横排）。
enum DemoSnapshot {

    /// 横排候选窗固定约 550 宽，左栏放不下：按这个比例缩小
    static let scale: CGFloat = 0.72

    static func make(_ pinyin: String, _ candidates: [String], cursor: Int = 0,
                     translation: CandidateTranslator.Bar? = nil) -> Snapshot {
        var snapshot = Snapshot(handled: true, commit: "", mode: .list, selected: "", remaining: pinyin, horizontal: true,
                                columns: candidates.count, first: 0, cursor: cursor, total: candidates.count + 4,
                                hasPrev: false, hasNext: true, candidates: candidates.map { Snapshot.Item(text: $0) },
                                caretBack: 0)
        snapshot.translation = translation
        return snapshot
    }

    /// 按快照画，缩小后放在 origin（缩小后候选窗本体的左上角；视图坐标朝下）。返回缩小后本体的大小。
    @discardableResult
    static func place(_ view: CandidateView, _ snapshot: Snapshot, at origin: NSPoint) -> NSSize {
        view.update(snapshot)
        let full = view.contentSize
        let margin = CandidateView.shadowMargin * scale
        view.frame = NSRect(x: origin.x - margin, y: origin.y - margin,
                            width: full.width * scale, height: full.height * scale)
        // bounds 比 frame 大：候选窗照原来的大小画，整体缩小显示
        view.bounds = NSRect(origin: .zero, size: full)
        view.needsDisplay = true
        return NSSize(width: (full.width - CandidateView.shadowMargin * 2) * scale,
                      height: (full.height - CandidateView.shadowMargin * 2) * scale)
    }
}

/// 按固定节拍走的剧本（GuideDemo，和安装器共用）加上引导插图要的几个回调。
class ScriptedDemo: GuideDemo, OnboardingDemo {}

/// 插图底下的一句说明（{…} 画成键帽）。
private func caption(_ template: String) -> NSTextField {
    let label = NSTextField(labelWithString: "")
    label.attributedStringValue = KeyCaps.text(template, font: .systemFont(ofSize: 12), color: .secondaryLabelColor,
                                               alignment: .center)
    label.alignment = .center
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
}

/// 演示里依次按下去的一排键帽（⌃⌥T）。
private final class PressedCombo: NSStackView {
    private let caps: [KeyCapView]

    init(_ keys: [KeyCap]) {
        caps = keys.map { KeyCapView($0, size: .regular) }
        super.init(frame: .zero)
        caps.forEach { addArrangedSubview($0) }
        spacing = 6
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 前 count 个按着，其余松开
    func press(_ count: Int) {
        for (i, cap) in caps.enumerated() { cap.setPressed(i < count) }
    }
}

// MARK: - 打拼音、选候选（欢迎、打字）

/// 假编辑器里打 nihao，横排候选窗弹出，选「你好」上屏；translate 时多演示单按 ⌃ 出译文条、⏎ 上屏译文。
final class CandidateDemo: ScriptedDemo {

    private let editor = MockEditor()
    private let candidates = CandidateView()
    private let label: NSTextField
    private static let prefix = "周末一起吃饭？"

    /// 每一拍：编辑器里的字、拼音、候选（nil 是收起）
    private struct Beat {
        var text: String
        var marked = ""
        var candidates: [String]? = nil
        var translation: CandidateTranslator.Bar? = nil
    }
    private let script: [Beat]

    init(translate: Bool) {
        label = caption(translate ? "候选窗开着时单按 {control}，{return} 上屏译文" : "打拼音，选候选，上屏")
        let p = Self.prefix
        let full = ["你好", "拟好", "你号", "泥嚎", "你", "尼", "泥"]
        var script: [Beat] = [
            Beat(text: p),
            Beat(text: p, marked: "n", candidates: ["你", "那", "年", "内", "女", "能", "呢"]),
            Beat(text: p, marked: "ni", candidates: ["你", "呢", "泥", "尼", "逆", "倪", "拟"]),
            Beat(text: p, marked: "nih", candidates: ["你好", "你会", "你和", "你还", "你", "呢", "泥"]),
            Beat(text: p, marked: "niha", candidates: ["你好", "你哈", "你", "呢", "泥", "尼", "逆"]),
            Beat(text: p, marked: "nihao", candidates: full),
            Beat(text: p, marked: "nihao", candidates: full),
        ]
        if translate {
            let source = "你好"
            script += [
                Beat(text: p, marked: "nihao", candidates: full,
                     translation: .init(source: source, complete: true, state: .translating)),
                Beat(text: p, marked: "nihao", candidates: full,
                     translation: .init(source: source, complete: true, state: .done("Hello"))),
                Beat(text: p, marked: "nihao", candidates: full,
                     translation: .init(source: source, complete: true, state: .done("Hello"))),
                Beat(text: p, marked: "nihao", candidates: full,
                     translation: .init(source: source, complete: true, state: .done("Hello"))),
                Beat(text: p + "Hello"),
            ]
        } else {
            script.append(Beat(text: p + "你好"))
        }
        // 结果停一会儿
        script += Array(repeating: script.last!, count: 5)
        self.script = script
        super.init(frame: .zero)
        editor.translatesAutoresizingMaskIntoConstraints = false
        for view in [editor, candidates, label] as [NSView] { addSubview(view) }
        NSLayoutConstraint.activate([
            editor.centerXAnchor.constraint(equalTo: centerXAnchor),
            editor.topAnchor.constraint(equalTo: centerYAnchor, constant: -150),
            editor.widthAnchor.constraint(equalToConstant: 360),
            editor.heightAnchor.constraint(equalToConstant: 104),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.topAnchor.constraint(equalTo: editor.bottomAnchor, constant: 120),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var beats: Int { script.count }
    override var interval: TimeInterval { 0.42 }

    override func show(beat: Int) {
        let b = script[beat]
        editor.text = b.text
        editor.marked = b.marked
        guard let list = b.candidates else {
            candidates.isHidden = true
            return
        }
        layoutSubtreeIfNeeded()
        let anchor = editor.convert(editor.markedOrigin(), to: self)
        let size = DemoSnapshot.place(candidates, DemoSnapshot.make(b.marked, list, translation: b.translation),
                                      at: NSPoint(x: anchor.x, y: anchor.y + 6))
        // 左边缘对齐拼音，右边出了左栏就往左挪
        let overflow = candidates.frame.minX + CandidateView.shadowMargin * DemoSnapshot.scale + size.width - (bounds.width - 12)
        if overflow > 0 { candidates.frame.origin.x -= overflow }
        candidates.isHidden = false
    }
}

// MARK: - 添加输入法

/// 怎么手动添加输入法：和安装器共用的那段动画（UI/Guide/InputSourceGuide.swift）。
extension InputSourceDemo: OnboardingDemo {}

/// 怎么允许麦克风、辅助功能：同一套系统设置画法（UI/Guide/InputSourceGuide.swift）。
extension PermissionDemo: OnboardingDemo {}

// MARK: - 引擎

/// 选中的引擎：大图标、名字和一句话，换引擎时跟着换。
final class EngineDemo: NSView, OnboardingDemo {

    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let art = CardView()

    init(engine: String) {
        super.init(frame: .zero)
        wantsLayer = true
        icon.symbolConfiguration = .init(pointSize: 64, weight: .light)
        name.font = .systemFont(ofSize: 20, weight: .semibold)
        name.alignment = .center
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        for view in [art, icon, name, detail] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(art)
        art.addSubview(icon)
        addSubview(name)
        addSubview(detail)
        NSLayoutConstraint.activate([
            art.centerXAnchor.constraint(equalTo: centerXAnchor),
            art.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -40),
            art.widthAnchor.constraint(equalToConstant: 160),
            art.heightAnchor.constraint(equalToConstant: 160),
            icon.centerXAnchor.constraint(equalTo: art.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: art.centerYAnchor),
            name.topAnchor.constraint(equalTo: art.bottomAnchor, constant: 18),
            name.centerXAnchor.constraint(equalTo: centerXAnchor),
            detail.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 6),
            detail.centerXAnchor.constraint(equalTo: centerXAnchor),
            detail.widthAnchor.constraint(equalToConstant: 260),
        ])
        set(engine, animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var mouseDownCanMoveWindow: Bool { true }

    func start() {}
    func stop() {}

    func settingsChanged() {
        set(Settings.shared.config.pinyinEngine, animated: true)
    }

    private func set(_ engine: String, animated: Bool) {
        let wanxiang = engine == "wanxiang"
        let title = wanxiang ? "万象" : "水杉"
        guard name.stringValue != title else { return }
        if animated, let layer {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.25
            layer.add(fade, forKey: "fade")
            art.layer?.add(OnboardingMotion.spring("transform.scale", from: 0.92, to: 1, OnboardingMotion.pop),
                           forKey: "pop")
        }
        icon.image = NSImage(systemSymbolName: wanxiang ? "character.book.closed.fill" : "leaf.fill",
                             accessibilityDescription: title)
        icon.contentTintColor = wanxiang ? .systemGreen : .systemTeal
        name.stringValue = title
        detail.stringValue = wanxiang ? "词库大，按前后文给候选排序" : "默认引擎，轻快跟手"
    }
}

// MARK: - 划词翻译

/// 翻译并显示：一段字被选中，⌃⌥T 依次按下，下面弹出译文气泡。
final class SelectionDemo: ScriptedDemo {

    private var highlighted = false
    private var bubble = false
    private let combo = PressedCombo(KeyCaps.keys(for: .init(.t, modifiers: [.control, .option])))
    private let label = caption("选中文字，按 \(OnboardingStepView.showToken)，译文显示在旁边")

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(combo)
        addSubview(label)
        NSLayoutConstraint.activate([
            combo.centerXAnchor.constraint(equalTo: centerXAnchor),
            combo.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 60),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.topAnchor.constraint(equalTo: combo.bottomAnchor, constant: 28),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var beats: Int { 16 }
    override var interval: TimeInterval { 0.3 }

    override func show(beat: Int) {
        let wasShown = bubble
        highlighted = beat >= 2
        // 第 4、5、6 拍依次按下 ⌃ ⌥ T，第 8 拍松开、气泡出来
        combo.press(beat >= 4 && beat < 8 ? min(beat - 3, 3) : 0)
        bubble = beat >= 8
        if bubble, !wasShown, !OnboardingMotion.reduced, let layer {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.2
            layer.add(fade, forKey: "fade")
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let card = NSRect(x: 24, y: bounds.midY - 170, width: bounds.width - 48, height: 150)
        Theme.settingsCard.setFill()
        NSBezierPath(roundedRect: card, xRadius: 12, yRadius: 12).fill()
        let font = NSFont.systemFont(ofSize: 15)
        let words = "The quick brown fox jumps over the lazy dog."
        let text = NSMutableAttributedString(string: words, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        let span = (words as NSString).range(of: "quick brown fox")
        if highlighted {
            text.addAttribute(.backgroundColor, value: NSColor.selectedTextBackgroundColor, range: span)
        }
        text.draw(with: card.insetBy(dx: 18, dy: 20), options: [.usesLineFragmentOrigin])
        guard bubble else { return }
        // 气泡：圆角框加一个小三角，指着选中的字
        let box = NSRect(x: card.minX + 40, y: card.minY + 64, width: 180, height: 42)
        let path = NSBezierPath(roundedRect: box, xRadius: 9, yRadius: 9)
        path.move(to: NSPoint(x: box.minX + 26, y: box.minY))
        path.line(to: NSPoint(x: box.minX + 34, y: box.minY - 8))
        path.line(to: NSPoint(x: box.minX + 42, y: box.minY))
        path.close()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        NSColor.windowBackgroundColor.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        ("敏捷的棕色狐狸" as NSString).draw(at: NSPoint(x: box.minX + 14, y: box.minY + 11),
                                    withAttributes: [.font: font, .foregroundColor: NSColor.labelColor])
    }
}

/// 翻译并替换：输入框里一句中文，⌃⌥I 依次按下，转一会儿圈，原地换成英文。
final class ReplaceDemo: ScriptedDemo {

    private let editor = MockEditor()
    private let combo = PressedCombo(KeyCaps.keys(for: .init(.i, modifiers: [.control, .option])))
    private let spinner = NSProgressIndicator()
    private let label = caption("在输入框里按 \(OnboardingStepView.replaceToken)，原地换成译文")
    private static let source = "今天下午三点在会议室开会"
    private static let result = "Meeting in the conference room at 3 pm today."

    override init(frame: NSRect) {
        super.init(frame: frame)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        for view in [editor, combo, spinner, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            editor.centerXAnchor.constraint(equalTo: centerXAnchor),
            editor.topAnchor.constraint(equalTo: centerYAnchor, constant: -170),
            editor.widthAnchor.constraint(equalToConstant: 360),
            editor.heightAnchor.constraint(equalToConstant: 120),
            spinner.trailingAnchor.constraint(equalTo: editor.trailingAnchor, constant: -14),
            spinner.topAnchor.constraint(equalTo: editor.topAnchor, constant: 10),
            combo.centerXAnchor.constraint(equalTo: centerXAnchor),
            combo.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 60),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.topAnchor.constraint(equalTo: combo.bottomAnchor, constant: 28),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var beats: Int { 18 }
    override var interval: TimeInterval { 0.3 }

    override func show(beat: Int) {
        // 第 3、4、5 拍依次按下 ⌃ ⌥ I，第 7 拍松开、转圈，第 10 拍换成英文
        combo.press(beat >= 3 && beat < 7 ? min(beat - 2, 3) : 0)
        if beat >= 7 && beat < 10 {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
        editor.text = beat >= 10 ? Self.result : Self.source
    }
}

// MARK: - 语音

/// 按住语音键说话：真的听写浮条（CapsuleView）按剧本走一遍，文字落进上面的编辑器。
/// 语音输入那一步上面是三种识别方式（跟着右边选的亮），下面一条「录音去哪儿」（本机、服务商、免费体验的服务器，
/// 说话时小圆点顺着走），说的是带「嗯、那个」的原话，开着润色时打进去的是润色好的；
/// 试试语音、语音翻译两步是「文本编辑」的样子，下面多一个键帽，说话时按着；试试语音打进去后打个勾，翻译时说中文、打出译文。
final class DictationDemo: NSView, OnboardingDemo {

    enum Mode { case setup, tryVoice, translate }

    private let mode: Mode
    private let editor = MockEditor()
    private let model = CapsuleModel()
    private lazy var capsule = CapsuleView(model: model)
    private let cap = KeyCapView(.command, size: .regular)
    private let side = NSTextField(labelWithString: "右侧")
    private var timer: Timer?
    private var started = Date()
    private var session = 0
    private var holding = false
    private let label = caption("")
    private let tiles = RecognitionTiles()
    private let flow = RecognitionFlow()
    private let done = NSTextField(labelWithString: "✓ 打进去了")
    private static let sentence = "明天下午三点在会议室见"
    /// 语音输入那一步说的原话（润色去掉语气词、加标点）
    private static let rawSpeech = "嗯那个明天下午呃三点在会议室见"

    /// 说话时浮条里一个字一个字出来的
    private var spoken: String { mode == .setup ? Self.rawSpeech : Self.sentence }

    /// 试试语音：文档里原来就有的那行提示
    private var prefix: String {
        guard mode == .tryVoice else { return "" }
        let key = Settings.shared.config.voiceKey
        return "在下面按住\(key == .fn ? " fn " : key == .rightCommand ? "右侧 command " : "右侧 option ")说话：\n"
    }

    /// 说话时这一轮用哪个键
    private var key: VoiceKey {
        let config = Settings.shared.config
        return mode == .translate ? (config.voiceTranslateKey ?? .rightOption) : config.voiceKey
    }

    /// 最后打进去的字
    private var written: String {
        switch mode {
        case .setup: return Settings.shared.config.voicePolish ? "明天下午三点在会议室见。" : Self.rawSpeech
        case .tryVoice: return Self.sentence
        case .translate: break
        }
        switch Settings.shared.config.voiceTranslateLanguage {
        case .ja: return "明日の午後3時に会議室で会いましょう。"
        case .ko: return "내일 오후 3시에 회의실에서 만나요."
        case .zhTW: return "明天下午三點在會議室見"
        default: return "See you in the meeting room at 3 pm tomorrow."
        }
    }

    init(mode: Mode) {
        self.mode = mode
        super.init(frame: .zero)
        wantsLayer = true
        side.font = .systemFont(ofSize: 11)
        side.textColor = .secondaryLabelColor
        let keyed = mode != .setup
        editor.title = keyed ? "试试语音输入.txt" : ""
        done.wantsLayer = true
        done.font = .systemFont(ofSize: 13, weight: .semibold)
        done.textColor = .systemGreen
        done.isHidden = true
        var views: [NSView] = [editor, capsule, label]
        if keyed { views += [cap, side] }
        if mode == .setup { views += [tiles, flow] }
        if mode == .tryVoice { views.append(done) }
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            editor.centerXAnchor.constraint(equalTo: centerXAnchor),
            editor.topAnchor.constraint(equalTo: centerYAnchor, constant: keyed ? -200 : -40),
            editor.widthAnchor.constraint(equalToConstant: 360),
            editor.heightAnchor.constraint(equalToConstant: 120),
            capsule.leadingAnchor.constraint(equalTo: leadingAnchor),
            capsule.trailingAnchor.constraint(equalTo: trailingAnchor),
            capsule.topAnchor.constraint(equalTo: editor.bottomAnchor, constant: 4),
            capsule.heightAnchor.constraint(equalToConstant: 110),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
        ])
        if keyed {
            NSLayoutConstraint.activate([
                cap.centerXAnchor.constraint(equalTo: centerXAnchor),
                cap.topAnchor.constraint(equalTo: capsule.bottomAnchor, constant: 4),
                side.centerXAnchor.constraint(equalTo: centerXAnchor),
                side.topAnchor.constraint(equalTo: cap.bottomAnchor, constant: 4),
                label.topAnchor.constraint(equalTo: side.bottomAnchor, constant: 18),
            ])
        } else {
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: capsule.bottomAnchor, constant: 8),
                flow.centerXAnchor.constraint(equalTo: centerXAnchor),
                flow.bottomAnchor.constraint(equalTo: editor.topAnchor, constant: -14),
                tiles.centerXAnchor.constraint(equalTo: centerXAnchor),
                tiles.bottomAnchor.constraint(equalTo: flow.topAnchor, constant: -12),
            ])
        }
        if mode == .tryVoice {
            NSLayoutConstraint.activate([
                done.trailingAnchor.constraint(equalTo: editor.trailingAnchor, constant: -14),
                done.bottomAnchor.constraint(equalTo: editor.bottomAnchor, constant: -10),
            ])
        }
        settingsChanged()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var mouseDownCanMoveWindow: Bool { true }

    func settingsChanged() {
        let key = self.key
        cap.key = KeyCap.voiceKey(key)
        side.isHidden = key == .fn
        let text: String
        let config = Settings.shared.config
        tiles.select(config.voiceRecognizer)
        flow.recognizer = config.voiceRecognizer
        switch mode {
        case .setup:
            let place = switch config.voiceRecognizer {
            case .local: "在这台 Mac 上识别，录音不上传"
            case .cloud: "录音发到你的服务供应商识别"
            case .trial(let channel): "录音发到\(channel.title)识别，免费体验"
            }
            text = place + (config.voicePolish ? "，打进去的是润色好的" : "")
        case .tryVoice:
            text = "在文本编辑里按住 \(OnboardingStepView.voiceKeyText(key)) 说话，松开结束"
        case .translate:
            text = "按住 \(OnboardingStepView.voiceKeyText(key)) 说中文，松开打出\(Settings.shared.config.voiceTranslateLanguage.title)"
        }
        label.attributedStringValue = KeyCaps.text(text, font: .systemFont(ofSize: 12), color: .secondaryLabelColor,
                                                   alignment: .center)
    }

    func start() {
        guard timer == nil else { return }
        if OnboardingMotion.reduced {
            editor.text = prefix + written
            done.isHidden = mode != .tryVoice
            return
        }
        started = Date()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        capsule.start()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        cap.setPressed(false, animated: false)
    }

    private func hold(_ down: Bool) {
        guard down != holding else { return }
        holding = down
        cap.setPressed(down)
    }

    /// 剧本（秒）：0.4 按下开始听，0.9～3.6 一个字一个字出来，3.9 松开识别，4.4 插入，7 从头再来
    private func tick() {
        let t = Date().timeIntervalSince(started)
        if t > 7 {
            started = Date()
            editor.text = prefix
            done.isHidden = true
            return
        }
        var d = model.dictation
        let set = { (state: SessionState) in
            if d.state != state {
                d.state = state
                d.changed = Date()
            }
        }
        switch t {
        case ..<0.4:
            if d.state != .idle { d = DictationState() }
            editor.text = prefix
            done.isHidden = true
            flow.progress = -1
            hold(false)
        case ..<3.9:
            if d.state == .idle {
                session += 1
                d.sessionID = "demo\(session)"
                d.keyLegend = VoiceController.legend(key)
                d.holding = true
            }
            hold(true)
            set(.capturing)
            // 说话时走前半段（录音 → 识别的地方）
            flow.progress = max(0, min(1, CGFloat(t - 0.9) / 2.7)) * 0.5
            let chars = Array(spoken)
            let shown = max(0, min(chars.count, Int((t - 0.9) / 2.7 * Double(chars.count))))
            d.draft = String(chars.prefix(shown))
            d.levels.append(Float.random(in: 0.15...0.75))
            if d.levels.count > DictationState.levelHistory { d.levels.removeFirst() }
        case ..<4.4:
            hold(false)
            d.holding = false
            d.final = written
            set(.finalizing)
            // 识别完走后半段（识别的地方 → 文字）
            flow.progress = 0.5 + max(0, min(1, CGFloat(t - 3.9) / 0.5)) * 0.5
        default:
            flow.progress = -1
            if d.state != .completed {
                d.outcome = DictationCopy.inserted
                set(.completed)
                editor.text = prefix + written
                if mode == .tryVoice {
                    done.isHidden = false
                    if !OnboardingMotion.reduced {
                        done.layer?.add(OnboardingMotion.spring("transform.scale", from: 0.6, to: 1, OnboardingMotion.pop),
                                        forKey: "pop")
                    }
                }
            }
        }
        model.dictation = d
        capsule.start()
    }
}

/// 语音输入那一步插图上面的三种识别方式：本机模型、云端识别、免费体验，右边选的那个亮。
final class RecognitionTiles: NSStackView {

    private let tiles: [Tile] = [
        Tile(symbol: "laptopcomputer", title: "本机模型"),
        Tile(symbol: "cloud.fill", title: "云端识别"),
        Tile(symbol: "gift.fill", title: "免费体验"),
    ]

    init() {
        super.init(frame: .zero)
        tiles.forEach(addArrangedSubview)
        spacing = 10
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func select(_ recognizer: VoiceRecognizer) {
        let index = switch recognizer {
        case .local: 0
        case .cloud: 1
        case .trial: 2
        }
        for (i, tile) in tiles.enumerated() where tile.selected != (i == index) {
            tile.selected = i == index
            if tile.selected, !OnboardingMotion.reduced {
                tile.layer?.add(OnboardingMotion.spring("transform.scale", from: 0.9, to: 1, OnboardingMotion.pop), forKey: "pop")
            }
        }
    }

    private final class Tile: NSView {
        let symbol: String
        let title: String
        var selected = false { didSet { needsDisplay = true } }

        init(symbol: String, title: String) {
            self.symbol = symbol
            self.title = title
            super.init(frame: .zero)
            wantsLayer = true
            translatesAutoresizingMaskIntoConstraints = false
            widthAnchor.constraint(equalToConstant: 96).isActive = true
            heightAnchor.constraint(equalToConstant: 72).isActive = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            let box = bounds.insetBy(dx: 1, dy: 1)
            let path = NSBezierPath(roundedRect: box, xRadius: 12, yRadius: 12)
            Theme.settingsCard.setFill()
            path.fill()
            (selected ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            path.lineWidth = selected ? 2 : 0.5
            path.stroke()
            let tint = selected ? NSColor.controlAccentColor : NSColor.secondaryLabelColor
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
                .withSymbolConfiguration(.init(pointSize: 22, weight: .regular).applying(.init(paletteColors: [tint]))) {
                let size = image.size
                image.draw(in: NSRect(x: (bounds.width - size.width) / 2, y: 14, width: size.width, height: size.height))
            }
            let name = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: selected ? .semibold : .regular),
                .foregroundColor: selected ? NSColor.labelColor : NSColor.secondaryLabelColor,
            ])
            name.draw(at: NSPoint(x: (bounds.width - name.size().width) / 2, y: 46))
        }
    }
}

/// 画一个 SF Symbol（指定颜色），左上角放在 origin（视图坐标朝下）
private func drawSymbol(_ name: String, _ color: NSColor, size: CGFloat, at origin: NSPoint) {
    guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: size, weight: .regular).applying(.init(paletteColors: [color]))) else { return }
    image.draw(in: NSRect(origin: origin, size: image.size))
}

private func drawText(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor,
                      at origin: NSPoint) {
    NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                  .foregroundColor: color]).draw(at: origin)
}

/// 下载模型：要下的模型一张张卡片，进度条一个接一个走满、打勾；底下说「下载一次，离线也能用」。
final class ModelDownloadDemo: ScriptedDemo {

    private var beat = 0
    private let label = caption("下载一次，以后没网也能用")

    /// 右边要下的（语音那一步选了本机的）；都没选时两个都画
    private var models: [(symbol: String, color: NSColor, name: String, size: String)] {
        let config = Settings.shared.config
        var models: [(String, NSColor, String, String)] = []
        if config.voiceRecognizer == .local {
            models.append(("waveform", .systemPurple, "语音识别 · Qwen3-ASR", OnboardingStepView.gigabytes(VoiceModelSpec.asr.approxBytes)))
        }
        if config.voicePolishEngine == .local || config.voiceTranslateEngine == .local {
            models.append(("wand.and.stars", .systemPink, "润色和翻译 · Qwen3.5-2B", OnboardingStepView.gigabytes(VoiceModelSpec.polish.approxBytes)))
        }
        return models.isEmpty ? [("waveform", .systemPurple, "语音识别 · Qwen3-ASR", "2.3 GB"),
                                 ("wand.and.stars", .systemPink, "润色和翻译 · Qwen3.5-2B", "1.6 GB")] : models
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.topAnchor.constraint(equalTo: centerYAnchor, constant: 90),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var beats: Int { 50 }
    override var interval: TimeInterval { 0.1 }

    override func show(beat: Int) {
        self.beat = beat
        needsDisplay = true
    }

    func settingsChanged() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let models = self.models
        let width: CGFloat = 340, height: CGFloat = 76, gap: CGFloat = 14
        var y = bounds.midY - CGFloat(models.count) * (height + gap) / 2 - 20
        for (i, model) in models.enumerated() {
            let card = NSRect(x: (bounds.width - width) / 2, y: y, width: width, height: height)
            Theme.settingsCard.setFill()
            NSBezierPath(roundedRect: card, xRadius: 12, yRadius: 12).fill()
            drawSymbol(model.symbol, model.color, size: 22, at: NSPoint(x: card.minX + 16, y: card.minY + 14))
            drawText(model.name, size: 13, weight: .semibold, at: NSPoint(x: card.minX + 52, y: card.minY + 14))
            // 第二个晚一点开始；走满后打勾
            let fraction = max(0, min(1, CGFloat(beat - 4 - i * 8) / 26))
            let status = fraction >= 1 ? "✓ 已下载" : "\(Int(fraction * 100))%  ·  \(model.size)"
            drawText(status, size: 11, color: fraction >= 1 ? .systemGreen : .secondaryLabelColor,
                     at: NSPoint(x: card.minX + 52, y: card.minY + 34))
            let track = NSRect(x: card.minX + 52, y: card.minY + 56, width: card.width - 68, height: 6)
            NSColor.separatorColor.setFill()
            NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
            (fraction >= 1 ? NSColor.systemGreen : NSColor.controlAccentColor).setFill()
            NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: track.width * fraction, height: track.height),
                         xRadius: 3, yRadius: 3).fill()
            y += height + gap
        }
    }
}

/// 添加服务商：照设置里的添加窗口画，选服务商、一个个点出密钥、按保存、显示已连接；
/// 底下一条「原话 → ☁️ → 润色好的」（只加云端识别时是「录音 → ☁️ → 文字」）。
final class ProviderDemo: ScriptedDemo {

    private var beat = 0

    /// 只要加云端识别（没选 AI 服务商）时画云端识别的窗口
    private var speechOnly: Bool {
        let config = Settings.shared.config
        if case .cloud = config.voiceRecognizer { return config.voicePolishEngine != .cloud && config.voiceTranslateEngine != .cloud }
        return false
    }

    override var beats: Int { 30 }
    override var interval: TimeInterval { 0.2 }

    override func show(beat: Int) {
        self.beat = beat
        needsDisplay = true
    }

    func settingsChanged() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let speech = speechOnly
        let sheet = NSRect(x: (bounds.width - 340) / 2, y: bounds.midY - 170, width: 340, height: 190)
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 16
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.15)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        Theme.settingsCard.setFill()
        NSBezierPath(roundedRect: sheet, xRadius: 12, yRadius: 12).fill()
        NSGraphicsContext.restoreGraphicsState()
        drawText(speech ? "添加云端识别" : "添加 AI 服务商", size: 14, weight: .semibold,
                 at: NSPoint(x: sheet.minX + 20, y: sheet.minY + 16))
        // 服务商
        drawText("服务商", size: 12, color: .secondaryLabelColor, at: NSPoint(x: sheet.minX + 20, y: sheet.minY + 56))
        let popup = NSRect(x: sheet.minX + 84, y: sheet.minY + 50, width: 236, height: 26)
        NSColor.controlBackgroundColor.setFill()
        let popupPath = NSBezierPath(roundedRect: popup, xRadius: 6, yRadius: 6)
        popupPath.fill()
        NSColor.separatorColor.setStroke()
        popupPath.stroke()
        drawText(speech ? "xAI · grok-voice" : "DeepSeek", size: 12, at: NSPoint(x: popup.minX + 10, y: popup.minY + 5))
        drawText("⌄", size: 12, color: .secondaryLabelColor, at: NSPoint(x: popup.maxX - 18, y: popup.minY + 3))
        // 密钥：第 3 拍起一个个点出来
        drawText("API 密钥", size: 12, color: .secondaryLabelColor, at: NSPoint(x: sheet.minX + 20, y: sheet.minY + 96))
        let field = NSRect(x: sheet.minX + 84, y: sheet.minY + 90, width: 236, height: 26)
        NSColor.textBackgroundColor.setFill()
        let fieldPath = NSBezierPath(roundedRect: field, xRadius: 6, yRadius: 6)
        fieldPath.fill()
        (beat >= 3 && beat < 16 ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        fieldPath.stroke()
        let dots = max(0, min(14, beat - 2))
        drawText("sk-" + String(repeating: "•", count: dots), size: 12, at: NSPoint(x: field.minX + 10, y: field.minY + 5))
        // 保存：第 17 拍按下，之后显示已连接
        let save = NSRect(x: sheet.maxX - 92, y: sheet.minY + 140, width: 72, height: 28)
        (beat == 17 ? NSColor.controlAccentColor.blended(withFraction: 0.3, of: .black) ?? .controlAccentColor
                    : NSColor.controlAccentColor).setFill()
        NSBezierPath(roundedRect: save, xRadius: 6, yRadius: 6).fill()
        drawText("保存", size: 12, weight: .medium, color: .white, at: NSPoint(x: save.minX + 22, y: save.minY + 6))
        if beat >= 18 {
            drawText("✓ 已连接", size: 12, weight: .semibold, color: .systemGreen, at: NSPoint(x: sheet.minX + 20, y: sheet.minY + 146))
        }
        // 底下：文字经过云端
        let y = sheet.maxY + 40
        let words = speech ? ("录音", "文字") : ("原话", "润色好的")
        let lit = beat >= 20
        let chip = { (text: String, x: CGFloat, on: Bool) in
            let rect = NSRect(x: x, y: y, width: 88, height: 30)
            (on ? NSColor.controlAccentColor.withAlphaComponent(0.15) : Theme.settingsCard).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 15, yRadius: 15).fill()
            let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)])
            attributed.draw(at: NSPoint(x: rect.midX - attributed.size().width / 2, y: rect.minY + 7))
        }
        let left = bounds.midX - 150
        chip(words.0, left, lit)
        drawText("→", size: 16, color: lit ? .controlAccentColor : .tertiaryLabelColor, at: NSPoint(x: left + 96, y: y + 4))
        drawSymbol("cloud.fill", lit ? .systemTeal : .tertiaryLabelColor, size: 22, at: NSPoint(x: bounds.midX - 14, y: y + 4))
        drawText("→", size: 16, color: beat >= 23 ? .controlAccentColor : .tertiaryLabelColor, at: NSPoint(x: bounds.midX + 36, y: y + 4))
        chip(words.1, bounds.midX + 62, beat >= 23)
    }
}

/// 更多设置：设置窗口的缩略图，侧边栏一项项亮起来，右边换成那一页的样子。
final class SettingsTourDemo: ScriptedDemo {

    private var beat = 0
    private let label = caption("这些都在 WoType 设置里，随时可以改")
    private static let titles = ["候选外观", "输入习惯", "拼音设置", "自定义词", "快捷短语", "语音输入", "模型管理"]
    private let sections = titles.compactMap { title in SettingsSection.all.first { $0.title == title } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.topAnchor.constraint(equalTo: centerYAnchor, constant: 150),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var beats: Int { sections.count }
    override var interval: TimeInterval { 1.1 }

    override func show(beat: Int) {
        self.beat = beat
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let window = NSRect(x: (bounds.width - 360) / 2, y: bounds.midY - 160, width: 360, height: 290)
        Theme.settingsCard.setFill()
        let path = NSBezierPath(roundedRect: window, xRadius: 12, yRadius: 12)
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 0.5
        path.stroke()
        // 侧边栏
        let sidebar = NSRect(x: window.minX, y: window.minY, width: 128, height: window.height)
        Theme.settingsSidebar.setFill()
        NSBezierPath(roundedRect: sidebar, xRadius: 12, yRadius: 12).fill()
        for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            color.withAlphaComponent(0.8).setFill()
            NSBezierPath(ovalIn: NSRect(x: window.minX + 12 + CGFloat(i) * 14, y: window.minY + 12, width: 8, height: 8)).fill()
        }
        for (i, section) in sections.enumerated() {
            let row = NSRect(x: sidebar.minX + 8, y: sidebar.minY + 36 + CGFloat(i) * 34, width: sidebar.width - 16, height: 28)
            if i == beat {
                NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
                NSBezierPath(roundedRect: row, xRadius: 7, yRadius: 7).fill()
            }
            drawSymbol(section.symbol, section.color, size: 12, at: NSPoint(x: row.minX + 8, y: row.minY + 7))
            drawText(section.title, size: 12, weight: i == beat ? .semibold : .regular, at: NSPoint(x: row.minX + 30, y: row.minY + 6))
        }
        // 右边：那一页的标题和几行设置（示意）
        guard sections.indices.contains(beat) else { return }
        let content = NSRect(x: sidebar.maxX + 18, y: window.minY + 36, width: window.maxX - sidebar.maxX - 36, height: window.height - 52)
        drawText(sections[beat].title, size: 16, weight: .semibold, at: NSPoint(x: content.minX, y: content.minY))
        for i in 0..<4 {
            let row = NSRect(x: content.minX, y: content.minY + 40 + CGFloat(i) * 44, width: content.width, height: 34)
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(roundedRect: row, xRadius: 8, yRadius: 8).fill()
            NSColor.tertiaryLabelColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: row.minX + 10, y: row.midY - 4, width: row.width * (0.38 + CGFloat((i + beat) % 3) * 0.1),
                                             height: 8), xRadius: 4, yRadius: 4).fill()
            // 右边一个开关
            let toggle = NSRect(x: row.maxX - 36, y: row.midY - 8, width: 26, height: 16)
            ((i + beat) % 2 == 0 ? NSColor.controlAccentColor : NSColor.separatorColor).setFill()
            NSBezierPath(roundedRect: toggle, xRadius: 8, yRadius: 8).fill()
        }
    }
}

/// 语音输入那一步插图中间的「录音去哪儿」：录音 → 识别的地方 → 文字，跟着右边选的识别方式换：
/// 本机是这台 Mac（不上传、没网也能用），云端是服务供应商（要密钥、要联网），免费体验是那家输入法的服务器（随时可能失效）。
/// 走网络的线画成虚线；说话时小圆点顺着线走过去，识别完走回来。
final class RecognitionFlow: NSView {

    var recognizer: VoiceRecognizer = .local {
        didSet {
            guard recognizer != oldValue else { return }
            needsDisplay = true
            if !OnboardingMotion.reduced {
                layer?.add(OnboardingMotion.basic("opacity", from: 0.3, to: 1, duration: 0.25, timing: .easeOut), forKey: "fade")
            }
        }
    }

    /// 小圆点的位置：0～1 从录音走到文字；负的不画
    var progress: CGFloat = -1 {
        didSet { if progress != oldValue { needsDisplay = true } }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 360).isActive = true
        heightAnchor.constraint(equalToConstant: 64).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    private var destination: (symbol: String, color: NSColor, title: String, detail: String) {
        switch recognizer {
        case .local:
            ("laptopcomputer", .systemGreen, "这台 Mac", "不上传 · 没网也能用")
        case .cloud:
            ("cloud.fill", .systemTeal, "服务供应商", "用你的 API 密钥 · 要联网")
        case .trial(let channel):
            ("gift.fill", .systemOrange, "\(channel.title)的服务器", "免费 · 随时可能失效")
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let target = destination
        let mid = bounds.midY
        // 两头：录音、文字
        let left = NSRect(x: 2, y: mid - 18, width: 36, height: 36)
        let right = NSRect(x: bounds.maxX - 38, y: mid - 18, width: 36, height: 36)
        for (rect, symbol) in [(left, "mic.fill"), (right, "text.cursor")] {
            Theme.settingsCard.setFill()
            NSBezierPath(ovalIn: rect).fill()
            drawSymbol(symbol, .secondaryLabelColor, size: 15, at: NSPoint(x: rect.midX - 8, y: rect.midY - 9))
        }
        // 中间：识别的地方
        let card = NSRect(x: bounds.midX - 96, y: mid - 28, width: 192, height: 56)
        Theme.settingsCard.setFill()
        let path = NSBezierPath(roundedRect: card, xRadius: 12, yRadius: 12)
        path.fill()
        target.color.withAlphaComponent(0.6).setStroke()
        path.lineWidth = 1.5
        path.stroke()
        drawSymbol(target.symbol, target.color, size: 20, at: NSPoint(x: card.minX + 12, y: card.minY + 15))
        drawText(target.title, size: 12, weight: .semibold, at: NSPoint(x: card.minX + 44, y: card.minY + 10))
        drawText(target.detail, size: 10, color: .secondaryLabelColor, at: NSPoint(x: card.minX + 44, y: card.minY + 30))
        // 连线：走网络的画成虚线
        let segments = [(left.maxX + 4, card.minX - 4), (card.maxX + 4, right.minX - 4)]
        for (from, to) in segments {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: from, y: mid))
            line.line(to: NSPoint(x: to, y: mid))
            line.lineWidth = 2
            if recognizer != .local { line.setLineDash([5, 4], count: 2, phase: 0) }
            NSColor.separatorColor.setStroke()
            line.stroke()
        }
        // 小圆点
        guard progress >= 0 else { return }
        let (from, to) = progress < 0.5 ? segments[0] : segments[1]
        let local = progress < 0.5 ? progress * 2 : (progress - 0.5) * 2
        let x = from + (to - from) * local
        NSColor.controlAccentColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: x - 5, y: mid - 5, width: 10, height: 10)).fill()
    }
}
