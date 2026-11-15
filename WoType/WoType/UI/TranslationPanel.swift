//
//  TranslationPanel.swift
//  WoType
//
//  划词翻译的结果气泡（docs/16）：popover 的样子，圆角框加一个小三角指着选中的文字，里面只有一段字——
//  译文，或者翻译失败的原因（2 秒后自己收起）。翻译中不用它，用 ModeToast 的转圈。
//  不抢焦点（和候选窗一样是不激活的面板），配色跟着候选窗的皮肤。按任何键、点外面、换输入框都收起。
//

import Cocoa

final class TranslationPanel {

    static let shared = TranslationPanel()

    /// 是不是正开着
    var isVisible: Bool { panel.isVisible }

    /// 文字最宽多少（再长就换行）
    private static let maxTextWidth: CGFloat = 340
    private static let padding = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
    /// 三角的高、底边宽
    private static let arrowHeight: CGFloat = 8
    private static let arrowWidth: CGFloat = 16
    /// 三角离气泡左边至少多远（不压在圆角上）
    private static let arrowInset: CGFloat = Theme.cornerRadius + 4
    /// 气泡和选中文字之间留的空
    private static let gap: CGFloat = 2

    private let panel: NSPanel
    private var mouseMonitor: Any?
    private var hideWork: DispatchWorkItem?

    private init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: true)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.cursorWindow)) - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
    }

    // MARK: - 显示

    /// 译文。note 是译文上面的一行灰字（「输入框的内容变了，没有替换」）
    func show(_ text: String, note: String? = nil, near anchor: NSRect) {
        present(text, color: Theme.text, note: note, near: anchor, autoHide: nil)
    }

    /// 翻译失败的原因，autoHide 秒后自己收起
    func showMessage(_ text: String, near anchor: NSRect, autoHide: TimeInterval = 2) {
        present(text, color: Theme.secondaryText, note: nil, near: anchor, autoHide: autoHide)
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        stopWatchingClicks()
        panel.orderOut(nil)
    }

    private func present(_ text: String, color: NSColor, note: String?, near anchor: NSRect, autoHide: TimeInterval?) {
        hideWork?.cancel()
        let body = NSMutableAttributedString()
        if let note {
            body.append(NSAttributedString(string: note + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: Theme.secondaryText,
            ]))
        }
        body.append(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: color,
        ]))
        let bounds = body.boundingRect(with: NSSize(width: Self.maxTextWidth, height: 10_000),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading])
        let textSize = NSSize(width: ceil(bounds.width), height: ceil(bounds.height))
        let size = NSSize(width: textSize.width + Self.padding.left + Self.padding.right,
                          height: textSize.height + Self.padding.top + Self.padding.bottom + Self.arrowHeight)

        // 放在选中文字下面、三角朝上；下面放不下就放上面、三角朝下
        let screen = NSScreen.screens.first { $0.frame.contains(anchor.origin) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let below = anchor.minY - Self.gap - size.height >= visible.minY
        // 三角对着选中文字的开头一段（选区很长时不跑到中间去），气泡往左让出一点
        let pointX = anchor.minX + min(anchor.width / 2, 24)
        var origin = NSPoint(x: pointX - Self.arrowInset - Self.arrowWidth / 2,
                             y: below ? anchor.minY - Self.gap - size.height : anchor.maxY + Self.gap)
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        let arrowX = min(max(pointX - origin.x, Self.arrowInset + Self.arrowWidth / 2),
                         size.width - Self.arrowInset - Self.arrowWidth / 2)

        let view = BubbleView(frame: NSRect(origin: .zero, size: size))
        view.arrowUp = below
        view.arrowX = arrowX
        view.arrowSize = NSSize(width: Self.arrowWidth, height: Self.arrowHeight)
        let label = NSTextField(labelWithAttributedString: body)
        label.isSelectable = false
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.preferredMaxLayoutWidth = Self.maxTextWidth
        label.frame = NSRect(x: Self.padding.left - 2,
                             y: Self.padding.bottom + (below ? 0 : Self.arrowHeight),
                             width: textSize.width + 4, height: textSize.height)
        view.addSubview(label)

        panel.contentView = view
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFront(nil)
        panel.invalidateShadow()
        startWatchingClicks()
        if let autoHide {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + autoHide, execute: work)
        }
    }

    /// 点气泡外面、按任何键（Esc、接着打字）收起。全局监听只收到别的应用的事件；
    /// 光标不在输入框里时（网页正文上的翻译并显示）输入法收不到 Esc，靠这里收起
    private func startWatchingClicks() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] _ in
            self?.hide()
        }
    }

    private func stopWatchingClicks() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
    }
}

/// 圆角框 + 小三角，皮肤的底色和边框
private final class BubbleView: NSView {
    var arrowUp = true
    /// 三角尖在 x 方向的位置
    var arrowX: CGFloat = 30
    var arrowSize = NSSize(width: 16, height: 8)

    override func draw(_ dirtyRect: NSRect) {
        let path = outline()
        Theme.background.setFill()
        path.fill()
        Theme.border.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    /// 一笔画出圆角框和三角（边框在三角处不断开）。AppKit 坐标 y 朝上
    private func outline() -> NSBezierPath {
        let inset = bounds.insetBy(dx: 0.5, dy: 0.5)
        let box = arrowUp
            ? NSRect(x: inset.minX, y: inset.minY, width: inset.width, height: inset.height - arrowSize.height)
            : NSRect(x: inset.minX, y: inset.minY + arrowSize.height, width: inset.width, height: inset.height - arrowSize.height)
        let r = Theme.cornerRadius
        let half = arrowSize.width / 2
        let path = NSBezierPath()
        // 从底边左端（圆角结束处）开始，逆时针
        path.move(to: NSPoint(x: box.minX + r, y: box.minY))
        if !arrowUp {
            path.line(to: NSPoint(x: arrowX - half, y: box.minY))
            path.line(to: NSPoint(x: arrowX, y: box.minY - arrowSize.height))
            path.line(to: NSPoint(x: arrowX + half, y: box.minY))
        }
        path.line(to: NSPoint(x: box.maxX - r, y: box.minY))
        path.appendArc(withCenter: NSPoint(x: box.maxX - r, y: box.minY + r), radius: r, startAngle: 270, endAngle: 0)
        path.line(to: NSPoint(x: box.maxX, y: box.maxY - r))
        path.appendArc(withCenter: NSPoint(x: box.maxX - r, y: box.maxY - r), radius: r, startAngle: 0, endAngle: 90)
        if arrowUp {
            path.line(to: NSPoint(x: arrowX + half, y: box.maxY))
            path.line(to: NSPoint(x: arrowX, y: box.maxY + arrowSize.height))
            path.line(to: NSPoint(x: arrowX - half, y: box.maxY))
        }
        path.line(to: NSPoint(x: box.minX + r, y: box.maxY))
        path.appendArc(withCenter: NSPoint(x: box.minX + r, y: box.maxY - r), radius: r, startAngle: 90, endAngle: 180)
        path.line(to: NSPoint(x: box.minX, y: box.minY + r))
        path.appendArc(withCenter: NSPoint(x: box.minX + r, y: box.minY + r), radius: r, startAngle: 180, endAngle: 270)
        path.close()
        return path
    }
}
