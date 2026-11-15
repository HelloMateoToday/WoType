//
//  ModelsPage.swift
//  WoType
//
//  设置 › 模型管理：本机模型（语音识别、润色和语音翻译，下载 → 进度 → ⋯ 里在访达中显示、删除）和云端模型。
//  模型的名字一律「供应商 · 模型名」，前面不放图标（本机的是「本机 · Qwen3.5-2B」）。
//
//  云端模型照 Arion apps/desktop/ui/features/cloud/cloud.go@d2108fe（AGPL-3.0-only）的规则：拉到模型列表才算密钥能用、
//  没选模型时默认选快的那一档。界面是 WoType 重新设计的：
//  - 每个模型一行：说明里是接口地址、用在哪儿、上次测试的结果；右边「测试」（发一句很短的话）和「⋯」（编辑、删除）；
//  - 添加和编辑用同一个窗口（CloudModelSheet）：服务商、接口地址（兼容类才有）、API 密钥、模型。
//    密钥填完（停 0.6 秒、离开输入框或按 ⏎）自动验证：拉模型列表，模型自动选默认的；验证过、选了模型才能保存。
//  没有 Arion 的「用 ChatGPT 登录」（只做 API 密钥）。
//
//  云端识别（docs/21）：用户自己的 API 密钥（现在有 xAI），每个一行，右边「测试」和「⋯」（编辑、删除），
//  添加和编辑用 CloudSpeechSheet。
//  最后是体验渠道（docs/21）：输入法客户端的内部识别接口，仅供体验，随时失效；每个一行，右边「测试」（连上并握手）。
//

import AppKit

final class ModelsPage: SettingsPage {
    override var pageTitle: String { "模型管理" }
    override var pageSubtitle: String { "本机模型离线运行；云端模型用你自己的 API 密钥。" }

    /// 每个模型上次测试的结果、正在测的
    private var results: [String: (ok: Bool, text: String)] = [:]
    private var testing: Set<String> = []

    private var modelObserver: NSObjectProtocol?
    private var speechObserver: NSObjectProtocol?

    override func viewDidLoad() {
        super.viewDidLoad()
        speechObserver = NotificationCenter.default.addObserver(
            forName: CloudSpeech.didChange, object: nil, queue: .main) { [weak self] _ in self?.reload() }
        // 本机模型的下载进度、装好了：刷新这一页
        modelObserver = NotificationCenter.default.addObserver(
            forName: VoiceModels.didChange, object: nil, queue: .main) { [weak self] _ in self?.reload() }
        VoiceModels.shared.refresh()
    }

    deinit {
        if let modelObserver { NotificationCenter.default.removeObserver(modelObserver) }
        if let speechObserver { NotificationCenter.default.removeObserver(speechObserver) }
    }

    override func build() -> [NSView] {
        let add = SettingButton(title: "添加", symbol: "plus") { [weak self] in self?.present(nil) }
        let models = CloudPolish.shared.models
        return localModels() + [
            SectionHeader(title: "云端模型", accessory: add),
            models.isEmpty ? emptyCard() : SettingsKit.card(models.map(row), separatorInset: SettingsKit.rowInset),
            SettingsKit.sectionTitle("高级"), SettingsKit.card([reasoningRow()]),
            footnote("云端模型只收到要润色、翻译的文字和你开启的润色参考。密钥存在本机的 WoType 数据文件夹里（cloud-keys.json，只有你的账户能读）。"),
            SectionHeader(title: "云端识别", accessory: SettingButton(title: "添加", symbol: "plus") { [weak self] in
                self?.presentSpeech(nil)
            }),
            SettingsKit.card(CloudSpeech.shared.models.isEmpty ? [speechEmptyRow()] : CloudSpeech.shared.models.map(speechRow),
                             separatorInset: SettingsKit.rowInset),
            footnote("语音识别用你自己的 API 密钥，录音会发给服务商。在「语音输入 › 识别方式」里选用。"),
            SettingsKit.sectionTitle("体验渠道"),
            SettingsKit.card([trialWarningRow()] + TrialChannel.allCases.map(trialRow), separatorInset: SettingsKit.rowInset),
            footnote("在「语音输入 › 识别方式」里选用。选用后说话的录音会发到对应厂商的服务器。"),
        ]
    }

