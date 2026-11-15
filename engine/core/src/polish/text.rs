//! 几处共用的文字判断，照 Arion packages/core/domain@d2108fe（AGPL-3.0-only）的
//! correction.go（IsCJK）、quotes.go（quotedText）、rewrite.go（contentRunes、latinWords、negations）、
//! rewrite_fidelity.go（losesUncertainty）。
//!
//! Go 和 Rust 的差别：
//! - Go 的 unicode.IsLetter / IsDigit 是 L / Nd 类，这里用 char::is_alphabetic / is_numeric
//!   （稍宽一点，多了少数带字母属性的符号），对中英文的结果一样；
//! - Go 正则的 `\s`、`\b`、`\d` 只认 ASCII，Rust 的认全部 Unicode：移植的正则里写成
//!   `[\t\n\f\r ]`、`(?-u:\b)`、`[0-9]`。

use regex::Regex;
use std::sync::LazyLock;

/// 引号里的是原话，不删不改；没合上的引号保护到结尾。直的单引号只在非字母后面才算开引号。
pub static QUOTED_TEXT: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r#"“[^”]*(?:”|$)|「[^」]*(?:」|$)|『[^』]*(?:』|$)|‘[^’]*(?:’|$)|"[^"]*(?:"|$)|`[^`]*(?:`|$)|(?:^|[^\p{L}\p{N}])'[^']*(?:'|$)"#)
        .unwrap()
});

/// 汉字、假名、谚文和全角标点（IsCJK）。
pub fn is_cjk(c: char) -> bool {
    is_han(c) || is_kana(c) || is_hangul(c) || is_cjk_punct(c)
}

pub fn is_cjk_punct(c: char) -> bool {
    matches!(c as u32, 0x3000..=0x303F | 0xFF00..=0xFFEF)
}

/// Unicode 的 Han 文字（unicode.Han）。
pub fn is_han(c: char) -> bool {
    matches!(c as u32,
        0x2E80..=0x2E99 | 0x2E9B..=0x2EF3 | 0x2F00..=0x2FD5 | 0x3005 | 0x3007 | 0x3021..=0x3029
        | 0x3038..=0x303B | 0x3400..=0x4DBF | 0x4E00..=0x9FFF | 0xF900..=0xFA6D | 0xFA70..=0xFAD9
        | 0x16FE2 | 0x16FE3 | 0x16FF0 | 0x16FF1 | 0x20000..=0x2A6DF | 0x2A700..=0x2EE5D
        | 0x2F800..=0x2FA1D | 0x30000..=0x323AF)
}

pub fn is_kana(c: char) -> bool {
    matches!(c as u32, 0x3041..=0x3096 | 0x309D..=0x309F | 0x30A1..=0x30FA | 0x30FD..=0x30FF
        | 0x31F0..=0x31FF | 0x32D0..=0x32FE | 0x3300..=0x3357 | 0xFF66..=0xFF6F | 0xFF71..=0xFF9D
        | 0x1B000..=0x1B122)
}

pub fn is_hangul(c: char) -> bool {
    matches!(c as u32, 0x1100..=0x11FF | 0x302E | 0x302F | 0x3131..=0x318E | 0x3200..=0x321E
        | 0x3260..=0x327E | 0xA960..=0xA97C | 0xAC00..=0xD7A3 | 0xD7B0..=0xD7C6 | 0xD7CB..=0xD7FB
        | 0xFFA0..=0xFFBE | 0xFFC2..=0xFFC7 | 0xFFCA..=0xFFCF | 0xFFD2..=0xFFD7 | 0xFFDA..=0xFFDC)
}

pub fn is_letter(c: char) -> bool {
    c.is_alphabetic()
}

pub fn is_digit(c: char) -> bool {
    c.is_numeric()
}

/// 字母和数字（contentRunes）。
pub fn content_runes(s: &str) -> Vec<char> {
    s.chars().filter(|&c| is_letter(c) || is_digit(c)).collect()
}

/// 小写的拉丁词（只算 ASCII 字母和撇号）。
pub fn latin_words(s: &str) -> Vec<String> {
    s.to_lowercase()
        .split(|c: char| !(c.is_ascii() && (c.is_ascii_alphabetic() || c == '\'')))
        .filter(|w| !w.is_empty())
        .map(str::to_string)
        .collect()
}

/// 有意义的否定词（「不对、不是、no」这些改口的说法不算：去掉它们正是改口的意思）。
const ZH_NEGATIONS: &[&str] = &["不要", "不能", "不用", "不会", "不该", "不必", "不可", "不准", "别", "没", "未", "勿"];
const EN_NEGATIONS: &[&str] = &["not", "n't", "never", "nothing", "nobody", "cannot"];

pub fn negations(s: &str) -> usize {
    let mut n = 0;
    for m in ZH_NEGATIONS {
        n += s.matches(m).count();
    }
    let lower = format!(" {} ", s.to_lowercase());
    let words = latin_words(&lower);
    for m in EN_NEGATIONS {
        if *m == "n't" {
            n += lower.matches(m).count();
            continue;
        }
        n += words.iter().filter(|w| w.as_str() == *m).count();
    }
    n
}

static CHINESE_UNCERTAINTY: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new("可能|也许|或许|大概|似乎|不确定|不一定|无法确定|不能确定|确定不了|确定不下来|说不准|说不定").unwrap()
});

/// 只有明确改口成确定的说法，才放过前一句里的「可能」。
static CERTAINTY_REPAIR: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)[^，,。.!！?？;；]+[，,][\t\n\f\r ]*(?:不对|哦不|说错了|no wait|sorry|actually)[，,\t\n\f\r ]*((?:(?:我)?(?:确定|肯定)|(?:I am |I'm )?(?:certain|sure)|definitely)[^，,。.!！?？;；]*)").unwrap()
});

/// 原文有不确定的语气、结果里没了（rewrite_fidelity.go）。
pub fn loses_uncertainty(source: &str, candidate: &str) -> bool {
    uncertain(&CERTAINTY_REPAIR.replace_all(source, "$1")) && !uncertain(candidate)
}

fn uncertain(text: &str) -> bool {
    if CHINESE_UNCERTAINTY.is_match(text) {
        return true;
    }
    latin_words(&text.to_lowercase()).iter().any(|w| {
        matches!(w.as_str(), "might" | "may" | "perhaps" | "maybe" | "probably" | "possibly" | "uncertain" | "unsure")
    })
}

/// Go 的 strings.TrimSpace / unicode.IsSpace。
pub fn is_space(c: char) -> bool {
    c.is_whitespace()
}

/// 最后一个字（utf8.DecodeLastRuneInString；空串是 None）。
pub fn last_char(s: &str) -> Option<char> {
    s.chars().next_back()
}

pub fn first_char(s: &str) -> Option<char> {
    s.chars().next()
}
