//! 清理口语：只删不改，删语气词、口吃式的重复和明确的改口（「三点，不对，四点」留「四点」）。
//! 润色前先跑这一步；润色失败或没开润色模型时，上屏的就是它的结果。
//!
//! 照 Arion packages/core/domain@d2108fe（AGPL-3.0-only）逐行移植：
//! speech_cleanup.go（CleanSpeech、ApplySpeechSpans）、speech_repair.go（markSpokenRepairs）、
//! correction.go（hesitationSpans）。偏移和 Go 一样按 UTF-8 字节算。

use super::text::*;
use regex::Regex;
use std::sync::LazyLock;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SpanKind {
    Hesitation,
    Repetition,
    Repair,
}

/// 删掉的一段（原文里的字节偏移）。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Span {
    pub start: usize,
    pub end: usize,
    pub kind: SpanKind,
}

#[derive(Clone, Debug)]
pub struct Cleanup {
    pub text: String,
    pub spans: Vec<Span>,
}

fn re(pattern: &str) -> Regex {
    Regex::new(pattern).unwrap()
}

static LEADING: LazyLock<Regex> = LazyLock::new(|| {
    re(r"(?i)(?:那个就是说|就是说|我想说的是|然后的话|然后呢)[，,\t\n\f\r ]*|(?:so basically(?: what I wanted to say is(?: that)?)?|what I wanted to say is(?: that)?)(?-u:\b)[,\t\n\f\r ]*")
});
static TOPIC: LazyLock<Regex> = LazyLock::new(|| re(r"(?:这个|那个)[\t\n\f\r ]*[A-Za-z_][A-Za-z0-9_]*[\t\n\f\r ]*的话"));
static QUESTION: LazyLock<Regex> = LazyLock::new(|| re(r"那个[，,][\t\n\f\r ]*(?:我想问|我想确认|我想了解)"));
static PARENTHETICAL: LazyLock<Regex> = LazyLock::new(|| re(r"(?i),[\t\n\f\r ]*like[\t\n\f\r ]*,"));
static FOREIGN: LazyLock<Regex> = LazyLock::new(|| re(r"(?i)(?:(?:euh|eh)[,，][\t\n\f\r ]*|(?:えーと|えっと|あの)、)"));
static WORDS: LazyLock<Regex> = LazyLock::new(|| re(r"[A-Za-z]+"));
static REPAIR_CUE: LazyLock<Regex> = LazyLock::new(|| {
    re(r"(?i)[，,、][\t\n\f\r ]*(?:啊?不对|哦不|说错了|no wait|i mean|sorry|perdón|non pardon|pardon|いや|no)[，,、\t\n\f\r ]+")
});
static QUANTITY: LazyLock<Regex> =
    LazyLock::new(|| re(r"[0-9零〇一二两三四五六七八九十百千万]+(?:点|时|時|个|元|块|天|号|人|张|台|件|分|秒)"));
static DAY: LazyLock<Regex> = LazyLock::new(|| {
    re(r"(?i)(?:el )?(?:lunes|martes|miércoles|jueves|viernes|sábado|domingo)|(?:lundi|mardi|mercredi|jeudi|vendredi|samedi|dimanche)")
});

const CLAUSE_ENDS: &str = "，,、。.!！?？;；\n";

/// 标出要删的几段，按原文的先后。
struct Marker<'a> {
    source: &'a str,
    removed: Vec<bool>,
    quoted: Vec<(usize, usize)>,
    spans: Vec<Span>,
}

impl<'a> Marker<'a> {
    fn new(source: &'a str) -> Self {
        let quoted = QUOTED_TEXT.find_iter(source).map(|m| (m.start(), m.end())).collect();
        Marker { source, removed: vec![false; source.len()], quoted, spans: Vec::new() }
    }

    /// 引号里的、会把两个词粘起来的、和已经标过的重叠的，不标。
    fn mark(&mut self, start: usize, end: usize, kind: SpanKind) {
        if end <= start || end > self.source.len() || joins_speech_words(self.source, start, end) {
            return;
        }
        if self.quoted.iter().any(|&(qs, qe)| start < qe && qs < end) {
            return;
        }
        if self.removed[start..end].iter().any(|&r| r) {
            return;
        }
        self.removed[start..end].iter_mut().for_each(|r| *r = true);
        self.spans.push(Span { start, end, kind });
    }

    /// start 前面（不算已经删掉的）是不是一句的开头。
    fn is_leading(&self, start: usize) -> bool {
        let before: Vec<u8> = self.source.as_bytes()[..start]
            .iter()
            .zip(&self.removed)
            .filter(|(_, &r)| !r)
            .map(|(&b, _)| b)
            .collect();
        clause_leading(&String::from_utf8_lossy(&before))
    }
}

