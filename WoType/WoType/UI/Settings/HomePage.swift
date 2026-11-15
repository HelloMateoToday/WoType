//
//  HomePage.swift
//  WoType
//
//  「WoType 能做什么」，照 screenshots/v1.mp4 的首页：上面一张演示卡片，下面按组列出功能。
//  打开时演示卡片把几项主要功能连着放一遍（总览）；鼠标指向哪个功能，就一步一步放那个功能的打字过程
//  （逐个字母打拼音、按键、选词上屏），放完停一下再从头放；点一下跳到它的设置。
//

import Cocoa

/// 演示的一帧：编辑区里已经上屏的字、还在打的拼音，候选窗，正在按的键和下面的字幕。
struct DemoFrame {
    var committed = ""
    var pinyin = ""
    var candidates: [String] = []
    var highlight = 0
    /// 候选展开成一大块（按 ↓）
    var expanded = false
    /// 候选窗最下面一行的译文（候选翻译）
    var translation: String?
    /// 语音输入时的音量条（0…1），nil 时不画
    var voiceLevels: [CGFloat]?
    /// 正在按的键，画成右上角的键帽
    var key: String?
    var caption = ""
    /// 这一帧停多久
    var hold: TimeInterval = 0.5
}

/// 按步骤写演示：打字、按键、选词，每一步生成几帧。
struct DemoScript {
    private(set) var frames: [DemoFrame] = []
    private var state = DemoFrame()

    static func make(_ build: (inout DemoScript) -> Void) -> [DemoFrame] {
        var script = DemoScript()
        build(&script)
        guard var first = script.frames.first else { return [] }
        // 开头空一下再打，循环时看得出是从头开始；结尾多停一会儿
        first = DemoFrame(caption: first.caption, hold: 0.6)
        script.frames.insert(first, at: 0)
        script.frames[script.frames.count - 1].hold += 1.4
        return script.frames
    }

    private mutating func emit(_ hold: TimeInterval) {
        var frame = state
        frame.hold = hold
        frames.append(frame)
    }

    mutating func caption(_ text: String) { state.caption = text }

    mutating func wait(_ seconds: TimeInterval) { emit(seconds) }

    /// 不按键，画面自己变（停顿后重排）。
    mutating func change(hold: TimeInterval, _ change: (inout DemoFrame) -> Void) {
        change(&state)
        emit(hold)
    }

    /// 逐个字母打拼音（分隔符 ' 跟着后面的字母一起出来），打完这一段候选换成 candidates。
    mutating func type(_ text: String, _ candidates: [String]) {
        var pending = ""
        for character in text {
            pending.append(character)
            guard character != "'" else { continue }
            state.pinyin += pending
            pending = ""
            emit(0.11)
        }
        state.candidates = candidates
        state.highlight = 0
        emit(0.55)
    }

    /// 英文状态下直接上屏的字母。
    mutating func typeCommitted(_ text: String) {
        for character in text {
            state.committed.append(character)
            emit(0.09)
        }
        emit(0.5)
    }

    /// 按一个键：键帽亮一下，然后 change 生效。
    mutating func press(_ key: String, hold: TimeInterval = 0.8, _ change: (inout DemoFrame) -> Void = { _ in }) {
        state.key = key
        emit(0.5)
        state.key = nil
        change(&state)
        emit(hold)
    }

    /// 选第 index 个候选：先高亮，按键后上屏；rest 是还没选的拼音和它的候选（分段选）。
    mutating func choose(_ index: Int, key: String? = nil, rest: (String, [String])? = nil) {
        state.highlight = index
        press(key ?? (index == 0 ? "空格" : "\(index + 1)")) { frame in
            frame.committed += frame.candidates[index]
            frame.pinyin = rest?.0 ?? ""
            frame.candidates = rest?.1 ?? []
            frame.highlight = 0
            frame.expanded = false
            frame.translation = nil
        }
    }

    /// 按住 key 说话（音量条跳动），松开后字幕换成 released，文字逐字上屏。
    mutating func speak(holding key: String, _ text: String, released: String) {
        state.key = key
        for i in 0..<16 {
            state.voiceLevels = (0..<9).map { j in 0.25 + 0.75 * abs(CGFloat(sin(Double(i) * 0.9 + Double(j) * 1.3))) }
            emit(0.12)
        }
        state.key = nil
        state.voiceLevels = nil
        state.caption = released
        for character in text {
            state.committed.append(character)
            emit(0.06)
        }
        emit(0.6)
    }
}

