//
//  MsimeSession.swift
//  WoType
//
//  水杉的输入会话（msime_client_create 建的那个），每个输入框一个，只在主线程用。
//  按键怎么交给水杉照它自己的 macOS 宿主（platforms/macos/src/input/InputControllerKeyRouting.h 和 InputController.mm）：
//  字符走 msime_client_character（数字选词、以词定字由它判断），组字中它不收的标点改走 msime_client_punctuation，
//  编辑键和翻页发命令。宿主自己做的几件事也照水杉：大写锁定时新起的大写字母交给应用、
//  符号自动补全（后半个留在组字区末尾，下一次上屏时一起送出）、两次上屏之间加空格、展开候选。
//  水杉回来的 {handled, commit, view} 转成 Snapshot，InputController 和候选窗只认 Snapshot。
//  会话整个进程一个（MsimeHost.session），切输入框只切焦点。
//

import Foundation
import os

/// msime_client.h 的 MsimeCommand。
private enum MsimeCommand: UInt32 {
    case backspace = 0, commitCandidate = 1, commitRaw = 2, cancel = 3
    case moveLeft = 4, moveRight = 5, moveHome = 6, moveEnd = 7, deleteForward = 8
    case finishComposition = 9
    case moveLeftSegment = 13, moveRightSegment = 14
    case commitRawWithoutLearning = 15
    case finishOnFocusLoss = 20
    case nextPage = 100, previousPage = 101, nextCandidate = 102, previousCandidate = 103
    case lastCandidate = 105, firstCandidateOrHome = 106
}

/// 水杉的候选（input-runtime 的 types.rs），只解出用得到的字段。
private struct MsimeCandidate: Decodable {
    struct ID: Decodable {
        let generation: UInt64
        let index: Int
    }
    let id: ID
    let text: String
    let annotation: String
    let highlighted: Bool
    /// 候选的来源：13 是日文，18 已经由水杉逐段转过繁体，这两种不再整行转
    let source: Int
    /// 候选用掉的拼音，音节之间带 '（wo'men）。去掉 ' 和 editing_text 一样时，选它就把剩下的拼音全用完了
    let code: String?

    /// 在线占位行：云候选在等回答（15，文字是 ☁）、AI 在等回答（12）。照水杉 macOS 宿主的
    /// MSIMEVisibleCandidates：它只表示请求的状态，不画、不占序号，翻页和展开也不算它
    var placeholder: Bool { source == 12 || source == 15 }

    /// 不画出来的候选：占位行，或者有字系统字体画不出来（扩展区的生僻字只能画成缺字方框，上屏到别的应用也一样）。
    /// 和占位行一样不占序号，翻页、展开都不算它，高亮落上去就挪开
    var hidden: Bool { placeholder || !CandidateView.canDisplay(text) }
}

/// 水杉的 View，只解出用得到的字段。
private struct MsimeView: Decodable {
    let session: UInt64
    let generation: UInt64
    /// 会话有没有焦点：没有时水杉不收按键
    let focused: Bool
    let preedit: String
    /// 光标在 preedit 里的位置（Unicode 标量）
    let preeditCaret: Int
    let editingText: String
    /// 光标在 editing_text 里的位置（字节，按键原文是 ASCII）
    let caretPosition: Int
    let phrasePrefix: String?
    let conversion: String
    let page: Int
    let pageSize: Int
    let pageCount: Int
    let spellingSymbols: String
    /// 简转繁对这次的候选和上屏适用（日期、Unicode 这类模式里出的字不转）
    let scriptConversion: Bool
    let candidates: [MsimeCandidate]

    /// 有组字或候选（包括上屏后的联想）。
    var active: Bool {
        !editingText.isEmpty || !(phrasePrefix ?? "").isEmpty || !conversion.isEmpty || !candidates.isEmpty
    }

    /// 高亮的候选在整张候选表里的位置。
    var highlighted: Int? { candidates.first(where: \.highlighted)?.id.index }
    /// 这一页画出来的候选（去掉占位行）
    var visible: [MsimeCandidate] { candidates.filter { !$0.hidden } }
}

private struct MsimeTransition: Decodable {
    /// 这次上屏是在哪个方案、哪种本地模式里出的（两次上屏之间加空格要用）
    struct Context: Decodable {
        let scheme: Int
        let localMode: String
        /// 这次上屏要不要简转繁（照它出来时的模式）
        let scriptConversion: Bool
    }
    let handled: Bool
    let commit: String?
    /// 快捷短语指定的光标后文本：上屏后光标退回它前面
    let commitCursorSuffix: String?
    let commitContext: Context?
    let view: MsimeView
}

/// msime_client_candidate_range 的回复：从 start 起的一段候选，id 能交给 select_any_candidate。
private struct MsimeCandidateRange: Decodable {
    let generation: UInt64
    let total: Int
    let candidates: [MsimeCandidate]
}

final class MsimeSession {

    private let handle: UInt64
    private var view: MsimeView
    /// 建会话时 MsimeHost 的代次（MsimeHost.generation）
    let hostGeneration = MsimeHost.shared.generation
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    /// options：MsimeHost 准备好的 HostOptions。
    init(options: Data) throws {
        // phrase_preedit：长句分段选时，选好的那段先留在组字区（view.phrase_prefix），整句打完一起上屏
        var document = try JSONSerialization.jsonObject(with: options) as? [String: Any] ?? [:]
        document["phrase_preedit"] = true
        // quick_phrase_candidates：打的正好是快捷短语的编码时，短语混进普通候选（照水杉 macOS 宿主）
        document["quick_phrase_candidates"] = true
        let request = try JSONSerialization.data(withJSONObject: document)
        view = try MsimeCall.withBytes(request) { bytes, count in
            try Self.decode(MsimeView.self, msime_client_create(bytes, count))
        }
        handle = view.session
        // 每页个数：6 个（候选窗是 6 列的宽度）
        apply(msime_client_set_candidate_page_size(handle, 6))
        _ = transition(msime_client_focus(handle, true))
    }

    deinit {
        cancelSettle()
        msime_client_string_free(msime_client_destroy(handle))
    }

    /// 有组字、候选或补上没送出的后半个：这时不重建会话。
    var composing: Bool { view.active || pendingClosing != nil }

    // MARK: - 按键

    /// 正在处理的标点键（符号自动补全看它决定补不补、引号要不要改回前半个）。
    private var punctuationKey: UInt8?

