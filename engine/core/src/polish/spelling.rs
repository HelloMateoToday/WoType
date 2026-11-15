//! 选同音词的候选：识别结果里哪几段和上下文里出现过的词读音一样（中文按拼音、不分声调；
//! 英文标识符按 CMU 发音词典），列出来让润色模型选「换」还是「不换」。这里只列候选、按选择替换，不做判断。
//!
//! 照 Arion packages/core/domain/spelling.go@d2108fe（AGPL-3.0-only）逐行移植（Prepare、PrepareContextual、
//! ApplySpellingChoices、选择提示里的 selectionText）；读音数据是 Arion 带的 pypinyin 字音表（MIT）和
//! CMU 发音词典（BSD），在 App 包的 Resources 里，由输入法传路径载入。
//! 没移植 earlierSourceHypotheses：它要 Arion 边说边润色时的上一版识别结果（EarlierSource），WoType 没有。

use super::text::is_letter;
use regex::Regex;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::{LazyLock, OnceLock};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Hypothesis {
    pub id: String,
    pub start: usize,
    pub end: usize,
    pub source: String,
    pub candidates: Vec<String>,
    pub status: String,
    pub kind: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Preparation {
    pub source: String,
    /// Screen、Before、After、History、Terms（按键名排序，和 Go 的 map 序列化一样）
    pub context: BTreeMap<String, String>,
    pub scene: String,
    pub hypotheses: Vec<Hypothesis>,
    pub unknown: Vec<String>,
}

/// 读音表：字 → 拼音（带声调数字）；英文词（小写）→ 几种读法（去掉重音数字的音素）。
#[derive(Default)]
pub struct Lexicon {
    pub readings: HashMap<char, Vec<String>>,
    pub english: HashMap<String, Vec<Vec<String>>>,
}

static LEXICON: OnceLock<Lexicon> = OnceLock::new();

/// 载入读音表（只载一次）。readings 是 pypinyin 的 {"字":["fei1",…],…}，dictionary 是 cmudict.dict 的文字。
pub fn load(readings: &str, dictionary: &str) -> bool {
    if LEXICON.get().is_some() {
        return true;
    }
    let Some(readings) = parse_readings(readings) else { return false };
    let _ = LEXICON.set(Lexicon { readings, english: parse_cmudict(dictionary) });
    true
}

pub fn lexicon() -> Option<&'static Lexicon> {
    LEXICON.get()
}

/// 只认这一种形状的 JSON：{"字":["读音",…],…}。
fn parse_readings(text: &str) -> Option<HashMap<char, Vec<String>>> {
    let mut out = HashMap::new();
    let mut chars = text.trim().chars().peekable();
    let string = |chars: &mut std::iter::Peekable<std::str::Chars>| -> Option<String> {
        while chars.peek()?.is_whitespace() {
            chars.next();
        }
        if chars.next()? != '"' {
            return None;
        }
        let mut s = String::new();
        loop {
            match chars.next()? {
                '"' => return Some(s),
                '\\' => match chars.next()? {
                    'u' => {
                        let hex: String = (0..4).filter_map(|_| chars.next()).collect();
                        s.push(char::from_u32(u32::from_str_radix(&hex, 16).ok()?)?);
                    }
                    c => s.push(c),
                },
                c => s.push(c),
            }
        }
    };
    let skip = |chars: &mut std::iter::Peekable<std::str::Chars>, want: char| -> Option<()> {
        while chars.peek()?.is_whitespace() {
            chars.next();
        }
        (chars.next()? == want).then_some(())
    };
    skip(&mut chars, '{')?;
    loop {
        let key = string(&mut chars)?;
        skip(&mut chars, ':')?;
        skip(&mut chars, '[')?;
        let mut values = Vec::new();
        loop {
            values.push(string(&mut chars)?);
            while chars.peek()?.is_whitespace() {
                chars.next();
            }
            match chars.next()? {
                ',' => continue,
                ']' => break,
                _ => return None,
            }
        }
        let mut key_chars = key.chars();
        if let (Some(c), None) = (key_chars.next(), key_chars.next()) {
            out.insert(c, values);
        }
        while chars.peek()?.is_whitespace() {
            chars.next();
        }
        match chars.next()? {
            ',' => continue,
            '}' => return Some(out),
            _ => return None,
        }
    }
}