/// 删掉这几段，去掉两头的空白（ApplySpeechSpans）；段不合规矩时返回 None。
pub fn apply_spans(source: &str, spans: &[Span]) -> Option<String> {
    let quoted: Vec<_> = QUOTED_TEXT.find_iter(source).map(|m| (m.start(), m.end())).collect();
    let mut out = String::new();
    let mut cursor = 0;
    for span in spans {
        if span.start < cursor
            || span.end <= span.start
            || span.end > source.len()
            || !source.is_char_boundary(span.start)
            || !source.is_char_boundary(span.end)
        {
            return None;
        }
        if joins_speech_words(source, span.start, span.end) {
            return None;
        }
        if quoted.iter().any(|&(qs, qe)| span.start < qe && qs < span.end) {
            return None;
        }
        out.push_str(&source[cursor..span.start]);
        cursor = span.end;
    }
    out.push_str(&source[cursor..]);
    Some(out.trim().to_string())
}

/// 清理口语（CleanSpeech）。所有规则都在原文上标，生成的内容不当证据。
pub fn clean_speech(source: &str) -> Cleanup {
    let mut m = Marker::new(source);
    // 单独的语气词在这里删（整理规则不删）
    for (start, end) in hesitation_spans(source) {
        m.mark(start, end, SpanKind::Hesitation);
    }
    for pattern in [&*LEADING, &*FOREIGN, &*PARENTHETICAL] {
        let parenthetical = std::ptr::eq(pattern, &*PARENTHETICAL);
        for found in pattern.find_iter(source) {
            if parenthetical || m.is_leading(found.start()) {
                m.mark(found.start(), found.end(), SpanKind::Hesitation);
            }
        }
    }
    for found in QUESTION.find_iter(source) {
        if !m.is_leading(found.start()) {
            continue;
        }
        let start = found.start() + found.as_str().find("那个").unwrap();
        let mut end = start + "那个".len();
        while let Some(c) = first_char(&source[end..]) {
            if !is_space(c) && !"，,".contains(c) {
                break;
            }
            end += c.len_utf8();
        }
        m.mark(start, end, SpanKind::Hesitation);
    }
    for found in TOPIC.find_iter(source) {
        if m.is_leading(found.start()) {
            m.mark(found.end() - "的话".len(), found.end(), SpanKind::Hesitation);
        }
    }

    for word in ["这个", "那个", "就是", "我"] {
        let doubled = word.repeat(2);
        let mut cursor = 0;
        while let Some(i) = source[cursor..].find(&doubled) {
            let i = i + cursor;
            m.mark(i, i + word.len(), SpanKind::Repetition);
            cursor = i + word.len();
        }
    }
    let words: Vec<_> = WORDS.find_iter(source).map(|w| (w.start(), w.end())).collect();
    for pair in words.windows(2) {
        let ((a0, a1), (b0, b1)) = (pair[0], pair[1]);
        let word = source[a0..a1].to_lowercase();
        if !matches!(word.as_str(), "i" | "the" | "a" | "we") {
            continue;
        }
        if source[a0..a1].to_lowercase() != source[b0..b1].to_lowercase() {
            continue;
        }
        if word == "a" && &source[a0..a1] == "A" && &source[b0..b1] == "A" {
            continue;
        }
        if !speech_word_boundary(source, a0, b1) {
            continue;
        }
        if source[a1..b0].trim_matches(|c| " ,\t".contains(c)).is_empty() {
            m.mark(a0, b0, SpanKind::Repetition);
        }
    }

    // 改口只看前一句，而且要有重复的说法或同一类的值（几点、几个人、星期几）；光有「不对」不删
    for cue in REPAIR_CUE.find_iter(source) {
        let (c0, c1) = (cue.start(), cue.end());
        let mut start = match source[..c0].rfind(|c| CLAUSE_ENDS.contains(c)) {
            Some(i) => i + first_char(&source[i..]).unwrap().len_utf8(),
            None => 0,
        };
        let end = source[c1..].find(|c| CLAUSE_ENDS.contains(c)).map_or(source.len(), |i| c1 + i);
        let seg = &source[start..c0];
        start += seg.len() - seg.trim_start_matches(is_space).len();
        let (left, right) = (source[start..c0].trim(), source[c1..end].trim());
        if left.is_empty() || right.is_empty() {
            continue;
        }
        let mut repair_start: Option<usize> = None;
        let mut repair_end = c1;
        let cue_text = source[c0..c1].to_lowercase();
        let english = cue_text.contains("no wait")
            || cue_text.contains("i mean")
            || cue_text.contains("no,")
            || cue_text.contains("no ")
            || cue_text.trim().ends_with("no");
        let chinese = cue_text.contains("不对") || cue_text.contains("说错") || cue_text.contains("哦不");
        let left_lower = left.to_lowercase();
        let right_lower = right.to_lowercase();
        let lw: Vec<&str> = left_lower.split_whitespace().collect();
        let rw: Vec<&str> = right_lower.split_whitespace().collect();
        if english && lw.len() >= 2 && lw.len() == rw.len() {
            // 一样的说法里只换了一个词，那个词就是改口（「three people, no, five people」）
            if lw.iter().zip(&rw).filter(|(a, b)| a != b).count() == 1 {
                repair_start = Some(start);
            }
        }
        // 改的是名词短语，前面的动词可以留着
        if english
            && repair_start.is_none()
            && rw.len() >= 3
            && (rw[0] == "the" || rw[0] == "a")
            && lw.len() >= rw.len()
            && lw[lw.len() - 1] == rw[rw.len() - 1]
        {
            if let Some(i) = last_speech_article(left, rw[0]) {
                repair_start = Some(start + source[start..c0].find(left).unwrap() + i);
            }
        }
        if repair_start.is_none() {
            let (l, r): (Vec<char>, Vec<char>) = (left.chars().collect(), right.chars().collect());
            let n = l.len().min(r.len());
            let mut prefix = 0;
            while prefix < n && l[prefix] == r[prefix] && is_cjk(l[prefix]) {
                prefix += 1;
            }
            let mut suffix = 0;
            while suffix < n - prefix && l[l.len() - 1 - suffix] == r[r.len() - 1 - suffix] && is_cjk(l[l.len() - 1 - suffix]) {
                suffix += 1;
            }
            if chinese && (prefix >= 2 || prefix >= 1 && suffix >= 2) {
                repair_start = Some(start);
            }
        }
        if repair_start.is_none() {
            let mut value = right;
            let copular = chinese && value.starts_with('是');
            if copular {
                value = value["是".len()..].trim_start_matches(is_space);
            }
            for (pattern, quantity) in [(&*QUANTITY, true), (&*DAY, false)] {
                let l: Vec<_> = pattern.find_iter(left).collect();
                let Some(r) = pattern.find(value) else { continue };
                let Some(last) = l.last() else { continue };
                if r.start() != 0 {
                    continue;
                }
                // 「是四秒」得是整句，不是「是四秒后重试」这种别的动作
                if copular && r.end() != value.len() {
                    continue;
                }
                if last.end() != left.len() {
                    continue;
                }
                if quantity && last_char(&left[last.start()..]) != last_char(&value[..r.end()]) {
                    continue;
                }
                repair_start = Some(start + source[start..c0].find(left).unwrap() + last.start());
                if copular {
                    let raw_right = &source[c1..end];
                    let leading = raw_right.len() - raw_right.trim_start_matches(is_space).len();
                    repair_end += leading + right.len() - value.len();
                }
                break;
            }
        }
        if let Some(repair_start) = repair_start {
            let candidate = format!("{}{}", &source[..repair_start], &source[repair_end..]);
            if negations(&candidate) >= negations(source) && !loses_uncertainty(source, &candidate) {
                m.mark(repair_start, repair_end, SpanKind::Repair);
            }
        }
    }
    mark_spoken_repairs(source, &mut m);

    let mut spans = m.spans;
    spans.sort_by_key(|s| s.start);
    let Some(text) = apply_spans(source, &spans) else {
        debug_assert!(false, "invalid local speech annotations");
        return Cleanup { text: source.to_string(), spans: Vec::new() };
    };
    // 删完什么都不剩：不算数，原文留着
    if content_runes(&text).is_empty() {
        return Cleanup { text: source.to_string(), spans: Vec::new() };
    }
    Cleanup { text, spans }
}

