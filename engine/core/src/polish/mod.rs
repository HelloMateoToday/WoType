//! 语音输入的润色里不用模型的部分：清理口语（speech）、场景（scene）、检查模型的结果（这里）。
//! 照 Arion@d2108fe（AGPL-3.0-only）移植，见 docs/ARION.md。提示词和调用模型在 Swift 那边。

pub mod learning;
pub mod scene;
pub mod speech;
pub mod spelling;
mod text;

pub use scene::{decide_scene, finish_scene, Scene};
pub use speech::{clean_speech, Cleanup};

/// 模型的结果不能有的东西：思考、提示词里的标签（rewrite.go 的 markers，含 context.go 的 contextTags
/// 和每个场景的标签）。
const MARKERS: &[&str] = &[
    "<think", "</think", "<source>", "</source>", "<|", "|>", "[terms", "\"transcript\"",
    "<context>", "</context>", "<screen>", "</screen>", "<before_cursor>", "</before_cursor>", "<after_cursor>",
    "</after_cursor>", "<history>", "</history>", "<dictation>", "</dictation>",
    "[chat]", "[email]", "[work]", "[prompt]", "[search]", "[list]",
];

/// 能不能上屏（rewrite.go 的 ValidateRewriteDelivery，Arion 实际用的检查）：没被截断、不空、不带标记。
/// 意思对不对（数字、否定、漏了内容）Arion 只在评测里检查，不拦上屏，这里也一样。
pub fn deliverable(candidate: &str, truncated: bool) -> bool {
    if truncated {
        return false;
    }
    let candidate = candidate.trim();
    if candidate.is_empty() {
        return false;
    }
    let lower = candidate.to_lowercase();
    !MARKERS.iter().any(|m| lower.contains(m))
}

/// 提示词选哪种语言（selected.go 的 route）：只有汉字是 han，只有拉丁字母是 latin，都有或都没有是 mixed。
pub fn route(source: &str) -> &'static str {
    let han = source.chars().any(|c| text::is_han(c) && (c as u32) >= 0x3400);
    let latin = source.chars().any(is_latin_script);
    match (han, latin) {
        (true, false) => "han",
        (false, true) => "latin",
        _ => "mixed",
    }
}

/// unicode.Latin：拉丁字母（含带变音的、全角的）。
fn is_latin_script(c: char) -> bool {
    matches!(c as u32,
        0x41..=0x5A | 0x61..=0x7A | 0xAA | 0xBA | 0xC0..=0xD6 | 0xD8..=0xF6 | 0xF8..=0x2B8 | 0x2E0..=0x2E4
        | 0x1D00..=0x1D25 | 0x1D2C..=0x1D5C | 0x1D62..=0x1D65 | 0x1D6B..=0x1D77 | 0x1D79..=0x1DBE
        | 0x1E00..=0x1EFF | 0x2071 | 0x207F | 0x2090..=0x209C | 0x212A | 0x212B | 0x2132 | 0x214E
        | 0x2160..=0x2188 | 0x2C60..=0x2C7F | 0xA722..=0xA787 | 0xA78B..=0xA7FF | 0xAB30..=0xAB5A
        | 0xAB5C..=0xAB64 | 0xFB00..=0xFB06 | 0xFF21..=0xFF3A | 0xFF41..=0xFF5A)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn delivery() {
        assert!(deliverable("好的，明天见。", false));
        assert!(!deliverable("好的", true));
        assert!(!deliverable("  ", false));
        assert!(!deliverable("<think>\n</think>好的", false));
        assert!(!deliverable("<source>好的</source>", false));
        assert!(!deliverable("[Email] 你好", false));
    }

    #[test]
    fn routes() {
        assert_eq!(route("明天开会"), "han");
        assert_eq!(route("see you"), "latin");
        assert_eq!(route("把 PR merge 了"), "mixed");
        assert_eq!(route("123"), "mixed");
    }
}