    /// preceding：光标前一个字（Unicode 标量，0 是不知道），水杉判断 3.14 这类数字后的标点用。
    func key(_ key: UInt32, modifiers: UInt32, preceding: UInt32) -> Snapshot? {
        // 带 ⌃⌥⌘ 的组合键交还给应用（组字中也是：⌘C 之类不该吃掉）
        if modifiers & UInt32(WOTYPE_MOD_CONTROL | WOTYPE_MOD_OPTION | WOTYPE_MOD_COMMAND) != 0 {
            return snapshot(handled: false)
        }
        noteKey()
        // 有的应用不调 activateServer（VS Code、Safari 地址栏），会话还停在上一个输入框失去焦点的状态：先给它焦点
        if !view.focused {
            setFocused(true)
        }
        let shift = modifiers & UInt32(WOTYPE_MOD_SHIFT) != 0
        updateCapsLock(modifiers & UInt32(WOTYPE_MOD_CAPSLOCK) != 0)
        if raw != nil { return rawKey(key, modifiers: modifiers) }
        let listed = !view.candidates.isEmpty
        let skip = autoClosed
        autoClosed = nil
        // 照微信：展开时 = 就是 ↓、- 就是 ↑
        if expanded, let grid = gridKey(key == 0x3D && !shift ? UInt32(WOTYPE_KEY_DOWN)
                                        : key == 0x2D ? UInt32(WOTYPE_KEY_UP) : key) {
            return grid
        }
        switch Int(key) {
        case WOTYPE_KEY_BACKSPACE:
            // 没在组字、只挂着补上的后半个：删左半个的同时把它也去掉（键交给应用删左半个）
            if !view.active, pendingClosing != nil {
                pendingClosing = nil
                return snapshot(handled: false)
            }
            return command(.backspace)
        case WOTYPE_KEY_RETURN: return command(shift ? .commitRawWithoutLearning : .commitRaw)
        case WOTYPE_KEY_ESCAPE: return command(.cancel)
        case WOTYPE_KEY_DELETE: return command(.deleteForward)
        case WOTYPE_KEY_TAB:
            // 先结束组字再把 Tab 交给应用（不让组字区、补上的后半个留在原来的输入框里）
            return command(.finishComposition, handled: false)
        case WOTYPE_KEY_LEFT: return arrow(backwards: true)
        case WOTYPE_KEY_RIGHT: return arrow(backwards: false)
        case WOTYPE_KEY_UP: return listed ? command(.previousCandidate) : snapshot(handled: false)
        case WOTYPE_KEY_DOWN:
            // 按 ↓ 展开更多候选，高亮跳到第二行（照微信）
            return listed ? expandDown() : snapshot(handled: false)
        case WOTYPE_KEY_PAGE_UP: return listed ? page(-1) : snapshot(handled: false)
        case WOTYPE_KEY_PAGE_DOWN: return listed ? page(1) : snapshot(handled: false)
        case WOTYPE_KEY_HOME: return command(listed ? .firstCandidateOrHome : .moveHome)
        case WOTYPE_KEY_END: return command(listed ? .lastCandidate : .moveEnd)
        default: break
        }
        guard key >= 0x20, key < 0x7F else { return snapshot(handled: false) }
        let ascii = UInt8(key)
        let spelling = view.spellingSymbols.utf8.contains(ascii)
        if ascii == 0x20, !spelling {
            return command(.commitCandidate)
        }
        // = 和 - 照微信（展开时的在上面 gridKey 里）：= 就是 ↓，展开并跳到第二行；
        // - 在打开过网格以后没反应，之前（和 + 一样）进原样输入。只有联想候选、没在打拼音时 - 还是往前翻
        if listed, !spelling, ascii == UInt8(ascii: "=") {
            return expandDown()
        }
        // . 和 @ 也进原样输入（照旧万象：网址、邮箱，@ 后面补全邮箱后缀，和万象一样）。水杉自己的 @ 邮箱模式
        // （@ 是它的拼写符号）原样排第一，不照微信，不用它
        let rawSymbol = ascii == UInt8(ascii: "+") || ascii == UInt8(ascii: ".") || ascii == UInt8(ascii: "-") && !navigated
        if listed, !spelling && rawSymbol || ascii == UInt8(ascii: "@"), !view.editingText.isEmpty {
            raw = RawInput(base: (view.phrasePrefix ?? "") + view.editingText, symbol: Character(Unicode.Scalar(ascii)))
            expanded = false
            return snapshot(handled: true)
        }
        if listed, !spelling, ascii == UInt8(ascii: "-") {
            return navigated ? snapshot(handled: true) : page(-1)
        }
        // 数字选的是画出来的候选：按宽度分行时是显示的这一行（水杉的固定分页和这一行对不上）
        if listed, !spelling, (0x31...0x39).contains(ascii) {
            if adaptive { refreshRow() }
            if expanded { refreshGrid() }
            let shown: [MsimeCandidate] = expanded
                ? (gridItems.isEmpty ? [] : Array(gridItems[gridRowRange(gridRow(of: gridCursor))]))
                : adaptive ? row : view.visible
            let slot = Int(ascii - 0x31)
            guard shown.indices.contains(slot) else { return snapshot(handled: true) }
            return transition(msime_client_select_any_candidate(handle, shown[slot].id.generation, shown[slot].id.index))
        }
        // 以词定字：候选窗开着时 [ 取高亮候选的第一个字，] 取最后一个字（照水杉 macOS 宿主的 wordCharacterClaimsEvent，
        // 水杉的 word_character 默认用方括号）。这时 [ ] 不当标点
        if listed, !spelling, ascii == UInt8(ascii: "[") || ascii == UInt8(ascii: "]") {
            guard let id = view.candidates.first(where: \.highlighted)?.id else { return snapshot(handled: true) }
            return transition(msime_client_select_edge(handle, id.generation, id.index, ascii == UInt8(ascii: "[") ? 0 : 1))
        }
        let isLetter = (0x41...0x5A).contains(ascii) || (0x61...0x7A).contains(ascii)
        let isDigit = (0x30...0x39).contains(ascii)
        // 大写锁定开着、没在组字时，大写字母交给应用（照水杉的 MSIMECapsLockFreshUppercaseBypass）
        if capsLock, !shift, (0x41...0x5A).contains(ascii), !view.active {
            return snapshot(handled: false)
        }
        if isLetter || isDigit || spelling {
            return transition(msime_client_character(handle, ascii, shift))
        }
        // 标点
        punctuationKey = ascii
        defer { punctuationKey = nil }
        // 紧跟在自动补上的后半个后面再按出同一个后半个：跨过去，不再出一个（照水杉的 PairedPunctuation 跟踪）
        if let skip, !view.active, Self.closingKeys[ascii] == skip {
            return snapshot(handled: true)
        }
        // 没有组字时带上光标前的字：数字后面的 . : 原样输出（3.14、12:30）
        if !view.active, preceding != 0 {
            return transition(msime_client_punctuation_with_context(handle, ascii, preceding))
        }
        let typed = transition(msime_client_character(handle, ascii, shift))
        // 组字中 character 不收的标点（英文模式下的 . 等）：先结束组字再出标点
        if typed?.handled == false, view.active {
            return transition(msime_client_punctuation(handle, ascii))
        }
        return typed
    }

