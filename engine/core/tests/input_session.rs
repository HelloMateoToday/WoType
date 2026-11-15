//! 输入会话（`session.rs`）的按键测试。
//!
//! `demo_*` 用仓库自带的演示词库，每次都跑；`full_*` 对照 fcitx5 插件的
//! `key_harness.cpp`，要用完整词库：有 `WOTYPE_LEXICON` 或仓库根目录的 `data/lexicon.tsv`
//! （`scripts/make-data.sh` 生成）时才跑，没有就跳过。
//!
//! 会话的设置是进程级的，所以每个测试先拿 `LOCK`，一个一个跑。

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};

use wotype_core::lm::BigramLm;
use wotype_core::session::{self, mods, Key, Mode, Session, SessionConfig};
use wotype_core::{Engine, Lexicon, MemoryLexicon};

static LOCK: Mutex<()> = Mutex::new(());

fn lock() -> MutexGuard<'static, ()> {
    let guard = LOCK.lock().unwrap_or_else(|e| e.into_inner());
    session::configure(SessionConfig::default());
    guard
}

fn data_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../data")
}

fn grammar_path() -> Option<PathBuf> {
    let path = std::env::var_os("WOTYPE_GRAM")
        .map(PathBuf::from)
        .unwrap_or_else(|| data_dir().join("../sample/wanxiang-lts-zh-hans.gram"));
    path.exists().then_some(path)
}

fn demo_engine() -> Engine {
    let lexicon = MemoryLexicon::from_tsv_path(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("data/demo_lexicon.tsv"),
    )
    .unwrap();
    let lexicon: Arc<dyn Lexicon> = Arc::new(lexicon);
    let mut engine = Engine::new(lexicon, Arc::new(BigramLm::default()));
    engine.set_max_candidates(session::MAX_CANDIDATES);
    engine
}

/// 一个读音十个字，用来测翻页。
fn homophone_engine() -> Engine {
    let tsv: String = ["是", "事", "时", "十", "使", "市", "式", "世", "实", "师"]
        .iter()
        .enumerate()
        .map(|(i, w)| format!("shi\t{w}\t{}\n", 10000 - i * 100))
        .collect();
    let lexicon: Arc<dyn Lexicon> = Arc::new(MemoryLexicon::from_tsv_str(&tsv).unwrap());
    let mut engine = Engine::new(lexicon, Arc::new(BigramLm::default()));
    engine.set_max_candidates(session::MAX_CANDIDATES);
    engine
}

/// 完整词库的引擎，所有 full_* 测试共用一个（和插件一样，选词学习会互相影响）。
fn full_engine() -> Option<&'static Mutex<Engine>> {
    static ENGINE: OnceLock<Option<Mutex<Engine>>> = OnceLock::new();
    ENGINE
        .get_or_init(|| {
            let lexicon = std::env::var_os("WOTYPE_LEXICON")
                .map(PathBuf::from)
                .unwrap_or_else(|| data_dir().join("lexicon.tsv"));
            if !lexicon.exists() {
                eprintln!("没有完整词库 {}，跳过", lexicon.display());
                return None;
            }
            let lex: Arc<dyn Lexicon> =
                Arc::new(MemoryLexicon::from_tsv_path_cached(&lexicon).unwrap());
            // 有万象的语法模型（几百 MB，不在仓库里）就用它，和 App 一样；WOTYPE_GRAM 可指定路径
            let lm = match grammar_path() {
                Some(path) => wotype_core::lm::load_lm(&path).unwrap(),
                None => Arc::new(BigramLm::default()),
            };
            let mut engine = Engine::new(lex, lm);
            engine.set_max_candidates(session::MAX_CANDIDATES);
            if data_dir().join("english.txt").exists() {
                engine.load_english(data_dir().join("english.txt")).unwrap();
            }
            if data_dir().join("mixed.txt").exists() {
                engine.load_mixed(data_dir().join("mixed.txt")).unwrap();
            }
            // 最近用过的 emoji 写到临时文件，从空开始
            let recent = std::env::temp_dir()
                .join(format!("wotype_recent_emoji_{}.txt", std::process::id()));
            let _ = std::fs::remove_file(&recent);
            session::set_recent_emoji_path(Some(recent));
            Some(Mutex::new(engine))
        })
        .as_ref()
}

/// 模拟一个输入框：记下上屏的文字和交还给应用的字符。
struct Field {
    session: Session,
    committed: String,
    passed: String,
    /// 上屏的和交给应用的按先后拼在一起：输入框里最后看到的文字
    text: String,
}

impl Field {
    fn new() -> Self {
        Self {
            session: Session::new(),
            committed: String::new(),
            passed: String::new(),
            text: String::new(),
        }
    }

    fn send(&mut self, engine: Option<&Engine>, key: Key, modifiers: u32) -> bool {
        let handled = self.session.key(engine, key, modifiers);
        let commit = self.session.take_commit();
        self.committed.push_str(&commit);
        self.text.push_str(&commit);
        if !handled {
            let passed = match key {
                Key::Char(c) => Some(c),
                Key::Space => Some(' '),
                Key::Tab => Some('\t'),
                _ => None,
            };
            if let Some(c) = passed {
                self.passed.push(c);
                self.text.push(c);
            }
        }
        handled
    }

    /// 按一串键。<sp> <bs> <cr> <esc> <tab> <up> <down> <left> <right> <pgup> <pgdn> <home> <end> <del> 是功能键，
    /// <S-cr> 是 ⇧⏎，其余按字符。
    fn type_keys(&mut self, engine: Option<&Engine>, keys: &str) {
        let mut rest = keys;
        while let Some(c) = rest.chars().next() {
            if c == '<' {
                if let Some(end) = rest.find('>') {
                    let mut modifiers = 0;
                    let key = match &rest[1..end] {
                        "S-cr" => {
                            modifiers = mods::SHIFT;
                            Key::Return
                        }
                        "home" => Key::Home,
                        "end" => Key::End,
                        "del" => Key::Delete,
                        "sp" => Key::Space,
                        "bs" => Key::Backspace,
                        "cr" => Key::Return,
                        "esc" => Key::Escape,
                        "tab" => Key::Tab,
                        "up" => Key::Up,
                        "down" => Key::Down,
                        "left" => Key::Left,
                        "right" => Key::Right,
                        "pgup" => Key::PageUp,
                        "pgdn" => Key::PageDown,
                        other => panic!("不认识的键 <{other}>"),
                    };
                    self.send(engine, key, modifiers);
                    rest = &rest[end + 1..];
                    continue;
                }
            }
            let modifiers = if c.is_ascii_uppercase() {
                mods::SHIFT
            } else {
                0
            };
            self.send(engine, Key::Char(c), modifiers);
            rest = &rest[c.len_utf8()..];
        }
    }

    /// 每个用例前清空编辑区和记录。
    fn fresh(&mut self, engine: Option<&Engine>) {
        self.session.reset(engine, false);
        self.session.take_commit();
        self.committed.clear();
        self.passed.clear();
        self.text.clear();
    }

    /// 全部候选
    fn all(&self) -> Vec<String> {
        self.session.all_candidates()
    }

    fn preedit(&self) -> String {
        self.session.preedit()
    }

    fn page(&self) -> Vec<String> {
        if self.session.mode() == Mode::Idle {
            return Vec::new();
        }
        self.session.shown()
    }
}

// MARK: 演示词库

#[test]
fn demo_space_commits_first_candidate() {
    let _guard = lock();
    let engine = demo_engine();
    let mut f = Field::new();
    f.type_keys(Some(&engine), "nihao");
    assert_eq!(f.preedit(), "ni'hao");
    assert_eq!(f.page().first().map(String::as_str), Some("你好"));
    f.type_keys(Some(&engine), "<sp>");
    assert_eq!(f.committed, "你好");
    assert_eq!(f.session.mode(), Mode::Idle);
}

#[test]
fn demo_return_backspace_escape() {
    let _guard = lock();
    let engine = demo_engine();
    let mut f = Field::new();
    f.type_keys(Some(&engine), "nihao<cr>");
    assert_eq!(f.committed, "nihao", "回车上屏原始字母");

    f.fresh(Some(&engine));
    f.type_keys(Some(&engine), "ni<bs><bs>");
    assert!(
        f.preedit().is_empty() && f.page().is_empty(),
        "退格删光后编辑区关闭"
    );
    f.type_keys(Some(&engine), "<bs>");
    assert!(
        f.committed.is_empty() && f.passed.is_empty(),
        "空编辑区的退格交给应用"
    );

    f.fresh(Some(&engine));
    f.type_keys(Some(&engine), "nihao<esc>");
    assert!(
        f.committed.is_empty() && f.preedit().is_empty(),
        "Esc 清空不上屏"
    );
}

#[test]
fn demo_ascii_punct_after_digits() {
    let _guard = lock();
    let engine = demo_engine();
    let e = Some(&engine);
    let mut f = Field::new();
    f.type_keys(e, "3.14");
    assert!(
        f.committed.is_empty() && f.passed == "3.14",
        "数字后的句号原样输出：{}",
        f.passed
    );

    f.fresh(e);
    f.type_keys(e, "1.2.3 12:30");
    assert_eq!(f.passed, "1.2.3 12:30", "版本号、时间");
    assert!(!f.committed.contains('。') && !f.committed.contains('：'));

    f.fresh(e);
    f.type_keys(e, "3,");
    assert_eq!(f.committed, "，", "逗号照常转中文：「第 3，」");

    f.fresh(e);
    f.type_keys(e, "3 .");
    assert_eq!(f.committed, "。", "数字和句号之间隔了别的键：照常转中文");

    f.fresh(e);
    f.type_keys(e, "nihao<sp>.");
    assert_eq!(f.committed, "你好。", "上屏后按句号不受影响（打拼音途中按 . 是原样输入，见 demo_raw_input_for_urls）");

    // 鼠标点到数字后面（上一个键不是数字，但光标前是数字）→ 原样
    f.fresh(e);
    f.session.set_context("价格是3");
    f.type_keys(e, ".");
    assert_eq!(f.passed, ".", "光标前是数字");
    // 上一个键是数字，但应用给的光标前文字对不上（终端就是这样）→ 仍然原样
    f.fresh(e);
    f.type_keys(e, "3");
    f.session.set_context("➜ ~");
    f.type_keys(e, ".");
    assert_eq!(
        f.passed, "3.",
        "终端：应用给的上文不可靠，上一个键是数字就算"
    );
    // 切走输入框后不再算「刚打过数字」
    f.fresh(e);
    f.type_keys(e, "3");
    f.session.reset(e, false);
    f.type_keys(e, ".");
    assert_eq!(f.committed, "。", "换了输入框");

    // 关掉这项设置
    session::configure(SessionConfig {
        ascii_punct_after_digit: false,
        ..SessionConfig::default()
    });
    f.fresh(e);
    f.type_keys(e, "3.");
    assert_eq!(f.committed, "。", "关掉后照常转中文句号");
    session::configure(SessionConfig::default());
}

