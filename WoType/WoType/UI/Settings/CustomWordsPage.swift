//
//  CustomWordsPage.swift
//  WoType
//
//  自定义词：上面一行加词（词语、拼音、添加按钮排成一行，拼音按词自动填好），
//  下面是我的词语：词语、拼音两列对齐，可以搜索、删除。
//  打字和语音共用（照 Arion 的词汇页 apps/desktop/ui/features/vocabulary/vocabulary.go@d2108fe，AGPL-3.0-only：
//  一个词条带着它的错误写法和键盘读音）：
//  - 有拼音的写 custom.tsv 并让引擎重新载入，打字时排第一个；拼音可以不填，那样只给语音用；
//  - 每个词都是语音输入的热词（VoiceVocabulary）；词下面一行是它的错误写法，划掉的灰色胶囊，
//    识别出来换成这个词；「＋ 错误写法」原地变成输入框，⏎ 保存，Esc 取消。
//  - 学到的词（改错学习，EditTracker）单独一块，和自己加的分开；两个列表都是固定高度、可以滚动。
//

import Cocoa

final class CustomWordsPage: SettingsPage, NSSearchFieldDelegate {

    private var words = CustomWords.load()
    private let wordField = NSTextField()
    private let pinyinField = NSTextField()
    private let searchField = NSSearchField()
    private lazy var addButton = SettingButton(title: "添加", symbol: "plus") { [weak self] in self?.add() }
    private let hint = SettingsKit.wrappingLabel(CustomWordsPage.hintText, size: 12, color: .secondaryLabelColor)
    /// 拼音是不是用户自己改过（改过就不再跟着词自动填）。
    private var pinyinEdited = false
    /// 列表那张卡片和它的标题，增删、搜索时只换这一块。
    private var listTitle: NSTextField?
    private var listCard: ScrollingCard?
    private var learnedTitle: NSTextField?
    private var learnedCard: ScrollingCard?
    /// 正在加错误写法的那个词
    private var addingVariant: String?

    private static let hintText = "拼音按词语自动填写，多音字请检查；英文术语可以不填拼音，只给语音输入用。按 ⏎ 添加。"

    /// 两个列表的高度（固定，多了滚动）
    private static let listHeight: CGFloat = 320
    private static let learnedHeight: CGFloat = 220

    override var rebuildsOnChange: Bool { false }
    override var pageTitle: String { "自定义词" }
    override var pageSubtitle: String { "人名、公司名、术语都可以加：打字时排在第一个，简拼也能打出来；语音输入时按你的写法写出来。" }

    override func build() -> [NSView] {
        wordField.placeholderString = "词语，比如：字节跳动"
        pinyinField.placeholderString = "拼音，自动填写"
        for field in [wordField, pinyinField] {
            field.delegate = self
            field.controlSize = .large
            field.font = .systemFont(ofSize: 13)
            field.bezelStyle = .roundedBezel
        }
        searchField.placeholderString = "搜索词语和错误写法"
        searchField.delegate = self
        searchField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        addButton.keyEquivalent = "\r"
        addButton.controlSize = .large
        updateAddButton()

        let header = SectionHeader(title: listTitleText, accessory: searchField)
        listTitle = header.subviews.first as? NSTextField
        let card = makeListCard()
        listCard = card

        let learnedHeader = SettingsKit.sectionTitle(learnedTitleText)
        learnedTitle = learnedHeader
        let learn = SettingsKit.row(title: "从我的修改中学习",
                                    detail: "记住你改过的写法，下次直接换。",
                                    help: "语音输入后你改了里面的词，就记住你的写法，下次识别出来直接换成你的写法。",
                                    icon: SettingsIcon(symbol: "graduationcap.fill", color: .systemGreen),
                                    accessory: SettingSwitch(isOn: config.voiceLearnEdits) { [weak self] on in
                                        self?.update { $0.voiceLearnEdits = on }
                                    })
        let learned = makeLearnedCard()
        learnedCard = learned

        return [
            SettingsKit.sectionTitle("添加词语"),
            SettingsKit.card([addRow()]),
            header,
            card,
            SettingsKit.sectionTitle("语音修改学习"),
            SettingsKit.card([learn]),
            learnedHeader,
            learned,
        ]
    }

