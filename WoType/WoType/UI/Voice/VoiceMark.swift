//
//  VoiceMark.swift
//  WoType
//
//  移植自 Arion apps/desktop/ui/shared/kit/voicemark.go@d2108fe（AGPL-3.0-only），
//  以及 kit.go 的 levelAt。MyGo 的 Box/AnimateTo/Loop 换成 FrameAnimator，Painter 换成 6 个 Core Animation 图层
//  （1 个红点、5 根竖条），每帧只改它们的位置、大小和不透明度。
//
//  语音图标：App 图标的 5 根竖条活过来。
//  - listening：竖条是音量表，左边一个红点在跳；
//  - waiting：竖条折成 3 个点，一个脉冲在点之间走（麦克风还在打开、识别还没完）；
//  - orbiting：3 个点绕圈转（润色在整理文字）；
//  - resting：竖条立成完整的图标（文字定下来了）。
//  每种状态只是改同一组形状的弹簧目标，所以状态之间（哪怕切到一半）都是一个连续的动作。
//

import AppKit
import QuartzCore

enum MarkMode {
    case listening
    case waiting
    case orbiting
    case resting
}

enum VoiceMark {

    /// App 图标的竖条轮廓（相对最高的那根）
    static let bars: [Double] = [230.0 / 560, 420.0 / 560, 1, 360.0 / 560, 250.0 / 560]
    /// 每根竖条折成哪个点：中间那根变成中间的点，两边各两根并进旁边的点，不会有形状凭空出现或消失
    static let dots = [0, 0, 1, 2, 2]
    /// 没声音时竖条站多高：说话前也看得出是图标
    static let rest = 0.4
    /// 每根竖条按离中间的距离晚一点折，从中间往外收拢
    static let stagger = 0.12
    /// 脉冲走过 3 个点一遍的时间
    static let wave = 1.4
    /// 转一圈：前 turn 的时间在转，后面停；每个点比后面那个晚 chase 开始
    static let spin = 1.6
    static let turn = 0.68
    static let chase = 0.045
    /// 转的缓动：慢起、快中、长收尾，停顿看起来是「到了」而不是「停了」
    static let spinEase = Ease.cubicBezier(0.7, 0, 0.25, 1)
    static let levelSpring = SpringCurve(stiffness: 520, damping: 32)

    struct Pose {
        var levels = [Double](repeating: 0, count: 5)
        var live = 0.0
        var fold = 0.0
        var orbit = 0.0
        var wave = 0.0
        var spin = [0.0, 0.0, 0.0]
    }

    struct Shape {
        var rect: CGRect
        var alpha: Double
    }

    /// 高 h、姿势 pose 时各个形状的位置：红点，然后 5 根按音量站着的竖条，
    /// 按 fold 折成点，点按 orbit 从一排移到圆上。
    static func layout(height h: Double, pose: Pose) -> (width: Double, live: Shape, bars: [Shape]) {
        let bar = 0.15 * h
        let dot = bar * 5 / 3
        let open = clamp01(pose.live)
        let orbit = clamp01(pose.orbit)
        // 麦克风开着时红点在竖条前面，关了就缩没，连同它的间距
        let lead = 0.9 * h * open
        let radius = 0.2 * h * open
        let live = Shape(rect: CGRect(x: 0, y: h / 2 - radius, width: 2 * radius, height: 2 * radius), alpha: open)
        let center = lead + 4.5 * bar
        let ring = 0.3 * h
        var shapes: [Shape] = []
        for i in 0..<5 {
            let distance = Double(abs(i - 2))
            let p = clamp01((pose.fold - stagger * distance) / (1 - 2 * stagger))
            let j = dots[i]
            var d = abs(pose.wave - Double(j) / 3)
            d = min(d, 1 - d)
            // 在圆上时点不变大小：转本身就是动作
            let pulse = lerp(exp(-(d * d) / 0.045), 1, orbit)
            let size = dot * (0.84 + 0.22 * pulse)
            let angle = 2 * Double.pi * (Double(j - 1) / 3 - 0.25 + pose.spin[j])
            let dx = lerp(center + Double(j - 1) * 3 * bar, center + ring * cos(angle), orbit)
            let dy = lerp(h / 2 - 0.2 * h * pulse, h / 2 + ring * sin(angle), orbit)
            let standing = bar + (h * bars[i] - bar) * (rest + (1 - rest) * clamp01(pose.levels[i]))
            let w = lerp(bar, size, p)
            let ht = lerp(standing, size, p)
            let x = lerp(lead + bar / 2 + Double(i) * 2 * bar, dx, p)
            let y = lerp(h / 2, dy, p)
            var alpha = lerp(1, 0.5 + 0.5 * pulse, p)
            if i % 2 == 1 {
                // 单数的竖条并进旁边的点，自己的不透明度留在后面
                alpha *= 1 - p
            }
            shapes.append(Shape(rect: CGRect(x: x - w / 2, y: y - ht / 2, width: w, height: ht), alpha: alpha))
        }
        return (lead + 9 * bar, live, shapes)
    }

