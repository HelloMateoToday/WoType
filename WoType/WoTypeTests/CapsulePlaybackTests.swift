//
//  CapsulePlaybackTests.swift
//  WoTypeTests
//
//  浮窗草稿的流畅度：把一串草稿（时间、文字）按 60 帧放进 CapsuleView，逐帧画出来，量文字每帧挪了多少。
//  平滑的滑动是每帧往左挪一点；往回跳、一下跳好几点就是抖。
//
//  默认用内嵌的一小段（豆包、微信实测的回复：中间补标点、带换行）。排查时可以换成录下来的整段：
//    TEST_RUNNER_CAPSULE_SEQUENCE=<json> TEST_RUNNER_CAPSULE_FRAMES=<目录> xcodebuild test -only-testing:WoTypeTests/CapsulePlaybackTests
//  json 是 [{"t": 秒, "draft": 文字}, …, {"t": 秒, "final": 文字}]；给了目录就把每次改字前后的几帧拼成图存下来。
//

import AppKit
import Testing
@testable import WoType

@MainActor
struct CapsulePlaybackTests {

    struct Step {
        let time: Double
        let text: String
        let final: Bool
    }

    /// 实测回复里挑的：先打出来，然后中间补逗号、改写法，微信还插换行
    static let sample: [Step] = [
        ("第一段我们先回顾一下上周的进度", 0.6), ("第一段，我们先回顾一下上周的进度。", 1.6),
        ("第一段，我们先回顾一下上周的进度。第二段开发这边已经完成了登录", 2.6),
        ("第一段，我们先回顾一下上周的进度。\n第二段开发这边已经完成了登录和注册两个模块", 3.4),
        ("第一段：我们先回顾一下上周的进度。\n第二段：开发这边已经完成了登录和注册两个模块，测试那边发现了三个问题", 4.4),
        ("第一段：我们先回顾一下上周的进度。\n第二段：开发这边已经完成了登录和注册两个模块，测试那边发现了 3 个问题，其中一个比较严重。", 5.4),
    ].map { Step(time: $0.1, text: $0.0, final: false) }

    struct Report {
        /// 每帧文字挪了多少（点，负的是往左）
        var moves: [Double] = []
        /// 往回跳、大跳的那几帧：时间（秒）、挪了多少
        var anomalies: [(time: Double, move: Double)] = []
        /// 改字（不是只在结尾加字）的时间
        var rewrites: [Double] = []
        /// 画出来的文字里出现过换行（单行草稿画成两行，叠在一起）
        var drewNewline = false
        /// 往回跳（往右挪超过 1 点）的帧数
        var backward: Int { moves.filter { $0 > 1 }.count }
        /// 一帧挪了 4 点以上的帧数
        var jumps: Int { moves.filter { abs($0) >= 4 }.count }
    }

    @Test func draftScrollsWithoutJitter() throws {
        let report = play(Self.loadSequence() ?? Self.sample, framesDirectory: Self.environment("CAPSULE_FRAMES"))
        print("浮窗回放：\(report.moves.count) 帧，往回跳 \(report.backward) 帧，大跳 \(report.jumps) 帧，画了换行：\(report.drewNewline)")
        #expect(!report.drewNewline)
    }