struct Feature {
    let title: String
    let detail: String
    let symbol: String
    let color: NSColor
    /// 右边的快捷键徽标。
    let badge: String?
    /// 点了跳到哪一页。
    let page: String
    let demo: [DemoFrame]

    static let typing: [Feature] = [
        Feature(title: "整句输入", detail: "长句一口气打完，按空格整句上屏。",
                symbol: "text.line.first.and.arrowtriangle.forward", color: .systemGreen, badge: nil, page: "engine",
                demo: DemoScript.make { s in
                    s.caption("一口气打完一整句")
                    s.type("xiang", ["想", "向", "像", "项"])
                    s.type("'qu", ["想去", "想取", "向去", "想"])
                    s.type("'zi'jie", ["想去字节", "想去", "想", "向"])
                    s.type("'shang'ban", ["想去字节上班", "想去字节", "想去", "想"])
                    s.caption("按空格整句上屏")
                    s.choose(0)
                }),
        Feature(title: "打一半就有词", detail: "zhongg 就有「中国」，不用打全。",
                symbol: "bolt.fill", color: .systemOrange, badge: nil, page: "pinyin",
                demo: DemoScript.make { s in
                    s.caption("只打 zhongg")
                    s.type("zhong", ["中", "种", "重", "众"])
                    s.type("'g", ["中国", "中共", "忠告", "中高"])
                    s.caption("「中国」已经排在第一个")
                    s.wait(0.6)
                    s.choose(0)
                }),
        Feature(title: "按错键也能认出来", detail: "zhognguo 也能打出「中国」。",
                symbol: "wand.and.stars", color: .systemPurple, badge: nil, page: "pinyin",
                demo: DemoScript.make { s in
                    s.caption("手快按反了：zhognguo")
                    s.type("zhog", ["中", "种", "重"])
                    s.type("nguo", ["中国", "种过", "重过"])
                    s.caption("照样认出「中国」")
                    s.wait(0.6)
                    s.choose(0)
                }),
        Feature(title: "简拼", detail: "只打声母：bjdx → 北京大学。",
                symbol: "keyboard", color: .systemBlue, badge: nil, page: "pinyin",
                demo: DemoScript.make { s in
                    s.caption("只打每个字的声母")
                    s.type("b", ["不", "把", "被", "吧"])
                    s.type("'j", ["北京", "不久", "比较"])
                    s.type("'d'x", ["北京大学", "北京电信", "半径大小"])
                    s.choose(0)
                }),
        Feature(title: "打英文不用切换", detail: "直接打 github，候选里就有 GitHub。",
                symbol: "globe", color: .systemTeal, badge: nil, page: "habits",
                demo: DemoScript.make { s in
                    s.caption("不切换，直接打英文")
                    s.type("git", ["git", "给他", "个体"])
                    s.type("hub", ["GitHub", "github"])
                    s.caption("大小写按词表来")
                    s.choose(0)
                }),
        Feature(title: "长句分段选", detail: "先选开头的词，剩下的接着选。",
                symbol: "scissors", color: .systemIndigo, badge: "1–9", page: "appearance",
                demo: DemoScript.make { s in
                    s.caption("第一个候选不是想要的")
                    s.type("ni'hao'zhong'guo", ["你好中国", "你好", "你", "尼"])
                    s.caption("先按 2 选「你好」")
                    s.choose(1, rest: ("zhong'guo", ["中国", "种过", "中"]))
                    s.caption("剩下的接着选")
                    s.choose(0)
                }),
        Feature(title: "打字推荐 emoji", detail: "打「开心」时候选里带上 😄。",
                symbol: "face.smiling", color: .systemYellow, badge: nil, page: "appearance",
                demo: DemoScript.make { s in
                    s.caption("打「开心」")
                    s.type("kai", ["开", "凯", "卡"])
                    s.type("'xin", ["开心", "😄", "开新", "开心的"])
                    s.caption("候选里接着出 emoji")
                    s.choose(1)
                }),
        Feature(title: "整句模型", detail: "小模型给整句排序，停顿时大模型再排一遍。",
                symbol: "brain.head.profile", color: .systemPink, badge: nil, page: "engine",
                demo: DemoScript.make { s in
                    s.caption("每次按键给整句排序")
                    s.type("wo'ma'yi'zhi", ["我妈一直", "我吗一直", "我妈"])
                    s.type("'nian'dao'ni'ne", ["我妈一直念到你呢", "我妈一直念叨你呢"])
                    s.caption("停顿一下，整句再排一遍")
                    s.wait(0.9)
                    s.change(hold: 1.0) { $0.candidates = ["我妈一直念叨你呢", "我妈一直念到你呢"] }
                    s.choose(0)
                }),
    ]