    /// 词语、拼音两个输入框一样宽，添加按钮在最右边；下面一行提示。
    private func addRow() -> NSView {
        let fields = NSStackView(views: [wordField, pinyinField, addButton])
        fields.spacing = 10
        fields.distribution = .fill
        wordField.widthAnchor.constraint(equalTo: pinyinField.widthAnchor).isActive = true
        for field in [wordField, pinyinField] {
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        addButton.setContentHuggingPriority(.required, for: .horizontal)
        let column = NSStackView(views: [fields, hint])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        fields.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        return Self.padded(column)
    }

    /// 卡片里的一块内容，四周留出和别的设置行一样的边距。
    private static func padded(_ content: NSView) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: row.topAnchor, constant: 14),
            content.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -14),
            content.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: SettingsKit.rowInset),
            content.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -SettingsKit.rowInset),
        ])
        return row
    }

    /// 列表里的词：语音词库的词（新的在前），再加上只在 custom.tsv 里的（太长不能当热词的常用语）。
    private var terms: [(word: String, pinyin: String)] {
        let pinyin = Dictionary(words.map { ($0.word, $0.pinyin) }, uniquingKeysWith: { a, _ in a })
        let voice = VoiceVocabulary.shared.terms
        let voiceSet = Set(voice)
        return voice.map { ($0, pinyin[$0] ?? "") } + words.filter { !voiceSet.contains($0.word) }.map { ($0.word, $0.pinyin) }
    }

    private var listTitleText: String {
        let count = terms.count
        return count == 0 ? "我的词语" : "我的词语（\(count)）"
    }

    private func makeListCard() -> ScrollingCard {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let compact = query.replacingOccurrences(of: " ", with: "")
        let all = terms
        let shown = all.filter { term in
            query.isEmpty || term.word.lowercased().contains(query)
                || term.pinyin.replacingOccurrences(of: " ", with: "").contains(compact)
                || VoiceVocabulary.shared.variants(of: term.word).contains { $0.from.lowercased().contains(query) }
        }
        if shown.isEmpty {
            let text = all.isEmpty ? "还没有词语，在上面加一个试试。" : "没有找到「\(searchField.stringValue)」"
            let label = SettingsKit.wrappingLabel(text, size: 13, color: .secondaryLabelColor)
            return ScrollingCard(rows: [Self.padded(label)], height: Self.listHeight)
        }
        return ScrollingCard(rows: shown.map { term in
            WordRow(word: term.word, pinyin: term.pinyin,
                    variants: VoiceVocabulary.shared.variants(of: term.word),
                    adding: addingVariant == term.word,
                    actions: rowActions(term.word))
        }, height: Self.listHeight)
    }

    private var learnedTitleText: String {
        let count = VoiceVocabulary.shared.learned.count
        return count == 0 ? "学到的词" : "学到的词（\(count)）"
    }

    /// 学到的词：错误写法 → 正确写法，改过几次、纠正过几次，可以删。
    private func makeLearnedCard() -> ScrollingCard {
        let learned = VoiceVocabulary.shared.learned
        if learned.isEmpty {
            let label = SettingsKit.wrappingLabel("还没有学到的词。打开「从我的修改中学习」后，语音输入后你改了某个词，就会记在这里。",
                                                  size: 13, color: .secondaryLabelColor)
            return ScrollingCard(rows: [Self.padded(label)], height: Self.learnedHeight)
        }
        return ScrollingCard(rows: learned.map { entry in
            LearnedRow(entry: entry) { [weak self] in
                VoiceVocabulary.shared.removeLearned(id: entry.id)
                self?.reloadList()
            }
        }, height: Self.learnedHeight)
    }

    private func rowActions(_ word: String) -> WordRow.Actions {
        WordRow.Actions(
            delete: { [weak self] in self?.remove(word) },
            startVariant: { [weak self] in
                self?.addingVariant = word
                self?.reloadList()
            },
            addVariant: { [weak self] text in
                do {
                    try VoiceVocabulary.shared.addVariant(text, to: word)
                } catch VoiceVocabulary.EditError.conflict {
                    return "这个错误写法已属于其他词，先在那里移除"
                } catch {
                    return "请输入和词语不同的错误写法"
                }
                self?.addingVariant = nil
                self?.reloadList()
                return nil
            },
            cancelVariant: { [weak self] in
                self?.addingVariant = nil
                self?.reloadList()
            },
            removeVariant: { [weak self] id in
                VoiceVocabulary.shared.removeVariant(id: id)
                self?.reloadList()
            })
    }

    /// 只换两个列表的卡片（不打断正在输入的文本框），滚到的位置留着。
    private func reloadList() {
        listTitle?.stringValue = listTitleText
        learnedTitle?.stringValue = learnedTitleText
        listCard = replace(listCard, with: makeListCard())
        learnedCard = replace(learnedCard, with: makeLearnedCard())
    }

    private func replace(_ old: ScrollingCard?, with card: ScrollingCard) -> ScrollingCard? {
        guard let old, let stack = old.superview as? NSStackView,
              let index = stack.arrangedSubviews.firstIndex(of: old) else { return old }
        let offset = old.offset
        old.removeFromSuperview()
        stack.insertArrangedSubview(card, at: index)
        card.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -SettingsKit.contentInset * 2).isActive = true
        stack.layoutSubtreeIfNeeded()
        card.offset = offset
        return card
    }

    // MARK: - 增删

    private func add() {
        let word = wordField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let pinyin = CustomWords.normalizePinyin(pinyinField.stringValue)
        guard !word.isEmpty else { return }
        // 当热词：太长（常用长句）的不当，有拼音照样给键盘用；没拼音又当不了热词的不收
        let hotword = (try? VoiceVocabulary.shared.addTerm(word)) != nil
        if !hotword && pinyin.isEmpty {
            showHint("词语最多 64 个字，不能有控制字符；或者填上拼音只给打字用。", error: true)
            return
        }
        words.removeAll { $0.word == word }
        if !pinyin.isEmpty {
            words.insert(CustomWord(word: word, pinyin: pinyin), at: 0)
        }
        save()
        wordField.stringValue = ""
        pinyinField.stringValue = ""
        pinyinEdited = false
        showHint(Self.hintText, error: false)
        updateAddButton()
        view.window?.makeFirstResponder(wordField)
        reloadList()
    }

    private func remove(_ word: String) {
        words.removeAll { $0.word == word }
        VoiceVocabulary.shared.removeTerm(word)
        if addingVariant == word { addingVariant = nil }
        save()
        reloadList()
    }

    private func save() {
        do {
            try CustomWords.save(words)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "自定义词保存失败"
            alert.runModal()
        }
    }

    private func showHint(_ text: String, error: Bool) {
        hint.stringValue = text
        hint.textColor = error ? .systemRed : .secondaryLabelColor
    }

    private func updateAddButton() {
        addButton.isEnabled = !wordField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === wordField, !pinyinEdited {
            pinyinField.stringValue = CustomWords.guessPinyin(wordField.stringValue)
        } else if field === pinyinField {
            pinyinEdited = !pinyinField.stringValue.isEmpty
        } else if field === searchField {
            reloadList()
            return
        }
        if hint.textColor == .systemRed { showHint(Self.hintText, error: false) }
        updateAddButton()
    }
}

