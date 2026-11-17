//
//  TranslationWindow.swift
//  WoType
//
//  翻译并显示的窗口（docs/16），照 Easydict 的固定窗口（EZBaseQueryWindow、EZBaseQueryViewController、
//  EZWindowManager、EZLayoutManager，screenshots/3.png）。对照表在 docs/16，这里只记要点：
//  - 带透明标题栏（28）的不激活面板：能拖空白处移动、能拖边改宽（最小 360），高度跟着内容；记住位置和宽度。
//  - 出现时成为 key、光标放进原文框（不激活 WoType）；失去 key 就收起（钉住的除外），Esc 收起。
//    出现时在浮动层，钉住提到工具层，取消钉住回普通层。
//  - 原文框、语言栏、每个开着的翻译源一张卡片（TranslationWindowViews）。几个源同时问，按设置的顺序排；
//    折叠着的不问，展开时再问；没有结果、语言不支持的自动折叠（手动展开过的不收）。每次查询代次加一，旧的结果丢掉。
//  - 高度：合并 0.08 秒里的变化，卡片的位置和高度、窗口高度用同一个进度一起动画（0.25 秒，先快后慢；
//    Easydict 是卡片立刻变、只有窗口动画，看着生硬；按距离 0.25～0.4 秒）；原文框行数变了马上过渡。
//    出现时是完整大小，0.15 秒淡入、从 97% 放大。顶边不动，往下长到屏幕底或
//    最大高度（屏幕可用高度的百分比，设置里选）就在窗口里滚动。出现、变高时挪回屏幕里，拖动不管（和 Easydict 一样）。
//  - 不用找选区在屏幕上的位置，也就不用打开浏览器的辅助功能树（打开了 Chrome 整个变慢）。
//

import Cocoa
import Carbon.HIToolbox
import FreeTranslate
import os

@MainActor
final class TranslationWindow: NSObject, NSWindowDelegate {

    static let shared = TranslationWindow()

    var isVisible: Bool { panel.isVisible }

    /// 标题栏这一行：照 screenshots/3.png，窗口顶边到第一张卡片 40（这一行 36.5 + 卡片上面的半个间距 3.5），
    /// 按钮在里面上下居中（中线离顶边 20）；图钉图形离左边 16，右边图标离右边 13.5
    private static let titleBar: CGFloat = 36.5
    private static let buttonCenter: CGFloat = 20
    /// 图钉画成 20×20（图形约 12×18.5，和 3.png 一样大），按钮离左边 10.5，图形正好离左边 16
    private static let pinLeft: CGFloat = 10.5
    private static let pinSize: CGFloat = 20
    private static let settingsRight: CGFloat = 13.5
    /// 卡片之间 7、左右各 10、最下面 6.5（EZBaseQueryViewController 的 intercellSpacing、contentInsets）
    private static let spacing: CGFloat = 7
    private static let margin: CGFloat = 10
    private static let bottomInset: CGFloat = 10 - 7 / 2
    private static let minSize = NSSize(width: 360, height: 40)
    /// 合并结果的等待（EZWindowHeightCoalescingInterval）；动画时长按距离 0.25～0.4 秒（applyHeight）
    private static let coalescing: TimeInterval = 0.08
    /// 改了原文以后多久重新认语言
    private static let detectDelay: TimeInterval = 1
    /// 窗口的位置和宽度（「上次的位置」、记住宽度用），存在 UserDefaults
    private static let frameKey = "translationWindowFrame"

