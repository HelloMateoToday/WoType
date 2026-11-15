//
//  WanxiangSession.swift
//  WoType
//
//  万象引擎的输入会话（engine/core/src/session.rs）的 Swift 包装，docs/15。只在主线程用。
//  交互逻辑都在 Rust 里；这里只负责把按键交进去、把 JSON 快照解出来转成 Snapshot。
//  2026-11-12 从 76a9241 的 Session.swift 取回。
//

import Foundation
import os

final class WanxiangSession {

    private let handle: OpaquePointer
    private let decoder = JSONDecoder()

    init() {
        handle = wotype_session_new()
    }

    deinit {
        wotype_session_free(handle)
    }

    private var engine: OpaquePointer? { WanxiangEngine.shared.handle }

    /// 自动补上、还没送出的后半个符号（（ 后面的 ）），画在编辑区末尾、光标后面，下次上屏时跟在后面送出。
    /// 照水杉（MsimeSession.pairing）：引擎把「（）」一起上屏再退光标，好些应用里光标退不回去。
    private var pendingClosing: String?
    /// 引擎那边没在组字（上一份快照是 idle）：这时只挂着后半个
    private var engineIdle = true

    /// wotype_session_snapshot 的 JSON，字段见 wotype_core.h。
    private struct Raw: Decodable {
        enum Mode: String, Decodable {
            case idle, list, grid, emoji
        }

        struct Item: Decodable {
            let text: String
            /// 选了它整串拼音就打完了（不是句首词）
            let whole: Bool?
            /// 前面画的图标（日期、时间候选是 calendar）
            let icon: String?
        }

        let handled: Bool
        let commit: String
        let learned: Int
        let mode: Mode
        let selected: String
        let remaining: String
        let horizontal: Bool
        let columns: Int
        let first: Int
        let cursor: Int
        let total: Int
        let hasPrev: Bool
        let hasNext: Bool
        let candidates: [Item]
        let caretBack: Int
        /// 原样输入（网址、邮箱、v 模式）
        let raw: Bool?
        /// 拼音里的光标在 remaining 里的位置（UTF-16）；在末尾时没有
        let caret: Int?
        /// 展开时这一屏每行几个、每个候选占几列（引擎按 CandidateView.gridSpan 量的排）
        let rows: [Int]?
        let spans: [Int]?

        enum CodingKeys: String, CodingKey {
            case handled, commit, learned, mode, selected, remaining, horizontal, columns, first, cursor, total
            case hasPrev = "has_prev"
            case hasNext = "has_next"
            case candidates
            case caretBack = "caret_back"
            case caret, rows, spans, raw
        }
    }

    private func snapshot(handled: Bool) -> Snapshot? {
        guard let raw = wotype_session_snapshot(handle, handled ? 1 : 0) else { return nil }
        let decoded: Raw
        do {
            decoded = try decoder.decode(Raw.self, from: Data(bytes: raw, count: strlen(raw)))
        } catch {
            Log.input.error("万象快照解码失败：\(error.localizedDescription, privacy: .public)")
            return nil
        }
        if decoded.learned > 0 {
            WanxiangEngine.shared.didLearn(decoded.learned)
        }
        engineIdle = decoded.mode == .idle
        let commit = pairing(decoded.commit, caretBack: decoded.caretBack)
        let mode: Snapshot.Mode = switch decoded.mode {
        case .idle: pendingClosing == nil ? .idle : .list
        case .list: .list
        case .grid, .emoji: .grid
        }
        var result = Snapshot(
            handled: decoded.handled, commit: commit, mode: mode,
            selected: decoded.selected, remaining: decoded.remaining, horizontal: decoded.horizontal,
            columns: decoded.columns, first: decoded.first, cursor: decoded.cursor, total: decoded.total,
            hasPrev: decoded.hasPrev, hasNext: decoded.hasNext,
            candidates: decoded.candidates.map { Snapshot.Item(text: $0.text, icon: $0.icon) },
            caretBack: 0)
        result.tail = pendingClosing ?? ""
        result.numbered = !(decoded.raw == true && mode == .list)
        result.caret = decoded.caret
        // 展开：固定 6 列，长词跨列，按引擎排好的行画（和水杉的展开候选一样）
        if mode == .grid {
            result.rows = decoded.rows ?? []
            result.spans = decoded.spans ?? []
        }
        // 候选翻译翻「已经选好的那段 + 高亮的候选」；高亮的是句首词（只用掉一部分拼音）时译文先不让 ⏎ 上屏
        if mode != .idle, decoded.candidates.indices.contains(decoded.cursor) {
            let highlighted = decoded.candidates[decoded.cursor]
            result.highlight = decoded.selected + highlighted.text
            result.highlightComplete = highlighted.whole ?? false
        }
        return result
    }

