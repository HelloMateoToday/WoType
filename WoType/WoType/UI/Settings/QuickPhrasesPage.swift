//
//  QuickPhrasesPage.swift
//  WoType
//
//  快捷短语：上面一行加短语（编码、短语、添加按钮排成一行），下面是我的快捷短语，可以搜索、编辑、删除。
//  照水杉的快捷短语：编码只能是英文字母，打编码时短语混进候选，⇧K 进快捷短语模式再打编码也行。
//

import Cocoa

final class QuickPhrasesPage: SettingsPage, NSSearchFieldDelegate {

    private var phrases = QuickPhrases.load()
    private let codeField = NSTextField()
    private let textField = NSTextField()
    private let searchField = NSSearchField()
    private lazy var addButton = SettingButton(title: "添加", symbol: "plus") { [weak self] in self?.add() }
    private let hint = SettingsKit.wrappingLabel(QuickPhrasesPage.hintText, size: 12, color: .secondaryLabelColor)
    /// 正在编辑的那条（点了列表里的铅笔，内容填回上面的输入框，添加按钮变成保存）
    private var editing: QuickPhrase?
    private var listTitle: NSTextField?
    private var listCard: ScrollingCard?

    private static let hintText = "编码只能是英文字母，最多 32 个；短语里要换行按 ⌥⏎。按 ⏎ 添加。"
    private static let listHeight: CGFloat = 360

    override var rebuildsOnChange: Bool { false }
    override var pageTitle: String { "快捷短语" }
    override var pageSubtitle: String {
        config.pinyinEngine == "wanxiang" ? "地址、邮箱、常用回复：打几个字母就出整段文字。"
            : "地址、邮箱、常用回复：打几个字母就出整段文字，也可以按 ⇧K 再打编码。"
    }

    override func build() -> [NSView] {
        codeField.placeholderString = "编码，比如：dz"
        textField.placeholderString = "短语，比如：北京市海淀区中关村大街 1 号"
        for field in [codeField, textField] {
            field.delegate = self
            field.controlSize = .large
            field.font = .systemFont(ofSize: 13)
            field.bezelStyle = .roundedBezel
        }
        textField.usesSingleLineMode = false
        textField.cell?.wraps = true
        textField.cell?.isScrollable = false
        searchField.placeholderString = "搜索编码和短语"
        searchField.delegate = self
        searchField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        addButton.keyEquivalent = "\r"
        addButton.controlSize = .large
        updateAddButton()

        let header = SectionHeader(title: listTitleText, accessory: searchField)
        listTitle = header.subviews.first as? NSTextField
        let card = makeListCard()
        listCard = card
        let inline = SettingsKit.row(title: "打编码时出现在候选里",
                                     detail: config.pinyinEngine == "wanxiang"
                                         ? "关掉后快捷短语不出现（万象没有 ⇧K）。" : "关掉后只能按 ⇧K 再打编码。",
                                     help: "打的拼音正好是编码时，短语排在第一页的最后（横排放不下时在下一行，按 = 翻过去）。\n\n"
                                         + "关掉后用水杉时只能按 ⇧K 再打编码；万象没有 ⇧K 模式，关掉后快捷短语就不出现。",
                                     icon: SettingsIcon(symbol: "text.quote", color: .systemGreen),
                                     accessory: SettingSwitch(isOn: config.quickPhraseCandidates) { [weak self] on in
                                         self?.update { $0.quickPhraseCandidates = on }
                                     })
        return [
            SettingsKit.sectionTitle("候选显示"),
            SettingsKit.card([inline]),
            SettingsKit.sectionTitle("添加快捷短语"),
            SettingsKit.card([addRow()]),
            header,
            card,
        ]
    }

    /// 编码框窄、短语框宽，添加按钮在最右边；下面一行提示。
    private func addRow() -> NSView {
        let fields = NSStackView(views: [codeField, textField, addButton])
        fields.spacing = 10
        fields.distribution = .fill
        fields.alignment = .top
        codeField.widthAnchor.constraint(equalToConstant: 130).isActive = true
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
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

    private var listTitleText: String {
        phrases.isEmpty ? "我的快捷短语" : "我的快捷短语（\(phrases.count)）"
    }

    private func makeListCard() -> ScrollingCard {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = phrases.filter { query.isEmpty || $0.code.contains(query) || $0.text.lowercased().contains(query) }
        if shown.isEmpty {
            let text = phrases.isEmpty ? "还没有快捷短语，在上面加一个试试。" : "没有找到「\(searchField.stringValue)」"
            let label = SettingsKit.wrappingLabel(text, size: 13, color: .secondaryLabelColor)
            return ScrollingCard(rows: [Self.padded(label)], height: Self.listHeight)
        }
        return ScrollingCard(rows: shown.map { phrase in
            PhraseRow(phrase: phrase,
                      edit: { [weak self] in self?.startEditing(phrase) },
                      delete: { [weak self] in self?.remove(phrase) })
        }, height: Self.listHeight)
    }

    /// 只换列表那张卡片（不打断正在输入的文本框），滚到的位置留着。
    private func reloadList() {
        listTitle?.stringValue = listTitleText
        guard let old = listCard, let stack = old.superview as? NSStackView,
              let index = stack.arrangedSubviews.firstIndex(of: old) else { return }
        let card = makeListCard()
        let offset = old.offset
        old.removeFromSuperview()
        stack.insertArrangedSubview(card, at: index)
        card.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -SettingsKit.contentInset * 2).isActive = true
        stack.layoutSubtreeIfNeeded()
        card.offset = offset
        listCard = card
    }