    /// 文字图层换内容不能有系统的隐式动画（0.25 秒交叉淡化）：位置同时在动，新旧两行会错开叠在一起
    /// （2026-11-14 录屏看到的「重叠」；layer.render 画的是模型层，回放测试看不出来，只能这样查）
    @Test func textLayersHaveNoImplicitAnimations() {
        let model = CapsuleModel()
        let view = CapsuleView(model: model)
        view.frame = NSRect(x: 0, y: 0, width: VoiceCapsule.width, height: VoiceCapsule.height)
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        model.dictation = DictationState(state: .capturing, changed: start, sessionID: "s", draft: "明天下午三点开会", holding: true)
        for k in 0..<30 { _ = view.renderForTesting(at: start.addingTimeInterval(Double(k) / 60)) }
        var textLayers: [CALayer] = []
        func walk(_ layer: CALayer) {
            if layer.value(forKey: "debugText") != nil { textLayers.append(layer) }
            layer.sublayers?.forEach(walk)
        }
        if let layer = view.layer { walk(layer) }
        #expect(!textLayers.isEmpty)
        for layer in textLayers {
            for key in ["contents", "position", "bounds"] { #expect(layer.action(forKey: key) == nil) }
        }
    }

    // MARK: - 回放

    func play(_ steps: [Step], framesDirectory: String?) -> Report {
        let model = CapsuleModel()
        let view = CapsuleView(model: model)
        view.frame = NSRect(x: 0, y: 0, width: VoiceCapsule.width, height: VoiceCapsule.height)
        view.appearance = NSAppearance(named: .aqua)
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        model.dictation = DictationState(state: .capturing, changed: start, sessionID: "playback", holding: true, keyLegend: "⌘")
        let end = (steps.last?.time ?? 0) + 1.5
        var report = Report()
        var previous: [Double]?
        var pending = steps[...]
        var lastText = ""
        // 改字（不是只在结尾加字）前后几帧存图
        var shots: [(label: String, images: [CGImage])] = []
        var capture: (label: String, until: Int, images: [CGImage])?
        var recent: [CGImage] = []
        var index = 0
        var t = 0.0
        while t <= end {
            while let step = pending.first, step.time <= t {
                pending = pending.dropFirst()
                if step.final {
                    model.dictation.state = .finalizing
                    model.dictation.changed = start.addingTimeInterval(t)
                }
                model.dictation.draft = step.text
                if !step.text.hasPrefix(lastText) { report.rewrites.append(t) }
                if !step.text.hasPrefix(lastText), framesDirectory != nil {
                    capture = ("\(String(format: "%05.2f", t))s 改字", index + (Int(Self.environment("CAPSULE_SHOT") ?? "") ?? 12), recent)
                }
                lastText = step.text
            }
            let clip = view.renderForTesting(at: start.addingTimeInterval(t))
            if let clip, let image = Self.snapshot(view, clip) {
                if Self.drawnText(view).contains("\n") { report.drewNewline = true }
                let profile = Self.inkProfile(image)
                if let previous {
                    let move = Self.displacement(previous, profile)
                    report.moves.append(move)
                    if move > 1 || abs(move) >= 4 { report.anomalies.append((t, move)) }
                }
                previous = profile
                recent = Array((recent + [image]).suffix(4))
                if var c = capture {
                    c.images.append(image)
                    capture = index >= c.until ? nil : c
                    if index >= c.until { shots.append((c.label, c.images)) }
                }
            }
            index += 1
            t += 1.0 / 60
        }
        if let directory = framesDirectory {
            let summary = "帧数 \(report.moves.count)，往回跳 \(report.backward)，大跳 \(report.jumps)，画了换行 \(report.drewNewline)\n"
                + "改字：" + report.rewrites.map { String(format: "%.2f", $0) }.joined(separator: " ") + "\n"
                + "异常：" + report.anomalies.map { String(format: "%.2f:%g", $0.time, $0.move) }.joined(separator: " ") + "\n"
                + "每帧挪动（点）：" + report.moves.map { String(format: "%g", $0) }.joined(separator: " ")
            try? summary.write(to: URL(fileURLWithPath: directory).appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
            for (i, shot) in shots.enumerated() {
                Self.writeStrip(shot.images, to: URL(fileURLWithPath: directory).appendingPathComponent(
                    String(format: "%02d %@.png", i, shot.label)))
            }
        }
        return report
    }

    // MARK: - 量

    /// 草稿区画成图（2 倍）
    static func snapshot(_ view: CapsuleView, _ clip: CGRect) -> CGImage? {
        guard let layer = view.layer else { return nil }
        let scale: CGFloat = 2
        let width = Int(clip.width * scale), height = Int(clip.height * scale)
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        // 视图是翻转坐标（y 往下）
        context.translateBy(x: -clip.minX, y: clip.maxY)
        context.scaleBy(x: 1, y: -1)
        layer.render(in: context)
        return context.makeImage()
    }

    /// 每一列有多少「墨」（和背景差多少；深色、浅色外观都行）
    static func inkProfile(_ image: CGImage) -> [Double] {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var luminance = [Double](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            luminance[i] = (0.299 * Double(pixels[i * 4]) + 0.587 * Double(pixels[i * 4 + 1]) + 0.114 * Double(pixels[i * 4 + 2])) / 255
        }
        let background = luminance.sorted()[luminance.count / 2]
        var profile = [Double](repeating: 0, count: width)
        for y in 0..<height {
            for x in 0..<width { profile[x] += abs(background - luminance[y * width + x]) }
        }
        return profile
    }

    /// 前后两帧对齐要挪多少（点）：在 ±24 点里找差最小的
    static func displacement(_ a: [Double], _ b: [Double]) -> Double {
        let n = min(a.count, b.count)
        guard n > 100 else { return 0 }
        var best = 0, bestCost = Double.infinity
        for d in -48...48 {
            var cost = 0.0, count = 0
            for x in 0..<n where x + d >= 0 && x + d < n {
                cost += abs(a[x] - b[x + d])
                count += 1
            }
            cost /= Double(max(count, 1))
            if cost < bestCost - 1e-9 || (abs(cost - bestCost) < 1e-9 && abs(d) < abs(best)) {
                best = d
                bestCost = cost
            }
        }
        return Double(best) / 2
    }

    /// 草稿那一行现在画的文字
    static func drawnText(_ view: CapsuleView) -> String {
        var texts: [String] = []
        func walk(_ layer: CALayer) {
            if let text = layer.value(forKey: "debugText") as? String { texts.append(text) }
            layer.sublayers?.forEach(walk)
        }
        if let layer = view.layer { walk(layer) }
        return texts.joined()
    }

    /// 几帧竖着拼成一张图
    static func writeStrip(_ images: [CGImage], to url: URL) {
        guard let first = images.first else { return }
        let gap = 4
        let height = images.count * (first.height + gap)
        guard let context = CGContext(data: nil, width: first.width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.setFillColor(NSColor.systemRed.withAlphaComponent(0.3).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: first.width, height: height))
        for (i, image) in images.enumerated() {
            context.draw(image, in: CGRect(x: 0, y: height - (i + 1) * (first.height + gap), width: image.width, height: image.height))
        }
        guard let strip = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: strip).representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }

    // MARK: - 输入

    static func environment(_ name: String) -> String? {
        ProcessInfo.processInfo.environment[name] ?? ProcessInfo.processInfo.environment["TEST_RUNNER_" + name]
    }

    static func loadSequence() -> [Step]? {
        guard let path = environment("CAPSULE_SEQUENCE"), let data = FileManager.default.contents(atPath: path),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return items.compactMap { item in
            guard let time = item["t"] as? Double else { return nil }
            if let draft = item["draft"] as? String { return Step(time: time, text: draft, final: false) }
            if let final = item["final"] as? String { return Step(time: time, text: final, final: true) }
            return nil
        }
    }
}
