//
//  FrameAnimator.swift
//  WoType
//
//  逐帧动画的小工具，给照 Arion 移植的浮窗用。Arion 的界面框架 MyGo 是逐帧重画的：
//  每帧对每个要动的值调 AnimateTo(key, 目标, 弹簧)，框架记住它现在在哪、速度多少，往目标走一步；
//  Loop 是按周期循环的进度；Keyframes 是按时间走的关键帧。这里用同样的用法：
//  浮窗每帧（TimelineView）调这些方法，值存在这个对象里，跨帧保留。
//
//  弹簧用 SpringCurve（duration / bounce 或 stiffness / damping，和 MyGo 的参数一一对应）。
//

import Foundation

@MainActor
final class FrameAnimator {

    private struct Track {
        var value: Double
        var velocity: Double
    }

    private var tracks: [String: Track] = [:]
    private var loops: [String: Date] = [:]
    private var keyframeStarts: [String: (run: UInt64, start: Date)] = [:]
    private var lastFrame: Date?
    private(set) var now = Date()
    /// 这一帧有没有还在动的值（没有就可以停掉逐帧刷新）
    private(set) var moving = false

    /// 每帧开始时调。
    func begin(_ date: Date) {
        now = date
        moving = false
    }

    private var deltaTime: Double {
        // 第一帧、停了一阵再动的帧：只走一帧的量，不跳
        guard let lastFrame else { return 1 / 60 }
        let dt = now.timeIntervalSince(lastFrame)
        return dt > 0 && dt < 0.25 ? dt : 1 / 60
    }

    /// 每帧结束时调。
    func end() {
        lastFrame = now
    }

    /// 让 key 这个值沿弹簧往 target 走一步，返回它现在的值。第一次出现时直接等于 target（除非给了 from）。
    func animate(_ key: String, to target: Double, _ spring: SpringCurve, from: Double? = nil) -> Double {
        var track = tracks[key] ?? Track(value: from ?? target, velocity: 0)
        var value = track.value
        var velocity = track.velocity
        spring.update(value: &value, velocity: &velocity, target: target, deltaTime: deltaTime)
        if abs(value - target) < 0.0005 && abs(velocity) < 0.001 {
            value = target
            velocity = 0
        } else {
            moving = true
        }
        track.value = value
        track.velocity = velocity
        tracks[key] = track
        return value
    }

    /// 直接设成某个值（不动画）。
    func set(_ key: String, _ value: Double) {
        tracks[key] = Track(value: value, velocity: 0)
    }

    func value(_ key: String) -> Double? { tracks[key]?.value }

    /// 把值和目标一起平移 delta（速度不变）：内容整体挪了，正在走的动画接着走。
    func offset(_ key: String, by delta: Double) {
        tracks[key]?.value += delta
    }

    /// 循环：从第一次调用开始，每 period 秒从 0 走到 1，经过 ease。
    func loop(_ key: String, period: Double, ease: (Double) -> Double = { $0 }) -> Double {
        let start = loops[key] ?? now
        loops[key] = start
        moving = true
        let t = now.timeIntervalSince(start).truncatingRemainder(dividingBy: period) / period
        return ease(t)
    }

    func stopLoop(_ key: String) {
        loops[key] = nil
    }

    /// 关键帧：run 变了就从头放一遍（Arion 用会话号当 run，每次语音只放一次）。
    /// frames 是（时间，值，缓动）；delay 之前停在第一帧。
    func keyframes(_ key: String, run: UInt64, delay: Double = 0,
                   _ frames: [(at: Double, value: Double, ease: (Double) -> Double)]) -> Double {
        if keyframeStarts[key]?.run != run {
            keyframeStarts[key] = (run, now)
        }
        let elapsed = now.timeIntervalSince(keyframeStarts[key]!.start) - delay
        guard let first = frames.first, let last = frames.last else { return 0 }
        if elapsed <= first.at {
            moving = true
            return first.value
        }
        if elapsed >= last.at { return last.value }
        moving = true
        for i in 1..<frames.count where elapsed <= frames[i].at {
            let a = frames[i - 1]
            let b = frames[i]
            let t = (elapsed - a.at) / (b.at - a.at)
            return a.value + (b.value - a.value) * b.ease(t)
        }
        return last.value
    }

    /// 清掉某个前缀下的所有状态（一个元素离开以后）。
    func forget(prefix: String) {
        tracks = tracks.filter { !$0.key.hasPrefix(prefix) }
        loops = loops.filter { !$0.key.hasPrefix(prefix) }
        keyframeStarts = keyframeStarts.filter { !$0.key.hasPrefix(prefix) }
    }
}

/// MyGo 里用到的几种缓动。
enum Ease {
    static func linear(_ t: Double) -> Double { t }

    static func easeOut(_ t: Double) -> Double { 1 - pow(1 - t, 3) }

    static func easeInOut(_ t: Double) -> Double {
        if t < 0.5 { return 4 * t * t * t }
        let u = 2 - 2 * t
        return 1 - u * u * u / 2
    }

    /// 沿 ease 去、再同样的时间回来（脉动）。
    static func bounce(_ ease: @escaping (Double) -> Double) -> (Double) -> Double {
        { t in t < 0.5 ? ease(2 * t) : ease(2 - 2 * t) }
    }

    /// 三次贝塞尔缓动（和 CSS cubic-bezier 一样，x 用牛顿法反解）。
    static func cubicBezier(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> (Double) -> Double {
        func bezier(_ t: Double, _ a: Double, _ b: Double) -> Double {
            3 * (1 - t) * (1 - t) * t * a + 3 * (1 - t) * t * t * b + t * t * t
        }
        func derivative(_ t: Double, _ a: Double, _ b: Double) -> Double {
            3 * (1 - t) * (1 - t) * a + 6 * (1 - t) * t * (b - a) + 3 * t * t * (1 - b)
        }
        return { x in
            var t = x
            for _ in 0..<8 {
                let error = bezier(t, x1, x2) - x
                let slope = derivative(t, x1, x2)
                if abs(error) < 1e-5 || slope == 0 { break }
                t -= error / slope
            }
            return bezier(min(max(t, 0), 1), y1, y2)
        }
    }
}
