//
//  CandidatePanel.swift
//  WoType
//
//  候选窗：一个不抢焦点的浮动面板，按会话快照画横排列表（万象的日期、时间格式是竖排）和下键展开的网格。
//  全进程一个，跟着当前输入框走；只在主线程用。
//
//  样子照微信输入法（screenshots/微信输入法.png）：紧凑、无描边、柔和阴影，序号和候选文字底部对齐，
//  左边缘对齐编辑区的字，右边一个 ∨ 展开更多候选。配色跟着设置里选的皮肤（Theme.Palette）。
//

import Cocoa

final class CandidatePanel {

    static let shared = CandidatePanel()

    /// 点了当前显示的第几个候选。
    var onSelect: ((Int) -> Void)?
    /// 点了右边的 ∨ / ∧：展开或收起网格。
    var onToggleGrid: (() -> Void)?
    /// 展开时触控板双指滑、鼠标滚轮滚了一格：-1 往上一行，1 往下一行。
    var onScroll: ((Int) -> Void)?
    /// 点了底下的译文条：上屏译文。
    var onTranslation: (() -> Void)?

    private let panel: NSPanel
    private let view = CandidateView()

    private init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: true)
        // 和鼠须管一样放在光标层下面一层：盖得住全屏应用和 Spotlight
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.cursorWindow)) - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // 阴影自己画（更柔、更散），窗口四周留出画阴影的边
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = view
        view.onSelect = { [weak self] index in self?.onSelect?(index) }
        view.onToggleGrid = { [weak self] in self?.onToggleGrid?() }
        view.onScroll = { [weak self] rows in self?.onScroll?(rows) }
        view.onTranslation = { [weak self] in self?.onTranslation?() }
    }

    var isVisible: Bool { panel.isVisible }

    /// 按快照显示在光标附近。caret 是编辑区开头的矩形（屏幕坐标，原点在左下）。
    func show(_ snapshot: Snapshot, caret: NSRect) {
        view.update(snapshot)
        let size = view.contentSize
        // 大小、位置没变就不再设（带阴影的窗口每次改大小都要重新合成，打字时每个键都会走到这里）
        if panel.contentRect(forFrameRect: panel.frame).size != size {
            panel.setContentSize(size)
        }
        let origin = Self.origin(for: size, caret: caret, margin: CandidateView.shadowMargin)
        if panel.frame.origin != origin {
            panel.setFrameOrigin(origin)
        }
        view.needsDisplay = true
        if !panel.isVisible {
            panel.orderFront(nil)
        }
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// 放在光标下方、左边缘对齐编辑区的字，靠近屏幕底部时翻到上方，左右不出屏幕。
    /// margin 是窗口四周留给阴影的透明边，不算进对齐。
    static func origin(for size: NSSize, caret: NSRect, margin: CGFloat = 0) -> NSPoint {
        let screen = NSScreen.screens.first { $0.frame.contains(caret.origin) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let gap: CGFloat = 4
        var origin = NSPoint(x: caret.minX - margin, y: caret.minY - gap - size.height + margin)
        if origin.y + margin < visible.minY {
            origin.y = caret.maxY + gap - margin
        }
        origin.x = min(max(origin.x, visible.minX - margin), visible.maxX - size.width + margin)
        origin.y = min(max(origin.y, visible.minY - margin), visible.maxY - size.height + margin)
        return origin
    }
}

// MARK: - 绘制

/// 候选窗的内容：自己排版、自己画，鼠标点候选、∨ 和网格的翻页箭头。
///
/// 排版在「面板本体」的坐标里做（左上角是原点），画和点的时候再加上四周留给阴影的边。
final class CandidateView: NSView {

    /// 窗口四周留给阴影的透明边。
    static let shadowMargin: CGFloat = 14

    var onSelect: ((Int) -> Void)?
    var onToggleGrid: (() -> Void)?
    var onScroll: ((Int) -> Void)?
    var onTranslation: (() -> Void)?

    private struct Cell {
        let index: Int
        let label: NSAttributedString?
        let text: NSAttributedString
        /// 候选文字的字体：序号按它的基线对齐
        let font: NSFont
        /// 整个可点的区域（列表里也是高亮框）。
        var frame: NSRect
        let highlighted: Bool
        /// 网格里给序号留的宽度：没有序号的行也留着，同一列的字上下对齐
        var labelSlot: CGFloat? = nil
        /// 网格里高亮框只包住内容（序号 + 字），不占满整列
        var highlightWidth: CGFloat? = nil
        /// 折行的候选（一行放不下）：文字画在这么大的框里
        var wrapSize: NSSize? = nil
        /// 纯学出来的词：字的右上角画小圆点
        var learned = false
    }

    private enum Control {
        case none
        /// 右边的 ∨（展开）或 ∧（收起）
        case toggle(expanded: Bool)
    }

    private var header: NSAttributedString?
    private var cells: [Cell] = []
    private var control = Control.none
    /// 网格行与行之间的分隔线（y 坐标）
    private var separators: [CGFloat] = []
    private var toggleRect: NSRect?
    /// 展开着（滚轮、触控板滑动只在展开时翻行）
    private var isGrid = false
    /// 触控板滑动攒下来的距离：攒够一行才挪一行
    private var scrollRemainder: CGFloat = 0
    /// 底下的译文行（和候选一样的一行）：分隔线的 y、译文（最多两行）、
    /// 右边那一列（⏎ 或一小段灰字提示），可点的区域（译文能上屏时才有）
    private var translationLine: CGFloat?
    private var translationText: (text: NSAttributedString, frame: NSRect)?
    private var translationAccessory: TranslationAccessory?
    private var translationRect: NSRect?
    /// 鼠标在能上屏的译文行上：铺一层淡绿底
    private var translationHovered = false

    private enum TranslationAccessory {
        /// ⏎ 符号，画在 ∨ 那一列
        case symbol(NSRect)
        case hint(NSAttributedString, NSPoint)
    }
    /// 面板本体的大小（不含阴影边）
    private var bodySize = NSSize(width: 1, height: 1)

    /// 整个窗口的大小（含阴影边）。
    var contentSize: NSSize {
        NSSize(width: bodySize.width + Self.shadowMargin * 2, height: bodySize.height + Self.shadowMargin * 2)
    }

    // 排版尺寸
    private let padding = NSSize(width: 4, height: 4)
    private let cellInset = NSSize(width: 8, height: 4)
    private let labelGap: CGFloat = 5
    private let cellGap: CGFloat = 2
    private let headerGap: CGFloat = 2
    private let controlWidth: CGFloat = 24
    /// 网格每行上下留的空（比列表宽松，照微信输入法）
    private let gridRowInset: CGFloat = 7
    /// 网格的列数（和引擎的 GRID_COLS 一致）
    private static let gridColumns = 6

    /// 网格一列的宽度：序号 + 4 个汉字。固定的，不跟着这一屏的词变
    private var columnWidth: CGFloat {
        labelSlot + ceil(NSAttributedString(string: "汉汉汉汉", attributes: [.font: Theme.candidateFont]).size().width)
            + cellInset.width * 2
    }

    /// 序号占的宽度（没有序号的格子也留着，字才对得齐）
    private var labelSlot: CGFloat { ceil(label(8, highlighted: false).size().width) + labelGap }

    /// 面板的固定宽度：单行和展开的网格一样宽（照微信输入法），展开、收起、打字时都不跳
    private var fixedWidth: CGFloat { padding.width * 2 + columnWidth * CGFloat(Self.gridColumns) }

    // MARK: 给 MsimeSession 排横排的一行用（照水杉 macOS 宿主的自适应排版：按宽度放得下几个放几个）

    private static let measurer = CandidateView()

    /// 横排一行放候选的宽度（去掉内边距和 ∨）。
    static var rowWidth: CGFloat { measurer.rowWidth }

    /// 展开时的列数。
    static var gridColumnCount: Int { gridColumns }

    /// 展开时这个候选占几列（序号 + 字 + 内边距按列宽向上取整，最多一整行；再长就在一整行里折行）。量过的记下来。
    static func gridSpan(_ text: String, cloud: Bool) -> Int {
        let key = "\(cloud)\t\(text)"
        if let span = spans[key] { return span }
        let view = measurer
        let width = view.labelSlot + ceil(view.candidateText(Snapshot.Item(text: text, cloud: cloud), highlighted: false,
                                                              font: Theme.candidateFont).size().width)
            + view.cellInset.width * 2
        let span = min(max(Int(ceil((width - 0.5) / view.columnWidth)), 1), gridColumns)
        if spans.count >= 4096 { spans.removeAll(keepingCapacity: true) }
        spans[key] = span
        return span
    }
    private static var spans: [String: Int] = [:]

    /// 这段文字能不能用候选字体（连同系统的后备字体）画出来：有一个字没有字形（只能画成缺字方框）就不能。
    /// Unicode 扩展区的生僻字 macOS 自带字体大多没有；用户装了覆盖它们的字体以后会自动能画。按字记下结果。
    static func canDisplay(_ text: String) -> Bool {
        for scalar in text.unicodeScalars where scalar.value >= 0x2E80 {
            if let known = glyphs[scalar.value] {
                if !known { return false }
                continue
            }
            let ok = hasGlyph(scalar)
            glyphs[scalar.value] = ok
            if !ok { return false }
        }
        return true
    }
    private static var glyphs: [UInt32: Bool] = [:]

    private static func hasGlyph(_ scalar: Unicode.Scalar) -> Bool {
        // emoji 的变体选择符、组合符号本身不画
        if scalar.properties.isVariationSelector || scalar.properties.generalCategory == .nonspacingMark { return true }
        let string = String(Character(scalar)) as NSString
        let font = CTFontCreateForString(Theme.candidateFont as CTFont, string as CFString, CFRange(location: 0, length: string.length))
        // 系统找不到字体时会退到 LastResort，那里的字形就是缺字方框
        if (CTFontCopyPostScriptName(font) as String) == "LastResort" { return false }
        var characters = [UniChar](repeating: 0, count: string.length)
        string.getCharacters(&characters, range: NSRange(location: 0, length: string.length))
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        return CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count)
    }
    private var rowWidth: CGFloat { fixedWidth - padding.width * 2 - controlWidth }

    /// 候选格子之间的空隙。
    static var candidateGap: CGFloat { measurer.cellGap }

    /// 一个候选格子（序号 + 字 + 内边距）的宽度；number 是 nil 时不画序号。每键都要量一排，量过的记下来（字体固定，不会变）。
    static func candidateWidth(_ text: String, number: Int?, cloud: Bool = false) -> CGFloat {
        let key = "\(number ?? 0)\t\(cloud)\t\(text)"
        if let width = widths[key] { return width }
        let view = measurer
        let width = view.cellSize(label: number.map { view.label($0, highlighted: false) },
                                  text: view.candidateText(Snapshot.Item(text: text, cloud: cloud), highlighted: false,
                                                           font: Theme.candidateFont)).width
        if widths.count >= 4096 { widths.removeAll(keepingCapacity: true) }
        widths[key] = width
        return width
    }
    private static var widths: [String: CGFloat] = [:]

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(_ snapshot: Snapshot) {
        header = makeHeader(snapshot)
        isGrid = snapshot.mode == .grid
        if !isGrid { scrollRemainder = 0 }
        switch snapshot.mode {
        case .grid:
            // 网格不放 ∧、也不放翻页箭头（照微信输入法）：Esc 或在第一行按 ↑ 收起，
            // 翻屏用 ↓、- =、PageUp/PageDown，或者触控板双指滑、鼠标滚轮
            control = .none
        default:
            // 这一页放不下全部候选时才有 ∨
            control = snapshot.total > snapshot.candidates.count ? .toggle(expanded: false) : .none
        }
        separators = []
        switch snapshot.mode {
        case .grid:
            layoutGrid(snapshot)
        case .list where snapshot.horizontal:
            layoutRow(snapshot)
        default:
            layoutColumn(snapshot)
        }
        layoutTranslation(snapshot.translation)
    }

    /// 候选翻译的译文行：接在候选下面，一条细线隔开，样子照候选的一行——译文从序号那一列开始（和候选窗里的拼音对齐），
    /// 右边 ∨ 那一列放 ⏎（能上屏时）或一小段灰字（只翻了一段、失败）。行高和上面的行一样。
    private func layoutTranslation(_ bar: CandidateTranslator.Bar?) {
        translationLine = nil
        translationText = nil
        translationAccessory = nil
        translationRect = nil
        guard let bar else {
            translationHovered = false
            return
        }
        // 网格：分隔线落在最后一行的下沿，上下留网格行的空；列表：上下和候选行一样（外边距 + 格子内边距）
        let line = isGrid ? bodySize.height - padding.height : bodySize.height
        let inset = isGrid ? gridRowInset : padding.height + cellInset.height
        let font = Theme.candidateFont
        let secondary: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.secondaryText]
        let hintAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: Theme.secondaryText,
        ]
        let message: NSAttributedString
        var hint: String?
        switch bar.state {
        case .translating:
            message = NSAttributedString(string: "翻译中…", attributes: secondary)
        case .done(let text):
            message = NSAttributedString(string: text, attributes: bar.complete
                ? [.font: font, .foregroundColor: Theme.text] : secondary)
            if !bar.complete { hint = "选完整句再翻译" }
        case .failed(let reason):
            message = NSAttributedString(string: reason, attributes: secondary)
            hint = "⌃ 重试"
        }
        let textX = padding.width + cellInset.width
        // 竖排的候选窗窄：译文放不下时加宽，最多和横排一样宽
        var width = bodySize.width
        var accessoryWidth: CGFloat = bar.committable != nil ? controlWidth : 0
        var hintText: NSAttributedString?
        if let hint {
            let text = NSAttributedString(string: hint, attributes: hintAttributes)
            hintText = text
            accessoryWidth = ceil(text.size().width) + cellInset.width * 2
        }
        let needed = textX + ceil(message.size().width) + max(accessoryWidth, cellInset.width) + padding.width
        if needed > width { width = min(needed, max(fixedWidth, width)) }
        let right = width - padding.width
        let (text, size) = wrapped(message, width: right - max(accessoryWidth, cellInset.width) - textX, lines: 2)
        let y = line + inset
        translationLine = line
        translationText = (text, NSRect(x: textX, y: y, width: size.width, height: size.height))
        let firstLine = NSRect(x: 0, y: y, width: 0, height: ceil(font.ascender - font.descender + font.leading))
        if let hintText {
            let hintSize = hintText.size()
            translationAccessory = .hint(hintText, NSPoint(x: right - cellInset.width - ceil(hintSize.width),
                                                           y: firstLine.midY - hintSize.height / 2))
        } else if bar.committable != nil {
            translationAccessory = .symbol(NSRect(x: right - controlWidth, y: firstLine.minY,
                                                  width: controlWidth, height: firstLine.height))
        }
        let bottom = y + size.height + inset + (isGrid ? padding.height : 0)
        if bar.committable != nil {
            translationRect = NSRect(x: 0, y: line, width: width, height: bottom - line)
        } else {
            translationHovered = false
        }
        bodySize = NSSize(width: width, height: bottom)
    }

    private func makeHeader(_ snapshot: Snapshot) -> NSAttributedString? {
        // 编辑区在有的应用里看不到（或者被截断），候选窗里再显示一遍拼音；设置里可以关掉
        guard Settings.shared.config.showPinyinInPanel else { return nil }
        let text = snapshot.remaining
        if text.isEmpty { return nil }
        return NSAttributedString(string: text, attributes: [
            .font: Theme.preeditFont, .foregroundColor: Theme.secondaryText,
        ])
    }

    private func candidateText(_ item: Snapshot.Item, highlighted: Bool, font: NSFont) -> NSAttributedString {
        let color = highlighted ? Theme.highlightText : Theme.text
        let text = NSMutableAttributedString(string: item.text, attributes: [
            .font: font,
            .foregroundColor: color,
        ])
        // 图标：画在字前面，和字一样大、一样的颜色（万象的日期、时间候选，照微信的日历图标）
        if let name = item.icon,
           let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
               .withSymbolConfiguration(.init(pointSize: font.pointSize * 0.9, weight: .regular)
                   .applying(.init(paletteColors: [color]))) {
            let attachment = NSTextAttachment()
            attachment.image = symbol
            attachment.bounds = NSRect(x: 0, y: font.descender * 0.6, width: symbol.size.width, height: symbol.size.height)
            let icon = NSMutableAttributedString(attachment: attachment)
            icon.append(NSAttributedString(string: " ", attributes: [.font: font]))
            text.insert(icon, at: 0)
        }
        // 云候选：后面一个彩色云朵 Emoji，和本地候选分开（照水杉 macOS 宿主的 " ☁️"）
        if item.cloud {
            text.append(NSAttributedString(string: " ☁️", attributes: [
                .font: NSFont.systemFont(ofSize: font.pointSize * 0.8),
            ]))
        }
        return text
    }

    private func label(_ number: Int, highlighted: Bool) -> NSAttributedString {
        NSAttributedString(string: "\(number)", attributes: [
            .font: Theme.labelFont,
            .foregroundColor: highlighted ? Theme.highlightText.withAlphaComponent(0.85) : Theme.secondaryText,
        ])
    }

    private var headerHeight: CGFloat {
        guard let header else { return 0 }
        return ceil(header.size().height) + headerGap
    }

    private var headerWidth: CGFloat { header.map { ceil($0.size().width) + cellInset.width } ?? 0 }

    /// 一个格子（序号 + 文字）的大小。
    private func cellSize(label: NSAttributedString?, text: NSAttributedString) -> NSSize {
        let labelWidth = label.map { ceil($0.size().width) + labelGap } ?? 0
        let textSize = text.size()
        return NSSize(width: labelWidth + ceil(textSize.width) + cellInset.width * 2,
                      height: ceil(textSize.height) + cellInset.height * 2)
    }

    /// maxWidth：格子最宽多少，放不下时字的末尾用「…」截断（上屏的还是完整的词）。
    private func makeCell(_ snapshot: Snapshot, _ i: Int, _ item: Snapshot.Item,
                          maxWidth: CGFloat = .greatestFiniteMagnitude) -> (NSAttributedString?, NSAttributedString) {
        let highlighted = i == snapshot.cursor
        let l = snapshot.numbered ? label(i + 1, highlighted: highlighted) : nil
        var t = candidateText(item, highlighted: highlighted, font: Theme.candidateFont)
        let labelWidth = l.map { ceil($0.size().width) + labelGap } ?? 0
        t = truncated(t, to: maxWidth - labelWidth - cellInset.width * 2)
        return (l, t)
    }

    /// 横排：一行候选从左往右排，面板是固定宽度，∨ 固定在最右边；候选太长放不下时才变宽。
    private func layoutRow(_ snapshot: Snapshot) {
        cells = []
        var x = padding.width
        let top = padding.height + headerHeight
        var rowHeight: CGFloat = 0
        for (i, item) in snapshot.candidates.enumerated() {
            // 一行最多和固定宽度一样宽：一个候选就超过整行时截断（MsimeSession 已经按宽度分好行）
            let (l, t) = makeCell(snapshot, i, item, maxWidth: rowWidth)
            let size = cellSize(label: l, text: t)
            cells.append(Cell(index: i, label: l, text: t, font: Theme.candidateFont,
                              frame: NSRect(origin: NSPoint(x: x, y: top), size: size), highlighted: i == snapshot.cursor,
                              learned: item.learned))
            x += size.width + cellGap
            rowHeight = max(rowHeight, size.height)
        }
        for i in cells.indices { cells[i].frame.size.height = rowHeight }
        x -= cellGap
        let hasControl: Bool
        if case .toggle = control { hasControl = true } else { hasControl = false }
        let needed = x + (hasControl ? controlWidth : 0) + padding.width
        let width = max(fixedWidth, needed, headerWidth + padding.width * 2)
        _ = placeControl(x: width - padding.width - controlWidth, top: top, height: rowHeight)
        bodySize = NSSize(width: width, height: top + rowHeight + padding.height)
    }

    /// 竖排：一列候选，∨ 在最下面一行的右边。只有万象展开日期、时间格式时用。
    private func layoutColumn(_ snapshot: Snapshot) {
        cells = []
        let top = padding.height + headerHeight
        var y = top
        var width: CGFloat = 0
        for (i, item) in snapshot.candidates.enumerated() {
            // 竖排也封顶：长句不能把候选窗撑得比横排还宽
            let (l, t) = makeCell(snapshot, i, item, maxWidth: fixedWidth - padding.width * 2)
            let size = cellSize(label: l, text: t)
            cells.append(Cell(index: i, label: l, text: t, font: Theme.candidateFont,
                              frame: NSRect(origin: NSPoint(x: padding.width, y: y), size: size),
                              highlighted: i == snapshot.cursor, learned: item.learned))
            y += size.height
            width = max(width, size.width)
        }
        width = max(width, 110, headerWidth)
        for i in cells.indices { cells[i].frame.size.width = width }
        let controlHeight = placeControl(x: padding.width + width - controlWidth, top: y, height: 20) > 0 ? 20 : 0
        bodySize = NSSize(width: width + padding.width * 2, height: y + CGFloat(controlHeight) + padding.height)
    }

    /// 网格（下键或 ∨ 展开），照微信输入法：各列等宽，只有光标所在行带序号，
    /// 别的行在序号的位置留空，同一列的字上下对齐；行与行之间一条细线。
    /// 展开：固定列的网格，按 MsimeSession 分好的行和每个候选占的列数摆，列线上下对齐；长词跨几列，
    /// 比一整行还宽时在整行里折行（最多 maxWrapLines 行，再多才截断）。序号只标在高亮所在的行。
    private func layoutGrid(_ snapshot: Snapshot) {
        cells = []
        let font = Theme.candidateFont
        let labelSlot = self.labelSlot
        let columnWidth = self.columnWidth
        let rows = snapshot.rows.isEmpty ? [snapshot.candidates.count] : snapshot.rows
        let top = padding.height + headerHeight
        var y = top
        var index = 0
        separators = []
        for (r, count) in rows.enumerated() {
            if r > 0 { separators.append(y) }
            let cursorRow = (index..<index + count).contains(snapshot.cursor)
            var rowCells: [Cell] = []
            var column = 0
            var textHeight: CGFloat = 0
            for slot in 0..<count where index + slot < snapshot.candidates.count {
                let i = index + slot
                let span = i < snapshot.spans.count ? snapshot.spans[i] : 1
                let cellWidth = columnWidth * CGFloat(span)
                let maxTextWidth = cellWidth - labelSlot - cellInset.width * 2
                let highlighted = i == snapshot.cursor
                let l = cursorRow ? label(slot + 1, highlighted: highlighted) : nil
                var t = candidateText(snapshot.candidates[i], highlighted: highlighted, font: font)
                var wrap: NSSize?
                if t.size().width > maxTextWidth {
                    // 占满一整行还放不下才会到这里（跨几列是按宽度算的）：折行
                    (t, wrap) = wrapped(t, width: maxTextWidth)
                }
                let size = wrap ?? NSSize(width: ceil(t.size().width), height: ceil(t.size().height))
                textHeight = max(textHeight, size.height)
                rowCells.append(Cell(index: i, label: l, text: t, font: font,
                                     frame: NSRect(x: padding.width + CGFloat(column) * columnWidth, y: y,
                                                   width: cellWidth, height: 0),
                                     highlighted: highlighted, labelSlot: labelSlot,
                                     highlightWidth: labelSlot + size.width + cellInset.width * 2, wrapSize: wrap,
                                     learned: snapshot.candidates[i].learned))
                column += span
            }
            let rowHeight = textHeight + gridRowInset * 2
            for c in rowCells.indices { rowCells[c].frame.size.height = rowHeight }
            cells += rowCells
            y += rowHeight
            index += count
        }
        let width = max(fixedWidth, headerWidth + padding.width * 2)
        _ = placeControl(x: 0, top: y, height: 0)
        bodySize = NSSize(width: width, height: y + padding.height)
    }

    /// 一个候选比整行还宽：按 width 折行，最多 maxWrapLines 行；再长就从末尾去字补「…」直到放得下。
    private func wrapped(_ text: NSAttributedString, width: CGFloat,
                         lines: Int = CandidateView.maxWrapLines) -> (NSAttributedString, NSSize) {
        let lineHeight = ceil(text.size().height)
        let maxHeight = lineHeight * CGFloat(lines) + 1
        func box(_ t: NSAttributedString) -> NSSize {
            let r = t.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                   options: [.usesLineFragmentOrigin, .usesFontLeading])
            return NSSize(width: ceil(min(r.width, width)), height: ceil(r.height))
        }
        var result = text
        var size = box(result)
        if size.height > maxHeight {
            let attributes = text.attributes(at: 0, effectiveRange: nil)
            var characters = Array(text.string)
            while characters.count > 1, size.height > maxHeight {
                characters.removeLast(max(1, characters.count / 20))
                result = NSAttributedString(string: String(characters) + "…", attributes: attributes)
                size = box(result)
            }
        }
        return (result, NSSize(width: width, height: size.height))
    }

    /// 折行最多几行
    private static let maxWrapLines = 3

    /// 宽度超过 maxWidth 时从末尾去掉字，补上「…」。
    private func truncated(_ text: NSAttributedString, to maxWidth: CGFloat) -> NSAttributedString {
        guard text.size().width > maxWidth, text.length > 1 else { return text }
        let attributes = text.attributes(at: 0, effectiveRange: nil)
        var characters = Array(text.string)
        while characters.count > 1 {
            characters.removeLast()
            let candidate = NSAttributedString(string: String(characters) + "…", attributes: attributes)
            if candidate.size().width <= maxWidth { return candidate }
        }
        return NSAttributedString(string: String(characters) + "…", attributes: attributes)
    }

    /// 放右边的控件（∨ / ∧），返回横排时占的宽度（没有控件时是 0）。
    private func placeControl(x: CGFloat, top: CGFloat, height: CGFloat) -> CGFloat {
        toggleRect = nil
        switch control {
        case .none:
            return 0
        case .toggle:
            toggleRect = NSRect(x: x, y: top, width: controlWidth, height: height)
            return controlWidth
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let margin = Self.shadowMargin
        let body = NSRect(x: margin, y: margin, width: bodySize.width, height: bodySize.height)
        let background = NSBezierPath(roundedRect: body, xRadius: Theme.cornerRadius, yRadius: Theme.cornerRadius)

        // 柔和的阴影，再铺底色
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = Theme.panelShadow
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        Theme.background.setFill()
        background.fill()
        NSGraphicsContext.restoreGraphicsState()
        // 浅色模式不描边；深色模式描一圈很淡的，免得和深色背景糊在一起
        Theme.border.setStroke()
        let outline = NSBezierPath(roundedRect: body.insetBy(dx: 0.5, dy: 0.5),
                                   xRadius: Theme.cornerRadius, yRadius: Theme.cornerRadius)
        outline.lineWidth = 1
        outline.stroke()

        NSGraphicsContext.saveGraphicsState()
        NSAffineTransform(transform: .init(translationByX: margin, byY: margin)).concat()

        header?.draw(at: NSPoint(x: padding.width + cellInset.width, y: padding.height))

        // 网格行间的细线，横跨整个面板
        Theme.gridSeparator.setFill()
        for y in separators {
            NSRect(x: 0, y: y - 0.5, width: bodySize.width, height: 1).fill()
        }

        for cell in cells {
            if cell.highlighted {
                var box = cell.frame
                if let width = cell.highlightWidth {
                    // 网格：高亮框只包住内容，上下离分隔线留一点
                    box = NSRect(x: box.minX, y: box.minY + 3, width: width, height: box.height - 6)
                }
                Theme.highlight.setFill()
                NSBezierPath(roundedRect: box, xRadius: Theme.highlightRadius, yRadius: Theme.highlightRadius).fill()
            }
            let x = cell.frame.minX + cellInset.width
            // 折行的从整块文字的上边算，序号对着第一行
            let textY = cell.frame.midY - (cell.wrapSize?.height ?? cell.text.size().height) / 2
            if let label = cell.label {
                // 序号和候选文字底部对齐（基线对齐）
                let labelY = textY + cell.font.ascender - Theme.labelFont.ascender
                label.draw(at: NSPoint(x: x, y: labelY))
            }
            let textX = x + (cell.labelSlot ?? cell.label.map { ceil($0.size().width) + labelGap } ?? 0)
            if let wrap = cell.wrapSize {
                cell.text.draw(with: NSRect(x: textX, y: textY, width: wrap.width, height: wrap.height),
                               options: [.usesLineFragmentOrigin, .usesFontLeading])
            } else {
                cell.text.draw(at: NSPoint(x: textX, y: textY))
            }
            if cell.learned {
                // 纯学出来的词：字的右上角一个小圆点，画在格子右边的留白里，不占宽度（按 ⇧⌫ 能删掉）
                let width = cell.wrapSize?.width ?? ceil(cell.text.size().width)
                (cell.highlighted ? Theme.highlightText.withAlphaComponent(0.85) : Theme.secondaryText).setFill()
                NSBezierPath(ovalIn: NSRect(x: textX + width + 1.5, y: textY + 2.5, width: 4, height: 4)).fill()
            }
        }

        if let line = translationLine {
            Theme.gridSeparator.setFill()
            NSRect(x: 0, y: line - 0.5, width: bodySize.width, height: 1).fill()
        }
        if translationHovered, let rect = translationRect {
            // 和高亮同色、很淡：这一行能点
            Theme.hoverTint.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: padding.width, dy: 3),
                         xRadius: Theme.highlightRadius, yRadius: Theme.highlightRadius).fill()
        }
        if let (text, frame) = translationText {
            text.draw(with: frame, options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
        switch translationAccessory {
        case .symbol(let rect)?:
            drawSymbol("return", in: rect, enabled: true)
        case .hint(let text, let origin)?:
            text.draw(at: origin)
        case nil:
            break
        }

        if case .toggle(let expanded) = control, let rect = toggleRect {
            drawSymbol(expanded ? "chevron.up" : "chevron.down", in: rect, enabled: true)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawSymbol(_ name: String, in rect: NSRect, enabled: Bool) {
        let color = enabled ? Theme.secondaryText : Theme.secondaryText.withAlphaComponent(0.35)
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            .applying(.init(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let size = image.size
        image.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                              width: size.width, height: size.height))
    }

    override func mouseDown(with event: NSEvent) {
        let raw = convert(event.locationInWindow, from: nil)
        let point = NSPoint(x: raw.x - Self.shadowMargin, y: raw.y - Self.shadowMargin)
        if let cell = cells.first(where: { $0.frame.contains(point) }) {
            onSelect?(cell.index)
        } else if toggleRect?.contains(point) == true {
            onToggleGrid?()
        } else if translationRect?.contains(point) == true {
            onTranslation?()
        }
    }

    // 鼠标移到能上屏的译文行上时铺淡底（面板不抢焦点，要 activeAlways 才收得到移动）
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let raw = convert(event.locationInWindow, from: nil)
        setTranslationHovered(translationRect?.contains(NSPoint(x: raw.x - Self.shadowMargin, y: raw.y - Self.shadowMargin)) == true)
    }

    override func mouseExited(with event: NSEvent) {
        setTranslationHovered(false)
    }

    private func setTranslationHovered(_ hovered: Bool) {
        guard hovered != translationHovered else { return }
        translationHovered = hovered
        needsDisplay = true
    }

    /// 展开时触控板双指滑、鼠标滚轮翻行：滚轮一格挪一行；触控板按滑过的距离，攒够一行高挪一行。
    /// 往下滑（内容往上走）看后面的行。
    override func scrollWheel(with event: NSEvent) {
        guard isGrid else { return super.scrollWheel(with: event) }
        if !event.hasPreciseScrollingDeltas {
            if event.scrollingDeltaY != 0 { onScroll?(event.scrollingDeltaY > 0 ? -1 : 1) }
            return
        }
        if event.phase == .began { scrollRemainder = 0 }
        scrollRemainder += event.scrollingDeltaY
        let step: CGFloat = 24
        while abs(scrollRemainder) >= step {
            onScroll?(scrollRemainder > 0 ? -1 : 1)
            scrollRemainder -= scrollRemainder > 0 ? step : -step
        }
    }
}
