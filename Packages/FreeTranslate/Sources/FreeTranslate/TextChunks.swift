// TextChunks.swift — 长文本分块（照 FluentRead 的 freeTextChunks）：按行切，空行和每行两头的空白留在本地、
// 只发正文；一行超过上限时按 Unicode 码点切，优先切在句末标点，其次空白。块按顺序逐个翻译。

import Foundation

enum TextChunks {

    /// 把 text 按 limit（码点）切好，逐块调 translate，再按原来的换行和空白拼回去。
    static func translate(_ text: String, limit: Int,
                          _ translate: (String) async throws -> String) async throws -> String {
        var output = ""
        var rest = Substring(text)
        while !rest.isEmpty {
            // 一行连同它后面的换行
            let lineEnd = rest.firstIndex(where: { $0 == "\n" || $0 == "\r" }) ?? rest.endIndex
            let line = rest[..<lineEnd]
            let breakEnd = rest[lineEnd...].firstIndex(where: { $0 != "\n" && $0 != "\r" }) ?? rest.endIndex
            output += try await translateLine(String(line), limit: limit, translate)
            output += rest[lineEnd..<breakEnd]
            rest = rest[breakEnd...]
        }
        return output
    }

    private static func translateLine(_ line: String, limit: Int,
                                      _ translate: (String) async throws -> String) async throws -> String {
        let leading = line.prefix { $0.isWhitespace }
        let trailing = String(line.reversed().prefix { $0.isWhitespace }.reversed())
        let content = line.trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return line }
        var translated: [String] = []
        for piece in split(content, limit: limit) {
            translated.append(try await translate(piece).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // 中文、日文之间不加空格，其余用空格接起来
        let joined = translated.dropFirst().reduce(translated.first ?? "") { result, next in
            guard let last = result.last, let first = next.first else { return result + next }
            return result + (isCJK(last) || isCJK(first) ? "" : " ") + next
        }
        return leading + joined + trailing
    }

    /// 一行按码点切成不超过 limit 的几段：优先在句末标点后切，其次在空白处，实在没有就硬切。
    static func split(_ line: String, limit: Int) -> [String] {
        var pieces: [String] = []
        var scalars = Array(line.unicodeScalars)
        while scalars.count > limit {
            var cut = limit
            let window = scalars[0..<limit]
            if let end = window.lastIndex(where: { sentenceEnds.contains($0) }), end > limit / 3 {
                cut = end + 1
            } else if let space = window.lastIndex(where: { $0.properties.isWhitespace }), space > limit / 3 {
                cut = space + 1
            }
            pieces.append(String(String.UnicodeScalarView(scalars[0..<cut])).trimmingCharacters(in: .whitespaces))
            scalars.removeFirst(cut)
        }
        let last = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { pieces.append(last) }
        return pieces
    }

    private static let sentenceEnds = Set("。！？；….!?;".unicodeScalars)

    private static func isCJK(_ c: Character) -> Bool {
        c.unicodeScalars.contains { (0x3000...0x9FFF).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) }
    }
}
