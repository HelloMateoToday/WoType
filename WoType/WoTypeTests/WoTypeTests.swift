//
//  WoTypeTests.swift
//  WoTypeTests
//
//  Swift 外壳的单元测试。拼音的交互逻辑在水杉里（docs/12）和万象方案里（librime，docs/22），
//  润色规则用 cargo test 测。
//

import Carbon.HIToolbox
import Cocoa
import FreeTranslate
import Testing
@testable import WoType

struct WoTypeTests {

    @Test func msimeHostIsLinked() {
        // 水杉的宿主层链在 libwotype_core.a 里；ABI 主版本变了要对照 msime_client.h 改 MsimeSession
        #expect(msime_client_abi_version() == 3)
    }

    @MainActor @Test func wanxiangTypesPinyin() async throws {
        // 万象（librime，docs/22）：Frameworks 里的 librime 载入得了，App 包里预编译的万象方案用得上，
        // 按键进去、librime 的状态转成 Snapshot。不按空格、不选词：上屏会让 librime 把词学进用户目录
        let engine = RimeEngine.shared
        engine.start()
        for _ in 0..<300 where !engine.ready {
            try await Task.sleep(for: .milliseconds(100))
        }
        let session = try #require(engine.session(idle: true))
        _ = session.reset(commitPending: false)
        var snapshot: Snapshot?
        for letter in "nihao".unicodeScalars {
            snapshot = session.key(letter.value, modifiers: 0, preceding: 0)
        }
        let typing = try #require(snapshot)
        #expect(typing.handled && typing.mode == .list)
        #expect(typing.candidates.first?.text == "你好", "首选：\(typing.candidates.prefix(5).map(\.text))")
        #expect(typing.highlight == typing.candidates.first?.text && typing.highlightComplete,
                "首选是整句：译文能 ⏎ 上屏")
        // 打到一半切英文：字母原样上屏
        _ = session.reset(commitPending: false)
        for letter in "abc".unicodeScalars { _ = session.key(letter.value, modifiers: 0, preceding: 0) }
        #expect(session.commitRaw()?.commit == "abc")
        // 候选翻译的译文上屏：撤掉组字，送出译文
        for letter in "ni".unicodeScalars { _ = session.key(letter.value, modifiers: 0, preceding: 0) }
        let translated = try #require(session.commitText("you"))
        #expect(translated.commit == "you" && translated.mode == .idle)
    }

    @MainActor @Test func wanxiangRowFitsWidth() async throws {
        // 万象一行按候选窗宽度放、最多 9 个（不是 librime 的一页 6 个）；Page Down 翻到下一行，Page Up 翻回来。不选词
        let engine = RimeEngine.shared
        engine.start()
        for _ in 0..<300 where !engine.ready {
            try await Task.sleep(for: .milliseconds(100))
        }
        let session = try #require(engine.session(idle: true))
        _ = session.reset(commitPending: false)
        defer { _ = session.reset(commitPending: false) }
        var snapshot: Snapshot?
        for letter in "shi".unicodeScalars { snapshot = session.key(letter.value, modifiers: 0, preceding: 0) }
        let first = try #require(snapshot)
        #expect(first.candidates.count > 6 && first.candidates.count <= 9, "单字一行放得下 7～9 个：\(first.candidates.count)")
        #expect(first.first == 0 && first.hasNext)
        let next = try #require(session.key(UInt32(WOTYPE_KEY_PAGE_DOWN), modifiers: 0, preceding: 0))
        #expect(next.first == first.candidates.count && next.cursor == 0 && next.hasPrev)
        let pageDown = try #require(session.key(UInt32(WOTYPE_KEY_PAGE_DOWN), modifiers: 0, preceding: 0))
        #expect(pageDown.first == next.first + next.candidates.count)
        _ = session.key(UInt32(WOTYPE_KEY_PAGE_UP), modifiers: 0, preceding: 0)
        let back = try #require(session.key(UInt32(WOTYPE_KEY_PAGE_UP), modifiers: 0, preceding: 0))
        #expect(back.first == 0 && back.candidates.map(\.text) == first.candidates.map(\.text))
    }

    /// - = + 照微信输入法（2026-11-15 实测，docs/22）：没打开过网格时 - 和 + 进原样输入，= 展开并跳到第二行，
    /// 网格里 = - 上下移、第一行按 - 收起，打开过网格以后收起时按 - 没反应。两个引擎同一套。原样上屏不学词
    @MainActor private func checkMinusEqualLikeWeChat(_ session: PinyinSession) throws {
        func type(_ text: String) -> Snapshot? {
            var last: Snapshot?
            for letter in text.unicodeScalars { last = session.key(letter.value, modifiers: 0, preceding: 0) }
            return last
        }
        func press(_ key: Int, shift: Bool = false) -> Snapshot? {
            session.key(UInt32(key), modifiers: shift ? UInt32(WOTYPE_MOD_SHIFT) : 0, preceding: 0)
        }
        _ = session.reset(commitPending: false)
        defer { _ = session.reset(commitPending: false) }

        // 刚打完拼音按 -：原样输入，候选只有这一串、不画序号；= 也接着打进去；退格删回去就回到原来的候选
        let list = try #require(type("women"))
        let minus = try #require(type("-"))
        #expect(minus.handled && minus.remaining == "women-" && minus.candidates.map(\.text) == ["women-"] && !minus.numbered)
        #expect(type("=")?.remaining == "women-=")
        #expect(press(WOTYPE_KEY_BACKSPACE)?.remaining == "women-")
        let back = try #require(press(WOTYPE_KEY_BACKSPACE))
        #expect(back.numbered && back.candidates.first?.text == list.candidates.first?.text, "回到候选：\(back.candidates.prefix(3).map(\.text))")
        // + 也进原样输入，回车原样上屏
        let plus = try #require(session.key(0x2B, modifiers: UInt32(WOTYPE_MOD_SHIFT), preceding: 0))
        #expect(plus.remaining == "women+")
        let committed = try #require(press(WOTYPE_KEY_RETURN))
        #expect(committed.commit == "women+" && committed.mode == .idle)

        // = 展开并跳到第二行；再 = 第三行；- 回第二行、第一行；第一行再 - 收起；收起后 - 没反应
        _ = type("shi")
        let row2 = try #require(type("="))
        #expect(row2.mode == .grid && row2.rows.count > 2 && row2.cursor >= row2.rows[0], "第二行：\(row2.cursor) \(row2.rows)")
        let row3 = try #require(type("="))
        #expect(row3.cursor >= row3.rows[0] + row3.rows[1])
        #expect(type("-").map { $0.cursor >= $0.rows[0] && $0.cursor < $0.rows[0] + $0.rows[1] } == true)
        #expect(type("-").map { $0.mode == .grid && $0.cursor < $0.rows[0] } == true)
        #expect(type("-")?.mode == .list)
        let still = try #require(type("-"))
        #expect(still.mode == .list && still.numbered && still.candidates.count > 1, "打开过网格后 - 不进原样输入")
    }

    /// 一行最后一个候选再按 →：展开网格，高亮留在它上面（照微信），算打开过网格（- 不进原样输入）；
    /// 网格里 ← → 跨行连着走。两个引擎同一套。不选词
    @MainActor private func checkRightArrowExpands(_ session: PinyinSession) throws {
        func press(_ key: Int) -> Snapshot? { session.key(UInt32(key), modifiers: 0, preceding: 0) }
        _ = session.reset(commitPending: false)
        defer { _ = session.reset(commitPending: false) }
        var list: Snapshot?
        for letter in "shi".unicodeScalars { list = session.key(letter.value, modifiers: 0, preceding: 0) }
        let row = try #require(list)
        #expect(row.mode == .list && row.first == 0 && row.hasNext)
        // → 走到这一行最后一个，候选窗还是这一行
        var last = row
        for _ in 1..<row.candidates.count { last = try #require(press(WOTYPE_KEY_RIGHT)) }
        #expect(last.mode == .list && last.cursor == row.candidates.count - 1 && last.candidates.map(\.text) == row.candidates.map(\.text))
        // 再按 →：展开，高亮还是那一个
        let grid = try #require(press(WOTYPE_KEY_RIGHT))
        #expect(grid.mode == .grid && grid.first + grid.cursor == row.candidates.count - 1, "高亮在第 \(grid.first + grid.cursor) 个")
        #expect(grid.candidates[grid.cursor].text == row.candidates.last?.text)
        // 网格里 → 一个一个往后（跨过行尾），← 一个一个往前
        var position = grid.first + grid.cursor
        for _ in 0..<8 {
            let next = try #require(press(WOTYPE_KEY_RIGHT))
            #expect(next.mode == .grid && next.first + next.cursor == position + 1)
            position = next.first + next.cursor
        }
        for _ in 0..<8 {
            let previous = try #require(press(WOTYPE_KEY_LEFT))
            #expect(previous.first + previous.cursor == position - 1)
            position = previous.first + previous.cursor
        }
        // 算打开过网格：- 是往上移，不进原样输入
        let minus = try #require(session.key(0x2D, modifiers: 0, preceding: 0))
        #expect(!minus.remaining.hasSuffix("-") && minus.numbered)
    }

    @MainActor @Test func wanxiangRightArrowExpands() async throws {
        let engine = RimeEngine.shared
        engine.start()
        for _ in 0..<300 where !engine.ready {
            try await Task.sleep(for: .milliseconds(100))
        }
        try checkRightArrowExpands(try #require(engine.session(idle: true)))
    }

    @MainActor @Test func msimeRightArrowExpands() async throws {
        let host = MsimeHost.shared
        host.prepareInBackground()
        for _ in 0..<600 where host.currentSession(idle: true) == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        try checkRightArrowExpands(try #require(host.currentSession(idle: true)))
    }

    @MainActor @Test func wanxiangMinusEqualLikeWeChat() async throws {
        let engine = RimeEngine.shared
        engine.start()
        for _ in 0..<300 where !engine.ready {
            try await Task.sleep(for: .milliseconds(100))
        }
        try checkMinusEqualLikeWeChat(try #require(engine.session(idle: true)))
    }

    @MainActor @Test func msimeMinusEqualLikeWeChat() async throws {
        let host = MsimeHost.shared
        host.prepareInBackground()
        for _ in 0..<600 where host.currentSession(idle: true) == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        try checkMinusEqualLikeWeChat(try #require(host.currentSession(idle: true)))
    }

    @MainActor @Test func wanxiangArrowsMoveCandidates() async throws {
        // 横排时 → 选下一个候选（光标在拼音末尾），← 回来；在首选上按 ← 移拼音里的光标。不选词
        let engine = RimeEngine.shared
        engine.start()
        for _ in 0..<300 where !engine.ready {
            try await Task.sleep(for: .milliseconds(100))
        }
        let session = try #require(engine.session(idle: true))
        _ = session.reset(commitPending: false)
        defer { _ = session.reset(commitPending: false) }
        for letter in "women".unicodeScalars { _ = session.key(letter.value, modifiers: 0, preceding: 0) }
        let right = try #require(session.key(UInt32(WOTYPE_KEY_RIGHT), modifiers: 0, preceding: 0))
        #expect(right.handled && right.cursor == 1, "→ 后高亮第 2 个：\(right.cursor)")
        let left = try #require(session.key(UInt32(WOTYPE_KEY_LEFT), modifiers: 0, preceding: 0))
        #expect(left.cursor == 0)
        // 首选上按 ←：交给 librime 移光标，光标不在末尾了
        let caret = try #require(session.key(UInt32(WOTYPE_KEY_LEFT), modifiers: 0, preceding: 0))
        #expect(caret.handled && caret.caret != nil, "光标移进拼音：\(String(describing: caret.caret))")
        // 光标不在末尾时 → 先移光标
        let back = try #require(session.key(UInt32(WOTYPE_KEY_RIGHT), modifiers: 0, preceding: 0))
        #expect(back.cursor == 0 && back.caret == nil)
    }

    @MainActor @Test func wanxiangGridExpands() async throws {
        // 万象（librime）的展开候选：候选窗出 ∨，展开后一屏几行、比一页多，↓ 换行、第一行按 ↑ 收起。不选词
        let engine = RimeEngine.shared
        engine.start()
        for _ in 0..<300 where !engine.ready {
            try await Task.sleep(for: .milliseconds(100))
        }
        let session = try #require(engine.session(idle: true))
        _ = session.reset(commitPending: false)
        defer { _ = session.reset(commitPending: false) }
        var snapshot: Snapshot?
        for letter in "shi".unicodeScalars {
            snapshot = session.key(letter.value, modifiers: 0, preceding: 0)
        }
        let list = try #require(snapshot)
        #expect(list.mode == .list && list.total > list.candidates.count, "有 ∨：\(list.total) > \(list.candidates.count)")
        let grid = try #require(session.toggleGrid())
        #expect(grid.mode == .grid && grid.rows.count > 1 && grid.candidates.count > list.candidates.count)
        #expect(grid.rows.reduce(0, +) == grid.candidates.count && grid.spans.count == grid.candidates.count)
        #expect(grid.candidates.first?.text == list.candidates.first?.text && grid.cursor == 0)
        // ↓ 到第二行
        let down = try #require(session.key(UInt32(WOTYPE_KEY_DOWN), modifiers: 0, preceding: 0))
        #expect(down.mode == .grid && down.cursor >= grid.rows[0], "高亮在第二行：\(down.cursor)")
        #expect(down.highlight == down.candidates[down.cursor].text)
        // ↑ 回第一行，再 ↑ 收起
        _ = session.key(UInt32(WOTYPE_KEY_UP), modifiers: 0, preceding: 0)
        let collapsed = try #require(session.key(UInt32(WOTYPE_KEY_UP), modifiers: 0, preceding: 0))
        #expect(collapsed.mode == .list)
    }

    @MainActor @Test func rimeCustomPhrases() throws {
        // 自定义词（全拼、简拼）和快捷短语写成万象的自定义短语；${cursor} 记下光标位置，反斜杠、换行转义
        let custom = RimeCustom(Config(), words: [CustomWord(word: "张叁丰", pinyin: "zhang san feng"), CustomWord(word: "叁", pinyin: "san")],
                                quickPhrases: [QuickPhrase(code: "dz", text: "地址：${cursor}号"), QuickPhrase(code: "hh", text: "a\\b\nc")])
        let dict = try #require(custom.files()["custom_phrase.dict.yaml"] ?? nil)
        #expect(dict.contains("张叁丰\tzhangsanfeng\t100\n") && dict.contains("张叁丰\tzsf\t100\n"))
        #expect(dict.contains("叁\tsan\t100\n") && !dict.contains("叁\ts\t"), "一个字的不加简拼")
        #expect(dict.contains("地址：号\tdz\t100\n") && custom.cursors["地址：号"] == 1)
        #expect(dict.contains("a[[\\]]b\\nc\thh\t100\n"))
        #expect(RimeCustom.expandCursor("$${cursor}x${cursor}y") == ("${cursor}xy", 1))
        #expect(RimeCustom.expandCursor("没有标记") == ("没有标记", nil))
    }

    @MainActor @Test func wanxiangPunctuationAndSpacing() async throws {
        // 符号补全（照微信输入法：一对都上屏、光标退回中间）、数字后的 . 原样、数字后的 , 不挂进组字区、
        // 汉字和英文数字之间补空格。不上屏拼音，不往用户目录学词；改的设置测完改回去
        let engine = RimeEngine.shared
        engine.start()
        for _ in 0..<300 where !engine.ready {
            try await Task.sleep(for: .milliseconds(100))
        }
        let session = try #require(engine.session(idle: true))
        let saved = Settings.shared.config
        Settings.shared.update { $0.autoPair = true; $0.asciiPunctAfterDigit = true; $0.spaceCJKLatin = true }
        defer {
            Settings.shared.update { $0.autoPair = saved.autoPair; $0.asciiPunctAfterDigit = saved.asciiPunctAfterDigit; $0.spaceCJKLatin = saved.spaceCJKLatin }
            _ = session.reset(commitPending: false)
        }
        _ = session.reset(commitPending: false)
        let shift = UInt32(WOTYPE_MOD_SHIFT)
        // 照微信输入法：没在组字时按 ( 一对都上屏，光标退回中间；打拼音到一半按 ( 是「候选 + 左括号」，不补
        let open = try #require(session.key(0x28, modifiers: shift, preceding: 0))
        #expect(open.commit == "（）" && open.caretBack == 1 && open.mode == .idle, "\(open.commit) | \(open.caretBack)")
        let quote = try #require(session.key(0x22, modifiers: shift, preceding: 0))
        #expect(quote.commit == "“”" && quote.caretBack == 1, "\(quote.commit)")
        for letter in "ni".unicodeScalars { _ = session.key(letter.value, modifiers: 0, preceding: 0) }
        let composing = try #require(session.key(0x28, modifiers: shift, preceding: 0))
        #expect(composing.commit.hasSuffix("（") && !composing.commit.contains("）") && composing.caretBack == 0,
                "\(composing.commit)")
        _ = session.reset(commitPending: false)
        // 数字后的 , 不再被万象当数字分隔符挂进组字区（1,ni → ,ni），出中文的（InputController 再按下一个键换英文）
        session.setContext("1")
        let comma = try #require(session.key(0x2C, modifiers: 0, preceding: 0x31))
        #expect(comma.commit == "，" && comma.mode == .idle, "\(comma.commit) | \(comma.mode)")
        // 数字后的 . 交给应用（原样），汉字后的数字由会话上屏、补空格
        session.setContext("3")
        #expect(session.key(0x2E, modifiers: 0, preceding: 0x33)?.handled == false)
        session.setContext("中")
        let digit = try #require(session.key(0x35, modifiers: 0, preceding: 0))
        #expect(digit.handled && digit.commit == "5")
        #expect(session.spacedCommit("5", preceding: 0x4E2D, application: "") == " 5")
        #expect(session.spacedCommit("你好", preceding: 0x61, application: "") == " 你好")
        #expect(session.spacedCommit("你好", preceding: 0x4E2D, application: "") == "你好")
    }

    @MainActor @Test func wanxiangLoneLetterDigits() async throws {
        // 只打了一个 v、i、u 时：候选不画序号，数字原样接在后面（v5.0，照微信输入法）；普通拼音后的数字照旧选词
        let engine = RimeEngine.shared
        engine.start()
        for _ in 0..<300 where !engine.ready { try await Task.sleep(for: .milliseconds(100)) }
        let session = try #require(engine.session(idle: true))
        _ = session.reset(commitPending: false)
        defer { _ = session.reset(commitPending: false) }
        let v = try #require(session.key(0x76, modifiers: 0, preceding: 0))
        #expect(!v.candidates.isEmpty && !v.numbered, "\(v.candidates.map(\.text))")
        var last: Snapshot?
        for key in "5.0 ".unicodeScalars { last = session.key(key.value, modifiers: 0, preceding: 0) }
        #expect(last?.commit == "v5.0", "\(last?.commit ?? "nil")")
        for key in "ni".unicodeScalars { _ = session.key(key.value, modifiers: 0, preceding: 0) }
        let picked = try #require(session.key(0x33, modifiers: 0, preceding: 0))
        #expect(!picked.commit.isEmpty && !picked.commit.contains("3"), "ni3 选第 3 个候选：\(picked.commit)")
    }

    @Test func rawInputCompletesMail() {
        // @ 后补全邮箱后缀（照微信）：没打后缀时列全部 15 个；打了开头时对得上的、加 .com 的、原样的；已经有 . 时不加 .com
        var input = RawInput(base: "ab", symbol: "@")
        #expect(input.candidates.count == 15 && input.candidates.first == "ab@qq.com")
        #expect(input.key(0x71, modifiers: 0) == .update)
        #expect(input.candidates == ["ab@qq.com", "ab@q.com", "ab@q"])
        #expect(input.key(UInt32(WOTYPE_KEY_RIGHT), modifiers: 0) == .update && input.cursor == 1)
        #expect(input.key(0x20, modifiers: 0) == .commit("ab@q.com"))
        #expect(input.key(UInt32(WOTYPE_KEY_TAB), modifiers: 0) == .finish("ab@q.com"))
        #expect(RawInput.candidates(for: "ab@qq.com") == ["ab@qq.com"])
        #expect(RawInput.candidates(for: "www.") == ["www."])
        // 退格删回到进来之前就退出
        var dot = RawInput(base: "abc", symbol: ".")
        #expect(dot.key(UInt32(WOTYPE_KEY_BACKSPACE), modifiers: 0) == .exit)
    }

    @MainActor @Test func rawInputRowFitsPanel() {
        // @ 后的十几个邮箱按候选窗宽度分行，只显示高亮那一行：候选窗和平时一样宽，← → 走到头翻行；点哪个上屏哪个
        let view = CandidateView()
        view.update(Snapshot(handled: true, commit: "", mode: .list, selected: "", remaining: "nihao", horizontal: true,
                             columns: 1, first: 0, cursor: 0, total: 1, hasPrev: false, hasNext: false,
                             candidates: [Snapshot.Item(text: "你好")], caretBack: 0))
        let normal = view.contentSize.width
        var input = RawInput(base: "hello", symbol: "@")
        var shown: [String] = []
        for i in input.candidates.indices {
            let snapshot = input.snapshot(handled: true)
            view.update(snapshot)
            #expect(view.contentSize.width == normal, "第 \(i) 个：\(view.contentSize.width)")
            #expect(snapshot.first + snapshot.cursor == i)
            if snapshot.cursor == 0 { shown += snapshot.candidates.map(\.text) }
            _ = input.key(UInt32(WOTYPE_KEY_RIGHT), modifiers: 0)
        }
        #expect(shown == input.candidates)
        var click = RawInput(base: "hello", symbol: "@")
        click.highlight(2)
        #expect(click.key(0x20, modifiers: 0) == .commit("hello@126.com"))
    }

    /// 打拼音途中按 . @ 进原样输入，@ 后面补全邮箱（两个引擎同一套）。原样上屏不学词
    @MainActor private func checkDotAtRawInput(_ session: PinyinSession) throws {
        func type(_ text: String) -> Snapshot? {
            var last: Snapshot?
            for letter in text.unicodeScalars { last = session.key(letter.value, modifiers: 0, preceding: 0) }
            return last
        }
        _ = session.reset(commitPending: false)
        defer { _ = session.reset(commitPending: false) }
        _ = type("abc")
        #expect(type(".")?.remaining == "abc.")
        #expect(type("com")?.candidates.map(\.text) == ["abc.com"])
        #expect(session.key(UInt32(WOTYPE_KEY_RETURN), modifiers: 0, preceding: 0)?.commit == "abc.com")
        _ = type("ab")
        let at = try #require(session.key(0x40, modifiers: UInt32(WOTYPE_MOD_SHIFT), preceding: 0))
        #expect(at.remaining == "ab@" && at.candidates.first?.text == "ab@qq.com" && !at.numbered,
                "\(at.handled) [\(at.remaining)] \(at.candidates.prefix(3).map(\.text))")
        #expect(type("q")?.candidates.map(\.text) == ["ab@qq.com", "ab@q.com", "ab@q"])
        #expect(session.key(UInt32(WOTYPE_KEY_RIGHT), modifiers: 0, preceding: 0)?.cursor == 1)
        #expect(type(" ")?.commit == "ab@q.com")
    }

    @MainActor @Test func msimeDotAtRawInput() async throws {
        let host = MsimeHost.shared
        host.prepareInBackground()
        for _ in 0..<600 where host.currentSession(idle: true) == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        try checkDotAtRawInput(try #require(host.currentSession(idle: true)))
    }

    @MainActor @Test func wanxiangKeysLikeMsime() async throws {
        // 照水杉：Tab 先上屏打了一半的再交给应用；带 ⌃ ⌥ ⌘ 的键交给应用；大写锁定时大写字母交给应用；
        // 照旧万象：打拼音途中按 . @ 进原样输入；数字后的 / 原样。原样上屏不学词
        let engine = RimeEngine.shared
        engine.start()
        for _ in 0..<300 where !engine.ready {
            try await Task.sleep(for: .milliseconds(100))
        }
        let session = try #require(engine.session(idle: true))
        _ = session.reset(commitPending: false)
        defer { _ = session.reset(commitPending: false) }
        func type(_ text: String) -> Snapshot? {
            var last: Snapshot?
            for letter in text.unicodeScalars { last = session.key(letter.value, modifiers: 0, preceding: 0) }
            return last
        }
        _ = type("nihao")
        let tab = try #require(session.key(UInt32(WOTYPE_KEY_TAB), modifiers: 0, preceding: 0))
        #expect(!tab.handled && tab.commit == "nihao" && tab.mode == .idle)
        _ = type("ni")
        let control = try #require(session.key(0x63, modifiers: UInt32(WOTYPE_MOD_CONTROL), preceding: 0))
        #expect(!control.handled && control.mode == .list && control.remaining.contains("ni"))
        _ = session.reset(commitPending: false)
        #expect(session.key(0x41, modifiers: UInt32(WOTYPE_MOD_CAPSLOCK), preceding: 0)?.handled == false)
        try checkDotAtRawInput(session)
        // 数字后的 / 交给应用（2024/1/1），不进万象的 / 功能
        let saved = Settings.shared.config.asciiPunctAfterDigit
        Settings.shared.update { $0.asciiPunctAfterDigit = true }
        defer { Settings.shared.update { $0.asciiPunctAfterDigit = saved } }
        session.setContext("2024")
        #expect(session.key(0x2F, modifiers: 0, preceding: 0x34)?.handled == false)
    }

    @MainActor @Test func wanxiangSlashCommands() async throws {
        // /sj：组字区后面有万象的提示（〔未时…〕），→ 照样移到下一个候选；电报符号（㍘ 是「0点」压成一个字）不显示。
        // / 只有一个候选：↓ 不展开（展开成网格候选窗会大一点，看起来抖一下）
        let engine = RimeEngine.shared
        engine.start()
        for _ in 0..<300 where !engine.ready { try await Task.sleep(for: .milliseconds(100)) }
        let session = try #require(engine.session(idle: true))
        _ = session.reset(commitPending: false)
        defer { _ = session.reset(commitPending: false) }
        var list: Snapshot?
        for letter in "/sj".unicodeScalars { list = session.key(letter.value, modifiers: 0, preceding: 0) }
        #expect(list?.cursor == 0)
        let right = try #require(session.key(UInt32(WOTYPE_KEY_RIGHT), modifiers: 0, preceding: 0))
        #expect(right.handled && right.cursor == 1)
        let grid = try #require(session.toggleGrid())
        #expect(!grid.candidates.contains { RimeSession.isTelegraphSymbol($0.text) }, "\(grid.candidates.map(\.text))")
        #expect(RimeSession.isTelegraphSymbol("㍘") && RimeSession.isTelegraphSymbol("㋀") && !RimeSession.isTelegraphSymbol("点"))
        _ = session.reset(commitPending: false)
        let slash = try #require(session.key(0x2F, modifiers: 0, preceding: 0))
        #expect(slash.mode == .list && slash.candidates.count == 1)
        let down = try #require(session.key(UInt32(WOTYPE_KEY_DOWN), modifiers: 0, preceding: 0))
        #expect(down.mode == .list, "只有一个候选时不展开")
    }

    @Test func appUpdaterComparesVersions() throws {
        // 检查更新：版本号一段一段按数字比；GitHub 的 tag 去掉开头的 v
        #expect(AppUpdater.isNewer("0.2.0", than: "0.1.0") && AppUpdater.isNewer("0.10.0", than: "0.9.1"))
        #expect(!AppUpdater.isNewer("0.1.0", than: "0.1.0") && !AppUpdater.isNewer("1.0", than: "1.0.0"))
        #expect(!AppUpdater.isNewer("0.1.0", than: "0.2.0") && AppUpdater.isNewer("1.0.1", than: "1.0"))
        let json = #"{"tag_name": "v0.2.0", "html_url": "https://github.com/HelloMateoToday/WoType/releases/tag/v0.2.0"}"#
        let release = try #require(AppUpdater.parseRelease(Data(json.utf8)))
        #expect(release.version == "0.2.0" && release.page.absoluteString.hasSuffix("/v0.2.0"))
        #expect(AppUpdater.parseRelease(Data(#"{"message": "Not Found"}"#.utf8)) == nil)
    }

    @MainActor @Test func rimeCustomFollowsSettings() throws {
        // 设置写成万象的补丁：模糊音在前、双拼方案、纠错；退格限制一直关；双拼时英文、混合编码、反查也跟着换
        var config = Config()
        config.wanxiangFuzzyRules = ["z=zh", "en=eng"]
        config.shuangpin = true
        config.shuangpinProfile = "xiaohe"
        let files = RimeCustom(config, words: [], quickPhrases: []).files()
        let main = try #require(files["wanxiang.custom.yaml"] ?? nil)
        #expect(main.contains("""
                      - wanxiang_algebra:/模糊音_z_zh
                      - wanxiang_algebra:/模糊音_en_eng
                      - wanxiang_algebra:/base/小鹤双拼
                      - wanxiang_algebra:/26jian
                """))
        #expect(main.contains("translator/enable_correction: false"))
        #expect(main.contains("super_processor/enable_backspace_limit: false"))
        // 标出纯学出来的词：过滤器和查系统词库的翻译器
        #expect(main.contains("    - lua_filter@*wotype_learned\n") && main.contains("wotype_system/enable_user_dict: false"))
        #expect((files["lua/wotype_learned.lua"] ?? nil)?.contains("local MARK = \"\(RimeCustom.learnedMark)\"") == true)
        #expect((files["wanxiang_english.custom.yaml"] ?? nil)?.contains("english/小鹤双拼") == true)
        // 全拼：只有主方案的补丁，别的文件（WoType 以前写过的）要删
        config.shuangpin = false
        let quanpin = RimeCustom(config, words: [], quickPhrases: []).files()
        #expect((quanpin["wanxiang.custom.yaml"] ?? nil)?.contains("base/全拼") == true)
        #expect(quanpin.keys.contains("wanxiang_english.custom.yaml") && quanpin["wanxiang_english.custom.yaml"]! == nil)
    }

    @Test func rimeKeysAreX11() {
        // WOTYPE_KEY_* 和修饰键换成 librime 认的 X11 keysym 和修饰位
        #expect(RimeSession.keysym(0x61) == 0x61)
        #expect(RimeSession.keysym(UInt32(WOTYPE_KEY_BACKSPACE)) == 0xFF08)
        #expect(RimeSession.keysym(UInt32(WOTYPE_KEY_RETURN)) == 0xFF0D)
        #expect(RimeSession.keysym(UInt32(WOTYPE_KEY_PAGE_DOWN)) == 0xFF56)
        #expect(RimeSession.keysym(0x4E2D) == 0x0100_4E2D)
        #expect(RimeSession.keysym(0x1F) == nil)
        #expect(RimeSession.mask(UInt32(WOTYPE_MOD_SHIFT | WOTYPE_MOD_CONTROL)) == (1 << 0 | 1 << 2))
        #expect(RimeSession.mask(UInt32(WOTYPE_MOD_COMMAND)) == 1 << 26)
    }

    @Test func fuzzyRulesAreKeptPerEngine() throws {
        // 水杉只留它支持的 11 条
        let old = #"{"fuzzyRules": ["z=zh", "g=k", "hui=fei", "an=ang"]}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(old.utf8))
        #expect(config.pinyinEngine == "msime")
        #expect(config.fuzzyRules == ["z=zh", "an=ang"] && config.wanxiangFuzzyRules.isEmpty)
        // 两个引擎各读各的；万象方案没有的（un=ong）去掉
        let split = #"{"fuzzyRules": ["c=ch"], "wanxiangFuzzyRules": ["r=y", "un=ong", "nonsense"], "pinyinEngine": "wanxiang"}"#
        let both = try JSONDecoder().decode(Config.self, from: Data(split.utf8))
        #expect(both.fuzzyRules == ["c=ch"] && both.wanxiangFuzzyRules == ["r=y"])
        #expect(both[keyPath: Config.fuzzyRulesKey(for: both.pinyinEngine)] == ["r=y"])
        #expect(FuzzyRule.wanxiangAll.count == 10 && FuzzyRule.all.count == 11)
        // 万象的每一条都对得上万象方案里的一组
        #expect(FuzzyRule.wanxiangAll.allSatisfy { RimeCustom.fuzzyNames[$0.id] != nil })
        // 水杉默认小模型
        #expect(config.msimeModel == "small")
    }

    @MainActor @Test func settingsSectionsAreTidy() {
        // 侧边栏的名字都是 4 个字（对齐）；每一页的每张卡片上面都有分组名称
        for section in SettingsSection.all {
            #expect(section.title.count == 4, "侧边栏「\(section.title)」不是 4 个字")
            // 语音页一建就去查语音模型的状态，要几十秒，只查名字
            guard section.id != "voice" else { continue }
            let items = section.makePage().build()
            for (i, item) in items.enumerated() where item is CardView {
                let titled = i > 0 && (items[i - 1] is NSTextField || items[i - 1] is SectionHeader)
                #expect(titled, "「\(section.title)」第 \(i + 1) 项是没有分组名称的卡片")
            }
        }
    }

    @Test func userDataLivesOutsideTheAppBundle() {
        let bundle = Bundle.main.bundleURL.path
        #expect(!Paths.userData.path.hasPrefix(bundle))
        #expect(!Paths.caches.path.hasPrefix(bundle))
        #expect(Paths.caches.path.hasSuffix("Library/Caches/WoType"))
    }

    @Test func functionKeysMapByKeyCode() {
        let enter = KeyMapper.map(keyCode: UInt16(kVK_Return), characters: "\r", charactersIgnoringModifiers: "\r", flags: [])
        #expect(enter?.key == UInt32(WOTYPE_KEY_RETURN))
        let down = KeyMapper.map(keyCode: UInt16(kVK_DownArrow), characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}", flags: [])
        #expect(down?.key == UInt32(WOTYPE_KEY_DOWN))
        let space = KeyMapper.map(keyCode: UInt16(kVK_Space), characters: " ", charactersIgnoringModifiers: " ", flags: [])
        #expect(space?.key == 0x20)
    }

    @Test func printableKeysUseTypedCharacter() {
        // Shift、大写锁定打出来的字符要原样交给会话
        let shifted = KeyMapper.map(keyCode: UInt16(kVK_ANSI_H), characters: "H", charactersIgnoringModifiers: "H", flags: [.shift])
        #expect(shifted == KeyMapper.Mapped(key: 0x48, modifiers: UInt32(WOTYPE_MOD_SHIFT)))
        let caps = KeyMapper.map(keyCode: UInt16(kVK_ANSI_A), characters: "A", charactersIgnoringModifiers: "a", flags: [.capsLock])
        #expect(caps == KeyMapper.Mapped(key: 0x41, modifiers: UInt32(WOTYPE_MOD_CAPSLOCK)))
        // ⌥ 打出特殊字符时按原来的键交给会话（会话会把带 ⌥ 的键交还给应用）
        let option = KeyMapper.map(keyCode: UInt16(kVK_ANSI_A), characters: "å", charactersIgnoringModifiers: "a", flags: [.option])
        #expect(option == KeyMapper.Mapped(key: 0x61, modifiers: UInt32(WOTYPE_MOD_OPTION)))
    }

    @Test func unknownKeysAreNotMapped() {
        #expect(KeyMapper.map(keyCode: UInt16(kVK_F1), characters: "\u{F704}", charactersIgnoringModifiers: "\u{F704}", flags: []) == nil)
    }

    @Test func configFillsMissingKeysWithDefaults() throws {
        // 老版本的配置、手改删掉的项：没写的用默认值，已经去掉的项（horizontal、pageSize、urlPunct）不影响读
        let json = #"{"horizontal": false, "pageSize": 20, "urlPunct": true, "voiceKey": "nonsense"}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(config.voiceKey == .rightCommand, "语音键默认右 ⌘（cec7988 起）")
        #expect(config.typoCorrection && config.emojiSuggest && config.fuzzyRules.isEmpty)
        #expect(config.showPinyinInPanel, "老配置里没有这一项：默认在候选窗显示拼音")
        #expect(config.asciiPunctAfterDigit, "老配置里没有这一项：默认数字后的句号用英文")
        #expect(config.slashDunhao, "/ 输入顿号默认开")
        #expect(!config.autoPair && !config.spaceCJKLatin, "自动补全、自动空格默认关")
        #expect(config.msimeModel == "small" && config.shuangpinProfile == "ziranma")
        #expect(!config.cloudCandidates, "云候选默认关：要联网，打开时还要确认")
        #expect(!config.chaizi && config.quickPhraseCandidates)
        #expect(!config.candidateTranslation, "候选翻译默认关：要联网")
        #expect(config.translationTarget == "en" && config.translationEngine == "auto")
        #expect(config.skin == .wechat, "皮肤默认微信")
        let unknownSkin = try JSONDecoder().decode(Config.self, from: Data(#"{"skin": "nonsense"}"#.utf8))
        #expect(unknownSkin.skin == .wechat, "不认识的皮肤用默认")
        let hidden = try JSONDecoder().decode(Config.self, from: Data(#"{"showPinyinInPanel": false}"#.utf8))
        #expect(!hidden.showPinyinInPanel)
    }

    @Test func customWordPinyinIsGuessedAndNormalized() throws {
        #expect(CustomWords.guessPinyin("字节跳动") == "zi jie tiao dong")
        #expect(CustomWords.normalizePinyin("  Zi'Jie  TIAO,dong ") == "zi'jie tiao dong")

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("wotype-custom-\(UUID()).tsv")
        defer { try? FileManager.default.removeItem(at: file) }
        try "# 注释\nzi jie tiao dong\t字节跳动\nbad line\n\nwo de you xiang\t我的邮箱\t100\n"
            .write(to: file, atomically: true, encoding: .utf8)
        #expect(CustomWords.load(from: file) == [
            CustomWord(word: "字节跳动", pinyin: "zi jie tiao dong"),
            CustomWord(word: "我的邮箱", pinyin: "wo de you xiang"),
        ])
    }

    @Test func oldFuzzySwitchBecomesDefaultRules() throws {
        let on = try JSONDecoder().decode(Config.self, from: Data(#"{"fuzzy": true}"#.utf8))
        #expect(on.fuzzyRules == FuzzyRule.defaults)
        let off = try JSONDecoder().decode(Config.self, from: Data(#"{"fuzzy": false}"#.utf8))
        #expect(off.fuzzyRules.isEmpty)
        // 新格式优先；不认识的规则丢掉
        let rules = try JSONDecoder().decode(Config.self, from: Data(#"{"fuzzy": true, "fuzzyRules": ["n=l", "x=y"]}"#.utf8))
        #expect(rules.fuzzyRules == ["n=l"])
        // 写回去只有新格式
        let json = String(decoding: try JSONEncoder().encode(rules), as: UTF8.self)
        #expect(json.contains("fuzzyRules") && !json.contains("\"fuzzy\""))
    }

    @Test func autoUpdateIsOffByDefault() throws {
        #expect(!Config().autoUpdateLexicon, "自动更新词库默认关")
        let on = try JSONDecoder().decode(Config.self, from: Data(#"{"autoUpdateLexicon": true}"#.utf8))
        #expect(on.autoUpdateLexicon)
    }

    @Test func singleShiftSurvivesStaleModifiers() {
        typealias C = InputController
        // 普通的单按
        #expect(C.shiftEdge(from: [], to: .shift) == .down(alone: true))
        #expect(C.shiftEdge(from: .shift, to: []) == .up)
        // ⌥空格 呼出启动器：Option 松开没收到，记着的还是 Option；接着按 Shift 也要算单按
        #expect(C.shiftEdge(from: .option, to: .shift) == .down(alone: true))
        // 按着别的键再按 Shift 不算单按；中途按了别的修饰键作废
        #expect(C.shiftEdge(from: .command, to: [.command, .shift]) == .down(alone: false))
        #expect(C.shiftEdge(from: .shift, to: [.shift, .command]) == .other)
        #expect(C.shiftEdge(from: [], to: .option) == .other)
        // 重复送来的事件（Chrome 网页输入框）
        #expect(C.shiftEdge(from: .shift, to: .shift) == .repeated)
        // 大写锁定亮着也算
        #expect(C.shiftEdge(from: .capsLock, to: [.capsLock, .shift]) == .down(alone: true))
    }

    @Test func everyFuzzyRuleIsKnownToMsime() {
        // 设置面板里的每条规则都要能换成水杉的名字（MsimeHost 写进水杉的偏好）
        #expect(FuzzyRule.all.allSatisfy { MsimeSettings.fuzzyRuleNames[$0.id] != nil })
        #expect(FuzzyRule.all.count == MsimeSettings.fuzzyRuleNames.count)
    }

    @MainActor @Test func candidatesWithoutGlyphsAreDetected() {
        // 常用字、繁体、emoji、中英混排都画得出来
        #expect(CandidateView.canDisplay("之前"))
        #expect(CandidateView.canDisplay("頭髮"))
        #expect(CandidateView.canDisplay("你好👋"))
        #expect(CandidateView.canDisplay("GitHub 仓库"))
        // 扩展 G 区（U+30000 起）macOS 自带字体没有：只能画成缺字方框
        #expect(!CandidateView.canDisplay("\u{30000}"))
        #expect(!CandidateView.canDisplay("之\u{30001}"))
    }

    @Test func singleControlTapTranslates() {
        typealias C = InputController
        var pressed = false
        // 单按：按下、松开
        #expect(!C.controlTapped(&pressed, from: [], to: .control))
        #expect(C.controlTapped(&pressed, from: .control, to: []))
        // 大写锁定亮着也算
        #expect(!C.controlTapped(&pressed, from: .capsLock, to: [.capsLock, .control]))
        #expect(C.controlTapped(&pressed, from: [.capsLock, .control], to: .capsLock))
        // ⌃⌘、按着 ⇧ 再按 ⌃：不算
        #expect(!C.controlTapped(&pressed, from: [], to: .control))
        #expect(!C.controlTapped(&pressed, from: .control, to: [.control, .command]))
        #expect(!C.controlTapped(&pressed, from: [.control, .command], to: .command))
        #expect(!C.controlTapped(&pressed, from: .shift, to: [.shift, .control]))
        #expect(!C.controlTapped(&pressed, from: [.shift, .control], to: .shift))
        // 中间按了别的键（⌃A）：handle 会把 pressed 清掉
        #expect(!C.controlTapped(&pressed, from: [], to: .control))
        pressed = false
        #expect(!C.controlTapped(&pressed, from: .control, to: []))
        // 重复送来的事件不影响
        #expect(!C.controlTapped(&pressed, from: [], to: .control))
        #expect(!C.controlTapped(&pressed, from: .control, to: .control))
        #expect(C.controlTapped(&pressed, from: .control, to: []))
    }

    @MainActor @Test func translationEnginesAndBar() {
        let ids = CandidateTranslator.engines.map(\.id)
        #expect(ids.first == "auto" && ids.count == 8)
        #expect(Set(ids) == ["auto", "microsoft", "google", "transmart", "volcengine", "youdao", "iciba", "bilibili"])
        // 有道、金山词霸只有中英；腾讯交互翻译不支持印地语
        #expect(CandidateTranslator.engine("youdao", supports: "en"))
        #expect(!CandidateTranslator.engine("youdao", supports: "es"))
        #expect(!CandidateTranslator.engine("transmart", supports: "hi"))
        #expect(CandidateTranslator.engine("microsoft", supports: "pt-BR"))
        #expect(CandidateTranslator.engine("auto", supports: "th"))
        // 只有整句、翻好了才能上屏
        typealias Bar = CandidateTranslator.Bar
        #expect(Bar(source: "我很赞同", complete: true, state: .done("I agree")).committable == "I agree")
        #expect(Bar(source: "我很", complete: false, state: .done("I")).committable == nil)
        #expect(Bar(source: "我很赞同", complete: true, state: .translating).committable == nil)
        #expect(Bar(source: "我很赞同", complete: true, state: .failed("超时")).committable == nil)
    }

    /// 划词翻译的智能方向（docs/16）：原文已经是目标语言就翻成简体中文，目标是简体中文时翻成英语。
    @MainActor @Test func selectionTranslationDirection() {
        typealias T = SelectionTranslator
        #expect(T.detect("今天天气不错，我们出去走走吧。")?.code == "zh-Hans")
        #expect(T.detect("我用 Swift 写代码")?.code == "zh-Hans")
        #expect(T.detect("The weather is nice today, let's go for a walk.")?.code == "en")
        #expect(T.detect("今日はいい天気ですね")?.code == "ja")
        #expect(T.detect("오늘 날씨가 좋네요")?.code == "ko")

        let english = Language("en"), chinese = Language("zh-Hans")
        #expect(T.direction(for: "今天天气不错", target: english, smart: true) == english)
        #expect(T.direction(for: "The weather is nice today.", target: english, smart: true) == chinese)
        #expect(T.direction(for: "The weather is nice today.", target: english, smart: false) == english)
        #expect(T.direction(for: "今天天气不错，我们出去走走吧。", target: chinese, smart: true) == english)
        #expect(T.direction(for: "今日はいい天気ですね", target: Language("ja"), smart: true) == chinese)
        // pt 和 pt-BR 算同一种
        #expect(T.direction(for: "Hoje o tempo está ótimo, vamos dar um passeio.", target: Language("pt-BR"), smart: true) == chinese)
    }
}