    static func spinAt(_ u: Double) -> [Double] {
        (0..<3).map { j in spinEase(clamp01((u - chase * Double(j)) / turn)) }
    }

    /// 第 i 根竖条显示的音量：最新的在中间，旧的往两边。
    static func levelAt(_ levels: [Float], _ i: Int, _ count: Int) -> Double {
        let n = levels.count
        guard n > 0 else { return 0 }
        let index = n - 1 - abs(i - count / 2) * max(n / count, 1)
        return index < 0 ? 0 : Double(levels[index])
    }

    /// 这一帧的姿势（弹簧和循环存在 animator 里，key 是这个图标的名字）。
    @MainActor
    static func pose(_ animator: FrameAnimator, key: String, levels: [Float], mode: MarkMode) -> Pose {
        var pose = Pose()
        pose.live = animator.animate(key + ".live", to: mode == .listening ? 1 : 0, VoiceStyle.pop)
        pose.fold = animator.animate(key + ".fold", to: mode == .waiting || mode == .orbiting ? 1 : 0, VoiceStyle.pop)
        pose.orbit = animator.animate(key + ".orbit", to: mode == .orbiting ? 1 : 0, VoiceStyle.pop)
        for i in 0..<5 {
            let target = mode == .resting ? 1 : levelAt(levels, i, 5)
            pose.levels[i] = animator.animate(key + ".bar\(i)", to: target, levelSpring)
        }
        if pose.fold > 0.004 && pose.orbit < 0.996 {
            pose.wave = animator.loop(key + ".wave", period: wave)
        } else {
            animator.stopLoop(key + ".wave")
        }
        if pose.orbit > 0.004 {
            pose.spin = spinAt(animator.loop(key + ".spin", period: spin))
        } else {
            animator.stopLoop(key + ".spin")
        }
        return pose
    }

    /// 把姿势放到图层上：dot 是红点，bars 是 5 根竖条（都在同一个父图层里，原点在左上角、y 往下）。
    @MainActor
    static func apply(_ pose: Pose, height h: Double, animator: FrameAnimator, key: String,
                      dot: CALayer, bars: [CALayer], ink: NSColor, live liveColor: NSColor) {
        var pulse = 1.0
        if pose.live > 0.004 {
            pulse = 0.45 + 0.55 * animator.loop(key + ".pulse", period: 1.4, ease: Ease.bounce(Ease.easeInOut))
        } else {
            animator.stopLoop(key + ".pulse")
        }
        let (_, liveShape, barShapes) = layout(height: h, pose: pose)
        func place(_ layer: CALayer, _ shape: Shape, _ color: NSColor, _ alpha: Double) {
            layer.frame = shape.rect
            layer.cornerRadius = min(shape.rect.width, shape.rect.height) / 2
            layer.backgroundColor = color.cgColor
            layer.opacity = Float(max(0, alpha))
        }
        place(dot, liveShape, liveColor, liveShape.alpha * pulse)
        for (layer, shape) in zip(bars, barShapes) { place(layer, shape, ink, shape.alpha) }
    }

    static func width(height h: Double, pose: Pose) -> Double {
        layout(height: h, pose: pose).width
    }
}

func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a * (1 - t) + b * t }

func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }
