//
//  VoiceControls.swift
//  WoType
//
//  设置 › 语音的麦克风控件，照 Arion apps/desktop/ui/features/microphone/microphone.go@d2108fe（AGPL-3.0-only）：
//  - 输入增益：分档的滑块（-6 到 +12 dB，每 3 dB 一档，packages/core/application/gain.go 的 GainStops），
//    每个刻度下面写这一档建议的说话距离，选中的那个加粗；
//  - 音量表：24 根竖条，最新的音量在中间、旧的往两边，越靠边越矮（kit.go 的 LevelBars）。
//  MyGo 的 StepSlider、LevelBars 换成 AppKit 的 NSSlider 和自己画的视图。
//

import AppKit

/// 增益的一档：分贝和它适合的说话距离（gain.go 的 GainStop）。
nonisolated struct GainStop {
    let db: Int
    let distanceCM: Int

    /// 说话的音量每远一倍降 6 dB，所以每 3 dB 一档对应远 √2 倍；0 dB 是设备本来的音量，适合约 30 厘米
    static let all = [
        GainStop(db: -6, distanceCM: 15), GainStop(db: -3, distanceCM: 21), GainStop(db: 0, distanceCM: 30),
        GainStop(db: 3, distanceCM: 42), GainStop(db: 6, distanceCM: 60), GainStop(db: 9, distanceCM: 85),
        GainStop(db: 12, distanceCM: 120),
    ]

    static func distance(_ db: Int) -> Int { all.first { $0.db == db }?.distanceCM ?? 30 }

    /// 「0 dB，建议距离约 30 厘米」
    static func describe(_ db: Int) -> String { "\(db) dB，建议距离约 \(distance(db)) 厘米" }
}

/// 分档的增益滑块，刻度下面是每档的距离。拖动时只改上面的说明，松手才保存。
final class GainSlider: NSView {
    private let slider = NSSlider()
    private var labels: [NSTextField] = []
    private let onPreview: (Int) -> Void
    private let onCommit: (Int) -> Void

    init(db: Int, onPreview: @escaping (Int) -> Void, onCommit: @escaping (Int) -> Void) {
        self.onPreview = onPreview
        self.onCommit = onCommit
        super.init(frame: .zero)
        let stops = GainStop.all
        slider.minValue = Double(stops.first!.db)
        slider.maxValue = Double(stops.last!.db)
        slider.numberOfTickMarks = stops.count
        slider.allowsTickMarkValuesOnly = true
        slider.tickMarkPosition = .below
        slider.doubleValue = Double(db)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(changed)
        slider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(slider)
        // 两头各留出半个标签的宽度，最边上的「15 厘米」「120 厘米」不会被截掉
        NSLayoutConstraint.activate([
            slider.topAnchor.constraint(equalTo: topAnchor),
            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            heightAnchor.constraint(equalToConstant: 44),
        ])
        for stop in stops {
            let label = NSTextField(labelWithString: "\(stop.distanceCM) 厘米")
            label.font = .systemFont(ofSize: 10.5)
            label.alignment = .center
            addSubview(label)
            labels.append(label)
        }
        highlight(db)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // 刻度离两头各有半个滑块的距离，距离标签按同样的位置放在刻度正下方
        let knob = slider.knobThickness > 0 ? slider.knobThickness : 20
        let track = slider.frame.width - knob
        for (i, label) in labels.enumerated() {
            let x = slider.frame.minX + knob / 2 + track * CGFloat(i) / CGFloat(labels.count - 1)
            let size = label.intrinsicContentSize
            label.frame = NSRect(x: x - size.width / 2, y: 28, width: size.width, height: size.height)
        }
    }

    override var isFlipped: Bool { true }

    private var value: Int { Int(slider.doubleValue.rounded()) }

    private func highlight(_ db: Int) {
        for (label, stop) in zip(labels, GainStop.all) {
            let selected = stop.db == db
            label.font = .systemFont(ofSize: 10.5, weight: selected ? .semibold : .regular)
            label.textColor = selected ? .labelColor : .secondaryLabelColor
        }
    }

    @objc private func changed() {
        highlight(value)
        onPreview(value)
        // 松手才保存（保存会让整页重建，拖动中重建会打断拖动）
        if NSApp.currentEvent?.type == .leftMouseUp || NSApp.currentEvent?.type == .keyDown {
            onCommit(value)
        }
    }
}

/// 设置页的音量表（kit.LevelBars）：24 根竖条，最新的音量在中间，旧的往两边，中间高、两边矮。
final class LevelMeterView: NSView {
    static let count = 24
    private var levels: [Float] = []
    private var heights = [CGFloat](repeating: 0, count: count)
    private var velocity = [CGFloat](repeating: 0, count: count)
    private var link: CADisplayLink?
    private var last = Date()

    override var intrinsicContentSize: NSSize { NSSize(width: CGFloat(Self.count) * 7 - 3, height: 36) }

    func push(_ level: Float) {
        levels.append(level)
        if levels.count > 48 { levels.removeFirst(levels.count - 48) }
        if link == nil, window != nil {
            let link = displayLink(target: self, selector: #selector(step))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            link?.invalidate()
            link = nil
        }
    }

    /// 每根竖条朝目标高度走一步（弹簧：刚度 520、阻尼 32，和 Arion 一样）。
    @objc private func step() {
        let now = Date()
        let dt = min(0.05, now.timeIntervalSince(last))
        last = now
        let spring = SpringCurve(stiffness: 520, damping: 32)
        let width: CGFloat = 4
        let height = bounds.height
        let n = levels.count
        for i in 0..<Self.count {
            // levelAt：最新的在中间，往两边是更早的
            let index = n - 1 - abs(i - Self.count / 2) * max(n / Self.count, 1)
            let level = index >= 0 && index < n ? CGFloat(levels[index]) : 0
            let shape = 1 - 0.55 * CGFloat(abs(i - Self.count / 2)) / CGFloat(Self.count / 2 + 1)
            let target = width + (height - width) * level * shape
            var value = Double(heights[i])
            var speed = Double(velocity[i])
            spring.update(value: &value, velocity: &speed, target: Double(target), deltaTime: dt)
            heights[i] = CGFloat(value)
            velocity[i] = CGFloat(speed)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let width: CGFloat = 4
        let gap: CGFloat = 3
        NSColor.labelColor.setFill()
        for (i, h) in heights.enumerated() {
            let barHeight = max(width, h)
            let x = CGFloat(i) * (width + gap)
            let rect = NSRect(x: x, y: (bounds.height - barHeight) / 2, width: width, height: barHeight)
            NSBezierPath(roundedRect: rect, xRadius: width / 2, yRadius: width / 2).fill()
        }
    }
}