    private let panel = QueryPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
                                   styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
                                   backing: .buffered, defer: true)
    private let root = FlippedView()
    /// 标题栏按钮 24×24：图钉用 Easydict 的图钉图片，右边是实心的系统符号
    private lazy var pinButton = HoverButton(symbol: "pin", tip: "钉住（点外面不收起）", target: self,
                                             action: #selector(togglePin))
    private lazy var settingsButton = HoverButton(symbol: "gearshape", tip: "划词翻译设置", target: self,
                                                  action: #selector(openSettings))
    /// 一直用悬浮滚动条（接着鼠标时系统会换成常驻的粗滚动条）
    private let scroll = OverlayScrollView()
    private let document = FlippedView()
    private let queryView = QueryView()
    private let languageBar = LanguageBar()
    private var cards: [ResultCard] = []

    /// 这一次翻的是什么（展开、重试时照这个问）
    private struct Query {
        let text: String
        let source: Language?
        let target: Language
    }
    private var query: Query?
    /// 每次查询加一：回来的结果代次对不上就丢掉（Easydict 的 resultGeneration）
    private var generation = 0
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// 选中的文字在输入框里、还没替换过：卡片显示「替换」
    private var replaceable = false
    /// 用「识别为」给某段文字指定的原文语言
    private var specified: [String: Language] = [:]
    private var detectWork: DispatchWorkItem?
    private var pinned = false

    /// 窗口高度：要更新、已经排了（updateWindowHeight 的标记；正在动画看 transition）
    private var needsHeight = false
    private var heightScheduled = false
    /// 自己改窗口大小时不当成用户拖边
    private var settingFrame = false

    private override init() {
        super.init()
        panel.delegate = self
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.backgroundColor = TranslationStyle.windowBackground
        panel.minSize = Self.minSize
        panel.onEscape = { [weak self] in self?.hide() }
        panel.contentView = root
        root.wantsLayer = true

        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        // 窗口高度动画里滚动区跟着窗口一起变，内容区保持完整高度（clip view 一点点露出来）
        scroll.autoresizingMask = [.width, .height]
        settingsButton.autoresizingMask = [.minXMargin]
        settingsButton.image = Self.titlebarSymbol("gearshape.fill")
        settingsButton.contentTintColor = TranslationStyle.titlebarIcon
        setPinned(false)
        for view in [scroll, pinButton, settingsButton] as [NSView] { root.addSubview(view) }
        for view in [queryView, languageBar] as [NSView] { document.addSubview(view) }

        queryView.onSubmit = { [weak self] in self?.startQuery() }
        queryView.onTextChange = { [weak self] in self?.textChanged() }
        queryView.onPickLanguage = { [weak self] language in self?.pick(language) }
        languageBar.onChange = { [weak self] in self?.startQuery() }
        languageBar.onSwap = { [weak self] in self?.swapLanguages() }

        // 记住的宽度（没有就照 Easydict：420 × 1727 / 屏幕宽）
        let width = Self.savedFrame?.width
            ?? 420 * 1727 / (NSScreen.main?.frame.width ?? 1727)
        panel.setContentSize(NSSize(width: max(width, Self.minSize.width), height: 200))
    }

    // MARK: - 出现

    /// 翻选中的文字（翻译并显示的快捷键）。editable：选中的文字在输入框里，可以替换
    func translate(_ text: String, editable: Bool = false) {
        replaceable = editable
        show(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 没读到选中的文字：打开空的窗口，可以自己输入
    func showEmpty() {
        replaceable = false
        show("")
    }

    /// 钉住着的就地换内容；没钉住的先清空、重新放位置（EZWindowManager showFloatingWindowType）
    private func show(_ text: String) {
        if panel.isVisible, pinned {
            queryView.text = text
            startQuery()
            panel.makeKeyAndOrderFront(nil)
            focusQuery()
            return
        }
        cancelAll()
        languageBar.set(source: nil, target: nil)
        queryView.text = text
        startQuery(layoutOnly: true)
        place()
        panel.level = .modalPanel
        appear()
        focusQuery()
        startQuery()
    }

    /// 出现：直接是完整大小，0.15 秒从透明、略小（97%）浮现出来（像 Spotlight），不一下子冒出来。
    /// 不先小后大地长：原文框长高的过程用户用不着看，每次打开多一段动画反而拖
    private func appear() {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        guard !reduceMotion, let layer = root.layer else { return }
        let center = CGPoint(x: root.bounds.midX, y: root.bounds.midY)
        var from = CATransform3DMakeTranslation(center.x, center.y, 0)
        from = CATransform3DScale(from, 0.97, 0.97, 1)
        from = CATransform3DTranslate(from, -center.x, -center.y, 0)
        let scale = CABasicAnimation(keyPath: "transform")
        scale.fromValue = from
        scale.toValue = CATransform3DIdentity
        scale.duration = 0.15
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(scale, forKey: "appear")
    }

    /// 光标放进原文框（窗口出现 0.1 秒后，照 Easydict）
    private func focusQuery() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.queryView.focus()
        }
    }

    // MARK: - 查询

    /// 按原文框里的文字、语言栏的选择，问每个开着、没折叠的翻译源。layoutOnly：只排好卡片（出现前算高度用）
    private func startQuery(layoutOnly: Bool = false) {
        cancelAll()
        generation += 1
        SpeechPlayer.shared.stop()
        cards.forEach { $0.removeFromSuperview() }
        cards = []
        let text = queryView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let detected = text.isEmpty ? nil : specified[text] ?? SelectionTranslator.detect(text)
        queryView.detected = detected
        queryView.detectEnabled = languageBar.source == nil
        guard !text.isEmpty else {
            query = nil
            languageBar.resolve(source: nil, target: nil)
            if layoutOnly { layoutRows() } else { applyHeight(animated: true) }
            return
        }
        let source = languageBar.source ?? specified[text]
        let target = languageBar.target ?? Self.automaticTarget(from: source ?? detected)
        languageBar.resolve(source: detected, target: target)
        query = Query(text: text, source: source, target: target)

        for engine in SelectionTranslator.enabledSources() {
            // 折叠只管当前这次结果：每次新的翻译全部展开（用户要求；Easydict 记住每个源的折叠，折叠的不问）
            let card = ResultCard(source: engine, showing: true)
            card.language = target
            card.replaceable = replaceable
            card.onToggle = { [weak self, weak card] in
                guard let self, let card else { return }
                self.toggle(card)
            }
            card.onRetry = { [weak self, weak card] in
                guard let self, let card else { return }
                self.ask(card)
            }
            card.onContentResize = { [weak self] in self?.updateHeight() }
            card.onStop = { [weak self, weak card] in
                guard let self, let card else { return }
                self.stop(card)
            }
            card.onReplace = { [weak self] text in self?.replace(with: text) }
            document.addSubview(card)
            cards.append(card)
        }
        guard !layoutOnly else {
            layoutRows()
            return
        }
        cards.forEach(ask)
        // 换了一批卡片（原文可能也变了，比如钉住时选了别的文字）：原文框、卡片、窗口一起过渡，
        // 新卡片从原文框原来的高度那里跟着滑到位
        applyHeight(animated: true)
    }

    /// 自动选择的目标语言：设置的「翻译成」，开着智能方向时原文已经是它就换（和翻译并替换一样）
    private static func automaticTarget(from source: Language?) -> Language {
        let config = Settings.shared.config
        let target = Language(config.selectionTarget)
        guard config.selectionSmartDirection, let source, SelectionTranslator.same(source, target) else { return target }
        return target == .simplifiedChinese ? .english : .simplifiedChinese
    }

    private func ask(_ card: ResultCard) {
        guard let query else { return }
        card.state = .loading
        let id = ObjectIdentifier(card)
        let engine = card.source
        let generation = generation
        tasks[id]?.cancel()
        streams[id] = nil
        if case .ai(let model) = engine.kind {
            askStreaming(card, model: model, query: query, generation: generation)
            updateHeight()
            return
        }
        tasks[id] = Task { [weak self, weak card] in
            let state: ResultCard.State
            do {
                let text = try await SelectionTranslator.shared.translate(query.text, from: query.source, to: query.target,
                                                                         with: engine)
                state = text.isEmpty ? .failed(.init(message: "没有结果", warning: true)) : .done(text)
            } catch let failure as SelectionTranslator.Failure {
                state = .failed(failure)
            } catch {
                state = .failed(.init(message: "翻译失败"))
            }
            guard !Task.isCancelled, let self, let card, generation == self.generation else { return }
            self.tasks[id] = nil
            card.state = state
            // 没有结果、语言不支持：自动折叠（手动展开过的不收）
            if case .failed(let failure) = state, failure.warning, !card.manualShow { card.showing = false }
            self.updateHeight()
        }
        updateHeight()
    }

    // MARK: - 流式（AI 翻译源）

    /// 一张卡片的流式状态：到目前为止收到的译文（停止时留下它）
    @MainActor
    private final class Stream {
        var latest = ""
    }
    private var streams: [ObjectIdentifier: Stream] = [:]

    /// AI 翻译源边生成边显示（docs/16 第二期，照 Easydict 的 StreamService 和 screenshots/4.mp4）：
    /// 收到的字马上交给卡片，卡片用打字机一个字一个字地出（最新的几个字从浅到深）、长高时窗口跟着平滑长高；
    /// 生成中有停止按钮；中途出错保留已经生成的、下面写原因；一个字都没有就和普通的失败一样
    private func askStreaming(_ card: ResultCard, model: CloudModel, query: Query, generation: Int) {
        let id = ObjectIdentifier(card)
        let stream = Stream()
        streams[id] = stream
        card.typewriter = true
        card.state = .streaming("")
        tasks[id] = Task { [weak self, weak card] in
            let state: ResultCard.State
            do {
                let result = try await SelectionTranslator.shared.streamAI(query.text, to: query.target, model: model) {
                    [weak self, weak card] text in
                    guard let self, let card, generation == self.generation, case .streaming = card.state else { return }
                    stream.latest = text
                    card.state = .streaming(text)
                    card.textArrived()
                }
                state = .done(result)
            } catch let failure as SelectionTranslator.Failure {
                state = stream.latest.isEmpty ? .failed(failure) : .interrupted(stream.latest, failure)
            } catch is CancellationError {
                return
            } catch {
                state = .failed(.init(message: "翻译失败"))
            }
            guard !Task.isCancelled, let self, let card, generation == self.generation else { return }
            self.tasks[id] = nil
            self.streams[id] = nil
            card.state = state
            if case .failed(let failure) = state, failure.warning, !card.manualShow { card.showing = false }
            self.updateHeight()
        }
    }

    /// 停止生成：已经生成的留着（Easydict 停止后 isStreamFinished，部分译文保留），一个字没有就当失败（可以重试）
    private func stop(_ card: ResultCard) {
        guard case .streaming(let shown) = card.state else { return }
        let id = ObjectIdentifier(card)
        let latest = streams[id]?.latest ?? shown
        tasks[id]?.cancel()
        tasks[id] = nil
        streams[id] = nil
        card.state = latest.isEmpty ? .failed(.init(message: "已停止")) : .interrupted(latest, nil)
        updateHeight()
    }

    private func cancelAll() {
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        streams = [:]
        detectWork?.cancel()
        detectWork = nil
    }

    /// 点标题栏：折叠 / 展开，只管当前这次结果，不记（Easydict 记进 enabledQuery）
    private func toggle(_ card: ResultCard) {
        guard card.hasShowingResult || query != nil else { return }
        card.showing.toggle()
        if card.showing { card.manualShow = true }
        if !card.showing { SpeechPlayer.shared.stop() }
        // 只排版、还没问过的（layoutOnly）展开时补问
        if card.showing, case .idle = card.state {
            ask(card)
        }
        // 直接点的不等合并，第一帧马上画（applyHeight 里）
        toggleStarted = CACurrentMediaTime()
        applyHeight(animated: true)
    }

    /// 点折叠到动画第一帧画出来用了多久（日志里看有没有延迟）
    private var toggleStarted: CFTimeInterval?

    /// ⇄（Easydict 的 toggle languages）：两边都是具体的语言就对调，再把第一个翻好的译文当原文回译；
    /// 两边都是自动就直接拿译文再翻
    private func swapLanguages() {
        let source = languageBar.source, target = languageBar.target
        let translation = cards.lazy.compactMap(\.translation).first
        if let source, let target, source != target {
            languageBar.set(source: target, target: source)
            if let translation { queryView.text = translation }
            startQuery()
        } else if source == nil, target == nil, let translation {
            queryView.text = translation
            startQuery()
        }
    }

    /// 「识别为」里指定了原文语言：记下这段文字的语言，重新翻
    private func pick(_ language: Language) {
        let text = queryView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        specified[text] = language
        startQuery()
    }

    /// 改了原文：重新排高度；停一秒再认语言（不自动翻，等回车）
    private func textChanged() {
        // 行数变了马上跟着长高 / 变矮（不等合并）
        applyHeight(animated: true)
        detectWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let text = self.queryView.text.trimmingCharacters(in: .whitespacesAndNewlines)
            self.queryView.detected = text.isEmpty ? nil : self.specified[text] ?? SelectionTranslator.detect(text)
            self.updateHeight()
        }
        detectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.detectDelay, execute: work)
    }

    // MARK: - 替换

    /// 译文换掉原来应用里选中的文字：交出键盘焦点，模拟 ⌘V，粘完把剪贴板还原。
    /// 替换过一次，所有卡片的「替换」都不再显示；钉住的窗口粘完放回来
    private func replace(with text: String) {
        replaceable = false
        cards.forEach { $0.replaceable = false }
        let keepOpen = pinned
        queryView.stopEditing()
        panel.orderOut(nil)
        if !keepOpen { hide() } else { updateHeight() }
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let source = CGEventSource(stateID: .combinedSessionState)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: down)
                event?.flags = .maskCommand
                event?.post(tap: .cghidEventTap)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                pasteboard.clearContents()
                let items = saved.map { pairs -> NSPasteboardItem in
                    let item = NSPasteboardItem()
                    for (type, data) in pairs { item.setData(data, forType: type) }
                    return item
                }
                if !items.isEmpty { pasteboard.writeObjects(items) }
                if keepOpen { self.panel.orderFrontRegardless() }
            }
        }
    }

    // MARK: - 排版、高度

    /// 每一格该在哪（排好了里面的控件，还没设到格子上）和内容总高
    private struct Layout {
        var frames: [(view: NSView, frame: NSRect)]
        var content: CGFloat
    }

    private func measure() -> Layout {
        let width = panel.contentView?.bounds.width ?? panel.frame.width
        let inner = width - Self.margin * 2
        var y = Self.spacing / 2
        let rows: [(NSView, CGFloat)] = [(queryView, queryView.layout(width: inner)),
                                         (languageBar, languageBar.layout(width: inner))]
            + cards.map { ($0, $0.layout(width: inner)) }
        var frames: [(view: NSView, frame: NSRect)] = []
        for (view, height) in rows {
            frames.append((view, NSRect(x: Self.margin, y: y, width: inner, height: height)))
            y += height + Self.spacing
        }
        // 取整：内容比窗口多出零点几点，滚动区就当成能滚，冒出滚动条
        return Layout(frames: frames, content: ceil(y - Self.spacing + Self.bottomInset))
    }

    /// 格子、内容区、标题栏按钮摆到位（content：内容区多高）
    private func apply(_ frames: [(view: NSView, frame: NSRect)], content: CGFloat) {
        let width = panel.contentView?.bounds.width ?? panel.frame.width
        for (view, frame) in frames where view.frame != frame {
            view.frame = frame
            view.needsDisplay = true
        }
        document.frame = NSRect(x: 0, y: 0, width: width, height: content)
        scroll.frame = NSRect(x: 0, y: Self.titleBar, width: width, height: max(root.bounds.height - Self.titleBar, 0))
        let buttonY = Self.buttonCenter - TranslationStyle.button / 2
        pinButton.frame.origin = NSPoint(x: Self.pinLeft, y: buttonY)
        // 齿轮图形 17 宽，在 24 的按钮里居中：按钮右边 = 图形右边 + 3.5
        settingsButton.frame.origin = NSPoint(x: width - Self.settingsRight - 3.5 - 17, y: buttonY)
    }

    /// 按现在的宽度立刻排好每一格（不做动画），返回内容总高
    @discardableResult
    private func layoutRows() -> CGFloat {
        let layout = measure()
        apply(layout.frames, content: layout.content)
        return layout.content
    }

    /// 内容变了（译文回来、改了原文）：合并 0.08 秒里的变化，再一起动画（updateWindowHeight）
    private func updateHeight() {
        needsHeight = true
        guard transition == nil, !heightScheduled else { return }
        guard panel.isVisible, !panel.inLiveResize else {
            applyHeight(animated: false)
            return
        }
        heightScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.coalescing) { [weak self] in
            guard let self else { return }
            self.heightScheduled = false
            if self.needsHeight { self.applyHeight(animated: true) }
        }
    }

    /// 卡片、下面的卡片、窗口高度一起走到新的布局。
    /// Easydict 是卡片立刻变、只有窗口动画（applyWindowHeightAnimated），内容先跳、外框再追，看着生硬；
    /// 这里每一帧用同一个进度算卡片的位置和高度、内容区高度、窗口高度（0.25 秒，先快后慢），三者始终对得上
    private func applyHeight(animated: Bool) {
        needsHeight = false
        let layout = measure()
        let target = targetFrame(content: layout.content)
        let animate = animated && panel.isVisible && !panel.inLiveResize
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard animate else {
            stopTransition()
            apply(layout.frames, content: layout.content)
            setWindowFrame(target)
            limitHeight(target.height, target.height)
            return
        }
        let unchanged = layout.frames.allSatisfy { $0.view.frame == $0.frame }
            && abs(target.height - panel.frame.height) < 0.5 && abs(target.minY - panel.frame.minY) < 0.5
        guard !unchanged else {
            apply(layout.frames, content: layout.content)
            limitHeight(target.height, target.height)
            return
        }
        // 正在动的接着从现在的位置走（新加的卡片直接在目标位置）
        // 新卡片（还没排过）：从原文框原来的高度对应的位置跟着滑下来 / 上去，不和原文框叠在一起
        let queryShift = (layout.frames.first { $0.view === queryView }?.frame.maxY ?? 0) - queryView.frame.maxY
        let from = Dictionary(uniqueKeysWithValues: layout.frames.map { row in
            (ObjectIdentifier(row.view),
             row.view.frame == .zero ? row.frame.offsetBy(dx: 0, dy: -queryShift) : row.view.frame)
        })
        // 走得越远越慢一点：0.25 秒起，最多 0.4 秒（几百点的变化 0.25 秒走完像弹出去）
        var distance = abs(target.height - panel.frame.height)
        for row in layout.frames {
            let old = from[ObjectIdentifier(row.view)] ?? row.frame
            distance = max(distance, abs(old.minY - row.frame.minY), abs(old.height - row.frame.height))
        }
        let duration = min(max(0.25 + (Double(distance) - 80) / 1200, 0.25), 0.4)
        transition = Transition(from: from, to: layout, fromContent: document.frame.height,
                                fromWindow: panel.frame, toWindow: target, start: CACurrentMediaTime(),
                                duration: duration)
        limitHeight(min(panel.frame.height, target.height), max(panel.frame.height, target.height))
        if displayLink == nil {
            let link = root.displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        // 第一帧马上走一小步，不等下一次屏幕刷新
        step()
    }

    private struct Transition {
        let from: [ObjectIdentifier: NSRect]
        let to: Layout
        let fromContent: CGFloat
        let fromWindow: NSRect
        let toWindow: NSRect
        let start: CFTimeInterval
        let duration: CFTimeInterval
    }
    private var transition: Transition?
    private var displayLink: CADisplayLink?

    @objc private func tick(_ link: CADisplayLink) {
        step()
    }

    private func step() {
        guard let transition else { return stopTransition() }
        // 第一帧至少走 1/60 秒的量：刚开始时 t 是 0，画面不动，看着像慢半拍
        let t = min(max(CACurrentMediaTime() - transition.start, 1.0 / 60) / transition.duration, 1)
        // easeInOut 偏快的一侧（先快后慢）：三次缓出
        let e = CGFloat(1 - pow(1 - t, 3))
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { (a + (b - a) * e).rounded() }
        let frames = transition.to.frames.map { row -> (view: NSView, frame: NSRect) in
            let from = transition.from[ObjectIdentifier(row.view)] ?? row.frame
            return (row.view, NSRect(x: row.frame.minX, y: mix(from.minY, row.frame.minY), width: row.frame.width,
                                     height: mix(from.height, row.frame.height)))
        }
        let height = mix(transition.fromWindow.height, transition.toWindow.height)
        let top = transition.fromWindow.maxY + (transition.toWindow.maxY - transition.fromWindow.maxY) * e
        setWindowFrame(NSRect(x: transition.toWindow.minX, y: top - height, width: transition.toWindow.width, height: height))
        apply(frames, content: max(mix(transition.fromContent, transition.to.content), 0))
        if let started = toggleStarted {
            toggleStarted = nil
            Log.input.info("翻译窗口：点折叠到动画第一帧 \(Int((CACurrentMediaTime() - started) * 1000)) ms")
        }
        guard t >= 1 else { return }
        apply(transition.to.frames, content: transition.to.content)
        setWindowFrame(transition.toWindow)
        limitHeight(transition.toWindow.height, transition.toWindow.height)
        stopTransition()
        // 动画时来的更新接着走
        if needsHeight { applyHeight(animated: true) }
    }

    private func stopTransition() {
        displayLink?.invalidate()
        displayLink = nil
        transition = nil
    }

    private func setWindowFrame(_ frame: NSRect) {
        guard panel.frame != frame else { return }
        settingFrame = true
        panel.setFrame(frame, display: true)
        settingFrame = false
    }

    /// 内容要多高的窗口：顶边不动，最高到最大高度、到屏幕底（至少留最小高度），再挪回屏幕里
    private func targetFrame(content: CGFloat) -> NSRect {
        let visible = Self.screen(for: panel).visibleFrame
        var height = min(content + Self.titleBar, Self.maxHeight(in: visible))
        let top = panel.frame.maxY
        height = min(height, max(top - visible.minY, Self.minSize.height + Self.titleBar))
        return Self.safe(NSRect(x: panel.frame.minX, y: top - height, width: panel.frame.width, height: height),
                         in: visible)
    }

    /// 最高多高：屏幕可用高度 × 设置的百分比（maximumWindowSize）
    private static func maxHeight(in visible: NSRect) -> CGFloat {
        let percent = CGFloat(min(max(Settings.shared.config.selectionWindowMaxHeight, 20), 100))
        return min(max(visible.height * percent / 100, minSize.height), visible.height)
    }

    /// 用户只能拖宽度，高度跟着内容
    private func limitHeight(_ minHeight: CGFloat, _ maxHeight: CGFloat) {
        panel.minSize = NSSize(width: Self.minSize.width, height: minHeight)
        panel.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: maxHeight)
    }

    // MARK: - 位置

    /// 出现时放在哪（getFloatingWindowLocation）：屏幕右侧（贴右边、上下居中）、上次的位置、鼠标处
    private func place() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = panel.frame.width
        let height = min(layoutRows() + Self.titleBar, Self.maxHeight(in: visible))
        let right = NSPoint(x: visible.maxX - width, y: visible.midY + height / 2)
        let topLeft: NSPoint
        switch Settings.shared.config.selectionWindowPosition {
        case .right:
            topLeft = right
        case .last:
            topLeft = Self.savedFrame.map { NSPoint(x: $0.minX, y: $0.maxY) } ?? right
        case .mouse:
            topLeft = mouse
        }
        let target = Self.safe(NSRect(x: topLeft.x, y: topLeft.y - height, width: width, height: height),
                               in: Self.screen(at: topLeft, fallback: visible))
        settingFrame = true
        limitHeight(height, height)
        panel.setFrame(target, display: false)
        settingFrame = false
        layoutRows()
        scroll.contentView.scroll(to: .zero)
    }

    /// 挪进屏幕可见区域（EZCoordinateUtils getSafeAreaFrame）
    private static func safe(_ frame: NSRect, in visible: NSRect) -> NSRect {
        if visible.contains(frame) { return frame }
        var rect = frame
        if rect.minX < visible.minX { rect.origin.x = visible.minX }
        if rect.maxX > visible.maxX { rect.origin.x = visible.maxX - rect.width }
        if rect.minY > visible.maxY { rect.origin.y = visible.maxY }
        if rect.minY < visible.minY, rect.height <= visible.height { rect.origin.y = visible.minY }
        return rect
    }

    private static func screen(for window: NSWindow) -> NSScreen {
        window.screen ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private static func screen(at point: NSPoint, fallback: NSRect) -> NSRect {
        NSScreen.screens.first { $0.frame.insetBy(dx: -1, dy: -1).contains(point) }?.visibleFrame ?? fallback
    }

    private static var savedFrame: NSRect? {
        UserDefaults.standard.string(forKey: frameKey).map(NSRectFromString).flatMap { $0.width > 0 ? $0 : nil }
    }

    // MARK: - 窗口事件

    func windowDidMove(_ notification: Notification) {
        saveFrame()
    }

    func windowDidResize(_ notification: Notification) {
        saveFrame()
        // 用户拖边改宽：重新排，高度直接跟上
        guard !settingFrame, panel.isVisible else { return }
        applyHeight(animated: false)
    }

    /// 失去 key 就收起（钉住的除外，Easydict 的 closeFloatingWindowIfNotPinned）
    func windowDidResignKey(_ notification: Notification) {
        if !pinned { hide() }
    }

    private func saveFrame() {
        guard panel.isVisible else { return }
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: Self.frameKey)
    }

    // MARK: - 收起

    func hide() {
        guard panel.isVisible else { return }
        stopTransition()
        cancelAll()
        generation += 1
        SpeechPlayer.shared.stop()
        queryView.stopEditing()
        setPinned(false)
        panel.orderOut(nil)
    }

    // MARK: - 标题栏

    @objc private func togglePin() {
        setPinned(!pinned)
    }

    /// 钉住提到工具层，取消回普通层（EZBaseQueryWindow updateWindowLevel）
    private func setPinned(_ on: Bool) {
        pinned = on
        // 没钉住：灰色图钉（模板图，跟着浅色 / 深色着色）；钉住：蓝色图钉原图
        let image = NSImage(named: on ? "titlebar-pin-selected" : "titlebar-pin")?.copy() as? NSImage
        image?.size = NSSize(width: Self.pinSize, height: Self.pinSize)
        pinButton.image = image
        pinButton.contentTintColor = on ? nil : TranslationStyle.titlebarIcon
        pinButton.toolTip = on ? "取消钉住" : "钉住（点外面不收起）"
        if panel.isVisible {
            panel.level = on ? NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.utilityWindow))) : .normal
        }
    }

    /// 标题栏右边的系统符号：实心、约 17×17（3.png 右边的图标 16～17）
    private static func titlebarSymbol(_ name: String) -> NSImage {
        let image = TranslationStyle.symbol(name, size: 16, weight: .medium)
        let side: CGFloat = 17
        let scale = min(side / image.size.width, side / image.size.height)
        image.size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        return image
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.open(page: "translate")
    }
}

/// 翻译窗口：能成为 key（改原文、选译文），不能成为 main。Esc 收起（在原文框里打拼音时 Esc 照常取消拼音）
private final class QueryPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53,
           (firstResponder as? NSTextView)?.hasMarkedText() != true {
            onEscape?()
            return
        }
        super.sendEvent(event)
    }
}