#[test]
fn demo_digits_and_punctuation() {
    let _guard = lock();
    let engine = demo_engine();
    let mut f = Field::new();
    f.type_keys(Some(&engine), "1");
    assert!(
        f.committed.is_empty() && f.passed == "1",
        "空编辑区数字交给应用"
    );

    f.fresh(Some(&engine));
    f.type_keys(Some(&engine), ",");
    assert_eq!(f.committed, "，", "空编辑区逗号转中文逗号");

    f.fresh(Some(&engine));
    f.type_keys(Some(&engine), "nihao,");
    assert_eq!(f.committed, "你好，", "打字途中按逗号：先上屏再出中文逗号");

    f.fresh(Some(&engine));
    f.type_keys(Some(&engine), "nihao/");
    assert_eq!(f.committed, "你好、", "/ 输入顿号");
    assert!(f.passed.is_empty());

    f.fresh(Some(&engine));
    f.type_keys(Some(&engine), "/");
    assert_eq!(f.committed, "、", "空编辑区的 / 也是顿号");

    f.fresh(Some(&engine));
    f.type_keys(Some(&engine), "2024/1");
    assert_eq!(f.passed, "2024/1", "数字后的 / 原样输出");

    session::configure(SessionConfig {
        slash_dunhao: false,
        ..SessionConfig::default()
    });
    f.fresh(Some(&engine));
    f.type_keys(Some(&engine), "nihao/");
    assert_eq!(f.committed, "你好/", "关掉后 / 原样上屏");
    f.fresh(Some(&engine));
    f.type_keys(Some(&engine), "/");
    assert_eq!(f.passed, "/", "关掉后空编辑区的 / 交给应用");
    session::configure(SessionConfig::default());
}

#[test]
fn demo_modifiers_and_caps_lock() {
    let _guard = lock();
    let engine = demo_engine();
    let mut f = Field::new();
    assert!(
        !f.send(Some(&engine), Key::Char('c'), mods::COMMAND),
        "⌘C 交给应用"
    );
    assert!(
        !f.send(Some(&engine), Key::Char('a'), mods::OPTION),
        "⌥ 加字母交给应用"
    );
    assert!(
        !f.send(Some(&engine), Key::Char('A'), mods::CAPS_LOCK),
        "大写锁定、没在输入时字母交给应用"
    );

    f.fresh(Some(&engine));
    f.type_keys(Some(&engine), "nihao");
    assert!(
        !f.send(Some(&engine), Key::Char('v'), mods::COMMAND),
        "打字途中 ⌘V 也交给应用"
    );
    assert_eq!(f.preedit(), "ni'hao", "编辑区不动");
    assert!(f.send(Some(&engine), Key::Char('A'), mods::CAPS_LOCK));
    assert_eq!(f.committed, "你好A", "打字途中打开大写锁定：先上屏再出字母");
}

#[test]
fn demo_reset_commits_or_drops_pending_input() {
    let _guard = lock();
    let engine = demo_engine();
    let mut f = Field::new();
    f.type_keys(Some(&engine), "nihao");
    f.session.reset(Some(&engine), true);
    assert_eq!(
        f.session.take_commit(),
        "nihao",
        "切英文或切输入法：打了一半的字母上屏"
    );

    f.type_keys(Some(&engine), "nihao");
    f.session.reset(Some(&engine), false);
    assert!(
        f.session.take_commit().is_empty() && f.preedit().is_empty(),
        "失去焦点：不上屏、编辑区清空"
    );
}

#[test]
fn demo_typing_works_before_engine_is_loaded() {
    let _guard = lock();
    let mut f = Field::new();
    f.type_keys(None, "nihao");
    assert_eq!(f.preedit(), "nihao");
    assert!(f.page().is_empty());
    f.type_keys(None, "<sp>");
    assert_eq!(f.committed, "nihao", "没有候选时空格上屏原始字母");
}

#[test]
fn demo_sentence_head_selection() {
    let _guard = lock();
    let engine = demo_engine();
    let mut f = Field::new();
    f.type_keys(Some(&engine), "nihaozhongguo");
    let page = f.page();
    let head = page
        .iter()
        .position(|t| t == "你好")
        .expect("第一页有句首词 你好");
    f.type_keys(Some(&engine), &(head + 1).to_string());
    assert!(f.committed.is_empty(), "选句首词不上屏");
    assert_eq!(f.preedit(), "你好zhong'guo");
    f.type_keys(Some(&engine), "<bs><bs><bs><bs><bs><bs><bs><bs>");
    assert_eq!(f.preedit(), "你好", "删完剩余拼音");
    f.type_keys(Some(&engine), "<bs>");
    assert_eq!(f.preedit(), "ni'hao", "再退格撤销选词");
}

#[test]
fn demo_snapshot_is_valid_json_shape() {
    let _guard = lock();
    let engine = demo_engine();
    let mut s = Session::new();
    s.key(Some(&engine), Key::Char('n'), 0);
    s.key(Some(&engine), Key::Char('i'), 0);
    let json = s.snapshot(true);
    assert!(
        json.starts_with("{\"handled\":true,\"commit\":\"\",\"learned\":0,\"mode\":\"list\""),
        "{json}"
    );
    assert!(json.contains("\"remaining\":\"ni\""), "{json}");
    assert!(json.contains("{\"text\":\"你\",\"emoji\":false,\"whole\":true}"), "{json}");
    s.key(Some(&engine), Key::Space, 0);
    let json = s.snapshot(true);
    assert!(
        json.contains("\"commit\":\"你\"")
            && json.contains("\"learned\":1")
            && json.contains("\"mode\":\"idle\""),
        "{json}"
    );
    assert!(
        s.snapshot(false).contains("\"commit\":\"\""),
        "上屏文字只给一次"
    );
}

#[test]
fn demo_paging_and_cursor() {
    let _guard = lock();
    session::configure(SessionConfig {
        page_size: 3,
        ..SessionConfig::default()
    });
    let engine = homophone_engine();
    let mut f = Field::new();
    f.type_keys(Some(&engine), "shi");
    let all = f.session.all_candidates();
    assert!(all.len() > 3, "shi 的候选要多于一页：{all:?}");
    let first = f.page();
    assert_eq!(first.len(), 3);
    f.type_keys(Some(&engine), "<pgdn>");
    assert_eq!(f.session.mode(), Mode::Grid, "翻页展开成网格（照系统拼音、微信输入法）");
    f.type_keys(Some(&engine), "<sp>");
    assert_eq!(f.committed, all[3], "光标在下一页的第一个");

    // 这一页最后一个再按右键：也展开，光标到下一个
    f.fresh(Some(&engine));
    f.type_keys(Some(&engine), "shi<right><right>");
    assert_eq!(f.session.mode(), Mode::List, "这一页里右移照常");
    f.type_keys(Some(&engine), "<right>");
    assert_eq!(f.session.mode(), Mode::Grid, "走过这一页最后一个就展开");
    let all = f.session.all_candidates();
    f.type_keys(Some(&engine), "<sp>");
    assert_eq!(f.committed, all[3]);

    // + = 一样，按着 Shift 也能翻页
    f.fresh(Some(&engine));
    f.type_keys(Some(&engine), "shi+");
    assert_eq!(f.session.mode(), Mode::Grid, "+ 翻页（展开），不当成符号上屏");
    assert!(f.committed.is_empty());

    // 选过词后排序会变（学习），重新取当前这一页
    f.fresh(Some(&engine));
    f.type_keys(Some(&engine), "shi");
    let now = f.page();
    f.type_keys(Some(&engine), "<right><sp>");
    assert_eq!(f.committed, now[1], "右移光标后空格选第二个");
    session::configure(SessionConfig::default());
}

#[test]
fn demo_mouse_select_and_page_api() {
    let _guard = lock();
    session::configure(SessionConfig {
        page_size: 3,
        ..SessionConfig::default()
    });
    let engine = homophone_engine();
    let mut s = Session::new();
    for c in "shi".chars() {
        s.key(Some(&engine), Key::Char(c), 0);
    }
    let all = s.all_candidates();
    assert!(!s.page(-1), "第一页没有上一页");
    assert!(s.page(1));
    assert!(s.select(Some(&engine), 0));
    assert_eq!(s.take_commit(), all[3], "鼠标点第二页的第一个");
    session::configure(SessionConfig::default());
}

/// 快照里光标在编辑区的位置；在末尾时没有这个字段。
fn snapshot_caret(s: &mut Session) -> Option<usize> {
    let json = s.snapshot(true);
    let at = json.find("\"caret\":")? + "\"caret\":".len();
    json[at..].split(',').next()?.parse().ok()
}

