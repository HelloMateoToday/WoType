//! 改错学习：语音插入的文字，用户改了里面的词（「送火」改成「纵火」），找出改了什么，记成错误写法 → 正确写法。
//! 在插入的文字前后打字、删掉、清空、整段重写都不算。
//!
//! 照 Arion packages/core/domain/learning.go、learning_words.go@d2108fe（AGPL-3.0-only）逐行移植
//! （ExtractCorrections）；分词由调用方给（Swift 用 CFStringTokenizer，和 Arion 的 wordseg 一样）。

use super::text::{is_cjk_punct, is_digit, is_letter};

/// 最多从多长的插入里学
pub const MAX_EDIT_RUNES: usize = 2000;
/// 学到的一对，每边最长几个字：词、名字、短语，不是句子
pub const MAX_PAIR_RUNES: usize = 16;
/// 一次修改最多几处；再多是重写，不是改错
pub const MAX_EDIT_HUNKS: usize = 3;
/// 中文一边最短几个字：单个字太容易误换
const MIN_CJK_PAIR: usize = 2;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Verdict {
    Learned,
    Unchanged,
    Cleared,
    NotFound,
    Outside,
    TooLarge,
    Rewrite,
    NoPair,
    WordsUnavailable,
}

impl Verdict {
    pub fn name(self) -> &'static str {
        match self {
            Verdict::Learned => "learned",
            Verdict::Unchanged => "unchanged",
            Verdict::Cleared => "cleared",
            Verdict::NotFound => "not_found",
            Verdict::Outside => "outside",
            Verdict::TooLarge => "too_large",
            Verdict::Rewrite => "rewrite",
            Verdict::NoPair => "no_pair",
            Verdict::WordsUnavailable => "words_unavailable",
        }
    }
}

/// 一个词的范围（按 Unicode 字符，左闭右开）。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct WordSpan {
    pub start: usize,
    pub end: usize,
}

/// 一次插入：inserted 是插进去的字，baseline 是刚插入后的输入框，settled 是用户改完以后的输入框。
pub struct FieldEdit<'a> {
    pub inserted: &'a str,
    pub baseline: &'a str,
    pub settled: &'a str,
}

/// 分词。None 是分不了。
pub type Segmenter<'a> = &'a dyn Fn(&str) -> Option<Vec<WordSpan>>;

/// 找出用户在插入的文字里改了哪些词（ExtractCorrections）。
pub fn extract_corrections(e: &FieldEdit, segmenter: Option<Segmenter>) -> (Verdict, Vec<(String, String)>) {
    if e.settled.trim().is_empty() {
        return (Verdict::Cleared, vec![]);
    }
    if e.settled == e.baseline {
        return (Verdict::Unchanged, vec![]);
    }
    if e.inserted.trim().is_empty() || e.inserted.chars().count() > MAX_EDIT_RUNES {
        return (Verdict::NotFound, vec![]);
    }
    let Some(at) = e.baseline.rfind(e.inserted) else { return (Verdict::NotFound, vec![]) };
    let end = at + e.inserted.len();
    let (prefix, suffix) = common_affixes(e.baseline, e.settled);
    // 改动都要在插入的范围里，两边的字原样
    if prefix < at || e.baseline.len() - suffix > end || e.settled.len() < at + e.baseline.len() - end {
        return (Verdict::Outside, vec![]);
    }
    let edited = &e.settled[at..e.settled.len() - (e.baseline.len() - end)];
    if edited == e.inserted {
        return (Verdict::Unchanged, vec![]);
    }
    if edited.chars().count() > MAX_EDIT_RUNES {
        return (Verdict::TooLarge, vec![]);
    }
    let (a, b) = (edit_units(e.inserted), edit_units(edited));
    let ops = diff_units(&a, &b);
    let (mut removed, mut added) = (0, 0);
    for op in &ops {
        match op.kind {
            Op::Delete => removed += content_weight(&a[op.i]),
            Op::Insert => added += content_weight(&b[op.j]),
            Op::Equal => {}
        }
    }
    // 大部分要留着：删掉三分之二以上、或者多打了两倍以上，是重写不是改错
    let total: usize = a.iter().map(|u| content_weight(u)).sum();
    if edited.trim().is_empty() || removed * 3 > total * 2 || added > 2 * total {
        return (Verdict::TooLarge, vec![]);
    }
    let mut hunks = group_hunks(&a, &ops);
    if hunks.len() > MAX_EDIT_HUNKS {
        return (Verdict::Rewrite, vec![]);
    }
    let needs_words = hunks.iter().any(|&h| {
        let h = trim_hunk(&a, &b, h);
        let (from, to) = (a[h.i0..h.i1].concat(), b[h.j0..h.j1].concat());
        content_weight(&from) > 0
            && content_weight(&to) > 0
            && !(numeric(&from) && numeric(&to))
            && !exempt_change(&from, &to)
            && (has_cjk(&from) || has_cjk(&to))
    });
    if needs_words {
        let Some(segmenter) = segmenter else { return (Verdict::WordsUnavailable, vec![]) };
        let (Some(source_words), Some(words)) = (segmenter(e.inserted), segmenter(edited)) else {
            return (Verdict::WordsUnavailable, vec![]);
        };
        if !valid_word_spans(&source_words, e.inserted.chars().count()) || !valid_word_spans(&words, edited.chars().count()) {
            return (Verdict::WordsUnavailable, vec![]);
        }
        hunks = align_word_hunks(&a, &b, &hunks, &source_words, &words);
    }
    let mut pairs: Vec<(String, String)> = Vec::new();
    for h in hunks {
        let h = trim_hunk(&a, &b, h);
        if sentence_case(&a, &b, h) {
            continue;
        }
        if let Some(pair) = hunk_pair(&a, &b, h) {
            if !pairs.contains(&pair) {
                pairs.push(pair);
            }
        }
    }
    if pairs.is_empty() {
        return (Verdict::NoPair, vec![]);
    }
    (Verdict::Learned, pairs)
}

