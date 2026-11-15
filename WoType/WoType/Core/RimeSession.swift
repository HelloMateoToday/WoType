//
//  RimeSession.swift
//  WoType
//
//  万象（librime）的输入会话，docs/22。只在主线程用。
//  按键换成 X11 keysym 交给 process_key，交互照万象方案；上屏文字、组字区、候选从 librime 取出来转成 Snapshot。
//  WoType 自己的键（单按 Shift 切中英、⌃ 候选翻译、语音键）在 InputController 里先拦下了，到不了这里。
//

import Foundation
import os

final class RimeSession {

    private let api: UnsafeMutablePointer<RimeApi>
    private let id: RimeSessionId

    init?(api: UnsafeMutablePointer<RimeApi>, schema: String) {
        self.api = api
        id = api.pointee.create_session!()
        guard id != 0 else {
            Log.engine.error("librime 建不了会话")
            return nil
        }
        if api.pointee.select_schema!(id, schema) == 0 {
            Log.engine.error("librime 选不了方案 \(schema, privacy: .public)")
        }
    }

    deinit {
        _ = api.pointee.destroy_session!(id)
    }

    /// 不用重新部署的开关：繁体（万象的 s2s / s2t 一组）、候选里出表情
    func apply(_ config: Config) {
        api.pointee.set_option!(id, config.traditional ? "s2t" : "s2s", 1)
        api.pointee.set_option!(id, "emoji", config.emojiSuggest ? 1 : 0)
    }

    // MARK: - 按键

    /// X11 的修饰键位（librime 的 key_table.h）
    private enum Mask {
        static let shift: Int32 = 1 << 0
        static let control: Int32 = 1 << 2
        static let alt: Int32 = 1 << 3
        static let `super`: Int32 = 1 << 26
    }

    /// WOTYPE_KEY_* → X11 keysym；可打印字符的 keysym 就是 ASCII 码，其余字符是 0x01000000 + 码位
    private static let functionKeys: [UInt32: Int32] = [
        UInt32(WOTYPE_KEY_BACKSPACE): 0xFF08,
        UInt32(WOTYPE_KEY_TAB): 0xFF09,
        UInt32(WOTYPE_KEY_RETURN): 0xFF0D,
        UInt32(WOTYPE_KEY_ESCAPE): 0xFF1B,
        UInt32(WOTYPE_KEY_HOME): 0xFF50,
        UInt32(WOTYPE_KEY_LEFT): 0xFF51,
        UInt32(WOTYPE_KEY_UP): 0xFF52,
        UInt32(WOTYPE_KEY_RIGHT): 0xFF53,
        UInt32(WOTYPE_KEY_DOWN): 0xFF54,
        UInt32(WOTYPE_KEY_PAGE_UP): 0xFF55,
        UInt32(WOTYPE_KEY_PAGE_DOWN): 0xFF56,
        UInt32(WOTYPE_KEY_END): 0xFF57,
        UInt32(WOTYPE_KEY_DELETE): 0xFFFF,
    ]

    static func keysym(_ key: UInt32) -> Int32? {
        if let sym = functionKeys[key] { return sym }
        if key >= 0x20, key < 0x7F { return Int32(key) }
        if key >= 0xA0, key <= 0x10FFFF { return Int32(0x0100_0000 + key) }
        return nil
    }

    static func mask(_ modifiers: UInt32) -> Int32 {
        var mask: Int32 = 0
        if modifiers & UInt32(WOTYPE_MOD_SHIFT) != 0 { mask |= Mask.shift }
        // 大写锁定不交给 librime（它会把大写锁定当中英切换）：没在组字时 RimeSession 把大写字母交给应用
        if modifiers & UInt32(WOTYPE_MOD_CONTROL) != 0 { mask |= Mask.control }
        if modifiers & UInt32(WOTYPE_MOD_OPTION) != 0 { mask |= Mask.alt }
        if modifiers & UInt32(WOTYPE_MOD_COMMAND) != 0 { mask |= Mask.super }
        return mask
    }

    // MARK: - 快照

    /// librime 现在的状态转成 Snapshot：先取走要上屏的文字，再读组字区和这一页候选。
    /// extraCommit：WoType 自己要上屏的（原样输入、译文……）；pair：上屏文字过不过符号补全
    private func snapshot(handled: Bool, extraCommit: String = "", pair: Bool = true) -> Snapshot {
        var commit = extraCommit
        var rimeCommit = RimeCommit()
        rimeCommit.data_size = Int32(MemoryLayout<RimeCommit>.stride - MemoryLayout<Int32>.stride)
        if api.pointee.get_commit!(id, &rimeCommit) != 0 {
            if let text = rimeCommit.text { commit += String(cString: text) }
            _ = api.pointee.free_commit!(&rimeCommit)
        }
        // 万象在自定义短语的换行前加了零宽空格（照顾 Electron 应用），上屏不要它
        commit = commit.replacingOccurrences(of: "\u{200B}\n", with: "\n")
        // 带光标位置的快捷短语：上屏后光标退到标记处
        var caretBack = RimeEngine.shared.loadedCustom?.cursors.first { commit.hasSuffix($0.key) }?.value ?? 0
        if pair {
            let before = commit.utf16.count
            commit = pairing(commit)
            if caretBack > 0 { caretBack += commit.utf16.count - before }
        }
        return finish(body(handled: handled, commit: commit), caretBack: caretBack)
    }