#[test]
fn demo_caret_moves_by_syllable() {
    let _guard = lock();
    let engine = demo_engine();
    let e = Some(&engine);
    let mut f = Field::new();
    f.type_keys(e, "nihaozhongguo");
    assert_eq!(f.preedit(), "ni'hao'zhong'guo");
    assert_eq!(snapshot_caret(&mut f.session), None);

    f.type_keys(e, "<left><left>");
    assert_eq!(f.preedit(), "ni'haozhong'guo", "光标处不加分隔符：ni'hao|zhong'guo");
    assert_eq!(snapshot_caret(&mut f.session), Some(6));
    assert_eq!(f.page().first().map(String::as_str), Some("你好"), "候选只查光标前那段");

    f.type_keys(e, "<left>");
    assert_eq!(f.page().first().map(String::as_str), Some("你"));
    f.type_keys(e, "<left>");
    assert_eq!(snapshot_caret(&mut f.session), Some(2), "光标前至少留一个音节");
    f.type_keys(e, "<right>");
    assert_eq!(snapshot_caret(&mut f.session), Some(6));

    f.type_keys(e, "<sp>");
    assert!(f.committed.is_empty(), "光标后还有拼音，选词不上屏");
    assert_eq!(f.preedit(), "你好zhong'guo");
    assert_eq!(snapshot_caret(&mut f.session), None, "选到光标处，光标回到末尾");
    f.type_keys(e, "<sp>");
    assert_eq!(f.committed, "你好中国");

    // 高亮不在首选时 ← → 只移候选
    f.fresh(e);
    f.type_keys(e, "nihao<right><left>");
    assert_eq!(snapshot_caret(&mut f.session), None, "← 先把高亮移回首选");
    f.type_keys(e, "<left>");
    assert_eq!(snapshot_caret(&mut f.session), Some(2));
    f.type_keys(e, "<right><right>");
    assert_eq!(f.page().first().map(String::as_str), Some("你好"), "→ 回到末尾再按就移高亮");
    assert!(f.session.snapshot(true).contains("\"cursor\":1"));

    // 单个音节没处可移
    f.fresh(e);
    f.type_keys(e, "ni<left>");
    assert_eq!(snapshot_caret(&mut f.session), None);
}

#[test]
fn demo_caret_editing() {
    let _guard = lock();
    let engine = demo_engine();
    let e = Some(&engine);
    let mut f = Field::new();
    f.type_keys(e, "nihaozhongguo<left><left><bs>");
    assert_eq!(f.preedit().replace('\'', ""), "nihazhongguo", "退格删光标前的字母");
    assert!(snapshot_caret(&mut f.session).is_some(), "光标还在中间");
    f.type_keys(e, "o");
    assert_eq!(f.page().first().map(String::as_str), Some("你好"), "字母插在光标处");
    f.type_keys(e, "<cr>");
    assert_eq!(f.committed, "nihaozhongguo", "回车照样上屏全部字母");
}

#[test]
fn demo_shift_return_tab_home_end_delete() {
    // 照水杉：⇧⏎ 原样上屏不学、Tab 先上屏再交给应用、Home / End / Delete（docs/17 A1～A3）
    let _guard = lock();
    let engine = demo_engine();
    let e = Some(&engine);
    let mut f = Field::new();

    // A1：分段选过的句首词也撤掉
    let before = engine.history_count("你好");
    f.type_keys(e, "nihaozhongguo<left><left><sp>");
    assert_eq!(engine.history_count("你好"), before + 1, "句首词选的时候就记了");
    f.type_keys(e, "<S-cr>");
    assert_eq!(f.committed, "你好zhongguo", "和回车一样上屏");
    assert_eq!(engine.history_count("你好"), before, "⇧⏎ 不学");
    assert_eq!(f.session.mode(), Mode::Idle);

    // A2
    f.fresh(e);
    f.type_keys(e, "nihao<tab>");
    assert_eq!(f.text, "nihao\t", "先上屏原样字母，Tab 交给应用");
    assert_eq!(f.session.mode(), Mode::Idle);
    f.fresh(e);
    f.type_keys(e, "nihao.com<tab>");
    assert_eq!(f.text, "nihao.com\t", "原样输入时也一样");
    f.fresh(e);
    f.type_keys(e, "nihao<down><tab>");
    assert_eq!(f.text, "nihao\t", "展开着先收起");

    // A3：Home 先回第一个候选，再按光标到第一个音节后面；End 到这一页最后一个
    f.fresh(e);
    f.type_keys(e, "nihaozhongguo<right><right><home>");
    assert!(f.session.snapshot(true).contains("\"cursor\":0"));
    assert_eq!(snapshot_caret(&mut f.session), None, "第一下只移高亮");
    f.type_keys(e, "<home>");
    assert_eq!(snapshot_caret(&mut f.session), Some(2), "ni|hao'zhong'guo");
    assert_eq!(f.page().first().map(String::as_str), Some("你"));
    f.type_keys(e, "<end>");
    let last = f.page().len() - 1;
    assert!(f.session.snapshot(true).contains(&format!("\"cursor\":{last}")), "到这一页最后一个");
    assert_eq!(snapshot_caret(&mut f.session), Some(2), "End 不动光标");

    // Delete：删光标后的字母；在末尾没反应
    f.fresh(e);
    f.type_keys(e, "nihaozhongguo<left><left><del>");
    assert_eq!(f.preedit().replace('\'', ""), "nihaohongguo");
    assert!(snapshot_caret(&mut f.session).is_some(), "光标还在中间");
    f.fresh(e);
    f.type_keys(e, "nihao<del>");
    assert_eq!(f.preedit(), "ni'hao");
    assert!(f.committed.is_empty());
}

#[test]
fn demo_date_time_candidates() {
    // 照微信输入法：riqi / rq、shijian / sj 时出一个带日历图标的候选，选它竖排展开各种格式
    let _guard = lock();
    let engine = demo_engine();
    let e = Some(&engine);
    let mut f = Field::new();

    f.type_keys(e, "riqi");
    assert!(!f.all().iter().any(|t| t == "日期" && f.session.snapshot(true).contains("calendar")), "没给格式时不出");
    session::set_date_formats(Some(Box::new(|kind| match kind {
        session::DateKind::Date => vec!["2026年11月13日".into(), "2026-11-13".into()],
        session::DateKind::Time => vec!["10:32:09".into()],
    })));

    f.fresh(e);
    f.type_keys(e, "riqi");
    let json = f.session.snapshot(true);
    assert!(json.contains("\"icon\":\"calendar\""), "带日历图标：{json}");
    let all = f.all();
    let at = all.iter().rposition(|t| t == "日期").expect("有「日期」");
    let word = all[..at].iter().position(|t| t == "日期");
    assert_eq!(at, word.map_or(1, |w| w + 1), "排在同名的词后面，没有就排第二：{all:?}");
    f.type_keys(e, &(at + 1).to_string());
    assert!(f.committed.is_empty(), "选它不上屏");
    assert_eq!(f.all(), ["2026年11月13日", "2026-11-13"], "换成各种格式");
    assert_eq!(f.preedit(), "ri'qi", "编辑区照旧分好音节");
    let json = f.session.snapshot(true);
    assert!(json.contains("\"horizontal\":false"), "竖排：{json}");
    f.type_keys(e, "<down><sp>");
    assert_eq!(f.committed, "2026-11-13", "↓ 选、空格上屏");

    // 退格回到拼音的候选；数字键直接上屏；Esc 清空
    f.fresh(e);
    f.type_keys(e, "riqi");
    let at = f.all().iter().rposition(|t| t == "日期").unwrap();
    f.type_keys(e, &(at + 1).to_string());
    f.type_keys(e, "<bs>");
    let json = f.session.snapshot(true);
    assert!(json.contains("calendar") && json.contains("\"horizontal\":true"), "回到拼音的候选：{json}");
    f.fresh(e);
    f.type_keys(e, "riqi");
    f.type_keys(e, &(at + 1).to_string());
    f.type_keys(e, "1");
    assert_eq!(f.committed, "2026年11月13日");
    f.fresh(e);
    f.type_keys(e, "riqi");
    f.type_keys(e, &(at + 1).to_string());
    f.type_keys(e, "<esc>");
    assert!(f.committed.is_empty() && f.session.mode() == Mode::Idle);

    // 首字母、时间也一样；别的拼音不出
    for (keys, label) in [("rq", "日期"), ("shijian", "时间"), ("sj", "时间")] {
        f.fresh(e);
        f.type_keys(e, keys);
        assert!(f.session.snapshot(true).contains("calendar"), "{keys}");
        assert!(f.all().contains(&label.to_string()), "{keys}");
    }
    f.fresh(e);
    f.type_keys(e, "nihao");
    assert!(!f.session.snapshot(true).contains("calendar"));
    session::set_date_formats(None);
}

// MARK: 完整词库（对照 key_harness.cpp）

macro_rules! full {
    () => {{
        let Some(engine) = full_engine() else { return };
        engine.lock().unwrap_or_else(|e| e.into_inner())
    }};
}

#[test]
fn full_basic_typing() {
    let _guard = lock();
    let engine = full!();
    let e = Some(&*engine);
    let mut f = Field::new();
    let cases = [
        ("nihao<sp>", "你好", "nihao 空格"),
        ("nihao,", "你好，", "打字途中按逗号"),
        ("zhognguo<sp>", "中国", "按反纠错"),
        ("nihao<cr>", "nihao", "回车上屏原始字母"),
        ("Hello<sp>", "Hello", "大写保留"),
        ("zhongdi<sp>", "种地", "打全了的拼音正好是一个词时排第一"),
        ("ka<sp>", "卡", "单音节"),
        ("/jixu<sp>", "、继续", "/ 是顿号，jixu 照常打"),
        ("nihao/", "你好、", "打字途中按 /"),
    ];
    for (keys, want, what) in cases {
        f.fresh(e);
        f.type_keys(e, keys);
        assert_eq!(f.committed, want, "{what}");
    }
    if data_dir().join("english.txt").exists() {
        f.fresh(e);
        f.type_keys(e, "github<sp>");
        assert_eq!(f.committed, "GitHub", "英文词");
    }
}

#[test]
fn full_first_page_shape() {
    let _guard = lock();
    let engine = full!();
    let e = Some(&*engine);
    let mut f = Field::new();

    f.type_keys(e, "dan");
    let dan = f.page();
    assert!(
        !dan.is_empty() && !dan.contains(&"大".to_string()),
        "单音节不出拆开音节的句首词：{dan:?}"
    );

    // 长句第一页不能全是只差最后一个字的整句，要有词和单字。
    // （首选是哪句看词库和语法模型，这里不管）
    f.fresh(e);
    f.type_keys(e, "hengxianghouxuanci");
    let heng = f.page();
    let first: Vec<char> = heng[0].chars().collect();
    let tail_variants = heng
        .iter()
        .filter(|t| {
            let chars: Vec<char> = t.chars().collect();
            chars.len() == first.len() && chars[..chars.len() - 1] == first[..first.len() - 1]
        })
        .count();
    assert!(
        tail_variants == 1
            && heng.contains(&"横向".to_string())
            && heng.contains(&"横".to_string()),
        "{heng:?}"
    );

    for (keys, want) in [("kyi", "可以"), ("yongzwen", "用中文")] {
        f.fresh(e);
        f.type_keys(e, keys);
        assert_eq!(f.page().first().map(String::as_str), Some(want), "{keys}");
    }

    f.fresh(e);
    f.type_keys(e, "hengxiang");
    assert_eq!(f.preedit(), "heng'xiang", "编辑区分音节");
    f.type_keys(e, "<cr>");
    assert_eq!(f.committed, "hengxiang", "回车上屏原始字母（不带隔音符）");
    f.fresh(e);
    f.type_keys(e, "zhongg");
    assert_eq!(f.preedit(), "zhong'g", "打了一半也分");
}

