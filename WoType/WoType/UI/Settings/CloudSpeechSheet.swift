//
//  CloudSpeechSheet.swift
//  WoType
//
//  添加、编辑一个云端识别的窗口（docs/21）：服务商、API 密钥（👁 显示）、模型、语言（默认中文）。
//  和 CloudModelSheet 一个样子，但简单：服务商的模型是固定的几个，不用拉列表。
//  点「保存」先测试密钥（CloudSpeech.test），通过了才存。
//

import AppKit

final class CloudSpeechSheet: NSWindowController, NSTextFieldDelegate {

    private static var current: CloudSpeechSheet?

    /// 在设置窗口（或新手引导窗口）上弹出；editing 是 nil 时添加。保存了就把存下的交给 onSaved
    static func present(editing: CloudSpeechModel?, on parent: NSWindow, onSaved: ((CloudSpeechModel) -> Void)? = nil) {
        guard current == nil else { return }
        let sheet = CloudSpeechSheet(editing: editing)
        sheet.onSaved = onSaved
        current = sheet
        parent.beginSheet(sheet.window!) { _ in current = nil }
    }

    /// 下拉框里选了「添加云端识别…」：跳到模型管理页，弹出添加窗口。
    static func presentAdding() {
        let settings = SettingsWindowController.shared
        settings.navigate(to: "models")
        if let window = settings.window { present(editing: nil, on: window) }
    }

    private let editing: CloudSpeechModel?
    private var onSaved: ((CloudSpeechModel) -> Void)?
    private var provider: CloudSpeechProvider
    private let providerPopUp: SettingPopUp
    private let modelPopUp: SettingPopUp
    private let languagePopUp = ActionPopUp()
    /// 选的语言代码，空的是自动识别
    private var language: String
    private let secureKey = NSSecureTextField()
    private let plainKey = NSTextField()
    private let eye = NSButton()
    private let keyStatus = NSTextField(labelWithString: "")
    private var keyLink: URL?
    private let note = NSTextField(wrappingLabelWithString: "")
    private let save = SettingButton(title: "保存") {}
    private let root = SettingsBackgroundView()
    private var testing = false
    private var failure: String?

    private var key: String { (eye.state == .on ? plainKey : secureKey).stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }

