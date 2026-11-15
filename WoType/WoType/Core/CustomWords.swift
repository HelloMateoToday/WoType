//
//  CustomWords.swift
//  WoType
//
//  自定义词（人名、公司名、常用长句），存在 ~/Library/Application Support/WoType/custom.tsv，
//  一行一个：拼音<TAB>词。保存时同步进水杉的个人词典（MsimeHost.syncCustomWords），
//  加进来的词全拼和简拼都排第一；语音输入也拿它们当热词（VoiceVocabulary）。
//

import Foundation

nonisolated struct CustomWord: Equatable {
    var word: String
    var pinyin: String
}

enum CustomWords {

    static var fileURL: URL { Paths.userData.appendingPathComponent("custom.tsv") }

    static func load(from url: URL = fileURL) -> [CustomWord] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            if line.hasPrefix("#") { return nil }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2 else { return nil }
            let pinyin = fields[0].trimmingCharacters(in: .whitespaces)
            let word = fields[1].trimmingCharacters(in: .whitespaces)
            guard !pinyin.isEmpty, !word.isEmpty else { return nil }
            return CustomWord(word: word, pinyin: pinyin)
        }
    }

    /// 写文件，然后同步给水杉的个人词典（reload 为 false 时只写文件）。
    static func save(_ words: [CustomWord], to url: URL = fileURL, reload: Bool = true) throws {
        var text = "# WoType 自定义词：拼音<TAB>词，一行一个\n"
        for word in words {
            text += "\(word.pinyin)\t\(word.word)\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        guard reload else { return }
        MsimeHost.shared.syncCustomWords(words)
        // 万象写进自定义短语（RimeCustom），重新部署
        RimeEngine.shared.refreshCustom()
    }

    /// 用系统的汉字转拼音猜词的拼音（音节用空格分开）；多音字可能猜错，界面上让用户检查。
    static func guessPinyin(_ word: String) -> String {
        let text = NSMutableString(string: word)
        CFStringTransform(text, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(text, nil, kCFStringTransformStripDiacritics, false)
        return normalizePinyin(text as String)
    }

    /// 只留字母、隔音符和空格，小写，多个空格并成一个。
    static func normalizePinyin(_ text: String) -> String {
        let kept = text.lowercased().map { c -> Character in
            c.isASCII && (c.isLetter || c == "'") ? c : " "
        }
        return String(kept).split(separator: " ").joined(separator: " ")
    }
}
