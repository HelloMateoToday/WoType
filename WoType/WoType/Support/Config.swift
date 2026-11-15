//
//  Config.swift
//  WoType
//
//  用户设置，存在 ~/Library/Application Support/WoType/config.json。
//  设置窗口改了立即生效：写文件、交给水杉（MsimeHost 重新准备），不用重启输入法。
//

import AppKit
import Foundation
import os

/// 语音键：按住说话，或点一下开始。都是单个修饰键，由输入法自己接（docs/10 4.1）。
nonisolated enum VoiceKey: String, Codable, CaseIterable {
    case fn
    case rightOption
    case rightCommand

    var title: String {
        switch self {
        // 有的键盘上这个键只印 🌐，有的印 fn
        case .fn: "🌐 fn"
        case .rightOption: "右 ⌥"
        case .rightCommand: "右 ⌘"
        }
    }

    /// 这个键在修饰键变化事件里的键码。
    var keyCode: UInt16 {
        switch self {
        case .fn: 63          // kVK_Function
        case .rightOption: 61 // kVK_RightOption
        case .rightCommand: 54 // kVK_RightCommand
        }
    }

    /// 按着时修饰键状态里的那一位。
    var flag: NSEvent.ModifierFlags {
        switch self {
        case .fn: .function
        case .rightOption: .option
        case .rightCommand: .command
        }
    }
}

/// 候选窗皮肤（配色见 Theme.swift）。
nonisolated enum Skin: String, Codable, CaseIterable {
    case wechat
    case sogouOrange
    case macosClassic

    var title: String {
        switch self {
        case .wechat: "微信"
        case .sogouOrange: "搜狗橘色"
        case .macosClassic: "macOS 经典"
        }
    }
}

/// 润色在哪儿跑（Arion 的 PolishEngine）。
nonisolated enum PolishEngine: String, Codable {
    case local
    case cloud
}

/// 语音翻译的目标语言（Arion packages/core/domain/rewrite.go 的 TranslationLanguages，名字是它的简体中文文案）。
nonisolated enum TranslationLanguage: String, Codable, CaseIterable {
    case en, zhCN = "zh-CN", zhTW = "zh-TW", ja, ko, es, fr, de, pt, it, ru, ar

    var title: String {
        switch self {
        case .en: "英语"
        case .zhCN: "简体中文"
        case .zhTW: "繁体中文"
        case .ja: "日语"
        case .ko: "韩语"
        case .es: "西班牙语"
        case .fr: "法语"
        case .de: "德语"
        case .pt: "葡萄牙语"
        case .it: "意大利语"
        case .ru: "俄语"
        case .ar: "阿拉伯语"
        }
    }
}

/// 模糊音规则（设置面板里的一个开关）。两个引擎各有一套（docs/15）：水杉支持 11 条（MsimeSettings.fuzzyRuleNames
/// 换成水杉的名字），万象 10 条（万象方案 wanxiang_algebra.yaml 自带的 10 组，RimeCustom 换成它的名字，docs/22）。
nonisolated struct FuzzyRule: Equatable {
    let id: String
    /// 面板里显示的样子：z = zh。
    var title: String { id.replacingOccurrences(of: "=", with: " = ") }

    enum Group: String, CaseIterable {
        case initial = "声母"
        case final = "韵母"
    }

    static let groups: [(Group, [FuzzyRule])] = [
        // 水杉支持的 11 条（client-core 的 FuzzyPinyinRule）
        (.initial, ["z=zh", "c=ch", "s=sh", "h=f", "n=l", "r=l"].map(FuzzyRule.init)),
        (.final, ["an=ang", "en=eng", "in=ing", "ian=iang", "uan=uang"].map(FuzzyRule.init)),
    ]

    /// 万象的 10 条：万象方案自带的模糊音（2026-11-15 前是旧引擎的 18 条，万象没有的 8 条去掉了）
    static let wanxiangGroups: [(Group, [FuzzyRule])] = [
        (.initial, ["z=zh", "c=ch", "s=sh", "g=k", "h=f", "n=l", "r=l", "r=y"].map(FuzzyRule.init)),
        (.final, ["en=eng", "in=ing"].map(FuzzyRule.init)),
    ]

    /// 这个引擎的规则（按设置面板分组）。
    static func groups(for engine: String) -> [(Group, [FuzzyRule])] {
        engine == "wanxiang" ? wanxiangGroups : groups
    }

    /// 面板里的一对例字：开了这条，这两个字的拼音当成一样的。
    var example: String {
        Self.examples[id] ?? ""
    }

    private static let examples = [
        "z=zh": "资 · 知", "c=ch": "次 · 吃", "s=sh": "四 · 是",
        "h=f": "湖 · 福", "n=l": "你 · 里", "r=l": "热 · 乐",
        "an=ang": "班 · 帮", "en=eng": "分 · 风", "in=ing": "民 · 明",
        "ian=iang": "年 · 娘", "uan=uang": "关 · 光",
        "g=k": "个 · 可", "r=y": "肉 · 有", "an=ai": "班 · 白", "eng=ong": "横 · 红",
        "un=ong": "顿 · 动", "un=iong": "群 · 穷", "hui=fei": "会 · 费", "huang=wang": "黄 · 王",
    ]

    static var all: [FuzzyRule] { groups.flatMap(\.1) }
    static var wanxiangAll: [FuzzyRule] { wanxiangGroups.flatMap(\.1) }

    /// 默认开的几条：平翘舌和前后鼻音。
    static let defaults = ["z=zh", "c=ch", "s=sh", "an=ang", "en=eng", "in=ing", "ian=iang", "uan=uang"]

    private init(_ id: String) { self.id = id }
}