    static let translation: [Feature] = [
        Feature(title: "候选翻译", detail: "打字时单按 ⌃ 翻译高亮的候选，⏎ 上屏译文。",
                symbol: "character.bubble.fill", color: .systemBlue, badge: "⌃", page: "translate",
                demo: DemoScript.make { s in
                    s.caption("打中文")
                    s.type("ni'hao", ["你好", "你", "尼"])
                    s.type("'shi'jie", ["你好世界", "你好", "你"])
                    s.caption("单按 ⌃ 翻译")
                    s.press("⌃", hold: 1.0) { $0.translation = "Hello world" }
                    s.caption("按 ⏎ 上屏译文")
                    s.press("⏎") { frame in
                        frame.committed += frame.translation ?? ""
                        frame.pinyin = ""
                        frame.candidates = []
                        frame.translation = nil
                    }
                }),
        Feature(title: "语音翻译", detail: "按住翻译键说中文，松开直接输入译文。",
                symbol: "globe", color: .systemIndigo, badge: "右 ⌥", page: "translate",
                demo: DemoScript.make { s in
                    s.caption("按住右 ⌥ 说「今天天气不错」")
                    s.speak(holding: "右 ⌥", "The weather is nice today.", released: "松开直接输入译文")
                }),
    ]

    static let shortcuts: [Feature] = [
        Feature(title: "中英切换", detail: "单按 ⇧，已输入的字母原样上屏。",
                symbol: "arrow.left.arrow.right", color: .systemGray, badge: "⇧", page: "habits",
                demo: DemoScript.make { s in
                    s.caption("打到一半想打英文")
                    s.type("hello", ["和", "喝了", "hello"])
                    s.caption("单按 ⇧，字母原样上屏")
                    s.press("⇧") { frame in
                        frame.committed += frame.pinyin
                        frame.pinyin = ""
                        frame.candidates = []
                    }
                    s.caption("接着打英文")
                    s.typeCommitted(" world")
                }),
        Feature(title: "搜表情和符号", detail: "⇧E 搜 emoji，⇧M 颜文字，⇧S 符号。",
                symbol: "smiley.fill", color: .systemPink, badge: "⇧E", page: "pinyin",
                demo: DemoScript.make { s in
                    s.caption("按 ⇧E 搜 emoji")
                    s.press("⇧E", hold: 0.4) { $0.pinyin = "E" }
                    s.caption("再打拼音")
                    s.type("kai'xin", ["😄", "😊", "🥰", "😆"])
                    s.choose(0)
                }),
        Feature(title: "日期时间", detail: "按 ⇧T 再打 rq，出今天的日期。",
                symbol: "calendar", color: .systemBlue, badge: "⇧T", page: "pinyin",
                demo: DemoScript.make { s in
                    s.caption("按 ⇧T")
                    s.press("⇧T", hold: 0.4) { $0.pinyin = "T" }
                    s.caption("打 rq 出今天的日期")
                    s.type("rq", todayCandidates)
                    s.choose(0)
                }),
        Feature(title: "展开更多候选", detail: "横排时按 ↓ 展开，方向键挑。",
                symbol: "square.grid.3x2.fill", color: .systemGreen, badge: "↓", page: "appearance",
                demo: DemoScript.make { s in
                    s.caption("想要的字不在第一页")
                    s.type("shi", ["是", "事", "时", "十", "使"])
                    s.caption("按 ↓ 展开")
                    s.press("↓") { frame in
                        frame.expanded = true
                        frame.candidates = ["是", "事", "时", "十", "使", "市", "式", "试", "世", "实", "石", "师"]
                    }
                    s.caption("方向键挑")
                    s.press("→", hold: 0.3) { $0.highlight = 1 }
                    s.press("↓", hold: 0.5) { $0.highlight = 7 }
                    s.choose(7, key: "空格")
                }),
        Feature(title: "语音输入", detail: "按住说话，松开就上屏。录音不上传。",
                symbol: "mic.fill", color: .systemRed, badge: "右 ⌘", page: "voice",
                demo: DemoScript.make { s in
                    s.caption("按住右 ⌘ 说话")
                    s.speak(holding: "右 ⌘", "今天天气不错。", released: "松开就上屏")
                }),
        Feature(title: "自定义词", detail: "人名、公司名加进来就排第一。",
                symbol: "text.book.closed.fill", color: .systemOrange, badge: nil, page: "words",
                demo: DemoScript.make { s in
                    s.caption("加过「字节跳动」")
                    s.type("z'j't'd", ["字节跳动", "中间态度", "这几天的"])
                    s.caption("简拼也排第一")
                    s.choose(0)
                }),
    ]