    /// ← →：按音节移拼音里的光标（水杉的 MOVE_*_SEGMENT），候选跟着变成光标前那段的。
    /// 照水杉运行时的 caret_edge_candidate_shortcut：高亮在首选时 ← 移光标，→ 没到末尾移光标、
    /// 到了末尾选下一个；高亮不在首选时只移候选。
    private func arrow(backwards: Bool) -> Snapshot? {
        guard view.active || pendingClosing != nil else { return snapshot(handled: false) }
        if !view.candidates.isEmpty, view.conversion.isEmpty {
            let edits = view.highlighted == 0 && (backwards || view.caretPosition < view.editingText.utf8.count)
            // 这一行最后一个再按 →：展开，高亮留在它上面（照微信，微信中间还停一下工具图标，WoType 没有）；
            // 后面没有了就不动
            if !edits, !backwards, adaptive {
                refreshRow()
                if !row.isEmpty, rowCursor == row.count - 1 {
                    guard rowStart + row.count < rowTotal else { return snapshot(handled: true) }
                    expanded = true
                    navigated = true
                    gridFirstRow = 0
                    return snapshot(handled: true)
                }
            }
            if !edits {
                return command(backwards ? .previousCandidate : .nextCandidate)
            }
        }
        return command(backwards ? .moveLeftSegment : .moveRightSegment)
    }

    func select(_ index: Int) -> Snapshot? {
        // 原样输入：上屏点的那个
        if raw != nil {
            raw?.highlight(index)
            return rawKey(0x20, modifiers: 0)
        }
        if expanded {
            refreshGrid()
            let shown = gridVisible.items
            guard index >= 0, index < shown.count else { return snapshot(handled: false) }
            let id = shown[shown.startIndex + index].id
            return transition(msime_client_select_any_candidate(handle, id.generation, id.index))
        }
        let shown = adaptive && !row.isEmpty ? row : view.visible
        guard shown.indices.contains(index) else { return snapshot(handled: false) }
        let id = shown[index].id
        return transition(msime_client_select_any_candidate(handle, id.generation, id.index))
    }

    func page(_ delta: Int32) -> Snapshot? {
        if adaptive, !view.candidates.isEmpty {
            return moveRow(forward: delta > 0)
        }
        if expanded {
            // 展开时一次滚过可见的几行
            refreshGrid()
            guard !gridItems.isEmpty else { return snapshot(handled: true) }
            let row = gridRow(of: gridCursor)
            return moveGrid(toRow: min(row + Int(delta) * Self.gridRows, gridRowStarts.count - 1))
        }
        return command(delta < 0 ? .previousPage : .nextPage)
    }

    /// commitPending：切中英文、切输入法、失去焦点前要上屏（水杉的 MSIME_FINISH_ON_FOCUS_LOSS）。
    func reset(commitPending: Bool) -> Snapshot? {
        if let raw {
            self.raw = nil
            return commitPending ? commitText(raw.text) : command(.cancel)
        }
        guard view.active || pendingClosing != nil else { return snapshot(handled: true) }
        return command(commitPending ? .finishOnFocusLoss : .cancel)
    }

    /// 输入框取得、失去焦点。取得焦点时水杉会读新装好的资源包（停顿重排的大模型）。
    func setFocused(_ focused: Bool) {
        Log.input.debug("水杉焦点 \(focused)")
        cancelSettle()
        cancelCloud()
        // 换了输入框：上一个输入框的状态不带过来（水杉取得焦点时也会丢掉旧组字）
        if focused {
            pendingClosing = nil
            autoClosed = nil
            expanded = false
            navigated = false
            raw = nil
        }
        _ = transition(msime_client_focus(handle, focused))
    }

    // MARK: - 候选翻译

    /// 不经过水杉上屏一段文字（候选翻译的译文）：先撤掉组字，挂着的后半个符号照样跟在后面送出。
    func commitText(_ text: String) -> Snapshot? {
        guard view.active else { return nil }
        cancelSettle()
        cancelCloud()
        guard let cancelled = try? Self.decode(MsimeTransition.self, msime_client_command(handle, MsimeCommand.cancel.rawValue))
        else { return nil }
        view = cancelled.view
        expanded = false
        navigated = false
        raw = nil
        // 两次上屏之间加空格要看上一次上屏是在哪个方案里出的：译文不是水杉出的，不拿它算
        lastCommitContext = nil
        return snapshot(handled: true, commit: pairing(text, handled: true) ?? text)
    }

    // MARK: - 中英文、大写锁定

    /// 单按 ⇧ 切到英文：英文模式下按键直接交给应用（照水杉 macOS 宿主），这里只把打到一半的字母原样上屏。
    func commitRaw() -> Snapshot? {
        if let raw {
            self.raw = nil
            return commitText(raw.text)
        }
        guard view.active || pendingClosing != nil else { return snapshot(handled: true) }
        return command(.commitRaw)
    }

    private var capsLock = false

    private func updateCapsLock(_ on: Bool) {
        guard on != capsLock else { return }
        capsLock = on
        msime_client_string_free(msime_client_set_caps_lock(handle, on))
    }

    // MARK: - 两次上屏之间加空格

    private var lastCommitContext: MsimeTransition.Context?