    /// 补上光标后退、挂着的后半个（画在编辑区末尾）；只挂着后半个时候选窗还算开着
    private func finish(_ s: Snapshot, caretBack: Int) -> Snapshot {
        let tail = pendingClosing ?? ""
        var result = Snapshot(
            handled: s.handled, commit: s.commit, mode: s.mode == .idle && !tail.isEmpty ? .list : s.mode,
            selected: s.selected, remaining: s.remaining, horizontal: s.horizontal, columns: s.columns, first: s.first,
            cursor: s.cursor, total: s.total, hasPrev: s.hasPrev, hasNext: s.hasNext, candidates: s.candidates,
            caretBack: caretBack)
        result.tail = tail
        result.numbered = s.numbered
        result.caret = s.caret
        result.rows = s.rows
        result.spans = s.spans
        result.highlight = s.highlight
        result.highlightComplete = s.highlightComplete
        return result
    }

    /// 编辑区和候选（上屏文字已经处理好）
    private func body(handled: Bool, commit: String) -> Snapshot {
        if let raw { return raw.snapshot(handled: handled, commit: commit) }

        var context = RimeContext()
        context.data_size = Int32(MemoryLayout<RimeContext>.stride - MemoryLayout<Int32>.stride)
        guard api.pointee.get_context!(id, &context) != 0 else {
            endInput()
            return Self.idle(handled: handled, commit: commit)
        }
        defer { _ = api.pointee.free_context!(&context) }

        let composition = context.composition
        let menu = context.menu
        guard composition.length > 0 || menu.num_candidates > 0 else {
            endInput()
            return Self.idle(handled: handled, commit: commit)
        }

        // 组字区：sel_start 之前是已经选好的那段，之后是还没选的拼音；librime 给的位置都是 UTF-8 字节
        let preedit = composition.preedit.map { Array(UnsafeBufferPointer(start: UnsafeRawPointer($0).assumingMemoryBound(to: UInt8.self),
                                                                         count: strlen($0))) } ?? []
        let split = min(max(Int(composition.sel_start), 0), preedit.count)
        let selected = String(decoding: preedit[..<split], as: UTF8.self)
        let remaining = String(decoding: preedit[split...], as: UTF8.self)
        let cursor = Int(composition.cursor_pos)
        let caret: Int? = cursor >= split && cursor < preedit.count
            ? String(decoding: preedit[split..<cursor], as: UTF8.self).utf16.count : nil

        var candidates: [Snapshot.Item] = []
        for i in 0..<Int(menu.num_candidates) {
            guard let text = menu.candidates[i].text else { continue }
            candidates.append(Snapshot.Item(text: String(cString: text),
                                            learned: Self.isLearned(menu.candidates[i].comment)))
        }
        let highlighted = Int(menu.highlighted_candidate_index)
        let first = Int(menu.page_no * menu.page_size)
        let hasNext = menu.is_last_page == 0

        var result = Snapshot(
            handled: handled, commit: commit, mode: .list,
            selected: selected, remaining: remaining, horizontal: true,
            columns: max(candidates.count, 1), first: first, cursor: highlighted,
            // 后面还有就比这一页多：候选窗据此出 ∨
            total: first + candidates.count + (hasNext ? 1 : 0),
            hasPrev: menu.page_no > 0, hasNext: hasNext,
            candidates: candidates, caretBack: 0)
        result.caret = caret
        var highlightedText = candidates.indices.contains(highlighted) ? candidates[highlighted].text : nil
        if !expanded, !candidates.isEmpty {
            // 不用 librime 的一页 6 个：按候选窗宽度放，最多 9 个（照旧万象、水杉）
            refreshRow(highlighted: first + highlighted)
            if !row.isEmpty {
                result = Snapshot(
                    handled: handled, commit: commit, mode: .list,
                    selected: selected, remaining: remaining, horizontal: true,
                    columns: row.count, first: rowStart, cursor: rowCursor,
                    total: rowItems.count + (rowMore ? 1 : 0),
                    hasPrev: rowStart > 0, hasNext: rowStart + row.count < rowItems.count || rowMore,
                    candidates: row.map(\.item), caretBack: 0)
                result.caret = caret
                highlightedText = row[rowCursor].text
            }
        }
        if expanded, !candidates.isEmpty { refreshGrid(highlighted: first + highlighted) }
        if expanded, !candidates.isEmpty {
            let visible = gridVisible
            result = Snapshot(
                handled: handled, commit: commit, mode: .grid,
                selected: selected, remaining: remaining, horizontal: true,
                columns: visible.rows.max() ?? 1, first: visible.start, cursor: gridCursor - visible.start,
                total: gridItems.count + (gridMore ? 1 : 0),
                hasPrev: gridFirstRow > 0, hasNext: gridFirstRow + Self.gridRows < gridRowStarts.count || gridMore,
                candidates: visible.items.map(\.item), caretBack: 0)
            result.caret = caret
            result.rows = visible.rows
            result.spans = (visible.start..<visible.start + visible.items.count).map { gridSpans[$0].right - gridSpans[$0].left }
            highlightedText = gridItems[gridCursor].text
        } else {
            expanded = false
        }
        // 候选翻译翻「已经选好的那段 + 高亮的候选」；选了它后面还剩拼音（只用掉一部分）时译文先不让 ⏎ 上屏
        if let highlightedText {
            let text = selected + highlightedText
            result.highlight = text
            let preview = context.commit_text_preview.map { String(cString: $0) }
            result.highlightComplete = preview == text
        }
        return result
    }