    // MARK: - 云端识别

    private func presentSpeech(_ model: CloudSpeechModel?) {
        guard let window = view.window else { return }
        CloudSpeechSheet.present(editing: model, on: window)
    }

    private func speechEmptyRow() -> NSView {
        SettingsKit.row(title: "还没有添加云端识别", detail: "支持 xAI，用你自己的 API 密钥，边说边出字。",
                        accessory: SettingButton(title: "添加", symbol: "plus") { [weak self] in self?.presentSpeech(nil) })
    }

    /// 一个云端识别：说明是「特点 · 用没用 · 测试结果」，右边「测试」和「⋯」。
    private func speechRow(_ model: CloudSpeechModel) -> NSView {
        let key = "speech." + model.id
        let hasKey = CloudSpeech.shared.apiKey(model) != nil
        var parts: [DetailPart] = [(model.spokenLanguage.title + " · " + (CloudSpeech.shared.inUse(model) ? "正在用于语音输入" : "未使用"),
                                    .secondaryLabelColor, nil)]
        if !hasKey {
            parts.append((" · 找不到密钥，请编辑", .systemRed, nil))
        } else if testing.contains(key) {
            parts.append((" · 测试中…", .secondaryLabelColor, nil))
        } else if let result = results[key] {
            parts.append((" · " + result.text, result.ok ? .systemGreen : .systemRed, nil))
        }
        let test = SettingButton(title: "测试") { [weak self] in self?.runSpeechTest(model) }
        test.isEnabled = hasKey && !testing.contains(key)
        let controls = SettingsKit.resourceAccessory(test, more: [
            ("编辑…", { [weak self] in self?.presentSpeech(model) }),
            ("删除…", { [weak self] in self?.confirmSpeechDelete(model) }),
        ])
        let row = SettingsKit.row(title: model.title, detail: parts.map(\.text).joined(), accessory: controls)
        Self.style(row, parts)
        return row
    }

    private func runSpeechTest(_ model: CloudSpeechModel) {
        let key = "speech." + model.id
        guard let apiKey = CloudSpeech.shared.apiKey(model) else { return }
        testing.insert(key)
        results[key] = nil
        reload()
        Task {
            do {
                let elapsed = try await CloudSpeech.test(model.provider, key: apiKey, model: model.model,
                                                         language: model.spokenLanguage)
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                results[key] = (true, String(format: "✓ 测试通过，%.1f 秒", seconds))
            } catch {
                results[key] = (false, "✗ " + error.localizedDescription)
            }
            testing.remove(key)
            reload()
        }
    }