    /// 上屏之前问水杉：这次上屏前面要不要补一个空格（前一次上屏的末尾和这次的开头一个是汉字、一个是字母数字）。
    /// preceding 是光标前一个字，application 是应用的 bundle ID。返回要上屏的文字。
    func spacedCommit(_ text: String, preceding: UInt32, application: String) -> String {
        guard let context = lastCommitContext, !text.isEmpty else { return text }
        let request: [String: Any] = [
            "config": ["enabled": true, "excluded_apps": [String]()],
            "application": application,
            "context": ["scheme": context.scheme, "local_mode": context.localMode],
            "text": text,
            "preceding": preceding,
        ]
        struct Reply: Decodable {
            let enabled: Bool
            let text: String?
        }
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let reply = try? MsimeCall.withBytes(data, { bytes, count in
                  try MsimeCall.decode(Reply.self, msime_client_cross_commit_spacing(bytes, count), decoder: Self.decoder)
              }), reply.enabled, let spaced = reply.text else { return text }
        return spaced
    }

    // MARK: - 符号自动补全

    /// 补全的成对符号（照水杉的 MSIMEPunctuationPairs）
    private static let pairs = [
        "（": "）", "【": "】", "《": "》", "“": "”", "‘": "’", "〈": "〉", "「": "」", "『": "』", "〖": "〗",
    ]
    /// 水杉的引号一开一合交替；补全时每按一次都是新的一对，后半个改回前半个
    private static let reopenings = ["”": "“", "’": "‘", "」": "「", "』": "『"]
    /// 按哪个键会出这个后半个（跨过刚补上的后半个时用）
    private static let closingKeys: [UInt8: String] = [
        UInt8(ascii: ")"): "）", UInt8(ascii: "]"): "】", UInt8(ascii: ">"): "》",
        UInt8(ascii: "\""): "”", UInt8(ascii: "'"): "’",
    ]

    /// 补上还没送出的后半个：留在组字区末尾、光标前面，下一次上屏时跟在后面一起送出。
    private var pendingClosing: String?
    /// 刚随上屏送出的后半个：紧接着再按出它时跨过去。
    private var autoClosed: String?

    /// 上屏的文字过一遍补全：送出挂着的后半个，看这次是不是打开了新的一对。
    private func pairing(_ commit: String?, handled: Bool) -> String? {
        let pending = pendingClosing
        // 组字没了、也没上屏（Esc、把键交给应用）：挂着的后半个不能丢，单独送出
        guard var text = commit else {
            if let pending, !view.active {
                pendingClosing = nil
                return pending
            }
            return nil
        }
        guard Settings.shared.config.autoPair, !text.isEmpty else {
            if let pending {
                pendingClosing = nil
                return text + pending
            }
            return text
        }
        // 组字中按标点上屏的是「候选 + 标点」（nihao( → 你好（）：只看最后一个字
        var mark = text
        if punctuationKey != nil, let last = text.last {
            mark = String(last)
        }
        var opened: String?
        if pending == nil {
            if let key = punctuationKey, key == UInt8(ascii: "\"") || key == UInt8(ascii: "'"),
               let opening = Self.reopenings[mark] {
                text = String(text.dropLast()) + opening
                mark = opening
            }
            opened = Self.pairs[mark]
            // 书名号会嵌套（《 里面是〈）：补上的后半个引擎不知道，要告诉它这一对已经关上
            if opened != nil, mark == "《" || mark == "〈" {
                msime_client_string_free(msime_client_balance_paired_punctuation_after_auto_close(handle, UInt8(ascii: "<")))
            }
        }
        if let pending {
            text += pending
            autoClosed = pending
        }
        pendingClosing = opened
        return text
    }

    // MARK: - 按宽度分行（照水杉 macOS 宿主的 LayoutAdaptiveCandidates）

    /// 没展开时按宽度排：一行放得下几个放几个，长句不会把候选窗撑宽
    private var adaptive: Bool { !expanded }

    /// 数字键只有 1～9
    private static let rowLimit = 9
    /// 显示出来的那一行（高亮所在的行）。下面的位置都按画出来的候选数（占位行不算），不是水杉的序号
    private var row: [MsimeCandidate] = []
    private var rowStart = 0
    /// 高亮在这一行里的第几个
    private var rowCursor = 0
    /// 从第一个起取到的候选（去掉占位行）和每一行的起点，到高亮所在的行为止（翻到上一行用）
    private var rowItems: [MsimeCandidate] = []
    private var rowStarts: [Int] = [0]
    private var rowTotal = 0
    /// 上次用 set_display_page 报给水杉的（代次、这一行第一个候选的序号、个数）
    private var reportedRow: (UInt64, Int, Int)?
    /// 上次排的是哪一代候选（候选 id 里的代次：候选一变它就变，水杉靠它拒绝过期的选词）、高亮在哪：
    /// 没变就不再取候选、量宽度（同一个键里可能要用两次）
    private var rowFor: (generation: UInt64, highlighted: Int)?