    private static func idle(handled: Bool, commit: String) -> Snapshot {
        Snapshot(handled: handled, commit: commit, mode: .idle, selected: "", remaining: "", horizontal: true,
                 columns: 0, first: 0, cursor: 0, total: 0, hasPrev: false, hasNext: false, candidates: [], caretBack: 0)
    }

    // MARK: - 符号自动补全（照 MsimeSession，它照的水杉）

    /// 补全的成对符号（照水杉的 MSIMEPunctuationPairs）
    private static let pairs = [
        "（": "）", "【": "】", "《": "》", "“": "”", "‘": "’", "〈": "〉", "「": "」", "『": "』", "〖": "〗",
    ]
    /// 万象的引号一开一合交替；补全时每按一次都是新的一对，后半个改回前半个
    private static let reopenings = ["”": "“", "’": "‘", "」": "「", "』": "『"]
    /// 按哪个键会出这个后半个（跨过刚补上的后半个时用）
    private static let closingKeys: [UInt32: String] = [0x29: "）", 0x5D: "】", 0x3E: "》", 0x22: "”", 0x27: "’"]

    /// 补上还没送出的后半个：留在编辑区末尾、光标前面，下一次上屏时跟在后面一起送出
    private var pendingClosing: String?
    /// 刚随上屏送出的后半个：紧接着再按出它时跨过去
    private var autoClosed: String?
    /// 正在处理的标点键（看它决定补不补、引号要不要改回前半个）
    private var punctuationKey: UInt32?

    /// 上屏的文字过一遍补全：送出挂着的后半个，看这次是不是打开了新的一对
    private func pairing(_ commit: String) -> String {
        let pending = pendingClosing
        guard !commit.isEmpty else { return commit }
        guard Settings.shared.config.autoPair else {
            pendingClosing = nil
            return commit + (pending ?? "")
        }
        var text = commit
        // 组字中按标点上屏的是「候选 + 标点」（nihao( → 你好（）：只看最后一个字
        var mark = text
        if punctuationKey != nil, let last = text.last { mark = String(last) }
        var opened: String?
        if pending == nil {
            if punctuationKey == 0x22 || punctuationKey == 0x27, let opening = Self.reopenings[mark] {
                text = String(text.dropLast()) + opening
                mark = opening
            }
            opened = Self.pairs[mark]
        }
        if let pending {
            text += pending
            autoClosed = pending
        }
        pendingClosing = opened
        return text
    }

    /// 没在组字、只挂着后半个时 librime 交还给应用的键：可打印字符由这里上屏，后半个接着挂着；
    /// 退格交给应用删左半个，后半个也不要了；别的键（回车、方向键……）先把后半个送出再交给应用
    private func passWithPending(_ key: UInt32, modifiers: UInt32) -> Snapshot {
        guard pendingClosing != nil else { return snapshot(handled: false) }
        let plain = modifiers & UInt32(WOTYPE_MOD_CONTROL | WOTYPE_MOD_OPTION | WOTYPE_MOD_COMMAND) == 0
        if plain, key >= 0x20, key < 0x7F, let scalar = Unicode.Scalar(key) {
            return snapshot(handled: true, extraCommit: String(Character(scalar)), pair: false)
        }
        let pending = key == UInt32(WOTYPE_KEY_BACKSPACE) ? "" : pendingClosing ?? ""
        pendingClosing = nil
        return snapshot(handled: false, extraCommit: pending, pair: false)
    }

    /// 光标前的那个字（InputController 在新输入的第一个键前给的上文），只对紧接着的那一次按键有效
    private var contextBefore: Unicode.Scalar?

