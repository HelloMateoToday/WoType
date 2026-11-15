//! 排序修正的用例：照上游 Gloridust/WowType 的单元测试改写（上游在 `core/src/lib.rs` 里，
//! 这里放进 tests/，用内嵌的小词库，不必 `--lib` 重编整个库）。
//!
//! 每个用例注明来自上游哪个 PR / 提交（engine/UPSTREAM.md 记移植情况）。

use std::sync::Arc;

use wotype_core::lm::BigramLm;
use wotype_core::session::{self, Key, Mode, Session, SessionConfig};
use wotype_core::{Engine, EngineConfig, Lexicon, MemoryLexicon};

fn engine(tsv: &str) -> Engine {
    let lexicon: Arc<dyn Lexicon> = Arc::new(MemoryLexicon::from_tsv_str(tsv).unwrap());
    Engine::new(lexicon, Arc::new(BigramLm::default()))
}

fn texts(e: &Engine, input: &str) -> Vec<String> {
    e.input(input).into_iter().map(|c| c.text).collect()
}

// ---------------------------------------------------------------------------
// #147（dd49547）：第一个中文候选是几个词硬凑的整句时，英文词排第一

#[test]
fn english_word_beats_chinese_sentence_made_of_abbreviations() {
    // ok -> 哦 | 可（o + k）是两个词硬凑的；bug -> 不过（bu + g）是一个词还没打完
    let e = engine("o\t哦\t900000\nke\t可\t900000\nbu guo\t不过\t500000\nbu\t不\t1000000\n");
    e.load_english_str("ok\nbug\n");
    let ok = texts(&e, "ok");
    assert_eq!(ok.first().map(String::as_str), Some("ok"), "{ok:?}");
    let bug = texts(&e, "bug");
    assert_eq!(bug.first().map(String::as_str), Some("不过"), "{bug:?}");
    assert_eq!(bug.get(1).map(String::as_str), Some("bug"), "{bug:?}");
}

// ---------------------------------------------------------------------------
// #165（92ce495）：只打一个声母时常用字固定排第一

#[test]
fn single_initial_pins_the_common_char_first() {
    // 只打 l，词频更高的「来」「里」不能排在「了」前面；选过别的字也不换掉第一个
    let e = engine(concat!(
        "lai\t来\t14837007\n",
        "li\t里\t7329328\n",
        "le\t了\t3481243\n",
        "liao\t了\t999\n",
        "ba\t把\t3798288\n",
        "bu\t不\t2985809\n",
        "fa\t发\t3000000\n",
        "fang\t放\t4000000\n",
    ));
    assert_eq!(texts(&e, "l")[0], "了", "{:?}", texts(&e, "l"));
    assert_eq!(texts(&e, "b")[0], "不", "{:?}", texts(&e, "b"));
    // 没列的声母照词频
    assert_eq!(texts(&e, "f")[0], "放", "{:?}", texts(&e, "f"));
    // 打全的拼音不受影响
    assert_eq!(texts(&e, "lai")[0], "来");
    for _ in 0..5 {
        e.record_selection("来");
    }
    let l = texts(&e, "l");
    assert_eq!(&l[..2], ["了", "来"], "选过的字排第二，第一个不变：{l:?}");
}

// ---------------------------------------------------------------------------
// #107（19eb3a0）：分几次选出来的词用一次就记住。
// 上游测的是 Engine::record_composed_word；本地还没有这个接口，从会话上模拟选词过程测，
// 移植前后都能编译。

/// 打 keys，再按顺序逐个选 picks 里的词（在全部候选里找，展开网格后点），返回上屏的文字。
fn compose(e: &Engine, keys: &str, picks: &[&str]) -> String {
    let mut s = Session::new();
    for c in keys.chars() {
        s.key(Some(e), Key::Char(c), 0);
    }
    let mut committed = String::new();
    for want in picks {
        if s.mode() == Mode::List {
            s.toggle_grid();
        }
        let mut found = false;
        for _ in 0..20 {
            if let Some(at) = s.shown().iter().position(|t| t == want) {
                assert!(s.select(Some(e), at), "选 {want} 失败");
                found = true;
                break;
            }
            s.key(Some(e), Key::PageDown, 0);
        }
        assert!(found, "{keys} 的候选里没有 {want}：{:?}", s.all_candidates());
        committed.push_str(&s.take_commit());
    }
    assert_eq!(s.mode(), Mode::Idle, "选完应当上屏");
    committed
}

fn composed_engine(config: EngineConfig) -> Engine {
    let lexicon: Arc<dyn Lexicon> = Arc::new(
        MemoryLexicon::from_tsv_str(
            "shuang\t双\t10000\nshuang\t霜\t500\npin\t拼\t8000\npin\t频\t500\n\
             ge\t个\t20000\nge\t阁\t300\nshuang pin\t双拼\t3000\n\
             wo\t我\t30000\nwo\t窝\t100\nte\t特\t5000\nte\t忑\t50\n",
        )
        .unwrap(),
    );
    let mut e = Engine::new(lexicon, Arc::new(BigramLm::default())).with_config(config);
    e.set_max_candidates(session::MAX_CANDIDATES);
    e
}