    private func confirmSpeechDelete(_ model: CloudSpeechModel) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "删除「\(model.title)」？"
        alert.informativeText = "密钥会从本机删掉。" + (CloudSpeech.shared.inUse(model) ? "语音输入正在用它，删除后改用本机识别。" : "")
        alert.addButton(withTitle: "删除").hasDestructiveAction = true
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.results["speech." + model.id] = nil
            CloudSpeech.shared.remove(model)
        }
    }

    // MARK: - 体验渠道

    private func trialWarningRow() -> NSView {
        SettingsKit.row(title: "仅供体验，随时失效",
                        detail: "调用输入法客户端的内部识别接口，不是官方开放接口，可能随时不能用。",
                        icon: SettingsIcon(symbol: "exclamationmark.triangle.fill", color: .systemOrange))
    }

    /// 一个体验渠道：说明是「录音发到谁 · 用没用 · 测试结果」，右边「测试」。
    private func trialRow(_ channel: TrialChannel) -> NSView {
        let key = VoiceRecognizer.trial(channel).name
        var parts: [DetailPart] = [("录音发到\(channel.vendor) · ", .secondaryLabelColor, nil)]
        let inUse = config.voiceRecognizer == .trial(channel)
        parts.append((inUse ? "正在用于语音输入" : "未使用", .secondaryLabelColor, nil))
        if testing.contains(key) {
            parts.append((" · 测试中…", .secondaryLabelColor, nil))
        } else if let result = results[key] {
            parts.append((" · " + result.text, result.ok ? .systemGreen : .systemRed, nil))
        }
        let test = SettingButton(title: "测试") { [weak self] in self?.runTrialTest(channel) }
        test.isEnabled = !testing.contains(key)
        let row = SettingsKit.row(title: channel.title, detail: parts.map(\.text).joined(), accessory: test)
        Self.style(row, parts)
        return row
    }

    private func runTrialTest(_ channel: TrialChannel) {
        let key = VoiceRecognizer.trial(channel).name
        testing.insert(key)
        results[key] = nil
        reload()
        Task {
            do {
                let elapsed = try await channel.test()
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                results[key] = (true, String(format: "✓ 连接正常，%.1f 秒", seconds))
            } catch {
                results[key] = (false, "✗ " + error.localizedDescription)
            }
            testing.remove(key)
            reload()
        }
    }

    // MARK: - 本机模型

    /// 「本机模型」分组：还有没装好的时候标题右边是「全部下载」，每个模型一行。
    private func localModels() -> [NSView] {
        let models = VoiceModels.shared
        let missing = VoiceModelSpec.all.filter {
            switch models.state($0) {
            case .installed, .connecting, .downloading, .verifying: false
            default: true
            }
        }
        let header: NSView = missing.count > 1
            ? SectionHeader(title: "本机模型", accessory: SettingButton(title: "全部下载") { VoiceModels.shared.downloadAll() })
            : SettingsKit.sectionTitle("本机模型")
        return [header, SettingsKit.card(VoiceModelSpec.all.map { localRow($0, state: models.state($0)) },
                                         separatorInset: SettingsKit.rowInset)]
    }

    private func localRow(_ spec: VoiceModelSpec, state: VoiceModels.State) -> NSView {
        let detail: String
        let accessory: NSView
        switch state {
        case .installed(let bytes, let revision):
            let base = "\(spec.detail) · \(SettingsKit.size(bytes))"
            let models = VoiceModels.shared
            let check = SettingButton(title: "检查更新") { models.checkForUpdate(spec) }
            let primary: NSView
            switch models.update(spec) {
            case .checking?:
                detail = base + " · 正在检查…"
                primary = SettingsKit.spinner()
            case .upToDate?:
                detail = base + " · 已是最新"
                primary = check
            case .available?:
                detail = base + " · 有新版"
                primary = SettingButton(title: "更新") { models.download(spec) }
            case .failed(let message)?:
                detail = base + " · 检查失败：\(message)"
                primary = check
            case nil:
                detail = base + " · 已就绪（版本 \(revision.prefix(7))）"
                primary = check
            }
            accessory = SettingsKit.resourceAccessory(primary, more: [
                ("在访达中显示", { NSWorkspace.shared.activateFileViewerSelecting([spec.directory]) }),
                ("删除…", { [weak self] in self?.confirmRemove(spec, bytes: bytes) }),
            ])
        case .connecting:
            detail = "正在连接…"
            accessory = SettingsKit.progress(nil) { VoiceModels.shared.cancel(spec) }
        case .verifying:
            detail = "正在校验…"
            accessory = SettingsKit.progress(nil) { VoiceModels.shared.cancel(spec) }
        case .downloading(let written, let total):
            detail = total > 0
                ? "正在下载 \(written * 100 / total)%（\(SettingsKit.size(written)) / \(SettingsKit.size(total))）"
                : "正在下载…"
            accessory = SettingsKit.progress(total > 0 ? Double(written) / Double(total) : nil) { VoiceModels.shared.cancel(spec) }
        case .partial:
            detail = "\(spec.detail) · 已下载一部分"
            accessory = SettingsKit.resourceAccessory(SettingButton(title: "继续") { VoiceModels.shared.download(spec) })
        case .missing:
            detail = "\(spec.detail) · 约 \(SettingsKit.size(spec.approxBytes))，下载一次就能离线用"
            accessory = SettingsKit.resourceAccessory(SettingButton(title: "下载") { VoiceModels.shared.download(spec) })
        case .failed(let message):
            detail = "下载失败：\(message)"
            accessory = SettingsKit.resourceAccessory(SettingButton(title: "重试") { VoiceModels.shared.download(spec) })
        }
        return SettingsKit.row(title: spec.title, detail: detail,
                               help: "从 Hugging Face（\(spec.repo)）下载，只需下载一次，之后离线可用。\n\n"
                                   + "「检查更新」看 Hugging Face 上有没有新版；更新时只下变了的文件。",
                               accessory: accessory)
    }

    private func confirmRemove(_ spec: VoiceModelSpec, bytes: Int64) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "删除「\(spec.title)」？"
        alert.informativeText = "会删掉 \(SettingsKit.size(bytes)) 的模型文件，要用时得重新下载。"
        alert.addButton(withTitle: "删除").hasDestructiveAction = true
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { VoiceModels.shared.remove(spec) }
        }
    }

    // MARK: - 云端模型

    private func present(_ model: CloudModel?) {
        guard let window = view.window else { return }
        CloudModelSheet.present(editing: model, on: window)
    }

    /// 一个模型：标题「供应商 · 模型名」，说明是「接口地址 · 用于润色、翻译 · 测试结果」。
    private func row(_ model: CloudModel) -> NSView {
        let cloud = CloudPolish.shared
        var parts: [DetailPart] = []
        if model.provider.needsBase, let host = URL(string: model.baseURL)?.host {
            parts.append((host + " · ", .secondaryLabelColor, nil))
        }
        let uses = cloud.uses(model)
        parts.append((uses.isEmpty ? "未使用" : "用于" + Self.describe(uses), .secondaryLabelColor, nil))
        let hasKey = cloud.apiKey(model) != nil
        if !hasKey {
            parts.append((" · 找不到密钥，请编辑", .systemRed, nil))
        } else if testing.contains(model.id) {
            parts.append((" · 测试中…", .secondaryLabelColor, nil))
        } else if let result = results[model.id] {
            parts.append((" · " + result.text, result.ok ? .systemGreen : .systemRed, nil))
        }
        let test = SettingButton(title: "测试") { [weak self] in self?.runTest(model) }
        test.isEnabled = hasKey && !testing.contains(model.id)
        let controls = SettingsKit.resourceAccessory(test, more: [
            ("编辑…", { [weak self] in self?.present(model) }),
            ("删除…", { [weak self] in self?.confirmDelete(model) }),
        ])
        let row = SettingsKit.row(title: model.title, detail: parts.map(\.text).joined(), accessory: controls)
        Self.style(row, parts)
        return row
    }

    /// 还没添加模型：一句说明和「添加模型」。
    private func emptyCard() -> NSView {
        let title = NSTextField(labelWithString: "还没有添加云端模型")
        title.font = .systemFont(ofSize: 13, weight: .medium)
        let detail = NSTextField(labelWithString: "润色、翻译默认在本机运行；要用云端模型请先添加。")
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        let add = SettingButton(title: "添加模型", symbol: "plus") { [weak self] in self?.present(nil) }
        let stack = NSStackView(views: [title, detail, add])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.setCustomSpacing(12, after: detail)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let card = CardView()
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -22),
        ])
        return card
    }

    private static func describe(_ uses: [CloudUse]) -> String {
        uses.map {
            switch $0 {
            case .polish: "润色"
            case .translate: "语音翻译"
            case .selection: "划词翻译"
            }
        }.joined(separator: "、")
    }

    private func reasoningRow() -> NSView {
        let toggle = SettingSwitch(isOn: config.voiceCloudReasoning) { [weak self] on in
            self?.update { $0.voiceCloudReasoning = on }
        }
        return SettingsKit.row(title: "必要时允许推理",
                               detail: "有的模型关不掉推理，开启后以最低强度重试",
                               help: "部分模型无法关闭推理。开启后会以模型接受的最低推理强度重试，可能变慢；"
                                   + "关闭时这类模型润色会失败，改用本机整理的文字。",
                               icon: SettingsIcon(symbol: "brain", color: .systemPink), accessory: toggle)
    }

    // MARK: - 动作

    private func runTest(_ model: CloudModel) {
        testing.insert(model.id)
        results[model.id] = nil
        reload()
        Task {
            do {
                let elapsed = try await CloudPolish.shared.test(model)
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                results[model.id] = (true, String(format: "✓ 测试通过，%.1f 秒", seconds))
            } catch {
                results[model.id] = (false, "✗ " + ((error as? CloudFailure)?.notice.title ?? "测试失败"))
            }
            testing.remove(model.id)
            reload()
        }
    }

    /// 删除先确认；正在用它的润色、翻译会改回本机。
    private func confirmDelete(_ model: CloudModel) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "删除「\(model.title)」？"
        var info = "密钥会从本机删掉。"
        let uses = CloudPolish.shared.uses(model)
        if !uses.isEmpty {
            info += Self.describe(uses) + "正在用它，删除后" + (uses == [.selection] ? "改用机器翻译。" : "改用本机。")
        }
        alert.informativeText = info
        alert.addButton(withTitle: "删除").hasDestructiveAction = true
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.results[model.id] = nil
            CloudPolish.shared.remove(model)
        }
    }

    // MARK: - 小工具

    /// 说明行的一段：文字、颜色、点了打开的网址
    typealias DetailPart = (text: String, color: NSColor, link: URL?)

    /// 给行里的说明文字上色。
    private static func style(_ row: NSView, _ parts: [DetailPart]) {
        guard !parts.isEmpty, let label = detailLabel(in: row) else { return }
        label.attributedStringValue = attributed(parts, font: label.font ?? .systemFont(ofSize: 11.5))
    }

    static func attributed(_ parts: [DetailPart], font: NSFont) -> NSAttributedString {
        let text = NSMutableAttributedString()
        for part in parts {
            text.append(NSAttributedString(string: part.text, attributes: [.font: font, .foregroundColor: part.color]))
        }
        return text
    }

    /// 行里的说明文字
    private static func detailLabel(in row: NSView) -> NSTextField? {
        var labels: [NSTextField] = []
        func walk(_ view: NSView) {
            if let field = view as? NSTextField, !field.isEditable { labels.append(field) }
            view.subviews.forEach(walk)
        }
        walk(row)
        return labels.count >= 2 ? labels[1] : nil
    }
}