fn clause_leading(before: &str) -> bool {
    match last_char(before.trim_end_matches(is_space)) {
        None => true,
        Some(c) => "，,、。.!！?？;；".contains(c),
    }
}

fn last_speech_article(text: &str, article: &str) -> Option<usize> {
    WORDS.find_iter(text).collect::<Vec<_>>().into_iter().rev().find_map(|w| {
        (w.as_str().to_lowercase() == article && w.end() < text.len() && text.as_bytes()[w.end()] == b' ').then_some(w.start())
    })
}

fn speech_word_boundary(source: &str, start: usize, end: usize) -> bool {
    let word = |c: char| is_letter(c) || is_digit(c) || c == '_';
    if last_char(&source[..start]).is_some_and(word) {
        return false;
    }
    !first_char(&source[end..]).is_some_and(word)
}

/// 删掉这一段会不会把两边的英文词或数字粘在一起。
fn joins_speech_words(source: &str, start: usize, end: usize) -> bool {
    if start == 0 || end == source.len() || !source.is_char_boundary(start) || !source.is_char_boundary(end) {
        return false;
    }
    let word = |c: char| is_digit(c) || is_letter(c) && !is_cjk(c);
    last_char(&source[..start]).is_some_and(word) && first_char(&source[end..]).is_some_and(word)
}