#[test]
fn full_sentence_head_then_rest() {
    let _guard = lock();
    let engine = full!();
    let e = Some(&*engine);
    let mut f = Field::new();
    f.type_keys(e, "nihaozhongguo");
    let head = f
        .page()
        .iter()
        .position(|t| t == "你好")
        .expect("第一页有句首词 你好");
    f.type_keys(e, &(head + 1).to_string());
    assert!(f.committed.is_empty());
    assert_eq!(f.preedit(), "你好zhong'guo");
    f.type_keys(e, "<bs><bs><bs><bs><bs><bs><bs><bs>");
    assert_eq!(f.preedit(), "你好");
    f.type_keys(e, "<bs>");
    assert_eq!(f.preedit(), "ni'hao");
    f.type_keys(e, "zhongguo");
    let head = f
        .page()
        .iter()
        .position(|t| t == "你好")
        .expect("还能选到 你好");
    f.type_keys(e, &(head + 1).to_string());
    f.type_keys(e, "<sp>");
    assert_eq!(f.committed, "你好中国", "选完开头再选剩下的，整句上屏");
}

#[test]
fn full_paging_and_grid() {
    let _guard = lock();
    let engine = full!();
    let e = Some(&*engine);
    let mut f = Field::new();

    f.type_keys(e, "shi");
    let first = f.page();
    let all = f.session.all_candidates();
    f.type_keys(e, "<pgdn>");
    assert_eq!(f.session.mode(), Mode::Grid, "翻页展开成网格");
    f.type_keys(e, "<sp>");
    assert_eq!(f.committed, all[first.len()], "光标在下一页的第一个");

    // 下键展开成 6 列的网格，光标在第一个
    f.fresh(e);
    f.type_keys(e, "shi");
    let first_page = f.page();
    assert!(first_page.len() >= 8);
    f.type_keys(e, "<down>");
    assert_eq!(f.session.mode(), Mode::Grid);
    let grid = f.page();
    assert_eq!(&grid[..6], &first_page[..6], "网格第一行是前 6 个");
    assert!(f
        .session
        .snapshot(true)
        .contains("\"columns\":6,\"first\":0,\"cursor\":0"));
    f.type_keys(e, "<right><right><sp>");
    assert_eq!(f.committed, first_page[2], "展开后右移两格空格选第三个");

    // 选过词后排序会变（学习、上文），每次按之前重新取当前这一页
    f.fresh(e);
    f.type_keys(e, "shi");
    let now = f.page();
    f.type_keys(e, "<down><down><sp>");
    assert_eq!(f.committed, now[6], "展开后下移一行空格选第七个");
    f.fresh(e);
    f.type_keys(e, "shi");
    let now = f.session.all_candidates();
    f.type_keys(e, "<down><down>2");
    assert_eq!(f.committed, now[7], "展开后数字选光标所在行");

    f.fresh(e);
    f.type_keys(e, "shi<down><down><up><up>");
    assert_eq!(f.session.mode(), Mode::List, "展开后在第一行按上键收起");
    f.fresh(e);
    f.type_keys(e, "shi<down><esc>");
    assert!(
        f.session.mode() == Mode::List && f.preedit() == "shi",
        "展开后 Esc 只收起，不清空输入"
    );
    f.type_keys(e, "<down>j");
    assert!(
        f.session.mode() == Mode::List && f.preedit() == "shi'j",
        "展开后接着打字：收起并照常输入，实际 {}",
        f.preedit()
    );

    f.fresh(e);
    f.type_keys(e, "shi<right>");
    let list = f.page();
    f.type_keys(e, "<sp>");
    assert_eq!(f.committed, list[1], "右移光标后空格选第二个");
}

#[test]
fn full_context_survives_many_commits() {
    let _guard = lock();
    let engine = full!();
    let e = Some(&*engine);
    let mut f = Field::new();
    for _ in 0..30 {
        f.type_keys(e, "zhongguo<sp>");
    }
    f.type_keys(e, "renmin<sp>");
    assert!(
        f.committed.len() > 30 * 6,
        "连续上屏 31 次，上下文按 UTF-8 截断不出错"
    );
}

#[test]
fn full_emoji_suggestions() {
    let _guard = lock();
    let engine = full!();
    let e = Some(&*engine);
    let mut f = Field::new();
    f.type_keys(e, "kaixin");
    let kaixin = f.page();
    assert!(
        kaixin.len() > 2 && kaixin[0] == "开心" && kaixin[2] == "😊",
        "{kaixin:?}"
    );
    f.type_keys(e, "3");
    assert_eq!(f.committed, "😊", "选 emoji 只上屏 emoji");

    f.fresh(e);
    f.type_keys(e, "jintianhaokaixin");
    let sentence = f.page();
    let at = sentence
        .iter()
        .position(|t| t == "开心😊")
        .expect("句尾是开心时推荐「开心😊」");
    f.type_keys(e, &(at + 1).to_string());
    assert_eq!(
        f.committed,
        format!("{}😊", sentence[0]),
        "句尾推荐：整句 + emoji"
    );

    f.fresh(e);
    f.type_keys(e, "shi");
    assert!(!f.page().contains(&"✅".to_string()), "单字不推荐 emoji");
}

#[test]
fn full_emoji_panel() {
    let _guard = lock();
    let engine = full!();
    let e = Some(&*engine);
    let mut f = Field::new();

    f.session.toggle_emoji(e);
    assert_eq!(f.session.mode(), Mode::Emoji);
    assert!(!f.page().is_empty(), "空搜索列全部");
    f.type_keys(e, "<right><sp>");
    let second = f.committed.clone();
    assert!(!second.is_empty(), "右键移到第二个再选");
    f.fresh(e);
    f.session.toggle_emoji(e);
    assert_eq!(f.page()[0], second, "最近用过的排最前");
    f.type_keys(e, "<sp>");
    assert_eq!(f.committed, second, "空格选第一个（刚用过的）");

    f.fresh(e);
    f.session.toggle_emoji(e);
    f.type_keys(e, "xiao");
    assert!(f.page().contains(&"😂".to_string()), "搜 xiao 有 😂");
    f.type_keys(e, "<cr>");
    assert!(
        !f.committed.is_empty() && f.preedit().is_empty(),
        "回车选中并关闭面板"
    );

    for (query, want) in [("pizza", "🍕"), ("youjiantou", "→")] {
        f.fresh(e);
        f.session.toggle_emoji(e);
        f.type_keys(e, &format!("{query}<sp>"));
        assert_eq!(f.committed, want, "搜 {query}");
    }

    // 打了一半的拼音带进面板当搜索词
    f.fresh(e);
    f.type_keys(e, "gou");
    f.session.toggle_emoji(e);
    assert_eq!(f.preedit(), "gou");
    assert!(
        f.page().contains(&"🐶".to_string()),
        "gou 搜狗：{:?}",
        f.page()
    );
    f.type_keys(e, "<esc>");
    assert!(
        f.committed.is_empty() && f.preedit().is_empty() && f.page().is_empty(),
        "Esc 关闭面板，不上屏"
    );

    // 再按一次快捷键也关闭；退格删空后再退格关闭
    f.fresh(e);
    f.session.toggle_emoji(e);
    f.session.toggle_emoji(e);
    assert!(
        f.page().is_empty() && f.committed.is_empty(),
        "再按一次快捷键关闭"
    );
    f.session.toggle_emoji(e);
    f.type_keys(e, "a<bs><bs>");
    assert!(
        f.page().is_empty() && f.committed.is_empty() && f.passed.is_empty(),
        "退格删空再退格关闭"
    );
}

#[test]
fn full_settings_take_effect() {
    let _guard = lock();
    let engine = full!();
    let e = Some(&*engine);
    let custom = std::env::temp_dir().join(format!("wotype_custom_{}.tsv", std::process::id()));
    std::fs::write(&custom, "# 测试\nni hao\t妮好\nwo de you xiang\t我的邮箱\n").unwrap();
    engine.load_custom_words(&custom).unwrap();
    session::configure(SessionConfig {
        page_size: 5,
        emoji_suggest: false,
        ..SessionConfig::default()
    });

    let mut f = Field::new();
    f.type_keys(e, "nihao");
    assert_eq!(f.page().len(), 5, "每页 5 个");
    assert_eq!(f.page()[0], "妮好", "自定义词排第一");
    f.fresh(e);
    f.type_keys(e, "wdyx<sp>");
    assert_eq!(f.committed, "我的邮箱", "自定义词也能简拼");
    f.fresh(e);
    f.type_keys(e, "kaixin");
    assert!(!f.page().contains(&"😊".to_string()), "关掉 emoji 推荐");

    // 删掉文件再载入：回到默认
    std::fs::remove_file(&custom).unwrap();
    engine.load_custom_words(&custom).unwrap();
    session::configure(SessionConfig::default());
    f.fresh(e);
    f.type_keys(e, "nihao");
    assert!(
        f.page().len() == 9 && f.page()[0] == "你好",
        "恢复默认：9 个、你好第一：{:?}",
        f.page()
    );
}