/// 我的词语里的一行：上面词语、拼音两列对齐，右边一个删除按钮；下面是错误写法和「＋ 错误写法」。
private final class WordRow: NSView, NSTextFieldDelegate {

    struct Actions {
        let delete: () -> Void
        let startVariant: () -> Void
        /// 返回出错的提示，nil 是加好了
        let addVariant: (String) -> String?
        let cancelVariant: () -> Void
        let removeVariant: (String) -> Void
    }

    /// 拼音那一列从哪开始（离左边）
    private static let pinyinColumn: CGFloat = 200
    /// 错误写法、添加按钮、输入框一样高，排在一行里对齐（Arion 的 chipHeight）
    static let chipHeight: CGFloat = 24

    private let actions: Actions
    private var variantField: NSTextField?
    private let error = NSTextField(labelWithString: "")

    init(word: String, pinyin: String, variants: [VocabularyEntry], adding: Bool, actions: Actions) {
        self.actions = actions
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let wordLabel = NSTextField(labelWithString: word)
        wordLabel.font = .systemFont(ofSize: 13, weight: .medium)
        wordLabel.lineBreakMode = .byTruncatingTail
        let pinyinLabel = NSTextField(labelWithString: pinyin.isEmpty ? "只用于语音" : pinyin)
        pinyinLabel.font = .systemFont(ofSize: 13)
        pinyinLabel.textColor = pinyin.isEmpty ? .tertiaryLabelColor : .secondaryLabelColor
        pinyinLabel.lineBreakMode = .byTruncatingTail
        let delete = SettingButton(title: "", symbol: "trash", onClick: actions.delete)
        delete.isBordered = false
        delete.contentTintColor = .secondaryLabelColor
        delete.toolTip = "删除「\(word)」"

        var chips: [NSView] = variants.map { entry in
            VariantChip(text: entry.from) { [actions] in actions.removeVariant(entry.id) }
        }
        if adding {
            let field = NSTextField()
            field.placeholderString = "错误写法"
            field.font = .systemFont(ofSize: 12)
            field.bezelStyle = .roundedBezel
            field.controlSize = .small
            field.delegate = self
            field.widthAnchor.constraint(equalToConstant: 140).isActive = true
            variantField = field
            chips.append(field)
        } else {
            chips.append(AddVariantButton(action: actions.startVariant))
        }
        let flow = FlowView(views: chips, spacing: 6)
        error.font = .systemFont(ofSize: 11)
        error.textColor = .systemRed
        error.isHidden = true

        for view in [wordLabel, pinyinLabel, delete, flow, error] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        wordLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pinyinLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let inset = SettingsKit.rowInset
        NSLayoutConstraint.activate([
            wordLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            wordLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            wordLabel.trailingAnchor.constraint(lessThanOrEqualTo: pinyinLabel.leadingAnchor, constant: -12),
            pinyinLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.pinyinColumn),
            pinyinLabel.firstBaselineAnchor.constraint(equalTo: wordLabel.firstBaselineAnchor),
            pinyinLabel.trailingAnchor.constraint(lessThanOrEqualTo: delete.leadingAnchor, constant: -12),
            delete.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset + 4),
            delete.centerYAnchor.constraint(equalTo: wordLabel.centerYAnchor),
            flow.topAnchor.constraint(equalTo: wordLabel.bottomAnchor, constant: 8),
            flow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            flow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            error.topAnchor.constraint(equalTo: flow.bottomAnchor, constant: 4),
            error.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            error.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset),
        ])
        errorBottom = error.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        flowBottom = flow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        flowBottom.isActive = true
    }

    private var errorBottom: NSLayoutConstraint!
    private var flowBottom: NSLayoutConstraint!

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let variantField { window?.makeFirstResponder(variantField) }
    }

    private func showError(_ text: String?) {
        error.stringValue = text ?? ""
        error.isHidden = text == nil
        flowBottom.isActive = text == nil
        errorBottom.isActive = text != nil
    }

    // ⏎ 保存，Esc 取消；输入框空着失去焦点就收起来
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let text = control.stringValue
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                actions.cancelVariant()
            } else {
                showError(actions.addVariant(text))
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            actions.cancelVariant()
            return true
        default:
            return false
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        if !error.isHidden { showError(nil) }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field === variantField,
              field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        // 等这一轮事件处理完再收（正在回调里，不能马上把输入框拿掉）
        DispatchQueue.main.async { [actions] in actions.cancelVariant() }
    }
}