// MARK: - 语气词（correction.go 的 hesitationSpans）

const FILLERS: &[&str] = &["嗯", "呃", "额", "um", "uh", "erm", "uhm"];

/// 单独的语气词（连着后面的逗号）。中文的可以贴着别的字，「额」要两边都不是汉字（余额、名额）。
fn hesitation_spans(s: &str) -> Vec<(usize, usize)> {
    let chars: Vec<char> = s.chars().collect();
    let mut offsets: Vec<usize> = s.char_indices().map(|(i, _)| i).collect();
    offsets.push(s.len());
    let mut out = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        let start = i;
        let mut end = i + 1;
        let c = chars[i];
        if c.is_ascii_alphabetic() {
            while end < chars.len() && chars[end].is_ascii_alphabetic() {
                end += 1;
            }
            let word: String = chars[start..end].iter().collect::<String>().to_lowercase();
            if !FILLERS.contains(&word.as_str()) {
                i = end;
                continue;
            }
        } else if !FILLERS.contains(&c.to_string().as_str()) || !standalone_cjk(&chars, i) {
            i += 1;
            continue;
        }
        if end < chars.len() && ",，、".contains(chars[end]) {
            end += 1;
        }
        out.push((offsets[start], offsets[end]));
        i = end;
    }
    out
}

fn standalone_cjk(chars: &[char], i: usize) -> bool {
    let before = i == 0 || !is_han(chars[i - 1]);
    let after = i + 1 >= chars.len() || !is_han(chars[i + 1]);
    if chars[i] == '额' {
        return before && after;
    }
    before || after
}

// MARK: - 改口（speech_repair.go）

static ZH_MONTH: LazyLock<Regex> = LazyLock::new(|| re(r"(?:[0-9]{1,2}|[零〇一二两三四五六七八九十百千]+)个?月"));
static ZH_QUANTITY: LazyLock<Regex> = LazyLock::new(|| {
    re(r"(?:[0-9]+|[零〇一二两三四五六七八九十百千万亿]+)(?:点[0-9零〇一二三四五六七八九]+)?(?:个|元|块|天|号|人|张|台|件|分|秒)")
});
static ZH_NUMBER: LazyLock<Regex> = LazyLock::new(|| re(r"[0-9]+|[零〇一二两三四五六七八九十百千万亿]+"));
static EN_MONTH: LazyLock<Regex> = LazyLock::new(|| {
    re(r"(?-u:\b)(?:January|February|March|April|May|June|July|August|September|October|November|December)(?-u:\b)")
});
static EN_WEEKDAY: LazyLock<Regex> =
    LazyLock::new(|| re(r"(?-u:\b)(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)(?-u:\b)"));
static EN_NUMBER: LazyLock<Regex> = LazyLock::new(|| {
    re(r"(?i)(?-u:\b)(?:zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|[0-9]+)(?-u:\b)(?:[\t\n\f\r ]+(?:people|seconds|minutes|hours|days|dollars|percent))?")
});
static GAP_SPLIT: LazyLock<Regex> = LazyLock::new(|| re(r"[，,、。.!！?？;；\n]+|…+|\.{3,}"));
static NOT_A_IS_B: LazyLock<Regex> = LazyLock::new(|| {
    re(r"不是([^，,、。.!！?？;；\n…]{1,48}?)[，,、\t\n\f\r ]*是([^，,、。.!！?？;；\n…]{1,48})")
});
static EN_NOT: LazyLock<Regex> = LazyLock::new(|| {
    re(r"(?i)(?-u:\b)not[\t\n\f\r ]+([A-Za-z0-9]+(?:[\t\n\f\r ]+[A-Za-z0-9]+){0,3})[\t\n\f\r ]*[，,][\t\n\f\r ]*(?:it(?:'s| is)[\t\n\f\r ]+)?([A-Za-z0-9]+(?:[\t\n\f\r ]+[A-Za-z0-9]+){0,3})")
});

const REPAIR_PUNCT: &str = "，,、。.!！?？;；…";

/// 说到一半改了的值删掉、留最后说的；排除（「四秒，不是四十秒」）、身份（「我不是张三，是李四」）、
/// 并列和引号里的不动，拿不准的留给模型。
fn mark_spoken_repairs(source: &str, m: &mut Marker) {
    mark_rejected_value_runs(source, m);
    mark_not_a_is_b(source, m);
    mark_english_not_repair(source, m);
}

#[derive(Clone, Debug)]
struct RepairValue {
    start: usize,
    end: usize,
    kind: String,
    text: String,
}

