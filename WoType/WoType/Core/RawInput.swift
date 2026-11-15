//
//  RawInput.swift
//  WoType
//
//  原样输入（照微信输入法，2026-11-15 实测）：打拼音途中按 -（还没用 = 或 ↓ 打开过网格时）或 +，
//  已经打的（选好的词 + 原始字母）连同这个符号原样留在编辑区，候选是这一串（不画序号）。
//  万象打拼音途中按 . 或 @ 也进来（照旧万象，docs/17）：网址、邮箱原样打，@ 后面补全邮箱后缀。
//  之后可打印字符都接在后面（数字也是，不选词），← → 挑候选（候选按候选窗宽度分行，显示高亮那一行），空格、回车上屏高亮的那个，Esc 全部清掉，
//  Tab 上屏后再交给应用；退格删最后一个字，删回到进来之前的那串就退出，回到原来的候选（引擎里的拼音一直没动）。
//  水杉和万象（MsimeSession、RimeSession）共用，状态由会话各自持有。
//

import Foundation

nonisolated struct RawInput {
    /// 进来之前编辑区里那串：退格删回到它就退出
    let base: String
    private(set) var text: String
    /// 候选：一般只有这一串；@ 后面是补全的邮箱，原样的排在最后
    private(set) var candidates: [String] = []
    /// 高亮的候选
    private(set) var cursor = 0

    init(base: String, symbol: Character) {
        self.base = base
        text = base + String(symbol)
        refresh()
    }

    /// @ 后补全的邮箱后缀：照微信输入法的表和顺序（2026-11-13 实测，旧万象的 MAIL_DOMAINS）
    static let mailDomains = [
        "qq.com", "163.com", "126.com", "gmail.com", "sina.com", "139.com", "hotmail.com", "outlook.com",
        "yahoo.com", "foxmail.com", "icloud.com", "tencent.com", "jd.com", "didiglobal.com", "alibaba.com",
    ]

    /// 这一串的候选（照微信）：@ 后面开头对得上的后缀，@ 后面打了字、还没有 . 时加「打的 + .com」，最后是原样，
    /// 重复的只留一个；@ 后面什么都没打时只列后缀。没有 @ 时只有原样
    static func candidates(for text: String) -> [String] {
        guard let at = text.lastIndex(of: "@") else { return [text] }
        let user = text[..<at], typed = String(text[text.index(after: at)...])
        var result = mailDomains.filter { $0.hasPrefix(typed) }.map { "\(user)@\($0)" }
        if !typed.isEmpty {
            if !typed.contains(".") { result.append(text + ".com") }
            result.append(text)
        }
        var seen = Set<String>()
        result = result.filter { seen.insert($0).inserted }
        return result.isEmpty ? [text] : result
    }

    private mutating func refresh() {
        candidates = Self.candidates(for: text)
        cursor = 0
    }

    enum Action: Equatable {
        /// 编辑区或高亮变了，接着原样输入
        case update
        /// 上屏这串，结束这次输入
        case commit(String)
        /// 上屏这串，再把这个键交给应用（Tab：表格、表单里照常跳格）
        case finish(String)
        /// 全部清掉（编辑区、引擎里的拼音）
        case cancel
        /// 退回进来之前：引擎里的拼音和候选照旧
        case exit
        /// 吃掉，什么都不变（编辑区里没有能移的光标）
        case ignore
        /// 交给应用（带 ⌃ ⌥ ⌘ 的组合键）
        case passThrough
    }

    /// 处理一个键（WOTYPE_KEY_* 或字符，modifiers 是 WOTYPE_MOD_*）
    mutating func key(_ key: UInt32, modifiers: UInt32) -> Action {
        if modifiers & UInt32(WOTYPE_MOD_CONTROL | WOTYPE_MOD_OPTION | WOTYPE_MOD_COMMAND) != 0 {
            return .passThrough
        }
        switch key {
        case UInt32(WOTYPE_KEY_BACKSPACE):
            text.removeLast()
            guard text.count > base.count else { return .exit }
            refresh()
            return .update
        case UInt32(WOTYPE_KEY_RETURN), 0x20:
            return .commit(candidates[cursor])
        case UInt32(WOTYPE_KEY_TAB):
            return .finish(candidates[cursor])
        case UInt32(WOTYPE_KEY_ESCAPE):
            return .cancel
        case UInt32(WOTYPE_KEY_LEFT):
            guard cursor > 0 else { return .ignore }
            cursor -= 1
            return .update
        case UInt32(WOTYPE_KEY_RIGHT):
            guard cursor + 1 < candidates.count else { return .ignore }
            cursor += 1
            return .update
        case 0x21..<0x7F:
            text.unicodeScalars.append(Unicode.Scalar(key)!)
            refresh()
            return .update
        default:
            return .ignore
        }
    }

    /// 点了候选窗这一行的第几个：高亮它（接着按空格上屏）
    @MainActor mutating func highlight(_ index: Int) {
        let row = self.row
        if index >= 0, index < row.count { cursor = row.lowerBound + index }
    }

    /// 候选窗显示的那一行：@ 后面的邮箱有十几个，按候选窗宽度放得下几个放几个（和平时的候选一样宽），
    /// 显示高亮所在的那一行，← → 走到头接着翻行
    @MainActor private var row: Range<Int> {
        let available = CandidateView.rowWidth, gap = CandidateView.candidateGap
        var start = 0
        while true {
            var end = start + 1
            var used = CandidateView.candidateWidth(candidates[start], number: nil)
            while end < candidates.count {
                let width = CandidateView.candidateWidth(candidates[end], number: nil)
                if used + gap + width > available { break }
                used += gap + width
                end += 1
            }
            if cursor < end || end >= candidates.count { return start..<end }
            start = end
        }
    }

    /// 编辑区是这一串，候选是补全的邮箱和原样（不画序号：数字是要打进去的字）。commit：同时上屏的文字
    @MainActor func snapshot(handled: Bool, commit: String = "") -> Snapshot {
        let row = self.row
        // total 只算这一行：不出 ∨（原样输入不展开）
        var result = Snapshot(handled: handled, commit: commit, mode: .list, selected: "", remaining: text,
                              horizontal: true, columns: row.count, first: row.lowerBound, cursor: cursor - row.lowerBound,
                              total: row.count, hasPrev: row.lowerBound > 0, hasNext: row.upperBound < candidates.count,
                              candidates: candidates[row].map { Snapshot.Item(text: $0) }, caretBack: 0)
        result.numbered = false
        return result
    }
}