    /// 汉字（基本区、扩展 A 到 G、兼容区）
    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        (0x3400...0x9FFF).contains(scalar.value) || (0xF900...0xFAFF).contains(scalar.value)
            || (0x20000...0x3FFFF).contains(scalar.value)
    }

    /// 英文字母、数字
    static func isLatin(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar))
    }

    // MARK: - 这次输入的状态（照微信输入法的 - = 规则，docs/22）

    /// 原样输入（打拼音途中按 - 或 +），见 RawInput
    private var raw: RawInput?
    /// 这次输入用 = 或 ↓ 打开过网格：之后 - 是往上移（收起时没反应），不再进原样输入。输入结束才清掉
    private var navigated = false

    /// 这次输入结束了（上屏、清空）
    private func endInput() {
        expanded = false
        navigated = false
        raw = nil
    }

    /// 原样输入里的按键
    private func rawKey(_ key: UInt32, modifiers: UInt32) -> Snapshot? {
        guard var input = raw else { return nil }
        let action = input.key(key, modifiers: modifiers)
        raw = input
        switch action {
        case .update, .ignore:
            return snapshot(handled: true)
        case .passThrough:
            return snapshot(handled: false)
        case .commit(let text):
            raw = nil
            api.pointee.clear_composition!(id)
            return snapshot(handled: true, extraCommit: text)
        case .finish(let text):
            raw = nil
            api.pointee.clear_composition!(id)
            return snapshot(handled: false, extraCommit: text)
        case .cancel:
            raw = nil
            api.pointee.clear_composition!(id)
            return snapshot(handled: true)
        case .exit:
            raw = nil
            return snapshot(handled: true)
        }
    }

    /// 横排时按 = 或 ↓：展开，高亮跳到第二行同一列（照微信）。后面没有更多候选时不展开
    /// （只有一行也切成网格的话，候选窗样式一变大一点，看起来抖一下）
    private func expandDown() -> Snapshot? {
        guard let highlighted = highlightedIndex else { return nil }
        refreshRow(highlighted: highlighted)
        guard row.isEmpty || rowStart + row.count < rowItems.count || rowMore else { return snapshot(handled: true) }
        expanded = true
        navigated = true
        gridFirstRow = 0
        refreshGrid(highlighted: highlighted)
        guard expanded else { return snapshot(handled: true) }
        return moveGrid(toRow: gridRow(of: gridCursor) + 1)
    }

    /// 展开时按数字：选高亮那一行的第几个
    private func gridPick(_ digit: Int) -> Snapshot? {
        guard let highlighted = highlightedIndex else { return nil }
        refreshGrid(highlighted: highlighted)
        guard expanded else { return nil }
        let row = gridRowRange(gridRow(of: gridCursor))
        guard digit >= 1, digit <= row.count else { return snapshot(handled: true) }
        let handled = api.pointee.select_candidate!(id, gridItems[row.lowerBound + digit - 1].index) != 0
        expanded = false
        return snapshot(handled: handled)
    }

    // MARK: - 展开更多候选：固定列的网格，长词跨列（列上下对齐），可见几行，上下滚动（照 MsimeSession）

    /// 可见几行
    private static let gridRows = 6
    private var expanded = false
    /// 从第一个候选起取到的候选、每一行的起点
    private var gridItems: [Entry] = []
    private var gridRowStarts: [Int] = []
    /// 每个候选在它那一行里从第几列开始、到第几列（上下换行时找同一列上的那个）
    private var gridSpans: [(left: Int, right: Int)] = []
    /// 可见的第一行、高亮在 gridItems 里的位置
    private var gridFirstRow = 0
    private var gridCursor = 0
    /// 取到的后面还有候选
    private var gridMore = false

    /// 候选窗里的一个候选：文字和它在 librime 整张候选表里的序号（画不出来的跳过了，两者对不上）
    private struct Entry {
        let text: String
        let index: Int
        var learned = false

        var item: Snapshot.Item { Snapshot.Item(text: text, learned: learned) }
    }

    /// 纯学出来的词：WoType 的 Lua 过滤器（RimeCustom.learnedFilter）把注释写成这个标记。别的注释 WoType 都不显示
    static func isLearned(_ comment: UnsafeMutablePointer<CChar>?) -> Bool {
        comment.map { String(cString: $0) == RimeCustom.learnedMark } ?? false
    }

    /// 从第一个起取 limit 个画得出来的候选（librime 一页只给 6 个，按宽度分行、展开都要更多）；more：后面还有。
    /// 有字系统字体画不出来的（扩展区的生僻字只能画成缺字方框）不要，和水杉一样（CandidateView.canDisplay）
    private func candidates(limit: Int) -> (items: [Entry], more: Bool) {
        var items: [Entry] = []
        var more = false
        var iterator = RimeCandidateListIterator()
        if api.pointee.candidate_list_begin!(id, &iterator) != 0 {
            // 全是生僻字时也别一直往后找
            var visited = 0
            while items.count < limit, visited < limit * 4, api.pointee.candidate_list_next!(&iterator) != 0 {
                visited += 1
                let text = iterator.candidate.text.map { String(cString: $0) } ?? ""
                if CandidateView.canDisplay(text), !Self.isTelegraphSymbol(text) {
                    items.append(Entry(text: text, index: Int(iterator.index), learned: Self.isLearned(iterator.candidate.comment)))
                }
            }
            more = items.count == limit && api.pointee.candidate_list_next!(&iterator) != 0
            api.pointee.candidate_list_end!(&iterator)
        }
        return (items, more)
    }

    /// 表示小时、日期、月份的电报符号（㍘ 是「0点」压成一个字）：万象的 /sj、/rq 会列出来，
    /// 几乎用不到，画出来字挤在一起像坏了，不显示
    static func isTelegraphSymbol(_ text: String) -> Bool {
        guard text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first else { return false }
        return (0x3358...0x3370).contains(scalar.value) || (0x33E0...0x33FE).contains(scalar.value)
            || (0x32C0...0x32CB).contains(scalar.value)
    }

    /// librime 高亮的是 highlighted，在 items 里落在第几个：它画不出来就挪到后面最近的那个，librime 的高亮也跟过去
    private func position(of highlighted: Int, in items: [Entry]) -> Int {
        let position = items.firstIndex { $0.index >= highlighted } ?? items.count - 1
        if items[position].index != highlighted { _ = api.pointee.highlight_candidate!(id, items[position].index) }
        return position
    }

    // MARK: - 按宽度分行（照 MsimeSession，水杉 macOS 宿主的 LayoutAdaptiveCandidates）

    /// 数字键只有 1～9
    private static let rowLimit = 9
    /// 显示出来的那一行（高亮所在的行）、它的第一个在 rowItems 里的位置、高亮在这一行里的第几个
    private var row: [Entry] = []
    private var rowStart = 0
    private var rowCursor = 0
    /// 从第一个起取到的候选和每一行的起点，到高亮所在的行为止（翻到上一行用）
    private var rowItems: [Entry] = []
    private var rowStarts: [Int] = [0]
    private var rowMore = false

    /// 从第一个候选起逐行贪心装填，找到高亮所在的那一行。一行最多 rowLimit 个，
    /// 所以只取到高亮后面 rowLimit 个：高亮那一行一定排得完
    private func refreshRow(highlighted: Int) {
        row = []
        let (items, more) = candidates(limit: highlighted + Self.rowLimit + 1)
        guard !items.isEmpty else { return }
        let cursor = position(of: highlighted, in: items)
        let available = CandidateView.rowWidth, gap = CandidateView.candidateGap
        var start = 0
        rowStarts = [0]
        while start < items.count {
            var end = start + 1
            var used = CandidateView.candidateWidth(items[start].text, number: 1, cloud: false)
            while end < items.count, end - start < Self.rowLimit {
                let width = CandidateView.candidateWidth(items[end].text, number: end - start + 1, cloud: false)
                if used + gap + width > available { break }
                used += gap + width
                end += 1
            }
            if cursor < end || end >= items.count {
                row = Array(items[start..<end])
                rowStart = start
                rowCursor = min(cursor - start, row.count - 1)
                break
            }
            start = end
            rowStarts.append(start)
        }
        rowItems = items
        rowMore = more
    }

    /// 翻到下一行、上一行：让 librime 高亮那一行的第一个
    private func moveRow(forward: Bool) -> Snapshot? {
        guard let highlighted = highlightedIndex else { return nil }
        refreshRow(highlighted: highlighted)
        guard !row.isEmpty else { return snapshot(handled: true) }
        if forward {
            let next = rowStart + row.count
            if next < rowItems.count { return moveHighlight(to: rowItems[next].index) }
            return rowMore ? moveHighlight(to: rowItems[next - 1].index + 1) : snapshot(handled: true)
        }
        guard let previous = rowStarts.last(where: { $0 < rowStart }) else { return snapshot(handled: true) }
        return moveHighlight(to: rowItems[previous].index)
    }

    /// 数字 1～9 选这一行里的第几个；这一行没那么多个时返回 nil，交给 librime（万象拿 7890 打声调）
    private func pick(_ digit: Int) -> Snapshot? {
        guard let highlighted = highlightedIndex else { return nil }
        refreshRow(highlighted: highlighted)
        guard digit >= 1, digit <= row.count else { return nil }
        let handled = api.pointee.select_candidate!(id, row[digit - 1].index) != 0
        return snapshot(handled: handled)
    }

    /// librime 高亮的候选在整张候选表里的位置；没有候选时为 nil
    private var highlightedIndex: Int? {
        var context = RimeContext()
        context.data_size = Int32(MemoryLayout<RimeContext>.stride - MemoryLayout<Int32>.stride)
        guard api.pointee.get_context!(id, &context) != 0 else { return nil }
        defer { _ = api.pointee.free_context!(&context) }
        let menu = context.menu
        return menu.num_candidates > 0 ? Int(menu.page_no * menu.page_size + menu.highlighted_candidate_index) : nil
    }

    /// 从第一个候选起排进固定列的网格：每个候选按宽度占 1～整行那么多列，这一行剩下的列放不下就挪到下一行，
    /// 列线上下对齐；高亮所在的行移出可见范围就滚过去。取到高亮后面可见几行能放下的最多个数
    private func refreshGrid(highlighted: Int) {
        let (items, more) = candidates(limit: highlighted + CandidateView.gridColumnCount * Self.gridRows + 1)
        gridMore = more
        guard !items.isEmpty else {
            expanded = false
            return
        }
        gridItems = items
        let columns = CandidateView.gridColumnCount
        gridRowStarts = []
        gridSpans = []
        var column = 0
        for (i, item) in items.enumerated() {
            let span = CandidateView.gridSpan(item.text, cloud: false)
            if i == 0 || column + span > columns {
                gridRowStarts.append(i)
                column = 0
            }
            gridSpans.append((column, column + span))
            column += span
        }
        gridCursor = position(of: highlighted, in: items)
        let row = gridRow(of: gridCursor)
        if row < gridFirstRow { gridFirstRow = row }
        if row >= gridFirstRow + Self.gridRows { gridFirstRow = row - Self.gridRows + 1 }
    }

    /// 可见的那几行：候选、每行几个、可见的第一个在 gridItems 里的位置
    private var gridVisible: (items: ArraySlice<Entry>, rows: [Int], start: Int) {
        let last = min(gridFirstRow + Self.gridRows, gridRowStarts.count)
        guard gridFirstRow < last else { return ([], [], 0) }
        let rows = (gridFirstRow..<last).map { gridRowRange($0).count }
        let start = gridRowStarts[gridFirstRow]
        return (gridItems[start..<gridRowRange(last - 1).upperBound], rows, start)
    }

    private func gridRow(of item: Int) -> Int {
        (gridRowStarts.lastIndex { $0 <= item }) ?? 0
    }

    private func gridRowRange(_ row: Int) -> Range<Int> {
        gridRowStarts[row]..<(row + 1 < gridRowStarts.count ? gridRowStarts[row + 1] : gridItems.count)
    }

    /// 展开时的方向键：← → 在一行里移，↑ ↓ 换到上下一行横向最近的那个，第一行再按 ↑ 收起；
    /// Page Up / Down 翻一屏。别的键返回 nil，收起后照常交给 librime
    private func gridKey(_ key: UInt32) -> Snapshot? {
        guard let highlighted = highlightedIndex else { return nil }
        refreshGrid(highlighted: highlighted)
        guard expanded else { return nil }
        let row = gridRow(of: gridCursor)
        switch Int(key) {
        case WOTYPE_KEY_LEFT:
            // 行首按 ← 到上一行最后一个，行尾按 → 到下一行第一个（移出可见范围就滚过去）
            guard gridCursor > 0 else { return snapshot(handled: true) }
            return moveHighlight(to: gridItems[gridCursor - 1].index)
        case WOTYPE_KEY_RIGHT:
            if gridCursor + 1 < gridItems.count { return moveHighlight(to: gridItems[gridCursor + 1].index) }
            return gridMore ? moveHighlight(to: gridItems[gridCursor].index + 1) : snapshot(handled: true)
        case WOTYPE_KEY_DOWN:
            return moveGrid(toRow: row + 1)
        case WOTYPE_KEY_UP:
            if row == 0 { return toggleGrid() }
            return moveGrid(toRow: row - 1)
        case WOTYPE_KEY_PAGE_DOWN:
            return moveGrid(toRow: min(row + Self.gridRows, gridRowStarts.count - 1))
        case WOTYPE_KEY_PAGE_UP:
            return moveGrid(toRow: row - Self.gridRows)
        default:
            return nil
        }
    }

    /// 高亮挪到 row 行里横向离现在最近的那个；没有那一行就不动。
    private func moveGrid(toRow row: Int) -> Snapshot? {
        let target = max(row, 0)
        guard target < gridRowStarts.count else { return snapshot(handled: true) }
        let center = gridSpans[gridCursor].left + gridSpans[gridCursor].right
        let nearest = gridRowRange(target).min { a, b in
            abs(gridSpans[a].left + gridSpans[a].right - center) < abs(gridSpans[b].left + gridSpans[b].right - center)
        } ?? gridRowStarts[target]
        return moveHighlight(to: gridItems[nearest].index)
    }

    /// 让 librime 高亮整张候选表里的第 index 个（它会翻到那一页；画不出来的，出快照时挪到后面最近的）
    private func moveHighlight(to index: Int) -> Snapshot? {
        _ = api.pointee.highlight_candidate!(id, index)
        return snapshot(handled: true)
    }

    /// 拼音里的光标在末尾（没用 ← 移进去过）。按原始输入算：万象有时在组字区后面加提示
    /// （/sj 是「/sj 〔未时(日昳)〕」），组字区的光标就不在末尾了
    private var caretAtEnd: Bool {
        guard let input = api.pointee.get_input!(id) else { return true }
        return api.pointee.get_caret_pos!(id) >= strlen(input)
    }

    /// 横排时的 ← →（照旧万象和水杉的 caret_edge_candidate_shortcut）：高亮在首选时 ← 移拼音里的光标，
    /// → 光标没到末尾移光标、到了末尾选下一个；高亮不在首选时只移候选。移光标交给 librime（按音节移），
    /// 移候选用 highlight_candidate（跨页它自己翻）。返回 nil 是交给 librime
    private func arrow(backwards: Bool) -> Snapshot? {
        guard let highlighted = highlightedIndex else { return nil }
        refreshRow(highlighted: highlighted)
        guard !row.isEmpty else { return nil }
        let current = rowStart + rowCursor
        let editsCaret = current == 0 && (backwards || !caretAtEnd)
        guard !editsCaret else { return nil }
        if backwards {
            guard current > 0 else { return snapshot(handled: true) }
            return moveHighlight(to: rowItems[current - 1].index)
        }
        // 这一行最后一个再按 →：展开，高亮留在它上面（照微信，微信中间还停一下工具图标，WoType 没有）；
        // 后面没有了就不动
        if rowCursor == row.count - 1 {
            guard rowStart + row.count < rowItems.count || rowMore else { return snapshot(handled: true) }
            expanded = true
            navigated = true
            gridFirstRow = 0
            return snapshot(handled: true)
        }
        return moveHighlight(to: rowItems[current + 1].index)
    }

    /// 打了一半要上屏时的文字：已经选好的那段 + 剩下的原始字母（没选过就是整串原始字母）
    private func pendingText() -> String {
        guard let input = api.pointee.get_input!(id).map({ String(cString: $0) }), !input.isEmpty else { return "" }
        var context = RimeContext()
        context.data_size = Int32(MemoryLayout<RimeContext>.stride - MemoryLayout<Int32>.stride)
        guard api.pointee.get_context!(id, &context) != 0 else { return input }
        defer { _ = api.pointee.free_context!(&context) }
        let composition = context.composition
        guard composition.sel_start > 0, let preedit = composition.preedit else { return input }
        let bytes = Array(UnsafeBufferPointer(start: UnsafeRawPointer(preedit).assumingMemoryBound(to: UInt8.self),
                                              count: strlen(preedit)))
        let split = min(Int(composition.sel_start), bytes.count)
        // 没选的那段组字区是带分隔符的拼音（ni hao），去掉分隔符就是原样的字母
        let tail = String(decoding: bytes[split...], as: UTF8.self).filter { $0 != " " && $0 != "'" }
        return String(decoding: bytes[..<split], as: UTF8.self) + tail
    }
}