/// 添加、编辑一个云端模型的窗口：服务商、接口地址（兼容类才有）、API 密钥（👁 显示）、模型（可以搜索）。
final class CloudModelSheet: NSWindowController, NSTextFieldDelegate {

    private static var current: CloudModelSheet?

    /// 在设置窗口（或新手引导窗口）上弹出；editing 是 nil 时添加。保存了就把存下的模型交给 onSaved。
    static func present(editing: CloudModel?, on parent: NSWindow, onSaved: ((CloudModel) -> Void)? = nil) {
        guard current == nil else { return }
        let sheet = CloudModelSheet(editing: editing)
        current = sheet
        parent.beginSheet(sheet.window!) { response in
            current = nil
            if response == .OK, let saved = sheet.saved { onSaved?(saved) }
        }
    }

    /// 保存下来的模型
    private var saved: CloudModel?

    /// 下拉框里选了「添加云端模型…」：跳到模型管理页，弹出添加窗口。
    static func presentAdding() {
        let settings = SettingsWindowController.shared
        settings.navigate(to: "models")
        if let window = settings.window { present(editing: nil, on: window) }
    }

    private let editing: CloudModel?
    private var provider: CloudProvider
    private let providerPopUp: SettingPopUp
    private let secureKey = NSSecureTextField()
    private let plainKey = NSTextField()
    private let baseField = NSTextField()
    private let eye = NSButton()
    private let keyStatus = NSTextField(labelWithString: "")
    private var keyLink: URL?
    private let picker: ModelPicker
    private let modelStatus = NSTextField(labelWithString: "")
    private let save = SettingButton(title: "保存") {}
    private let grid: NSGridView
    private let root = SettingsBackgroundView()

