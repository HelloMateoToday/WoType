//
//  OnboardingSteps.swift
//  WoType
//
//  新手引导每一步的内容（docs/18）：标题、说明，下面是这一步真能用的控件——
//  启用输入法、选引擎、试用区（PracticeInput.swift）、划词翻译、语音（识别方式、润色和翻译用什么）、
//  下载模型、添加服务商、语音的试用。
//  说明、清单、提示里的按键画成键帽（KeyCaps.text，写法是 {control}、{control+option+T}）。
//  下载进度、授权、启用这些会变的部分放在 LiveSection 里，收到通知整段重建。
//

import Cocoa
import FreeTranslate
import KeyboardShortcuts
import os

/// 步骤页面要窗口做的事。
struct OnboardingContext {
    let model: OnboardingModel
    /// 往下一步（「以后再下」「以后再加」）
    let advance: () -> Void
    /// 完成引导、关窗口，接着打开设置窗口（最后一步的「打开设置」）
    let openSettings: () -> Void
    /// 试用区里的事，插图跟着动（按下语音键）
    let practiceEvent: (PracticeInputController.Event) -> Void
}

/// 一步的内容：标题、说明，下面是这一步的控件。
final class OnboardingStepView: NSView {

    static let contentWidth: CGFloat = 420

    let step: OnboardingStep
    private let context: OnboardingContext
    private let stack = NSStackView()
    /// 这一步的试用区（要在页面出现时拿到焦点）
    private var practice: PracticeBox?
    /// 翻译并显示那一步：自己接 ⌃⌥T
    private var keyMonitor: Any?
    private var settingsObserver: NSObjectProtocol?
    private var checklist: Checklist?
    private var hint: NSTextField?