    /// 当前引擎的快捷键：万象没有水杉的 ⇧E 搜表情，日期时间是打 /rq（万象方案的，docs/22）
    static func shortcuts(for engine: String) -> [Feature] {
        guard engine == "wanxiang" else { return shortcuts }
        return shortcuts.compactMap { feature in
            switch feature.title {
            case "搜表情和符号": nil
            case "日期时间": wanxiangDate
            default: feature
            }
        }
    }

    private static let wanxiangDate = Feature(
        title: "日期时间", detail: "打 /rq 出今天的日期，/sj 出时间。",
        symbol: "calendar", color: .systemBlue, badge: "/rq", page: "pinyin",
        demo: DemoScript.make { s in
            s.caption("打 /rq 出今天的日期")
            s.type("/rq", todayCandidates)
            s.choose(0)
        })

    /// 打开这一页时演示卡片放的：几项主要功能连着放一遍，看 WoType 能做什么。指向下面的功能再放单项。
    static let overview: Feature = {
        let picks = ["整句输入", "按错键也能认出来", "打英文不用切换", "打字推荐 emoji", "候选翻译", "语音输入"]
        let all = typing + translation + shortcuts
        return Feature(title: "WoType 能做什么",
                       detail: "整句输入、按错键也认得、打英文不用切换、推荐表情、候选翻译、语音输入。指向下面的功能，看单项演示。",
                       symbol: "sparkles", color: .systemPink, badge: nil, page: "",
                       demo: picks.compactMap { title in all.first { $0.title == title } }.flatMap(\.demo))
    }()

    /// 日期时间的候选：今天。
    private static var todayCandidates: [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        return ["y年M月d日", "yyyy-MM-dd", "yyyy/MM/dd"].map { format in
            formatter.dateFormat = format
            return formatter.string(from: Date())
        }
    }
}

final class HomePage: SettingsPage {
    override var pageTitle: String { "功能介绍" }
    override var pageSubtitle: String { "指向一项功能即可看到演示。点按即可前往它的设置。" }

    private let hero = HeroCard()

    /// 演示卡片固定在上面：往下指功能时也看得到演示。
    override var pinnedView: NSView? { hero }

    override func build() -> [NSView] {
        hero.show(Feature.overview)
        hero.onOpen = { page in SettingsWindowController.shared.navigate(to: page) }
        return [
            SettingsKit.sectionTitle("打字"),
            list(Feature.typing),
            SettingsKit.sectionTitle("翻译"),
            list(Feature.translation),
            SettingsKit.sectionTitle("快捷键"),
            list(Feature.shortcuts(for: config.pinyinEngine)),
        ]
    }

    private func list(_ features: [Feature]) -> NSView {
        SettingsKit.card(features.map { feature in
            let row = NavRow(content: SettingsKit.row(
                title: feature.title, detail: feature.detail,
                icon: SettingsIcon(symbol: feature.symbol, color: feature.color),
                accessory: SettingsKit.trailing(badge: feature.badge)))
            row.onHover = { [weak self] in self?.hero.show(feature) }
            row.onClick = { SettingsWindowController.shared.navigate(to: feature.page) }
            return row
        })
    }
}

