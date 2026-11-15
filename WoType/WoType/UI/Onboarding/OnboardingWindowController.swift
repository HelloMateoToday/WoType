//
//  OnboardingWindowController.swift
//  WoType
//
//  新手引导窗口（docs/18），布局照 Arion ui/pages/onboarding：960×600，左边 440 宽是插图（放得下缩小的横排候选窗），
//  右边顶上是进度点，中间是这一步的内容，底下是「返回」和「继续 / 完成」。
//  「继续」能不能点由 OnboardingFlow.ready 按真实状态定；翻页往前进的方向滑（OnboardingMotion）。
//
//  四种打开方式：
//  - 设置窗口侧边栏的「新手引导」；
//  - 还没弹过引导时，输入法启动后自动弹出；
//  - 安装器的「开始使用」（docs/19）：WoType 没在跑就带 --show-onboarding 启动它，在跑就发 showRequest 通知。
//    引导和输入法在同一个进程里，用户边看边用 WoType（单独运行的引导和输入法是同一个 App，开着时系统不再启动输入法）；
//  - 单独运行，调试不用装：open -n …/WoType.app --args --onboarding [--step 5] [--mock]。
//    这时不注册输入法、不准备拼音引擎（main.swift），关窗口就退出。
//

import Cocoa

final class OnboardingWindowController: NSWindowController, NSWindowDelegate {

    /// 单独运行（--onboarding）
    nonisolated static let isStandalone = CommandLine.arguments.contains("--onboarding")

    /// 安装器的「开始使用」请正在跑的 WoType 打开引导（分布式通知，docs/19）
    nonisolated static let showRequest = Notification.Name("com.acme.inputmethod.WoType.showOnboarding")

    /// 点过「完成」。存在 UserDefaults 里（和输入法进程、单独运行的进程共用）
    static var isCompleted: Bool {
        get { UserDefaults.standard.bool(forKey: "onboardingCompleted") }
        set { UserDefaults.standard.set(newValue, forKey: "onboardingCompleted") }
    }

    /// 自动弹出过（第一次装好以后弹一次，不管点没点「完成」，以后都不再自动弹；设置里还能打开）
    static var wasShown: Bool {
        get { UserDefaults.standard.bool(forKey: "onboardingShown") }
        set { UserDefaults.standard.set(newValue, forKey: "onboardingShown") }
    }

    /// 调试：不看条件，每一步都能继续（--mock，或设置页的调试开关）
    static var ignoresChecks = CommandLine.arguments.contains("--mock")

    /// 用到时才建，关掉就放掉（和设置窗口一样）。
    static var shared: OnboardingWindowController {
        if let instance { return instance }
        let controller = OnboardingWindowController()
        instance = controller
        return controller
    }
    private static var instance: OnboardingWindowController?

    /// 引导窗口开着时是它，没开着是 nil。
    static var visibleWindow: NSWindow? {
        guard let window = instance?.window, window.isVisible else { return nil }
        return window
    }

    static let pane: CGFloat = 440
    static let inset: CGFloat = 44

    private let model = OnboardingModel()
    private var flow = OnboardingFlow()
    private let illustration = OnboardingIllustrationView()
    private let stepper = OnboardingStepper()
    private let stepContainer = NSView()
    private var stepView: OnboardingStepView?
    private let backButton = NSButton(title: "返回", target: nil, action: nil)
    private let nextButton = NSButton(title: "继续", target: nil, action: nil)
    private var observers: [NSObjectProtocol] = []
    /// 试用时临时切到了 ABC，离开时要切回 WoType
    private var switchedAway = false
    /// 按键监视：画面上的键帽跟着真实按键按下去（KeyCapPresses）
    private var keyMonitor: Any?

    /// 有试用区、要自己接按键的几步：单独运行时，装好的 WoType 是当前输入法的话，⌃、⌃⌥T、⌃⌥I
    /// 它也会收到（2026-11-13 实测：两个进程各开了一次语音，⌃⌥T 被它的全局热键截走，
    /// 而且它会把结果插进上一个应用的输入框）。这几步窗口在前台时临时切到 ABC。
    /// 在输入法进程里打开的不用切（菜单栏一直是 W，用户才不糊涂）：InputController 只收别的应用交过来的按键，
    /// 引导自己窗口里的按键不经过它；⌃⌥T 的全局热键「翻译并显示」那一步自己停掉
    static let practiceSteps: Set<OnboardingStep> = [.typing, .selectionShow, .selectionReplace]

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "WoType 新手引导"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = Theme.settingsBackground
        super.init(window: window)
        window.delegate = self
        window.contentView = makeContent()
        window.center()