nonisolated struct Config: Codable, Equatable {
    /// 候选窗皮肤，默认微信
    var skin = Skin.wechat
    /// 拼音引擎：msime 水杉（默认），wanxiang 万象（docs/15）。PinyinEngines.current 按它选
    var pinyinEngine = "msime"
    /// 候选窗最上面再显示一遍正在打的拼音（输入框里不显示拼音的应用靠它）。
    var showPinyinInPanel = true
    var emojiSuggest = true
    /// 紧跟在数字后面的 . 和 : 原样输出（3.14、12:30）。
    var asciiPunctAfterDigit = true
    /// / 键输入顿号「、」。
    var slashDunhao = true
    /// （【《“‘ 自动补上右半边，光标停在中间（照水杉：后半个先留在编辑区末尾）。
    var autoPair = false
    /// 中文与英文、数字之间自动加空格（水杉的 chinese_english_spacing、cross_commit_spacing）。
    var spaceCJKLatin = false
    /// 拆字反查：没在打字时按 ⇧C，再打字的各个部件的拼音找字（水杉的 local_modes.chaizi，桌面默认关）。
    var chaizi = false
    /// v 加数字转中文数字（v234 → 二百三十四）。只有万象有；微信输入法没有，默认关
    var vNumber = false
    /// 打的拼音正好是快捷短语的编码时，短语混进候选（水杉的 mixed_input.quick_phrase；水杉新装默认关，WoType 默认开）。
    var quickPhraseCandidates = true
    /// 云候选：停顿时把还没上屏的拼音发给 Google 要一个候选（水杉的 cloud_candidates，默认关）。
    var cloudCandidates = false
    /// 候选翻译：候选窗开着时单按 ⌃，把高亮的候选翻成 translationTarget，⏎ 上屏译文（FreeTranslate，默认关）。
    var candidateTranslation = false
    /// 翻成哪种语言（FreeTranslate 的语言代码：en、es、pt-BR…）
    var translationTarget = "en"
    /// 用哪家翻：auto 是几家轮着用、失败换下一家；别的是 FreeTranslate 的 provider id，只用这一家
    var translationEngine = "auto"
    /// 划词翻译（docs/16，快捷键存在 KeyboardShortcuts 自己的 UserDefaults 里）：两个功能分开开关，默认都关。
    /// 翻译并替换（⌃⌥I）：输入框里选中的（没选中是整个输入框）换成译文
    var selectionReplace = false
    /// 翻译并显示（⌃⌥T）：任何地方选中的文字（网页也行），译文显示在气泡里
    var selectionShow = false
    /// 翻成哪种语言（FreeTranslate 的语言代码，多一个 zh-Hans）
    var selectionTarget = "en"
    /// 智能方向：原文已经是目标语言时改翻成简体中文（目标是简体中文时改翻成英语）
    var selectionSmartDirection = true
    /// 用什么翻：auto、FreeTranslate 的 provider id（机器翻译），ai.cloud（AI 翻译，用 selectionCloudModel）
    var selectionEngine = "auto"
    /// AI 翻译选的云端模型（selectionEngine 是 ai.cloud 时用）
    var selectionCloudModel: String?
    /// 开着的模糊音规则（按设置面板的顺序）；空表示不用模糊音。
    var fuzzyRules: [String] = []
    /// 万象的模糊音规则，和水杉的分开存（docs/15）
    var wanxiangFuzzyRules: [String] = []

    /// 当前引擎的模糊音规则（设置面板改的是这份）
    static func fuzzyRulesKey(for engine: String) -> WritableKeyPath<Config, [String]> {
        engine == "wanxiang" ? \.wanxiangFuzzyRules : \.fuzzyRules
    }
    var typoCorrection = true
    /// 万象的按错键纠正（librime 的 translator/enable_correction）。默认关：开了整句首选掉 6～7 个点、每键慢一倍（docs/22）
    var wanxiangTypoCorrection = false
    /// 每天检查一次水杉的词库，有新版自动下载更新（MsimeHost.refreshLexicon）。默认关：要用户自己点更新。
    var autoUpdateLexicon = false
    /// 每天检查一次万象的词库，有新版自动下载更新（RimeLexiconUpdater）。默认关
    var wanxiangAutoUpdateLexicon = false
    var shuangpin = false
    var traditional = false
    /// 整句模型：none 不用，small 逐键重排的小模型（随 App），large 再加停顿后重排的大模型（要下载 24 MB），
    /// fluent 流畅优先：按键上不跑模型，只在停顿时用大模型排
    var msimeModel = "small"
    /// 双拼方案（水杉的 shuangpin_profile）
    var shuangpinProfile = "ziranma"
    var voice = true
    /// 语音键，默认右 ⌘（翻译键默认右 ⌥）
    var voiceKey = VoiceKey.rightCommand
    /// 开始、结束录音时的提示音（照 Arion，默认开）
    var voiceSound = true
    /// 输入设备的 UID，空是系统默认
    var voiceInputDevice = ""
    /// 输入增益（dB）：-6、-3、0、3、6、9、12
    var voiceGain = 0
    /// 润色：用本机的润色模型整理说的话（照 Arion，默认开；模型没下载时不润色）
    var voicePolish = true
    /// 润色时参考的上下文（照 Arion 的 ContextPolicy；WoType 默认都关）：光标前后的文字、窗口里看得到的文字、最近的听写
    var voiceContextCursor = false
    var voiceContextScreen = false
    var voiceContextHistory = false
    /// 用户给 App 指定的润色场景（Arion 的 SceneOverrides）：bundle ID（在搜索框里是「search@」+ bundle ID）→ 场景
    /// （chat、email、work、prompt、search）。没指定的按内置规则
    var voiceSceneOverrides: [String: String] = [:]
    /// 从我的修改中学习（照 Arion 的 LearnEdits；WoType 默认关）
    var voiceLearnEdits = false
    /// 润色用本机模型还是云端模型（voicePolish 关了也记着：语音翻译用它）
    var voicePolishEngine = PolishEngine.local
    /// 语音翻译的按键（默认右 ⌥；nil 是关了翻译）。不能和语音键相同
    var voiceTranslateKey: VoiceKey? = .rightOption
    /// 关掉翻译时记住的按键，再打开时恢复（Arion 的 PreviousTranslateKey）
    var voicePreviousTranslateKey: VoiceKey?
    /// 翻译为（照 Arion 默认英语）
    var voiceTranslateLanguage = TranslationLanguage.en
    /// 翻译用本机模型还是云端模型（WoType 加的，和润色分开选；Arion 跟着润色走），默认本机
    var voiceTranslateEngine = PolishEngine.local
    /// 老版本：在用的服务商和每个服务商选的模型。只在升级时读一次，换成 cloudModels（CloudPolish.migrate）
    var voiceCloudProvider: String?
    var voiceCloudModels: [String: String] = [:]
    /// 添加的云端模型（密钥按 id 存在 cloud-keys.json 里，CloudPolish）
    var cloudModels: [CloudModel] = []
    /// 润色、翻译选「云端」时用哪个云端模型（CloudModel.id）
    var voicePolishCloudModel: String?
    var voiceTranslateCloudModel: String?
    /// 必要时允许推理（Arion 的 CloudReasoning，默认关）
    var voiceCloudReasoning = false
    /// 识别方式：本机，或体验渠道（docs/21）
    var voiceRecognizer = VoiceRecognizer.local
    /// 看过说明、同意用的体验渠道（TrialChannel 的 rawValue）：第一次选时弹一次说明
    var voiceTrialAccepted: [String] = []
    /// 添加的云端识别（密钥按 id 存在 cloud-keys.json 里，CloudSpeech）
    var cloudSpeechModels: [CloudSpeechModel] = []

    init() {}

    /// 文件里没写的项（老版本的配置、手改删掉的项）用默认值。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        skin = (try? c.decodeIfPresent(Skin.self, forKey: .skin)) ?? d.skin
        showPinyinInPanel = try c.decodeIfPresent(Bool.self, forKey: .showPinyinInPanel) ?? d.showPinyinInPanel
        emojiSuggest = try c.decodeIfPresent(Bool.self, forKey: .emojiSuggest) ?? d.emojiSuggest
        asciiPunctAfterDigit = try c.decodeIfPresent(Bool.self, forKey: .asciiPunctAfterDigit) ?? d.asciiPunctAfterDigit
        slashDunhao = try c.decodeIfPresent(Bool.self, forKey: .slashDunhao) ?? d.slashDunhao
        autoPair = try c.decodeIfPresent(Bool.self, forKey: .autoPair) ?? d.autoPair
        spaceCJKLatin = try c.decodeIfPresent(Bool.self, forKey: .spaceCJKLatin) ?? d.spaceCJKLatin
        chaizi = try c.decodeIfPresent(Bool.self, forKey: .chaizi) ?? d.chaizi
        vNumber = try c.decodeIfPresent(Bool.self, forKey: .vNumber) ?? d.vNumber
        quickPhraseCandidates = try c.decodeIfPresent(Bool.self, forKey: .quickPhraseCandidates) ?? d.quickPhraseCandidates
        cloudCandidates = try c.decodeIfPresent(Bool.self, forKey: .cloudCandidates) ?? d.cloudCandidates
        candidateTranslation = try c.decodeIfPresent(Bool.self, forKey: .candidateTranslation) ?? d.candidateTranslation
        translationTarget = try c.decodeIfPresent(String.self, forKey: .translationTarget) ?? d.translationTarget
        translationEngine = try c.decodeIfPresent(String.self, forKey: .translationEngine) ?? d.translationEngine
        // 以前只有一个总开关 selectionTranslation（2026-11-12 拆成两个）：不沿用，两个都从关着开始
        selectionReplace = try c.decodeIfPresent(Bool.self, forKey: .selectionReplace) ?? d.selectionReplace
        selectionShow = try c.decodeIfPresent(Bool.self, forKey: .selectionShow) ?? d.selectionShow
        selectionTarget = try c.decodeIfPresent(String.self, forKey: .selectionTarget) ?? d.selectionTarget
        selectionSmartDirection = try c.decodeIfPresent(Bool.self, forKey: .selectionSmartDirection) ?? d.selectionSmartDirection
        selectionEngine = try c.decodeIfPresent(String.self, forKey: .selectionEngine) ?? d.selectionEngine
        // 本机模型那一项删掉了（2026-11-12）：选着它的改回「自动」
        if selectionEngine == "ai.local" { selectionEngine = d.selectionEngine }
        selectionCloudModel = try c.decodeIfPresent(String.self, forKey: .selectionCloudModel)
        if let rules = try? c.decodeIfPresent([String].self, forKey: .fuzzyRules) {
            let known = Set(FuzzyRule.all.map(\.id))
            fuzzyRules = rules.filter(known.contains)
        } else if try c.decodeIfPresent(Bool.self, forKey: .fuzzy) == true {
            // 老版本只有一个总开关：开着的换成默认那几条
            fuzzyRules = FuzzyRule.defaults
        }
        if let rules = try? c.decodeIfPresent([String].self, forKey: .wanxiangFuzzyRules) {
            wanxiangFuzzyRules = rules.filter(Set(FuzzyRule.wanxiangAll.map(\.id)).contains)
        }
        wanxiangAutoUpdateLexicon = try c.decodeIfPresent(Bool.self, forKey: .wanxiangAutoUpdateLexicon)
            ?? d.wanxiangAutoUpdateLexicon
        typoCorrection = try c.decodeIfPresent(Bool.self, forKey: .typoCorrection) ?? d.typoCorrection
        wanxiangTypoCorrection = try c.decodeIfPresent(Bool.self, forKey: .wanxiangTypoCorrection) ?? d.wanxiangTypoCorrection
        autoUpdateLexicon = try c.decodeIfPresent(Bool.self, forKey: .autoUpdateLexicon) ?? d.autoUpdateLexicon
        shuangpin = try c.decodeIfPresent(Bool.self, forKey: .shuangpin) ?? d.shuangpin
        traditional = try c.decodeIfPresent(Bool.self, forKey: .traditional) ?? d.traditional
        msimeModel = try c.decodeIfPresent(String.self, forKey: .msimeModel) ?? d.msimeModel
        pinyinEngine = try c.decodeIfPresent(String.self, forKey: .pinyinEngine) ?? d.pinyinEngine
        shuangpinProfile = try c.decodeIfPresent(String.self, forKey: .shuangpinProfile) ?? d.shuangpinProfile
        voice = try c.decodeIfPresent(Bool.self, forKey: .voice) ?? d.voice
        // 换了存的键名：以前的 voiceKey 是语音还不能用时存下的默认值（右 ⌥），不算用户选的，用默认值
        voiceKey = (try? c.decodeIfPresent(VoiceKey.self, forKey: .voiceKey)) ?? d.voiceKey
        voiceSound = try c.decodeIfPresent(Bool.self, forKey: .voiceSound) ?? d.voiceSound
        voiceInputDevice = try c.decodeIfPresent(String.self, forKey: .voiceInputDevice) ?? d.voiceInputDevice
        voicePolish = try c.decodeIfPresent(Bool.self, forKey: .voicePolish) ?? d.voicePolish
        voiceContextCursor = try c.decodeIfPresent(Bool.self, forKey: .voiceContextCursor) ?? d.voiceContextCursor
        voiceContextScreen = try c.decodeIfPresent(Bool.self, forKey: .voiceContextScreen) ?? d.voiceContextScreen
        voiceContextHistory = try c.decodeIfPresent(Bool.self, forKey: .voiceContextHistory) ?? d.voiceContextHistory
        voiceSceneOverrides = try c.decodeIfPresent([String: String].self, forKey: .voiceSceneOverrides) ?? d.voiceSceneOverrides
        voiceLearnEdits = try c.decodeIfPresent(Bool.self, forKey: .voiceLearnEdits) ?? d.voiceLearnEdits
        voicePolishEngine = (try? c.decodeIfPresent(PolishEngine.self, forKey: .voicePolishEngine)) ?? d.voicePolishEngine
        // 翻译键存成名字，「off」是关了
        if let name = try c.decodeIfPresent(String.self, forKey: .voiceTranslateKey) {
            voiceTranslateKey = VoiceKey(rawValue: name)
        } else {
            voiceTranslateKey = d.voiceTranslateKey
        }
        voicePreviousTranslateKey = (try? c.decodeIfPresent(String.self, forKey: .voicePreviousTranslateKey))
            .flatMap { $0.flatMap(VoiceKey.init(rawValue:)) }
        voiceTranslateLanguage = (try? c.decodeIfPresent(TranslationLanguage.self, forKey: .voiceTranslateLanguage))
            ?? d.voiceTranslateLanguage
        voiceTranslateEngine = (try? c.decodeIfPresent(PolishEngine.self, forKey: .voiceTranslateEngine)) ?? d.voiceTranslateEngine
        voiceCloudProvider = try c.decodeIfPresent(String.self, forKey: .voiceCloudProvider)
        voiceCloudModels = try c.decodeIfPresent([String: String].self, forKey: .voiceCloudModels) ?? d.voiceCloudModels
        voiceCloudReasoning = try c.decodeIfPresent(Bool.self, forKey: .voiceCloudReasoning) ?? d.voiceCloudReasoning
        cloudModels = (try? c.decodeIfPresent([CloudModel].self, forKey: .cloudModels)) ?? d.cloudModels
        voiceRecognizer = (try? c.decodeIfPresent(VoiceRecognizer.self, forKey: .voiceRecognizer)) ?? d.voiceRecognizer
        voiceTrialAccepted = (try? c.decodeIfPresent([String].self, forKey: .voiceTrialAccepted)) ?? d.voiceTrialAccepted
        // 一项一项读：认不得的服务商（比如没接的）跳过，不连累别的
        cloudSpeechModels = ((try? c.decodeIfPresent([Lossy<CloudSpeechModel>].self, forKey: .cloudSpeechModels)) ?? nil)?
            .compactMap(\.value) ?? d.cloudSpeechModels
        voicePolishCloudModel = try c.decodeIfPresent(String.self, forKey: .voicePolishCloudModel)
        voiceTranslateCloudModel = try c.decodeIfPresent(String.self, forKey: .voiceTranslateCloudModel)
        // 翻译键和语音键撞了：翻译先关掉、记住原来的键（Arion preferences.go 的 HoldKeysConflict）
        if voiceTranslateKey == voiceKey {
            voicePreviousTranslateKey = voiceTranslateKey
            voiceTranslateKey = nil
        }
        voiceGain = min(max(try c.decodeIfPresent(Int.self, forKey: .voiceGain) ?? d.voiceGain, -6), 12)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(skin, forKey: .skin)
        try c.encode(showPinyinInPanel, forKey: .showPinyinInPanel)
        try c.encode(emojiSuggest, forKey: .emojiSuggest)
        try c.encode(asciiPunctAfterDigit, forKey: .asciiPunctAfterDigit)
        try c.encode(slashDunhao, forKey: .slashDunhao)
        try c.encode(autoPair, forKey: .autoPair)
        try c.encode(spaceCJKLatin, forKey: .spaceCJKLatin)
        try c.encode(chaizi, forKey: .chaizi)
        try c.encode(vNumber, forKey: .vNumber)
        try c.encode(quickPhraseCandidates, forKey: .quickPhraseCandidates)
        try c.encode(cloudCandidates, forKey: .cloudCandidates)
        try c.encode(candidateTranslation, forKey: .candidateTranslation)
        try c.encode(translationTarget, forKey: .translationTarget)
        try c.encode(translationEngine, forKey: .translationEngine)
        try c.encode(selectionReplace, forKey: .selectionReplace)
        try c.encode(selectionShow, forKey: .selectionShow)
        try c.encode(selectionTarget, forKey: .selectionTarget)
        try c.encode(selectionSmartDirection, forKey: .selectionSmartDirection)
        try c.encode(selectionEngine, forKey: .selectionEngine)
        try c.encodeIfPresent(selectionCloudModel, forKey: .selectionCloudModel)
        try c.encode(fuzzyRules, forKey: .fuzzyRules)
        try c.encode(wanxiangFuzzyRules, forKey: .wanxiangFuzzyRules)
        try c.encode(wanxiangAutoUpdateLexicon, forKey: .wanxiangAutoUpdateLexicon)
        try c.encode(typoCorrection, forKey: .typoCorrection)
        try c.encode(wanxiangTypoCorrection, forKey: .wanxiangTypoCorrection)
        try c.encode(autoUpdateLexicon, forKey: .autoUpdateLexicon)
        try c.encode(shuangpin, forKey: .shuangpin)
        try c.encode(traditional, forKey: .traditional)
        try c.encode(msimeModel, forKey: .msimeModel)
        try c.encode(pinyinEngine, forKey: .pinyinEngine)
        try c.encode(shuangpinProfile, forKey: .shuangpinProfile)
        try c.encode(voice, forKey: .voice)
        try c.encode(voiceKey, forKey: .voiceKey)
        try c.encode(voiceSound, forKey: .voiceSound)
        try c.encode(voiceInputDevice, forKey: .voiceInputDevice)
        try c.encode(voiceGain, forKey: .voiceGain)
        try c.encode(voicePolish, forKey: .voicePolish)
        try c.encode(voiceContextCursor, forKey: .voiceContextCursor)
        try c.encode(voiceContextScreen, forKey: .voiceContextScreen)
        try c.encode(voiceContextHistory, forKey: .voiceContextHistory)
        try c.encode(voiceSceneOverrides, forKey: .voiceSceneOverrides)
        try c.encode(voiceLearnEdits, forKey: .voiceLearnEdits)
        try c.encode(voicePolishEngine, forKey: .voicePolishEngine)
        try c.encode(voiceTranslateKey?.rawValue ?? "off", forKey: .voiceTranslateKey)
        try c.encodeIfPresent(voicePreviousTranslateKey?.rawValue, forKey: .voicePreviousTranslateKey)
        try c.encode(voiceTranslateLanguage, forKey: .voiceTranslateLanguage)
        try c.encode(voiceTranslateEngine, forKey: .voiceTranslateEngine)
        try c.encodeIfPresent(voiceCloudProvider, forKey: .voiceCloudProvider)
        try c.encode(voiceCloudModels, forKey: .voiceCloudModels)
        try c.encode(voiceCloudReasoning, forKey: .voiceCloudReasoning)
        try c.encode(cloudModels, forKey: .cloudModels)
        try c.encode(voiceRecognizer, forKey: .voiceRecognizer)
        try c.encode(voiceTrialAccepted, forKey: .voiceTrialAccepted)
        try c.encode(cloudSpeechModels, forKey: .cloudSpeechModels)
        try c.encodeIfPresent(voicePolishCloudModel, forKey: .voicePolishCloudModel)
        try c.encodeIfPresent(voiceTranslateCloudModel, forKey: .voiceTranslateCloudModel)
    }

    private enum CodingKeys: String, CodingKey {
        case skin, showPinyinInPanel, emojiSuggest, asciiPunctAfterDigit, fuzzyRules, typoCorrection, shuangpin, traditional, voice
        case voiceKey = "voiceHotkey"
        case voiceSound, voiceInputDevice, voiceGain, voicePolish, voiceContextCursor, voiceContextScreen, voiceContextHistory, voiceSceneOverrides, voiceLearnEdits
        case voicePolishEngine, voiceTranslateKey, voicePreviousTranslateKey, voiceTranslateLanguage
        case voiceCloudProvider, voiceCloudModels, voiceCloudReasoning, voiceTranslateEngine
        case cloudModels, voicePolishCloudModel, voiceTranslateCloudModel
        case voiceRecognizer, voiceTrialAccepted, cloudSpeechModels
        case slashDunhao, autoPair, spaceCJKLatin, chaizi, vNumber, quickPhraseCandidates, cloudCandidates
        case candidateTranslation, translationTarget, translationEngine
        case selectionReplace, selectionShow, selectionTarget, selectionSmartDirection, selectionEngine, selectionCloudModel
        case autoUpdateLexicon
        case msimeModel, pinyinEngine, shuangpinProfile, wanxiangFuzzyRules, wanxiangAutoUpdateLexicon, wanxiangTypoCorrection
        /// 老版本的模糊音总开关，只读不写。
        case fuzzy
    }
}