    init(step: OnboardingStep, context: OnboardingContext) {
        self.step = step
        self.context = context
        super.init(frame: .zero)
        wantsLayer = true
        stack.orientation = .vertical
        stack.alignment = .leading
        // 语音那一步卡片多，排紧一点才放得下
        stack.spacing = step == .voice ? 12 : 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.contentWidth),
        ])
        // 设置里的行只有最小高度，整页的高度本来是不定的：右边控件高的时候，多出来的高度会随便分给某一行。
        // 用最低的优先级要求「越矮越好」，整页收到刚好放下内容的高度
        let compact = heightAnchor.constraint(equalToConstant: 0)
        compact.priority = NSLayoutConstraint.Priority(1)
        compact.isActive = true
        // 语音键默认右 ⌘：每次打开引导，第一次走到这一步时设一次，之后用户在这一步改的照用
        if step == .voiceKey, !context.model.voiceKeyDefaulted {
            context.model.voiceKeyDefaulted = true
            Self.setVoiceKey(.rightCommand)
        }
        let (title, body) = Self.copy(step, engine: Settings.shared.config.pinyinEngine)
        stack.addArrangedSubview(heading(title, body))
        for view in content() {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 页面出现了：试用区拿焦点；翻译并显示接管 ⌃⌥T。
    func didAppear() {
        if let practice { window?.makeFirstResponder(practice.textView) }
        if step == .selectionShow { startShowKeys() }
    }

    /// 页面要走了：试用区交出焦点（还回候选窗），⌃⌥T 还给输入法。
    func willDisappear() {
        if let practice, window?.firstResponder === practice.textView { window?.makeFirstResponder(nil) }
        if step == .selectionShow { stopShowKeys() }
        practice?.stop()
        translateTask?.cancel()
        TranslationPanel.shared.hide()
        TranslationWindow.shared.hide()
        ModeToast.shared.hideLoading(animated: false)
    }

    private func heading(_ title: String, _ body: String) -> NSView {
        let welcome = step == .welcome
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: welcome ? 28 : 22, weight: welcome ? .bold : .semibold)
        let bodyLabel = text(body, size: welcome ? 15 : 13)
        bodyLabel.widthAnchor.constraint(equalToConstant: welcome ? Self.contentWidth : 400).isActive = true
        var views: [NSView] = [titleLabel, bodyLabel]
        if welcome {
            let mark = NSImageView(image: NSApp.applicationIconImage)
            mark.translatesAutoresizingMaskIntoConstraints = false
            mark.widthAnchor.constraint(equalToConstant: 64).isActive = true
            mark.heightAnchor.constraint(equalToConstant: 64).isActive = true
            views.insert(mark, at: 0)
        }
        let column = NSStackView(views: views)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = welcome ? 10 : 8
        if welcome { column.setCustomSpacing(16, after: views[0]) }
        return column
    }

    /// 划词翻译两个快捷键在说明里的写法（用户在设置里改过的照实画）
    static var showToken: String {
        let token = KeyCaps.token(for: KeyboardShortcuts.getShortcut(for: .translateShow))
        return token.isEmpty ? "{control+option+T}" : token
    }
    static var replaceToken: String {
        let token = KeyCaps.token(for: KeyboardShortcuts.getShortcut(for: .translateReplace))
        return token.isEmpty ? "{control+option+I}" : token
    }


    /// 语音键在说明里的写法：右侧 {command}、{fn}
    static func voiceKeyText(_ key: VoiceKey) -> String {
        switch key {
        case .fn: "{fn}"
        case .rightOption: "右侧 {option}"
        case .rightCommand: "右侧 {command}"
        }
    }

    /// 标题和说明（说明里的 {…} 画成键帽）。
    static func copy(_ step: OnboardingStep, engine: String) -> (String, String) {
        switch step {
        case .welcome:
            ("欢迎使用 WoType", "像微信输入法一样顺手的拼音输入法，打字在本机处理。花两分钟设置好，顺便试试几个好用的功能。")
        case .enable:
            ("添加输入法", "照左边的步骤，在「系统设置 › 键盘 › 输入法」里点「编辑…」› ＋，在「简体中文」里选 WoType 添加，再到菜单栏切换到 WoType。")
        case .permissions:
            ("允许权限", "语音输入、划词翻译、符号自动补全要用到这两项权限，都在本机使用，不会上传。")
        case .engine:
            ("选择拼音引擎", "两个引擎都在本机运行，以后可以在设置里随时换。下面的模型能让首选更准，不下载也能正常打字。")
        case .typing:
            ("试试打字和候选翻译", "在下面打 nihao，候选出来后单按 {control}，高亮的候选翻成英文，再按 {return} 上屏译文。")
        case .selectionShow:
            ("翻译并显示", "选中任何地方的文字，按 \(showToken)，译文显示在翻译窗口里。网页、PDF 里的字也行。")
        case .selectionReplace:
            ("翻译并替换", "在输入框里按 \(replaceToken)，选中的文字（没选就是整个输入框）直接换成译文。")
        case .voice:
            ("语音输入", "按住一个键说话，松开后文字打进输入框。先选识别和润色用什么，要下载的模型、要添加的服务商在后面。")
        case .voiceModels:
            ("下载模型", "语音要用的本机模型。在后台下载，可以先往下走；下载一次以后离线可用。")
        case .providers:
            ("添加服务商", "用你自己的 API 密钥，密钥只存在本机。")
        case .voiceTranslate:
            ("语音翻译", "按住翻译键说中文，松开后直接输入译文。不用先开润色。")
        case .voiceKey:
            ("试试语音输入", "选一个语音键，然后在「文本编辑」里按住它说话，松开后文字就打进去了。")
        case .moreSettings:
            ("更多设置", "候选外观、自定义词、快捷短语、语音和模型……都在 WoType 设置里，随时可以改。")
        }
    }

    private func content() -> [NSView] {
        switch step {
        case .welcome: return []
        case .enable: return [LiveSection { [weak self] in self?.enableRows() ?? [] }]
        case .permissions: return [LiveSection { [weak self] in self?.permissionRows() ?? [] }]
        case .engine: return engineChoices() + [LiveSection { [weak self] in self?.engineModelRows() ?? [] }]
        case .typing: return typingRows()
        case .selectionShow: return showRows()
        case .selectionReplace: return replaceRows()
        case .voice: return voiceRows()
        case .voiceModels: return [LiveSection { [weak self] in self?.voiceModelsRows() ?? [] }]
        case .providers: return [LiveSection { [weak self] in self?.providerRows() ?? [] }]
        case .voiceTranslate: return [LiveSection { [weak self] in self?.voiceTranslateRows() ?? [] }]
        case .voiceKey: return voiceKeyRows()
        case .moreSettings: return moreSettingsRows()
        }
    }

    // MARK: - 2 启用

    private func enableRows() -> [NSView] {
        let state = context.model.state
        var views: [NSView] = [SettingsKit.card([
            SettingsKit.row(title: "加入输入法列表", icon: SettingsIcon(symbol: "list.bullet", color: .systemBlue),
                            accessory: Status(state.inputSourceEnabled ? "已加入" : "未加入", ok: state.inputSourceEnabled)),
            SettingsKit.row(title: "切换到 WoType", icon: SettingsIcon(symbol: "keyboard", color: .systemIndigo),
                            accessory: Status(state.inputSourceSelected ? "正在使用" : "未切换", ok: state.inputSourceSelected)),
        ])]
        if state.inputSourceEnabled, state.inputSourceSelected {
            views.append(text("好了。以后点菜单栏的输入法菜单\(InputSwitchKeys.orPress)切换。", size: 12, color: .secondaryLabelColor))
            return views
        }
        // 不替用户启用、切换：第三方程序请求启用要在系统设置里点「允许」，停用更是补不回来（docs/19）。照左边的动画手动添加
        let settings = SettingButton(title: "打开键盘设置") {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?InputSources")!)
        }
        let logOut = SettingButton(title: "注销…") { Self.logOut() }
        let buttons = NSStackView(views: [settings, logOut])
        buttons.spacing = 10
        if state.inputSourceEnabled {
            // 名单里有，菜单里却可能没有（App 删掉再装回来时遇到过，程序查不出来）：给移除再添加、注销的出路
            let keys = InputSwitchKeys.tokens
            views.append(note(keys.isEmpty ? "已经加好了。点菜单栏右上角的输入法图标选「WoType 拼音」，切换过去。"
                              : "已经加好了。按 \(keys.joined(separator: " 或 "))，或点菜单栏右上角的输入法图标选「WoType 拼音」，切换过去。"))
            views.append(note("菜单里找不到 WoType？到「系统设置 › 键盘 › 输入法」里选中 WoType 点 －，再照左边的步骤添加一次；还是没有就注销重新登录，也可以重启电脑。"))
        } else {
            settings.bezelColor = .controlAccentColor
            // 同一次登录里删掉又重新装上的输入法，系统设置可能认不出来，要注销重新登录
            views.append(note("列表里找不到 WoType？新装的输入法，有时要注销重新登录系统才认得出，也可以重启电脑。重新登录后照样添加，切换到 WoType 后这个引导会自动接着打开。"))
        }
        views.append(buttons)
        return views
    }

    /// 让系统弹出「确定要注销吗？」（和苹果菜单里的「退出登录…」一样，用户可以取消）。
    private static func logOut() {
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"loginwindow\" to «event aevtlogo»")?.executeAndReturnError(&error)
        if let error { Log.app.error("注销请求失败：\(error, privacy: .public)") }
    }

    // MARK: - 4 选引擎

    private var choiceCards: [(id: String, card: ChoiceCard)] = []

    private func engineChoices() -> [NSView] {
        let engine = Settings.shared.config.pinyinEngine
        let choices: [(id: String, title: String, detail: String, symbol: String, color: NSColor)] = [
            ("msime", "水杉", "默认。随 App 带词库和小模型，按键最跟手；可以再下 24 MB 的整句模型。",
             "leaf.fill", .systemTeal),
            ("wanxiang", "万象", "万象拼音的 Rime 方案：整句准，选过的词马上往前排，日期、计算器、符号等玩法更多。",
             "character.book.closed.fill", .systemGreen),
        ]
        choiceCards = choices.map { choice in
            (choice.id, ChoiceCard(title: choice.title, detail: choice.detail,
                                   icon: SettingsIcon(symbol: choice.symbol, color: choice.color),
                                   selected: engine == choice.id) { [weak self] in
                Settings.shared.update { $0.pinyinEngine = choice.id }
                for (id, card) in self?.choiceCards ?? [] { card.setSelected(id == choice.id) }
            })
        }
        let column = NSStackView(views: choiceCards.map(\.card))
        column.orientation = .vertical
        column.spacing = 10
        for (_, card) in choiceCards { card.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        return [column]
    }

    /// 所选引擎的模型（选引擎那一页，跟着选中的引擎换）：水杉的整句大模型、万象的语法模型，可下可不下
    private func engineModelRows() -> [NSView] {
        let wanxiang = Settings.shared.config.pinyinEngine == "wanxiang"
        let title = wanxiang ? "万象语法模型（可选）" : "水杉整句大模型（可选）"
        let icon = SettingsIcon(symbol: "arrow.down.circle.fill", color: .systemBlue)
        let download = SettingButton(title: "下载") {
            if wanxiang {
                WanxiangGrammarModel.shared.download()
            } else {
                if ["none", "small"].contains(Settings.shared.config.msimeModel) {
                    Settings.shared.update { $0.msimeModel = "large" }
                }
                MsimeHost.shared.downloadSettledModel()
            }
        }
        let row: NSView
        var note = "不下也能打字，以后可以在设置 › 拼音引擎里下载。"
        if wanxiang {
            switch WanxiangGrammarModel.shared.state {
            case .installed(let bytes):
                row = SettingsKit.row(title: title, detail: "已下载（\(bytes / 1_048_576) MB）", icon: icon,
                                      accessory: Status("已下载", ok: true))
                note = "已经在用了。"
            case .downloading(let written, let total):
                row = SettingsKit.row(title: title, detail: total > 0 ? "正在下载 \(written * 100 / total)%" : "正在连接…",
                                      icon: icon, accessory: progress(total > 0 ? Double(written) / Double(total) : 0))
                note = "下载在后台继续，可以先往下走。"
            case .failed:
                row = SettingsKit.row(title: title, detail: "下载失败，请检查网络后重试。", icon: icon, accessory: download)
            case .missing:
                row = SettingsKit.row(title: title, detail: "约 400 MB，按前后文给候选排序。", icon: icon, accessory: download)
            }
        } else {
            let host = MsimeHost.shared
            switch host.settledModelState {
            case "installed":
                row = SettingsKit.row(title: title, detail: "已下载（24 MB）", icon: icon, accessory: Status("已下载", ok: true))
                note = "已经在用了。"
            case "installing":
                row = SettingsKit.row(title: title, detail: "正在下载 \(Int(host.settledModelProgress * 100))%", icon: icon,
                                      accessory: progress(host.settledModelProgress))
                note = "下载在后台继续，可以先往下走。"
            default:
                row = SettingsKit.row(title: title, detail: "约 24 MB，打字停顿时把整句再排一遍。", icon: icon, accessory: download)
            }
        }
        return [SettingsKit.card([row]), self.note(note)]
    }

    // MARK: - 5 打字和候选翻译

    private func typingRows() -> [NSView] {
        let practice = PracticeBox(placeholder: "在这里打 nihao", height: 72)
        self.practice = practice
        let checklist = Checklist(["候选窗开着时单按 {control}，翻译高亮的候选", "按 {return} 上屏译文"])
        self.checklist = checklist
        let hint = makeHint()
        practice.controller.onEvent = { [weak self] event in
            guard let self else { return }
            self.context.practiceEvent(event)
            switch event {
            case .controlTapped(let translated):
                if translated {
                    checklist.check(0)
                    self.showHint("")
                } else if !Settings.shared.config.candidateTranslation {
                    self.showHint("候选翻译还没打开，打开下面的开关再试。")
                } else {
                    self.showHint("先打拼音，候选窗开着时再单按 {control}。")
                }
            case .translationCommitted:
                checklist.check(1)
            default:
                break
            }
        }
        let toggle = SettingsKit.card([SettingsKit.row(
            title: "候选翻译", detail: "翻成英文，设置 › 拼音设置里可以换语言。",
            icon: SettingsIcon(symbol: "character.bubble.fill", color: .systemBlue),
            accessory: SettingSwitch(isOn: Settings.shared.config.candidateTranslation) { [weak self] on in
                Settings.shared.update { $0.candidateTranslation = on }
                self?.showHint(on ? "打开了。打拼音后单按 {control} 试试。" : "")
                if let practice = self?.practice { self?.window?.makeFirstResponder(practice.textView) }
            })])
        return [practice, checklist, hint, toggle]
    }

    // MARK: - 6 翻译并显示

    private let sampleText = "WoType makes typing Chinese on the Mac feel effortless."
    private weak var sampleView: NSTextView?

    private func showRows() -> [NSView] {
        // 示范文字：可以选、不能改
        let sample = NSTextView()
        sample.string = sampleText
        sample.isEditable = false
        sample.isSelectable = true
        sample.drawsBackground = false
        sample.font = .systemFont(ofSize: 14)
        sample.textContainerInset = NSSize(width: 12, height: 12)
        sample.translatesAutoresizingMaskIntoConstraints = false
        sample.heightAnchor.constraint(equalToConstant: 64).isActive = true
        sampleView = sample
        let sampleCard = CardView()
        sampleCard.addSubview(sample)
        NSLayoutConstraint.activate([
            sample.topAnchor.constraint(equalTo: sampleCard.topAnchor),
            sample.bottomAnchor.constraint(equalTo: sampleCard.bottomAnchor),
            sample.leadingAnchor.constraint(equalTo: sampleCard.leadingAnchor),
            sample.trailingAnchor.constraint(equalTo: sampleCard.trailingAnchor),
        ])
        let checklist = Checklist(["选中上面的英文，按 \(Self.showToken) 看译文"])
        self.checklist = checklist
        let hint = makeHint()
        let toggle = SettingsKit.card([SettingsKit.row(
            title: "翻译并显示", detail: "任何地方选中的文字，译文显示在翻译窗口里。",
            icon: SettingsIcon(symbol: "text.bubble.fill", color: .systemBlue),
            accessory: SettingSwitch(isOn: Settings.shared.config.selectionShow) { [weak self] on in
                Settings.shared.update { $0.selectionShow = on }
                self?.showHint(on ? "打开了。选中上面的英文，按 \(Self.showToken) 试试。" : "")
                // 输入法进程里改了开关会重新注册全局热键：这一步还是自己接
                DispatchQueue.main.async { KeyboardShortcuts.disable(.translateShow) }
                if let sample = self?.sampleView { self?.window?.makeFirstResponder(sample) }
            })])
        return [sampleCard, checklist, hint, toggle, LiveSection { [weak self] in self?.accessibilityRows() ?? [] }]
    }

    /// 这一步自己接 ⌃⌥T（输入法进程里的全局热键先停掉，走了再还回去）。
    private func startShowKeys() {
        KeyboardShortcuts.disable(.translateShow)
        if let sampleView {
            window?.makeFirstResponder(sampleView)
            sampleView.setSelectedRange((sampleText as NSString).range(of: "makes typing Chinese"))
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // 本地监视器就在主线程上调
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, event.window === self.window,
                      let shortcut = KeyboardShortcuts.Shortcut(event: event),
                      shortcut == KeyboardShortcuts.getShortcut(for: .translateShow) else { return false }
                self.translateAndShow()
                return true
            }
            return handled ? nil : event
        }
        settingsObserver = NotificationCenter.default.addObserver(forName: Settings.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                DispatchQueue.main.async { KeyboardShortcuts.disable(.translateShow) }
            }
        }
    }

    private func stopShowKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        settingsObserver = nil
        // 单独运行的进程没挂热键的处理，不能注册（注册了会把 ⌃⌥T 吃掉）
        if !OnboardingWindowController.isStandalone { SelectionTranslation.shared.shortcutsChanged() }
    }

    private func translateAndShow() {
        guard Settings.shared.config.selectionShow else {
            showHint("「翻译并显示」还没打开，打开下面的开关再试。")
            return
        }
        guard let textView = window?.firstResponder as? NSTextView else { return }
        let range = textView.selectedRange()
        let text = (textView.string as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            // 和快捷键一样：设置里开了「没选中文字时也打开」才打开空窗口
            if Settings.shared.config.selectionOpenEmpty { TranslationWindow.shared.showEmpty() }
            return
        }
        TranslationWindow.shared.translate(text)
        checklist?.check(0)
        showHint("")
    }

    // MARK: - 7 翻译并替换

    private func replaceRows() -> [NSView] {
        let practice = PracticeBox(placeholder: "", height: 56)
        practice.textView.string = "今天下午三点在会议室开会"
        practice.controller.keyFilter = { [weak self] event in self?.replaceKey(event) ?? false }
        self.practice = practice
        let checklist = Checklist(["在上面的输入框里按 \(Self.replaceToken)，换成译文"])
        self.checklist = checklist
        let hint = makeHint()
        let toggle = SettingsKit.card([SettingsKit.row(
            title: "翻译并替换", detail: "输入框里选中的文字（没选是整个输入框）换成译文。",
            icon: SettingsIcon(symbol: "arrow.left.arrow.right", color: .systemIndigo),
            accessory: SettingSwitch(isOn: Settings.shared.config.selectionReplace) { [weak self] on in
                Settings.shared.update { $0.selectionReplace = on }
                self?.showHint(on ? "打开了。在上面的输入框里按 \(Self.replaceToken) 试试。" : "")
                if let practice = self?.practice { self?.window?.makeFirstResponder(practice.textView) }
            })])
        return [practice, checklist, hint, toggle, LiveSection { [weak self] in self?.accessibilityRows() ?? [] }]
    }

    /// 试用区里的 ⌃⌥I：选中的（没选是全部）换成译文。返回 true 是吃掉了。
    private func replaceKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53, TranslationPanel.shared.isVisible || ModeToast.shared.isLoading {
            TranslationPanel.shared.hide()
            ModeToast.shared.hideLoading(animated: false)
            return true
        }
        guard let shortcut = KeyboardShortcuts.Shortcut(event: event),
              shortcut == KeyboardShortcuts.getShortcut(for: .translateReplace) else {
            TranslationPanel.shared.hide()
            return false
        }
        guard Settings.shared.config.selectionReplace else {
            showHint("「翻译并替换」还没打开，打开下面的开关再试。")
            return true
        }
        guard let textView = practice?.textView else { return true }
        var range = textView.selectedRange()
        if range.length == 0 { range = NSRange(location: 0, length: (textView.string as NSString).length) }
        let text = (textView.string as NSString).substring(with: range)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        let before = textView.string
        let anchor = textView.firstRect(forCharacterRange: range, actualRange: nil)
        translate(text, near: anchor) { [weak self] result in
            ModeToast.shared.hideLoading()
            // 等的时候改了字就不换，译文放气泡里
            guard textView.string == before else {
                TranslationPanel.shared.show(result, note: "输入框的内容变了，没有替换", near: anchor)
                return
            }
            textView.insertText(result, replacementRange: range)
            self?.checklist?.check(0)
            self?.showHint("")
        }
        return true
    }

    /// 划词翻译在别的应用里要「辅助功能」读选中的文字；没给时提醒（引导里试用不用）。
    private func accessibilityRows() -> [NSView] {
        guard !context.model.state.accessibilityGranted else { return [] }
        return [SettingsKit.card([SettingsKit.row(
            title: "辅助功能", detail: "在别的应用里用，要先允许 WoType 读取选中的文字。",
            icon: SettingsIcon(symbol: "accessibility", color: .systemBlue),
            accessory: SettingButton(title: "去授权") { Self.requestAccessibility() })])]
    }

    private var translateTask: Task<Void, Never>?

    private func translate(_ text: String, near anchor: NSRect, done: @escaping (String) -> Void) {
        translateTask?.cancel()
        TranslationPanel.shared.hide()
        let target = SelectionTranslation.target(for: text)
        ModeToast.shared.showLoading(near: anchor)
        translateTask = Task {
            do {
                let result = try await SelectionTranslator.shared.translate(text, to: target)
                guard !Task.isCancelled else { return }
                done(result.text)
            } catch {
                guard !Task.isCancelled else { return }
                ModeToast.shared.hideLoading(animated: false)
                TranslationPanel.shared.showMessage((error as? SelectionTranslator.Failure)?.message ?? "翻译失败", near: anchor)
            }
        }
    }

    // MARK: - 8 语音

    private func voiceRows() -> [NSView] {
        [LiveSection { [weak self] in self?.voiceSetupRows() ?? [] }]
    }

    private func voiceSetupRows() -> [NSView] {
        let config = Settings.shared.config
        let toggle = SettingsKit.row(
            title: "开启语音输入", detail: "不开的话，后面跳过语音相关的几步，什么都不用下载。",
            icon: SettingsIcon(symbol: "mic.fill", color: .systemRed),
            accessory: SettingSwitch(isOn: config.voice) { on in
                Settings.shared.update { $0.voice = on }
            })
        guard config.voice else { return [SettingsKit.card([toggle])] }

        // 识别方式：本机模型、云端识别（下一步添加）、免费体验（微信、豆包、千问输入法的识别，选了就算看过说明）
        let recognizer = config.voiceRecognizer
        let kind = switch recognizer {
        case .local: 0
        case .cloud: 1
        case .trial: 2
        }
        let recognition = SettingSegments(labels: ["本机模型", "云端识别", "免费体验"], selected: kind) { index in
            Settings.shared.update { config in
                switch index {
                case 0: config.voiceRecognizer = .local
                case 1: config.voiceRecognizer = .cloud(config.cloudSpeechModels.first?.id ?? "")
                default: Self.pickTrial(.wetype, in: &config)
                }
            }
        }
        var recognitionRows: [NSView] = [SettingsKit.row(title: "识别方式", icon: SettingsIcon(symbol: "waveform", color: .systemPurple),
                                                         accessory: recognition)]
        let recognitionNote: String
        switch recognizer {
        case .local:
            recognitionNote = "在 Mac 上识别，离线、录音不上传。要下载约 \(Self.gigabytes(VoiceModelSpec.asr.approxBytes)) 的模型。"
        case .cloud:
            recognitionNote = "用 xAI 等服务商识别，要你自己的 API 密钥，录音会发到服务商。下一步添加。"
        case .trial(let channel):
            let channels = TrialChannel.allCases
            let picker = SettingPopUp(items: channels.map(\.title), selected: channels.firstIndex(of: channel) ?? 0) { index in
                Settings.shared.update { Self.pickTrial(channels[index], in: &$0) }
            }
            recognitionRows.append(SettingsKit.row(title: "用谁的识别", icon: SettingsIcon(symbol: "gift.fill", color: .systemOrange),
                                                   accessory: picker))
            recognitionNote = "不用密钥。录音会发到\(channel.vendor)的服务器，仅供体验，随时可能失效。"
        }

        // 润色和语音翻译：同一个本机模型（Qwen3.5-2B）或同一组 AI 服务商，一起选
        let cloud = config.voicePolishEngine == .cloud
        let polish = SettingsKit.row(
            title: "润色", detail: "去掉语气词和改口，改同音错字。", icon: SettingsIcon(symbol: "sparkles", color: .systemPink),
            accessory: SettingSwitch(isOn: config.voicePolish) { on in Settings.shared.update { $0.voicePolish = on } })
        let engine = SettingSegments(labels: ["本机模型", "AI 服务商"], selected: cloud ? 1 : 0) { index in
            Settings.shared.update { config in
                let engine: PolishEngine = index == 1 ? .cloud : .local
                config.voicePolishEngine = engine
                config.voiceTranslateEngine = engine
                // AI：已经加过服务商的话先选上第一个（服务商那一步还能换）
                if engine == .cloud, let first = config.cloudModels.first?.id {
                    if !config.cloudModels.contains(where: { $0.id == config.voicePolishCloudModel }) { config.voicePolishCloudModel = first }
                    if !config.cloudModels.contains(where: { $0.id == config.voiceTranslateCloudModel }) { config.voiceTranslateCloudModel = first }
                }
            }
        }
        let engineRow = SettingsKit.row(title: "润色和翻译用", icon: SettingsIcon(symbol: "wand.and.stars", color: .systemIndigo),
                                        accessory: engine)
        let engineNote = cloud ? "用你的 AI 服务商（OpenAI、DeepSeek、Gemini…），长句更准。下一步添加。"
            : "在 Mac 上运行，要下载约 \(Self.gigabytes(VoiceModelSpec.polish.approxBytes)) 的模型。"
        return [
            SettingsKit.card([toggle]),
            SettingsKit.card(recognitionRows),
            note(recognitionNote),
            SettingsKit.card([polish, engineRow]),
            note(engineNote),
        ] + permissionReminder(context.model.state)
    }

    /// 选一个免费体验渠道：引导里说明写在页面上，选了就算看过（设置里第一次选时弹的那个说明不再弹）
    static func pickTrial(_ channel: TrialChannel, in config: inout Config) {
        config.voiceRecognizer = .trial(channel)
        if !config.voiceTrialAccepted.contains(channel.rawValue) { config.voiceTrialAccepted.append(channel.rawValue) }
    }

    // MARK: - 9 下载模型

    /// 语音要用的本机模型：只列语音那一步选了本机的（识别、润色和翻译）
    private func voiceModelsRows() -> [NSView] {
        let state = context.model.state
        var rows: [NSView] = []
        var specs: [VoiceModelSpec] = []
        if state.needsSpeechModel {
            rows.append(voiceModelRow(.asr, title: "语音识别 · Qwen3-ASR 1.7B", icon: SettingsIcon(symbol: "waveform", color: .systemPurple)))
            specs.append(.asr)
        }
        if state.needsPolishModel {
            rows.append(voiceModelRow(.polish, title: "润色和翻译 · Qwen3.5-2B", icon: SettingsIcon(symbol: "wand.and.stars", color: .systemPink)))
            specs.append(.polish)
        }
        let models = VoiceModels.shared
        let pending = specs.filter { spec in
            switch models.state(spec) {
            case .missing, .partial, .failed: true
            case .connecting, .downloading, .verifying, .installed: false
            }
        }
        var views: [NSView] = [SettingsKit.card(rows)]
        var buttons: [NSView] = []
        if pending.count > 1 {
            let all = SettingButton(title: "全部下载") { pending.forEach(models.download) }
            all.bezelColor = .controlAccentColor
            buttons.append(all)
        }
        if !pending.isEmpty {
            buttons.append(SettingButton(title: "以后再下") { [weak self] in
                self?.context.model.modelsDeferred = true
                self?.context.advance()
            })
        }
        if !buttons.isEmpty {
            let stack = NSStackView(views: buttons)
            stack.spacing = 10
            views.append(stack)
        }
        let installed = specs.allSatisfy { if case .installed = models.state($0) { true } else { false } }
        views.append(note(installed ? "都下载好了。" : pending.isEmpty ? "下载在后台继续，可以先往下走。"
                          : "不下载的话，语音要等以后在设置 › 模型管理里下载了才能用。"))
        return views
    }

    // MARK: - 10 添加服务商

    /// 语音那一步选了云端的：云端识别（要密钥）、AI 服务商（润色和语音翻译）
    private func providerRows() -> [NSView] {
        let state = context.model.state
        var views: [NSView] = []
        if state.needsCloudSpeech {
            views += [SettingsKit.sectionTitle("云端识别"), SettingsKit.card(cloudSpeechRows())]
        }
        if state.needsAIProvider {
            views += [SettingsKit.sectionTitle("AI 服务商（润色和语音翻译）"), SettingsKit.card(aiModelRows())]
        }
        let done = (!state.needsCloudSpeech || state.hasCloudSpeech) && (!state.needsAIProvider || state.hasAIProvider)
        if !done {
            views.append(SettingButton(title: "以后再加") { [weak self] in
                self?.context.model.providersDeferred = true
                self?.context.advance()
            })
        }
        views.append(note(done ? "好了。以后可以在设置 › 模型管理里换。" : "不加的话，以后在设置 › 模型管理里添加了才能用。"))
        return views
    }

    /// 云端识别用哪个：加过的选一个，或者添加（设置里同一个添加窗口，弹在引导窗口上，保存后选上它）
    private func cloudSpeechRows() -> [NSView] {
        let config = Settings.shared.config
        let add = SettingButton(title: "添加云端识别…") { [weak self] in
            guard let window = self?.window else { return }
            CloudSpeechSheet.present(editing: nil, on: window) { model in
                Settings.shared.update { $0.voiceRecognizer = .cloud(model.id) }
            }
        }
        let models = CloudSpeech.shared.models
        guard !models.isEmpty else {
            add.bezelColor = .controlAccentColor
            return [SettingsKit.row(title: "云端识别", detail: "还没有添加。支持 xAI，用你自己的 API 密钥。",
                                    icon: SettingsIcon(symbol: "waveform.badge.plus", color: .systemPurple), accessory: add)]
        }
        let picker = ActionPopUp()
        for model in models {
            picker.add(model.title, selected: config.voiceRecognizer == .cloud(model.id)) {
                Settings.shared.update { $0.voiceRecognizer = .cloud(model.id) }
            }
        }
        return [
            SettingsKit.row(title: "识别用", icon: SettingsIcon(symbol: "waveform", color: .systemPurple), accessory: picker),
            SettingsKit.row(title: "再加一个", icon: SettingsIcon(symbol: "plus", color: .systemBlue), accessory: add),
        ]
    }

    /// 语音那一步：权限在「允许权限」那一步给，没给的话这里提醒一句，带个按钮直接去要（免得用户回头找）
    private func permissionReminder(_ state: OnboardingState) -> [NSView] {
        guard !(state.microphoneGranted && state.accessibilityGranted) else { return [] }
        let missing = [state.microphoneGranted ? nil : "麦克风", state.accessibilityGranted ? nil : "辅助功能"].compactMap { $0 }
        let allow = SettingButton(title: "去允许") { [weak self] in
            if !state.microphoneGranted {
                self?.requestMicrophone()
            } else {
                Self.requestAccessibility()
            }
        }
        let row = NSStackView(views: [note("还没允许\(missing.joined(separator: "和"))，语音输入用不了。"), allow])
        row.spacing = 10
        return [row]
    }

    // MARK: - 3 允许权限

    private func permissionRows() -> [NSView] {
        let state = context.model.state
        let ax: NSView = state.accessibilityGranted ? Status("已允许", ok: true)
            : SettingButton(title: "去授权") { Self.requestAccessibility() }
        return [
            SettingsKit.card([
                SettingsKit.row(title: "麦克风", detail: "按住语音键说话时才听。", icon: SettingsIcon(symbol: "mic.circle.fill", color: .systemOrange),
                                accessory: microphoneAccessory()),
                SettingsKit.row(title: "辅助功能", detail: "把文字插进别的应用，读你选中的文字（划词翻译也要）。",
                                icon: SettingsIcon(symbol: "accessibility", color: .systemBlue), accessory: ax),
            ]),
            note("不用语音和划词翻译的话，可以先跳过，以后在设置里再开。"),
        ]
    }

    /// 一个语音模型的下载行：没下 → 下载按钮，下载中 → 进度条，装好 → 绿勾。
    private func voiceModelRow(_ spec: VoiceModelSpec, title: String, icon: NSView) -> NSView {
        let models = VoiceModels.shared
        switch models.state(spec) {
        case .installed:
            return SettingsKit.row(title: title, detail: "已下载。", icon: icon, accessory: Status("已下载", ok: true))
        case .connecting:
            return SettingsKit.row(title: title, detail: "正在连接…", icon: icon, accessory: progress(0))
        case .downloading(let written, let total):
            return SettingsKit.row(title: title,
                                   detail: total > 0 ? "正在下载 \(written * 100 / total)%（\(Self.gigabytes(written)) / \(Self.gigabytes(total))）" : "正在下载…",
                                   icon: icon, accessory: progress(total > 0 ? Double(written) / Double(total) : 0))
        case .verifying:
            return SettingsKit.row(title: title, detail: "正在校验…", icon: icon, accessory: progress(1))
        case .failed(let message):
            return SettingsKit.row(title: title, detail: "下载失败：\(message)", icon: icon,
                                   accessory: SettingButton(title: "重试") { models.download(spec) })
        case .missing, .partial:
            let button = SettingButton(title: "下载") { models.download(spec) }
            button.bezelColor = .controlAccentColor
            return SettingsKit.row(title: title, detail: "约 \(Self.gigabytes(spec.approxBytes))，下载一次以后离线可用。",
                                   icon: icon, accessory: button)
        }
    }

    /// 麦克风：没问过的点「允许」才问一次；拒绝过的系统不会再问，只能去系统设置里开。
    private func microphoneAccessory() -> NSView {
        switch Permissions.microphone {
        case .granted:
            return Status("已允许", ok: true)
        case .notAsked:
            return SettingButton(title: "允许") { [weak self] in self?.requestMicrophone() }
        case .denied:
            return SettingButton(title: "打开系统设置") { [weak self] in self?.requestMicrophone() }
        }
    }

    /// 没问过的弹系统的授权框；拒绝过的系统不会再问，打开系统设置的那一页（和设置的「系统权限」页同一套）
    private func requestMicrophone() {
        Permissions.requestMicrophone()
        context.model.refresh()
    }

    static func requestAccessibility() { Permissions.requestAccessibility() }

    static func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }

    // MARK: - 12 语音翻译

    private func voiceTranslateRows() -> [NSView] {
        let config = Settings.shared.config
        let key = config.voiceTranslateKey
        let enabled = SettingSwitch(isOn: key != nil) { on in
            Settings.shared.update { config in
                if on {
                    // 恢复关掉前的键（默认右 ⌥）；撞了语音键就换一个没被占的（同设置页）
                    let previous = config.voicePreviousTranslateKey ?? .rightOption
                    config.voiceTranslateKey = previous != config.voiceKey
                        ? previous : VoiceKey.allCases.first { $0 != config.voiceKey }
                } else {
                    config.voicePreviousTranslateKey = config.voiceTranslateKey
                    config.voiceTranslateKey = nil
                }
            }
        }
        var rows: [NSView] = [SettingsKit.row(title: "启用语音翻译", icon: SettingsIcon(symbol: "globe", color: .systemIndigo),
                                              accessory: enabled)]
        guard let key else { return [SettingsKit.card(rows)] }
        // 翻译键：三个键帽，语音键占着的那个灰掉
        let choices = NSStackView(views: VoiceKey.allCases.map { option in
            let choice = KeyChoice(key: option, selected: option == key) {
                Settings.shared.update { $0.voiceTranslateKey = option }
            }
            if option == config.voiceKey { choice.disable(note: "已用于听写") }
            return choice
        })
        choices.spacing = 10
        choices.alignment = .top
        // 放在一行右边：高度按键帽定，不许被拉高
        choices.setHuggingPriority(.required, for: .vertical)
        choices.setContentCompressionResistancePriority(.required, for: .vertical)
        let languages = TranslationLanguage.allCases
        let language = SettingPopUp(items: languages.map(\.title),
                                    selected: languages.firstIndex(of: config.voiceTranslateLanguage) ?? 0) { index in
            Settings.shared.update { $0.voiceTranslateLanguage = languages[index] }
        }
        let ai = config.voiceTranslateEngine == .cloud
        rows += [
            SettingsKit.row(title: "翻译键", icon: SettingsIcon(symbol: "command", color: .systemGray), accessory: choices),
            SettingsKit.row(title: "翻译成", icon: SettingsIcon(symbol: "character.bubble.fill", color: .systemTeal),
                            accessory: language),
        ]
        return [SettingsKit.card(rows),
                note("翻译用\(ai ? "你的 AI 服务商" : "本机模型")，和润色一样，在「语音输入」那一步选。")]
    }

    /// 润色和语音翻译用哪个 AI 模型：加过的模型选一个，或者添加服务商（设置里同一个添加窗口，弹在引导窗口上）。
    private func aiModelRows() -> [NSView] {
        let config = Settings.shared.config
        let add = SettingButton(title: "添加 AI 服务商…") { [weak self] in
            guard let window = self?.window else { return }
            CloudModelSheet.present(editing: nil, on: window) { model in
                Settings.shared.update { config in
                    config.voicePolishCloudModel = model.id
                    config.voiceTranslateCloudModel = model.id
                }
            }
        }
        let models = config.cloudModels
        guard !models.isEmpty else {
            add.bezelColor = .controlAccentColor
            return [SettingsKit.row(title: "AI 服务商", detail: "还没有添加。支持 OpenAI、Anthropic、Gemini、DeepSeek、OpenRouter 等，用你自己的 API 密钥。",
                                    icon: SettingsIcon(symbol: "cloud.fill", color: .systemTeal), accessory: add)]
        }
        let picker = ActionPopUp()
        for model in models {
            picker.add(model.title, selected: model.id == config.voicePolishCloudModel) {
                Settings.shared.update { config in
                    config.voicePolishCloudModel = model.id
                    config.voiceTranslateCloudModel = model.id
                }
            }
        }
        return [
            SettingsKit.row(title: "AI 模型", icon: SettingsIcon(symbol: "cloud.fill", color: .systemTeal), accessory: picker),
            SettingsKit.row(title: "换一个服务商", detail: "密钥只存在本机。", icon: SettingsIcon(symbol: "plus", color: .systemBlue),
                            accessory: add),
        ]
    }

    // MARK: - 11 试试语音

    private var keyChoices: [(key: VoiceKey, view: KeyChoice)] = []

    /// 换语音键；和翻译键撞了，翻译键换成原来的语音键（同设置页）
    static func setVoiceKey(_ key: VoiceKey) {
        Settings.shared.update { config in
            guard config.voiceKey != key else { return }
            if config.voiceTranslateKey == key { config.voiceTranslateKey = config.voiceKey }
            config.voiceKey = key
        }
    }

    private func voiceKeyRows() -> [NSView] {
        let current = Settings.shared.config.voiceKey
        keyChoices = VoiceKey.allCases.map { key in
            (key, KeyChoice(key: key, selected: key == current) { [weak self] in
                Self.setVoiceKey(key)
                for (k, view) in self?.keyChoices ?? [] { view.selected = k == key }
            })
        }
        let choices = NSStackView(views: keyChoices.map(\.view))
        choices.spacing = 12
        choices.alignment = .top
        let open = SettingButton(title: "打开「文本编辑」试试", symbol: "doc.text") { Self.openTextEdit() }
        open.bezelColor = .controlAccentColor
        open.controlSize = .large
        let guide = LiveSection { [weak self] in
            guard let self else { return [] }
            let config = Settings.shared.config
            var text = "在文本编辑里按住 \(Self.voiceKeyText(config.voiceKey)) 说话，松开后文字就打进去了。"
            if let translate = config.voiceTranslateKey {
                text += "按住 \(Self.voiceKeyText(translate)) 说中文，打出来的是\(config.voiceTranslateLanguage.title)。"
            }
            var views: [NSView] = [self.text(text, size: 13)]
            if !self.context.model.state.recognitionReady {
                // 识别还用不了：本机模型没下好，或者云端识别还没加
                var detail = "云端识别还没加好，在设置 › 模型管理里添加了才能用。"
                if config.voiceRecognizer == .local {
                    detail = "语音识别模型还没下载，在设置 › 模型管理里下载好了才能用。"
                    switch VoiceModels.shared.state(.asr) {
                    case .downloading(let written, let total) where total > 0:
                        detail = "语音识别模型下载中 \(written * 100 / total)%，下载好了才能用。"
                    case .connecting, .downloading, .verifying:
                        detail = "语音识别模型还在下载，下载好了才能用。"
                    default: break
                    }
                }
                views.append(self.note(detail))
            }
            // 不拦「继续」了：权限没给也写一句（带「去允许」）
            return views + self.permissionReminder(self.context.model.state)
        }
        return [choices, open, guide]
    }

    // MARK: - 13 更多设置

    private func moreSettingsRows() -> [NSView] {
        // 完成用底部的「完成」
        let open = SettingButton(title: "打开设置") { [weak self] in self?.context.openSettings() }
        open.bezelColor = .controlAccentColor
        open.controlSize = .large
        return [open, note("以后想再看这个教程，在设置 › 新手引导里打开。")]
    }

    /// 打开「文本编辑」，新建（第一次）一个「试试语音输入」文档；当前输入法不是 WoType 就先切回来。
    static func openTextEdit() {
        if !InputSource.status().selected { InputSource.selectWoType() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("试试语音输入.txt")
        if !FileManager.default.fileExists(atPath: file.path) {
            let key = Settings.shared.config.voiceKey
            let side = key == .fn ? "fn" : "右侧 \(key == .rightCommand ? "command" : "option")"
            try? "在下面按住\(side)说话，松开后文字会打在光标处：\n\n".write(to: file, atomically: true, encoding: .utf8)
        }
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        NSWorkspace.shared.open([file], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - 小部件

    private func progress(_ fraction: Double) -> NSView {
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = fraction <= 0
        bar.doubleValue = fraction * 100
        bar.widthAnchor.constraint(equalToConstant: 110).isActive = true
        if fraction <= 0 { bar.startAnimation(nil) }
        return bar
    }

    /// 一段字，{…} 画成键帽，会换行。
    private func text(_ template: String, size: CGFloat, color: NSColor = .secondaryLabelColor) -> NSTextField {
        let label = SettingsKit.wrappingLabel("", size: size, color: color)
        label.attributedStringValue = KeyCaps.text(template, font: .systemFont(ofSize: size), color: color)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func note(_ template: String) -> NSTextField {
        text(template, size: 12)
    }

    /// 试用区下面的一句提示；没有提示时不占地方
    private func makeHint() -> NSTextField {
        let hint = note("")
        hint.isHidden = true
        self.hint = hint
        return hint
    }

    private func showHint(_ template: String) {
        hint?.attributedStringValue = KeyCaps.text(template, font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
        hint?.isHidden = template.isEmpty
    }
}

// MARK: - 跟着状态刷新的一段

/// 收到这些通知就整段重建（启用、下载进度、授权、设置）。
final class LiveSection: NSStackView {

    private let build: () -> [NSView]
    private var observers: [NSObjectProtocol] = []

    init(build: @escaping () -> [NSView]) {
        self.build = build
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 12
        let names = [OnboardingModel.didChange, Settings.didChange, MsimeHost.settledModelDidChange,
                     WanxiangGrammarModel.didChange, VoiceModels.didChange, CloudSpeech.didChange]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.rebuild() }
            })
        }
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func rebuild() {
        arrangedSubviews.forEach { $0.removeFromSuperview() }
        for view in build() {
            addArrangedSubview(view)
            if view is CardView || view is NSTextField {
                view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
            }
        }
    }
}

// MARK: - 状态、选择卡片、选键、打勾清单、试用区

/// 行右边的状态：绿勾「已允许」，或灰色的「未切换」。
final class Status: NSStackView {
    init(_ text: String, ok: Bool) {
        super.init(frame: .zero)
        let icon = NSImageView(image: NSImage(systemSymbolName: ok ? "checkmark.circle.fill" : "circle.dashed",
                                              accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = ok ? .systemGreen : .tertiaryLabelColor
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = ok ? .labelColor : .secondaryLabelColor
        addArrangedSubview(icon)
        addArrangedSubview(label)
        spacing = 4
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// 可以点的选项卡片（选引擎）：选中时描一圈强调色。
final class ChoiceCard: CardView {

    private let onClick: () -> Void
    private var selected: Bool
    private let check = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "已选")
                                        ?? NSImage())

    init(title: String, detail: String, icon: NSView, selected: Bool, onClick: @escaping () -> Void) {
        self.onClick = onClick
        self.selected = selected
        super.init(frame: .zero)
        let row = SettingsKit.row(title: title, detail: detail, icon: icon, accessory: check)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        apply()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setSelected(_ on: Bool) {
        guard on != selected else { return }
        selected = on
        apply()
        if on, !OnboardingMotion.reduced {
            layer?.add(OnboardingMotion.spring("transform.scale", from: 0.98, to: 1, OnboardingMotion.pop), forKey: "pop")
        }
    }

    private func apply() {
        check.contentTintColor = selected ? .controlAccentColor : .clear
        needsDisplay = true
        updateLayer()
    }

    override func updateLayer() {
        super.updateLayer()
        layer?.borderWidth = selected ? 2 : 0.5
        layer?.borderColor = (selected ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }
}

/// 选语音键的一个选项：键帽（右 ⌥、右 ⌘ 下面写「右侧」），选中的键面带强调色、右上角打勾。
final class KeyChoice: NSView {

    var selected: Bool {
        didSet {
            cap.highlighted = selected
            check.isHidden = !selected
        }
    }
    private let onClick: () -> Void
    private let cap: KeyCapView
    private let check = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "已选")
                                        ?? NSImage())

    private var enabled = true
    private let side: NSTextField

    init(key: VoiceKey, selected: Bool, onClick: @escaping () -> Void) {
        self.selected = selected
        self.onClick = onClick
        cap = KeyCapView(KeyCap.voiceKey(key), size: .regular)
        side = NSTextField(labelWithString: key == .fn ? " " : "右侧")
        super.init(frame: .zero)
        side.font = .systemFont(ofSize: 11)
        side.textColor = .secondaryLabelColor
        check.contentTintColor = .controlAccentColor
        let column = NSStackView(views: [cap, side])
        column.orientation = .vertical
        column.spacing = 4
        for view in [column, check] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            check.centerXAnchor.constraint(equalTo: cap.trailingAnchor),
            check.centerYAnchor.constraint(equalTo: cap.topAnchor),
        ])
        cap.highlighted = selected
        check.isHidden = !selected
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(key.title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 不能选（已经被另一个功能占着）：灰掉，下面写原因
    func disable(note: String) {
        enabled = false
        alphaValue = 0.4
        side.stringValue = note
    }

    override func mouseDown(with event: NSEvent) {
        guard enabled else { return }
        cap.setPressed(true)
    }

    override func mouseUp(with event: NSEvent) {
        guard enabled else { return }
        cap.setPressed(false)
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }
}

/// 要试的几件事（{…} 画成键帽），做到了打勾（勾弹一下）。
final class Checklist: NSStackView {

    private var icons: [NSImageView] = []

    init(_ items: [String]) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        for item in items {
            let icon = NSImageView(image: NSImage(systemSymbolName: "circle", accessibilityDescription: nil) ?? NSImage())
            icon.contentTintColor = .tertiaryLabelColor
            icon.wantsLayer = true
            let label = NSTextField(labelWithAttributedString: KeyCaps.text(item, font: .systemFont(ofSize: 13)))
            let row = NSStackView(views: [icon, label])
            row.spacing = 6
            row.alignment = .centerY
            addArrangedSubview(row)
            icons.append(icon)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func check(_ index: Int) {
        guard icons.indices.contains(index) else { return }
        let icon = icons[index]
        guard icon.contentTintColor != .systemGreen else { return }
        icon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "完成")
        icon.contentTintColor = .systemGreen
        guard !OnboardingMotion.reduced, let layer = icon.layer else { return }
        // 以中心弹出来
        let b = layer.bounds
        var from = CATransform3DMakeTranslation(b.midX, b.midY, 0)
        from = CATransform3DScale(from, 0.4, 0.4, 1)
        from = CATransform3DTranslate(from, -b.midX, -b.midY, 0)
        layer.add(OnboardingMotion.spring("transform", from: from, to: CATransform3DIdentity, OnboardingMotion.pop),
                  forKey: "pop")
    }
}

/// 试用区：一张卡片里的文本框，没字时显示提示（{…} 画成键帽）。按键由 PracticeInputController 处理。
final class PracticeBox: CardView {

    let textView: PracticeTextView
    let controller: PracticeInputController
    private let placeholder = NSTextField(labelWithString: "")

    init(placeholder text: String, height: CGFloat) {
        textView = PracticeTextView(frame: NSRect(x: 0, y: 0, width: OnboardingStepView.contentWidth, height: height))
        controller = PracticeInputController(textView: textView)
        super.init(frame: .zero)
        let scroll = OverlayScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 15)
        textView.textContainerInset = NSSize(width: 8, height: 10)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        scroll.documentView = textView
        setPlaceholder(text)
        for view in [scroll, placeholder] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: height),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            placeholder.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            placeholder.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
        ])
        textView.onTextChange = { [weak self] in self?.updatePlaceholder() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setPlaceholder(_ text: String) {
        placeholder.attributedStringValue = KeyCaps.text(text, font: .systemFont(ofSize: 15), color: .placeholderTextColor)
        updatePlaceholder()
    }

    private func updatePlaceholder() {
        placeholder.isHidden = !textView.string.isEmpty || textView.hasMarkedText() || placeholder.attributedStringValue.length == 0
    }

    func stop() {
        controller.focus(false)
    }

    /// 点卡片的空白处也把焦点给文本框
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(textView)
    }
}
