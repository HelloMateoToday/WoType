//
//  CapsuleView.swift
//  WoType
//
//  移植自 Arion apps/desktop/ui/widgets/capsule/capsule.go@d2108fe（AGPL-3.0-only），
//  以及 ui/shared/kit/kit.go 的 Pill、Kbd。MyGo 的逐帧界面换成 AppKit + Core Animation：
//  胶囊、图标、文字各是一个图层，每帧（显示器刷新时）只算位置、大小、不透明度、变换，
//  文字只在内容变了时重画一次，不再每帧把整个胶囊重画。
//
//  和 Arion 不同：
//  - 键帽上画修饰键的图标（fn 是地球，⌥、⌘ 是它们的符号），不是文字；
//  - 结果和提示：图标放在实心圆底里（完成绿色、取消灰色、失败红色）；两行的提示胶囊高 56、
//    左右内边距 18 / 22、图标和文字间距 12、两行之间 3（Arion 是 44、16 / 18、10、1，两行太挤）；
//  - 「已记住」的提示：撤销按钮由另一个透明小窗口接点击（VoiceCapsule），浮窗本身一直点击穿透；
//  - 没有「云端润色降级」的提示（云端润色还没做）。
//
//  浮窗：说话时一个实时音量表、流式草稿，然后是结果，状态之间用弹簧过渡。
//  胶囊在透明窗口的底部正中，离底边 22 pt。
//

import AppKit
import QuartzCore

@MainActor
final class CapsuleModel {
    var dictation = DictationState()
    /// 刚学到的词（capsule.go 的 learnedNotice、dictation.go 的 LearnedShown）：不在听写时显示 5 秒
    var learned: LearnedNotice?
    /// 鼠标在「撤销」上
    var undoHovered = false
    /// 胶囊完全收起了（窗口可以关）
    var onIdle: (() -> Void)?
    /// 「撤销」按钮在视图里的位置（没显示时是 nil）：VoiceCapsule 把接点击的小窗口放上去
    var onUndoFrame: ((CGRect?) -> Void)?

    static let learnedVisible: TimeInterval = 5

    func visibleLearned(at now: Date) -> LearnedNotice? {
        guard let learned, now.timeIntervalSince(learned.at) < Self.learnedVisible else { return nil }
        return learned
    }
}

/// 「已记住 错误写法 → 正确写法」
struct LearnedNotice: Equatable {
    let id: String
    let from: String
    let to: String
    let at: Date
}

/// 一个会进场、离场的内容行（MyGo 的 ElementTransition）。
private struct Presence {
    var key: String
    var entering: Bool
}

/// 进场、离场时的样子（MyGo 的 Motion：缩放、往下移、透明度 0）。
private struct Motion {
    var scale: Double
    var y: Double
}

@MainActor
final class CapsuleView: NSView {

    // MARK: 常量（capsule.go、kit.go）

    /// 草稿最多排这么多字，再前面的早就在左边界外面了
    static let previewRunes = 600
    /// 草稿那一行排、画最后多少个字（文字区最宽 248 点，约 17 个字，够用；整段都排的话长句每帧要排几百个字）
    static let drawRunes = 80
    /// 草稿变长时整行往左滑：打字机每几帧加一个字，弹簧把这些小步连成一个动作
    static let glide = SpringCurve(duration: 0.18, bounce: 0)
    /// 滑动最多落后目标多少（约一个字）：最新的、还在淡入的字不会滑出右边
    static let maxLag = 16.0
    /// 字从左边离开时渐隐的宽度
    static let edgeFade = 28.0
    static let lineHeight = 22.0
    /// 文字区：一开始和「结束」提示一样宽，随草稿按 slotStep 一档变宽，结尾留 slotHeadroom，最宽 slotMax。
    /// 一次语音里只变宽不变窄：流式结果会改来改去，按文字定宽的胶囊会跟着每个结果一胀一缩
    static let slotStep = 24.0
    static let slotHeadroom = 16.0
    static let slotMax = 248.0
    fileprivate static let pillEnter = Motion(scale: 0.86, y: 14)
    fileprivate static let pillExit = Motion(scale: 0.92, y: 10)
    fileprivate static let contentEnter = Motion(scale: 0.94, y: 0)
    fileprivate static let contentExit = Motion(scale: 0.97, y: 0)
    static let pillHeight = 44.0
    static let paddingLeft = 16.0
    static let paddingRight = 18.0
    static let gap = 10.0
    static let bottom = 22.0
    /// 两行的提示（WoType 加大的间距）
    static let noticeHeight = 56.0
    static let noticePaddingLeft = 18.0
    static let noticePaddingRight = 22.0
    static let noticeGap = 12.0
    static let noticeCircle = 22.0
    static let noticeLineGap = 3.0
    /// 单行结果的圆底（Arion 的 ✓ 是 18）
    static let outcomeCircle = 18.0

    let model: CapsuleModel
    private let animator = FrameAnimator()
    private var typing = Typewriter()
    private var tokens = VoiceTokens.resolve(dark: false)

    /// 这次语音里文字区到过的最宽
    private var slotSession = ""
    private var slot = 0.0
    private var pillShown = false
    private var pillEntering = true
    private var rows: [Presence] = []
    /// 每一行最后一次是当前行时的样子：离场的行按它画，不按新状态重画
    private var rowSnapshots: [String: (DictationState, DictationPhase)] = [:]
    private var lastDictation = DictationState()
    private var lastPhase = DictationPhase.hidden
    private var lastKey = "hidden"
    /// 最后显示的「已记住」（收起时还按它画）
    private var lastLearned: LearnedNotice?
    /// 「撤销」按钮的位置（视图坐标）
    private var undoFrame: CGRect?
    private var idleReported = true
    private var hintShown = false