    /// 引擎补上的后半个（上屏文字末尾 caretBack 个字）不送出，挂起来；别的上屏把挂着的接在后面送出。
    /// 括号套括号时后半个叠起来：（（ → （（|））。
    private func pairing(_ commit: String, caretBack: Int) -> String {
        if caretBack > 0, commit.count >= caretBack {
            pendingClosing = String(commit.suffix(caretBack)) + (pendingClosing ?? "")
            return String(commit.dropLast(caretBack))
        }
        guard !commit.isEmpty, let pending = pendingClosing else { return commit }
        pendingClosing = nil
        return commit + pending
    }

    /// 只挂着后半个时引擎交还给应用的键：字符（数字、空格、没收录的符号）由这里上屏，后半个接着挂着；
    /// 别的键（回车、方向键、⌘V 之类）先把后半个送出再交给应用。
    private func passThrough(_ key: UInt32, modifiers: UInt32, _ result: Snapshot) -> Snapshot {
        let plain = modifiers & UInt32(WOTYPE_MOD_CONTROL | WOTYPE_MOD_OPTION | WOTYPE_MOD_COMMAND) == 0
        if plain, key >= 0x20, key < 0x7F, let scalar = UnicodeScalar(key) {
            return committed(String(Character(scalar)), from: result, handled: true)
        }
        let pending = pendingClosing ?? ""
        pendingClosing = nil
        return committed(pending, from: result, handled: false)
    }

    /// 同一个画面换成上屏 text（编辑区只剩挂着的后半个，或什么都没有）。
    private func committed(_ text: String, from result: Snapshot, handled: Bool) -> Snapshot {
        var snapshot = Snapshot(handled: handled, commit: text, mode: pendingClosing == nil ? .idle : .list,
                                selected: "", remaining: "", horizontal: result.horizontal, columns: 0, first: 0,
                                cursor: 0, total: 0, hasPrev: false, hasNext: false, candidates: [], caretBack: 0)
        snapshot.tail = pendingClosing ?? ""
        return snapshot
    }
}

extension WanxiangSession: PinyinSession {
    var wantsContext: Bool { true }

    func setContext(_ text: String) {
        wotype_session_set_context(handle, text)
    }

    func key(_ key: UInt32, modifiers: UInt32, preceding: UInt32) -> Snapshot? {
        let idle = engineIdle
        let handled = wotype_session_key(handle, engine, key, modifiers) != 0
        guard let result = snapshot(handled: handled) else { return nil }
        guard idle, !handled, pendingClosing != nil, result.mode != .grid, result.remaining.isEmpty else { return result }
        // 没在组字、只挂着后半个时按退格：键交给应用删左半个，后半个也不要了
        if key == UInt32(WOTYPE_KEY_BACKSPACE) {
            pendingClosing = nil
            return committed("", from: result, handled: false)
        }
        return passThrough(key, modifiers: modifiers, result)
    }

    func select(_ index: Int) -> Snapshot? {
        let handled = wotype_session_select(handle, engine, index) != 0
        return snapshot(handled: handled)
    }

    func toggleGrid() -> Snapshot? {
        let handled = wotype_session_toggle_grid(handle) != 0
        return snapshot(handled: handled)
    }

    func scrollGrid(_ rows: Int) -> Snapshot? {
        guard rows != 0 else { return nil }
        let handled = wotype_session_page(handle, rows < 0 ? -1 : 1) != 0
        return snapshot(handled: handled)
    }

    /// commitPending 为 true（切英文、切输入法）时打了一半的内容放进快照的 commit 上屏。
    /// 挂着的后半个：commitPending 时跟着送出，否则（失去焦点）丢掉。
    func reset(commitPending: Bool) -> Snapshot? {
        wotype_session_reset(handle, engine, commitPending ? 1 : 0)
        let pending = commitPending ? pendingClosing ?? "" : ""
        pendingClosing = nil
        guard let result = snapshot(handled: true) else { return nil }
        return pending.isEmpty ? result : committed(result.commit + pending, from: result, handled: true)
    }

    /// 换了输入框：上一个输入框挂着的后半个不带过来
    func setFocused(_ focused: Bool) {
        if focused { pendingClosing = nil }
    }

    /// 挂着的后半个照样跟在译文后面送出。
    func commitText(_ text: String) -> Snapshot? {
        wotype_session_reset(handle, engine, 0)
        guard let cleared = snapshot(handled: true) else { return nil }
        let pending = pendingClosing ?? ""
        pendingClosing = nil
        return committed(text + pending, from: cleared, handled: true)
    }

    func commitRaw() -> Snapshot? {
        reset(commitPending: true)
    }

    /// 中英文之间的空格引擎在会话里自己加（WOTYPE_OPT_SPACE_CJK_*），这里不再补。
    func spacedCommit(_ text: String, preceding: UInt32, application: String) -> String {
        text
    }
}