/// 最长的相同开头和结尾（字节数，不重叠，都在字的边界上）。
fn common_affixes(x: &str, y: &str) -> (usize, usize) {
    let mut p = 0;
    for (cx, cy) in x.chars().zip(y.chars()) {
        if cx != cy {
            break;
        }
        p += cx.len_utf8();
    }
    let mut s = 0;
    for (cx, cy) in x[p..].chars().rev().zip(y[p..].chars().rev()) {
        if cx != cy {
            break;
        }
        s += cx.len_utf8();
    }
    (p, s)
}

fn latin_or_digit(c: char) -> bool {
    c.is_ascii() && (is_letter(c) || is_digit(c))
}

/// 切成单位：英文词或数字、单个汉字、连续的空白、单个别的字（标点）。
fn edit_units(s: &str) -> Vec<String> {
    let runes: Vec<char> = s.chars().collect();
    let mut out = Vec::new();
    let mut i = 0;
    while i < runes.len() {
        let mut j = i + 1;
        let r = runes[i];
        if latin_or_digit(r) {
            while j < runes.len() && (latin_or_digit(runes[j]) || inner_joiner(&runes, j)) {
                j += 1;
            }
        } else if r.is_whitespace() {
            while j < runes.len() && runes[j].is_whitespace() {
                j += 1;
            }
        }
        out.push(runes[i..j].iter().collect());
        i = j;
    }
    out
}

/// 英文词里面的撇号、连字符、点（don't、gpt-4o、v1.2）。
fn inner_joiner(runes: &[char], j: usize) -> bool {
    "'-.".contains(runes[j]) && j + 1 < runes.len() && latin_or_digit(runes[j + 1]) && latin_or_digit(runes[j - 1])
}