extension RimeSession: PinyinSession {
    func key(_ key: UInt32, modifiers: UInt32, preceding: UInt32) -> Snapshot? {
        let before = contextBefore ?? (preceding != 0 ? Unicode.Scalar(preceding) : nil)
        contextBefore = nil
        let skip = autoClosed
        autoClosed = nil
        if raw != nil { return rawKey(key, modifiers: modifiers) }
        // ⇧⌫ / ⇧⌦：删掉高亮候选学到的记录（照 Rime 的 Shift+Delete）。学错的词（分段选拼出来的）就没了，
        // 词库里本来有的词只是回到原来的排位。万象的 auto_phrase.lua 会多删一个，下载时修补过（scripts/fetch-wanxiang.sh）
        if modifiers & UInt32(WOTYPE_MOD_CONTROL | WOTYPE_MOD_OPTION | WOTYPE_MOD_COMMAND | WOTYPE_MOD_SHIFT) == UInt32(WOTYPE_MOD_SHIFT),
           key == UInt32(WOTYPE_KEY_BACKSPACE) || key == UInt32(WOTYPE_KEY_DELETE), let highlighted = highlightedIndex {
            _ = api.pointee.delete_candidate!(id, highlighted)
            return snapshot(handled: true)
        }
        let plain = modifiers & UInt32(WOTYPE_MOD_CONTROL | WOTYPE_MOD_OPTION | WOTYPE_MOD_COMMAND | WOTYPE_MOD_SHIFT) == 0
        let noCommand = modifiers & UInt32(WOTYPE_MOD_CONTROL | WOTYPE_MOD_OPTION | WOTYPE_MOD_COMMAND) == 0
        let idle = api.pointee.get_input!(id).map { $0.pointee == 0 } ?? true
        // 带 ⌃ ⌥ ⌘ 的组合键交还给应用（组字中也是：⌘C 之类不该吃掉；万象绑的 ⌃ 键也不要，照水杉）
        guard noCommand else { return snapshot(handled: false) }
        // Tab：先上屏打了一半的（和切英文一样），再交给应用，表格、表单里照常跳格（照水杉）
        if key == UInt32(WOTYPE_KEY_TAB) {
            guard !idle else { return passWithPending(key, modifiers: modifiers) }
            let text = pendingText() + (pendingClosing ?? "")
            endInput()
            pendingClosing = nil
            api.pointee.clear_composition!(id)
            return snapshot(handled: false, extraCommit: text, pair: false)
        }
        // 大写锁定开着、没在组字时，大写字母交给应用（照水杉）
        if idle, modifiers & UInt32(WOTYPE_MOD_CAPSLOCK) != 0, modifiers & UInt32(WOTYPE_MOD_SHIFT) == 0,
           (0x41...0x5A).contains(key) {
            return passWithPending(key, modifiers: modifiers)
        }
        if idle {
            let config = Settings.shared.config
            // 紧跟在补上的后半个后面再按出同一个后半个：跨过去，不再出一个
            if pendingClosing == nil, let skip, Self.closingKeys[key] == skip {
                return snapshot(handled: true)
            }
            // 后半个还挂着时按出它：送出挂着的那个就是，不再多出一个
            if let pending = pendingClosing, Self.closingKeys[key] == pending {
                pendingClosing = nil
                return snapshot(handled: true, extraCommit: pending, pair: false)
            }
            // 数字后面的 . : / 原样（3.14、12:30、2024/1/1），不转成中文标点、不进万象的 / 功能
            if config.asciiPunctAfterDigit, [0x2E, 0x3A, 0x2F].contains(key), let before, ("0"..."9").contains(before) {
                return passWithPending(key, modifiers: modifiers)
            }
            // 汉字后面打数字：由这里上屏，InputController 按 spacedCommit 补空格（数字 librime 不收，会直接交给应用）
            if config.spaceCJKLatin, (0x30...0x39).contains(key), let before, Self.isCJK(before) {
                return snapshot(handled: true, extraCommit: String(Character(Unicode.Scalar(key)!)), pair: false)
            }
        }
        // 照微信：= 就是 ↓；- 打开过网格以后是 ↑，之前（和 + 一样）进原样输入。
        // . 和 @ 也进原样输入（照旧万象：网址、邮箱，@ 后面补全邮箱后缀）
        let down = plain && (key == UInt32(WOTYPE_KEY_DOWN) || key == 0x3D)
        let up = plain && (key == UInt32(WOTYPE_KEY_UP) || key == 0x2D && (navigated || expanded))
        if [0x2B, 0x2E, 0x40].contains(key) || key == 0x2D && !up, highlightedIndex != nil, case let base = pendingText(), !base.isEmpty {
            raw = RawInput(base: base, symbol: Character(Unicode.Scalar(key)!))
            expanded = false
            return snapshot(handled: true)
        }
        if expanded {
            if down, let grid = gridKey(UInt32(WOTYPE_KEY_DOWN)) { return grid }
            if up, let grid = gridKey(UInt32(WOTYPE_KEY_UP)) { return grid }
            if plain, (0x31...0x39).contains(key), let picked = gridPick(Int(key) - 0x30) { return picked }
            if plain, let grid = gridKey(key) { return grid }
            // 别的键（打字母、空格、回车……）收起后照常交给 librime
            expanded = false
        } else if down, let grid = expandDown() {
            return grid
        } else if plain, key == 0x2D, navigated, highlightedIndex != nil {
            // 打开过网格又收起了：- 没反应
            return snapshot(handled: true)
        } else if plain, key == UInt32(WOTYPE_KEY_LEFT) || key == UInt32(WOTYPE_KEY_RIGHT),
                  let moved = arrow(backwards: key == UInt32(WOTYPE_KEY_LEFT)) {
            return moved
        } else if plain, key == UInt32(WOTYPE_KEY_PAGE_UP) || key == UInt32(WOTYPE_KEY_PAGE_DOWN),
                  let paged = moveRow(forward: key == UInt32(WOTYPE_KEY_PAGE_DOWN)) {
            // Page Up / Down：按宽度分好的行翻，不按 librime 的一页 6 个
            return paged
        } else if plain, (0x31...0x39).contains(key), let picked = pick(Int(key) - 0x30) {
            return picked
        }
        guard let sym = Self.keysym(key) else { return snapshot(handled: false) }
        let isPunctuation = key > 0x20 && key < 0x7F && !Unicode.Scalar(key)!.properties.isAlphabetic && !(0x30...0x39).contains(key)
        punctuationKey = isPunctuation ? key : nil
        defer { punctuationKey = nil }
        let handled = api.pointee.process_key!(id, sym, Self.mask(modifiers)) != 0
        if idle, !handled, pendingClosing != nil, api.pointee.get_input!(id).map({ $0.pointee == 0 }) ?? true {
            return passWithPending(key, modifiers: modifiers)
        }
        return snapshot(handled: handled)
    }

