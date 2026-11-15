//
//  VoiceCapsule.swift
//  WoType
//
//  移植自 Arion apps/desktop/bootstrap/windows.go（createOverlay、positionOverlay）和
//  apps/desktop/infrastructure/macos/overlay.m@d2108fe（AGPL-3.0-only），Objective-C 翻成 Swift。
//
//  放浮窗的窗口：720×180、透明、点击穿透、不抢焦点，在鼠标所在屏幕的工作区底部正中。
//  窗口大小固定，胶囊在里面动（CapsuleView，Core Animation 图层）；全屏应用的桌面上也显示。
//  「已记住」提示的撤销按钮：浮窗一直点击穿透，按钮上另放一个透明的小窗口接点击和悬停
//  （Arion 是把浮窗缩到胶囊那一条、临时不穿透：bootstrap/learning.go 的 showLearned）。
//

import AppKit

@MainActor
final class VoiceCapsule {

    static let shared = VoiceCapsule()

    static let width: CGFloat = 720
    static let height: CGFloat = 180

    let model = CapsuleModel()
    private var panel: NSPanel?
    private var capsule: CapsuleView?
    /// 撤销按钮上接点击的小窗口
    private var undoPanel: NSPanel?
    /// 点了撤销（参数是学到的词条 id）
    var onUndo: ((String) -> Void)?

    private init() {
        model.onIdle = { [weak self] in self?.panel?.orderOut(nil) }
        model.onUndoFrame = { [weak self] frame in self?.placeUndo(frame) }
    }

    /// 学到了一个词：不在听写时显示「已记住」5 秒（在听写时不显示）。
    func showLearned(id: String, from: String, to: String) {
        guard !model.dictation.isActive else { return }
        model.learned = LearnedNotice(id: id, from: from, to: to, at: Date())
        model.undoHovered = false
        show()
    }

    /// 收起「已记住」（撤销了、开始下一次听写）。
    func dismissLearned() {
        guard model.learned != nil else { return }
        model.learned = nil
        model.undoHovered = false
        placeUndo(nil)
    }

    /// 把接点击的小窗口放到撤销按钮上（frame 是浮窗视图里的位置，nil 就收起）。
    private func placeUndo(_ frame: CGRect?) {
        guard let frame, let panel, let capsule, panel.isVisible else {
            undoPanel?.orderOut(nil)
            return
        }
        let screenRect = panel.convertToScreen(capsule.convert(frame, to: nil))
        let undo = undoPanel ?? makeUndoPanel()
        undo.setFrame(screenRect, display: false)
        if !undo.isVisible { undo.orderFrontRegardless() }
    }

    private func makeUndoPanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        // 完全透明的窗口不接点击，留一点点不透明
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.002)
        panel.hasShadow = false
        panel.level = .statusBar
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = true
        configureOverlay(panel)
        let hotspot = UndoHotspot()
        hotspot.onHover = { [weak self] inside in self?.model.undoHovered = inside }
        hotspot.onClick = { [weak self] in
            guard let self, let id = self.model.learned?.id else { return }
            self.dismissLearned()
            self.onUndo?(id)
        }
        panel.contentView = hotspot
        undoPanel = panel
        return panel
    }

    var dictation: DictationState { model.dictation }

    /// 改浮窗的状态。会话还在的时候窗口一直显示，收起动画放完自己关。
    func update(_ change: (inout DictationState) -> Void) {
        change(&model.dictation)
        guard Dictation.phase(model.dictation, at: Date()) != .hidden else { return }
        show()
    }

    /// 进入一个新状态（记下时间，结果停留的时长从这时算）。
    func set(_ state: SessionState) {
        update {
            if $0.state != state {
                $0.state = state
                $0.changed = Date()
            }
        }
    }

    /// 加一个音量（每 20 ms 一个，留最近 48 个）。
    func level(_ value: Float) {
        model.dictation.levels.append(value)
        if model.dictation.levels.count > DictationState.levelHistory {
            model.dictation.levels.removeFirst(model.dictation.levels.count - DictationState.levelHistory)
        }
    }

    private func show() {
        let panel = self.panel ?? makePanel()
        position(panel)
        if !panel.isVisible { panel.orderFrontRegardless() }
        capsule?.start()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        configureOverlay(panel)
        let view = CapsuleView(model: model)
        view.frame = panel.contentLayoutRect
        panel.contentView = view
        capsule = view
        self.panel = panel
        return panel
    }

    /// overlay.m：全屏应用的桌面上也要能显示。只加入所有桌面不够，要 FullScreenAuxiliary，
    /// 并且去掉 FullScreenNone、Managed、Stationary、MoveToActiveSpace 这些和它冲突的。
    private func configureOverlay(_ window: NSWindow) {
        var behavior = window.collectionBehavior
        behavior.remove([.fullScreenPrimary, .fullScreenNone, .moveToActiveSpace, .managed, .stationary,
                         .participatesInCycle, .primary, .auxiliary])
        behavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle, .canJoinAllApplications])
        window.collectionBehavior = behavior
    }

    /// 鼠标所在屏幕的工作区底部正中（用户在哪儿干活就在哪儿）。
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        let origin = NSPoint(x: (area.midX - Self.width / 2).rounded(), y: area.minY)
        if panel.frame.origin != origin {
            panel.setFrameOrigin(origin)
        }
    }
}

/// 撤销按钮上透明的接点击视图：悬停时按钮变亮、手形光标，点一下撤销。不抢焦点（窗口不激活）。
private final class UndoHotspot: NSView {
    var onHover: ((Bool) -> Void)?
    var onClick: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}