    /// 从第一个候选起逐行贪心装填，找到高亮所在的那一行；报给水杉（二三候选键、翻译按看得见的这一行）。
    /// 一行最多 rowLimit 个，所以只取到高亮后面 rowLimit 个（再多一个，前面可能有一个占位行）：高亮那一行一定排得完。
    private func refreshRow() {
        let started = DispatchTime.now().uptimeNanoseconds
        defer { Log.input.debug("分行 \(Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6, format: .fixed(precision: 2)) ms") }
        let current = view.candidates.first(where: \.highlighted)?.id
        if let current, let last = rowFor, last.generation == current.generation, last.highlighted == current.index,
           !row.isEmpty {
            return
        }
        rowFor = nil
        row = []
        guard let highlighted = view.highlighted,
              let range = try? Self.decode(MsimeCandidateRange.self,
                                           msime_client_candidate_range(handle, 0, highlighted + Self.rowLimit + 1)) else { return }
        let items = range.candidates.filter { !$0.hidden }
        // 高亮落在占位行上时（还没来得及移开）当成它后面那一个
        guard let cursor = items.firstIndex(where: { $0.id.index >= highlighted }) ?? items.indices.last else { return }
        let available = CandidateView.rowWidth, gap = CandidateView.candidateGap
        var start = 0
        rowStarts = [0]
        while start < items.count {
            var end = start + 1
            var used = CandidateView.candidateWidth(items[start].text, number: 1, cloud: items[start].source == Self.cloudSource)
            while end < items.count, end - start < Self.rowLimit {
                let width = CandidateView.candidateWidth(items[end].text, number: end - start + 1,
                                                         cloud: items[end].source == Self.cloudSource)
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
        rowTotal = range.total - (range.candidates.count - items.count)
        if let current { rowFor = (current.generation, current.index) }
        guard let first = row.first else { return }
        let report = (range.generation, first.id.index, row.count)
        if reportedRow.map({ $0 != report }) ?? true {
            reportedRow = report
            let indices = row.map(\.id.index)
            indices.withUnsafeBufferPointer { buffer in
                msime_client_string_free(msime_client_set_display_page(handle, range.generation, buffer.baseAddress, buffer.count))
            }
        }
    }

    /// 翻到下一行、上一行：用水杉的上下一个候选把高亮挪过去（一行最多 9 个）。
    private func moveRow(forward: Bool) -> Snapshot? {
        refreshRow()
        guard let highlighted = view.highlighted, let last = row.last else { return snapshot(handled: true) }
        // 目标换成水杉的序号：下一行从这一行最后一个的后面起（中间的占位行由 skipPlaceholder 跳过），上一行取它的第一个
        let target: Int
        if forward {
            guard rowStart + row.count < rowTotal else { return snapshot(handled: true) }
            target = last.id.index + 1
        } else {
            guard let previous = rowStarts.last(where: { $0 < rowStart }) else { return snapshot(handled: true) }
            target = rowItems[previous].id.index
        }
        _ = highlighted
        return moveHighlight(to: target)
    }

    // MARK: - 展开更多候选：固定列的网格，长词跨列（列上下对齐），可见几行，上下滚动

    /// 可见几行
    private static let gridRows = 6
    private var expanded = false
    /// 展开时从第一个候选起取到的候选（去掉占位行）、每一行的起点
    private var gridItems: [MsimeCandidate] = []
    private var gridRowStarts: [Int] = []
    /// 每个候选在它那一行里从第几列开始、占几列（上下换行时找同一列上的那个）
    private var gridSpans: [(left: CGFloat, right: CGFloat)] = []
    /// 可见的第一行、高亮在 gridItems 里的位置
    private var gridFirstRow = 0
    private var gridCursor = 0
    private var gridTotal = 0

    /// 候选窗右边的 ∨ / ∧；展开时在第一行按 ↑ 或 - 收起。
    func toggleGrid() -> Snapshot? {
        if raw != nil { return snapshot(handled: true) }
        guard !view.candidates.isEmpty || expanded else { return snapshot(handled: false) }
        expanded.toggle()
        gridFirstRow = 0
        return snapshot(handled: true)
    }

    /// 横排时按 = 或 ↓：展开，高亮跳到第二行同一列（照微信），记下这次输入打开过网格。
    /// 后面没有更多候选时不展开（只有一行也切成网格的话，候选窗样式一变大一点，看起来抖一下）
    private func expandDown() -> Snapshot? {
        guard !view.candidates.isEmpty else { return snapshot(handled: false) }
        refreshRow()
        guard row.isEmpty || rowStart + row.count < rowTotal else { return snapshot(handled: true) }
        expanded = true
        navigated = true
        gridFirstRow = 0
        refreshGrid()
        guard expanded, !gridItems.isEmpty else { return snapshot(handled: true) }
        return moveGrid(toRow: gridRow(of: gridCursor) + 1)
    }

    // MARK: - 原样输入（照微信输入法的 - + 规则，docs/22）

    /// 打拼音途中按 - 或 + 进的原样输入，见 RawInput
    private var raw: RawInput?
    /// 这次输入用 = 或 ↓ 打开过网格：之后 - 是往上移（收起时没反应），不再进原样输入。输入结束才清掉
    private var navigated = false

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
            return commitText(text)
        case .finish(let text):
            raw = nil
            return commitText(text)?.passedThrough
        case .cancel:
            raw = nil
            return command(.cancel)
        case .exit:
            raw = nil
            return snapshot(handled: true)
        }
    }

    /// 展开时的方向键：← → 在一行里移，↑ ↓ 换到上下一行横向最近的那个；第一行再按 ↑ 收起。
    private func gridKey(_ key: UInt32) -> Snapshot? {
        refreshGrid()
        guard !gridItems.isEmpty else { return nil }
        let row = gridRow(of: gridCursor)
        switch Int(key) {
        case WOTYPE_KEY_LEFT:
            // 行首按 ← 到上一行最后一个，行尾按 → 到下一行第一个（移出可见范围就滚过去）
            guard gridCursor > 0 else { return snapshot(handled: true) }
            return moveHighlight(to: gridItems[gridCursor - 1].id.index)
        case WOTYPE_KEY_RIGHT:
            if gridCursor + 1 < gridItems.count { return moveHighlight(to: gridItems[gridCursor + 1].id.index) }
            return gridItems.count < gridTotal ? command(.nextCandidate) : snapshot(handled: true)
        case WOTYPE_KEY_DOWN:
            return moveGrid(toRow: row + 1)
        case WOTYPE_KEY_UP:
            if row == 0 { return toggleGrid() }
            return moveGrid(toRow: row - 1)
        default:
            return nil
        }
    }

    /// 展开时触控板、滚轮翻行：高亮挪到上下 rows 行同一列上的那个（移出可见范围就滚过去）。
    /// 和 ↑ 不一样，在第一行往上滑不收起。
    func scrollGrid(_ rows: Int) -> Snapshot? {
        guard raw == nil, expanded else { return snapshot(handled: true) }
        refreshGrid()
        guard !gridItems.isEmpty else { return snapshot(handled: true) }
        let target = gridRow(of: gridCursor) + rows
        guard target >= 0, target < gridRowStarts.count else { return snapshot(handled: true) }
        return moveGrid(toRow: target)
    }

    /// 高亮挪到 row 行里横向离现在最近的那个；没有那一行就不动。
    private func moveGrid(toRow row: Int) -> Snapshot? {
        let target = max(row, 0)
        guard target < gridRowStarts.count else { return snapshot(handled: true) }
        let center = (gridSpans[gridCursor].left + gridSpans[gridCursor].right) / 2
        let nearest = gridRowRange(target).min { a, b in
            abs((gridSpans[a].left + gridSpans[a].right) / 2 - center) < abs((gridSpans[b].left + gridSpans[b].right) / 2 - center)
        } ?? gridRowStarts[target]
        return moveHighlight(to: gridItems[nearest].id.index)
    }

    private func gridRow(of item: Int) -> Int {
        (gridRowStarts.lastIndex { $0 <= item }) ?? 0
    }

