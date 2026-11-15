//
//  ModeToast.swift
//  WoType
//
//  切换中 / 英时在光标下面亮一块圆角方块「中」「英」（样式照 screenshots/1.mp4）：
//  第一次出现从一条竖线展开；还亮着时再切换，就横着压扁、换字、再拉开，像翻牌；
//  停手一会儿淡出。颜色照状态栏图标，跟着浅色 / 深色模式反过来。
//  划词翻译（docs/16）借它显示「翻译中」：同样的方块，字换成转圈，一直转到 hideLoading。
//

import Cocoa

final class ModeToast {

    static let shared = ModeToast()

    private static let size = NSSize(width: 24, height: 24)
    private static let font = NSFont.systemFont(ofSize: 14, weight: .medium)
    /// 翻牌压扁、拉开各用的时间
    private static let flipHalf: CFTimeInterval = 0.08
    /// 最后一次切换后亮多久再开始淡出
    private static let hold: TimeInterval = 1.5
    private static let fadeOut: TimeInterval = 0.25

    private let panel: NSPanel
    /// 自己管的图层，锚点放中间，压扁时才是往中线收
    private let card = CALayer()
    private let label = CATextLayer()
    /// 翻译中的转圈（一段圆弧绕中心转）
    private let spinner = CAShapeLayer()
    /// 正在显示转圈
    private(set) var isLoading = false
    private var flipWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?
    /// 每次 show 加一，淡出结束时对不上就说明中途又显示了，不能收起
    private var generation = 0

    private init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.cursorWindow)) - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // 窗口阴影跟不上图层压扁，不要
        panel.hasShadow = false
        panel.ignoresMouseEvents = true

        let host = NSView(frame: NSRect(origin: .zero, size: Self.size))
        host.wantsLayer = true
        card.frame = host.bounds
        card.cornerRadius = 6
        card.cornerCurve = .continuous
        label.font = Self.font
        label.fontSize = Self.font.pointSize
        label.alignmentMode = .center
        card.addSublayer(label)
        let arc = NSRect(x: 0, y: 0, width: 12, height: 12)
        spinner.frame = NSRect(x: (Self.size.width - arc.width) / 2, y: (Self.size.height - arc.height) / 2,
                               width: arc.width, height: arc.height)
        spinner.path = CGPath(ellipseIn: arc.insetBy(dx: 1, dy: 1), transform: nil)
        spinner.fillColor = nil
        spinner.lineWidth = 2
        spinner.lineCap = .round
        spinner.strokeEnd = 0.7
        spinner.isHidden = true
        card.addSublayer(spinner)
        host.layer?.addSublayer(card)
        panel.contentView = host
    }

    func show(_ text: String, near caret: NSRect) {
        generation += 1
        hideWork?.cancel()
        let wasVisible = panel.isVisible && panel.alphaValue > 0
        stopSpinner()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // 动态色要在当前外观下取，跟着浅色 / 深色模式变
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            card.backgroundColor = Theme.modeIndicator.cgColor
            label.foregroundColor = Theme.modeIndicatorText.cgColor
            spinner.strokeColor = Theme.modeIndicatorText.cgColor
        }
        CATransaction.commit()

        panel.setFrameOrigin(CandidatePanel.origin(for: Self.size, caret: caret))
        let scale = panel.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        card.contentsScale = scale
        label.contentsScale = scale
        // 正在淡出就停下，直接回到不透明
        NSAnimationContext.runAnimationGroup { $0.duration = 0; panel.animator().alphaValue = 1 }
        panel.orderFront(nil)

        if wasVisible {
            flip(to: text)
        } else {
            // 新出现：从一条竖线展开
            flipWork?.cancel()
            card.removeAllAnimations()
            setText(text)
            setScaleX(0)
            expand()
        }

        let work = DispatchWorkItem { [weak self] in self?.fade() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hold, execute: work)
    }

    // MARK: - 翻译中

    /// 方块里转圈，放在 anchor 下面（放不下放上面），一直亮到 hideLoading。
    func showLoading(near anchor: NSRect) {
        generation += 1
        hideWork?.cancel()
        flipWork?.cancel()
        let wasVisible = panel.isVisible && panel.alphaValue > 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            card.backgroundColor = Theme.modeIndicator.cgColor
            spinner.strokeColor = Theme.modeIndicatorText.cgColor
        }
        label.string = ""
        spinner.isHidden = false
        CATransaction.commit()
        isLoading = true
        let rotate = CABasicAnimation(keyPath: "transform.rotation.z")
        rotate.fromValue = 0
        rotate.toValue = -2 * CGFloat.pi
        rotate.duration = 0.8
        rotate.repeatCount = .infinity
        spinner.add(rotate, forKey: "spin")

        panel.setFrameOrigin(CandidatePanel.origin(for: Self.size, caret: anchor))
        let scale = panel.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        card.contentsScale = scale
        spinner.contentsScale = scale
        NSAnimationContext.runAnimationGroup { $0.duration = 0; panel.animator().alphaValue = 1 }
        panel.orderFront(nil)
        if !wasVisible {
            card.removeAnimation(forKey: "flip")
            setScaleX(0)
            expand()
        }
    }

    /// 翻译结束：转圈的方块淡出；animated 为 false 时马上收起（接着要在同一处弹气泡，淡出会从气泡底下透出来）。
    /// 没在转圈就不动，免得把刚亮起的「中」「英」收掉
    func hideLoading(animated: Bool = true) {
        guard isLoading else { return }
        stopSpinner()
        if animated {
            fade()
        } else {
            generation += 1
            panel.orderOut(nil)
        }
    }

    private func stopSpinner() {
        isLoading = false
        spinner.removeAnimation(forKey: "spin")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spinner.isHidden = true
        CATransaction.commit()
    }

    // MARK: - 翻牌

    /// 压扁到一条线 → 换字 → 拉开。连按时从当前宽度接着压，字总是最后一次的
    private func flip(to text: String) {
        flipWork?.cancel()
        let current = (card.presentation()?.value(forKeyPath: "transform.scale.x") as? CGFloat) ?? 1
        card.removeAllAnimations()
        setScaleX(0)
        animateScaleX(from: current, to: 0, duration: Self.flipHalf * Double(current),
                      timing: .easeIn)
        let work = DispatchWorkItem { [weak self] in
            self?.setText(text)
            self?.expand()
        }
        flipWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.flipHalf * Double(current), execute: work)
    }

    private func expand() {
        setScaleX(1)
        animateScaleX(from: 0, to: 1, duration: Self.flipHalf, timing: .easeOut)
    }

    private func animateScaleX(from: CGFloat, to: CGFloat, duration: CFTimeInterval,
                               timing: CAMediaTimingFunctionName) {
        let anim = CABasicAnimation(keyPath: "transform.scale.x")
        anim.fromValue = from
        anim.toValue = to
        anim.duration = duration
        anim.timingFunction = CAMediaTimingFunction(name: timing)
        card.add(anim, forKey: "flip")
    }

    private func setScaleX(_ x: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        card.transform = CATransform3DMakeScale(x, 1, 1)
        CATransaction.commit()
    }

    private func setText(_ text: String) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        label.string = text
        // CATextLayer 不会竖着居中，按字的行高自己摆
        let height = ceil(Self.font.ascender - Self.font.descender)
        label.frame = NSRect(x: 0, y: (Self.size.height - height) / 2,
                             width: Self.size.width, height: height)
        CATransaction.commit()
    }

    // MARK: - 淡出

    private func fade() {
        let current = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeOut
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.generation == current else { return }
            self.panel.orderOut(nil)
        })
    }
}