/// 字母和数字的个数：只改空白、标点不算大改。
fn content_weight(u: &str) -> usize {
    u.chars().filter(|&c| is_letter(c) || is_digit(c)).count()
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Op {
    Equal,
    Delete,
    Insert,
}

#[derive(Clone, Copy)]
struct DiffOp {
    kind: Op,
    i: usize,
    j: usize,
}

/// 最长公共子序列的差异。
fn diff_units(a: &[String], b: &[String]) -> Vec<DiffOp> {
    let (n, m) = (a.len(), b.len());
    let mut lcs = vec![vec![0i32; m + 1]; n + 1];
    for i in (0..n).rev() {
        for j in (0..m).rev() {
            lcs[i][j] = if a[i] == b[j] { lcs[i + 1][j + 1] + 1 } else { lcs[i + 1][j].max(lcs[i][j + 1]) };
        }
    }
    let mut ops = Vec::new();
    let (mut i, mut j) = (0, 0);
    while i < n || j < m {
        if i < n && j < m && a[i] == b[j] {
            ops.push(DiffOp { kind: Op::Equal, i, j });
            i += 1;
            j += 1;
        } else if j < m && (i == n || lcs[i][j + 1] >= lcs[i + 1][j]) {
            ops.push(DiffOp { kind: Op::Insert, i, j });
            j += 1;
        } else {
            ops.push(DiffOp { kind: Op::Delete, i, j });
            i += 1;
        }
    }
    ops
}

/// 一处改动：a[i0..i1] 改成了 b[j0..j1]。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Hunk {
    i0: usize,
    i1: usize,
    j0: usize,
    j1: usize,
}

/// 只隔一个空白的改动并成一处（「open ai」→「OpenAI」）。
fn group_hunks(a: &[String], ops: &[DiffOp]) -> Vec<Hunk> {
    let mut out: Vec<Hunk> = Vec::new();
    let mut gap: Vec<DiffOp> = Vec::new();
    for &op in ops {
        if op.kind == Op::Equal {
            gap.push(op);
            continue;
        }
        let mut joined = !out.is_empty() && gap.len() <= 1;
        if joined && gap.len() == 1 {
            joined = a[gap[0].i].trim().is_empty();
        }
        if !joined {
            out.push(Hunk { i0: op.i, i1: op.i, j0: op.j, j1: op.j });
        }
        let h = out.last_mut().unwrap();
        if op.kind == Op::Delete {
            h.i1 = op.i + 1;
        } else {
            h.j1 = op.j + 1;
        }
        h.i1 = h.i1.max(op.i);
        h.j1 = h.j1.max(op.j);
        gap.clear();
    }
    out
}

/// 一处改动变成一对词条（hunkPair）。
fn hunk_pair(a: &[String], b: &[String], h: Hunk) -> Option<(String, String)> {
    let from = a[h.i0..h.i1].concat().trim().to_string();
    let to = b[h.j0..h.j1].concat().trim().to_string();
    if content_weight(&from) == 0 || content_weight(&to) == 0 || from == to {
        return None;
    }
    // 改的是数字、时间：是改内容，不是拼写
    if numeric(&from) && numeric(&to) {
        return None;
    }
    // 改小写是风格，不强制；改大写（iphone → iPhone）算
    if from.to_lowercase() == to.to_lowercase() && upper_count(&to) <= upper_count(&from) {
        return None;
    }
    // 单个英文字母太模糊
    let mut chars = from.chars();
    if let (Some(c), None) = (chars.next(), chars.next()) {
        if latin_or_digit(c) {
            return None;
        }
    }
    // 他/她/它、的/地/得、在/再：看句子定，不能一换了之
    if exempt_change(&from, &to) {
        return None;
    }
    if (has_cjk(&from) || has_cjk(&to)) && (from.chars().count() < MIN_CJK_PAIR || to.chars().count() < MIN_CJK_PAIR) {
        return None;
    }
    if from.chars().count() > MAX_PAIR_RUNES || to.chars().count() > MAX_PAIR_RUNES || (from.clone() + &to).contains(['\n', '\r']) {
        return None;
    }
    Some((from, to))
}

/// 去掉一处改动两头的标点和空白（改完词顺手加的逗号不算进去）。
fn trim_hunk(a: &[String], b: &[String], mut h: Hunk) -> Hunk {
    while h.i0 < h.i1 && content_weight(&a[h.i0]) == 0 {
        h.i0 += 1;
    }
    while h.i1 > h.i0 && content_weight(&a[h.i1 - 1]) == 0 {
        h.i1 -= 1;
    }
    while h.j0 < h.j1 && content_weight(&b[h.j0]) == 0 {
        h.j0 += 1;
    }
    while h.j1 > h.j0 && content_weight(&b[h.j1 - 1]) == 0 {
        h.j1 -= 1;
    }
    h
}