/// 当前设置。只在主线程用。
final class Settings {

    static let shared = Settings()

    /// 设置变了（设置窗口据此刷新）。
    static let didChange = Notification.Name("WoTypeSettingsDidChange")

    private(set) var config: Config

    static var fileURL: URL { Paths.userData.appendingPathComponent("config.json") }

    private init() {
        config = Self.load(from: Self.fileURL)
    }

    static func load(from url: URL) -> Config {
        guard let data = try? Data(contentsOf: url) else { return Config() }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            Log.app.error("配置文件读不了，用默认设置：\(error.localizedDescription, privacy: .public)")
            return Config()
        }
    }

    /// 改设置：写文件，交给拼音引擎，通知设置窗口。
    func update(_ change: (inout Config) -> Void) {
        var next = config
        change(&next)
        guard next != config else { return }
        let previousEngine = config.pinyinEngine
        config = next
        save()
        if config.pinyinEngine != previousEngine {
            PinyinEngines.switched(from: previousEngine)
        }
        // 交给引擎的设置变了就重新准备，空闲的输入框下次按键用上新会话
        PinyinEngines.current.settingsChanged(config)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(config).write(to: Self.fileURL, options: .atomic)
        } catch {
            Log.app.error("保存设置失败：\(error.localizedDescription, privacy: .public)")
        }
    }
}

/// 读数组时一项坏了只丢这一项。
nonisolated struct Lossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}