fn parse_cmudict(text: &str) -> HashMap<String, Vec<Vec<String>>> {
    let mut out: HashMap<String, Vec<Vec<String>>> = HashMap::new();
    for line in text.lines() {
        let line = line.split('#').next().unwrap_or("");
        let fields: Vec<&str> = line.split_whitespace().collect();
        if fields.len() < 2 {
            continue;
        }
        let mut word = fields[0].to_lowercase();
        if let Some(i) = word.rfind('(') {
            word.truncate(i);
        }
        let phones: Vec<String> = fields[1..].iter().map(|p| p.trim_end_matches(|c: char| c.is_ascii_digit()).to_string()).collect();
        let list = out.entry(word).or_default();
        if !list.contains(&phones) {
            list.push(phones);
        }
    }
    out
}

fn re(pattern: &str) -> Regex {
    Regex::new(pattern).unwrap()
}

static HAN: LazyLock<Regex> = LazyLock::new(|| re(r"[\x{3400}-\x{9fff}]+"));
static WORDS: LazyLock<Regex> = LazyLock::new(|| re(r"[A-Za-z]+"));
static SPOKEN: LazyLock<Regex> = LazyLock::new(|| re(r"[A-Za-z]+(?:[ \t]+[A-Za-z]+)+"));
static IDENTIFIER: LazyLock<Regex> = LazyLock::new(|| re(r"(?-u:\b)[A-Za-z_][A-Za-z_0-9]*(?-u:\b)"));
static NUMBERS: LazyLock<Regex> =
    LazyLock::new(|| re(r"[0-9零〇一二三四五六七八九十百千万亿两点]+(?:元|块|秒|天|小时|分钟|米|户|个|次|年|月|日)"));
