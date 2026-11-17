//
//  RimeCustom.swift
//  WoType
//
//  WoType 的设置写成万象方案的补丁文件（*.custom.yaml），放在 Rime 用户目录（docs/22）。
//  改的是要重新部署才生效的：模糊音、双拼方案（万象的拼写运算，只重建拼写表，0.3 秒）、纠错，
//  还有关掉万象的「退格限制」；自定义词和快捷短语写成万象的自定义短语（custom_phrase.dict.yaml，置顶，重新部署 0.2 秒）。
//  不用重新部署的开关（繁体、表情）在会话上直接设（RimeSession.apply）。
//  还有一个 Lua 过滤器（lua/wotype_learned.lua）：标出纯学出来的词，候选窗画小圆点。
//  文件由 WoType 管：手改会被覆盖；万象的 /flypy 这类切换双拼的命令改的也是这几个文件，下次设置一变就改回设置里的。
//

import Foundation
import os

nonisolated struct RimeCustom: Equatable {
    /// 开着的模糊音（设置面板的 id，按面板顺序）
    var fuzzy: [String]
    /// 双拼方案在万象里的名字；全拼是 nil
    var shuangpin: String?
    var correction: Bool
    /// 自定义短语的条目（custom_phrase.dict.yaml 的一行：已经转义好的文字、编码）
    var phrases: [Phrase]
    /// 带光标位置的快捷短语：上屏的文字 → 光标要往左退几个字（UTF-16）
    var cursors: [String: Int]

    struct Phrase: Equatable {
        let text: String
        let code: String
    }

    /// words、quickPhrases 默认读 WoType 的 custom.tsv、quick-phrases.tsv（设置里关了快捷短语就不要）。在主线程建
    @MainActor init(_ config: Config, words: [CustomWord]? = nil, quickPhrases: [QuickPhrase]? = nil) {
        fuzzy = config.wanxiangFuzzyRules.filter { Self.fuzzyNames[$0] != nil }
        shuangpin = config.shuangpin ? Self.shuangpinNames[config.shuangpinProfile] ?? "自然码" : nil
        correction = config.wanxiangTypoCorrection
        phrases = []
        cursors = [:]
        // 自定义词：全拼和简拼都排第一（照水杉）；一个字的不加简拼，免得单个字母就出它
        for word in words ?? CustomWords.load() {
            let syllables = word.pinyin.split(whereSeparator: { $0 == " " || $0 == "'" }).map { $0.lowercased() }
            guard !syllables.isEmpty, !word.word.isEmpty else { continue }
            phrases.append(Phrase(text: Self.escape(word.word), code: syllables.joined()))
            if syllables.count > 1 {
                phrases.append(Phrase(text: Self.escape(word.word), code: String(syllables.compactMap(\.first))))
            }
        }
        for phrase in quickPhrases ?? (config.quickPhraseCandidates ? QuickPhrases.load() : []) {
            let (text, suffix) = Self.expandCursor(phrase.text)
            guard !text.isEmpty else { continue }
            phrases.append(Phrase(text: Self.escape(text), code: phrase.code))
            if let suffix, suffix > 0 { cursors[text] = suffix }
        }
    }

    /// 快捷短语的光标标记（照水杉的 expand_quick_phrase）：第一个 ${cursor} 是上屏后光标停的地方，
    /// $${cursor} 是字面的 ${cursor}。返回去掉标记的文字和光标后面还有几个字（UTF-16；没有标记是 nil）
    static func expandCursor(_ text: String) -> (text: String, suffix: Int?) {
        let marker = "${cursor}", placeholder = "\u{F8FF}"
        let masked = text.replacingOccurrences(of: "$" + marker, with: placeholder)
        let restore = { (part: Substring) in part.replacingOccurrences(of: placeholder, with: marker) }
        guard let range = masked.range(of: marker) else { return (restore(masked[...]), nil) }
        let after = restore(masked[range.upperBound...])
        return (restore(masked[..<range.lowerBound]) + after, after.utf16.count)
    }

    /// 自定义短语里的转义（万象 super_filter）：\n 换行、\t 制表、\s 空格、字\3 重复，[[…]] 里不转义。
    /// 原文的反斜杠放进 [[ ]]，换行、制表写成转义（制表符是文件的分隔符）
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "[[\\]]")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    /// 面板的模糊音 → wanxiang_algebra.yaml 里的那一组
    static let fuzzyNames = [
        "z=zh": "模糊音_z_zh", "c=ch": "模糊音_c_ch", "s=sh": "模糊音_s_sh", "g=k": "模糊音_kg",
        "h=f": "模糊音_hf", "n=l": "模糊音_nl", "r=l": "模糊音_rl", "r=y": "模糊音_ry",
        "en=eng": "模糊音_en_eng", "in=ing": "模糊音_in_ing",
    ]

    /// 设置里的双拼方案（Config.shuangpinProfile，和水杉共用）→ 万象的方案名。这 4 种万象的主方案、英文、
    /// 混合编码、反查都有
    static let shuangpinNames = ["xiaohe": "小鹤双拼", "ziranma": "自然码", "microsoft": "微软双拼", "shoudao": "首道双拼"]

    /// 文件头：认得出哪些是 WoType 写的（双拼关掉时只删这些）
    private static let header = "# 由 WoType 按设置生成（docs/22），手改会被覆盖\n"

    /// 要写的文件：文件名 → 内容；nil 是这个文件不该有（WoType 以前写过的要删掉）
    func files() -> [String: String?] {
        let scheme = shuangpin ?? "全拼"
        let algebra = fuzzy.compactMap { Self.fuzzyNames[$0] } + ["base/\(scheme)", "26jian"]
        var main = Self.header + "patch:\n" + Self.algebraPatch(algebra)
        main += "  translator/enable_correction: \(correction)\n"
        // 退格限制靠按键松开判断一串退格结束了：macOS 的输入法拿不到松开，状态会卡住，删不了已上屏的字。
        // 万象对鼠须管也是关掉的（wanxiang.is_special_desktop）
        main += "  super_processor/enable_backspace_limit: false\n"
        // 数字后的 , . : 不当数字分隔符挂进组字区（挂着时后面打的拼音也原样上屏：1,ni → ,ni）。
        // 数字后的标点由 InputController、RimeSession 照微信输入法处理（docs/22）
        main += "  punctuator/digit_separators: \"\"\n"
        // 标出纯学出来的词（learnedFilter）：放在最后，查系统词库用一个不带用户词库的翻译器
        main += "  engine/filters/+:\n    - lua_filter@*wotype_learned\n"
        main += "  wotype_system/dictionary: wanxiang\n  wotype_system/prism: wanxiang\n  wotype_system/enable_user_dict: false\n"
        // 英文、混合编码、反查也跟着换双拼（照万象的 set_schema.lua）；全拼时用万象默认的，不写
        let follow: ([String]) -> String? = { items in
            shuangpin == nil ? nil : Self.header + "patch:\n" + Self.algebraPatch(items)
        }
        return [
            "wanxiang.custom.yaml": main,
            "lua/wotype_learned.lua": Self.learnedFilter,
            "wanxiang_english.custom.yaml": follow(["english/混合派生", "english/\(scheme)", "26jian"]),
            "wanxiang_mixedcode.custom.yaml": follow(["mixed/混合派生", "mixed/\(scheme)", "26jian"]),
            "wanxiang_reverse.custom.yaml": follow(["reverse/\(scheme)", "reverse/hspzn", "26jian"]),
            // 一直写（没有条目也写）：盖掉万象自带的示例（b → 吧、jys → 静夜思……）
            "custom_phrase.dict.yaml": Self.header + "---\nname: custom_phrase\nversion: \"wotype\"\nsort: by_weight\n"
                + "use_preset_vocabulary: false\n...\n" + phrases.map { "\($0.text)\t\($0.code)\t100\n" }.joined(),
        ]
    }

    /// 纯学出来的词的标记（写在候选的注释里，RimeSession.isLearned 认）
    static let learnedMark = "wotype:learned"

    /// 标出纯学出来的词：用户词库里有、系统词库里没有的（分段选拼出来的「提价哦」这类），按 ⇧⌫ 能整个删掉。
    /// 学过的系统词（提交、你好）不标：它们删不掉，只会回到原来的排位，常用词都带标识就看不出哪个有问题了。
    /// librime 只告诉 App 候选的文字和注释，来源只有 Lua 看得到（类型 user_phrase）；系统词库有没有这个词，
    /// 用另一个不带用户词库的翻译器 wotype_system 查同一段拼音（librime-lua 的 Memory:dict_lookup 查不到东西，
    /// ReverseLookup 只认单字，2026-11-15 实测）。只有出现 user_phrase 时才查，一段拼音查一次
    static let learnedFilter = """
        -- 由 WoType 生成（RimeCustom.swift），手改会被覆盖
        local MARK = "\(learnedMark)"
        local LIMIT = 1000

        local function init(env)
          local ok, system = pcall(Component.Translator, env.engine, "", "script_translator@wotype_system")
          env.system = ok and system or nil
          env.known = {}
        end

        -- 系统词库给这一段拼音出的词
        local function known(env, cand)
          local context = env.engine.context
          local input = context.input
          if env.input ~= input then
            env.input = input
            env.known = {}
          end
          local key = cand.start .. ":" .. cand._end
          local words = env.known[key]
          if words then return words end
          words = {}
          env.known[key] = words
          local range = Segment(cand.start, cand._end)
          range.tags = context.composition:back().tags
          local translation = env.system:query(input:sub(cand.start + 1, cand._end), range)
          if translation then
            local n = 0
            for c in translation:iter() do
              words[c.text] = true
              n = n + 1
              if n >= LIMIT then break end
            end
          end
          return words
        end

        local function func(translation, env)
          for cand in translation:iter() do
            local genuine = cand:get_genuine()
            if env.system and genuine.type == "user_phrase" then
              local ok, words = pcall(known, env, cand)
              if ok and not words[genuine.text] then cand.comment = MARK end
            end
            yield(cand)
          end
        end

        return { init = init, func = func }

        """

    private static func algebraPatch(_ items: [String]) -> String {
        "  speller/algebra:\n    __patch:\n" + items.map { "      - wanxiang_algebra:/\($0)\n" }.joined()
    }

    /// 写进 Rime 用户目录。内容没变的文件不碰：librime 按修改时间判断要不要重新部署
    func write(to directory: URL) {
        let fm = FileManager.default
        for (name, content) in files() {
            let url = directory.appendingPathComponent(name)
            let old = try? String(contentsOf: url, encoding: .utf8)
            guard let content else {
                if old?.hasPrefix(Self.header) == true { try? fm.removeItem(at: url) }
                continue
            }
            guard old != content else { continue }
            do {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try content.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                Log.engine.error("写不了 \(name, privacy: .public)：\(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
