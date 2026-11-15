//
//  QuickPhrases.swift
//  WoType
//
//  快捷短语（照水杉的快捷短语：编码只能是 1～32 个英文字母，打编码出短语），
//  存在 ~/Library/Application Support/WoType/quick-phrases.tsv，一行一个：编码<TAB>短语。
//  保存时同步进水杉的个人词典（MsimeHost.syncQuickPhrases）：打的拼音正好是编码时短语混进候选，
//  也可以按 ⇧K 进快捷短语模式再打编码。万象写进它的自定义短语（RimeCustom），打编码时置顶，没有 ⇧K 模式。
//

import Foundation

nonisolated struct QuickPhrase: Equatable {
    var code: String
    var text: String
}

enum QuickPhrases {

    static var fileURL: URL { Paths.userData.appendingPathComponent("quick-phrases.tsv") }

    /// 水杉的限制：编码 1～32 个英文字母（存成小写）
    static let maxCodeLength = 32
    /// 短语最长多少字节（水杉的上限，UTF-8；可以有换行和制表符）
    static let maxTextBytes = 4096

    static func load(from url: URL = fileURL) -> [QuickPhrase] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            if line.hasPrefix("#") { return nil }
            guard let tab = line.firstIndex(of: "\t") else { return nil }
            let code = String(line[..<tab]).trimmingCharacters(in: .whitespaces)
            let phrase = unescape(String(line[line.index(after: tab)...]))
            guard !code.isEmpty, !phrase.isEmpty else { return nil }
            return QuickPhrase(code: code, text: phrase)
        }
    }

    /// 写文件，然后同步给水杉的个人词典（reload 为 false 时只写文件）。
    static func save(_ phrases: [QuickPhrase], to url: URL = fileURL, reload: Bool = true) throws {
        var text = "# WoType 快捷短语：编码<TAB>短语，一行一个\n"
        for phrase in phrases {
            text += "\(phrase.code)\t\(escape(phrase.text))\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        guard reload else { return }
        MsimeHost.shared.syncQuickPhrases(phrases)
        // 万象写进自定义短语（RimeCustom），重新部署
        RimeEngine.shared.refreshCustom()
    }

    /// 编码：只留英文字母，小写；不合法（空、有别的字符、太长）时为 nil。
    static func normalizeCode(_ text: String) -> String? {
        let code = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard (1...maxCodeLength).contains(code.count),
              code.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        return code
    }

    // 短语里可以有换行和制表符，文件里写成 \n \t
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    private static func unescape(_ text: String) -> String {
        var result = "", escaping = false
        for c in text {
            if escaping {
                result.append(c == "n" ? "\n" : c == "t" ? "\t" : c)
                escaping = false
            } else if c == "\\" {
                escaping = true
            } else {
                result.append(c)
            }
        }
        return result
    }
}