/// 句首改大小写：是排版，不是拼写。
fn sentence_case(a: &[String], b: &[String], h: Hunk) -> bool {
    let (from, to) = (a[h.i0..h.i1].concat(), b[h.j0..h.j1].concat());
    if from == to || from.to_lowercase() != to.to_lowercase() {
        return false;
    }
    for i in (0..h.i0).rev() {
        if a[i].contains('\n') {
            return true;
        }
        let u = a[i].trim();
        if u.is_empty() {
            continue;
        }
        return u.contains(['.', '!', '?', '。', '！', '？']);
    }
    true
}

/// 读音相近、按语法或意思选的字。
const EXEMPT_GROUPS: &[&str] = &["他她它祂", "的地得", "在再", "那哪", "做作", "以已", "即既", "象像"];

fn exempt_change(from: &str, to: &str) -> bool {
    let (a, b): (Vec<char>, Vec<char>) = (from.chars().collect(), to.chars().collect());
    if a.len() != b.len() {
        return false;
    }
    let mut changed = false;
    for (x, y) in a.iter().zip(&b) {
        if x == y {
            continue;
        }
        changed = true;
        if !EXEMPT_GROUPS.iter().any(|g| g.contains(*x) && g.contains(*y)) {
            return false;
        }
    }
    changed
}

fn upper_count(s: &str) -> usize {
    s.chars().filter(|c| c.is_uppercase()).count()
}

/// 只有数字、中文数字和数字里的标点。
fn numeric(s: &str) -> bool {
    !s.is_empty() && s.chars().all(|r| is_digit(r) || "〇零一二三四五六七八九十百千万亿两.,:：".contains(r) || r.is_whitespace())
}

fn has_cjk(s: &str) -> bool {
    s.chars().any(|c| super::text::is_cjk(c) && !is_cjk_punct(c))
}

// MARK: - 按词对齐（learning_words.go）

fn valid_word_spans(words: &[WordSpan], length: usize) -> bool {
    let mut end = 0;
    for w in words {
        if w.start < end || w.end <= w.start || w.end > length {
            return false;
        }
        end = w.end;
    }
    !words.is_empty()
}

/// 中文的改动要扩到完整的词（两边都是）。按原文的词边界，改完后分词认不出的名字也能留住。
fn align_word_hunks(a: &[String], b: &[String], hunks: &[Hunk], source: &[WordSpan], target: &[WordSpan]) -> Vec<Hunk> {
    let (aw, bw) = (unit_words(a, source), unit_words(b, target));
    struct Candidate {
        h: Hunk,
        from: WordSpan,
        to: WordSpan,
    }
    let mut candidates: Vec<Candidate> = Vec::new();
    for &raw in hunks {
        let h = trim_hunk(a, b, raw);
        let (from, to) = (a[h.i0..h.i1].concat(), b[h.j0..h.j1].concat());
        if content_weight(&from) == 0 || content_weight(&to) == 0 || (numeric(&from) && numeric(&to)) || exempt_change(&from, &to) {
            continue;
        }
        let mut left = WordSpan { start: h.i0, end: h.i1 };
        let mut right = WordSpan { start: h.j0, end: h.j1 };
        if has_cjk(&from) || has_cjk(&to) {
            let Some(l) = covering_words(&aw, left) else { continue };
            let Some(r) = covering_words(&bw, right) else { continue };
            left = l;
            right = r;
            // 单个字没有能复用的词边界，只放过「字 + 语气词」（报吗）
            if left.end - left.start == 1 && right.end - right.start == 1 {
                if right.end < b.len() && question_particle(&b[right.end]) && has_cjk(&b[right.start]) {
                    right.end += 1;
                } else {
                    continue;
                }
            }
        }
        if let Some(prev) = candidates.last_mut().filter(|p| left.start < p.from.end || right.start < p.to.end) {
            prev.h.i1 = h.i1;
            prev.h.j1 = h.j1;
            prev.from.end = prev.from.end.max(left.end);
            prev.to.end = prev.to.end.max(right.end);
        } else {
            candidates.push(Candidate { h, from: left, to: right });
        }
    }
    let mut out = Vec::new();
    for c in candidates {
        let mut h = c.h;
        let left = (h.i0 as isize - c.from.start as isize).max(h.j0 as isize - c.to.start as isize);
        let mut right = (c.from.end as isize - h.i1 as isize).max(c.to.end as isize - h.j1 as isize);
        let mut valid = true;
        for _ in 0..left.max(0) {
            if h.i0 == 0 || h.j0 == 0 || a[h.i0 - 1] != b[h.j0 - 1] {
                valid = false;
                break;
            }
            h.i0 -= 1;
            h.j0 -= 1;
        }
        while valid && right > 0 {
            if h.i1 == a.len() || h.j1 == b.len() || a[h.i1] != b[h.j1] {
                valid = false;
                break;
            }
            h.i1 += 1;
            h.j1 += 1;
            right -= 1;
        }
        // 从一边扩的时候不能切开另一边更长的词
        if valid && word_edges(&aw, h.i0, h.i1) && word_edges(&bw, h.j0, h.j1) {
            out.push(h);
        }
    }
    out
}

