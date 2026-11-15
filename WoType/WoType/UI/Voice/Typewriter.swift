//
//  Typewriter.swift
//  WoType
//
//  移植自 Arion apps/desktop/ui/entities/dictation/typewriter.go@d2108fe（AGPL-3.0-only），逐行翻成 Swift。
//
//  识别结果不是整段跳出来，而是按稳定、好读的速度一个字一个字打出来（Arion 照豆包的 ASRTypeWriter）。
//  弹簧式的节奏：没显示出来的字积得越多打得越快，追上了就放慢。识别会改已经显示的字（分段精修、
//  松开后的润色、还在变的尾巴），这一行不会往回缩，只有新字是打出来的；改过的结果比已显示的短，就截到它。
//
//  改已经显示的字时都有过渡（WoType 加的，2026-11-14 用户说「抖动、重叠」，定了用动画、不加颜色）：
//  逐字对齐（realign）；中间插进来的字淡入、宽度从 0 撑开；删掉的字原地淡出、再收拢；换掉的字新旧交叉淡化。
//

import Foundation

struct Typewriter {

    /// 弹簧围绕的积压字数
    static let balance: Double = 6
    /// 积压正好是 balance 时的节奏；每多（少）一个字，节奏快（慢）这么多比例
    static let interval: Double = 0.045
    static let elastic: Double = 0.25
    /// 节奏的上下限。识别结束以后按最快的节奏把剩下的放完，最终文字不会等动画太久
    static let minInterval: Double = 0.012
    static let maxInterval: Double = 0.090
    /// 新字从 fadeFrom 淡到不透明的时间：短而不完全的淡入，像墨水落定，不像闪烁
    static let fadeIn: Double = 0.150
    static let fadeFrom: Double = 0.35
    /// 中间插进来的字，宽度从 0 撑开用多久
    static let grow: Double = 0.160
    /// 删掉的字淡出用多久；淡出一半以后开始收拢，收拢用多久
    static let fadeOut: Double = 0.120
    static let collapse: Double = 0.160

    /// 这一帧要画的
    struct Frame {
        var text: String
        /// 还在淡入的字：在 text 里的位置 → 不透明度
        var alpha: [Int: Double] = [:]
        /// 中间插进来、还在撑开的字：位置 → 宽度（0 到 1）
        var widths: [Int: Double] = [:]
        /// 删掉、换掉，还在淡出的字
        var ghosts: [Ghost] = []
        /// 这一帧刚对齐过（识别改了已经显示的字）：旧文字里的位置 → 新文字里的位置
        var moved: [Int]?
        /// 还有几个字没打出来
        var backlog = 0
        /// 还要不要下一帧
        var animating = false
    }

    /// 一个正在消失的字：画在 text 的第 index 个字前面
    struct Ghost: Equatable {
        var index: Int
        var character: Character
        var alpha: Double
        /// 还占多宽（0 到 1）。换掉的字一开始就是 0：叠在新字上淡出
        var width: Double
    }

    private var session = ""
    private var target: [Character] = []
    private var shown: Double = 0
    /// 每个已显示的字出现的时间（淡入用）
    private var at: [Date] = []
    /// 中间插进来的字开始撑开的时间（打在结尾的字是 nil）
    private var grows: [Date?] = []
    /// 正在消失的字：位置、字、开始的时间、是不是换掉的
    private var removed: [(index: Int, character: Character, at: Date, replaced: Bool)] = []
    private var last = Date.distantPast
    /// 上一次对齐的位置对照（交给下一帧）
    private var justMoved: [Int]?