/// 一个错误写法：灰底胶囊，文字划掉（这是要被换掉的写法），右边一个小 ×。
private final class VariantChip: NSView {
    private let onRemove: () -> Void

    init(text: String, onRemove: @escaping () -> Void) {
        self.onRemove = onRemove
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = WordRow.chipHeight / 2
        let label = NSTextField(labelWithAttributedString: NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor,
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            .strikethroughColor: NSColor.tertiaryLabelColor,
        ]))
        label.lineBreakMode = .byTruncatingTail
        let remove = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "移除 \(text)")!,
                              target: self, action: #selector(removeClicked))
        remove.isBordered = false
        remove.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        remove.contentTintColor = .tertiaryLabelColor
        remove.toolTip = "移除 \(text)"
        for view in [label, remove] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: WordRow.chipHeight),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
            remove.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 2),
            remove.centerYAnchor.constraint(equalTo: centerYAnchor),
            remove.widthAnchor.constraint(equalToConstant: 18),
            remove.heightAnchor.constraint(equalToConstant: 18),
            remove.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.12).cgColor
    }

    override var wantsUpdateLayer: Bool { true }

    @objc private func removeClicked() { onRemove() }
}

/// 「＋ 错误写法」：虚线边的安静按钮，点了原地变成输入框。
private final class AddVariantButton: NSView {
    private let action: () -> Void
    private let border = CAShapeLayer()