    private var models: [String] = []
    private var chosen: String?
    private enum KeyState { case empty, verifying, verified, failed(String) }
    private var keyState = KeyState.empty
    /// 验证过的密钥和地址（没变就不再验证）、验证失败过的（没改就不自动重试，按 ⏎ 才重试）
    private var verifiedInput = ""
    private var failedInput = ""
    private var verifyTimer: Timer?

    private var key: String { (eye.state == .on ? plainKey : secureKey).stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var currentInput: String { key + "|" + baseField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }

    private init(editing: CloudModel?) {
        self.editing = editing
        provider = editing?.provider ?? .openai
        let providers = CloudProvider.allCases
        providerPopUp = SettingPopUp(items: providers.map(\.title), selected: providers.firstIndex(of: provider) ?? 0) { _ in }
        picker = ModelPicker(models: [], selected: nil, placeholder: "—", onRefresh: {}, onPick: { _ in })
        grid = NSGridView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        super.init(window: window)
        providerPopUp.target = self
        providerPopUp.action = #selector(providerChanged)
        picker.onRefresh = { [weak self] in self?.refreshModels() }
        picker.onPick = { [weak self] model in
            self?.chosen = model
            self?.update()
        }
        window.contentView = makeContent(title: editing == nil ? "添加云端模型" : "编辑云端模型")
        if let editing, let saved = CloudPolish.shared.apiKey(editing) {
            secureKey.stringValue = saved
            plainKey.stringValue = saved
            baseField.stringValue = editing.baseURL
            chosen = editing.model
            verifiedInput = currentInput
            keyState = .verified
            refreshModels()
        }
        update()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { verifyTimer?.invalidate() }

    private func makeContent(title: String) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 15, weight: .semibold)

        secureKey.cell = EyeInsetSecureCell(textCell: "")
        plainKey.cell = EyeInsetCell(textCell: "")
        for field in [secureKey, plainKey, baseField] {
            field.isEditable = true
            field.isSelectable = true
            field.isBezeled = true
            field.bezelStyle = .roundedBezel
            field.usesSingleLineMode = true
            field.cell?.isScrollable = true
            field.font = .systemFont(ofSize: 13)
            field.delegate = self
        }
        secureKey.placeholderString = "粘贴 API 密钥"
        plainKey.placeholderString = "粘贴 API 密钥"
        baseField.placeholderString = "https://example.com/v1"
        plainKey.isHidden = true

        // 密钥框：👁 放在框里面的右边
        eye.setButtonType(.toggle)
        eye.isBordered = false
        eye.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "显示密钥")
        eye.alternateImage = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: "隐藏密钥")
        eye.contentTintColor = .secondaryLabelColor
        eye.toolTip = "显示密钥"
        eye.target = self
        eye.action = #selector(toggleReveal)
        let keyBox = NSView()
        for view in [secureKey, plainKey, eye] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            keyBox.addSubview(view)
        }
        var constraints: [NSLayoutConstraint] = []
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

        for label in [keyStatus, modelStatus] {
            label.font = .systemFont(ofSize: 11.5)
            label.lineBreakMode = .byTruncatingTail
        }
        keyStatus.addGestureRecognizer(ClickGesture { [weak self] in
            if let link = self?.keyLink { NSWorkspace.shared.open(link) }
        })

        func label(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 13)
            return label
        }
        for (i, row) in ([[label("服务商"), providerPopUp], [label("接口地址"), baseField], [label("API 密钥"), keyBox],
                          [NSGridCell.emptyContentView, keyStatus], [label("模型"), picker],
                          [NSGridCell.emptyContentView, modelStatus]] as [[NSView]]).enumerated() {
            grid.addRow(with: row)
            if i == 3 || i == 5 { grid.row(at: i).topPadding = -4 }
        }
        grid.column(at: 0).xPlacement = .trailing
        grid.yPlacement = .center
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        for control in [providerPopUp, baseField, keyBox, picker, keyStatus, modelStatus] as [NSView] {
            control.translatesAutoresizingMaskIntoConstraints = false
            constraints.append(control.widthAnchor.constraint(equalToConstant: 300))
        }

        let cancel = SettingButton(title: "取消") { [weak self] in self?.close(saving: false) }
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

    /// 按现在的状态更新：接口地址那一行、密钥和模型的说明、模型下拉框、保存按钮；窗口高度跟着内容。
    private func update() {
        grid.row(at: 1).isHidden = !provider.needsBase
        let parts: [ModelsPage.DetailPart]
        switch keyState {
        case .verifying:
            parts = [("验证中…", .secondaryLabelColor, nil)]
        case .failed(let message):
            parts = [(message, .systemRed, nil)]
        case .verified:
            parts = provider.keyPage.map { [("✓ 已验证 · ", .systemGreen, nil), ("在 \(provider.keyPageName)管理 ↗", .linkColor, $0)] }
                ?? [("✓ 已验证", .systemGreen, nil)]
        case .empty:
            parts = provider.keyPage.map { [("在 \(provider.keyPageName)创建 ↗", .linkColor, $0)] }
                ?? [("粘贴后自动验证", .secondaryLabelColor, nil)]
        }
        keyStatus.attributedStringValue = ModelsPage.attributed(parts, font: .systemFont(ofSize: 11.5))
        keyLink = parts.compactMap(\.link).first

        picker.set(models: models, selected: chosen, placeholder: models.isEmpty ? "—" : "选择模型")
        picker.isEnabled = !models.isEmpty
        let modelText: String
        switch keyState {
        case _ where !models.isEmpty: modelText = "共 \(models.count) 个，点开可以搜索"
        case .verifying: modelText = "获取中…"
        case .verified where chosen != nil: modelText = "正在获取模型列表…"
        default: modelText = "密钥验证通过后再选"
        }
        modelStatus.stringValue = modelText
        modelStatus.textColor = .secondaryLabelColor

        let verified: Bool = { if case .verified = keyState { return true } else { return false } }()
        save.isEnabled = verified && chosen != nil && currentInput == verifiedInput
        root.layoutSubtreeIfNeeded()
        window?.setContentSize(root.fittingSize)
    }

    @objc private func providerChanged() {
        let next = CloudProvider.allCases[providerPopUp.indexOfSelectedItem]
        guard next != provider else { return }
        provider = next
        models = []
        chosen = nil
        verifiedInput = ""
        failedInput = ""
        keyState = .empty
        update()
        verifyIfChanged()
    }

    @objc private func toggleReveal() {
        let revealed = eye.state == .on
        let value = (revealed ? secureKey : plainKey).stringValue
        secureKey.stringValue = value
        plainKey.stringValue = value
        secureKey.isHidden = revealed
        plainKey.isHidden = !revealed
        eye.toolTip = revealed ? "隐藏密钥" : "显示密钥"
        window?.makeFirstResponder(revealed ? plainKey : secureKey)
    }

    // MARK: - 验证

    func controlTextDidChange(_ obj: Notification) {
        // 两个密钥框保持一致
        if let field = obj.object as? NSTextField, field === secureKey || field === plainKey {
            (field === secureKey ? plainKey : secureKey).stringValue = field.stringValue
        }
        update()
        // 停 0.6 秒再验证：粘贴完马上就验，一个个打字时不会边打边报错
        verifyTimer?.invalidate()
        guard key.count >= 8 else { return }
        verifyTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.verifyIfChanged() }
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        verifyTimer?.invalidate()
        verifyIfChanged()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        verifyTimer?.invalidate()
        if save.isEnabled {
            saveTapped()
        } else {
            verifyIfChanged(force: true)
        }
        return true
    }

    /// 验证：拉模型列表，拉到了模型选上默认的（编辑时原来的还在就留着）。force 是按了 ⏎：失败过的也再试一次。
    private func verifyIfChanged(force: Bool = false) {
        let input = currentInput
        guard !key.isEmpty, input != verifiedInput, force || input != failedInput else { return }
        if case .verifying = keyState { return }
        if provider.needsBase && baseField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty {
            keyState = .failed("先填接口地址")
            update()
            return
        }
        keyState = .verifying
        update()
        let provider = provider, key = key, base = baseField.stringValue
        Task {
            do {
                let list = try await CloudPolish.shared.fetchModels(provider, key: key, baseURL: base)
                guard provider == self.provider else { return }
                models = list
                if chosen.map(list.contains) != true { chosen = CloudPolish.defaultModel(provider, list) }
                verifiedInput = input
                failedInput = ""
                keyState = .verified
            } catch {
                guard provider == self.provider else { return }
                let failure = error as? CloudFailure
                keyState = .failed(failure == .credential ? "服务商拒绝了这个密钥，请检查是否复制完整"
                                   : failure?.connectMessage ?? "无法连接服务商。")
                verifiedInput = ""
                failedInput = input
            }
            update()
            // 验证的时候又改了密钥：接着验证新的
            if provider == self.provider, currentInput != input { verifyIfChanged() }
        }
    }

    /// 模型下拉框里的「刷新列表」、编辑时打开窗口：用填着的密钥重新拉一次。
    private func refreshModels() {
        guard case .verified = keyState else { return }
        let provider = provider, key = key, base = baseField.stringValue
        Task {
            do {
                models = try await CloudPolish.shared.fetchModels(provider, key: key, baseURL: base)
            } catch {
                keyState = .failed((error as? CloudFailure)?.connectMessage ?? "无法加载模型列表。")
                verifiedInput = ""
            }
            update()
        }
    }

    // MARK: - 保存

    @objc private func saveTapped() {
        guard save.isEnabled, let chosen else { return }
        let model = CloudModel(id: editing?.id ?? UUID().uuidString, provider: provider, model: chosen,
                               baseURL: baseField.stringValue)
        do {
            try CloudPolish.shared.save(model, key: key)
            saved = model
            close(saving: true)
        } catch {
            keyState = .failed((error as? CloudFailure)?.connectMessage ?? "保存失败。")
            update()
        }
    }

    private func close(saving: Bool) {
        verifyTimer?.invalidate()
        guard let window else { return }
        window.sheetParent?.endSheet(window, returnCode: saving ? .OK : .cancel)
    }
}

