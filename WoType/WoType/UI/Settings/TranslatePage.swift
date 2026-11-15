//
//  TranslatePage.swift
//  WoType
//
//  设置 › 翻译设置：候选翻译、划词翻译（docs/16）、语音翻译三组，各设各的「翻译成」「翻译引擎」，写法一样。
//  划词翻译的「翻译并替换」「翻译并显示」各有开关和快捷键（默认都关，可以只开一个），下面一组两个功能共用的语言和引擎。
//

import Cocoa
import FreeTranslate
import KeyboardShortcuts

final class TranslatePage: SettingsPage {
    override var pageTitle: String { "翻译设置" }
    override var pageSubtitle: String { "打字的候选、选中的文字、说的话，都能翻译。" }

    override func build() -> [NSView] {
        NoticeBanner.banners(page: "translate", config: config) + [
            SettingsKit.sectionTitle("候选翻译"),
            SettingsKit.card(candidateRows()),
            SettingsKit.sectionTitle("划词翻译"),
            SettingsKit.card(selectionRows()),
            SettingsKit.sectionTitle("划词翻译的语言"),
            SettingsKit.card(selectionLanguageRows()),
            SettingsKit.sectionTitle("语音翻译"),
            SettingsKit.card(voiceRows()),
        ]
    }

    // MARK: - 候选翻译

    private func candidateRows() -> [NSView] {
        let targets = Language.translationTargets
        let engines = CandidateTranslator.engines
        let enabled = config.candidateTranslation
        let target = SettingPopUp(items: targets.map { $0.chineseName ?? $0.code },
                                  selected: targets.firstIndex { $0.code == config.translationTarget } ?? 0) {
            [weak self] index in self?.update { $0.translationTarget = targets[index].code }
        }
        let engine = SettingPopUp(items: engines.map(\.name),
                                  selected: engines.firstIndex { $0.id == config.translationEngine } ?? 0) {
            [weak self] index in self?.update { $0.translationEngine = engines[index].id }
        }
        // 两个选项一直显示，候选翻译关着时不能选
        target.isEnabled = enabled
        engine.isEnabled = enabled
        let supported = CandidateTranslator.engine(config.translationEngine, supports: config.translationTarget)
        return [
            SettingsKit.row(
                title: "候选翻译", detail: "打字时单按 ⌃ 翻译高亮的候选。",
                help: "译文显示在候选窗最下面一行：按 ⏎ 或点它上屏译文，空格照常上屏原文，Esc 或再按 ⌃ 收起译文。\n\n"
                    + "翻译时这段文字会通过网络发给翻译服务（微软、谷歌、腾讯等的免费网页接口）。",
                icon: SettingsIcon(symbol: "globe", color: .systemBlue),
                accessory: SettingSwitch(isOn: enabled) { [weak self] on in self?.update { $0.candidateTranslation = on } }),
            SettingsKit.row(title: "翻译成", icon: SettingsIcon(symbol: "character.bubble.fill", color: .systemOrange),
                            accessory: target),
            SettingsKit.row(title: "翻译引擎", detail: Self.machineDetail(config.translationEngine, target: config.translationTarget),
                            help: Self.machineHelp,
                            icon: SettingsIcon(symbol: "server.rack", color: supported || !enabled ? .systemGray : .systemRed),
                            accessory: engine),
        ]
    }

    // MARK: - 划词翻译

    private static let privacy = "翻译时文字会通过网络发给所选的翻译服务：机器翻译是微软、谷歌、腾讯等的免费网页接口，"
        + "AI 模型是你在「模型管理」里添加的模型。"

    private static let shortcutHelp = "点录键框后按新的组合键；点右边的 ✕ 清空就是不用这个快捷键。两个功能的快捷键不能相同。"

    /// 「翻译并替换」「翻译并显示」：各自一个开关、一个快捷键，可以只开一个。
    private func selectionRows() -> [NSView] {
        let replace = config.selectionReplace
        let show = config.selectionShow
        return [
            SettingsKit.row(
                title: "翻译并替换", detail: "在输入框里把选中的文字换成译文，没选中就翻整个输入框。",
                help: "替换后按 ⌘Z 可以撤销。翻译的时候改了输入框里的字，就不替换，改成弹出译文。\n\n" + Self.privacy,
                icon: SettingsIcon(symbol: "arrow.left.arrow.right", color: .systemIndigo),
                accessory: SettingSwitch(isOn: replace) { [weak self] on in self?.update { $0.selectionReplace = on } }),
            SettingsKit.row(title: "快捷键", help: Self.shortcutHelp,
                            icon: SettingsIcon(symbol: "command", color: .systemGray),
                            accessory: recorder(.translateReplace, other: .translateShow, enabled: replace)),
            SettingsKit.row(
                title: "翻译并显示", detail: "在选中的文字下面弹出译文，原文不动，网页、PDF 也行。",
                help: "翻译时选中文字下面转圈，翻好了弹出译文。按任意键或点外面就收起。\n\n"
                    + "选中的文字用辅助功能读；读不到时（有的应用、刚打开的网页）会替你按一次 ⌘C 复制，复制完把剪贴板还原。\n\n"
                    + Self.privacy,
                icon: SettingsIcon(symbol: "text.bubble.fill", color: .systemTeal),
                accessory: SettingSwitch(isOn: show) { [weak self] on in self?.update { $0.selectionShow = on } }),
            SettingsKit.row(title: "快捷键",
                            help: Self.shortcutHelp + "\n\n开着时这个快捷键归 WoType（切到别的输入法就还给应用）。",
                            icon: SettingsIcon(symbol: "command", color: .systemGray),
                            accessory: recorder(.translateShow, other: .translateReplace, enabled: show)),
        ]
    }