fn find_repair_values(source: &str) -> Vec<RepairValue> {
    let mut found = Vec::new();
    let mut add = |pattern: &Regex, kind: &dyn Fn(&str) -> String, skip: &dyn Fn(usize) -> bool| {
        for loc in pattern.find_iter(source) {
            if skip(loc.start()) {
                continue;
            }
            let text = loc.as_str();
            found.push(RepairValue { start: loc.start(), end: loc.end(), kind: kind(text), text: text.to_string() });
        }
    };
    let never = |_: usize| false;
    add(&ZH_MONTH, &|_| "zh-month".into(), &never);
    add(&ZH_QUANTITY, &|t| format!("zhq:{}", last_char(t).unwrap()), &never);
    add(&ZH_NUMBER, &|_| "zh-num".into(), &|start| preceded_by(source, start, &["什么", "没有", "哪有", "不是"]));
    add(&EN_MONTH, &|_| "en-month".into(), &never);
    add(&EN_WEEKDAY, &|_| "en-weekday".into(), &never);
    add(
        &EN_NUMBER,
        &|t| {
            let fields: Vec<&str> = t.split_whitespace().collect();
            if fields.len() > 1 {
                format!("en-num:{}", fields[fields.len() - 1].to_lowercase())
            } else {
                "en-num".into()
            }
        },
        &never,
    );
    keep_longest(found)
}

/// 先开始的在前；同一处开始的留长的（「十二月」赢过里面的「十二」）。
fn keep_longest(mut found: Vec<RepairValue>) -> Vec<RepairValue> {
    found.sort_by(|a, b| a.start.cmp(&b.start).then((b.end - b.start).cmp(&(a.end - a.start))));
    let mut kept: Vec<RepairValue> = Vec::new();
    for v in found {
        if !kept.iter().any(|p| v.start < p.end && p.start < v.end) {
            kept.push(v);
        }
    }
    kept.sort_by_key(|v| v.start);
    kept
}

fn preceded_by(source: &str, start: usize, prefixes: &[&str]) -> bool {
    prefixes.iter().any(|p| source.as_bytes()[..start].ends_with(p.as_bytes()))
}

fn mark_rejected_value_runs(source: &str, m: &mut Marker) {
    let values = find_repair_values(source);
    let mut i = 0;
    while i < values.len() {
        let mut last = i;
        let mut saw = false;
        let mut next = i + 1;
        while next < values.len() && values[next].kind == values[i].kind {
            // 放弃的说法到这一句为止；「是四秒」要是整句，不是「是四秒后重试」
            if !repair_clause_final(source, values[next - 1].end) {
                break;
            }
            let gap = &source[values[next - 1].end..values[next].start];
            if gap_has_copula(gap) && !repair_clause_final(source, values[next].end) {
                break;
            }
            let (allow, rejection) = gap_allows_repair(gap, &values[i..=next]);
            if !allow {
                break;
            }
            saw |= rejection;
            last = next;
            next += 1;
        }
        if saw && last > i {
            m.mark(values[i].start, values[last].start, SpanKind::Repair);
            i = last + 1;
            continue;
        }
        i += 1;
    }
}

fn repair_clause_final(source: &str, end: usize) -> bool {
    match first_char(&source[end..]) {
        None => true,
        Some(c) => is_space(c) || "，,、。.!！?？;；\n…".contains(c),
    }
}

fn gap_has_copula(gap: &str) -> bool {
    GAP_SPLIT.split(gap).any(|part| is_repair_copula(part.trim()))
}

fn gap_allows_repair(gap: &str, values: &[RepairValue]) -> (bool, bool) {
    if repair_glued_exclusion(gap) {
        return (false, false);
    }
    let mut rejection = false;
    for part in GAP_SPLIT.split(gap) {
        let part = part.trim();
        if part.is_empty() || is_repair_copula(part) {
            continue;
        }
        if is_repair_rejection(part, values) {
            rejection = true;
            continue;
        }
        return (false, false);
    }
    (true, rejection)
}

/// 「不是四十秒」「not fifty」：后面的值是排除掉的，不是改正。
fn repair_glued_exclusion(gap: &str) -> bool {
    let trimmed = gap.trim_end_matches(is_space);
    if trimmed.ends_with("不是") {
        return true;
    }
    let lower = trimmed.to_lowercase();
    if let Some(head) = lower.strip_suffix("not") {
        return match last_char(head) {
            None => true,
            Some(prev) => !is_letter(prev) && !is_digit(prev),
        };
    }
    false
}

fn is_repair_copula(part: &str) -> bool {
    matches!(part.to_lowercase().as_str(), "是" | "it's" | "it is")
}