    private let bodyFont = NSFont.systemFont(ofSize: VoiceStyle.body)
    private let bodyMedium = NSFont.systemFont(ofSize: VoiceStyle.body, weight: .medium)
    private let captionFont = NSFont.systemFont(ofSize: VoiceStyle.caption)
    private var advances: [Character: Double] = [:]
    /// 上一帧草稿画的文字和要滑出去的宽度（改字时让滑动跟着宽度一起挪）
    private var drawnDraft: (session: String, text: String, hidden: Double, xs: [Int: Double], shift: Double)?
    /// 结尾变短时滑动先停住：到什么时候、停在哪儿、变短前有几个字
    private var shiftHold: (until: Date, value: Double, length: Int)?
    /// 结尾变短后滑动停多久：识别多半很快把结尾补回来，补上了整行就不用先往右滑再滑回去
    static let shrinkHold: TimeInterval = 0.4

    // MARK: 图层

    private let pill = CALayer()
    private let farShadow = CALayer()
    private let nearShadow = CALayer()
    private let body = CALayer()
    private let highlight = CAShapeLayer()
    private let content = CALayer()
    private var rowLayers: [String: RowLayers] = [:]
    private var link: CADisplayLink?

    init(model: CapsuleModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.isGeometryFlipped = true
        layer?.masksToBounds = false
        for shadow in [farShadow, nearShadow] {
            shadow.shadowOpacity = 1
            pill.addSublayer(shadow)
        }
        body.masksToBounds = true
        body.borderWidth = 1
        highlight.fillRule = .evenOdd
        body.addSublayer(highlight)
        pill.addSublayer(body)
        content.masksToBounds = true
        pill.addSublayer(content)
        layer?.addSublayer(pill)
        pill.opacity = 0
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    // MARK: - 逐帧

    /// 开始逐帧刷新（浮窗要显示时调）。
    func start() {
        guard link == nil else { return }
        let link = displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        tokens = VoiceTokens.resolve(dark: dark)
        let scale = window?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame(now: Date(), scale: scale)
        CATransaction.commit()
    }

    /// 测试用：画 now 这一帧（不开逐帧刷新），返回草稿区在视图里的位置（没有草稿是 nil）。
    func renderForTesting(at now: Date, scale: CGFloat = 2) -> CGRect? {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame(now: now, scale: scale)
        CATransaction.commit()
        guard let r = rowLayers["live"], r.draftClip.opacity > 0 else { return nil }
        return r.draftClip.convert(r.draftClip.bounds, to: layer)
    }

    private func frame(now: Date, scale: CGFloat) {
        animator.begin(now)
        defer { animator.end() }
        var d = model.dictation
        var phase = Dictation.phase(d, at: now)
        // 不在听写时，刚学到的词显示 5 秒
        let learned = phase == .hidden ? model.visibleLearned(at: now) : nil
        let key: String
        if phase == .hidden && learned == nil {
            key = lastKey
            // 收起时还画最后的样子（在缩小、淡出）
            d = lastDictation
            phase = lastPhase
            if pillShown {
                pillShown = false
                pillEntering = false
            }
        } else {
            if !pillShown {
                // 进场：从 Enter 的样子弹到原位
                pillShown = true
                pillEntering = true
                animator.set("pill.presence", 0)
                animator.forget(prefix: "row.")
                rows = []
                rowLayers.values.forEach { $0.container.removeFromSuperlayer() }
                rowLayers = [:]
                idleReported = false
            }
            // 说话的几个阶段共用一行，说完时草稿留在原地，不是离场再进场
            key = if learned != nil { "learned" } else {
                switch phase {
                case .preparing, .listening, .transcribing, .polishing, .reviewing, .inserting: "live"
                case .done: "done"
                case .note: "note"
                case .failed: "failed"
                case .cancelled: "cancelled"
                case .hidden: "hidden"
                }
            }
            lastDictation = d
            lastPhase = phase
            lastKey = key
            if let learned { lastLearned = learned }
        }
        let presence = animator.animate("pill.presence", to: pillShown ? 1 : 0, VoiceStyle.settle)
        if !pillShown && presence < 0.01 {
            pill.opacity = 0
            if !idleReported {
                idleReported = true
                reportUndo(nil)
                stop()
                model.onIdle?()
            }
            return
        }
        if rows.last?.key != key {
            for i in rows.indices { rows[i].entering = false }
            rows.append(Presence(key: key, entering: true))
            animator.set("row.\(key).presence", rows.count == 1 ? 1 : 0)
            rowLayers[key]?.container.removeFromSuperlayer()
            let layers = RowLayers(scale: scale)
            content.addSublayer(layers.container)
            rowLayers[key] = layers
            if key == "live" { hintShown = false }
        }
        rowSnapshots[key] = (d, phase)

        var rowPresence: [(Presence, Double)] = []
        for row in rows {
            let p = animator.animate("row.\(row.key).presence", to: row.entering ? 1 : 0, VoiceStyle.pop)
            rowPresence.append((row, p))
        }
        for (row, p) in rowPresence where !row.entering && p <= 0.01 {
            rowLayers[row.key]?.container.removeFromSuperlayer()
            rowLayers[row.key] = nil
        }
        rows = rowPresence.filter { $0.0.entering || $0.1 > 0.01 }.map(\.0)
        rowSnapshots = rowSnapshots.filter { entry in rows.contains { $0.key == entry.key } }

        // 胶囊的大小跟着当前这一行走（Settle）
        let size = rowSize(key, d, phase: phase)
        let width = animator.animate("pill.width", to: size.width, VoiceStyle.settle, from: size.width)
        let height = animator.animate("pill.height", to: size.height, VoiceStyle.settle, from: size.height)
        let motion = pillEntering ? Self.pillEnter : Self.pillExit
        let s = lerp(motion.scale, 1, presence)
        let dy = lerp(motion.y, 0, presence)
        let rect = CGRect(x: ((bounds.width - width) / 2).rounded(), y: bounds.height - Self.bottom - height,
                          width: width, height: height)
        layoutPill(rect, scale: s, dy: dy, opacity: presence)

        for (row, p) in rowPresence where row.entering || p > 0.01 {
            guard let layers = rowLayers[row.key] else { continue }
            let m = row.entering ? Self.contentEnter : Self.contentExit
            let rs = lerp(m.scale, 1, p)
            layers.container.frame = CGRect(origin: .zero, size: rect.size)
            layers.container.opacity = Float(clamp01(p))
            layers.container.transform = scaleAround(CGPoint(x: rect.width / 2, y: rect.height / 2), rs, dy: 0)
            let (rowState, rowPhase) = rowSnapshots[row.key] ?? (d, phase)
            layoutRow(row.key, layers, rowState, phase: rowPhase, size: rect.size, now: now)
        }
        // 「撤销」能点：「已记住」这一行在、而且基本进场了
        if key == "learned", pillShown, presence > 0.5, let button = rowLayers["learned"]?.undoButton.frame {
            reportUndo(button.offsetBy(dx: rect.minX, dy: rect.minY))
        } else {
            reportUndo(nil)
        }
    }

    private func reportUndo(_ frame: CGRect?) {
        let rounded = frame.map { $0.integral }
        guard rounded != undoFrame else { return }
        undoFrame = rounded
        model.onUndoFrame?(rounded)
    }

    // MARK: - 胶囊（kit.Pill）

    /// 圆角到底、表面色、1 pt 边、顶部 1 pt 内亮边、两层阴影。
    private func layoutPill(_ rect: CGRect, scale s: Double, dy: Double, opacity: Double) {
        pill.frame = rect
        pill.opacity = Float(clamp01(opacity))
        pill.transform = scaleAround(CGPoint(x: rect.width / 2, y: rect.height / 2), s, dy: dy)
        let bounds = CGRect(origin: .zero, size: rect.size)
        let radius = rect.height / 2
        for layer in [farShadow, nearShadow, body, content] { layer.frame = bounds }
        farShadow.shadowPath = CGPath(roundedRect: bounds.insetBy(dx: 6, dy: 6), cornerWidth: radius - 6,
                                      cornerHeight: radius - 6, transform: nil)
        farShadow.shadowColor = tokens.shade.withAlphaComponent(0.36).cgColor
        farShadow.shadowRadius = 12
        farShadow.shadowOffset = CGSize(width: 0, height: 10)
        nearShadow.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        nearShadow.shadowColor = tokens.shade.withAlphaComponent(0.22).cgColor
        nearShadow.shadowRadius = 2
        nearShadow.shadowOffset = CGSize(width: 0, height: 2)
        body.cornerRadius = radius
        body.backgroundColor = tokens.pillSurface.cgColor
        body.borderColor = tokens.pillBorder.cgColor
        content.cornerRadius = radius
        // 内亮边：胶囊减去往下挪 1 pt 的胶囊
        let ring = CGMutablePath()
        ring.addRoundedRect(in: bounds, cornerWidth: radius, cornerHeight: radius)
        ring.addRoundedRect(in: bounds.offsetBy(dx: 0, dy: 1), cornerWidth: radius, cornerHeight: radius)
        highlight.frame = bounds
        highlight.path = ring
        highlight.fillColor = tokens.pillText.withAlphaComponent(0.06).cgColor
    }

    // MARK: - 内容行

    private func markMode(_ phase: DictationPhase) -> MarkMode {
        switch phase {
        case .listening: .listening
        case .polishing: .orbiting
        case .reviewing, .inserting: .resting
        default: .waiting
        }
    }

    /// 某一行的胶囊尺寸（含内边距）。
    private func rowSize(_ key: String, _ d: DictationState, phase: DictationPhase) -> CGSize {
        switch key {
        case "live":
            let pose = VoiceMark.pose(animator, key: "mark", levels: d.levels, mode: markMode(phase))
            let w = VoiceMark.width(height: 20, pose: pose) + Self.gap + liveSlotWidth(d, phase: phase)
            return CGSize(width: Self.paddingLeft + w + Self.paddingRight, height: Self.pillHeight)
        case "done":
            return CGSize(width: Self.paddingLeft + Self.outcomeCircle + Self.gap + width(d.outcome, bodyMedium) + Self.paddingRight,
                          height: Self.pillHeight)
        case "cancelled":
            return CGSize(width: Self.paddingLeft + Self.outcomeCircle + Self.gap + width(DictationCopy.cancelled, bodyFont) + Self.paddingRight,
                          height: Self.pillHeight)
        case "note":
            let notice = d.polishNote ?? DictationCopy.generic
            let text = min(420, max(width(notice.title, bodyMedium), notice.hint.map { width($0, captionFont) } ?? 0))
            return CGSize(width: Self.noticePaddingLeft + Self.noticeCircle + Self.noticeGap + text + Self.noticePaddingRight,
                          height: notice.hint == nil ? Self.pillHeight : Self.noticeHeight)
        case "failed":
            let notice = d.failure ?? DictationCopy.generic
            let text = min(420, max(width(notice.title, bodyMedium), notice.hint.map { width($0, captionFont) } ?? 0))
            if notice.hint == nil {
                return CGSize(width: Self.paddingLeft + Self.outcomeCircle + Self.gap + text + Self.paddingRight,
                              height: Self.pillHeight)
            }
            return CGSize(width: Self.noticePaddingLeft + Self.noticeCircle + Self.noticeGap + text + Self.noticePaddingRight,
                          height: Self.noticeHeight)
        case "learned":
            guard let l = lastLearned else { fallthrough }
            let fixed = Self.paddingLeft + 15 + Self.learnedGap + width(DictationCopy.learned, bodyFont) + Self.learnedGap
                + Self.learnedGap + undoWidth + Self.paddingRight
            let pair = min(pairWidth(l), Self.learnedMax - fixed)
            return CGSize(width: fixed + pair, height: Self.pillHeight)
        default:
            return CGSize(width: Self.paddingLeft + Self.paddingRight, height: Self.pillHeight)
        }
    }

    // 「已记住」一行（capsule.go 的 learnedNotice）：图标、「已记住」、错误写法 → 正确写法、撤销
    static let learnedGap = 8.0
    static let learnedMax = 600.0
    static let undoHeight = 28.0

    private var undoWidth: Double { width(DictationCopy.undo, NSFont.systemFont(ofSize: VoiceStyle.caption, weight: .medium)) + 20 }

    private func pairText(_ l: LearnedNotice) -> NSAttributedString {
        let text = NSMutableAttributedString(string: l.from, attributes: [.font: bodyFont, .foregroundColor: tokens.pillText])
        text.append(NSAttributedString(string: "  →  ", attributes: [.font: captionFont, .foregroundColor: tokens.pillMuted]))
        text.append(NSAttributedString(string: l.to, attributes: [.font: bodyMedium, .foregroundColor: tokens.pillText]))
        return text
    }

    private func pairWidth(_ l: LearnedNotice) -> Double {
        ceil(pairText(l).size().width) + 2
    }

    private func learnedRow(_ r: RowLayers, midY: Double, size: CGSize) {
        guard let l = lastLearned else { return }
        let icon = CGRect(x: Self.paddingLeft, y: midY - 9, width: 15, height: 18)
        r.symbol("sparkles", size: 13, weight: .medium, color: tokens.pillMuted, in: icon)
        r.title.update(DictationCopy.learned, bodyFont, tokens.pillMuted,
                       at: CGPoint(x: icon.maxX + Self.learnedGap, y: midY), height: Self.lineHeight)
        let pairX = icon.maxX + Self.learnedGap + width(DictationCopy.learned, bodyFont) + Self.learnedGap
        let button = CGRect(x: size.width - Self.paddingRight - undoWidth, y: midY - Self.undoHeight / 2,
                            width: undoWidth, height: Self.undoHeight)
        // 太长时截断在撤销按钮前面
        r.pairClip.frame = CGRect(x: pairX, y: midY - Self.lineHeight / 2,
                                  width: max(0, button.minX - Self.learnedGap - pairX), height: Self.lineHeight)
        r.pairText.update(pairText(l), at: CGPoint(x: 0, y: Self.lineHeight / 2), width: pairWidth(l), height: Self.lineHeight)
        let hover = animator.animate("undo.hover", to: model.undoHovered ? 1 : 0, VoiceStyle.pop)
        r.undoButton.frame = button
        r.undoButton.cornerRadius = VoiceStyle.radiusControl
        r.undoButton.backgroundColor = tokens.pillText.withAlphaComponent(lerp(0.12, 0.2, hover)).cgColor
        r.undoText.update(DictationCopy.undo, NSFont.systemFont(ofSize: VoiceStyle.caption, weight: .medium), tokens.pillText,
                          at: CGPoint(x: 10, y: Self.undoHeight / 2), height: Self.lineHeight)
    }

    private func layoutRow(_ key: String, _ r: RowLayers, _ d: DictationState, phase: DictationPhase,
                           size: CGSize, now: Date) {
        let midY = size.height / 2
        switch key {
        case "live":
            let pose = VoiceMark.pose(animator, key: "mark", levels: d.levels, mode: markMode(phase))
            let markWidth = VoiceMark.width(height: 20, pose: pose)
            r.mark.frame = CGRect(x: Self.paddingLeft, y: midY - 10, width: markWidth, height: 20)
            VoiceMark.apply(pose, height: 20, animator: animator, key: "mark", dot: r.dot, bars: r.bars,
                            ink: tokens.pillText, live: tokens.live)
            let x = Self.paddingLeft + markWidth + Self.gap
            switch phase {
            case .preparing, .listening:
                listening(r, d, x: x, midY: midY, now: now)
            default:
                transcribing(r, d, x: x, midY: midY, now: now)
            }
        case "done":
            outcome(r, d, midY: midY)
        case "failed":
            failure(r, d, midY: midY)
        case "note":
            note(r, d, midY: midY)
        case "learned":
            learnedRow(r, midY: midY, size: size)
        case "cancelled":
            let circle = CGRect(x: Self.paddingLeft, y: midY - Self.outcomeCircle / 2,
                                width: Self.outcomeCircle, height: Self.outcomeCircle)
            r.circle(circle, color: tokens.pillText.withAlphaComponent(0.2))
            r.symbol("xmark", size: 9, weight: .bold, color: .white, in: circle)
            r.title.update(DictationCopy.cancelled, bodyFont, tokens.pillMuted,
                           at: CGPoint(x: circle.maxX + Self.gap, y: midY), height: Self.lineHeight)
        default:
            break
        }
    }

    /// 文字区现在多宽（还没出字时是提示的宽度）。
    private func liveSlotWidth(_ d: DictationState, phase: DictationPhase) -> Double {
        let text = Self.lineText(d)
        if (phase == .preparing || phase == .listening) && text.isEmpty {
            return widen(d.sessionID, hintWidth(d))
        }
        let shown = text.isEmpty ? DictationCopy.transcribing : text
        let full = shapedWidth(String(shown.suffix(Self.previewRunes)), bodyFont) + 1
        let room = widen(d.sessionID, Self.slotStep * ((full + Self.slotHeadroom) / Self.slotStep).rounded(.up))
        return animator.value("draft.width") ?? room
    }

    /// 把 session 的文字区撑宽到 w（最宽 slotMax），返回它的宽度。
    private func widen(_ session: String, _ w: Double) -> Double {
        if session != slotSession {
            slotSession = session
            slot = 0
        }
        slot = max(slot, min(Self.slotMax, w))
        return slot
    }

    /// 键帽（kit.Kbd）：高 20，至少和高一样宽，左右留 4。
    private func keycapWidth(_ d: DictationState) -> Double {
        let icon = Self.legendSymbol(d.keyLegend) != nil
            ? 13.0 : width(d.keyLegend, NSFont.systemFont(ofSize: 12, weight: .medium))
        return max(20, icon + 8)
    }

    private func hintText(_ d: DictationState) -> String {
        d.holding ? DictationCopy.releaseHint : DictationCopy.finishHint
    }

    private func hintWidth(_ d: DictationState) -> Double {
        keycapWidth(d) + 6 + width(hintText(d), captionFont)
    }

    /// 键帽上画哪个系统图标（fn 是地球，⌥、⌘ 是它们的符号）。
    static func legendSymbol(_ legend: String) -> String? {
        switch legend {
        case "fn": "globe"
        case "⌥": "option"
        case "⌘": "command"
        default: nil
        }
    }

    /// 说话时：有草稿显示草稿，还没有就显示怎么结束（一个键帽和几个字，照豆包的「松手结束」）。
    private func listening(_ r: RowLayers, _ d: DictationState, x: Double, midY: Double, now: Date) {
        let spoken = Self.lineText(d)
        if !spoken.isEmpty {
            hintShown = false
            r.hint.opacity = 0
            let frame = typing.update(session: d.sessionID, text: spoken, final: !d.final.isEmpty, now: now)
            draft(r, d.sessionID, frame, muted: 0, x: x, midY: midY, now: now)
            return
        }
        r.draftClip.opacity = 0
        if !hintShown {
            // 提示进场：往下 4 pt、透明，弹到原位
            hintShown = true
            animator.set("hint.presence", 0)
        }
        let p = animator.animate("hint.presence", to: 1, VoiceStyle.pop)
        r.hint.opacity = Float(clamp01(p))
        r.hint.frame = CGRect(x: x, y: midY - 11 + lerp(4, 0, p), width: hintWidth(d), height: 22)
        let capWidth = keycapWidth(d)
        let cap = CGRect(x: 0, y: 1, width: capWidth, height: 20)
        r.keycap.frame = cap
        r.keycap.cornerRadius = VoiceStyle.radiusSM
        r.keycap.backgroundColor = tokens.pillBorder.cgColor
        if let symbol = Self.legendSymbol(d.keyLegend) {
            r.keycapIcon.setSymbol(symbol, size: 11, weight: .medium, color: tokens.pillMuted, scale: r.scale)
            r.keycapIcon.frame = cap
        }
        r.hintText.update(hintText(d), captionFont, tokens.pillMuted, at: CGPoint(x: capWidth + 6, y: 11), height: 22)
    }

    /// 识别结束：剩下的草稿按最快的速度放完，颜色变暗。
    private func transcribing(_ r: RowLayers, _ d: DictationState, x: Double, midY: Double, now: Date) {
        r.hint.opacity = 0
        var frame = Typewriter.Frame(text: DictationCopy.transcribing)
        let spoken = Self.lineText(d)
        if !spoken.isEmpty {
            frame = typing.update(session: d.sessionID, text: spoken, final: true, now: now)
        }
        draft(r, d.sessionID, frame, muted: 1, x: x, midY: midY, now: now)
    }

    /// 草稿那一行显示的文字：换行换成空格。草稿只有一行，换行照画会画成第二行、叠在下面
    /// （微信体验渠道的草稿分段带换行，2026-11-14）。插入的文字不变
    static func lineText(_ d: DictationState) -> String {
        Dictation.text(d).replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    /// 草稿：一行里显示流式文字的结尾，文字区按需撑宽。比文字区最宽时还宽，就整行往左滑，让结尾一直看得见，
    /// 从左边出去的字渐隐。改字的过渡（Typewriter）：淡入的字按 alpha，中间插进来的字宽度从 0 撑开，
    /// 删掉的字原地淡出再收拢，换掉的字叠在新字上淡出；宽度用字距（kern）收放，整行交给系统一次排版、一次画完，
    /// 位置和宽度都出自同一次排版，不会对不上。muted：0 是正文色，1 是次要色。
    private func draft(_ r: RowLayers, _ session: String, _ frame: Typewriter.Frame, muted: Double, x: Double, midY: Double,
                       now: Date) {
        r.draftClip.opacity = 1
        // 说完时文字变暗：渐变，不是一下切过去
        let dim = animator.animate("draft.color", to: muted, Self.glide)
        // pillMuted 就是 pillText 的 62%，按 dim 在两者之间插透明度（blended 会丢掉透明度）
        let ink = tokens.pillText.withAlphaComponent(lerp(1, tokens.pillMuted.alphaComponent, dim))
        let chars = Array(frame.text)
        let window = max(0, chars.count - Self.drawRunes)
        let shiftNow = animator.value("draft.shift") ?? 0

        /// 排一行：先把要画的字（含正在消失的）排成一串；滑出左边看不见的过渡直接用结束时的样子
        func items(settledBefore cutoff: Double?) -> [(character: Character, alpha: Double, width: Double, text: Bool)] {
            var list: [(character: Character, alpha: Double, width: Double, text: Bool)] = []
            var x = 0.0
            let ghosts = Dictionary(grouping: frame.ghosts.filter { $0.index >= window }, by: \.index)
            for index in window..<(chars.count + 1) {
                let settled = cutoff.map { x < $0 } ?? false
                for ghost in ghosts[index] ?? [] where !settled {
                    list.append((ghost.character, ghost.alpha, ghost.width, false))
                }
                if index == chars.count { break }
                list.append((chars[index], settled ? 1 : frame.alpha[index] ?? 1, settled ? 1 : frame.widths[index] ?? 1, true))
                x += advance(chars[index])
            }
            return list
        }
        /// 排成一行：宽度不满的字用字距收。字占多宽要看前后的字（全角逗号单独 7 点，夹在汉字中间 14 点；
        /// 中英文之间系统还会加间距），所以先不收排一次，量出每个字实际占的宽度再收
        func compose(_ list: [(character: Character, alpha: Double, width: Double, text: Bool)]) -> (NSAttributedString, [Int]) {
            func attributed(_ kerns: [Double]) -> (NSMutableAttributedString, [Int], [Int]) {
                let line = NSMutableAttributedString()
                var textOffsets: [Int] = []
                var itemOffsets: [Int] = []
                for (k, item) in list.enumerated() {
                    if item.text { textOffsets.append(line.length) }
                    itemOffsets.append(line.length)
                    var attributes: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: ink.withAlphaComponent(item.alpha)]
                    if kerns[k] != 0 { attributes[.kern] = kerns[k] }
                    line.append(NSAttributedString(string: String(item.character), attributes: attributes))
                }
                textOffsets.append(line.length)
                itemOffsets.append(line.length)
                return (line, textOffsets, itemOffsets)
            }
            var kerns = [Double](repeating: 0, count: list.count)
            var (line, textOffsets, itemOffsets) = attributed(kerns)
            if list.contains(where: { $0.width < 1 }) {
                let measured = CTLineCreateWithAttributedString(line)
                for (k, item) in list.enumerated() where item.width < 1 {
                    let occupied = Double(CTLineGetOffsetForStringIndex(measured, itemOffsets[k + 1], nil)
                        - CTLineGetOffsetForStringIndex(measured, itemOffsets[k], nil))
                    kerns[k] = -(1 - item.width) * occupied
                }
                (line, textOffsets, itemOffsets) = attributed(kerns)
            }
            return (line, textOffsets)
        }
        var (line, offsets) = compose(items(settledBefore: nil))
        if shiftNow > 0, !frame.ghosts.isEmpty || !frame.widths.isEmpty { (line, offsets) = compose(items(settledBefore: shiftNow)) }
        let ctLine = CTLineCreateWithAttributedString(line)
        let full = Double(CTLineGetTypographicBounds(ctLine, nil, nil, nil)) + 1
        let room = widen(session, Self.slotStep * ((full + Self.slotHeadroom) / Self.slotStep).rounded(.up))
        let hidden = max(0, full - room)
        /// 第 index 个字（整段文字里的位置）在这一行里的横坐标
        func position(_ index: Int) -> Double? {
            guard index >= window, index - window < offsets.count else { return nil }
            return Double(CTLineGetOffsetForStringIndex(ctLine, offsets[index - window], nil))
        }
        // 改了已经显示的字：左边第一个看得见的字钉住不动——它在新文字里挪了多少，滑动就跟着挪多少。
        // 改的地方在它左边（滑出去看不见了），看得见的字全都不动；改的地方在它右边，它左边本来就不动，
        // 右边的交给过渡和弹簧。（原来按「第一个改的地方」判断，左边看不见的地方和结尾同时改时，
        // 把结尾的宽度变化也算进滑动，看得见的字一下跳一个字，2026-11-14 录屏）
        if let last = drawnDraft, last.session == session, frame.text != last.text, !frame.text.hasPrefix(last.text) {
            if let moved = frame.moved,
               let anchor = last.xs.keys.sorted().first(where: { (last.xs[$0] ?? 0) - last.shift >= 0 }),
               anchor < moved.count, let oldX = last.xs[anchor], let newX = position(moved[anchor]) {
                animator.offset("draft.shift", by: newX - oldX)
            }
            let common = zip(frame.text, last.text).prefix { $0 == $1 }.count
            let changeVisible = (position(common) ?? -Double.infinity) - (animator.value("draft.shift") ?? 0) >= 0
            if changeVisible, frame.text.count < last.text.count {
                // 看得见的结尾变短了：滑动先停住（右边暂时空着、截掉的字在淡出）
                shiftHold = (now.addingTimeInterval(Self.shrinkHold), max(shiftHold?.value ?? 0, last.hidden),
                             max(shiftHold?.length ?? 0, last.text.count))
            }
        }
        if drawnDraft?.session != session { shiftHold = nil }
        // 到时间了、或者字数长回来了，就不停了。不按宽度判断：截掉的字刚开始淡出时还占着宽度；行尾的全角标点
        // 系统会压成半个字宽，收拢时加了字距就不压了，宽度反而先涨一点（2026-11-14 回放），按宽度会一停就松
        // 时间到了但结尾正在打回来（还有没打出来的字）：等打回来再说，免得先往右滑一点又被新字推回去
        if let hold = shiftHold, (now >= hold.until && (frame.backlog == 0 || frame.text.count + frame.backlog < hold.length))
            || frame.text.count >= hold.length { shiftHold = nil }
        let target = max(hidden, shiftHold?.value ?? 0)
        let lineWidth = animator.animate("draft.width", to: room, Self.glide)
        let shift = max(animator.animate("draft.shift", to: target, Self.glide), hidden - Self.maxLag)
        var xs: [Int: Double] = [:]
        for index in window..<chars.count { xs[index] = position(index) }
        drawnDraft = (session, frame.text, hidden, xs, shift)
        r.draftClip.frame = CGRect(x: x, y: midY - Self.lineHeight / 2, width: lineWidth, height: Self.lineHeight)
        r.draftText.update(line, at: CGPoint(x: -shift, y: Self.lineHeight / 2), width: full + Self.edgeFade,
                           height: Self.lineHeight)
        // 从左边出去的字渐隐：越靠左边界越淡（capsule.go 逐字算的 edge，这里用渐变遮罩画出同样的效果）
        let edgeAlpha = max(0.01, 1 - min(1, shift / Self.edgeFade))
        r.draftFade.frame = r.draftClip.bounds
        r.draftFade.colors = [NSColor.black.withAlphaComponent(edgeAlpha).cgColor, NSColor.black.cgColor]
        r.draftFade.locations = [0, NSNumber(value: min(1, Self.edgeFade / max(lineWidth, 1)))]
    }

    /// 完成：绿色圆底，白色对勾 60 ms 后用 320 ms 画出来，旁边「已插入」。
    private func outcome(_ r: RowLayers, _ d: DictationState, midY: Double) {
        let circle = CGRect(x: Self.paddingLeft, y: midY - Self.outcomeCircle / 2,
                            width: Self.outcomeCircle, height: Self.outcomeCircle)
        r.circle(circle, color: tokens.success)
        let drawn = animator.keyframes("check", run: run(d.sessionID), delay: 0.06,
                                       [(0, 0, Ease.linear), (0.32, 1, Ease.easeOut)])
        let path = CGMutablePath()
        path.move(to: CGPoint(x: circle.minX + 5, y: circle.minY + 9.5))
        path.addLine(to: CGPoint(x: circle.minX + 8, y: circle.minY + 12.5))
        path.addLine(to: CGPoint(x: circle.minX + 13.5, y: circle.minY + 6))
        r.check.frame = r.container.bounds
        r.check.path = path
        r.check.strokeColor = tokens.onFill.cgColor
        r.check.fillColor = nil
        r.check.lineWidth = 2
        r.check.lineCap = .round
        r.check.lineJoin = .round
        r.check.strokeEnd = drawn
        r.title.update(d.outcome, bodyMedium, tokens.pillText,
                       at: CGPoint(x: circle.maxX + Self.gap, y: midY), height: Self.lineHeight)
    }

    /// 失败：红色实心圆里白色的「!」，抖一下；旁边标题和下一步。
    private func failure(_ r: RowLayers, _ d: DictationState, midY: Double) {
        let notice = d.failure ?? DictationCopy.generic
        let shake = animator.keyframes("shake", run: run(d.sessionID), [
            (0, 0, Ease.linear), (0.06, -3, Ease.linear), (0.14, 3, Ease.linear),
            (0.22, -1.5, Ease.linear), (0.30, 0, Ease.easeOut),
        ])
        let twoLines = notice.hint != nil
        let size = twoLines ? Self.noticeCircle : Self.outcomeCircle
        let left = twoLines ? Self.noticePaddingLeft : Self.paddingLeft
        let gap = twoLines ? Self.noticeGap : Self.gap
        let circle = CGRect(x: left + shake, y: midY - size / 2, width: size, height: size)
        r.circle(circle, color: tokens.live)
        r.symbol("exclamationmark", size: twoLines ? 12 : 10, weight: .heavy, color: .white, in: circle)
        let x = left + size + gap
        if let hint = notice.hint {
            let titleHeight = 17.0
            let hintHeight = 15.0
            let top = midY - (titleHeight + Self.noticeLineGap + hintHeight) / 2
            r.title.update(notice.title, bodyMedium, tokens.pillText,
                           at: CGPoint(x: x, y: top + titleHeight / 2), height: titleHeight)
            r.detail.update(hint, captionFont, tokens.pillMuted,
                            at: CGPoint(x: x, y: top + titleHeight + Self.noticeLineGap + hintHeight / 2), height: hintHeight)
        } else {
            r.title.update(notice.title, bodyMedium, tokens.pillText, at: CGPoint(x: x, y: midY), height: Self.lineHeight)
        }
    }

    /// 云端润色没成功（polishNote）：ⓘ、标题和下一步，文字已经用本机整理的上屏了。云端识别改用本机时也是这样。
    private func note(_ r: RowLayers, _ d: DictationState, midY: Double) {
        let notice = d.polishNote ?? DictationCopy.generic
        let icon = CGRect(x: Self.noticePaddingLeft, y: midY - Self.noticeCircle / 2, width: Self.noticeCircle, height: Self.noticeCircle)
        r.symbol("info.circle", size: 16, weight: .regular, color: tokens.pillMuted, in: icon)
        let x = icon.maxX + Self.noticeGap
        if let hint = notice.hint {
            let titleHeight = 17.0
            let hintHeight = 15.0
            let top = midY - (titleHeight + Self.noticeLineGap + hintHeight) / 2
            r.title.update(notice.title, bodyMedium, tokens.pillText, at: CGPoint(x: x, y: top + titleHeight / 2), height: titleHeight)
            r.detail.update(hint, captionFont, tokens.pillMuted,
                            at: CGPoint(x: x, y: top + titleHeight + Self.noticeLineGap + hintHeight / 2), height: hintHeight)
        } else {
            r.title.update(notice.title, bodyMedium, tokens.pillText, at: CGPoint(x: x, y: midY), height: Self.lineHeight)
        }
    }

    // MARK: - 小工具

    /// 以 center 为原点缩放、再往下移 dy。
    private func scaleAround(_ center: CGPoint, _ s: Double, dy: Double) -> CATransform3D {
        var t = CATransform3DMakeTranslation(0, dy, 0)
        t = CATransform3DTranslate(t, center.x, center.y, 0)
        t = CATransform3DScale(t, s, s, 1)
        return CATransform3DTranslate(t, -center.x, -center.y, 0)
    }

    private func width(_ string: String, _ font: NSFont) -> Double {
        (string as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    }

    /// 整串排出来的宽度
    private func shapedWidth(_ string: String, _ font: NSFont) -> Double {
        guard !string.isEmpty else { return 0 }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [.font: font]))
        return CTLineGetTypographicBounds(line, nil, nil, nil)
    }

