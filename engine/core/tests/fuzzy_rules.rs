//! 换模糊音规则后立即生效（词库的模糊索引会重建）。
//!
//! 规则是进程级的，放在单独的测试文件里（单独一个进程），不影响别的测试。

use std::sync::Arc;

use wotype_core::lm::BigramLm;
use wotype_core::syllable::{set_fuzzy_rules, DEFAULT_FUZZY_RULES};
use wotype_core::{Engine, Lexicon, MemoryLexicon};

#[test]
fn switching_rules_takes_effect_immediately() {
    let lexicon: Arc<dyn Lexicon> = Arc::new(
        MemoryLexicon::from_tsv_str("lan mao\t懒猫\t5000\nzhi dao\t知道\t5000\nfei ji\t飞机\t5000\n").unwrap(),
    );
    let mut e = Engine::new(lexicon, Arc::new(BigramLm::default()));
    e.set_typo_correction(false);
    e.set_fuzzy(true);
    let has = |e: &Engine, input: &str, word: &str| e.input(input).iter().any(|c| c.text == word);

    // 默认规则：z=zh 开着，n=l 没开
    assert!(has(&e, "zidao", "知道"));
    assert!(!has(&e, "nanmao", "懒猫"));

    // 换成 n=l 和 hui=fei：知道不再模糊，懒猫、飞机能打出来
    assert_eq!(set_fuzzy_rules(&["n=l", "hui=fei", "不认识的"]), 2);
    assert!(has(&e, "nanmao", "懒猫"));
    assert!(has(&e, "huiji", "飞机"));
    assert!(!has(&e, "zidao", "知道"));

    // 一条都不开
    set_fuzzy_rules(&[]);
    assert!(!has(&e, "nanmao", "懒猫"));

    set_fuzzy_rules(DEFAULT_FUZZY_RULES);
    assert!(has(&e, "zidao", "知道"));
}