#[test]
fn demo_raw_input_for_urls() {
    // 照微信输入法（screenshots/1.mp4）：打拼音途中按 . 进原样输入，候选只有整串原样文字
    let _guard = lock();
    let engine = demo_engine();
    let e = Some(&engine);
    let mut f = Field::new();

    f.type_keys(e, "nihao.");
    assert_eq!(f.preedit(), "nihao.", "编辑区是原样字母，不分音节");
    assert_eq!(f.page(), vec!["nihao."]);
    f.type_keys(e, "com/a1-b");
    assert_eq!(f.page(), vec!["nihao.com/a1-b"], "字母、数字、网址符号接着拼进去");
    f.type_keys(e, "<sp>");
    assert_eq!(f.text, "nihao.com/a1-b", "空格上屏");

    for (keys, want, what) in [
        ("Google.com<cr>", "Google.com", "回车上屏，大写保留"),
        ("ni'hao.<sp>", "nihao.", "隔音符去掉"),
        ("a.<sp>", "a.", "一个字母也是原样，不上屏「啊。」"),
        ("nihao.<bs><sp>", "你好", "退格删掉 . 回到打拼音"),
        ("nihao.<esc>", "", "Esc 清空"),
        ("nihao.com,", "nihao.com，", "别的标点：先上屏，再照常出中文标点"),
        (".", "。", "编辑区空着时照旧是句号"),
    ] {
        f.fresh(e);
        f.type_keys(e, keys);
        assert_eq!(f.text, want, "{what}");
    }

    // 已经选过词：整串原样字母（选过的词作废）
    f.fresh(e);
    f.type_keys(e, "nihaozhongguo");
    let first = f.page().iter().position(|t| t == "你好").expect("有「你好」");
    f.type_keys(e, &(first + 1).to_string());
    assert_eq!(f.preedit(), "你好zhong'guo");
    f.type_keys(e, ".<sp>");
    assert_eq!(f.text, "nihaozhongguo.", "你好 + zhongguo + . 是 nihaozhongguo.");

    session::configure(SessionConfig {
        url_punct: false,
        ..SessionConfig::default()
    });
    f.fresh(e);
    f.type_keys(e, "nihao.");
    assert_eq!(f.text, "你好。", "关掉后照旧");
    session::configure(SessionConfig::default());
}

#[test]
fn demo_raw_input_for_mail() {
    // 照微信输入法（screenshots/2.mp4）：@ 后补全常见邮箱后缀
    let _guard = lock();
    let engine = demo_engine();
    let e = Some(&engine);
    let mut f = Field::new();

    f.type_keys(e, "g@");
    let page = f.page();
    assert_eq!(&page[..3], ["g@qq.com", "g@163.com", "g@126.com"]);
    f.type_keys(e, "<right><right><cr>");
    assert_eq!(f.text, "g@126.com", "左右键选，回车上屏");

    f.fresh(e);
    f.type_keys(e, "nihao@gm");
    assert_eq!(
        f.page(),
        vec!["nihao@gmail.com", "nihao@gm.com", "nihao@gm"],
        "按 @ 后打的前缀过滤，再加「打的 + .com」和原样"
    );
    f.type_keys(e, "<sp>");
    assert_eq!(f.text, "nihao@gmail.com");

    f.fresh(e);
    f.type_keys(e, "nihao@abc.cn<cr>");
    assert_eq!(f.text, "nihao@abc.cn", "对不上的后缀：原样");

    f.fresh(e);
    f.type_keys(e, "@");
    assert_eq!(f.text, "@", "编辑区空着时是半角 @（照微信）");

    // 照微信输入法（2026-11-13 实测）的候选
    for (keys, want) in [
        ("ab@q", vec!["ab@qq.com", "ab@q.com", "ab@q"]),
        ("ab@gx", vec!["ab@gx.com", "ab@gx"]),
        ("ab@qq.", vec!["ab@qq.com", "ab@qq."]),
        ("ab@gx.", vec!["ab@gx."]),
        ("ab@qq.com", vec!["ab@qq.com"]),
        ("ab@qq", vec!["ab@qq.com", "ab@qq"]),
    ] {
        f.fresh(e);
        f.type_keys(e, keys);
        assert_eq!(f.all(), want, "{keys}");
    }
    f.fresh(e);
    f.type_keys(e, "g@");
    assert_eq!(f.all().len(), 15, "@ 后面没打时只列后缀，一共 15 个");
    assert_eq!(f.all()[5], "g@139.com");
    f.fresh(e);
    f.type_keys(e, "ab@1");
    assert_eq!(&f.all()[..3], ["ab@163.com", "ab@126.com", "ab@139.com"], "数字接着打进去");
    f.fresh(e);
    f.type_keys(e, "123456@");
    assert_eq!(f.text, "123456@", "数字后面也是半角 @，不补全（微信也不补）");

    // 选候选和打拼音时一样：到这一页最后一个再按 → 展开，↓ 展开，展开后数字选这一行的第几个
    f.fresh(e);
    f.type_keys(e, "g@");
    let page = f.page().len();
    assert!(page < 15, "一页放不下 15 个后缀");
    for _ in 1..page {
        f.type_keys(e, "<right>");
    }
    assert_eq!(f.session.mode(), Mode::List, "还在这一页");
    f.type_keys(e, "<right>");
    assert_eq!(f.session.mode(), Mode::Grid, "这一页最后一个再按 → 展开");
    f.type_keys(e, "<esc>");
    assert_eq!(f.session.mode(), Mode::List, "Esc 收起");
    f.type_keys(e, "<down>");
    assert_eq!(f.session.mode(), Mode::Grid, "↓ 展开");
    f.type_keys(e, "<down><sp>");
    assert!(f.committed.starts_with("g@") && f.committed != "g@qq.com", "展开后空格上屏高亮的：{}", f.committed);
    f.fresh(e);
    f.type_keys(e, "g@<down>2");
    assert_eq!(f.committed, "g@163.com", "展开后数字选这一行的第几个");
    f.fresh(e);
    f.type_keys(e, "g@");
    assert!(f.session.toggle_grid(), "∨ 也能展开");
    f.type_keys(e, "<bs>");
    assert_eq!(f.session.mode(), Mode::List, "退格先收起再删");
    assert_eq!(f.preedit(), "g", "删掉 @ 回到打拼音");
    f.fresh(e);
    f.type_keys(e, "ab@1");
    assert_eq!(f.preedit(), "ab@1", "没展开时数字照旧打进去");

    // 记住用过的、不在内置表里的后缀（公司邮箱）：下次排在内置的前面，只存后缀
    let path = std::env::temp_dir().join(format!("wotype_mail_{}.txt", std::process::id()));
    let _ = std::fs::remove_file(&path);
    session::set_mail_domains_path(Some(path.clone()));
    f.fresh(e);
    f.type_keys(e, "ab@mycorp.com<sp>");
    assert_eq!(f.text, "ab@mycorp.com");
    f.fresh(e);
    f.type_keys(e, "cd@");
    assert_eq!(f.all()[..2], ["cd@mycorp.com", "cd@qq.com"], "记住的排在内置的前面");
    f.fresh(e);
    f.type_keys(e, "cd@m");
    assert_eq!(f.all()[0], "cd@mycorp.com", "也按打的前缀过滤");
    f.fresh(e);
    f.type_keys(e, "ab@qq.com<sp>ab@ex.cn<sp>ab@bad.<sp>");
    assert_eq!(
        std::fs::read_to_string(&path).unwrap(),
        "ex.cn\nmycorp.com\n",
        "内置的、不像域名的不记；最近的在前；不存用户名"
    );
    session::set_mail_domains_path(None);
    let _ = std::fs::remove_file(&path);

    // 鼠标点候选
    f.fresh(e);
    f.type_keys(e, "g@");
    assert!(f.session.select(e, 1));
    f.committed.push_str(&f.session.take_commit());
    assert_eq!(f.committed, "g@163.com");
}

#[test]
fn demo_auto_pair() {
    let _guard = lock();
    let engine = demo_engine();
    let e = Some(&engine);
    session::configure(SessionConfig {
        auto_pair: true,
        ..SessionConfig::default()
    });
    let mut s = Session::new();
    s.key(e, Key::Char('('), mods::SHIFT);
    let json = s.snapshot(true);
    assert!(json.contains("\"commit\":\"（）\""), "{json}");
    assert!(json.contains("\"caret_back\":1"), "{json}");
    assert!(s.snapshot(true).contains("\"caret_back\":0"), "只退一次");

    for key in "nihao[".chars() {
        s.key(e, Key::Char(key), 0);
    }
    let json = s.snapshot(true);
    assert!(json.contains("\"commit\":\"你好【】\""), "打字途中也补：{json}");
    assert!(json.contains("\"caret_back\":1"), "{json}");

    session::configure(SessionConfig::default());
    s.key(e, Key::Char('('), mods::SHIFT);
    let json = s.snapshot(true);
    assert!(json.contains("\"commit\":\"（\"") && json.contains("\"caret_back\":0"), "默认关：{json}");
}

#[test]
fn demo_auto_space() {
    let _guard = lock();
    let engine = demo_engine();
    let e = Some(&engine);
    session::configure(SessionConfig {
        space_cjk_latin: true,
        space_cjk_digit: true,
        ..SessionConfig::default()
    });
    let mut f = Field::new();
    for (before, keys, want, what) in [
        ("ok", "nihao<sp>", " 你好", "英文后打中文"),
        ("你好", "Hello<cr>", " Hello", "中文后上屏英文"),
        ("第", "3", " 3", "中文后打数字"),
        ("3", "nihao<sp>", " 你好", "数字后打中文"),
        ("你好", "，", "，", "中文标点不加"),
        ("ok", "，", "，", "英文后中文标点也不加"),
        ("", "nihao<sp>", "你好", "前面没有字"),
        ("你好", "12", " 12", "连着的数字只在前面加一次"),
    ] {
        f.fresh(e);
        f.session.set_context(before);
        f.type_keys(e, keys);
        assert_eq!(f.text, want, "{what}");
    }

    session::configure(SessionConfig::default());
    f.fresh(e);
    f.session.set_context("ok");
    f.type_keys(e, "nihao<sp>");
    assert_eq!(f.text, "你好", "默认关");
}