    private init(editing: CloudSpeechModel?) {
        self.editing = editing
        provider = editing?.provider ?? .xai
        language = editing?.language ?? CloudSpeechLanguage.defaultCode
        let providers = CloudSpeechProvider.allCases
        providerPopUp = SettingPopUp(items: providers.map(\.title), selected: providers.firstIndex(of: provider) ?? 0) { _ in }
        modelPopUp = SettingPopUp(items: [], selected: 0) { _ in }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 260), styleMask: [.titled],
                              backing: .buffered, defer: false)
        super.init(window: window)
        providerPopUp.target = self
        providerPopUp.action = #selector(providerChanged)
        providerPopUp.isEnabled = editing == nil
        window.contentView = makeContent(title: editing == nil ? "添加云端识别" : "编辑云端识别")
        if let editing, let saved = CloudSpeech.shared.apiKey(editing) { setKey(saved) }
        fillModels(selected: editing?.model)
        fillLanguages()
        update()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func makeContent(title: String) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 15, weight: .semibold)

        secureKey.cell = EyeInsetSecureCell(textCell: "")
        plainKey.cell = EyeInsetCell(textCell: "")
        for field in [secureKey, plainKey] {
            field.isEditable = true
            field.isSelectable = true
            field.isBezeled = true
            field.bezelStyle = .roundedBezel
            field.usesSingleLineMode = true
            field.cell?.isScrollable = true
            field.font = .systemFont(ofSize: 13)
            field.placeholderString = "粘贴 API 密钥"
            field.delegate = self
        }
        plainKey.isHidden = true
        eye.setButtonType(.toggle)
        eye.isBordered = false
        eye.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "显示密钥")
        eye.alternateImage = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: "隐藏密钥")
        eye.contentTintColor = .secondaryLabelColor
        eye.toolTip = "显示密钥"
        eye.target = self
        eye.action = #selector(toggleReveal)
        let keyBox = NSView()
        var constraints: [NSLayoutConstraint] = []
        for view in [secureKey, plainKey, eye] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            keyBox.addSubview(view)
        }
        for field in [secureKey, plainKey] {
            constraints += [
                field.leadingAnchor.constraint(equalTo: keyBox.leadingAnchor),
                field.trailingAnchor.constraint(equalTo: keyBox.trailingAnchor),
                field.topAnchor.constraint(equalTo: keyBox.topAnchor),
                field.bottomAnchor.constraint(equalTo: keyBox.bottomAnchor),
            ]
        }
        constraints += [
            eye.trailingAnchor.constraint(equalTo: keyBox.trailingAnchor, constant: -6),
            eye.centerYAnchor.constraint(equalTo: keyBox.centerYAnchor),
        ]

        keyStatus.font = .systemFont(ofSize: 11.5)
        keyStatus.lineBreakMode = .byTruncatingTail
        keyStatus.addGestureRecognizer(ClickGesture { [weak self] in
            if let link = self?.keyLink { NSWorkspace.shared.open(link) }
        })
        note.font = .systemFont(ofSize: 11.5)
        note.textColor = .secondaryLabelColor

        func label(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 13)
            return label
        }
        let grid = NSGridView()
        for (i, row) in ([[label("服务商"), providerPopUp], [label("API 密钥"), keyBox],
                          [NSGridCell.emptyContentView, keyStatus], [label("模型"), modelPopUp],
                          [label("语言"), languagePopUp], [NSGridCell.emptyContentView, note]] as [[NSView]]).enumerated() {
            grid.addRow(with: row)
            if i == 2 || i == 5 { grid.row(at: i).topPadding = -4 }
        }
        grid.column(at: 0).xPlacement = .trailing
        grid.yPlacement = .center
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        for control in [providerPopUp, keyBox, keyStatus, modelPopUp, languagePopUp, note] as [NSView] {
            control.translatesAutoresizingMaskIntoConstraints = false
            constraints.append(control.widthAnchor.constraint(equalToConstant: 300))
        }

        let cancel = SettingButton(title: "取消") { [weak self] in self?.dismiss() }
        cancel.keyEquivalent = "\u{1b}"
        save.target = self
        save.action = #selector(saveTapped)
        save.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancel, save])
        buttons.spacing = 10

        for view in [heading, grid, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        constraints += [
            root.widthAnchor.constraint(equalToConstant: 480),
            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            grid.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 18),
            grid.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            buttons.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 22),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
        ]
        NSLayoutConstraint.activate(constraints)
        return root
    }

    private func setKey(_ value: String) {
        secureKey.stringValue = value
        plainKey.stringValue = value
    }

    /// 模型下拉框：这家的几个（只有一个时不用选）
    private func fillModels(selected: String?) {
        modelPopUp.removeAllItems()
        modelPopUp.addItems(withTitles: provider.models.map(provider.modelTitle))
        if let selected, let index = provider.models.firstIndex(of: selected) { modelPopUp.selectItem(at: index) }
        modelPopUp.isEnabled = provider.models.count > 1
    }

    /// 语言下拉框：能写数字的一组、其他语言一组，最后是自动识别。这家没有当前选的语言时换成默认的
    private func fillLanguages() {
        let languages = provider.languages
        if !language.isEmpty, !languages.contains(where: { $0.code == language }) {
            language = languages.contains { $0.code == CloudSpeechLanguage.defaultCode } ? CloudSpeechLanguage.defaultCode : ""
        }
        languagePopUp.removeAllItems()
        languagePopUp.addHeader("数字写成阿拉伯数字")
        for item in languages where item.formats {
            languagePopUp.add(item.title, selected: item.code == language) { [weak self] in self?.pickLanguage(item.code) }
        }
        languagePopUp.addSeparator()
        languagePopUp.addHeader("其他语言")
        for item in languages where !item.formats {
            languagePopUp.add(item.title, selected: item.code == language) { [weak self] in self?.pickLanguage(item.code) }
        }
        languagePopUp.addSeparator()
        languagePopUp.add("自动识别（不指定）", selected: language.isEmpty) { [weak self] in self?.pickLanguage("") }
    }

    private func pickLanguage(_ code: String) {
        language = code
        update()
    }

    private func update() {
        let parts: [ModelsPage.DetailPart]
        if testing {
            parts = [("验证中…", .secondaryLabelColor, nil)]
        } else if let failure {
            parts = [(failure, .systemRed, nil)]
        } else {
            parts = provider.keyPage.map { [("在 \(provider.keyPageName)创建 ↗", .linkColor, $0)] } ?? []
        }
        keyStatus.attributedStringValue = ModelsPage.attributed(parts, font: .systemFont(ofSize: 11.5))
        keyLink = parts.compactMap(\.link).first
        let chosen = provider.languages.first { $0.code == language } ?? .automatic
        note.stringValue = provider.summary + (chosen.formats ? "说的数字写成阿拉伯数字。"
            : language.isEmpty ? "自动判断语言，中途换语言也跟得上；数字照说的写。" : "这种语言的数字照说的写。")
        save.isEnabled = !key.isEmpty && !testing
        save.title = testing ? "验证中…" : "保存"
        root.layoutSubtreeIfNeeded()
        window?.setContentSize(root.fittingSize)
    }

    @objc private func providerChanged() {
        provider = CloudSpeechProvider.allCases[providerPopUp.indexOfSelectedItem]
        failure = nil
        fillModels(selected: nil)
        fillLanguages()
        update()
    }

    @objc private func toggleReveal() {
        let revealing = eye.state == .on
        (revealing ? plainKey : secureKey).stringValue = (revealing ? secureKey : plainKey).stringValue
        plainKey.isHidden = !revealing
        secureKey.isHidden = revealing
        eye.toolTip = revealing ? "隐藏密钥" : "显示密钥"
        window?.makeFirstResponder(revealing ? plainKey : secureKey)
    }

    func controlTextDidChange(_ notification: Notification) {
        failure = nil
        update()
    }

    /// 先测试密钥，通过了才存。
    @objc private func saveTapped() {
        guard save.isEnabled else { return }
        let provider = self.provider
        let model = provider.models[max(0, modelPopUp.indexOfSelectedItem)]
        let key = self.key
        let language = self.language
        let spoken = provider.languages.first { $0.code == language } ?? .automatic
        testing = true
        failure = nil
        update()
        Task {
            do {
                _ = try await CloudSpeech.test(provider, key: key, model: model, language: spoken)
                let saved = CloudSpeechModel(id: editing?.id ?? UUID().uuidString, provider: provider, model: model,
                                             language: language)
                CloudSpeech.shared.save(saved, key: key)
                onSaved?(saved)
                dismiss()
            } catch {
                testing = false
                failure = "✗ " + error.localizedDescription
                update()
            }
        }
    }

    private func dismiss() {
        guard let window else { return }
        window.sheetParent?.endSheet(window, returnCode: .OK)
    }
}