    /// 录键框（录的时候它自己要求带 ⌃、⌥ 或 ⌘，也会提示和菜单、系统快捷键撞车）。
    /// 录成和另一个一样的，就把另一个清空（两个键不能同一个）。
    private func recorder(_ name: KeyboardShortcuts.Name, other: KeyboardShortcuts.Name, enabled: Bool) -> NSView {
        let recorder = KeyboardShortcuts.RecorderCocoa(for: name) { [weak self] shortcut in
            if let shortcut, shortcut == KeyboardShortcuts.getShortcut(for: other) {
                KeyboardShortcuts.setShortcut(nil, for: other)
                DispatchQueue.main.async { self?.reload() }
            }
            // 库存快捷键时注册了全局热键：翻译并替换的要取消，翻译并显示的按开关、当前输入法重新定
            SelectionTranslation.shared.shortcutsChanged()
        }
        recorder.isEnabled = enabled
        recorder.widthAnchor.constraint(equalToConstant: SettingsKit.controlWidth).isActive = true
        return recorder
    }

    /// 两个功能共用；两个都关着时灰掉
    private func selectionLanguageRows() -> [NSView] {
        let enabled = config.selectionReplace || config.selectionShow
        let targets = SelectionTranslator.targets
        let target = SettingPopUp(items: targets.map { $0.chineseName ?? $0.code },
                                  selected: targets.firstIndex { $0.code == config.selectionTarget } ?? 0) {
            [weak self] index in self?.update { $0.selectionTarget = targets[index].code }
        }
        target.isEnabled = enabled
        let smart = SettingSwitch(isOn: config.selectionSmartDirection) { [weak self] on in
            self?.update { $0.selectionSmartDirection = on }
        }
        smart.isEnabled = enabled
        let targetName = Language(config.selectionTarget).chineseName ?? config.selectionTarget
        let smartDetail = config.selectionTarget == Language.simplifiedChinese.code
            ? "原文已经是简体中文时，翻成英语。"
            : "原文已经是\(targetName)时，翻成简体中文。"
        let detail = config.selectionEngine == SelectionTranslator.cloudEngine
            ? VoicePage.cloudStatus(.selection) : Self.machineDetail(config.selectionEngine, target: config.selectionTarget)
        return [
            SettingsKit.row(title: "翻译成", icon: SettingsIcon(symbol: "character.bubble.fill", color: .systemOrange),
                            accessory: target),
            SettingsKit.row(title: "智能方向", detail: smartDetail,
                            help: "按文字判断原文是什么语言。认不出时照常翻成上面选的语言。",
                            icon: SettingsIcon(symbol: "arrow.triangle.swap", color: .systemGreen), accessory: smart),
            SettingsKit.row(title: "翻译引擎", detail: detail,
                            help: Self.machineHelp + "\n\nAI 模型：长句更通顺、会保留格式，慢一些。用你在「模型管理」里添加的模型和你自己的 API 密钥。",
                            icon: SettingsIcon(symbol: "server.rack", color: selectionEngineWorks() || !enabled ? .systemGray : .systemRed),
                            accessory: selectionEnginePopUp(enabled: enabled)),
        ]
    }

    /// 一个下拉框，分「机器翻译」「AI 模型」两段
    private func selectionEnginePopUp(enabled: Bool) -> NSView {
        let engine = config.selectionEngine
        let popUp = ActionPopUp()
        popUp.menu?.addItem(.sectionHeader(title: "机器翻译"))
        for (id, name) in SelectionTranslator.machineEngines {
            popUp.add(name, selected: engine == id) { [weak self] in self?.update { $0.selectionEngine = id } }
        }
        let selected = engine == SelectionTranslator.cloudEngine ? config.selectionCloudModel : nil
        let models = CloudPolish.shared.models
        if !models.isEmpty {
            popUp.addSeparator()
            popUp.menu?.addItem(.sectionHeader(title: "AI 模型"))
            for model in models {
                popUp.add(model.title, selected: model.id == selected) { [weak self] in
                    self?.update { config in
                        config.selectionEngine = SelectionTranslator.cloudEngine
                        config.selectionCloudModel = model.id
                    }
                }
            }
        }
        popUp.addSeparator()
        popUp.add("添加云端模型…") {
            // 下拉框先收起、这一页还原，再跳过去（跳走时这一页会被拿掉）
            DispatchQueue.main.async { CloudModelSheet.presentAdding() }
        }
        popUp.isEnabled = enabled
        return popUp
    }