    private func gridRowRange(_ row: Int) -> Range<Int> {
        gridRowStarts[row]..<(row + 1 < gridRowStarts.count ? gridRowStarts[row + 1] : gridItems.count)
    }

    /// 从第一个候选起排进固定列的网格：每个候选按宽度占 1～整行那么多列，这一行剩下的列放不下就挪到下一行
    /// （行尾留空），列线上下对齐；高亮所在的行移出可见范围就滚过去。
    /// 一行最多 gridColumns 个，取到高亮后面可见几行能放下的最多个数，下面几行一定排得完。
    private func refreshGrid() {
        guard let highlighted = view.highlighted,
              let range = try? Self.decode(MsimeCandidateRange.self,
                                           msime_client_candidate_range(handle, 0, highlighted + CandidateView.gridColumnCount * Self.gridRows + 1)),
              !range.candidates.isEmpty else {
            expanded = false
            return
        }
        gridItems = range.candidates.filter { !$0.hidden }
        gridTotal = range.total - (range.candidates.count - gridItems.count)
        let columns = CandidateView.gridColumnCount
        gridRowStarts = []
        gridSpans = []
        var column = 0
        for (i, item) in gridItems.enumerated() {
            let span = CandidateView.gridSpan(item.text, cloud: item.source == Self.cloudSource)
            if i == 0 || column + span > columns {
                gridRowStarts.append(i)
                column = 0
            }
            gridSpans.append((CGFloat(column), CGFloat(column + span)))
            column += span
        }
        gridCursor = gridItems.firstIndex { $0.id.index >= highlighted } ?? gridItems.count - 1
        let row = gridRow(of: gridCursor)
        if row < gridFirstRow { gridFirstRow = row }
        if row >= gridFirstRow + Self.gridRows { gridFirstRow = row - Self.gridRows + 1 }
    }

    /// 可见的那几行：候选、每行几个、可见的第一个在 gridItems 里的位置
    private var gridVisible: (items: ArraySlice<MsimeCandidate>, rows: [Int], start: Int) {
        let last = min(gridFirstRow + Self.gridRows, gridRowStarts.count)
        guard gridFirstRow < last else { return ([], [], 0) }
        let rows = (gridFirstRow..<last).map { gridRowRange($0).count }
        let start = gridRowStarts[gridFirstRow]
        return (gridItems[start..<gridRowRange(last - 1).upperBound], rows, start)
    }

    /// 把高亮移到水杉序号为 target 的候选：一个一个移，直到到了为止（路上的占位行由 skipPlaceholder 跳过，
    /// 按固定步数移会多走一步）。
    private func moveHighlight(to target: Int) -> Snapshot? {
        var result: Snapshot?
        for _ in 0..<512 {
            guard let highlighted = view.highlighted, highlighted != target else { break }
            guard let next = command(highlighted < target ? .nextCandidate : .previousCandidate),
                  view.highlighted != highlighted else { break }
            result = next
        }
        return result ?? snapshot(handled: true)
    }

    // MARK: - 停顿后重排

    /// 停顿后大模型把候选重新排了：在主线程交回新快照，InputController 拿去更新候选窗。
    var onSettled: ((Snapshot) -> Void)?

    // MARK: - 停顿多久才算停下来（按打字节奏）

    /// 最近几个键之间的间隔（秒）。超过 pauseCap 的不算：那是停下来了，不是打字的节奏
    private var keyGaps: [TimeInterval] = []
    private var lastKeyTime: TimeInterval?
    private static let gapWindow = 8
    private static let pauseCap: TimeInterval = 1.5

    /// 每个键进来时记一下。
    private func noteKey() {
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastKeyTime, now - last < Self.pauseCap {
            keyGaps.append(now - last)
            if keyGaps.count > Self.gapWindow { keyGaps.removeFirst() }
        }
        lastKeyTime = now
    }

    /// 停多久算停下来：平时键间隔中位数的 2 倍，限在 0.3～0.8 秒；还没攒够间隔时 0.4 秒。
    /// 停顿重排要等真停下来：大模型排好的首选，下一个键按键时引擎不带大模型重新解码，又会退回去；
    /// 连打中途就排，首选会在两种写法之间来回跳（水杉 macOS 宿主固定 0.15 秒，连打时也会碰到）。见 docs/12
    private var pauseDelay: TimeInterval {
        guard keyGaps.count >= 3 else { return 0.4 }
        let median = keyGaps.sorted()[keyGaps.count / 2]
        return min(max(median * 2, 0.3), 0.8)
    }
    private static let pollInterval: TimeInterval = 0.03

    private var settleWork: DispatchWorkItem?
    /// 后台评分还没完成时的令牌。
    private var settleToken: UInt64?

    private struct SettleReply: Decodable {
        let status: String?
        let moved: Bool?
        let token: UInt64?
        let view: MsimeView?
    }