#[test]
fn demo_v_mode_numbers() {
    // v 后面打数字转中文数字（搜狗那样的 v 模式；微信输入法没有，设置里默认关）
    let _guard = lock();
    let engine = demo_engine();
    let e = Some(&engine);
    let mut f = Field::new();

    f.type_keys(e, "v1");
    assert_ne!(f.preedit(), "v1", "默认关：数字照常选候选");
    f.fresh(e);
    session::configure(SessionConfig {
        v_number: true,
        ..SessionConfig::default()
    });

    f.type_keys(e, "v234");
    assert_eq!(f.preedit(), "v234");
    assert_eq!(f.page(), vec!["二百三十四", "贰佰叁拾肆", "234", "二三四"]);
    for (keys, want, what) in [
        ("v234<sp>", "二百三十四", "空格上屏第一个"),
        ("v234<right><cr>", "贰佰叁拾肆", "左右键挑，回车上屏"),
        ("v234<right><right><sp>", "234", "原样数字"),
        ("v12.5<sp>", "十二点五", "小数"),
        ("v1<sp>", "一", "数字 1 也进 v 模式，不再是选第一个候选"),
        ("v2,", "二，", "别的标点：先上屏，再照常处理"),
        ("v2<esc>", "", "Esc 清空"),
        ("v<sp>", "v", "只打 v 照旧"),
    ] {
        f.fresh(e);
        f.type_keys(e, keys);
        assert_eq!(f.text, want, "{what}");
    }

    f.fresh(e);
    f.type_keys(e, "v234<down>");
    assert_eq!(f.session.mode(), Mode::Grid, "和打拼音一样 ↓ 展开");
    f.type_keys(e, "2");
    assert_eq!(f.text, "贰佰叁拾肆", "展开后数字选第几个");

    f.fresh(e);
    f.type_keys(e, "v2<bs>");
    assert_eq!(f.preedit(), "v", "数字删光回到只打了 v");
    f.type_keys(e, "3<sp>");
    assert_eq!(f.text, "三", "再打数字又进 v 模式");

    f.fresh(e);
    f.type_keys(e, "v1.2.");
    assert_eq!(f.text, "一点二。", "只收一个小数点：第二个 . 先上屏再出句号");
    session::configure(SessionConfig::default());
}

#[test]
fn demo_toggle_grid() {
    let _guard = lock();
    let engine = demo_engine();
    let e = Some(&engine);
    let mut f = Field::new();
    f.type_keys(e, "nihaozhongguo");
    assert!(f.page().len() > 1);
    assert_eq!(f.session.mode(), Mode::List);
    assert!(f.session.toggle_grid(), "点 ∨ 展开");
    assert_eq!(f.session.mode(), Mode::Grid);
    assert!(f.session.toggle_grid(), "点 ∧ 收起");
    assert_eq!(f.session.mode(), Mode::List);

    f.fresh(e);
    f.type_keys(e, "nihao.");
    assert!(!f.session.toggle_grid(), "原样输入只有一个候选，不展开");
}

#[test]
fn demo_row_width_paging() {
    // 横排按宽度分页：能放几个放几个，最多 9 个
    let _guard = lock();
    let engine = homophone_engine();
    let e = Some(&engine);
    let mut f = Field::new();

    // 单字一个约 3.1（序号、留白 2.1 + 字 1）：宽 20 放 6 个
    session::configure(SessionConfig {
        row_width: 2000,
        ..SessionConfig::default()
    });
    f.type_keys(e, "shi");
    let all = f.session.all_candidates();
    assert!(all.len() > 9, "shi 的候选要多：{all:?}");
    assert_eq!(f.page().len(), 6);
    f.type_keys(e, "6");
    assert_eq!(f.committed, all[5], "数字键选这一页的第 6 个");

    f.fresh(e);
    f.type_keys(e, "shi<right><right><right><right><right>");
    assert_eq!(f.session.mode(), Mode::List);
    f.type_keys(e, "<right>");
    assert_eq!(f.session.mode(), Mode::Grid, "走过这一页最后一个（第 6 个）就展开");

    // 宽度很大也最多 9 个
    session::configure(SessionConfig {
        row_width: 100_000,
        ..SessionConfig::default()
    });
    f.fresh(e);
    f.type_keys(e, "shi");
    assert_eq!(f.page().len(), 9);
    session::configure(SessionConfig::default());
}

#[test]
fn demo_chinese_quotes() {
    // 中文状态的 " ' 是中文引号，一开一合交替；打拼音途中的 ' 还是隔音符
    let _guard = lock();
    let engine = demo_engine();
    let e = Some(&engine);
    let mut f = Field::new();
    for (keys, want, what) in [
        ("\"nihao\"", "“你好”", "双引号一开一合"),
        ("'nihao<sp>'", "‘你好’", "单引号一开一合（打拼音途中的 ' 是隔音符，先上屏）"),
        ("\"\"\"", "“”“", "连按也交替"),
        ("xi'an<sp>", "西安", "打拼音途中的 ' 是隔音符"),
        ("nihao\"", "你好“", "打拼音途中按 \"：先上屏再出引号"),
    ] {
        f.fresh(e);
        f.type_keys(e, keys);
        assert_eq!(f.text, want, "{what}");
    }

    // 换了输入框从左半边开始
    f.fresh(e);
    f.type_keys(e, "\"");
    f.session.reset(e, false);
    f.text.clear();
    f.type_keys(e, "\"");
    assert_eq!(f.text, "“", "换输入框后重新从左引号开始");

    // 开了自动补全：成对上屏，光标退回中间
    session::configure(SessionConfig {
        auto_pair: true,
        ..SessionConfig::default()
    });
    let mut s = Session::new();
    s.key(e, Key::Char('"'), mods::SHIFT);
    let json = s.snapshot(true);
    assert!(json.contains("\"commit\":\"“”\"") && json.contains("\"caret_back\":1"), "{json}");
    s.key(e, Key::Char('\''), 0);
    let json = s.snapshot(true);
    assert!(json.contains("\"commit\":\"‘’\"") && json.contains("\"caret_back\":1"), "{json}");
    session::configure(SessionConfig::default());
}

#[test]
fn full_mixed_chinese_and_english() {
    // 中英混打：拼音里夹一个英文词
    let _guard = lock();
    let engine = full!();
    let e = Some(&*engine);
    if !data_dir().join("english.txt").exists() {
        return;
    }
    let mut f = Field::new();
    for (keys, want, what) in [
        ("wozaigithub<sp>", "我在GitHub", "英文在后面"),
        ("githubshangyou<sp>", "GitHub上有", "英文在前面"),
        ("zhegeappbucuo<sp>", "这个app不错", "英文在中间"),
        ("woyongiPhone<sp>", "我用iPhone", "自己打了大写就照打的"),
        ("womenthe<sp>", "我们the", "几种切法里取中文部分更顺的（不是 我 ment 和）"),
        ("Hello<sp>", "Hello", "整串就是英文词：不切成 Hell + 哦"),
        ("hello<sp>", "hello", "同上"),
    ] {
        f.fresh(e);
        f.type_keys(e, keys);
        assert_eq!(f.committed, want, "{what}");
    }
    f.fresh(e);
    f.type_keys(e, "wozaigithub");
    assert_eq!(f.preedit(), "wo'zai'github", "编辑区按中文、英文分段");

    // 开了「中英文之间加空格」：混打候选里的英文词两边也加
    session::configure(SessionConfig {
        space_cjk_latin: true,
        ..SessionConfig::default()
    });
    for (keys, want) in [
        ("wozaigithub<sp>", "我在 GitHub"),
        ("zhegeappbucuo<sp>", "这个 app 不错"),
        ("githubshangyou<sp>", "GitHub 上有"),
    ] {
        f.fresh(e);
        f.type_keys(e, keys);
        assert_eq!(f.committed, want);
    }
    session::configure(SessionConfig::default());

    // 拼音打到一半、简拼、纠错：首选还是中文
    for (keys, what) in [
        ("tamenbus", "bus"),
        ("xihuand", "and"),
        ("wobuzhid", "不知道"),
        ("wozaibj", "简拼"),
        ("zhognguo", "纠错"),
    ] {
        f.fresh(e);
        f.type_keys(e, keys);
        let first = f.page().first().cloned().unwrap_or_default();
        assert!(
            !first.bytes().any(|b| b.is_ascii_alphabetic()),
            "{keys}（{what}）首选应当是中文：{first}"
        );
    }

    // 选词记忆：混打候选不在第一时，选过一次下次就排第一；开着加空格也一样
    // （以前按带空格的文字记，引擎里的候选不带空格，永远对不上）
    for spaced in [false, true] {
        session::configure(SessionConfig {
            space_cjk_latin: spaced,
            ..SessionConfig::default()
        });
        let keys = if spaced { "tamenbus" } else { "xihuand" };
        let want = if spaced { "他们 bus" } else { "喜欢and" };
        f.fresh(e);
        f.type_keys(e, keys);
        let page = f.page();
        let at = page.iter().position(|t| t == want).expect("混打候选在第一页");
        assert!(at > 0, "{keys} 一开始首选是中文：{page:?}");
        f.type_keys(e, &(at + 1).to_string());
        assert_eq!(f.committed, want);
        f.fresh(e);
        f.type_keys(e, keys);
        assert_eq!(f.page()[0], want, "选过一次以后排第一");
    }
    session::configure(SessionConfig::default());
}