    /// 单个字的宽度（缓存）
    private func advance(_ ch: Character) -> Double {
        if let w = advances[ch] { return w }
        let w = shapedWidth(String(ch), bodyFont)
        advances[ch] = w
        return w
    }

    /// 会话号变成关键帧的 run：结果的动画每次语音只放一次
    private func run(_ session: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in session.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}

// MARK: - 一行的图层

/// 一行内容用到的图层。不同的行用到其中不同的几个。
@MainActor
private final class RowLayers {
    let scale: CGFloat
    let container = CALayer()
    // 说话时
    let mark = CALayer()
    let dot = CALayer()
    let bars = (0..<5).map { _ in CALayer() }
    let hint = CALayer()
    let keycap = CALayer()
    let keycapIcon = ImageLayer()
    let hintText = TextLayer()
    let draftClip = CALayer()
    let draftFade = CAGradientLayer()
    let draftText = TextLayer()
    // 结果、提示
    let circleLayer = CALayer()
    let symbolLayer = ImageLayer()
    let check = CAShapeLayer()
    let title = TextLayer()
    let detail = TextLayer()
    // 已记住
    let pairClip = CALayer()
    let pairText = TextLayer()
    let undoButton = CALayer()
    let undoText = TextLayer()

    init(scale: CGFloat) {
        self.scale = scale
        mark.addSublayer(dot)
        bars.forEach(mark.addSublayer)
        hint.addSublayer(keycap)
        hint.addSublayer(keycapIcon)
        hint.addSublayer(hintText)
        draftClip.masksToBounds = true
        draftFade.startPoint = CGPoint(x: 0, y: 0.5)
        draftFade.endPoint = CGPoint(x: 1, y: 0.5)
        draftClip.mask = draftFade
        draftClip.addSublayer(draftText)
        pairClip.masksToBounds = true
        pairClip.addSublayer(pairText)
        undoButton.addSublayer(undoText)
        for layer in [mark, hint, draftClip, circleLayer, symbolLayer, check, title, detail, pairClip, undoButton] as [CALayer] {
            container.addSublayer(layer)
        }
        for layer in [hintText, draftText, title, detail, keycapIcon, symbolLayer, pairText, undoText] as [CALayer] {
            layer.contentsScale = scale
        }
        hint.opacity = 0
        draftClip.opacity = 0
    }

