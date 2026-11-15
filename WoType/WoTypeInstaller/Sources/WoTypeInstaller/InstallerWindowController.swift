//
//  InstallerWindowController.swift
//  WoType 安装器
//
//  一个窗口，页面依次换：首页（安装、卸载）→ 进度 → 教程（添加 / 移除 WoType 的动画）或结果。
//  卸载要在确认框里再点一次（docs/19）。
//

import AppKit

final class InstallerWindowController: NSWindowController, NSWindowDelegate {

    /// 装到一半、卸到一半：不让关窗口、不让退出
    private(set) var isBusy = false

    private let root = NSView()
    private var page: NSView?
    private var progressPage: ProgressPage?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "安装 WoType"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.contentView = root
        super.init(window: window)
        window.delegate = self
        showHome()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isBusy else { return false }
        removePendingApp()
        return true
    }

    // MARK: - 首页

    private func showHome() {
        let bundled = Installer.version(of: Installer.payload)
        // 装着、但读不出版本的（Info.plist 坏了）当成「已安装 WoType」
        let installed: AppVersion?? = Installer.isInstalled ? .some(Installer.version(of: Installer.destination)) : nil

        let status: String
        var installTitle = "安装"
        switch (bundled, installed) {
        case (nil, _):
            status = "安装包不完整，找不到要安装的 WoType"
        case (let new?, nil):
            status = "版本 \(new.display)"
        case (_, .some(nil)):
            status = "已安装 WoType"
            installTitle = "重新安装"
        case (let new?, .some(let old?)) where old == new:
            status = "已安装 \(old.display)"
            installTitle = "重新安装"
        case (let new?, .some(let old?)) where old < new:
            status = "已安装 \(old.display)，可以更新到 \(new.display)"
            installTitle = "更新"
        case (let new?, .some(let old?)):
            status = "已安装 \(old.display)，比这个安装包里的 \(new.display) 新"
            installTitle = "安装旧版本"
        }

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        let title = Self.label("WoType", size: 28, weight: .semibold)
        let tagline = Self.label("拼音 · 语音 · 翻译", size: 13, color: .secondaryLabelColor)
        let statusLabel = Self.label(status, size: 13, color: .secondaryLabelColor)

        let install = Self.button(installTitle, target: self, action: #selector(install))
        install.keyEquivalent = "\r"
        install.isEnabled = bundled != nil
        let uninstall = Self.button("卸载", target: self, action: #selector(confirmUninstall))
        uninstall.isEnabled = installed != nil
        let buttons = NSStackView(views: [uninstall, install])
        buttons.spacing = 12

        let note = Self.label(installed == nil
                              ? "只给当前用户安装，不需要输入密码"
                              : "安装、卸载时 WoType 会退出一下；正在打字的应用如果打不出字，重开一下就好",
                              size: 11, color: .tertiaryLabelColor)

        let stack = NSStackView(views: [icon, title, tagline, statusLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.setCustomSpacing(10, after: icon)
        stack.setCustomSpacing(14, after: tagline)
        stack.setCustomSpacing(26, after: statusLabel)

        let view = NSView()
        for subview in [stack, note] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 104),
            icon.heightAnchor.constraint(equalToConstant: 104),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -6),
            note.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            note.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -18),
        ])
        show(view)
    }

    // MARK: - 安装

    @objc private func install() {
        let freshInstall = !Installer.isInstalled
        Task {
            // 全新安装、或者装着但没加进输入法列表：装完显示添加教程。名单里有 WoType 不等于菜单里看得到
            // （App 在访达里删掉再装回来时遇到过），程序查不出来，所以全新安装一律显示教程。
            // 全新安装时名单里已经有 WoType：上次卸载时没在系统设置里移除，留下的条目用不了，要先移除再添加
            let listedBefore = await Installer.inputStatus().enabled
            let guide = freshInstall || !listedBefore
            let leftover = freshInstall && listedBefore
            let page = ProgressPage(title: freshInstall ? "正在安装 WoType…" : "正在更新 WoType…",
                                    steps: ["结束正在运行的 WoType", "复制文件", "检查签名", "注册输入法"],
                                    weights: [3, 75, 15, 7])
            begin(page)
            do {
                page.begin(0)
                await Installer.stopWoType()
                page.begin(1)
                try await Installer.copyPayload { done, total in
                    Task { @MainActor in self.copied(done, of: total) }
                }
                page.detail = nil
                page.begin(2)
                try await creeping(2, expected: 1.5) { try await Installer.verify() }
                page.begin(3)
                let status = await creeping(3, expected: 0.5) { await Installer.register() }
                Installer.log.info("装好了：认出 \(status.found)、启用 \(status.enabled)、当前 \(status.selected)")
                page.finish()
                end()
                if guide {
                    showGuide(.add, hint: leftover
                              ? "列表里已经有 WoType（上次卸载时留下的），先选中它点 －，再照着动画重新添加。"
                              : "如果看不到 WoType，注销或重启后再进行添加。",
                              primary: ("开始使用", #selector(startUsing)))
                } else {
                    showResult(.success, title: "更新成功",
                               message: status.selected ? "WoType 已经是当前输入法。" : "点菜单栏右上角的输入法图标，选「WoType 拼音」就能用了。",
                               buttons: [("完成", #selector(quit))])
                }
            } catch {
                Installer.log.error("安装失败：\(error.localizedDescription, privacy: .public)")
                page.fail()
                end()
                showResult(.failure, title: "安装没有完成", message: error.localizedDescription,
                           buttons: [("返回", #selector(backHome))])
            }
        }
    }

    /// 打开使用教程（WoType 的新手引导，在输入法进程里），用户边看边用 WoType 做完设置和试用；安装器退出
    @objc private func startUsing() {
        Task {
            await Installer.showOnboarding()
            NSApp.terminate(nil)
        }
    }

    /// 说不准要多久的一步：进度条在这一步的范围里一直往前走（越走越慢，到 90% 为止），别让人以为卡住了
    private func creeping<T>(_ index: Int, expected: Double, _ work: () async throws -> T) async rethrows -> T {
        let started = Date()
        let ticker = Task {
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(started)
                progressPage?.advance(within: index, by: 0.9 * (1 - exp(-elapsed / expected)))
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        defer { ticker.cancel() }
        return try await work()
    }

    private func copied(_ done: Int64, of total: Int64) {
        guard let progressPage, total > 0 else { return }
        progressPage.advance(within: 1, by: Double(done) / Double(total))
        let format = ByteCountFormatter()
        format.countStyle = .file
        progressPage.detail = "\(format.string(fromByteCount: done)) / \(format.string(fromByteCount: total))"
    }

    // MARK: - 卸载

    @objc private func confirmUninstall() {
        guard let window else { return }
        Task {
            let size = await Installer.userDataSize()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "确定要卸载 WoType 吗？"
            alert.informativeText = "会删除 WoType。正在用 WoType 的话，先切换到 ABC 键盘。"
            let confirm = alert.addButton(withTitle: "卸载")
            confirm.hasDestructiveAction = true
            let cancel = alert.addButton(withTitle: "取消")
            // 回车是「取消」，卸载一定要点按钮
            confirm.keyEquivalent = ""
            cancel.keyEquivalent = "\r"
            alert.showsSuppressionButton = true
            let checkbox = alert.suppressionButton
            checkbox?.title = "同时删除我的词库、设置和下载的模型"
                + (size > 0 ? "（\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))）" : "")
            checkbox?.state = .off
            let response = await alert.beginSheetModal(for: window)
            guard response == .alertFirstButtonReturn else { return }
            uninstall(removeData: checkbox?.state == .on)
        }
    }

    private func uninstall(removeData: Bool) {
        Task {
            // 在输入法列表里的，卸载完显示移除教程：名单只有系统设置能改，要用户自己点 －（docs/19）。
            // WoType.app 等用户关掉教程再删：App 删了，系统设置可能就不列 WoType 了，用户没处点 －
            let listed = await Installer.inputStatus().enabled
            let page = ProgressPage(title: "正在卸载 WoType…",
                                    steps: ["切换到其他输入法", "结束正在运行的 WoType"]
                                        + (listed ? [] : ["删除 WoType.app"])
                                        + (removeData ? ["删除词库、设置和模型"] : []))
            begin(page)
            do {
                var step = 0
                page.begin(step)
                await Installer.deselectWoType()
                step += 1
                page.begin(step)
                await Installer.stopWoType()
                if !listed {
                    step += 1
                    page.begin(step)
                    try await Installer.removeApp()
                }
                if removeData {
                    step += 1
                    page.begin(step)
                    await Installer.removeUserData()
                }
                page.finish()
                end()
                let data = removeData ? "词库和设置已一并删除。" : "词库和设置已保留，重新安装后可以接着用。"
                if listed {
                    pendingRemoval = true
                    showGuide(.remove, hint: "卸载完成。最后一步：把 WoType 从输入法列表移除。\n" + data,
                              primary: ("完成", #selector(finishUninstall)))
                } else {
                    showResult(.success, title: "卸载完成", message: data,
                               buttons: [("返回", #selector(backHome)), ("完成", #selector(quit))])
                }
            } catch {
                Installer.log.error("卸载失败：\(error.localizedDescription, privacy: .public)")
                page.fail()
                end()
                showResult(.failure, title: "卸载没有完成", message: error.localizedDescription,
                           buttons: [("返回", #selector(backHome))])
            }
        }
    }

    /// 移除教程的「完成」：删掉 WoType.app，退出
    @objc private func finishUninstall() {
        removePendingApp()
        NSApp.terminate(nil)
    }

    /// 卸载完还没删的 WoType.app（等用户在系统设置里移除）：点「完成」、关窗口、退出时删
    private var pendingRemoval = false

    func removePendingApp() {
        guard pendingRemoval else { return }
        pendingRemoval = false
        do {
            try Installer.removeAppNow()
        } catch {
            Installer.log.error("删除 WoType.app 失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - 教程页

    /// 只有动画、动画的分步说明、一句提示和按钮，窗口不变大。最后一个按钮是默认按钮（回车）
    private func showGuide(_ mode: InputSourceDemo.Mode, hint: String, primary: (String, Selector)) {
        let page = GuidePage(mode: mode, hint: hint,
                             buttons: [Self.button("打开键盘设置", target: self, action: #selector(openKeyboardSettings)),
                                       Self.button(primary.0, target: self, action: primary.1)])
        show(page)
    }

    @objc private func openKeyboardSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?InputSources")!)
    }

    // MARK: - 结果页

    private enum Outcome { case success, warning, failure }

    /// 最后一个按钮是默认按钮（回车）。
    private func showResult(_ outcome: Outcome, title: String, message: String, buttons: [(String, Selector)]) {
        let (symbol, color): (String, NSColor) = switch outcome {
        case .success: ("checkmark.circle.fill", .systemGreen)
        case .warning: ("exclamationmark.triangle.fill", .systemOrange)
        case .failure: ("xmark.circle.fill", .systemRed)
        }
        let mark = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 52, weight: .regular))!)
        mark.contentTintColor = color
        let titleLabel = Self.label(title, size: 22, weight: .semibold)
        let messageLabel = NSTextField(wrappingLabelWithString: message)
        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center
        messageLabel.preferredMaxLayoutWidth = 460

        let row = NSStackView(views: buttons.map { Self.button($0.0, target: self, action: $0.1) })
        row.spacing = 12
        (row.views.last as? NSButton)?.keyEquivalent = "\r"

        let stack = NSStackView(views: [mark, titleLabel, messageLabel, row])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(16, after: mark)
        stack.setCustomSpacing(28, after: messageLabel)
        show(Self.centered(stack))
    }

    @objc private func backHome() {
        showHome()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - 页面切换

    private func begin(_ page: ProgressPage) {
        isBusy = true
        window?.standardWindowButton(.closeButton)?.isEnabled = false
        progressPage = page
        show(page)
    }

    private func end() {
        isBusy = false
        window?.standardWindowButton(.closeButton)?.isEnabled = true
        progressPage = nil
    }

    /// 新页面淡入、旧页面淡出。
    private func show(_ next: NSView) {
        next.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(next)
        NSLayoutConstraint.activate([
            next.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            next.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            next.topAnchor.constraint(equalTo: root.topAnchor),
            next.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        let old = page
        page = next
        guard let old else { return }
        next.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            old.animator().alphaValue = 0
            next.animator().alphaValue = 1
        }
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            old.removeFromSuperview()
        }
    }

    // MARK: - 小部件

    static func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        return label
    }

    static func button(_ title: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.controlSize = .large
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        return button
    }

    static func centered(_ content: NSView) -> NSView {
        let view = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        return view
    }
}

/// 进度页：标题、进度条、步骤清单（✓ 做完、转圈 正在做、○ 还没做、✗ 出错）。
private final class ProgressPage: NSView {

    private let bar = NSProgressIndicator()
    private let detailLabel = InstallerWindowController.label("", size: 11, color: .secondaryLabelColor)
    private let rows: [StepRow]
    /// 每一步开始时进度条在哪（0～1），多一项 1
    private let starts: [Double]
    private var current = -1

    /// 0～1，只往前走
    var fraction: Double = 0 {
        didSet { bar.doubleValue = max(bar.doubleValue, fraction * 100) }
    }

    var detail: String? {
        didSet { detailLabel.stringValue = detail ?? "" }
    }

    /// weights：每一步占进度条多少，不给就平分
    init(title: String, steps: [String], weights: [Double]? = nil) {
        rows = steps.map(StepRow.init)
        let weights = weights ?? Array(repeating: 1, count: steps.count)
        let sum = weights.reduce(0, +)
        starts = weights.indices.map { weights[..<$0].reduce(0, +) / sum } + [1]
        super.init(frame: .zero)

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        let titleLabel = InstallerWindowController.label(title, size: 17, weight: .semibold)
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 100

        let list = NSStackView(views: rows)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 8

        let barRow = NSStackView(views: [bar, detailLabel])
        barRow.orientation = .vertical
        barRow.alignment = .trailing
        barRow.spacing = 4

        let stack = NSStackView(views: [icon, titleLabel, barRow, list])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(18, after: titleLabel)
        stack.setCustomSpacing(16, after: barRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64),
            bar.widthAnchor.constraint(equalToConstant: 380),
            list.widthAnchor.constraint(equalTo: bar.widthAnchor),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 开始第 index 步，前面的都打勾，进度条走到这一步的起点。
    func begin(_ index: Int) {
        for (i, row) in rows.enumerated() {
            row.state = i < index ? .done : i == index ? .running : .waiting
        }
        current = index
        fraction = starts[index]
    }

    /// 第 index 步做了 part（0～1）：复制文件那一步按字节细分。
    func advance(within index: Int, by part: Double) {
        fraction = starts[index] + (starts[index + 1] - starts[index]) * min(max(part, 0), 1)
    }

    func finish() {
        rows.forEach { $0.state = .done }
        fraction = 1
    }

    func fail() {
        if rows.indices.contains(current) { rows[current].state = .failed }
    }
}

private final class StepRow: NSStackView {

    enum State { case waiting, running, done, failed }

    private let mark = NSImageView()
    private let spinner = NSProgressIndicator()
    private let text: NSTextField

    var state = State.waiting {
        didSet { update() }
    }

    init(_ title: String) {
        text = InstallerWindowController.label(title, size: 13)
        super.init(frame: .zero)
        spinner.style = .spinning
        spinner.controlSize = .small
        let slot = NSView()
        for view in [mark, spinner] {
            view.translatesAutoresizingMaskIntoConstraints = false
            slot.addSubview(view)
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: slot.centerXAnchor),
                view.centerYAnchor.constraint(equalTo: slot.centerYAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            slot.widthAnchor.constraint(equalToConstant: 18),
            slot.heightAnchor.constraint(equalToConstant: 18),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14),
        ])
        setViews([slot, text], in: .leading)
        spacing = 8
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func update() {
        let (symbol, color): (String, NSColor) = switch state {
        case .waiting: ("circle", .tertiaryLabelColor)
        case .running: ("", .labelColor)
        case .done: ("checkmark.circle.fill", .systemGreen)
        case .failed: ("xmark.circle.fill", .systemRed)
        }
        mark.image = symbol.isEmpty ? nil : NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        mark.contentTintColor = color
        text.textColor = state == .waiting ? .secondaryLabelColor : .labelColor
        if state == .running {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
        spinner.isHidden = state != .running
    }
}

/// 教程页：缩小的系统设置动画（InputSourceDemo，和新手引导共用），下面是动画的分步说明、一句提示、按钮。
private final class GuidePage: NSView {

    private let demo: InputSourceDemo

    init(mode: InputSourceDemo.Mode, hint: String, buttons: [NSButton]) {
        demo = InputSourceDemo(mode: mode, showsCaption: false)
        super.init(frame: .zero)

        let picture = DemoBox(demo)
        let caption = NSTextField(labelWithString: "")
        caption.alignment = .center
        let hintLabel = NSTextField(wrappingLabelWithString: hint)
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.alignment = .center
        hintLabel.preferredMaxLayoutWidth = 480
        // 分步说明用正常字号另外显示（动画缩小了，里面的字太小）
        demo.captionChanged = { text in
            caption.attributedStringValue = KeyCaps.text(text, font: .systemFont(ofSize: 13), color: .labelColor, alignment: .center)
        }
        (buttons.last)?.keyEquivalent = "\r"
        let row = NSStackView(views: buttons)
        row.spacing = 12

        for view in [picture, caption, hintLabel, row] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            picture.topAnchor.constraint(equalTo: topAnchor, constant: 30),
            picture.centerXAnchor.constraint(equalTo: centerXAnchor),
            picture.heightAnchor.constraint(equalToConstant: 206),
            picture.widthAnchor.constraint(equalTo: picture.heightAnchor,
                                           multiplier: InputSourceDemo.designSize.width / InputSourceDemo.pictureHeight),
            caption.topAnchor.constraint(equalTo: picture.bottomAnchor, constant: 8),
            caption.centerXAnchor.constraint(equalTo: centerXAnchor),
            caption.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
            hintLabel.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 8),
            hintLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            hintLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
            row.centerXAnchor.constraint(equalTo: centerXAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { demo.start() } else { demo.stop() }
    }
}

/// 把 440 宽的动画整体缩小显示：bounds 固定成动画的大小，frame 多大就缩成多大；只露出上面的画面，说明那一块切掉
private final class DemoBox: NSView {

    private let demo: NSView
    private let design = NSSize(width: InputSourceDemo.designSize.width, height: InputSourceDemo.pictureHeight)

    init(_ demo: NSView) {
        self.demo = demo
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        demo.frame = NSRect(origin: .zero, size: InputSourceDemo.designSize)
        addSubview(demo)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        bounds = NSRect(origin: .zero, size: design)
    }
}

