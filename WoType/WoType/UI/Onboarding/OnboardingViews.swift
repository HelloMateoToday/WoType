//
//  OnboardingViews.swift
//  WoType
//
//  新手引导窗口里的部件（docs/18）：进度点，和翻页用的弹簧动画。
//  动画照 Arion（ui/shared/theme 的 Page、Settle、Quick、Exit），用 Core Animation 的弹簧做，
//  参数用 SpringCurve 换算（duration / bounce → stiffness / damping），和语音浮窗一致。
//

import Cocoa

// MARK: - 动画

enum OnboardingMotion {
    /// 翻页
    static let page = SpringCurve(duration: 0.52, bounce: 0.04)
    /// 进度点的长度
    static let settle = SpringCurve(duration: 0.42, bounce: 0)
    /// 打勾、授权成功这类小东西弹出来
    static let pop = SpringCurve(duration: 0.38, bounce: 0.18)
    /// 颜色
    static let quick: CFTimeInterval = 0.12
    /// 旧的一页离开
    static let exit: CFTimeInterval = 0.16

    /// 系统设置里开了「减弱动态效果」：不滑、不缩放，只淡入淡出。
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    static func spring(_ keyPath: String, from: Any?, to: Any?, _ curve: SpringCurve) -> CASpringAnimation {
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.mass = 1
        animation.stiffness = curve.stiffness
        animation.damping = curve.damping
        animation.fromValue = from
        animation.toValue = to
        animation.duration = animation.settlingDuration
        return animation
    }

    static func basic(_ keyPath: String, from: Any?, to: Any?, duration: CFTimeInterval,
                      timing: CAMediaTimingFunctionName) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: timing)
        return animation
    }

    /// 新的一页进来：从前进的方向滑进 28（刚打开时从下面升上来 10），同时淡入。
    static func enter(_ layer: CALayer, direction: Int) {
        layer.add(basic("opacity", from: 0, to: 1, duration: 0.22, timing: .easeOut), forKey: "enter.opacity")
        guard !reduced else { return }
        // 图层坐标 y 朝上：「从下面升上来」是从 -10 开始
        let (keyPath, offset) = direction == 0
            ? ("transform.translation.y", -10.0) : ("transform.translation.x", 28.0 * Double(direction))
        layer.add(spring(keyPath, from: offset, to: 0, page), forKey: "enter.move")
    }

    /// 旧的一页离开：以中心缩到 0.98、淡出，然后移除。
    static func exit(_ view: NSView) {
        guard let layer = view.layer else {
            view.removeFromSuperview()
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { view.removeFromSuperview() }
        CATransaction.setDisableActions(true)
        layer.opacity = 0
        layer.add(basic("opacity", from: 1, to: 0, duration: exit, timing: .easeIn), forKey: "exit.opacity")
        if !reduced {
            let b = layer.bounds
            var shrink = CATransform3DMakeTranslation(b.midX, b.midY, 0)
            shrink = CATransform3DScale(shrink, 0.98, 0.98, 1)
            shrink = CATransform3DTranslate(shrink, -b.midX, -b.midY, 0)
            layer.add(basic("transform", from: CATransform3DIdentity, to: shrink, duration: exit, timing: .easeIn),
                      forKey: "exit.scale")
            layer.transform = shrink
        }
        CATransaction.commit()
    }
}

// MARK: - 进度点

/// 进度点：一步一个点，当前这一步拉长成胶囊（照 Arion ui/widgets/stepper）。
final class OnboardingStepper: NSView {

    static let dot: CGFloat = 6
    static let active: CGFloat = 22
    static let gap: CGFloat = 6

    private var dots: [CALayer] = []
    private var current = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        let n = CGFloat(dots.count)
        guard n > 0 else { return NSSize(width: 0, height: Self.dot) }
        return NSSize(width: (n - 1) * (Self.dot + Self.gap) + Self.active, height: Self.dot)
    }

    func set(current: Int, total: Int, animated: Bool) {
        var animated = animated
        if dots.count != total {
            dots.forEach { $0.removeFromSuperlayer() }
            dots = (0..<total).map { _ in
                let dot = CALayer()
                dot.cornerRadius = Self.dot / 2
                layer?.addSublayer(dot)
                return dot
            }
            invalidateIntrinsicContentSize()
            animated = false
        }
        self.current = current
        setAccessibilityLabel("第 \(current + 1) 步，共 \(total) 步")
        layoutDots(animated: animated)
    }

    private func color(_ index: Int) -> CGColor {
        var color = NSColor.quaternaryLabelColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = (index == current ? NSColor.labelColor
                     : index < current ? NSColor.tertiaryLabelColor : NSColor.quaternaryLabelColor).cgColor
        }
        return color
    }

    private func layoutDots(animated: Bool) {
        let animated = animated && !OnboardingMotion.reduced
        var x: CGFloat = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, dot) in dots.enumerated() {
            let width = i == current ? Self.active : Self.dot
            let frame = CGRect(x: x, y: 0, width: width, height: Self.dot)
            x += width + Self.gap
            let color = color(i)
            if animated {
                let shown = dot.presentation() ?? dot
                dot.add(OnboardingMotion.spring("bounds", from: NSValue(rect: shown.bounds),
                                                 to: NSValue(rect: CGRect(origin: .zero, size: frame.size)),
                                                 OnboardingMotion.settle), forKey: "bounds")
                dot.add(OnboardingMotion.spring("position", from: NSValue(point: shown.position),
                                                 to: NSValue(point: CGPoint(x: frame.midX, y: frame.midY)),
                                                 OnboardingMotion.settle), forKey: "position")
                dot.add(OnboardingMotion.basic("backgroundColor", from: shown.backgroundColor, to: color,
                                                duration: OnboardingMotion.quick, timing: .easeOut),
                        forKey: "color")
            }
            dot.frame = frame
            dot.backgroundColor = color
        }
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layoutDots(animated: false)
    }

    override var mouseDownCanMoveWindow: Bool { true }
}