        model.ignoresChecks = Self.ignoresChecks
        model.start()
        observers.append(NotificationCenter.default.addObserver(
            forName: OnboardingModel.didChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateControls(animated: true) }
            })
        observers.append(NotificationCenter.default.addObserver(
            forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.illustration.settingsChanged() }
            })
        observers.append(NotificationCenter.default.addObserver(
            forName: KeyCapPresses.didChange, object: nil, queue: .main) { [weak self] _ in
                // 正文里的键帽是文本附件：重画那些文字
                MainActor.assumeIsolated { self?.window?.contentView.map(Self.redisplay) }
            })
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) { [weak self] event in
            nonisolated(unsafe) let event = event
            MainActor.assumeIsolated {
                if event.window != nil, event.window === self?.window { KeyCapPresses.update(with: event) }
            }
            return event
        }
        showStep(animated: false)
    }

    private static func redisplay(_ view: NSView) {
        if view is NSTextField { view.needsDisplay = true }
        view.subviews.forEach(redisplay)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func makeContent() -> NSView {
        let root = SettingsBackgroundView()
        stepContainer.wantsLayer = true
        // 翻页时滑进来的那一页不画到左边的插图上
        stepContainer.layer?.masksToBounds = true

        backButton.bezelStyle = .rounded
        backButton.isBordered = false
        backButton.contentTintColor = .secondaryLabelColor
        backButton.controlSize = .large
        backButton.target = self
        backButton.action = #selector(back)
        nextButton.bezelStyle = .rounded
        nextButton.controlSize = .large
        nextButton.keyEquivalent = "\r"
        nextButton.target = self
        nextButton.action = #selector(next)

        for view in [illustration, stepper, stepContainer, backButton, nextButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        let inset = Self.inset
        NSLayoutConstraint.activate([
            illustration.topAnchor.constraint(equalTo: root.topAnchor),
            illustration.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            illustration.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            illustration.widthAnchor.constraint(equalToConstant: Self.pane),

            // 进度点在标题栏下面
            stepper.topAnchor.constraint(equalTo: root.topAnchor, constant: 44),
            stepper.leadingAnchor.constraint(equalTo: illustration.trailingAnchor, constant: inset),

            stepContainer.topAnchor.constraint(equalTo: stepper.bottomAnchor, constant: 8),
            stepContainer.leadingAnchor.constraint(equalTo: illustration.trailingAnchor),
            stepContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stepContainer.bottomAnchor.constraint(equalTo: nextButton.topAnchor, constant: -16),

            nextButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
            nextButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
            nextButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 88),
            backButton.leadingAnchor.constraint(equalTo: illustration.trailingAnchor, constant: inset - 8),
            backButton.centerYAnchor.constraint(equalTo: nextButton.centerYAnchor),
        ])
        return root
    }

    /// 打开引导窗口；给了 step 就从那一步开始。
    func open(from step: OnboardingStep? = nil) {
        // 窗口在屏幕上停满 5 秒（或者用户自己关掉）才算弹过：安装脚本打开一下就结束进程的那一次不算。
        // 单独运行的预览不算，免得调试时把真正的第一次用掉
        if !Self.isStandalone {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                if self?.window?.isVisible == true { Self.wasShown = true }
            }
        }
        let opening = window?.isVisible != true
        if let step, step != flow.step {
            flow = OnboardingFlow(step: step)
            showStep(animated: false)
        }
        // 后台进程拿不到键盘焦点：开窗口时切成辅助 App，不出 Dock 图标（和设置窗口一样）
        if NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if opening, let layer = stepView?.layer {
            OnboardingMotion.enter(layer, direction: 0)
        }
        stepView?.didAppear()
    }

    /// 调试开关改了（设置页）。窗口没开着时只记下来，不为它建窗口。
    static func setIgnoresChecks(_ on: Bool) {
        ignoresChecks = on
        instance?.model.ignoresChecks = on
    }

    // MARK: - 翻页

    private func showStep(animated: Bool) {
        let old = stepView
        old?.willDisappear()
        window?.makeFirstResponder(nil)
        let context = OnboardingContext(model: model, advance: { [weak self] in self?.next() },
                                        openSettings: { [weak self] in self?.finish(openSettings: true) },
                                        practiceEvent: { [weak self] event in self?.illustration.handle(event) })
        let view = OnboardingStepView(step: flow.step, context: context)
        stepView = view
        view.translatesAutoresizingMaskIntoConstraints = false
        stepContainer.addSubview(view)
        let inset = Self.inset
        // 内容竖着居中，太高时从顶上排
        let centered = view.centerYAnchor.constraint(equalTo: stepContainer.centerYAnchor)
        centered.priority = .defaultHigh
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: stepContainer.leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(lessThanOrEqualTo: stepContainer.trailingAnchor, constant: -inset),
            view.topAnchor.constraint(greaterThanOrEqualTo: stepContainer.topAnchor, constant: 8),
            centered,
        ])
        updateInputSource()
        illustration.show(flow.step, state: model.state, animated: animated)
        updateControls(animated: animated)
        if window?.isVisible == true {
            DispatchQueue.main.async { [weak view] in view?.didAppear() }
        }
        guard animated, let old else {
            old?.removeFromSuperview()
            return
        }
        stepContainer.layoutSubtreeIfNeeded()
        OnboardingMotion.exit(old)
        if let layer = view.layer {
            OnboardingMotion.enter(layer, direction: flow.direction)
        }
    }

    private func updateControls(animated: Bool) {
        let state = model.state
        backButton.isHidden = flow.isFirst
        nextButton.title = flow.isFirst ? "开始" : flow.isLast(state) ? "完成" : "继续"
        nextButton.isEnabled = OnboardingFlow.ready(flow.step, state)
        let progress = flow.progress(state)
        stepper.set(current: progress.current, total: progress.total, animated: animated)
        illustration.update(state)
    }

    @objc private func next() {
        let state = model.state
        if flow.isLast(state) {
            guard OnboardingFlow.ready(flow.step, state) else { return }
            finish(openSettings: false)
        } else if flow.move(1, state) {
            showStep(animated: true)
        }
    }

    /// 完成引导、关窗口；openSettings 时接着打开设置窗口（「更多设置」那一步的「打开设置」）
    private func finish(openSettings: Bool) {
        Self.isCompleted = true
        window?.close()
        if openSettings { SettingsWindowController.shared.open() }
    }

    @objc private func back() {
        if flow.move(-1, model.state) {
            showStep(animated: true)
        }
    }

    // MARK: - 关闭

    // MARK: - 试用时的输入法

    /// 单独运行、试用的几步、窗口在前台：切到 ABC；否则切回 WoType（只切回自己切走的）。
    private func updateInputSource() {
        let practicing = Self.isStandalone && window?.isKeyWindow == true && Self.practiceSteps.contains(flow.step)
        if practicing, !switchedAway, InputSource.status().selected {
            switchedAway = InputSource.selectKeyboardLayout()
        } else if !practicing, switchedAway {
            switchedAway = false
            InputSource.selectWoType()
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        updateInputSource()
    }

    func windowDidResignKey(_ notification: Notification) {
        updateInputSource()
        KeyCapPresses.clear()
    }

    func windowWillClose(_ notification: Notification) {
        if !Self.isStandalone { Self.wasShown = true }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        KeyCapPresses.clear()
        if switchedAway {
            switchedAway = false
            InputSource.selectWoType()
        }
        stepView?.willDisappear()
        illustration.stopAll()
        CandidatePanel.shared.hide()
        model.stop()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        if Self.isStandalone {
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return
        }
        // 设置窗口也关了才切回后台进程
        if SettingsWindowController.visibleWindow == nil {
            NSApp.setActivationPolicy(.prohibited)
        }
        DispatchQueue.main.async {
            if Self.instance === self, self.window?.isVisible != true {
                self.window?.contentView = nil
                self.window?.delegate = nil
                Self.instance = nil
            }
        }
    }

    // MARK: - 单独运行

    /// --step 后面的数字（1～13）或步骤名（permissions、voice、voiceModels、providers、voiceKey、moreSettings…）。
    static var stepArgument: OnboardingStep? {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--step"), args.count > flag + 1 else { return nil }
        let value = args[flag + 1]
        if let number = Int(value) { return OnboardingStep(rawValue: number - 1) }
        return OnboardingStep.allCases.first { "\($0)".lowercased() == value.lowercased() }
    }
}