fn is_repair_rejection(part: &str, values: &[RepairValue]) -> bool {
    let lower = part.to_lowercase();
    if matches!(
        lower.as_str(),
        "不对" | "啊不对" | "哦不" | "说错了" | "不是" | "no" | "no wait" | "wait" | "i mean" | "sorry" | "actually"
            | "scratch that" | "pardon" | "perdón" | "non pardon" | "いや"
    ) {
        return true;
    }
    for prefix in ["什么", "没有", "哪有", "不是", "what ", "no ", "not ", "there's no ", "there is no "] {
        if lower.starts_with(prefix) && part.is_char_boundary(prefix.len()) {
            let rest = part[prefix.len()..].trim();
            if !rest.is_empty() && refers_to_repair_value(rest, values) {
                return true;
            }
        }
    }
    false
}

fn refers_to_repair_value(rest: &str, values: &[RepairValue]) -> bool {
    let rest = rest.to_lowercase();
    values.iter().any(|v| v.text.to_lowercase() == rest || repair_core(&v.text).to_lowercase() == rest)
}

fn repair_core(text: &str) -> String {
    for suffix in ["个月", "月", "人", "秒", "分", "个", "天", "元", "块", "号"] {
        if let Some(stripped) = text.strip_suffix(suffix) {
            if !stripped.is_empty() {
                return stripped.to_string();
            }
        }
    }
    let fields: Vec<&str> = text.split_whitespace().collect();
    if fields.len() > 1 {
        return fields[0].to_string();
    }
    text.to_string()
}

/// 「告诉张三，不是张三，是李四」→「告诉李四」。
fn mark_not_a_is_b(source: &str, m: &mut Marker) {
    for caps in NOT_A_IS_B.captures_iter(source) {
        let (whole, ga, gb) = (caps.get(0).unwrap(), caps.get(1).unwrap(), caps.get(2).unwrap());
        let (a, b) = (ga.as_str().trim(), gb.as_str().trim());
        if a.is_empty() || b.is_empty() || replacement_blocked(b) {
            continue;
        }
        let b_start = gb.start() + gb.as_str().len() - gb.as_str().trim_start_matches(is_space).len();
        if let Some(start) = repeated_attempt_start(&source[..whole.start()], a) {
            m.mark(start, b_start, SpanKind::Repair);
            continue;
        }
        if !same_whole_repair_kind(a, b) {
            continue;
        }
        let start = extend_same_kind(source, whole.start(), &repair_kind_of(b));
        m.mark(start, b_start, SpanKind::Repair);
    }
}

fn mark_english_not_repair(source: &str, m: &mut Marker) {
    for caps in EN_NOT.captures_iter(source) {
        let (whole, ga, gb) = (caps.get(0).unwrap(), caps.get(1).unwrap(), caps.get(2).unwrap());
        let (a, b) = (ga.as_str().trim(), gb.as_str().trim());
        if a.is_empty() || b.is_empty() || replacement_blocked(b) {
            continue;
        }
        let Some(start) = repeated_attempt_start(&source[..whole.start()], a) else { continue };
        let b_start = gb.start() + gb.as_str().len() - gb.as_str().trim_start_matches(is_space).len();
        m.mark(start, b_start, SpanKind::Repair);
    }
}

/// 前面刚说过 attempt（改口前的说法）时它的开头；英文要在词的边界上（ice 不算 notice 的结尾）。
fn repeated_attempt_start(prefix: &str, attempt: &str) -> Option<usize> {
    let trimmed = prefix.trim_end_matches(|c| is_space(c) || REPAIR_PUNCT.contains(c));
    if attempt.is_empty() || !trimmed.ends_with(attempt) {
        return None;
    }
    let start = trimmed.len() - attempt.len();
    if let (Some(r), Some(first)) = (last_char(&trimmed[..start]), first_char(attempt)) {
        if is_letter(r) && is_letter(first) && !is_han(r) && !is_han(first) {
            return None;
        }
    }
    Some(start)
}

fn replacement_blocked(s: &str) -> bool {
    let lower = s.trim().to_lowercase();
    ["不", "没", "别", "未", "也许", "可能", "大概", "或许", "maybe", "perhaps", "might"].iter().any(|p| lower.starts_with(p))
}

fn same_whole_repair_kind(a: &str, b: &str) -> bool {
    let (va, vb) = (find_repair_values(a), find_repair_values(b));
    va.len() == 1
        && vb.len() == 1
        && va[0].start == 0
        && va[0].end == a.len()
        && vb[0].start == 0
        && vb[0].end == b.len()
        && va[0].kind == vb[0].kind
}

fn repair_kind_of(text: &str) -> String {
    let values = find_repair_values(text);
    if values.len() == 1 {
        values[0].kind.clone()
    } else {
        String::new()
    }
}

