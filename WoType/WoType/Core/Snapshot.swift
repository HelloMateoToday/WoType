//
//  Snapshot.swift
//  WoType
//
//  一次按键之后要做的事：上屏什么、编辑区画什么、候选窗画什么（MsimeSession 从水杉的 View 转来）。
//

import Foundation

struct Snapshot {
    enum Mode {
        /// 没有组字：编辑区清空、候选窗收起
        case idle
        /// 一页候选（横排一行；万象的日期、时间格式是竖排一列）
        case list
        /// 展开的网格（横排时按 ↓ 或点 ∨）
        case grid
    }

    struct Item {
        let text: String
        /// 云候选（水杉的来源 2），候选窗在后面画一个小云朵
        var cloud = false
        /// 候选前面画的图标（SF Symbols 名）：万象的日期、时间候选是 calendar
        var icon: String?
        /// 纯学出来的词（万象：用户词库有、系统词库没有），候选窗在字的右上角画小圆点，按 ⇧⌫ 能删掉
        var learned = false
    }

    /// 水杉处理了这个键；false 时交还给应用
    let handled: Bool
    /// 要上屏的文字
    let commit: String
    let mode: Mode
    /// 长句分段选时已经选好的部分（粗下划线）
    let selected: String
    /// 还没选的拼音（细下划线）
    let remaining: String
    let horizontal: Bool
    /// 一行几个（展开时是最长那一行的个数）
    let columns: Int
    /// 第一个候选在整张候选表里的位置
    let first: Int
    /// 高亮的候选在这一页（这一屏）里的位置
    let cursor: Int
    /// 候选总数（够不够展开）
    let total: Int
    let hasPrev: Bool
    let hasNext: Bool
    let candidates: [Item]
    /// 上屏后光标要往左退几个字（快捷短语指定了光标位置）
    let caretBack: Int
    /// 自动补上、还没送出的后半个符号：画在编辑区末尾、光标后面
    var tail = ""
    /// 候选前画不画序号：万象的原样输入（网址、邮箱、v 模式）没展开时数字是要打进去的字，不是选词，不画（照微信）
    var numbered = true
    /// 光标在 remaining 里的位置（UTF-16）；nil 是在末尾
    var caret: Int?
    /// 展开时可见的每一行各有几个候选（candidates 按行依次排）
    var rows: [Int] = []
    /// 展开时每个候选占几列（固定列的网格，长词跨列；一行里从第 0 列依次排，行尾可能留空）
    var spans: [Int] = []
    /// 高亮的候选连同已经选好的那段（候选翻译翻它）；没在打拼音时是 nil
    var highlight: String?
    /// 选了高亮的候选整句就打完了（候选只用掉一部分拼音时，译文先不让上屏）
    var highlightComplete = false
    /// 候选窗底下的译文条（InputController 按 CandidateTranslator 的状态填）
    var translation: CandidateTranslator.Bar?

    /// 同一个画面、不再上屏（重画候选窗用）
    var withoutCommit: Snapshot {
        Snapshot(handled: handled, commit: "", mode: mode, selected: selected, remaining: remaining, horizontal: horizontal,
                 columns: columns, first: first, cursor: cursor, total: total, hasPrev: hasPrev, hasNext: hasNext,
                 candidates: candidates, caretBack: 0, tail: tail, numbered: numbered, caret: caret, rows: rows, spans: spans,
                 highlight: highlight, highlightComplete: highlightComplete, translation: translation)
    }

    /// 同一个画面、键交还给应用（Tab：先上屏，表格、表单里照常跳格）
    var passedThrough: Snapshot {
        Snapshot(handled: false, commit: commit, mode: mode, selected: selected, remaining: remaining, horizontal: horizontal,
                 columns: columns, first: first, cursor: cursor, total: total, hasPrev: hasPrev, hasNext: hasNext,
                 candidates: candidates, caretBack: caretBack, tail: tail, numbered: numbered, caret: caret, rows: rows,
                 spans: spans, highlight: highlight, highlightComplete: highlightComplete, translation: translation)
    }

    /// 编辑区要显示的文字。
    var preedit: String { selected + remaining }
}