/// 首页最上面的演示卡片：左边是打字的样子，右边是功能名、说明、快捷键和「打开 ›」。
final class HeroCard: CardView {

    var onOpen: ((String) -> Void)?

    private let demo = HeroDemoView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = SettingsKit.wrappingLabel("", size: 13, color: .secondaryLabelColor)
    private let footer = NSStackView()
    private var page = ""
    private var shownTitle: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        footer.spacing = 12
        let texts = NSStackView(views: [titleLabel, detailLabel, footer])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 8
        texts.setCustomSpacing(12, after: detailLabel)
        for view in [demo, texts] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            demo.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            demo.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            demo.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            demo.widthAnchor.constraint(equalToConstant: 248),
            demo.heightAnchor.constraint(equalToConstant: 164),
            texts.leadingAnchor.constraint(equalTo: demo.trailingAnchor, constant: 22),
            texts.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            texts.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailLabel.widthAnchor.constraint(equalTo: texts.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ feature: Feature) {
        // 鼠标在同一项上进出不重放
        guard feature.title != shownTitle else { return }
        shownTitle = feature.title
        titleLabel.stringValue = feature.title
        detailLabel.stringValue = feature.detail
        demo.play(feature.demo)
        page = feature.page
        footer.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let badge = feature.badge {
            footer.addArrangedSubview(KeyBadge(badge))
        }
        // 总览没有对应的设置页，不放链接
        guard let name = SettingsSection.all.first(where: { $0.id == feature.page })?.title else { return }
        footer.addArrangedSubview(LinkButton(title: "打开“\(name)” ›") { [weak self] in
            guard let self else { return }
            self.onOpen?(self.page)
        })
    }
}

/// 演示画面：灰色底上一个小文本框（已上屏的字 + 带下划线的拼音），下面是候选窗，
/// 右上角是正在按的键，最下面一行字幕。按帧播放，放完从头再来。
final class HeroDemoView: NSView {

