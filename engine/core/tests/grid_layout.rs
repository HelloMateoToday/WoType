//! 展开的候选按宽度分行（固定 6 列，长词跨列，照水杉 macOS 宿主），↑↓ 走到上下一行同一列附近，数字键选这一行的。
//!
//! 量列数的函数是进程级的，放在单独的测试文件里（单独一个进程），不影响别的测试。

use std::sync::Arc;

use wotype_core::lm::BigramLm;
use wotype_core::session::{set_grid_span, Key, Session};
use wotype_core::{Engine, Lexicon, MemoryLexicon};

fn engine() -> Engine {
    // 前几个候选：一字词占 1 列，四字词占 3 列（下面的量法）
    let lexicon: Arc<dyn Lexicon> = Arc::new(
        MemoryLexicon::from_tsv_str(concat!(
            "shi\t是\t900000\n",
            "shi\t事\t800000\n",
            "shi\t十\t700000\n",
            "shi\t实事求是\t600000\n",
            "shi\t时\t500000\n",
            "shi\t市\t400000\n",
            "shi\t使\t300000\n",
            "shi\t世\t200000\n",
            "shi\t式\t100000\n",
            "shi\t试\t90000\n",
            "shi\t室\t80000\n",
        ))
        .unwrap(),
    );
    Engine::new(lexicon, Arc::new(BigramLm::default()))
}

fn field<'a>(json: &'a str, name: &str) -> &'a str {
    let start = json.find(&format!("\"{name}\":")).expect(name) + name.len() + 3;
    let end = start + json[start..].find(']').unwrap() + 1;
    &json[start..end]
}

#[test]
fn grid_rows_follow_spans() {
    // 四个字以上占 3 列，别的 1 列
    set_grid_span(Some(Box::new(|text: &str| if text.chars().count() >= 4 { 3 } else { 1 })));
    let e = engine();
    let mut s = Session::new();
    for c in "shi".chars() {
        s.key(Some(&e), Key::Char(c), 0);
    }
    assert!(s.toggle_grid(), "展开");
    let all = s.all_candidates();
    let long = all.iter().position(|t| t == "实事求是").expect("长词在候选里");
    let json = s.snapshot(true);
    let spans: Vec<usize> = field(&json, "spans")
        .trim_matches(|c| c == '[' || c == ']')
        .split(',')
        .map(|n| n.parse().unwrap())
        .collect();
    assert_eq!(spans[long], 3, "长词占 3 列：{json}");
    let rows: Vec<usize> = field(&json, "rows")
        .trim_matches(|c| c == '[' || c == ']')
        .split(',')
        .map(|n| n.parse().unwrap())
        .collect();
    // 每一行加起来不超过 6 列，行数和候选数对得上
    let mut at = 0;
    for &count in &rows {
        assert!(spans[at..at + count].iter().sum::<usize>() <= 6, "一行不超过 6 列：{json}");
        at += count;
    }
    assert_eq!(at, spans.len());
    assert!(rows[0] < 6, "有长词的那一行放不下 6 个：{rows:?}");

    // ↓ 到第二行、数字键选这一行的第 1 个
    s.key(Some(&e), Key::Down, 0);
    s.key(Some(&e), Key::Char('1'), 0);
    let committed = s.take_commit();
    assert_eq!(committed, all[rows[0]], "第二行的第一个：{all:?} {rows:?}");
    set_grid_span(None);
}
