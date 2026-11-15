//
//  VoiceCorrection.swift
//  WoType
//
//  识别结果的整理和热词复读检测，照 Arion@d2108fe（AGPL-3.0-only）移植：
//  - 整理：packages/core/domain/correction.go 的 Correct（合并空格 → 拼字母缩写 → 换错误写法 → 去掉中文间的空格），
//    quotes.go 的 transformUnquoted（引号里的原样留着）。只改空格、拼缩写和用户认可的替换，不加词。
//    Qwen3-ASR 出的英文大小写本来就对，Arion 只对全大写的识别模型做的 naturalizeUppercaseLatin 不移植。
//  - 复读：apps/desktop/infrastructure/asr/echo.go 的 hotwordEcho。
//

import Foundation

nonisolated enum VoiceCorrection {

    /// 整理一段识别结果；返回整理后的文字和生效了的错误写法（用来记次数）。
    static func correct(_ raw: String, vocabulary: VocabularyIndex) -> (text: String, recalled: [VocabularyReplacement]) {
        var text = collapseWhitespace(raw)
        text = transformUnquoted(text, joinUnquotedAcronyms)
        var recalled: [VocabularyReplacement] = []
        if !vocabulary.isEmpty {
            (text, recalled) = vocabulary.apply(text)
        }
        return (joinCJKSpacing(text), recalled)
    }

    static func collapseWhitespace(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// 识别模型逐个念出来的大写字母拼回去（「A P I」→「API」）；单独一个大写字母不动，一串「I」也不动。
    static func joinUnquotedAcronyms(_ s: String) -> String {
        let fields = s.components(separatedBy: " ")
        func single(_ f: String) -> Bool {
            f.unicodeScalars.count == 1 && ("A"..."Z").contains(f.unicodeScalars.first!)
        }
        var out: [String] = []
        var i = 0
        while i < fields.count {
            var j = i
            while j < fields.count, single(fields[j]) { j += 1 }
            let firstPerson = j > i && fields[i..<j].allSatisfy { $0 == "I" }
            if j - i >= 2, !firstPerson {
                out.append(fields[i..<j].joined())
                i = j
                continue
            }
            out.append(fields[i])
            i += 1
        }
        return out.joined(separator: " ")
    }

    /// 去掉中文之间、右标点前、中文标点后的空格（识别模型拿空格分词）。
    static func joinCJKSpacing(_ s: String) -> String {
        let scalars = Array(collapseWhitespace(s).unicodeScalars)
        var out = String.UnicodeScalarView()
        for (i, r) in scalars.enumerated() {
            if r == " ", i > 0, i + 1 < scalars.count {
                let prev = scalars[i - 1], next = scalars[i + 1]
                if (VoicePCM.isCJKText(prev) && VoicePCM.isCJKText(next)) || isClosingPunct(next) || isCJKPunct(prev) {
                    continue
                }
            }
            out.append(r)
        }
        return String(out)
    }

    private static func isCJKPunct(_ r: Unicode.Scalar) -> Bool {
        (0x3000...0x303F).contains(r.value) || (0xFF00...0xFFEF).contains(r.value)
    }

    private static func isClosingPunct(_ r: Unicode.Scalar) -> Bool {
        ",.!?;:%)]}".unicodeScalars.contains(r) || isCJKPunct(r) && !"「『（【《〈".unicodeScalars.contains(r)
    }

    /// 引号里的是原话，不整理；没合上的引号保护到结尾。直的单引号只在非字母后面才算开引号（不当成 don't 的撇号）。
    private static let quoted = try! NSRegularExpression(
        pattern: "“[^”]*(?:”|$)|「[^」]*(?:」|$)|『[^』]*(?:』|$)|‘[^’]*(?:’|$)|\"[^\"]*(?:\"|$)|`[^`]*(?:`|$)|(?:^|[^\\p{L}\\p{N}])'[^']*(?:'|$)")

    static func transformUnquoted(_ text: String, _ transform: (String) -> String) -> String {
        let ns = text as NSString
        var out = ""
        var start = 0
        for m in quoted.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += transform(ns.substring(with: NSRange(location: start, length: m.range.location - start)))
            out += ns.substring(with: m.range)
            start = m.range.location + m.range.length
        }
        out += transform(ns.substring(from: start))
        return out
    }

    // MARK: - 热词复读（echo.go）

    /// Qwen3 是不是把这次的热词表念了出来。只出现一个热词是热词在起作用，留着；
    /// 连着两个以上热词、占了整句或句首或句尾才算。标点不管，开头的「气声：」不算词。
    static func hotwordEcho(_ text: String, hotwords: [String]) -> Bool {
        guard hotwords.count >= 2, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let body = Array(stripBreathLabel(text).unicodeScalars)
        guard hasSpeech(body[...]) else { return false }
        let terms = hotwords.map { Array($0.unicodeScalars) }
        for i in 0..<terms.count {
            for j in stride(from: i + 2, through: terms.count, by: 1) {
                let slice = Array(terms[i..<j])
                if exactSlice(body, slice) || prefixSlice(body, slice) || suffixSlice(body, slice) { return true }
            }
        }
        return false
    }

    private typealias Scalars = ArraySlice<Unicode.Scalar>

    private static func stripBreathLabel(_ text: String) -> String {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while body.hasPrefix("气声") {
            let after = body.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let r = after.first, r == "：" || r == ":" else { return body }
            body = after.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return body
    }

    private static func exactSlice(_ text: [Unicode.Scalar], _ terms: [[Unicode.Scalar]]) -> Bool {
        guard let rest = consume(skipGaps(text[...]), terms) else { return false }
        return !hasSpeech(skipGaps(rest))
    }

    private static func prefixSlice(_ text: [Unicode.Scalar], _ terms: [[Unicode.Scalar]]) -> Bool {
        guard let rest = consume(skipGaps(text[...]), terms) else { return false }
        return hasSpeech(rest)
    }

    private static func suffixSlice(_ text: [Unicode.Scalar], _ terms: [[Unicode.Scalar]]) -> Bool {
        for start in 0..<text.count where hasSpeech(text[..<start]) {
            if let rest = consume(text[start...], terms), !hasSpeech(skipGaps(rest)) { return true }
        }
        return false
    }

    private static func consume(_ text: Scalars, _ terms: [[Unicode.Scalar]]) -> Scalars? {
        var rest = text
        for (i, term) in terms.enumerated() {
            if term.isEmpty { return nil }
            if i > 0 {
                let skipped = skipGaps(rest)
                if skipped.count != rest.count {
                    rest = skipped
                } else if !cjkTerm(terms[i - 1]) || !cjkTerm(term) {
                    return nil
                }
            }
            guard let next = matchTerm(rest, term) else { return nil }
            guard let r = next.first else {
                rest = next
                continue
            }
            if isGap(r) {
                rest = next
                continue
            }
            if i + 1 < terms.count, cjkTerm(term), cjkTerm(terms[i + 1]), matchTerm(next, terms[i + 1]) != nil {
                rest = next
                continue
            }
            return nil
        }
        return rest
    }

    /// 不分大小写比，词里的空白对上文字里的任意空白。
    private static func matchTerm(_ text: Scalars, _ term: [Unicode.Scalar]) -> Scalars? {
        var si = text.startIndex, ti = 0
        while ti < term.count {
            if term[ti].properties.isWhitespace {
                guard si < text.endIndex, text[si].properties.isWhitespace else { return nil }
                while ti < term.count, term[ti].properties.isWhitespace { ti += 1 }
                while si < text.endIndex, text[si].properties.isWhitespace { si += 1 }
                continue
            }
            guard si < text.endIndex, String(text[si]).lowercased() == String(term[ti]).lowercased() else { return nil }
            si += 1
            ti += 1
        }
        return text[si...]
    }

    private static func cjkTerm(_ term: [Unicode.Scalar]) -> Bool {
        guard let r = term.first else { return false }
        return VoicePCM.isCJKText(r) && !isCJKPunct(r)
    }

    private static func skipGaps(_ text: Scalars) -> Scalars { text.drop(while: isGap) }

    /// 空白、标点、符号
    private static func isGap(_ r: Unicode.Scalar) -> Bool {
        if r.properties.isWhitespace { return true }
        switch r.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation,
             .finalPunctuation, .otherPunctuation, .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            return true
        default:
            return false
        }
    }

    private static func hasSpeech(_ text: Scalars) -> Bool { text.contains { !isGap($0) } }
}
