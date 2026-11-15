//! 混合编码词表：编码里有字母的词，`Azuo` → A座、`OKla` → OK啦、`jizijie` → GB。
//!
//! 来自万象的 `dicts/mixed.dict.yaml`（万象方案里是单独一个 table_translator）。这些词进不了主词库：
//! 主词库的每个音节都得是合法拼音，「A」不是。所以和英文词表一样单独放一张表，整串输入正好是
//! 某个编码时把词加进候选（`Engine::insert_mixed_code`）。

/// 一条：编码（小写、不带隔音符）、词、分好段的编码（编辑区里显示成 a'zuo）。
struct Entry {
    code: String,
    word: String,
    segments: String,
    /// 词表里的编码带大写字母（A'zuò）。不带的多半是整个拼音（fēn'bèi → dB），排得靠后一些。
    lettered: bool,
}

/// 查到的一个词。
pub(crate) struct MixedWord<'a> {
    pub(crate) word: &'a str,
    pub(crate) segments: &'a str,
    pub(crate) lettered: bool,
}

/// 按编码排好序的混合编码词表。
#[derive(Default)]
pub(crate) struct MixedWords {
    entries: Vec<Entry>,
}

impl MixedWords {
    pub(crate) fn len(&self) -> usize {
        self.entries.len()
    }

    /// 编码正好是 `code`（要小写）的词，按词表里的先后。
    pub(crate) fn get<'a>(&'a self, code: &'a str) -> impl Iterator<Item = MixedWord<'a>> {
        let start = self.entries.partition_point(|e| e.code.as_str() < code);
        self.entries[start..]
            .iter()
            .take_while(move |e| e.code == code)
            .map(|e| MixedWord {
                word: &e.word,
                segments: &e.segments,
                lettered: e.lettered,
            })
    }

    /// 读 rime 的词表（`词<TAB>编码[<TAB>词频]`，编码各段用 ' 隔开，拼音带声调）。
    ///
    /// 编码去掉声调、去掉隔音符后只剩字母的才要：带数字、连字符的（歼-6 `jiān-6`、2B）
    /// 打字时数字是选词用的，打不出来。编码和词一样的（OK `OK`）也不要，那是英文词表的事。
    pub(crate) fn parse(text: &str) -> Self {
        let body = text.split_once("\n...\n").map_or(text, |(_, body)| body);
        let mut entries = Vec::new();
        for line in body.lines() {
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let mut fields = line.split('\t');
            let (Some(word), Some(code)) = (fields.next(), fields.next()) else {
                continue;
            };
            let Some(segments) = code
                .split('\'')
                .map(crate::wanxiang::plain_pinyin)
                .collect::<Option<Vec<_>>>()
            else {
                continue;
            };
            // 一段里不能有空格（plain_pinyin 把多个音节用空格连起来）
            if segments.is_empty() || segments.iter().any(|s| s.contains(' ')) {
                continue;
            }
            let joined = segments.concat();
            if joined.eq_ignore_ascii_case(word) {
                continue;
            }
            entries.push(Entry {
                lettered: code.bytes().any(|b| b.is_ascii_uppercase()),
                code: joined,
                word: word.to_string(),
                segments: segments.join(" "),
            });
        }
        // 稳定排序：同一个编码的词保持词表里的先后
        entries.sort_by(|a, b| a.code.cmp(&b.code));
        Self { entries }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_mixed_codes() {
        let words = MixedWords::parse(
            "# 注释\n---\nname: mixed\n...\n2B\t2B\nA座\tA'zuò\nA作\tA'zuò\nOK啦\tOK'la\nGB\tjí'zì'jié\n\
             歼-6\tjiān-6\nOK\tOK\nC++编程\tC'jiā'jiā'biān'chéng\n",
        );
        let get = |code: &str| {
            words
                .get(code)
                .map(|m| format!("{}|{}", m.word, m.segments))
                .collect::<Vec<_>>()
        };
        assert_eq!(get("azuo"), ["A座|a zuo", "A作|a zuo"], "同一个编码的词按词表的先后");
        assert_eq!(get("okla"), ["OK啦|ok la"]);
        assert_eq!(get("jizijie"), ["GB|ji zi jie"]);
        assert_eq!(get("cjiajiabiancheng"), ["C++编程|c jia jia bian cheng"]);
        assert!(get("2b").is_empty() && get("jian6").is_empty(), "带数字、连字符的打不出来，不要");
        assert!(get("ok").is_empty(), "编码和词一样的不要");
        assert!(get("azu").is_empty(), "要整个编码对上");
        assert_eq!(words.len(), 5);
        assert!(words.get("azuo").all(|m| m.lettered));
        assert!(words.get("jizijie").all(|m| !m.lettered), "编码整个是拼音");
    }
}