    /// 每次按键后重新计时；没有候选时不排。
    private func scheduleSettle() {
        cancelSettle()
        guard !view.candidates.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in self?.startSettle() }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + pauseDelay, execute: work)
    }

    private func cancelSettle() {
        settleWork?.cancel()
        settleWork = nil
        if let token = settleToken {
            // 已经离开原来的组字：告诉水杉不要这次的结果，只把模型还回去
            settleToken = nil
            msime_client_string_free(msime_client_poll_settled_rerank(handle, token, false))
        }
    }

    private func startSettle() {
        settleWork = nil
        handleSettle(msime_client_start_settled_rerank(handle))
    }

    private func pollSettle() {
        settleWork = nil
        guard let token = settleToken else { return }
        handleSettle(msime_client_poll_settled_rerank(handle, token, true))
    }

    private func handleSettle(_ raw: UnsafeMutablePointer<CChar>?) {
        guard let reply = try? Self.decode(SettleReply.self, raw) else {
            settleToken = nil
            return
        }
        // 带回的 view 要换上：候选的代次可能变了，选词时要用新的
        if let next = reply.view {
            view = next
        }
        switch reply.status {
        case "pending", "continue":
            // pending：后台在评分，过一会儿再问；continue：在会话线程上分片做，接着调
            if reply.status == "pending" { settleToken = reply.token ?? settleToken }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if reply.status == "pending" { self.pollSettle() } else { self.startSettle() }
            }
            settleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.pollInterval, execute: work)
        default:
            settleToken = nil
            Log.input.debug("停顿重排：\(reply.moved == true ? "换了顺序" : "没变", privacy: .public)")
            if reply.view != nil, reply.moved == true {
                onSettled?(snapshot(handled: true))
            }
        }
    }

    // MARK: - 云候选（照水杉 macOS 宿主的 synchronizeCloudCandidates）

    /// 水杉候选的来源码：云候选
    private static let cloudSource = 2
    /// 停多久才发请求：每个键都换掉还没发的请求（照水杉）；按打字节奏，最短 0.8 秒，
    /// 免得回答在打字间隙里插到第 2 位，把后面的候选往后挤
    private var cloudDelay: TimeInterval { max(pauseDelay, 0.8) }

    /// OnlineQuery 里用得到的字段；整份原文原样交回水杉。
    private struct OnlineQuery: Decodable {
        /// 自定义服务的请求描述（来源是 Google 时没有，地址问 msime_client_cloud_request_url）
        struct Request: Decodable {
            let url: String
            let method: String
            let headers: [String: String]?
            let bodyUtf8: String?
            let timeoutMs: Int?
            /// 水杉缓存里已经有的回包，不用再发
            let cachedResponse: String?
        }
        let cloudCandidates: Bool?
        let cloudEligible: Bool?
        let cloudRequest: Request?
    }

    private struct CloudReply: Decodable {
        let applied: Bool
        let view: MsimeView?
    }

    private var cloudWork: DispatchWorkItem?
    private var cloudTask: URLSessionDataTask?
    /// 已经排上、发出或者已经用上的那份查询；同一份不再发
    private var cloudQuery: NSDictionary?

    /// 现在这份组字的在线查询：原文（交回水杉）和对象（比较是不是同一份）。没开云候选、没在组字时为 nil
    private func onlineQuery() -> (data: Data, object: NSDictionary)? {
        guard Settings.shared.config.cloudCandidates, view.active,
              let data = try? MsimeCall.rawValue(msime_client_online_query(handle)),
              let object = try? JSONSerialization.jsonObject(with: data) as? NSDictionary else { return nil }
        return (data, object)
    }

    /// 每次按键后重新等 0.5 秒；在线查询到停下来、真要发的时候才问水杉（每个键少一次调用和解析）。
    /// 没开云候选、没在组字就全部取消。已经发出去的请求不在这里取消：到点时查询还是同一份就让它接着回来
    private func scheduleCloud() {
        guard Settings.shared.config.cloudCandidates, view.active else {
            cancelCloud()
            return
        }
        cloudWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.sendCloud() }
        cloudWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + cloudDelay, execute: work)
    }

    private func cancelCloud() {
        cloudWork?.cancel()
        cloudWork = nil
        cloudTask?.cancel()
        cloudTask = nil
        cloudQuery = nil
    }

    /// 停了 0.5 秒：水杉说这份能问云（是拼音、开关开着），而且和已经发出、已经用上的不是同一份，才发
    private func sendCloud() {
        cloudWork = nil
        guard let query = onlineQuery(),
              let parsed = try? Self.decoder.decode(OnlineQuery.self, from: query.data),
              parsed.cloudCandidates == true, parsed.cloudEligible == true else {
            cancelCloud()
            return
        }
        if cloudQuery == query.object { return }
        cloudTask?.cancel()
        cloudTask = nil
        cloudQuery = query.object
        let request: URLRequest?
        if let descriptor = parsed.cloudRequest {
            if let cached = descriptor.cachedResponse {
                finishCloud(query, body: Data(cached.utf8))
                return
            }
            request = CloudCandidates.request(url: descriptor.url, method: descriptor.method,
                                              headers: descriptor.headers ?? [:], body: descriptor.bodyUtf8,
                                              timeout: descriptor.timeoutMs.map { Double($0) / 1000 } ?? CloudCandidates.defaultTimeout)
        } else {
            let url = MsimeCall.withBytes(query.data) { bytes, count in
                try? Self.decode(String.self, msime_client_cloud_request_url(bytes, count))
            }
            request = url.flatMap { CloudCandidates.request(url: $0) }
        }
        // 拼不出合规的请求：这份查询不再试
        guard let request else { return }
        cloudTask = CloudCandidates.send(request) { [weak self] body in
            self?.finishCloud(query, body: body)
        }
    }

    /// 回包交给水杉解析；组字已经变了的回包不用（水杉自己也会拒绝过期的）。
    private func finishCloud(_ query: (data: Data, object: NSDictionary), body: Data?) {
        cloudTask = nil
        guard onlineQuery()?.object == query.object else { return }
        guard let body else {
            // 没连上、超时：留给下一次按键再试
            cloudQuery = nil
            return
        }
        let raw = MsimeCall.withBytes(query.data) { q, qCount in
            MsimeCall.withBytes(body) { b, bCount in
                msime_client_apply_cloud_response(handle, q, qCount, b, bCount)
            }
        }
        guard let reply = try? Self.decode(CloudReply.self, raw), reply.applied, let next = reply.view else {
            // 回包里没有能用的候选，或者本地候选已经不在了
            cloudQuery = nil
            Log.input.debug("云候选：回包没用上")
            return
        }
        view = next
        // 用上以后查询会变（换了代次），记下新的，免得再发一次
        cloudQuery = onlineQuery()?.object
        Log.input.debug("云候选：用上了")
        onSettled?(snapshot(handled: true))
    }

    /// 上一次高亮的序号：高亮落到占位行上时，按刚才移动的方向再挪一格
    private var lastHighlighted: Int?

    /// 水杉移高亮时不跳过不画出来的候选（☁ 等回答的那一格、画不出来的生僻字）；高亮停在上面就看不见了，
    /// 按刚才移动的方向接着挪，直到落在画得出来的候选上（生僻字常连成一串）。到头了就反过来挪。
    private func skipPlaceholder() {
        defer { lastHighlighted = view.highlighted }
        guard let start = view.candidates.first(where: \.highlighted), start.hidden else { return }
        var forward = start.id.index >= (lastHighlighted ?? 0)
        for _ in 0..<64 {
            guard let current = view.candidates.first(where: \.highlighted), current.hidden else { return }
            let command: MsimeCommand = forward ? .nextCandidate : .previousCandidate
            guard let moved = try? Self.decode(MsimeTransition.self, msime_client_command(handle, command.rawValue)) else { return }
            view = moved.view
            if view.highlighted == current.id.index {
                // 挪不动（到了头或尾）：换个方向
                if !forward { return }
                forward = false
            }
        }
    }

    // MARK: - 调用和转换

    /// 设置里开了繁体时转成繁体（水杉的 OpenCC s2t 表，按词转：头发 → 頭髮）；没开或转不了时原样返回。
    private static func traditional(_ text: String) -> String {
        guard Settings.shared.config.traditional, !text.isEmpty else { return text }
        let bytes = Array(text.utf8)
        guard let converted = msime_client_simplified_to_traditional(bytes, bytes.count) else { return text }
        defer { msime_client_string_free(converted) }
        return String(cString: converted)
    }

    private func command(_ command: MsimeCommand, handled: Bool? = nil) -> Snapshot? {
        transition(msime_client_command(handle, command.rawValue), handled: handled)
    }

    /// handled 给了就用它，不用水杉回的（Tab：结束组字后照样交给应用）。
    /// raw 是 @autoclosure：调用水杉也算在耗时里，和解码分开记
    private func transition(_ raw: @autoclosure () -> UnsafeMutablePointer<CChar>?, handled: Bool? = nil) -> Snapshot? {
        let started = DispatchTime.now().uptimeNanoseconds
        let reply = raw()
        let called = DispatchTime.now().uptimeNanoseconds
        guard let transition = try? Self.decode(MsimeTransition.self, reply) else { return nil }
        let decoded = DispatchTime.now().uptimeNanoseconds
        Log.input.debug("水杉 \(Double(called - started) / 1e6, format: .fixed(precision: 1)) ms，解码 \(Double(decoded - called) / 1e6, format: .fixed(precision: 1)) ms，handled=\(transition.handled) 组字=\(transition.view.editingText, privacy: .public)")
        view = transition.view
        skipPlaceholder()
        if transition.commit != nil {
            lastCommitContext = transition.commitContext
        }
        if !view.active {
            expanded = false
            navigated = false
            self.raw = nil
        }
        scheduleSettle()
        scheduleCloud()
        // 繁体：水杉只标出哪些能转，转换由宿主做（照水杉 macOS 宿主的 MSIMEChineseOutputString）
        var output = transition.commit
        if let text = output, transition.commitContext?.scriptConversion == true {
            output = Self.traditional(text)
        }
        let commit = pairing(output, handled: transition.handled) ?? ""
        // commit_cursor_suffix 是上屏文本末尾的一段，光标要退到它前面
        return snapshot(handled: handled ?? transition.handled, commit: commit,
                        caretBack: transition.commitCursorSuffix?.utf16.count ?? 0)
    }

    /// 回 {..., view} 的调用（设每页个数回 {deferred, view}）。
    private struct ViewReply: Decodable {
        let view: MsimeView
    }

    private func apply(_ raw: UnsafeMutablePointer<CChar>?) {
        if let reply = try? Self.decode(ViewReply.self, raw) {
            view = reply.view
        }
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, _ raw: UnsafeMutablePointer<CChar>?) throws -> Value {
        do {
            return try MsimeCall.decode(type, raw, decoder: decoder)
        } catch {
            Log.input.error("水杉返回出错：\(String(describing: error), privacy: .public)")
            throw error
        }
    }

    private func snapshot(handled: Bool, commit: String = "", caretBack: Int = 0) -> Snapshot {
        let tail = pendingClosing ?? ""
        if let raw {
            var result = raw.snapshot(handled: handled, commit: commit)
            result.tail = tail
            return result
        }
        let mode: Snapshot.Mode = expanded ? .grid : (view.active || !tail.isEmpty ? .list : .idle)
        var candidates = view.visible
        var first = candidates.first?.id.index ?? 0
        var cursor = candidates.firstIndex(where: \.highlighted) ?? 0
        var hasPrev = view.page > 0
        var hasNext = view.page + 1 < view.pageCount
        var columns = max(candidates.count, 1)
        if expanded {
            refreshGrid()
        }
        if adaptive, !candidates.isEmpty {
            refreshRow()
            if !row.isEmpty {
                candidates = row
                first = rowStart
                cursor = rowCursor
                hasPrev = rowStart > 0
                hasNext = rowStart + row.count < rowTotal
                columns = row.count
            }
        }
        var gridRowCounts: [Int] = []
        var gridColumnSpans: [Int] = []
        if expanded {
            let visible = gridVisible
            candidates = Array(visible.items)
            gridRowCounts = visible.rows
            gridColumnSpans = (visible.start..<visible.start + candidates.count).map {
                Int(gridSpans[$0].right - gridSpans[$0].left)
            }
            first = visible.start
            cursor = gridCursor - visible.start
            hasPrev = gridFirstRow > 0
            hasNext = gridFirstRow + Self.gridRows < gridRowStarts.count || gridItems.count < gridTotal
            columns = visible.rows.max() ?? 1
        }
        var result = Snapshot(
            handled: handled,
            commit: commit,
            mode: expanded ? .grid : mode,
            selected: view.scriptConversion ? Self.traditional(view.phrasePrefix ?? "") : view.phrasePrefix ?? "",
            remaining: view.conversion.isEmpty ? view.preedit : view.conversion,
            horizontal: true,
            columns: columns,
            first: first,
            cursor: cursor,
            total: expanded ? gridTotal : adaptive ? max(rowTotal, candidates.count) : view.pageCount * view.pageSize,
            hasPrev: hasPrev,
            hasNext: hasNext,
            candidates: candidates.map {
                Snapshot.Item(text: view.scriptConversion && $0.source != 13 && $0.source != 18 ? Self.traditional($0.text) : $0.text,
                              cloud: $0.source == Self.cloudSource)
            },
            caretBack: caretBack
        )
        result.tail = tail
        result.rows = gridRowCounts
        result.spans = gridColumnSpans
        // 候选翻译翻的是「已经选好的那段 + 高亮的候选」；只在打拼音时（联想出来的候选不翻）
        if !view.editingText.isEmpty, let highlighted = view.candidates.first(where: \.highlighted), !highlighted.hidden,
           let index = candidates.firstIndex(where: { $0.id.index == highlighted.id.index }) {
            result.highlight = result.selected + result.candidates[index].text
            result.highlightComplete = highlighted.code?.replacingOccurrences(of: "'", with: "") == view.editingText
        }
        // 拼音里的光标（← → 移过以后不在末尾）；整句改字时画的是改好的句子，光标放末尾
        if view.conversion.isEmpty {
            result.caret = String(view.preedit.unicodeScalars.prefix(view.preeditCaret)).utf16.count
        }
        return result
    }
}