    // MARK: - 增删改

    private func add() {
        guard let code = QuickPhrases.normalizeCode(codeField.stringValue) else {
            showHint("编码只能是英文字母，1 到 32 个。", error: true)
            return
        }
        let text = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard text.utf8.count <= QuickPhrases.maxTextBytes else {
            showHint("短语太长了，最多 1300 个汉字左右。", error: true)
            return
        }
        let phrase = QuickPhrase(code: code, text: text)
        if phrase != editing, phrases.contains(phrase) {
            showHint("已经有这条快捷短语了。", error: true)
            return
        }
        if let editing, let index = phrases.firstIndex(of: editing) {
            phrases[index] = phrase
        } else {
            phrases.insert(phrase, at: 0)
        }
        save()
        stopEditing()
        reloadList()
    }

    private func remove(_ phrase: QuickPhrase) {
        phrases.removeAll { $0 == phrase }
        if editing == phrase { stopEditing() }
        save()
        reloadList()
    }

    private func startEditing(_ phrase: QuickPhrase) {
        editing = phrase
        codeField.stringValue = phrase.code
        textField.stringValue = phrase.text
        addButton.title = "保存"
        showHint("正在编辑「\(phrase.code)」，改好按 ⏎ 保存，按 Esc 取消。", error: false)
        updateAddButton()
        view.window?.makeFirstResponder(textField)
    }

    private func stopEditing() {
        editing = nil
        codeField.stringValue = ""
        textField.stringValue = ""
        addButton.title = "添加"
        showHint(Self.hintText, error: false)
        updateAddButton()
        view.window?.makeFirstResponder(codeField)
    }

    private func save() {
        do {
            try QuickPhrases.save(phrases)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "快捷短语保存失败"
            alert.runModal()
        }
    }

    private func showHint(_ text: String, error: Bool) {
        hint.stringValue = text
        hint.textColor = error ? .systemRed : .secondaryLabelColor
    }

    private func updateAddButton() {
        addButton.isEnabled = !codeField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
            && !textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === searchField {
            reloadList()
            return
        }
        if hint.textColor == .systemRed { showHint(Self.hintText, error: false) }
        updateAddButton()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        // ⏎ 添加（短语框能多行，回车不会自己触发默认按钮）；短语框里 ⌥⏎ 换行；编辑时 Esc 取消
        if selector == #selector(NSResponder.insertNewline(_:)) {
            if addButton.isEnabled { add() }
            return true
        }
        if control === textField, selector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
            textView.insertNewlineIgnoringFieldEditor(nil)
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)), editing != nil {
            stopEditing()
            return true
        }
        return false
    }
}

/// 我的快捷短语里的一行：左边编码，右边短语（多行的只显示前两行），最右边编辑、删除按钮。
private final class PhraseRow: NSView {
    /// 短语那一列从哪开始（离左边）
    private static let textColumn: CGFloat = 150

    init(phrase: QuickPhrase, edit: @escaping () -> Void, delete: @escaping () -> Void) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let code = NSTextField(labelWithString: phrase.code)
        code.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        code.lineBreakMode = .byTruncatingTail
        let text = NSTextField(wrappingLabelWithString: phrase.text)
        text.font = .systemFont(ofSize: 13)
        text.maximumNumberOfLines = 2
        text.lineBreakMode = .byTruncatingTail
        text.cell?.truncatesLastVisibleLine = true
        let editButton = Self.iconButton("pencil", "编辑「\(phrase.code)」", edit)
        let deleteButton = Self.iconButton("trash", "删除「\(phrase.code)」", delete)
        for view in [code, text, editButton, deleteButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let inset = SettingsKit.rowInset
        NSLayoutConstraint.activate([
            code.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            code.widthAnchor.constraint(lessThanOrEqualToConstant: Self.textColumn - 12),
            code.firstBaselineAnchor.constraint(equalTo: text.firstBaselineAnchor),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset + Self.textColumn),
            text.trailingAnchor.constraint(lessThanOrEqualTo: editButton.leadingAnchor, constant: -12),
            deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset + 4),
            deleteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            editButton.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -2),
            editButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func iconButton(_ symbol: String, _ tip: String, _ action: @escaping () -> Void) -> NSButton {
        let button = SettingButton(title: "", symbol: symbol, onClick: action)
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tip
        return button
    }
}