    private var frames: [DemoFrame] = []
    private var index = 0
    private var timer: Timer?
    private var current = DemoFrame() {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    func play(_ frames: [DemoFrame]) {
        timer?.invalidate()
        timer = nil
        self.frames = frames
        index = 0
        guard !frames.isEmpty else { return }
        // 减少动态效果：停在候选最全的那一帧
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            current = frames.last { !$0.candidates.isEmpty && $0.key == nil } ?? frames[frames.count - 1]
            return
        }
        current = frames[0]
        if window != nil { schedule() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        if window != nil, frames.count > 1, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { schedule() }
    }

    private func schedule() {
        let timer = Timer(timeInterval: current.hold, repeats: false) { [weak self] _ in
            guard let self, !self.frames.isEmpty else { return }
            self.index = (self.index + 1) % self.frames.count
            self.current = self.frames[self.index]
            self.schedule()
        }
        // 滚动列表时也接着放
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    override func draw(_ dirtyRect: NSRect) {
        let backdrop = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        Theme.settingsArt.setFill()
        backdrop.fill()

        let field = NSRect(x: 14, y: 36, width: bounds.width - 28, height: 34)
        drawField(field)
        let below = NSRect(x: field.minX + 4, y: field.maxY + 8, width: field.width - 8, height: 0)
        if let levels = current.voiceLevels {
            drawVoice(levels, below: below)
        } else if !current.candidates.isEmpty {
            drawPanel(below: below)
        }
        if let key = current.key { drawKey(key) }
        if !current.caption.isEmpty {
            let caption = NSAttributedString(string: current.caption, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor,
            ])
            caption.draw(at: NSPoint(x: field.minX + 2, y: 12))
        }
    }

    /// 文本框：已上屏的字 + 带下划线的拼音 + 光标；太长时往左滚，光标一直看得见。
    private func drawField(_ field: NSRect) {
        Theme.settingsCard.setFill()
        NSBezierPath(roundedRect: field, xRadius: 6, yRadius: 6).fill()
        let text = NSMutableAttributedString(string: current.committed, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor,
        ])
        text.append(NSAttributedString(string: current.pinyin, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]))
        let size = text.size()
        let x = min(field.minX + 10, field.maxX - 14 - size.width)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: field.insetBy(dx: 6, dy: 0)).addClip()
        text.draw(at: NSPoint(x: x, y: field.midY - size.height / 2))
        NSGraphicsContext.restoreGraphicsState()
        NSColor.controlAccentColor.setFill()
        NSRect(x: x + 1 + size.width, y: field.midY - 8, width: 1.5, height: 16).fill()
    }

    /// 候选窗：和真的一样高亮选中的那个；展开时排成固定列；有译文时最下面多一行。
    private func drawPanel(below: NSRect) {
        let columns = 6
        let rowHeight: CGFloat = 24
        let rows = current.expanded ? (current.candidates.count + columns - 1) / columns : 1
        var height = CGFloat(rows) * rowHeight + 10
        if current.translation != nil { height += 24 }
        let panel = NSRect(x: below.minX, y: below.minY, width: below.width, height: height)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        Theme.background.setFill()
        NSBezierPath(roundedRect: panel, xRadius: 8, yRadius: 8).fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: panel, xRadius: 8, yRadius: 8).addClip()
        let columnWidth = (panel.width - 10) / CGFloat(columns)
        var x = panel.minX + 5
        for (i, word) in current.candidates.enumerated() {
            let selected = i == current.highlight
            let label = NSAttributedString(string: "\(i % 9 + 1)", attributes: [
                .font: NSFont.systemFont(ofSize: 9), .foregroundColor: selected ? Theme.highlightText : Theme.secondaryText,
            ])
            let text = NSAttributedString(string: word, attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: selected ? Theme.highlightText : Theme.text,
            ])
            let cell: NSRect
            if current.expanded {
                cell = NSRect(x: panel.minX + 5 + CGFloat(i % columns) * columnWidth,
                              y: panel.minY + 5 + CGFloat(i / columns) * rowHeight,
                              width: columnWidth - 2, height: rowHeight - 2)
            } else {
                let width = label.size().width + 3 + text.size().width + 10
                cell = NSRect(x: x, y: panel.minY + 5, width: width, height: rowHeight)
                x += width + 2
            }
            if selected {
                Theme.highlight.setFill()
                NSBezierPath(roundedRect: cell, xRadius: 5, yRadius: 5).fill()
            }
            label.draw(at: NSPoint(x: cell.minX + 5, y: cell.midY - label.size().height / 2))
            text.draw(at: NSPoint(x: cell.minX + 8 + label.size().width, y: cell.midY - text.size().height / 2))
        }
        if let translation = current.translation {
            let lineY = panel.minY + 5 + rowHeight + 2
            NSColor.separatorColor.setFill()
            NSRect(x: panel.minX + 8, y: lineY, width: panel.width - 16, height: 0.5).fill()
            let text = NSAttributedString(string: "译  " + translation, attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: Theme.text,
            ])
            text.draw(at: NSPoint(x: panel.minX + 10, y: lineY + 11 - text.size().height / 2 + 1))
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 语音：文本框下面一个胶囊，红点加跳动的音量条。
    private func drawVoice(_ levels: [CGFloat], below: NSRect) {
        let capsule = NSRect(x: below.midX - 60, y: below.minY + 4, width: 120, height: 30)
        Theme.background.setFill()
        NSBezierPath(roundedRect: capsule, xRadius: 15, yRadius: 15).fill()
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: NSRect(x: capsule.minX + 12, y: capsule.midY - 4, width: 8, height: 8)).fill()
        Theme.text.setFill()
        for (i, level) in levels.enumerated() {
            let height = 4 + level * 14
            NSBezierPath(roundedRect: NSRect(x: capsule.minX + 32 + CGFloat(i) * 8, y: capsule.midY - height / 2,
                                             width: 3, height: height), xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    /// 右上角正在按的键。
    private func drawKey(_ key: String) {
        let text = NSAttributedString(string: key, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white,
        ])
        let size = text.size()
        let cap = NSRect(x: bounds.maxX - 14 - size.width - 18, y: 8, width: size.width + 18, height: 22)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: cap, xRadius: 6, yRadius: 6).fill()
        text.draw(at: NSPoint(x: cap.midX - size.width / 2, y: cap.midY - size.height / 2))
    }
}