#[test]
fn composed_word_is_learned_on_first_use() {
    session::configure(SessionConfig::default());
    let e = composed_engine(EngineConfig::default());
    assert!(!texts(&e, "shuangpinge").iter().any(|t| t == "霜频阁"));
    assert_eq!(compose(&e, "shuangpinge", &["霜", "频", "阁"]), "霜频阁");
    assert!(
        e.user_words().iter().any(|(_, w, _)| w == "霜频阁"),
        "分三次选出来的词用一次就进用户词库：{:?}",
        e.user_words()
    );
    assert_eq!(texts(&e, "shuangpinge")[0], "霜频阁", "{:?}", texts(&e, "shuangpinge"));
}

#[test]
fn long_composed_sentence_still_needs_repeats() {
    // 先选句首词再选剩下的长句：不当造词，一次不进词库
    let e = engine("ni hao\t你好\t10000\n");
    e.record_composed_word("我今天去学校了", "wo jin tian qu xue xiao le");
    assert!(e.user_words().is_empty());
    e.record_composed_word("我今天去学校了", "wo jin tian qu xue xiao le");
    e.record_composed_word("我今天去学校了", "wo jin tian qu xue xiao le");
    assert_eq!(e.user_words().len(), 1);
}

#[test]
fn composed_word_respects_auto_learn_off() {
    session::configure(SessionConfig::default());
    let e = composed_engine(EngineConfig {
        auto_learn: false,
        ..EngineConfig::default()
    });
    assert_eq!(compose(&e, "wote", &["窝", "忑"]), "窝忑");
    assert!(e.user_words().is_empty(), "{:?}", e.user_words());
}

// ---------------------------------------------------------------------------
// #105（7cffc5c，依赖 932ffd2）：单独的 r、hm，qv/xv/yv/jv 也出候选

#[test]
fn single_letters_and_dead_syllables_still_give_candidates() {
    let e = engine(concat!(
        "ren\t人\t50000\n",
        "ri\t日\t30000\n",
        "hou mian\t后面\t20000\n",
        "hao ma\t好吗\t10000\n",
        "qu\t去\t80000\n",
        "xu yao\t需要\t40000\n",
        "yu\t与\t30000\n",
        "ju zi\t句子\t9000\n",
        "quan bu\t全部\t9000\n",
        "hua\t花\t9000\n",
        "lv\t绿\t9000\n",
        "lu\t路\t9000\n",
    ));
    let mut missing = Vec::new();
    for (raw, want) in [
        ("r", "人"),
        ("r", "日"),
        ("hm", "后面"),
        ("hm", "好吗"),
        ("qv", "去"),
        ("xvyao", "需要"),
        ("yv", "与"),
        ("jvzi", "句子"),
        ("qvanbu", "全部"),
        // 儿化照旧
        ("hua'r", "花"),
    ] {
        let got = texts(&e, raw);
        if !got.iter().any(|t| t == want) {
            missing.push(format!("{raw} 应有 {want}：{got:?}"));
        }
    }
    assert!(missing.is_empty(), "{}", missing.join("\n"));
    // lv 还是绿，不变成路
    assert_eq!(texts(&e, "lv").first().map(String::as_str), Some("绿"));
}

// ---------------------------------------------------------------------------
// #149（76d0644）：两键按反比按错一个键少罚；单字硬凑的第一名后面放纠一处错得到的词

#[test]
fn swapped_keys_beat_a_wrong_key() {
    // meiyuo：两键按反是「没有」，按错一个键（y 当 g）是「美国」；美国词频高一些，
    // 但打反比按错常见，没有排第一
    let e = engine("mei you\t没有\t500000\nmei guo\t美国\t900000\n");
    let got = texts(&e, "meiyuo");
    assert_eq!(got.first().map(String::as_str), Some("没有"), "{got:?}");
}

#[test]
fn one_typo_word_follows_a_sentence_of_single_characters() {
    // tianqu：第一名「天 | 去」是两个单字硬凑的，纠一处错（u 当 i）就是「天气」，排第二
    let e = engine("tian\t天\t100000\nqu\t去\t100000\ntian qi\t天气\t1000000\n");
    let got = texts(&e, "tianqu");
    assert_eq!(got.first().map(String::as_str), Some("天去"), "{got:?}");
    assert_eq!(got.get(1).map(String::as_str), Some("天气"), "{got:?}");
}

// ---------------------------------------------------------------------------
// #147（10291af + 7cf7c96）：打全一个音节时本音节的字排前面

