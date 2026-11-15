//! 打印几条输入的候选，配置和 fcitx5 插件一致（候选上限 18、英文词表、纠错）。
//!
//! ```
//! wotype-show --lexicon lexicon.tsv [--english english.txt] [--mixed mixed.txt] [--lm 模型] [--fuzzy] [--fuzzy-rules z=zh,n=l,...] [--user-dict user.tsv] [--history history.tsv] [--max 18] [--context 文本] 拼音...
//! ```
//!
//! 每个候选标出类型：`句` 整句（多个词拼的）、`词` 整个输入是一个词、
//! `首` 句首词（只用掉输入的开头）、`原` 原始串/英文。

use std::sync::Arc;

use wotype_core::lm::BigramLm;
use wotype_core::{Engine, EngineConfig, Lexicon, MemoryLexicon};

fn fail(msg: &str) -> ! {
    eprintln!("{msg}");
    std::process::exit(1);
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mut lexicon_path = String::new();
    let mut english_path = String::new();
    let mut mixed_path = String::new();
    // 复现用户机器上的结果：语法模型、模糊音、用户词库、输入习惯
    let mut lm_path = String::new();
    let mut user_dict = String::new();
    let mut history = String::new();
    let mut fuzzy = false;
    let mut fuzzy_rules = String::new();
    // 调参用：模糊音扣分、束宽（不给就用默认值）
    let mut fuzzy_penalty: Option<f64> = None;
    let mut beam_size: Option<usize> = None;
    let mut context = String::new();
    let mut max_candidates = 18usize;
    let mut scores = false;
    let mut inputs = Vec::new();
    let mut i = 1;
    while i < args.len() {
        let take = |i: &mut usize| -> String {
            *i += 1;
            args.get(*i).cloned().unwrap_or_default()
        };
        match args[i].as_str() {
            "--lexicon" => lexicon_path = take(&mut i),
            "--english" => english_path = take(&mut i),
            "--mixed" => mixed_path = take(&mut i),
            "--lm" => lm_path = take(&mut i),
            "--user-dict" => user_dict = take(&mut i),
            "--history" => history = take(&mut i),
            "--fuzzy" => fuzzy = true,
            // 照设置里的模糊音规则（config.json 的 wanxiangFuzzyRules），隐含 --fuzzy
            "--fuzzy-rules" => {
                fuzzy_rules = take(&mut i);
                fuzzy = true;
            }
            "--fuzzy-penalty" => fuzzy_penalty = take(&mut i).parse().ok(),
            "--beam" => beam_size = take(&mut i).parse().ok(),
            "--context" => context = take(&mut i),
            "--max" => max_candidates = take(&mut i).parse().unwrap_or(18),
            "--scores" => scores = true,
            "-h" | "--help" => {
                println!("wotype-show --lexicon <tsv> [--english <txt>] [--mixed <txt>] [--lm <模型>] [--fuzzy] [--fuzzy-rules <z=zh,n=l,...>] [--user-dict <tsv>] [--history <tsv>] [--max n] [--context 文本] [--scores] 拼音...");
                return;
            }
            other => inputs.push(other.to_string()),
        }
        i += 1;
    }
    if lexicon_path.is_empty() {
        fail("需要 --lexicon");
    }
    let lexicon = MemoryLexicon::from_tsv_path_cached(&lexicon_path)
        .unwrap_or_else(|e| fail(&format!("词库载入失败: {e:#}")));
    let lex: Arc<dyn Lexicon> = Arc::new(lexicon);
    let mut config = EngineConfig {
        max_candidates,
        ..EngineConfig::default()
    };
    if let Some(p) = fuzzy_penalty {
        config.fuzzy_penalty = p;
    }
    if let Some(b) = beam_size {
        config.beam.beam_size = b;
    }
    let lm = if lm_path.is_empty() {
        Arc::new(BigramLm::default())
    } else {
        wotype_core::lm::load_lm(&lm_path).unwrap_or_else(|e| fail(&format!("语言模型载入失败: {e:#}")))
    };
    let mut engine = Engine::new(lex, lm).with_config(config);
    if !fuzzy_rules.is_empty() {
        let ids: Vec<&str> = fuzzy_rules.split(',').filter(|s| !s.is_empty()).collect();
        wotype_core::syllable::set_fuzzy_rules(&ids);
    }
    engine.set_fuzzy(fuzzy);
    if !user_dict.is_empty() {
        engine
            .load_user_dict(&user_dict)
            .unwrap_or_else(|e| fail(&format!("用户词库载入失败: {e:#}")));
    }
    if !history.is_empty() {
        engine
            .load_history(&history)
            .unwrap_or_else(|e| fail(&format!("输入习惯载入失败: {e:#}")));
    }
    if !english_path.is_empty() {
        engine
            .load_english(&english_path)
            .unwrap_or_else(|e| fail(&format!("英文词表载入失败: {e:#}")));
    }
    if !mixed_path.is_empty() {
        engine
            .load_mixed(&mixed_path)
            .unwrap_or_else(|e| fail(&format!("混合编码词表载入失败: {e:#}")));
    }
    engine.set_context(&context);
    for input in &inputs {
        let candidates = engine.input(input);
        let line: Vec<String> = candidates
            .iter()
            .enumerate()
            .map(|(i, c)| {
                let kind = if c.consumed < input.len() {
                    "首"
                } else if c.words.len() == 1 && c.words[0].pinyin.is_empty() {
                    "原"
                } else if c.words.len() >= 2 {
                    "句"
                } else {
                    "词"
                };
                if scores {
                    format!("{}.{}{}({:.1})", i + 1, c.text, kind, c.score)
                } else {
                    format!("{}.{}{}", i + 1, c.text, kind)
                }
            })
            .collect();
        // 编辑区的分词和插件一样：按第一个用完整个输入的候选切
        let shown = candidates
            .iter()
            .find(|c| c.consumed >= input.len())
            .and_then(|c| wotype_core::preedit::segment_input(input, &c.pinyin))
            .unwrap_or_else(|| input.clone());
        println!("{input} [{shown}]: {}", line.join(" "));
    }
}