    /// 走到 now，朝 session 的 text 打字。final：识别已经结束，剩下的按最快的节奏放完。
    mutating func update(session: String, text: String, final: Bool, now: Date) -> Frame {
        if session != self.session {
            self = Typewriter()
            self.session = session
            last = now
        }
        let target = Array(text)
        if target != self.target {
            realign(to: target, now: now)
        }
        self.target = target
        var elapsed = now.timeIntervalSince(last)
        if elapsed < 0 || elapsed > 0.25 {
            // 卡住的帧、第一帧：只走一帧的量，不跳
            elapsed = 0.016
        }
        last = now
        let backlog = Double(target.count) - shown
        var pace = Self.minInterval
        if !final {
            let scale = max(0.1, 1 + Self.elastic * (backlog - Self.balance))
            pace = min(Self.maxInterval, max(Self.minInterval, Self.interval / scale))
        }
        shown = min(Double(target.count), shown + elapsed / pace)
        while at.count < Int(shown) {
            at.append(now)
            grows.append(nil)
        }
        let count = Int(shown)
        var frame = Frame(text: String(target[0..<count]), moved: justMoved, backlog: target.count - count,
                          animating: count < target.count)
        justMoved = nil
        for i in 0..<count {
            let age = now.timeIntervalSince(at[i])
            if age < Self.fadeIn {
                frame.alpha[i] = Self.fadeFrom + (1 - Self.fadeFrom) * age / Self.fadeIn
                frame.animating = true
            }
            if let started = grows[i] {
                let p = now.timeIntervalSince(started) / Self.grow
                if p < 1 {
                    frame.widths[i] = Self.easeOut(p)
                    frame.animating = true
                } else {
                    grows[i] = nil
                }
            }
        }
        removed.removeAll { now.timeIntervalSince($0.at) >= Self.fadeOut / 2 + Self.collapse }
        for item in removed {
            let age = now.timeIntervalSince(item.at)
            let alpha = max(0, 1 - age / Self.fadeOut)
            let width = item.replaced ? 0 : 1 - Self.easeOut(max(0, age - Self.fadeOut / 2) / Self.collapse)
            frame.ghosts.append(Ghost(index: min(item.index, count), character: item.character, alpha: alpha, width: width))
            frame.animating = true
        }
        return frame
    }

    /// 文字改了（WoType 加的，Arion 只按位置截）：已经显示的那部分对到新文字上。
    /// 云端识别常在已经显示的字中间补标点、换写法（「第一段我们」→「第一段，我们」）。只按位置算的话，
    /// 中间多一个字，结尾已经显示的字就少一个、重打一遍，整行先往右跳再滑回来（2026-11-14 用户说「抖动」）。
    /// 现在逐字对：相同的照样算已显示；新插进来的标点、空格算已显示，淡入、宽度撑开；删掉的标点、空格原地淡出再收拢；
    /// 原地换掉的字新字淡入、旧字叠在上面淡出。新文字比已显示的短就截到它。
    private mutating func realign(to new: [Character], now: Date) {
        let old = target
        let count = min(Int(shown), old.count)
        var common = 0
        while common < count && common < new.count && old[common] == new[common] { common += 1 }
        guard common < count else { return }
        var times = Array(at.prefix(common))
        var growing = Array(grows.prefix(common))
        // 旧位置 → 新位置（正在消失的字跟着挪）
        var moved = Array(0...count)
        var gone: [(index: Int, character: Character, at: Date, replaced: Bool)] = []
        var i = common, j = common
        while i < count && j < new.count {
            moved[i] = j
            if old[i] == new[j] {
                times.append(at[i]); growing.append(grows[i]); i += 1; j += 1
            } else if Self.isSeparator(new[j]) && !Self.isSeparator(old[i]) {
                times.append(now); growing.append(now); j += 1
            } else if Self.isSeparator(old[i]) && !Self.isSeparator(new[j]) {
                gone.append((j, old[i], now, false)); i += 1
            } else {
                gone.append((j, old[i], now, true))
                times.append(now); growing.append(nil); i += 1; j += 1
            }
        }
        // 没走到的旧字（新文字短了，结尾被截掉）：在结尾淡出、收拢，不是一下没了
        //（xAI 结尾常先截短再补回来，一下没了整行就往右跳一个字，2026-11-14 录屏）
        for k in i..<count { gone.append((j, old[k], now, false)) }
        for k in i...count { moved[k] = j }
        removed = removed.map { item in
            var item = item
            if item.index >= common { item.index = moved[min(item.index, count)] }
            return item
        } + gone
        shown = min(Double(new.count), Double(j) + (shown - Double(Int(shown))))
        at = times
        grows = growing
        justMoved = moved
    }

    private static func easeOut(_ t: Double) -> Double {
        let t = min(1, max(0, t))
        return 1 - (1 - t) * (1 - t) * (1 - t)
    }

    /// 标点、空白（补上、删掉的多半是这些）
    static func isSeparator(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy {
            CharacterSet.punctuationCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }
}