    /// index：候选窗里这一行（展开时是可见的这一屏）的第几个
    func select(_ index: Int) -> Snapshot? {
        // 原样输入：上屏点的那个
        if raw != nil {
            raw?.highlight(index)
            return rawKey(0x20, modifiers: 0)
        }
        let shown = expanded ? Array(gridVisible.items) : row
        guard shown.indices.contains(index) else { return snapshot(handled: false) }
        let handled = api.pointee.select_candidate!(id, shown[index].index) != 0
        expanded = false
        return snapshot(handled: handled)
    }

    /// 候选窗右边的 ∨ / ∧，或横排时按 ↓。
    func toggleGrid() -> Snapshot? {
        if raw != nil { return snapshot(handled: true) }
        guard expanded || highlightedIndex != nil else { return snapshot(handled: false) }
        expanded.toggle()
        gridFirstRow = 0
        return snapshot(handled: true)
    }

    /// 展开时触控板、滚轮翻行：高亮挪到上下 rows 行同一列上的那个（移出可见范围就滚过去）。
    /// 和 ↑ 不一样，在第一行往上滑不收起。
    func scrollGrid(_ rows: Int) -> Snapshot? {
        guard raw == nil, expanded, let highlighted = highlightedIndex else { return snapshot(handled: true) }
        refreshGrid(highlighted: highlighted)
        let target = gridRow(of: gridCursor) + rows
        guard expanded, target >= 0, target < gridRowStarts.count else { return snapshot(handled: true) }
        return moveGrid(toRow: target)
    }