#[test]
fn full_mixed_code_words() {
    // 万象 mixed.dict.yaml 里编码带字母的词：Azuo → A座
    let _guard = lock();
    let engine = full!();
    let e = Some(&*engine);
    if !data_dir().join("mixed.txt").exists() {
        return;
    }
    let mut f = Field::new();
    // 全小写：也能当拼音读，中文还是首选，混合编码的词排第二
    // （放在最前面查：下面一上屏就进了选词记忆，再打就排第一了）
    for (keys, word) in [("azuo", "A座"), ("bzhan", "B站"), ("txu", "T恤")] {
        f.fresh(e);
        f.type_keys(e, keys);
        let page = f.page();
        assert_eq!(page.iter().position(|t| t == word), Some(1), "{keys}：{page:?}");
    }
    // 夹在句子里也出：全小写时在第一页，不抢首选
    for (keys, word) in [("shenmeadian", "什么A点"), ("qubzhan", "去B站")] {
        f.fresh(e);
        f.type_keys(e, keys);
        let page = f.page();
        let at = page.iter().position(|t| t == word);
        assert!(matches!(at, Some(1..)), "{keys}：{page:?}");
    }
    // 编码的分段和音节对不上的不出：jia 不是 ji'a（吉A），jiagu 不是 ji + A股
    for (keys, first) in [("jiagu", "加固"), ("dajiahao", "大家好")] {
        f.fresh(e);
        f.type_keys(e, keys);
        let page = f.page();
        assert_eq!(page[0], first, "{keys}");
        assert!(!page.iter().any(|t| t.contains('A')), "{keys}：{page:?}");
    }
    f.fresh(e);
    f.type_keys(e, "jia");
    assert!(!f.page().iter().any(|t| t.contains('A')), "jia：{:?}", f.page());
    // 编码本身是英文词的（iphone → iPhone 18 Pro）：首选还是英文词
    f.fresh(e);
    f.type_keys(e, "iPhone<sp>");
    assert_eq!(f.committed, "iPhone");
    for (keys, want, what) in [
        ("shenmeAdian<sp>", "什么A点", "句子里打了大写：排第一"),
        ("wozaiAzuo<sp>", "我在A座", "同上"),
        ("woxihuanOKla<sp>", "我喜欢OK啦", "同上"),
        ("jiA<sp>", "吉A", "分段对不上的要打大写"),
        ("Azuo<sp>", "A座", "打了大写：排第一"),
        ("Agu<sp>", "A股", "同上"),
        ("OKla<sp>", "OK啦", "同上"),
        ("Bzhan<sp>", "B站", "同上"),
    ] {
        f.fresh(e);
        f.type_keys(e, keys);
        assert_eq!(f.committed, want, "{what}");
    }
    // 编码整个是拼音的排在正常的词后面
    for (keys, first, word) in [("hezi", "盒子", "Hz"), ("fenbei", "分贝", "dB")] {
        f.fresh(e);
        f.type_keys(e, keys);
        let page = f.page();
        assert_eq!(page[0], first);
        let at = page.iter().position(|t| t == word);
        assert!(matches!(at, Some(2..)), "{keys}：{page:?}");
    }
    // 正常的拼音不受影响
    f.fresh(e);
    f.type_keys(e, "nihao<sp>");
    assert_eq!(f.committed, "你好");

    // 选过以后排第一（选词记忆），选到自动记进用户词库以后也一样
    for round in 0..4 {
        for (keys, word) in [("bzhan", "B站"), ("okla", "OK啦")] {
            f.fresh(e);
            f.type_keys(e, keys);
            let page = f.page();
            let at = page.iter().position(|t| t == word).expect("有这个词");
            assert!(round == 0 || at == 0, "第 {round} 轮 {keys}：{page:?}");
            f.type_keys(e, &(at + 1).to_string());
            assert_eq!(f.committed, word);
        }
    }
    f.fresh(e);
    f.type_keys(e, "bzhan");
    assert_eq!(f.page()[0], "B站");
    assert_eq!(f.page().iter().filter(|t| *t == "B站").count(), 1, "不重复");
}

#[test]
fn full_raw_english_candidate_is_remembered() {
    // main 能当成 mai'n（买你）打到一半的拼音，英文排第二；选过它以后要排第一
    let _guard = lock();
    let engine = full!();
    let e = Some(&*engine);
    if !data_dir().join("english.txt").exists() {
        return;
    }
    let mut f = Field::new();
    f.type_keys(e, "main");
    let page = f.page();
    let at = page.iter().position(|t| t == "main").expect("有 main");
    assert!(at > 0, "一开始首选是中文：{page:?}");
    let chinese = page[0].clone();
    f.type_keys(e, &(at + 1).to_string());
    assert_eq!(f.committed, "main");

    f.fresh(e);
    f.type_keys(e, "main");
    assert_eq!(f.page()[0], "main", "选过一次以后排第一");

    // 反过来：中文选得更多，中文回到第一（一样多时也是中文）
    for _ in 0..2 {
        f.fresh(e);
        f.type_keys(e, "main");
        let at = f.page().iter().position(|t| *t == chinese).expect("中文候选还在");
        f.type_keys(e, &(at + 1).to_string());
    }
    f.fresh(e);
    f.type_keys(e, "main");
    assert_eq!(f.page()[0], chinese, "中文选得更多时中文排第一");
}

#[test]
fn full_raw_letters_committed_by_return_do_not_outrank_chinese() {
    // 回车上屏过原样字母（不是英文词）也会记进历史，不能因此排到中文前面
    let _guard = lock();
    let engine = full!();
    let e = Some(&*engine);
    let mut f = Field::new();
    for _ in 0..3 {
        f.fresh(e);
        f.type_keys(e, "wobuzhid<cr>");
    }
    assert_eq!(f.committed, "wobuzhid");
    f.fresh(e);
    f.type_keys(e, "wobuzhid");
    assert_eq!(f.page()[0], "我不知道");
}

#[test]
fn full_unified_selection_memory() {
    // 选词记忆的通用规则：选得多的排第一，一样多看最近；所有输入方式都管
    let _guard = lock();
    let engine = full!();
    let e = Some(&*engine);
    let mut f = Field::new();
    // 在当前输入的全部候选里找到 want，展开网格后点它
    fn pick(f: &mut Field, e: Option<&Engine>, keys: &str, want: &str) {
        f.fresh(e);
        f.type_keys(e, keys);
        if f.page().first().map(String::as_str) == Some(want) {
            f.type_keys(e, "<sp>");
            return;
        }
        f.session.toggle_grid();
        for _ in 0..8 {
            if let Some(at) = f.session.shown().iter().position(|t| t == want) {
                assert!(f.session.select(e, at));
                f.committed.push_str(&f.session.take_commit());
                return;
            }
            f.type_keys(e, "<pgdn>");
        }
        panic!("{keys} 的候选里没有 {want}");
    }
    let first = |f: &mut Field, keys: &str| {
        f.fresh(e);
        f.type_keys(e, keys);
        f.page()[0].clone()
    };

    // 最后一个音节没打完的输入（以前不管）：选一次就排第一
    let before = first(&mut f, "yuanc");
    assert_ne!(before, "远程");
    pick(&mut f, e, "yuanc", "远程");
    assert_eq!(first(&mut f, "yuanc"), "远程", "选一次，下次排第一");

    // 两个都选过：一样多时最近选的在前，选得多的在前
    pick(&mut f, e, "yuanc", &before);
    assert_eq!(first(&mut f, "yuanc"), before, "各一次：最近选的在前");
    pick(&mut f, e, "yuanc", "远程");
    assert_eq!(first(&mut f, "yuanc"), "远程", "二比一：选得多的在前");

    // 单字：这一步最多把它提到第二（它排第一是普通加分的结果，不是这一步强行提的）
    f.fresh(e);
    f.type_keys(e, "tuo");
    let third = f.page()[2].clone();
    assert!(third.chars().count() == 1);
    pick(&mut f, e, "tuo", &third);
    f.fresh(e);
    f.type_keys(e, "tuo");
    assert!(f.page()[..2].contains(&third), "单字选过排在前两个：{:?}", f.page());
}

#[test]
fn full_commit_then_delete_is_not_learned() {
    // 上屏后紧接着用退格整个删掉：选错了，不算学习
    let _guard = lock();
    let engine = full!();
    let e = Some(&*engine);
    let mut f = Field::new();

    f.type_keys(e, "kaihui<sp>");
    let word = f.committed.clone();
    assert_eq!(word.chars().count(), 2);
    assert_eq!(engine.history_count(&word), 1);
    f.type_keys(e, "<bs><bs>");
    assert_eq!(engine.history_count(&word), 0, "两个字都删了：撤销");

    // 只删了一半、或者中间按了别的键：算数
    f.fresh(e);
    f.type_keys(e, "kaihui<sp><bs>a<esc><bs>");
    assert_eq!(engine.history_count(&word), 1, "没删完");
    f.fresh(e);
    f.type_keys(e, "kaihui<sp>,<bs><bs><bs>");
    assert_eq!(engine.history_count(&word), 2, "中间按了别的键");

    // 误按空格上屏错词、删掉重选：只有对的词被记
    for _ in 0..3 {
        f.fresh(e);
        f.type_keys(e, "yuany<sp>");
        let wrong = f.committed.clone();
        if wrong == "愿意" {
            break;
        }
        for _ in 0..wrong.chars().count() {
            f.type_keys(e, "<bs>");
        }
        assert_eq!(engine.history_count(&wrong), 0, "误选的 {wrong} 不留记录");
    }
}

// MARK: 选词记忆的行为矩阵
//
// 候选有好几个来源（主词库、英文、中英混打、混合编码、自定义词…），除了主词库都是排完序以后
// 按各自的规则插进去的。每加一个来源，「第一次排哪、选过以后排哪、能不能进句子」都要单独接一遍，
// 漏一处就是一个问题（docs/bugs/05、06、07）。这里把规则写成对所有来源都要成立的几条，
// 一张表跑完：加新来源时在 MEMORY_ROWS 里加一行。
//
// 现在不满足、但知道原因的写在 MEMORY_KNOWN 里（docs/09）；修好一条就从里面删一条——
// 表里有、实际已经满足的也算测试失败，免得这张表过期。

/// 一行：哪种来源、打什么、要的是哪个候选。
struct MemoryRow {
    source: &'static str,
    input: &'static str,
    want: &'static str,
}

const MEMORY_ROWS: &[MemoryRow] = &[
    MemoryRow { source: "普通词", input: "shishi", want: "实时" },
    MemoryRow { source: "普通词", input: "zhidao", want: "直到" },
    MemoryRow { source: "简拼", input: "zg", want: "中国" },
    MemoryRow { source: "末字简拼", input: "yuanc", want: "元朝" },
    MemoryRow { source: "单字", input: "shi", want: "市" },
    MemoryRow { source: "拼出来的整句", input: "woaibiancheng", want: "我爱编程" },
    MemoryRow { source: "英文", input: "main", want: "main" },
    MemoryRow { source: "中英混打", input: "nihaoyaenglish", want: "你好呀english" },
    MemoryRow { source: "混合编码", input: "azuo", want: "A座" },
    MemoryRow { source: "混合编码", input: "bzhan", want: "B站" },
    MemoryRow { source: "混合编码", input: "okla", want: "OK啦" },
    MemoryRow { source: "混合编码（编码是拼音）", input: "hezi", want: "Hz" },
    MemoryRow { source: "混合编码在句子里", input: "shenmeadian", want: "什么A点" },
    MemoryRow { source: "混合编码在句子里", input: "qubzhan", want: "去B站" },
];

