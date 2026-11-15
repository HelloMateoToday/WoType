//
//  TypewriterTests.swift
//  WoTypeTests
//
//  浮窗打字机：识别改了已经显示的字时，已显示的部分对到新文字上，不缩回去重打（2026-11-14 用户说「抖动」）。
//

import Foundation
import Testing
@testable import WoType

struct TypewriterTests {

    /// 一直走到打完（或 max 秒）
    func settle(_ typing: inout Typewriter, _ text: String, from start: Date, seconds: Double = 3) -> (Typewriter.Frame, Date) {
        var now = start
        var frame = typing.update(session: "s", text: text, final: false, now: now)
        while frame.animating && now.timeIntervalSince(start) < seconds {
            now = now.addingTimeInterval(1.0 / 60)
            frame = typing.update(session: "s", text: text, final: false, now: now)
        }
        return (frame, now)
    }

    @Test func insertedPunctuationKeepsShownText() {
        var typing = Typewriter()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let (shown, now) = settle(&typing, "第一段我们先回顾", from: start)
        #expect(shown.text == "第一段我们先回顾")
        // 中间补逗号（云端识别常见）：已显示的八个字都还在，逗号算已显示、从现在淡入；结尾不缩
        let next = typing.update(session: "s", text: "第一段，我们先回顾一下", final: false, now: now.addingTimeInterval(1.0 / 60))
        #expect(next.text.hasPrefix("第一段，我们先回顾"))
        // 淡入的只有逗号和结尾新打的字，「们先回顾」不重新淡入
        let comma = 3
        #expect(next.alpha[comma] != nil)
        #expect(next.alpha.keys.allSatisfy { $0 == comma || $0 >= 9 })
        // 逗号的宽度从 0 撑开，过一会儿撑满
        #expect((next.widths[comma] ?? 1) < 0.5)
        let later = typing.update(session: "s", text: "第一段，我们先回顾一下", final: false, now: now.addingTimeInterval(0.5))
        #expect(later.widths[comma] == nil)
    }

    @Test func replacedCharactersStayInPlace() {
        var typing = Typewriter()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let (_, now) = settle(&typing, "明天下午三点开会", from: start)
        // 原地换写法（三 → 3）：字数不变；新字淡入，旧字叠在上面淡出（不占宽度）
        let next = typing.update(session: "s", text: "明天下午3点开会", final: false, now: now.addingTimeInterval(1.0 / 60))
        #expect(next.text == "明天下午3点开会")
        #expect(next.alpha.keys.sorted() == [4])
        #expect(next.ghosts.count == 1)
        #expect(next.ghosts.first?.character == "三" && next.ghosts.first?.index == 4 && next.ghosts.first?.width == 0)
        let later = typing.update(session: "s", text: "明天下午3点开会", final: false, now: now.addingTimeInterval(0.5))
        #expect(later.ghosts.isEmpty && later.alpha.isEmpty)
    }

    @Test func removedPunctuationAndShorterTextTruncate() {
        var typing = Typewriter()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let (_, now) = settle(&typing, "第三段，下周的重点", from: start)
        // 删掉中间的逗号：后面的字照样显示；逗号原地淡出，过一会儿收拢、没了
        let next = typing.update(session: "s", text: "第三段下周的重点", final: false, now: now.addingTimeInterval(1.0 / 60))
        #expect(next.text == "第三段下周的重点")
        #expect(next.ghosts.count == 1)
        #expect(next.ghosts.first?.character == "，" && next.ghosts.first?.index == 3)
        #expect((next.ghosts.first?.width ?? 0) > 0.99 && (next.ghosts.first?.alpha ?? 0) > 0.8)
        let fading = typing.update(session: "s", text: "第三段下周的重点", final: false, now: now.addingTimeInterval(0.15))
        #expect((fading.ghosts.first?.alpha ?? 1) < 0.1 && (fading.ghosts.first?.width ?? 0) < 1)
        let gone = typing.update(session: "s", text: "第三段下周的重点", final: false, now: now.addingTimeInterval(0.4))
        #expect(gone.ghosts.isEmpty)
        // 改得比已显示的短：截到它（还在消失的逗号跟着挪到结尾以内）
        let shorter = typing.update(session: "s", text: "第三段", final: false, now: now.addingTimeInterval(2.0 / 60))
        #expect(shorter.text == "第三段")
        #expect(shorter.ghosts.allSatisfy { $0.index <= 3 })
    }

    @Test func separatorsAreRecognized() {
        #expect(Typewriter.isSeparator("，"))
        #expect(Typewriter.isSeparator("。"))
        #expect(Typewriter.isSeparator(" "))
        #expect(Typewriter.isSeparator("\n"))
        #expect(!Typewriter.isSeparator("我"))
        #expect(!Typewriter.isSeparator("3"))
    }
}