static QUOTES: LazyLock<Regex> = LazyLock::new(|| {
    re(r#"“[^”]*(?:”|$)|「[^」]*(?:」|$)|『[^』]*(?:』|$)|‘[^’]*(?:’|$)|"[^"]*(?:"|$)|`[^`]*(?:`|$)|'[^']*(?:'|$)"#)
});
static LANGUAGE_DISCUSSION: LazyLock<Regex> =
    LazyLock::new(|| re(r"(?-u:\b)(?:spelling|spellings|phrase|phrases|literal|literals|intentional|intentionally)(?-u:\b)"));
static WORD_OR_SPACE: LazyLock<Regex> = LazyLock::new(|| re(r"(?-u:\b)(?:word|words|space|spaces)(?-u:\b)"));
static PRESERVATION: LazyLock<Regex> = LazyLock::new(|| {
    re(r"(?-u:\b)(?:preserve|keep|separate|separated|exact|exactly|between|two|three|internal)(?-u:\b)")
});

fn overlap(a: (usize, usize), b: (usize, usize)) -> bool {
    a.0 < b.1 && a.1 > b.0
}

/// 引号里的不列候选；直的单引号前面是字母数字时是撇号，不算引号。
fn quoted(source: &str) -> Vec<(usize, usize)> {
    QUOTES
        .find_iter(source)
        .filter(|m| {
            if source.as_bytes()[m.start()] == b'\'' && m.start() > 0 {
                let r = source[..m.start()].chars().next_back().unwrap();
                return !(is_letter(r) || r.is_numeric() || r == '_');
            }
            true
        })
        .map(|m| (m.start(), m.end()))
        .collect()
}

fn blocked(start: usize, end: usize, spans: &[(usize, usize)]) -> bool {
    spans.iter().any(|&s| overlap((start, end), s))
}

fn unique(mut items: Vec<String>) -> Vec<String> {
    items.sort();
    items.dedup();
    items
}

/// 标识符拆成词：fetchCache → fetch、Cache；HTTPServer → HTTP、Server。有别的字符就不拆（None）。
fn parts(s: &str) -> Option<Vec<&str>> {
    let b = s.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < b.len() {
        let start = i;
        match b[i] {
            b'A'..=b'Z' => {
                i += 1;
                while i < b.len() && b[i].is_ascii_uppercase() {
                    i += 1;
                }
                if i - start > 1 && i < b.len() && b[i].is_ascii_lowercase() {
                    i -= 1;
                } else {
                    while i < b.len() && b[i].is_ascii_lowercase() {
                        i += 1;
                    }
                }
            }
            b'a'..=b'z' => {
                while i < b.len() && b[i].is_ascii_lowercase() {
                    i += 1;
                }
            }
            b'0'..=b'9' => {
                while i < b.len() && b[i].is_ascii_digit() {
                    i += 1;
                }
            }
            _ => return None,
        }
        out.push(&s[start..i]);
    }
    Some(out)
}

impl Lexicon {
    /// 几个词连起来的所有读法（每个词有几种读法时组合起来，超过 4096 种不算）。
    fn phones(&self, words: &[&str]) -> Option<HashSet<String>> {
        let mut combinations: Vec<Vec<String>> = vec![vec![]];
        for w in words {
            let choices = self.english.get(&w.to_lowercase())?;
            if choices.is_empty() || combinations.len() * choices.len() > 4096 {
                return None;
            }
            let mut next = Vec::new();
            for a in &combinations {
                for b in choices {
                    let mut c = a.clone();
                    c.extend(b.iter().cloned());
                    next.push(c);
                }
            }
            combinations = next;
        }
        Some(combinations.into_iter().map(|p| p.join(" ")).collect())
    }

    /// 两段汉字逐字读音相同（tones 为 false 时不分声调）。
    fn matches(&self, a: &str, b: &str, tones: bool) -> bool {
        let (ar, br): (Vec<char>, Vec<char>) = (a.chars().collect(), b.chars().collect());
        if ar.len() != br.len() {
            return false;
        }
        let strip = |s: &str| if tones { s.to_string() } else { s.trim_end_matches(|c: char| ('0'..='5').contains(&c)).to_string() };
        ar.iter().zip(&br).all(|(x, y)| {
            let (xs, ys) = (self.readings.get(x), self.readings.get(y));
            match (xs, ys) {
                (Some(xs), Some(ys)) => xs.iter().any(|x| ys.iter().any(|y| strip(x) == strip(y))),
                _ => false,
            }
        })
    }

    /// 列候选（Prepare / PrepareContextual）。compounds 时（润色用的就是这个）英文按字母拼起来也算候选。
    pub fn prepare(&self, source: &str, context: BTreeMap<String, String>, scene: &str, compounds: bool) -> Preparation {
        let screen = context
            .iter()
            .filter(|(k, _)| !(compounds && k.as_str() == "EarlierSource"))
            .map(|(_, v)| v.as_str())
            .collect::<Vec<_>>()
            .join("\n");
        let quoted = quoted(source);
        let mut blocked_spans = quoted.clone();
        blocked_spans.extend(NUMBERS.find_iter(source).map(|m| (m.start(), m.end())));
        let mut hypotheses: Vec<Hypothesis> = Vec::new();
        let phonetic = scene == "work" || scene == "prompt";
        if phonetic || compounds {
            let mut ids = Vec::new();
            let mut phones: HashMap<String, Option<HashSet<String>>> = HashMap::new();
            for id in IDENTIFIER.find_iter(&screen) {
                let id = id.as_str();
                let p = parts(id).unwrap_or_default();
                if compounds || p.len() >= 2 {
                    ids.push(id.to_string());
                }
                if phonetic && p.len() >= 2 {
                    phones.insert(id.to_string(), self.phones(&p));
                }
            }
            let ids = unique(ids);
            for run in SPOKEN.find_iter(source) {
                let words: Vec<_> = WORDS.find_iter(run.as_str()).map(|w| (w.start(), w.end())).collect();
                for n in 2..=words.len().min(6) {
                    for i in 0..=words.len() - n {
                        let (start, end) = (run.start() + words[i].0, run.start() + words[i + n - 1].1);
                        if blocked(start, end, &quoted) {
                            continue;
                        }
                        if compounds && (!compound_boundary(source, start, end) || source_intent(source, start, end)) {
                            continue;
                        }
                        let text = &source[start..end];
                        let fields: Vec<&str> = text.split_whitespace().collect();
                        let letters = fields.concat();
                        let pron = self.phones(&fields);
                        let mut same = Vec::new();
                        let mut matches = Vec::new();
                        for id in &ids {
                            if id.to_lowercase() == letters.to_lowercase() {
                                same.push(id.clone());
                            }
                            if let (Some(pron), Some(Some(known))) = (&pron, phones.get(id)) {
                                if pron.iter().any(|ph| known.contains(ph)) {
                                    matches.push(id.clone());
                                }
                            }
                        }
                        if !same.is_empty() {
                            matches = same;
                        }
                        let matches = unique(matches);
                        if !matches.is_empty() {
                            hypotheses.push(Hypothesis {
                                id: String::new(),
                                start,
                                end,
                                source: text.to_string(),
                                candidates: matches,
                                status: String::new(),
                                kind: "english-identifier".into(),
                            });
                        }
                    }
                }
            }
        }
        let targets = unique(han_windows(&screen).into_iter().map(|(_, _, s)| s).collect());
        // 按长度和第一个字的读音分桶，不用拿每个窗口和每个上下文窗口两两比
        let mut index: HashMap<(usize, String), Vec<String>> = HashMap::new();
        for target in &targets {
            let first = target.chars().next().unwrap();
            for reading in self.readings.get(&first).into_iter().flatten() {
                let key = (target.chars().count(), toneless(reading).to_string());
                index.entry(key).or_default().push(target.clone());
            }
        }
        for (start, end, text) in han_windows(source) {
            if blocked(start, end, &blocked_spans) || screen.contains(&text) {
                continue;
            }
            let first = text.chars().next().unwrap();
            let len = text.chars().count();
            let mut possible = Vec::new();
            for reading in self.readings.get(&first).into_iter().flatten() {
                if let Some(list) = index.get(&(len, toneless(reading).to_string())) {
                    possible.extend(list.iter().cloned());
                }
            }
            let matches: Vec<String> = unique(possible).into_iter().filter(|t| self.matches(&text, t, false)).collect();
            if !matches.is_empty() {
                let exact = matches.iter().all(|t| self.matches(&text, t, true));
                hypotheses.push(Hypothesis {
                    id: String::new(),
                    start,
                    end,
                    source: text,
                    candidates: matches,
                    status: String::new(),
                    kind: if exact { "chinese-character-readings" } else { "chinese-segmental-readings" }.into(),
                });
            }
        }

        // 长的先占位，重叠的不要；再按位置排、编号
        hypotheses.sort_by(|a, b| (b.end - b.start).cmp(&(a.end - a.start)).then(a.start.cmp(&b.start)));
        let mut kept: Vec<Hypothesis> = Vec::new();
        for h in hypotheses {
            if !kept.iter().any(|c| overlap((h.start, h.end), (c.start, c.end))) {
                kept.push(h);
            }
        }
        kept.sort_by_key(|h| h.start);
        for (i, h) in kept.iter_mut().enumerate() {
            h.id = format!("e{i}");
            h.status = if h.candidates.len() == 1 { "unique" } else { "ambiguous" }.into();
        }
        let unknown = unique(
            source
                .chars()
                .chain(screen.chars())
                .filter(|&r| ('\u{3400}'..='\u{9fff}').contains(&r) && self.readings.get(&r).map_or(true, |v| v.is_empty()))
                .map(String::from)
                .collect(),
        );
        Preparation { source: source.to_string(), context, scene: scene.to_string(), hypotheses: kept, unknown }
    }
}

fn toneless(reading: &str) -> &str {
    reading.trim_end_matches(|c: char| ('0'..='5').contains(&c))
}

/// 每一段连续汉字里 2 到 6 个字的窗口：(开始, 结束, 文字)。
fn han_windows(s: &str) -> Vec<(usize, usize, String)> {
    let mut out = Vec::new();
    for span in HAN.find_iter(s) {
        let text = span.as_str();
        let mut positions: Vec<usize> = text.char_indices().map(|(i, _)| i).collect();
        positions.push(text.len());
        for n in 2..=6 {
            let mut i = 0;
            while i + n < positions.len() {
                let (start, end) = (span.start() + positions[i], span.start() + positions[i + n]);
                out.push((start, end, s[start..end].to_string()));
                i += 1;
            }
        }
    }
    out
}

/// 英文窗口不能切开标识符或数字，旁边是中文、标点可以。
fn compound_boundary(source: &str, start: usize, end: usize) -> bool {
    let attached = |b: u8| b.is_ascii_alphanumeric() || b == b'_';
    let bytes = source.as_bytes();
    (start == 0 || !attached(bytes[start - 1])) && (end == source.len() || !attached(bytes[end]))
}

/// 这句话在讨论字词本身（拼写、短语、空格……）时不列英文候选（spellingSourceIntent，earlier 为 false）。
fn source_intent(source: &str, start: usize, end: usize) -> bool {
    let boundary = |c: char| "。.!?！？\n".contains(c);
    let left = source[..start].char_indices().filter(|&(_, c)| boundary(c)).last().map_or(0, |(i, c)| i + c.len_utf8());
    let right = source[end..].char_indices().find(|&(_, c)| boundary(c)).map_or(source.len(), |(i, _)| end + i);
    let sentence = source[left..right].to_lowercase();
    if ["拼写", "短语", "字面", "单词", "空格", "写法", "新名称"].iter().any(|m| sentence.contains(m)) {
        return true;
    }
    LANGUAGE_DISCUSSION.is_match(&sentence) || WORD_OR_SPACE.is_match(&sentence) && PRESERVATION.is_match(&sentence)
}

/// 按模型的选择替换（ApplySpellingChoices）：每个候选都要有「keep」或「replace」，只有唯一候选能 replace，
/// 位置和原文对得上。不对时返回 None（这次不换）。
pub fn apply_choices(p: &Preparation, choices: &HashMap<String, String>) -> Option<String> {
    if choices.len() != p.hypotheses.len() {
        return None;
    }
    let mut source = p.source.clone();
    for h in p.hypotheses.iter().rev() {
        let choice = choices.get(&h.id)?.as_str();
        if !matches!(choice, "keep" | "replace") || choice == "replace" && h.candidates.len() != 1 {
            return None;
        }
        if h.end > source.len() || h.end < h.start || source.get(h.start..h.end)? != h.source {
            return None;
        }
        if choice == "replace" {
            source.replace_range(h.start..h.end, &h.candidates[0]);
        }
    }
    Some(source)
}

// MARK: - 给模型的文字（selected.go 的 selectionText，Go 的 json 不转义 HTML）

pub fn json_string(s: &str) -> String {
    let mut out = String::from("\"");
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{2028}' => out.push_str("\\u2028"),
            '\u{2029}' => out.push_str("\\u2029"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn json_list(items: &[String]) -> String {
    format!("[{}]", items.iter().map(|s| json_string(s)).collect::<Vec<_>>().join(","))
}

/// 选择提示里的一条用户消息。
pub fn selection_text(p: &Preparation) -> String {
    let context = p.context.iter().map(|(k, v)| format!("{}:{}", json_string(k), json_string(v))).collect::<Vec<_>>().join(",");
    let hypotheses = p
        .hypotheses
        .iter()
        .map(|h| {
            format!(
                "{{\"id\":{},\"sourceSpan\":{},\"candidateSpellings\":{},\"status\":{},\"kind\":{}}}",
                json_string(&h.id),
                json_string(&h.source),
                json_list(&h.candidates),
                json_string(&h.status),
                json_string(&h.kind)
            )
        })
        .collect::<Vec<_>>()
        .join(",");
    format!(
        "{{\"source\":{},\"context\":{{{}}},\"scene\":{},\"unknownChineseCharacters\":{},\"hypotheses\":[{}]}}",
        json_string(&p.source),
        context,
        json_string(&p.scene),
        json_list(&p.unknown),
        hypotheses
    )
}