fn extend_same_kind(source: &str, from: usize, kind: &str) -> usize {
    if kind.is_empty() {
        return from;
    }
    let head = source[..from].trim_end_matches(|c| is_space(c) || REPAIR_PUNCT.contains(c));
    match find_repair_values(head).last() {
        Some(last) if last.kind == kind && last.end == head.len() => last.start,
        _ => from,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn check(source: &str, want: &str) {
        let got = clean_speech(source);
        assert_eq!(got.text, want, "source {source:?} spans {:?}", got.spans);
        let applied = apply_spans(source, &got.spans).expect("span round trip");
        assert_eq!(applied, got.text.trim(), "span round trip {source:?}");
        assert_eq!(clean_speech(&got.text).text, got.text, "not idempotent {source:?}");
    }

    // speech_cleanup_test.go 的 TestSpeechCleanup
    #[test]
    fn speech_cleanup() {
        let cases = [
            ("呃，那个，我想问一下，评审几点开始？", "我想问一下，评审几点开始？"),
            ("我要那个，别拿这个。", "我要那个，别拿这个。"),
            ("あのボタンは削除しないでください。", "あのボタンは削除しないでください。"),
            ("文案里的“呃”和\"um\"都保留。", "文案里的“呃”和\"um\"都保留。"),
            ("保留“呃，那个，我想问一下", "保留“呃，那个，我想问一下"),
            ("Keep `I I` and `, like,` intact.", "Keep `I I` and `, like,` intact."),
            ("Uh, um, please do not delete it.", "please do not delete it."),
            ("I,like,need it today.", "I,like,need it today."),
            ("I, like, need it today.", "I need it today."),
            ("I like that, but I might wait.", "I like that, but I might wait."),
            ("我我觉得这个这个可能不行。", "我觉得这个可能不行。"),
            ("I I might need the the earlier train.", "I might need the earlier train."),
            ("It is very very important.", "It is very very important."),
            ("Use A A for the label.", "Use A A for the label."),
            ("Keep I_I I_I.", "Keep I_I I_I."),
            ("Keep İtem the red folder, I mean the blue folder.", "Keep İtem the blue folder."),
            ("就是说这个 max_retry_count 的话不要改名，然后的话 timeout 设成 30 秒。", "这个 max_retry_count 不要改名，timeout 设成 30 秒。"),
            ("如果 timeout 失败的话不要重试。", "如果 timeout 失败的话不要重试。"),
            ("这个 API 失败的话不要重试。", "这个 API 失败的话不要重试。"),
            ("I had had enough of that that day.", "I had had enough of that that day."),
            ("Send it to Alice, no wait, send it to Bob.", "send it to Bob."),
            ("Use the red folder, I mean the blue folder.", "Use the blue folder."),
            ("Keep the draft. Send it to Alice, no wait, send it to Bob.", "Keep the draft. send it to Bob."),
            ("会議は三時、いや、五時からです。", "会議は五時からです。"),
            ("La réunion est mardi, non pardon, jeudi.", "La réunion est jeudi."),
            ("La reunión es el martes, perdón, el jueves.", "La reunión es el jueves."),
            ("えーと、あの、会議は何時ですか。", "会議は何時ですか。"),
            ("I might send it to Alice, no wait, I will send it to Bob.", "I might send it to Alice, no wait, I will send it to Bob."),
            ("Do not ship Tuesday, no wait, do ship Thursday.", "Do not ship Tuesday, no wait, do ship Thursday."),
            ("I need the report, sorry, I need the spreadsheet too.", "I need the report, sorry, I need the spreadsheet too."),
            ("Send it to Alice in Berlin, no wait, send it to Bob.", "Send it to Alice in Berlin, no wait, send it to Bob."),
            ("The report is ready, sorry, I have a question.", "The report is ready, sorry, I have a question."),
            ("Send it to Alice, no wait, ", "Send it to Alice, no wait,"),
            ("呃，嗯", "呃，嗯"),
            ("umbrella and hum", "umbrella and hum"),
            ("文案里的“呃”和“那个”都保留，别删除。", "文案里的“呃”和“那个”都保留，别删除。"),
            ("Keep the exact word \"um\" in the title.", "Keep the exact word \"um\" in the title."),
            ("Um, don't delete 'uh' or 'um'.", "don't delete 'uh' or 'um'."),
            ("um l'équipe arrive", "l'équipe arrive"),
            ("um keep \"uh\" here, uh please", "keep \"uh\" here,  please"),
            ("保留原文“呃", "保留原文“呃"),
            ("余额，名额，金额。", "余额，名额，金额。"),
            ("嗯我觉得这个可以，呃这个还不行。", "我觉得这个可以，这个还不行。"),
            ("那个按钮别删，啊不对，删这个按钮。", "那个按钮别删，啊不对，删这个按钮。"),
            ("嗯，我觉得 um 这个可以", "我觉得  这个可以"),
        ];
        for (source, want) in cases {
            check(source, want);
        }
    }

    // TestSpeechSpanContract
    #[test]
    fn span_contract() {
        let source = "呃，keep \"um\".";
        let bad = [
            vec![Span { start: 0, end: 99, kind: SpanKind::Hesitation }],
            vec![Span { start: 0, end: 1, kind: SpanKind::Hesitation }],
            vec![Span { start: 0, end: 3, kind: SpanKind::Hesitation }, Span { start: 0, end: 3, kind: SpanKind::Repair }],
            vec![Span { start: 11, end: 13, kind: SpanKind::Hesitation }],
        ];
        for spans in bad {
            assert!(apply_spans(source, &spans).is_none(), "accepted {spans:?}");
        }
    }

    // TestSpeechCleanupCopularQuantityRepair
    #[test]
    fn copular_quantity_repair() {
        let cases = [
            ("把超时设成四十秒，不对，是四秒，保留并发数，先别改其他配置。", "把超时设成四秒，保留并发数，先别改其他配置。", true),
            ("超时40秒，不对，是4秒，先别重试。", "超时4秒，先别重试。", true),
            ("超时40秒，不对，　是　4秒，先别重试。", "超时4秒，先别重试。", true),
            ("预算四十元，不对，是四秒，先别提交。", "预算四十元，不对，是四秒，先别提交。", false),
            ("超时四十秒，不对，不是四秒，先别改。", "超时四十秒，不对，不是四秒，先别改。", false),
            ("超时四十秒，不对，也许是四秒，先别改。", "超时四十秒，不对，也许是四秒，先别改。", false),
            ("超时四十秒，不对，是四秒后重试，先别提交。", "超时四十秒，不对，是四秒后重试，先别提交。", false),
            ("把超时设成四秒，不是四十秒，先别改配置。", "把超时设成四秒，不是四十秒，先别改配置。", false),
            ("保留“超时四十秒，不对，是四秒”。", "保留“超时四十秒，不对，是四秒”。", false),
            ("地点北京，不对，是上海。", "地点北京，不对，是上海。", false),
        ];
        for (source, want, repaired) in cases {
            let got = clean_speech(source);
            assert_eq!(got.text, want, "{source:?} spans {:?}", got.spans);
            if repaired {
                assert!(got.spans.len() == 1 && got.spans[0].kind == SpanKind::Repair, "{source:?} {:?}", got.spans);
            } else {
                assert!(got.spans.is_empty(), "{source:?} {:?}", got.spans);
            }
            assert_eq!(apply_spans(source, &got.spans).as_deref(), Some(want));
            assert_eq!(clean_speech(&got.text).text, got.text);
        }
    }

    // speech_repair_test.go 的 TestSpokenSelfRepairCollapsesToFinalSpan
    #[test]
    fn spoken_self_repair() {
        let cases = [
            ("十二月，十三月，什么十三，没有十三，十一月", "十一月"),
            ("十二月…十三月…什么十三，没有十三…十一月", "十一月"),
            ("开会定在十二月，十三月，什么十三，没有十三，十一月下午", "开会定在十一月下午"),
            ("十二月。十三月。什么十三，没有十三。十一月", "十一月"),
            ("来了三十人，不对，五十人。", "来了五十人。"),
            ("预算报三十，不对，五十。", "预算报五十。"),
            ("帮我告诉张三，不是张三，是李四，明天不用来了。", "帮我告诉李四，明天不用来了。"),
            ("不是三十人，是五十人。", "五十人。"),
            ("见十二月，不是十三月，是十一月。", "见十一月。"),
            ("Meet in December, no, November.", "Meet in November."),
            ("We need three people, no, five people.", "We need five people."),
            ("Send it to Alice, not Alice, it's Bob.", "Send it to Bob."),
            ("Send it to Alice, no, send it to Bob.", "send it to Bob."),
        ];
        for (source, want) in cases {
            check(source, want);
        }
    }

    // TestSpokenRepairLeavesContentAndWording
    #[test]
    fn spoken_repair_leaves_content() {
        let cases = [
            "把超时设成四秒，不是四十秒，先别改配置。",
            "读数是负一点五度，不是正一点五度。",
            "我不是张三，是李四。",
            "十二月和十一月都要。",
            "十二月，十一月。",
            "保留“十二月，十三月，什么十三，没有十三，十一月”。",
            "请核对账目，别急着提交。",
            "Please reconcile the ledger before Friday.",
            "Set pollingDelay to five seconds, not fifty seconds, keep the attempt limit.",
            "十二月，十三月，什么十三，没有十三",
        ];
        for source in cases {
            assert_eq!(clean_speech(source).text.trim(), source.trim(), "changed wording");
        }
    }
}