    /// commitPending：打了一半的和挂着的后半个都上屏；否则（失去焦点）都丢掉
    func reset(commitPending: Bool) -> Snapshot? {
        let text = commitPending ? (raw?.text ?? pendingText()) + (pendingClosing ?? "") : ""
        endInput()
        pendingClosing = nil
        api.pointee.clear_composition!(id)
        return snapshot(handled: true, extraCommit: text, pair: false)
    }

    /// 换了输入框：上一个输入框挂着的后半个不带过来
    func setFocused(_ focused: Bool) {
        if focused {
            pendingClosing = nil
            autoClosed = nil
        }
    }

    /// 要光标前的文字：判断数字后的标点、汉字和数字之间补空格
    var wantsContext: Bool { true }

    func setContext(_ text: String) {
        contextBefore = text.unicodeScalars.last
    }

    func commitText(_ text: String) -> Snapshot? {
        endInput()
        api.pointee.clear_composition!(id)
        return snapshot(handled: true, extraCommit: text)
    }

    func commitRaw() -> Snapshot? {
        reset(commitPending: true)
    }

    /// 设置里开了「中英文之间加空格」：光标前是汉字、这次开头是英文字母或数字（或者反过来）时前面补一个空格
    func spacedCommit(_ text: String, preceding: UInt32, application: String) -> String {
        guard Settings.shared.config.spaceCJKLatin, let first = text.unicodeScalars.first,
              let before = Unicode.Scalar(preceding) else { return text }
        let needsSpace = Self.isCJK(before) && Self.isLatin(first) || Self.isLatin(before) && Self.isCJK(first)
        return needsSpace ? " " + text : text
    }
}