/// 单独能打出来的词，夹在句子里也要能出：(句子, 里面的词)。每个词单独打都要有。
const MEMORY_SENTENCES: &[(&str, &[(&str, &str)])] = &[
    ("wodemain", &[("main", "main")]),
    ("wozaigithub", &[("github", "GitHub")]),
    ("wozaiazuo", &[("azuo", "A座")]),
    ("qubzhan", &[("bzhan", "B站")]),
    ("nishuookla", &[("okla", "OK啦")]),
    ("wozaiAzuo", &[("Azuo", "A座")]),
    ("nishuoOKla", &[("OKla", "OK啦")]),
    // 一句里两个
    ("wozaigithubyongpython", &[("github", "GitHub"), ("python", "python")]),
    ("wozaibzhankangithub", &[("bzhan", "B站"), ("github", "GitHub")]),
    ("congAzuoquBzhan", &[("Azuo", "A座"), ("Bzhan", "B站")]),
];

/// 几种设置各跑一遍：(名字, 模糊音, 中英文之间加空格)。
const MEMORY_SETUPS: &[(&str, bool, bool)] = &[
    ("默认", false, false),
    ("模糊音", true, false),
    ("中英文加空格", false, true),
];

/// 学了别的词以后，这些常用词的首选不能变。
const MEMORY_CONTROLS: &[(&str, &str)] = &[
    ("nihao", "你好"),
    ("women", "我们"),
    ("shijian", "时间"),
    ("keyi", "可以"),
    ("xihuan", "喜欢"),
    ("jintianxiawukaihui", "今天下午开会"),
];

const RULE_FIRST_PAGE: &str = "第一次就在第一页";
const RULE_ONCE: &str = "选过一次下次排第一";
const RULE_STAYS: &str = "再选几次一直排第一";
const RULE_UNDO: &str = "上屏后马上删掉的不算";
const RULE_MORE_WINS: &str = "别的词选得更多就换它排第一";
const RULE_NO_SPILL: &str = "不影响别的输入";
const RULE_IN_SENTENCE: &str = "夹在句子里也能出";

/// 现在不满足的：(设置，"*" 是每种设置都这样, 输入, 规则, 原因)。见 docs/09。
const MEMORY_KNOWN: &[(&str, &str, &str, &str)] = &[
    // 有意的：单字最多提到第二（是、的、了 这样的首选不该被偶尔选一次的字顶掉）
    ("*", "shi", RULE_ONCE, "单字最多提到第二"),
    ("*", "shi", RULE_STAYS, "单字最多提到第二"),
    // 一句里只认一个英文词 / 混合编码词，等并进整句搜索以后解决（docs/09 第二步）
    ("*", "wozaigithubyongpython", RULE_IN_SENTENCE, "一句里只认一个英文词"),
    ("*", "wozaibzhankangithub", RULE_IN_SENTENCE, "一句里只认一个英文词或混合编码词"),
    ("*", "congAzuoquBzhan", RULE_IN_SENTENCE, "一句里只认一个混合编码词"),
];

/// 每个用例一个新引擎（词库、语言模型共用），选词记忆从空开始。
fn fresh_full_engine(fuzzy: bool) -> Option<Engine> {
    type Base = (Arc<dyn Lexicon>, Arc<dyn wotype_core::lm::LanguageModel>, String, String);
    static BASE: OnceLock<Option<Base>> = OnceLock::new();
    let (lexicon, lm, english, mixed) = BASE
        .get_or_init(|| {
            let lexicon = data_dir().join("lexicon.tsv");
            let english = std::fs::read_to_string(data_dir().join("english.txt")).ok()?;
            let mixed = std::fs::read_to_string(data_dir().join("mixed.txt")).ok()?;
            if !lexicon.exists() {
                return None;
            }
            let lexicon: Arc<dyn Lexicon> =
                Arc::new(MemoryLexicon::from_tsv_path_cached(&lexicon).unwrap());
            let lm = match grammar_path() {
                Some(path) => wotype_core::lm::load_lm(&path).unwrap(),
                None => Arc::new(BigramLm::default()),
            };
            Some((lexicon, lm, english, mixed))
        })
        .as_ref()?;
    let mut engine = Engine::new(Arc::clone(lexicon), Arc::clone(lm));
    engine.set_max_candidates(session::MAX_CANDIDATES);
    engine.set_fuzzy(fuzzy);
    engine.load_english_str(english);
    engine.load_mixed_str(mixed);
    Some(engine)
}

/// 打 `input`，返回第一页（去掉「中英文之间加空格」加的空格）。
fn memory_page(engine: &Engine, input: &str) -> Vec<String> {
    let mut f = Field::new();
    f.type_keys(Some(engine), input);
    let page = f.page().iter().map(|t| t.replace(' ', "")).collect();
    f.fresh(Some(engine));
    page
}

/// 打 `input`、用数字键选 `want`；不在第一页返回 false。`undo` 时上屏后马上用退格删掉。
fn memory_pick(engine: &Engine, input: &str, want: &str, undo: bool) -> bool {
    let e = Some(engine);
    let mut f = Field::new();
    f.type_keys(e, input);
    let Some(at) = f.page().iter().position(|t| t.replace(' ', "") == want) else {
        f.fresh(e);
        return false;
    };
    f.type_keys(e, &(at + 1).to_string());
    assert_eq!(f.committed.replace(' ', ""), want, "{input} 选第 {} 个", at + 1);
    if undo {
        // 加的空格也是上屏的字，要一起删
        for _ in 0..f.committed.chars().count() {
            f.type_keys(e, "<bs>");
        }
    }
    true
}

#[test]
fn full_memory_matrix() {
    let _guard = lock();
    if fresh_full_engine(false).is_none() {
        return;
    }
    // (设置, 输入, 规则, 看到了什么)
    let mut failures: Vec<(&str, String, &str, String)> = Vec::new();
    for &(setup, fuzzy, space) in MEMORY_SETUPS {
    session::configure(SessionConfig {
        space_cjk_latin: space,
        ..SessionConfig::default()
    });
    let engine = || fresh_full_engine(fuzzy).unwrap();
    let mut fail = |input: &str, rule: &'static str, detail: String| {
        failures.push((setup, input.to_string(), rule, detail));
    };

    for row in MEMORY_ROWS {
        let (input, want) = (row.input, row.want);
        let e = engine();
        let fresh = memory_page(&e, input);
        if !fresh.iter().any(|t| t == want) {
            fail(input, RULE_FIRST_PAGE, format!("{}：{fresh:?}", row.source));
            continue;
        }
        let other = fresh.iter().find(|t| *t != want).cloned();

        // 选一次排第一，再选几次一直第一（第 3 次起自动记进用户词库，不能有变化）
        memory_pick(&e, input, want, false);
        let page = memory_page(&e, input);
        if page.first().map(String::as_str) != Some(want) {
            fail(input, RULE_ONCE, format!("{page:?}"));
        }
        for round in 2..=5 {
            if !memory_pick(&e, input, want, false) {
                fail(input, RULE_STAYS, format!("选了 {} 次以后不在第一页了", round - 1));
                break;
            }
            let page = memory_page(&e, input);
            if page.first().map(String::as_str) != Some(want) {
                fail(input, RULE_STAYS, format!("选了 {round} 次：{page:?}"));
                break;
            }
        }
        for (control, first) in MEMORY_CONTROLS {
            let page = memory_page(&e, control);
            if page.first().map(String::as_str) != Some(first) {
                fail(input, RULE_NO_SPILL, format!("{control}：{page:?}"));
            }
        }

        // 上屏后马上删掉：和没选过一样
        let e = engine();
        memory_pick(&e, input, want, true);
        let page = memory_page(&e, input);
        if page != fresh {
            fail(input, RULE_UNDO, format!("{page:?}，原来是 {fresh:?}"));
        }

        // 要的词选 2 次，另一个选 3 次：另一个排第一
        if let Some(other) = other {
            let e = engine();
            let mut picked = true;
            for _ in 0..2 {
                picked &= memory_pick(&e, input, want, false);
            }
            for _ in 0..3 {
                picked &= memory_pick(&e, input, &other, false);
            }
            let page = memory_page(&e, input);
            if !picked || page.first() != Some(&other) {
                fail(input, RULE_MORE_WINS, format!("{other} 选了 3 次、{want} 2 次：{page:?}"));
            }
        }
    }

    for (sentence, words) in MEMORY_SENTENCES {
        let e = engine();
        for (alone, word) in *words {
            let page = memory_page(&e, alone);
            assert!(page.iter().any(|t| t == word), "{setup} {alone} 应该有 {word}：{page:?}");
        }
        let page = memory_page(&e, sentence);
        if !page.iter().any(|t| words.iter().all(|(_, word)| t.contains(word))) {
            fail(sentence, RULE_IN_SENTENCE, format!("{page:?}"));
        }
    }
    }
    session::configure(SessionConfig::default());

    for (setup, input, rule, detail) in &failures {
        eprintln!("不满足  [{setup}] {input}  {rule}  {detail}");
    }
    let known = |setup: &str, input: &str, rule: &str| {
        MEMORY_KNOWN
            .iter()
            .any(|(s, i, r, _)| (*s == "*" || *s == setup) && *i == input && *r == rule)
    };
    let mut wrong = Vec::new();
    for (setup, input, rule, detail) in &failures {
        if !known(setup, input, rule) {
            wrong.push(format!("[{setup}] {input}：{rule}（{detail}）"));
        }
    }
    for (setup, input, rule, _) in MEMORY_KNOWN {
        let still = failures
            .iter()
            .any(|(s, i, r, _)| (*setup == "*" || setup == s) && i == input && r == rule);
        if !still {
            wrong.push(format!("[{setup}] {input}：{rule} 现在满足了，从 MEMORY_KNOWN 里删掉"));
        }
    }
    assert!(wrong.is_empty(), "选词记忆的行为矩阵：\n{}", wrong.join("\n"));
}