/// 密钥框的格子：右边让出 👁 的位置，文字和光标不压到它。
final class EyeInsetCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var rect = super.drawingRect(forBounds: rect)
        rect.size.width -= 20
        return rect
    }
}

final class EyeInsetSecureCell: NSSecureTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var rect = super.drawingRect(forBounds: rect)
        rect.size.width -= 20
        return rect
    }
}

/// 可以搜索的模型下拉框：外观就是普通的下拉框（跟服务商那个一样），点开换成带搜索框的列表，底下是数量和「刷新列表」。
final class ModelPicker: NSPopUpButton, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private var models: [String]
    private var shown: [String]
    var onRefresh: () -> Void
    var onPick: (String) -> Void
    private let popover = NSPopover()
    private let search = NSSearchField()
    private let table = NSTableView()

    init(models: [String], selected: String?, placeholder: String, onRefresh: @escaping () -> Void,
         onPick: @escaping (String) -> Void) {
        self.models = models
        shown = models
        self.onRefresh = onRefresh
        self.onPick = onPick
        super.init(frame: .zero, pullsDown: false)
        addItem(withTitle: selected ?? placeholder)
        controlSize = .regular
        (cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingMiddle
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 换列表（验证了密钥、刷新了）和显示的名字。
    func set(models: [String], selected: String?, placeholder: String) {
        self.models = models
        shown = models
        removeAllItems()
        addItem(withTitle: selected ?? placeholder)
    }

    // 不弹系统菜单，弹自己的列表
    override func mouseDown(with event: NSEvent) {
        if isEnabled { openList() }
    }

    override func performClick(_ sender: Any?) {
        if isEnabled { openList() }
    }

    @objc private func openList() {
        let controller = NSViewController()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 360))
        search.placeholderString = "搜索模型"
        search.delegate = self
        search.stringValue = ""
        shown = models
        let column = NSTableColumn(identifier: .init("model"))
        if table.tableColumns.isEmpty { table.addTableColumn(column) }
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 24
        table.target = self
        table.action = #selector(picked)
        table.reloadData()
        let scroll = OverlayScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        let line = NSBox()
        line.boxType = .separator
        let count = NSTextField(labelWithString: "共 \(models.count) 个")
        count.font = .systemFont(ofSize: 11.5)
        count.textColor = .secondaryLabelColor
        let refresh = SettingButton(title: "刷新列表", symbol: "arrow.clockwise") { [weak self] in
            self?.popover.close()
            self?.onRefresh()
        }
        refresh.isBordered = false
        refresh.font = .systemFont(ofSize: 12)
        refresh.contentTintColor = .linkColor
        for view in [search, scroll, line, count, refresh] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: line.topAnchor),
            line.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -34),
            count.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            count.centerYAnchor.constraint(equalTo: root.bottomAnchor, constant: -17),
            refresh.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            refresh.centerYAnchor.constraint(equalTo: count.centerYAnchor),
        ])
        controller.view = root
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeFirstResponder(search)
    }

    func controlTextDidChange(_ obj: Notification) {
        let query = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        shown = query.isEmpty ? models : models.filter { $0.lowercased().contains(query) }
        table.reloadData()
    }

    // 搜索框里按 ⏎ 选第一个
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)), let first = shown.first else { return false }
        choose(first)
        return true
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: shown[row])
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }

    @objc private func picked() {
        guard table.clickedRow >= 0, table.clickedRow < shown.count else { return }
        choose(shown[table.clickedRow])
    }

    private func choose(_ model: String) {
        popover.close()
        removeAllItems()
        addItem(withTitle: model)
        onPick(model)
    }
}