    func circle(_ rect: CGRect, color: NSColor) {
        circleLayer.frame = rect
        circleLayer.cornerRadius = rect.width / 2
        circleLayer.backgroundColor = color.cgColor
    }

    func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, in rect: CGRect) {
        symbolLayer.setSymbol(name, size: size, weight: weight, color: color, scale: scale)
        symbolLayer.frame = rect
    }
}

/// 画一行文字的图层：内容变了才重画。
private final class TextLayer: CALayer {
    private var text = NSAttributedString()

    override init() {
        super.init()
        needsDisplayOnBoundsChange = true
    }

    /// 不要系统的隐式动画。逐帧刷新时关了动画（step 里的 CATransaction），可文字是之后画的，
    /// 换内容时系统照样加 0.25 秒交叉淡化：位置又同时在动，新旧两行错开叠在一起（2026-11-14 录屏看到的「重叠」）
    override func action(forKey event: String) -> CAAction? { nil }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 一种字体、一种颜色：左边在 point.x，竖直中心在 point.y。
    func update(_ string: String, _ font: NSFont, _ color: NSColor, at point: CGPoint, height: CGFloat) {
        let text = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
        let width = ceil(text.size().width) + 2
        update(text, at: point, width: width, height: height)
    }

    func update(_ text: NSAttributedString, at point: CGPoint, width: CGFloat, height: CGFloat) {
        let frame = CGRect(x: point.x, y: point.y - height / 2, width: width, height: height)
        if self.frame != frame { self.frame = frame }
        if !self.text.isEqual(to: text) {
            self.text = text
            // 测试读画了什么（CapsulePlaybackTests）
            setValue(text.string, forKey: "debugText")
            setNeedsDisplay()
        }
    }

    override func draw(in ctx: CGContext) {
        guard text.length > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        // 父图层翻转过（y 往下），这里也按 y 往下画
        if !contentsAreFlipped() {
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        let font = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: 13)
        let lineHeight = font.ascender - font.descender
        text.draw(at: CGPoint(x: 0, y: (bounds.height - lineHeight) / 2))
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// 放一个系统图标的图层：图标变了才重新生成。
private final class ImageLayer: CALayer {
    private var key = ""

    override init() {
        super.init()
        contentsGravity = .center
    }

    /// 不要系统的隐式动画（同 TextLayer）
    override func action(forKey event: String) -> CAAction? { nil }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setSymbol(_ name: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, scale: CGFloat) {
        let key = "\(name)|\(size)|\(weight.rawValue)|\(color.description)|\(scale)"
        guard key != self.key else { return }
        self.key = key
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
            .applying(.init(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        var rect = CGRect(origin: .zero, size: image.size)
        contents = image.cgImage(forProposedRect: &rect, context: nil,
                                 hints: [.ctm: AffineTransform(scale: scale)])
        contentsScale = scale
    }
}