    init(action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        border.fillColor = nil
        border.lineWidth = 1
        border.lineDashPattern = [3, 2]
        layer?.addSublayer(border)
        let icon = NSImageView(image: NSImage(systemSymbolName: "plus", accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        icon.contentTintColor = .secondaryLabelColor
        let label = NSTextField(labelWithString: "错误写法")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        for view in [icon, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: WordRow.chipHeight),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel("添加错误写法")
        toolTip = "添加识别时常出现的错误写法，识别出来会换成这个词"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        border.frame = bounds
        border.path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: bounds.height / 2 - 0.5,
                             cornerHeight: bounds.height / 2 - 0.5, transform: nil)
        border.strokeColor = NSColor.separatorColor.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func mouseDown(with event: NSEvent) { action() }

    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// 一行排不下就换行的一排控件（错误写法多了会折到下一行）。
private final class FlowView: NSView {
    private let views: [NSView]
    private let spacing: CGFloat
    private var height: CGFloat = WordRow.chipHeight

    init(views: [NSView], spacing: CGFloat) {
        self.views = views
        self.spacing = spacing
        super.init(frame: .zero)
        for view in views { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height) }

    override func layout() {
        super.layout()
        var x: CGFloat = 0, y: CGFloat = 0
        for view in views {
            let size = view.fittingSize
            let width = min(size.width, bounds.width)
            if x > 0, x + width > bounds.width {
                x = 0
                y += WordRow.chipHeight + spacing
            }
            view.frame = NSRect(x: x, y: y, width: width, height: WordRow.chipHeight)
            x += width + spacing
        }
        let total = y + WordRow.chipHeight
        if total != height {
            height = total
            invalidateIntrinsicContentSize()
        }
    }
}

/// 固定高度的卡片，里面的行多了就滚动（自定义词、学到的词两个列表）。
final class ScrollingCard: CardView {
    private let scroll = OverlayScrollView()

    init(rows: [NSView], height: CGFloat) {
        super.init(frame: .zero)
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        let content = SettingsKit.card(rows, separatorInset: SettingsKit.rowInset)
        // 背景由外面这张卡片画，里面那张不画
        content.layer?.backgroundColor = nil
        (content as? CardView)?.transparent = true
        content.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        addSubview(scroll)
        layer?.masksToBounds = true
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: height),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 滚到的位置（换卡片时接着用）
    var offset: CGPoint {
        get { scroll.contentView.bounds.origin }
        set {
            scroll.contentView.scroll(to: newValue)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }
}

/// 学到的一个词：划掉的错误写法 → 正确写法，下面是改过几次、纠正过几次，右边删除。
private final class LearnedRow: NSView {
    init(entry: VocabularyEntry, onDelete: @escaping () -> Void) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let pair = NSMutableAttributedString(string: entry.from, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.secondaryLabelColor,
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            .strikethroughColor: NSColor.tertiaryLabelColor,
        ])
        pair.append(NSAttributedString(string: "  →  ", attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.tertiaryLabelColor,
        ]))
        pair.append(NSAttributedString(string: entry.to, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.labelColor,
        ]))
        let title = NSTextField(labelWithAttributedString: pair)
        title.lineBreakMode = .byTruncatingTail
        var counts = "改过 \(entry.uses) 次"
        if entry.recalls > 0 { counts += "，纠正过 \(entry.recalls) 次" }
        let detail = NSTextField(labelWithString: counts)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        let delete = SettingButton(title: "", symbol: "trash", onClick: onDelete)
        delete.isBordered = false
        delete.contentTintColor = .secondaryLabelColor
        delete.toolTip = "删除「\(entry.from) → \(entry.to)」"
        for view in [title, detail, delete] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let inset = SettingsKit.rowInset
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            title.trailingAnchor.constraint(lessThanOrEqualTo: delete.leadingAnchor, constant: -12),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            delete.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset + 4),
            delete.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