#[test]
fn complete_syllable_keeps_its_own_characters_first() {
    // 「想」字频高得多，但 xian 已经打全了：本音节的字都排在补全出来的「想」前面；
    // 切成 xi'an 的整词「西安」分数差得不多，抬到第五个
    let mut tsv = String::from("xiang\t想\t50000000\nxi an\t西安\t400000\nxiao\t笑\t100\n");
    for (i, c) in "先现显线险仙咸鲜".chars().enumerate() {
        tsv.push_str(&format!("xian\t{c}\t{}\n", 1_000_000 - i * 100_000));
    }
    let e = engine(&tsv);
    let got = texts(&e, "xian");
    let at = |w: &str| got.iter().position(|t| t == w);
    assert_eq!(got.first().map(String::as_str), Some("先"), "{got:?}");
    assert!(at("鲜") < at("想"), "补全的字排到了本音节的字前面：{got:?}");
    assert_eq!(at("西安"), Some(4), "{got:?}");
    // 没打全时照样出补全
    assert!(texts(&e, "xia").iter().any(|t| t == "想"), "{:?}", texts(&e, "xia"));
}

// ---------------------------------------------------------------------------
// 模糊音选过的词只在当时打的拼音上往前提（用户 2026-11-15 的例子）：
// 打 lixian 选过「离线」，打 lixiang、nixiang 不该因为它选过就排第一；
// 打 yinshi 选过「硬是」（in=ing），下次打 yinshi 它排第一。
// 和纠错一样：选「提前」时打的是 tiqian，打 riqi 不该因为它选过就排到「日期」前面。

/// 用户开着的几条模糊音规则（模糊音规则是进程级的，这个文件里的用例都用同一组）。
const FUZZY_RULES: &[&str] = &["n=l", "in=ing", "ian=iang"];

fn fuzzy_engine() -> Engine {
    wotype_core::syllable::set_fuzzy_rules(FUZZY_RULES);
    let lexicon: Arc<dyn Lexicon> = Arc::new(
        MemoryLexicon::from_tsv_str(concat!(
            "li xiang\t理想\t50000\n",
            "ni xiang\t你想\t20000\n",
            "ni xiang\t逆向\t5000\n",
            "li xian\t离线\t3000\n",
            "ying shi\t影视\t40000\n",
            "ying shi\t硬是\t4000\n",
            "yin shi\t饮食\t30000\n",
        ))
        .unwrap(),
    );
    let mut e = Engine::new(lexicon, Arc::new(BigramLm::default()));
    e.set_fuzzy(true);
    e.set_max_candidates(session::MAX_CANDIDATES);
    e
}

#[test]
fn picked_word_is_not_carried_to_fuzzy_inputs() {
    session::configure(SessionConfig::default());
    let e = fuzzy_engine();
    assert_eq!(texts(&e, "lixiang")[0], "理想");
    assert_eq!(texts(&e, "nixiang")[0], "你想");
    // 打 lixian 选两次「离线」
    for _ in 0..2 {
        assert_eq!(compose(&e, "lixian", &["离线"]), "离线");
    }
    assert_eq!(texts(&e, "lixian")[0], "离线", "拼对的输入照旧往前提");
    let lixiang = texts(&e, "lixiang");
    assert_eq!(lixiang[0], "理想", "lixian 上选的「离线」串到了 lixiang：{lixiang:?}");
    let nixiang = texts(&e, "nixiang");
    assert_eq!(nixiang[0], "你想", "lixian 上选的「离线」串到了 nixiang：{nixiang:?}");
}

#[test]
fn fuzzy_pick_is_remembered_for_the_input_it_was_made_on() {
    session::configure(SessionConfig::default());
    let e = fuzzy_engine();
    assert_eq!(texts(&e, "yinshi")[0], "饮食");
    for _ in 0..2 {
        assert_eq!(compose(&e, "yinshi", &["硬是"]), "硬是");
    }
    let yinshi = texts(&e, "yinshi");
    assert_eq!(yinshi[0], "硬是", "在 yinshi 上选过的模糊音词，下次打 yinshi 排第一：{yinshi:?}");
}

#[test]
fn fuzzy_pick_survives_save_and_load() {
    session::configure(SessionConfig::default());
    let path = std::env::temp_dir().join(format!("wotype_fuzzy_pick_{}.tsv", std::process::id()));
    let _ = std::fs::remove_file(&path);
    {
        let e = fuzzy_engine();
        for _ in 0..2 {
            compose(&e, "yinshi", &["硬是"]);
            compose(&e, "lixian", &["离线"]);
        }
        e.save_history(&path).unwrap();
    }
    let e = fuzzy_engine();
    e.load_history(&path).unwrap();
    let _ = std::fs::remove_file(&path);
    assert_eq!(texts(&e, "yinshi")[0], "硬是", "{:?}", texts(&e, "yinshi"));
    assert_eq!(texts(&e, "lixian")[0], "离线", "{:?}", texts(&e, "lixian"));
    assert_eq!(texts(&e, "lixiang")[0], "理想", "{:?}", texts(&e, "lixiang"));
}