fn question_particle(word: &str) -> bool {
    word.chars().count() == 1 && "吗呢吧啊呀嘛".contains(word)
}

/// 按字的词范围换成单位的下标；切在英文词中间的不要。
fn unit_words(units: &[String], spans: &[WordSpan]) -> Vec<WordSpan> {
    let mut offsets = std::collections::HashMap::from([(0usize, 0usize)]);
    let mut position = 0;
    for (i, u) in units.iter().enumerate() {
        position += u.chars().count();
        offsets.insert(position, i + 1);
    }
    spans
        .iter()
        .filter_map(|s| Some(WordSpan { start: *offsets.get(&s.start)?, end: *offsets.get(&s.end)? }))
        .collect()
}

fn covering_words(words: &[WordSpan], change: WordSpan) -> Option<WordSpan> {
    let mut result: Option<WordSpan> = None;
    for w in words {
        if w.start < change.end && w.end > change.start {
            match &mut result {
                None => result = Some(*w),
                Some(r) => r.end = w.end,
            }
        }
    }
    result.filter(|r| r.start <= change.start && r.end >= change.end)
}

fn word_edges(words: &[WordSpan], start: usize, end: usize) -> bool {
    !words.iter().any(|w| w.start < start && w.end > start || w.start < end && w.end > end)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// learning_test.go 的 learningTestSegmenter：认几个固定的词，别的一个单位一个词。
    fn segmenter(text: &str) -> Option<Vec<WordSpan>> {
        let units = edit_units(text);
        let mut spans = Vec::new();
        let mut position = 0;
        let mut i = 0;
        while i < units.len() {
            let mut word = units[i].clone();
            let mut count = 1;
            for known in ["纵火", "送火", "小王", "晓王", "回复", "回付", "公式", "公示", "全棉", "全免", "数据库", "模型"] {
                if units[i..].concat().starts_with(known) {
                    word = known.to_string();
                    count = known.chars().count();
                    break;
                }
            }
            let end = position + word.chars().count();
            spans.push(WordSpan { start: position, end });
            position = end;
            i += count;
        }
        Some(spans)
    }

    fn run(inserted: &str, baseline: &str, settled: &str) -> (Verdict, Vec<(String, String)>) {
        extract_corrections(&FieldEdit { inserted, baseline, settled }, Some(&segmenter))
    }

    fn pairs(list: &[(&str, &str)]) -> Vec<(String, String)> {
        list.iter().map(|(a, b)| (a.to_string(), b.to_string())).collect()
    }

    // TestExtractCorrections
    #[test]
    fn extract() {
        use Verdict::*;
        let cases: Vec<(&str, &str, &str, Verdict, Vec<(String, String)>)> = vec![
            ("成功处置深航机上送火事件", "新闻：成功处置深航机上送火事件", "新闻：成功处置深航机上纵火事件", Learned, pairs(&[("送火", "纵火")])),
            ("ask jason about the release", "Hi, ask jason about the release", "Hi, ask Jayson about the release", Learned, pairs(&[("jason", "Jayson")])),
            ("we use open ai models", "we use open ai models", "we use OpenAI models", Learned, pairs(&[("open ai", "OpenAI")])),
            ("把阿里昂的配置发给小王", "把阿里昂的配置发给小王", "把Arion的配置发给晓王", Learned, pairs(&[("阿里昂", "Arion"), ("小王", "晓王")])),
            ("打开杰森文件", "打开杰森文件", "打开JSON文件", Learned, pairs(&[("杰森", "JSON")])),
            ("明天开会", "明天开会", "明天开会，记得带电脑", NoPair, vec![]),
            ("明天开会", "备注：明天开会", "重要备注：明天开会", Outside, vec![]),
            ("好的 我知道了", "好的 我知道了", "好的，我知道了。", NoPair, vec![]),
            ("this is really good", "this is really good", "this is good", NoPair, vec![]),
            ("let us meet tomorrow at noon", "let us meet tomorrow at noon", "see you friday", TooLarge, vec![]),
            ("明天下午三点开会", "明天下午三点开会", "明天下午四点开会", NoPair, vec![]),
            ("the budget is 5000 dollars", "the budget is 5000 dollars", "the budget is 6000 dollars", NoPair, vec![]),
            ("done\nok thanks", "done\nok thanks", "done\nOk thanks", NoPair, vec![]),
            ("ask Cozette now", "ask Cozette now", "ask cozette now", NoPair, vec![]),
            ("merge to M today", "merge to M today", "merge to main today", NoPair, vec![]),
            ("我觉得他也同意", "我觉得他也同意", "我觉得她也同意", NoPair, vec![]),
            ("认真的学习", "认真的学习", "认真地学习", NoPair, vec![]),
            ("hello", "hello", "  ", Cleared, vec![]),
            ("hello", "x hello", "x hello", Unchanged, vec![]),
            ("hello", "goodbye", "goodbye!", NotFound, vec![]),
            ("a1 b c d e f g h", "a1 b c d e f g h", "a1 B c D e F g H", Rewrite, vec![]),
            ("在", "在", "再", TooLarge, vec![]),
            ("收到请回付", "收到请回付", "收到请回复", Learned, pairs(&[("回付", "回复")])),
            ("公示需要修改", "公示需要修改", "公式需要修改", Learned, pairs(&[("公示", "公式")])),
            ("这个公示已经更新", "这个公示已经更新", "这个公式已经更新", Learned, pairs(&[("公示", "公式")])),
            ("这是全免的衣服", "这是全免的衣服", "这是全棉的衣服", Learned, pairs(&[("全免", "全棉")])),
            ("codex能爆吗", "codex能爆吗", "codex能报吗", Learned, pairs(&[("爆吗", "报吗")])),
            ("我们在来一次", "我们在来一次", "我们再来一次", NoPair, vec![]),
            ("please send it", "please send it", "please forward the quarterly planning spreadsheet it", TooLarge, vec![]),
            ("call get user by id first", "call get user by id first", "call getUserById first", Learned, pairs(&[("get user by id", "getUserById")])),
            ("ok sounds good", "ok sounds good", "Ok, sounds good!", NoPair, vec![]),
            ("the new iphone is out", "the new iphone is out", "the new iPhone is out", Learned, pairs(&[("iphone", "iPhone")])),
            ("我觉得这个方案还可以再改改", "我觉得这个方案还可以再改改", "方案通过", TooLarge, vec![]),
        ];
        for (inserted, baseline, settled, verdict, want) in cases {
            let got = run(inserted, baseline, settled);
            assert_eq!(got, (verdict, want), "{inserted:?} → {settled:?}");
        }
    }

    // TestChangesInsideOneWordMerge
    #[test]
    fn changes_inside_one_word_merge() {
        let got = run("这个术据酷需要迁移", "这个术据酷需要迁移", "这个数据库需要迁移");
        assert_eq!(got, (Verdict::Learned, pairs(&[("术据酷", "数据库")])));
    }

    // TestMissingOrInvalidSegmentationNeverGuesses
    #[test]
    fn invalid_segmentation_never_guesses() {
        let edit = FieldEdit { inserted: "公示需要修改", baseline: "公示需要修改", settled: "公式需要修改" };
        assert_eq!(extract_corrections(&edit, None), (Verdict::WordsUnavailable, vec![]));
        for spans in [vec![], vec![WordSpan { start: 0, end: 99 }], vec![WordSpan { start: 0, end: 3 }, WordSpan { start: 2, end: 4 }]] {
            let seg = move |_: &str| Some(spans.clone());
            assert_eq!(extract_corrections(&edit, Some(&seg)), (Verdict::WordsUnavailable, vec![]));
        }
    }
}