    /// 选的引擎能不能用（不能用时图标变红）
    private func selectionEngineWorks() -> Bool {
        switch config.selectionEngine {
        case SelectionTranslator.cloudEngine: CloudPolish.shared.ready(.selection)
        case let id: CandidateTranslator.engine(id, supports: config.selectionTarget)
        }
    }

    // MARK: - 语音翻译

    /// 语音翻译（照 Arion 的 holdkey.go 翻译部分）：开关、翻译键（不能和语音键相同）、翻译成、翻译引擎。
    /// 要先开语音输入。
    private func voiceRows() -> [NSView] {
        let voice = config.voice
        let key = config.voiceTranslateKey
        let enabled = SettingSwitch(isOn: key != nil) { [weak self] on in
            self?.update { config in
                if on {
                    // 恢复关掉前的键；撞了语音键就换一个没被占的
                    let previous = config.voicePreviousTranslateKey ?? .rightOption
                    config.voiceTranslateKey = previous != config.voiceKey
                        ? previous : VoiceKey.allCases.first { $0 != config.voiceKey }
                } else {
                    config.voicePreviousTranslateKey = config.voiceTranslateKey
                    config.voiceTranslateKey = nil
                }
            }
        }
        enabled.isEnabled = voice
        let on = voice && key != nil
        let shown = key ?? config.voicePreviousTranslateKey ?? .rightOption
        let keyPopUp = SettingPopUp(items: VoiceKey.allCases.map(\.title),
                                    selected: VoiceKey.allCases.firstIndex(of: shown) ?? 0) { [weak self] index in
            self?.update { $0.voiceTranslateKey = VoiceKey.allCases[index] }
        }
        keyPopUp.isEnabled = on
        VoicePage.disable(keyPopUp, key: config.voiceKey, note: "已用于听写")
        let languages = TranslationLanguage.allCases
        let language = SettingPopUp(items: languages.map(\.title),
                                    selected: languages.firstIndex(of: config.voiceTranslateLanguage) ?? 0) { [weak self] index in
            self?.update { $0.voiceTranslateLanguage = languages[index] }
        }
        language.isEnabled = on
        // 翻译用哪个模型（和润色分开选）
        let engine = ActionPopUp()
        engine.add(VoiceModelSpec.polish.title, selected: config.voiceTranslateEngine == .local) { [weak self] in
            self?.update { $0.voiceTranslateEngine = .local }
        }
        VoicePage.addCloudModels(to: engine, selected: config.voiceTranslateEngine == .cloud ? config.voiceTranslateCloudModel : nil) {
            [weak self] model in
            self?.update { config in
                config.voiceTranslateEngine = .cloud
                config.voiceTranslateCloudModel = model.id
            }
        }
        engine.isEnabled = on
        return [
            SettingsKit.row(title: "语音翻译",
                            detail: voice ? "按住翻译键说话，松开输入译文。" : "先在「语音输入」里打开语音输入。",
                            help: "按住翻译键说话，松开后直接输入译文，不用先开启润色。",
                            icon: SettingsIcon(symbol: "waveform", color: .systemIndigo), accessory: enabled),
            SettingsKit.row(title: "翻译键", icon: SettingsIcon(symbol: "command", color: .systemGray), accessory: keyPopUp),
            SettingsKit.row(title: "翻译成", icon: SettingsIcon(symbol: "character.bubble.fill", color: .systemOrange),
                            accessory: language),
            SettingsKit.row(title: "翻译引擎",
                            detail: config.voiceTranslateEngine == .local ? VoicePage.localStatus("离线") : VoicePage.cloudStatus(.translate),
                            help: "本机：离线、较快，长句和专有名词可能不够准。\n"
                                + "云端模型：用你在「模型管理」里添加的模型。",
                            icon: SettingsIcon(symbol: "server.rack", color: .systemGray), accessory: engine),
        ]
    }

    // MARK: - 小工具

    private static let machineHelp = "机器翻译：快，免费；「自动」时几家轮着用，一家不行自动换下一家。谷歌需要能访问 Google。"

    /// 机器翻译引擎那一行的说明
    private static func machineDetail(_ engine: String, target: String) -> String {
        engine == "auto" ? "几家轮着用，一家不行就换下一家。"
            : CandidateTranslator.engine(engine, supports: target)
            ? "只用这一家，它不行时不换别家。" : "这家不支持翻成所选的语言，请换一家或选「自动」。"
    }
}
