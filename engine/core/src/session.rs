//! 输入会话：一个输入框里的交互状态机。
//!
//! 编辑区、已选的句首词、候选翻页、下键展开的网格、表情面板都在这里，和平台无关：
//! 前端（macOS 的 IMK 外壳、fcitx5 插件）只把按键交进来，再按 [`Session::snapshot`]
//! 把编辑区和候选画出来、把要上屏的文字交给应用。
//!
//! 行为照搬 fcitx5 插件 `wowtype_engine.cpp` 的 `keyEvent` 一族，测试对照它的
//! `key_harness.cpp`。语音、表情面板的快捷键、中英切换不在这里，由前端处理。
//!
//! 引擎不归会话持有：每次调用把引擎传进来，引擎还在后台载入时传 `None`，
//! 这时字母照常进编辑区，只是没有候选。

use std::path::PathBuf;
use std::sync::{Mutex, RwLock};

use crate::Engine;

/// 展开的网格每行几个候选、一屏几行（照微信输入法）。
pub const GRID_COLS: usize = 6;
pub const GRID_ROWS: usize = 6;
/// 每次输入最多要多少个候选：前两页之后把同音词、句首词、单字全补上，翻页能翻到生僻字。
pub const MAX_CANDIDATES: usize = 300;
/// 参与排序的上文最多几个字节（按字符边界截）。
const CONTEXT_BYTES: usize = 24;
/// 表情面板最多列多少个。
const MAX_EMOJI: usize = 2000;
/// 最近用过的 emoji 记几个。
const RECENT_EMOJI: usize = 18;
/// 打字推荐的 emoji 插在第几个候选（从 0 数）。
const EMOJI_SLOT: usize = 2;
/// 标点前把候选一个个选完时最多选几次（防止死循环）。
const COMMIT_GUARD: usize = 16;

/// 一个按键。可打印字符直接给字符，其他是功能键。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Key {
    Char(char),
    Space,
    Return,
    Backspace,
    Escape,
    Tab,
    Delete,
    Left,
    Right,
    Up,
    Down,
    PageUp,
    PageDown,
    Home,
    End,
}

impl Key {
    fn is_cursor_move(self) -> bool {
        matches!(
            self,
            Key::Left
                | Key::Right
                | Key::Up
                | Key::Down
                | Key::PageUp
                | Key::PageDown
                | Key::Home
                | Key::End
        )
    }

    fn digit(self) -> Option<usize> {
        match self {
            Key::Char(c) => c.to_digit(10).map(|d| d as usize),
            _ => None,
        }
    }

    fn letter(self) -> Option<char> {
        match self {
            Key::Char(c) if c.is_ascii_alphabetic() => Some(c),
            _ => None,
        }
    }
}

/// 修饰键位（和 C 接口的 WOTYPE_MOD_* 一致）。
pub mod mods {
    pub const SHIFT: u32 = 1;
    pub const CONTROL: u32 = 2;
    pub const OPTION: u32 = 4;
    pub const COMMAND: u32 = 8;
    pub const CAPS_LOCK: u32 = 16;
}

/// 所有会话共用的设置（设置界面改了立即生效）。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SessionConfig {
    /// 每页候选个数，3–9（没给 row_width 时）。
    pub page_size: usize,
    /// 一行能放多宽（单位：候选字号的 1/100）。给了就按宽度分页：
    /// 能放几个放几个，最多 9 个（照微信输入法，固定宽度的候选窗不留大片空白）。0 表示按 page_size。
    pub row_width: u32,
    /// 首选候选对得上 emoji 时，在第三个候选插一个。
    pub emoji_suggest: bool,
    /// 紧跟在数字后面的 . 和 : 原样输出（3.14、12:30），不转成中文标点。
    pub ascii_punct_after_digit: bool,
    /// 打字途中按 . 或 @ 进「原样输入」：字母原样拼在编辑区里，候选是整串原样文字（@ 后补全邮箱后缀）。
    pub url_punct: bool,
    /// / 键输入顿号「、」。
    pub slash_dunhao: bool,
    /// （ 【 《 自动补上右半边，光标退回中间（前端要能移动光标才开）。
    pub auto_pair: bool,
    /// 中文和英文字母之间自动加空格。
    pub space_cjk_latin: bool,
    /// 中文和数字之间自动加空格。
    pub space_cjk_digit: bool,
    /// v 加数字转中文数字（v234 → 二百三十四）。微信输入法没有，默认关。
    pub v_number: bool,
}

impl Default for SessionConfig {
    fn default() -> Self {
        Self {
            page_size: 9,
            row_width: 0,
            emoji_suggest: true,
            ascii_punct_after_digit: true,
            url_punct: true,
            slash_dunhao: true,
            auto_pair: false,
            space_cjk_latin: false,
            space_cjk_digit: false,
            v_number: false,
        }
    }
}

static CONFIG: RwLock<SessionConfig> = RwLock::new(SessionConfig {
    page_size: 9,
    row_width: 0,
    emoji_suggest: true,
    ascii_punct_after_digit: true,
    url_punct: true,
    slash_dunhao: true,
    auto_pair: false,
    space_cjk_latin: false,
    space_cjk_digit: false,
    v_number: false,
});

/// 数字后面原样输出的标点（逗号不算：「第 3，」这种中文写法也常见，猜不准）。
/// / 在开了「/ 输入顿号」时也算：2024/1/1 不能变成 2024、1、1。
const ASCII_AFTER_DIGIT: [char; 3] = ['.', ':', '/'];

/// 原样输入时还能接着打进编辑区的符号（字母、数字之外）：网址、邮箱里会出现的。
const RAW_CHARS: &str = "./:-_@?=&#%~+";

/// @ 后补全的邮箱后缀：照微信输入法的表和顺序（2026-11-13 实测）。
const MAIL_DOMAINS: [&str; 15] = [
    "qq.com",
    "163.com",
    "126.com",
    "gmail.com",
    "sina.com",
    "139.com",
    "hotmail.com",
    "outlook.com",
    "yahoo.com",
    "foxmail.com",
    "icloud.com",
    "tencent.com",
    "jd.com",
    "didiglobal.com",
    "alibaba.com",
];

/// 自动补全的成对符号。
const PAIRS: [(&str, &str); 5] = [("（", "）"), ("【", "】"), ("《", "》"), ("“", "”"), ("‘", "’")];

/// 改所有会话的设置。
pub fn configure(config: SessionConfig) {
    let config = SessionConfig {
        page_size: config.page_size.clamp(3, 9),
        ..config
    };
    *CONFIG.write().unwrap_or_else(|e| e.into_inner()) = config;
}

pub fn config() -> SessionConfig {
    *CONFIG.read().unwrap_or_else(|e| e.into_inner())
}

/// 展开时一个候选占几列（1～GRID_COLS）：前端按候选窗里真实的字宽量（`set_grid_span`），和候选窗画的一样。
/// 日期、时间候选（照微信输入法：riqi / rq、shijian / sj 时出一个带日历图标的候选，选它竖排展开各种格式）。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DateKind {
    Date = 0,
    Time = 1,
}

/// 日期、时间的各种格式由前端按本地时区、农历排好给（Rust 这边拿不到本地时区）。
pub type DateFormats = Box<dyn Fn(DateKind) -> Vec<String> + Send + Sync>;

static DATE_FORMATS: RwLock<Option<DateFormats>> = RwLock::new(None);

/// 设上日期时间格式的来源；None 时不出日期时间候选。
pub fn set_date_formats(formats: Option<DateFormats>) {
    *DATE_FORMATS.write().unwrap_or_else(|e| e.into_inner()) = formats;
}

fn date_formats(kind: DateKind) -> Option<Vec<String>> {
    let formats = DATE_FORMATS.read().unwrap_or_else(|e| e.into_inner());
    formats.as_ref().map(|f| f(kind))
}

/// 整串拼音是不是日期、时间的关键词（照微信：全拼和首字母）。
fn date_keyword(input: &str) -> Option<DateKind> {
    match input.replace('\'', "").as_str() {
        "riqi" | "rq" => Some(DateKind::Date),
        "shijian" | "sj" => Some(DateKind::Time),
        _ => None,
    }
}

pub type GridSpan = Box<dyn Fn(&str) -> usize + Send + Sync>;

static GRID_SPAN: RwLock<Option<GridSpan>> = RwLock::new(None);

/// 设上量候选占几列的函数（None 取消，改按估的字宽算）。只在调会话的线程里调用它。
pub fn set_grid_span(span: Option<GridSpan>) {
    *GRID_SPAN.write().unwrap_or_else(|e| e.into_inner()) = span;
}

/// 最近用过的几样（最近的在前），所有会话共用，存在一个文本文件里，一行一个：
/// 最近用过的 emoji、记住的邮箱后缀。
struct RecentList {
    path: Option<PathBuf>,
    items: Vec<String>,
    loaded: bool,
    limit: usize,
}

impl RecentList {
    const fn new(limit: usize) -> Self {
        Self {
            path: None,
            items: Vec::new(),
            loaded: false,
            limit,
        }
    }

    /// 换文件：下次用到时再读。
    fn set_path(&mut self, path: Option<PathBuf>) {
        self.path = path;
        self.items.clear();
        self.loaded = false;
    }

    fn items(&mut self) -> Vec<String> {
        if !self.loaded {
            self.loaded = true;
            if let Some(text) = self.path.as_ref().and_then(|p| std::fs::read_to_string(p).ok()) {
                self.items = text
                    .lines()
                    .filter(|l| !l.is_empty())
                    .take(self.limit)
                    .map(str::to_string)
                    .collect();
            }
        }
        self.items.clone()
    }

    /// 记一样，挪到最前面，马上写回文件。
    fn remember(&mut self, item: &str) {
        if item.is_empty() {
            return;
        }
        self.items(); // 先读进来，别把文件里的覆盖掉
        self.items.retain(|e| e != item);
        self.items.insert(0, item.to_string());
        self.items.truncate(self.limit);
        if let Some(path) = &self.path {
            if let Some(dir) = path.parent() {
                let _ = std::fs::create_dir_all(dir);
            }
            let mut text = self.items.join("\n");
            text.push('\n');
            let _ = std::fs::write(path, text);
        }
    }
}

static RECENT: Mutex<RecentList> = Mutex::new(RecentList::new(RECENT_EMOJI));

/// 指定最近用过的 emoji 存在哪个文件；下次打开表情面板时读。
pub fn set_recent_emoji_path(path: Option<PathBuf>) {
    RECENT.lock().unwrap_or_else(|e| e.into_inner()).set_path(path);
}

fn recent_emoji() -> Vec<String> {
    RECENT.lock().unwrap_or_else(|e| e.into_inner()).items()
}

fn remember_emoji(emoji: &str) {
    RECENT.lock().unwrap_or_else(|e| e.into_inner()).remember(emoji);
}

/// 记住几个用过的邮箱后缀（不在 MAIL_DOMAINS 里的，比如公司邮箱）。
const MAIL_REMEMBERED: usize = 5;

static MAIL: Mutex<RecentList> = Mutex::new(RecentList::new(MAIL_REMEMBERED));

/// 指定记住的邮箱后缀存在哪个文件（只存 @ 后面的后缀，不存用户名）；None 表示不记。
pub fn set_mail_domains_path(path: Option<PathBuf>) {
    MAIL.lock().unwrap_or_else(|e| e.into_inner()).set_path(path);
}

/// 补全用的邮箱后缀：记住的（最近用的在前）排在内置的前面。
fn mail_domains() -> Vec<String> {
    let mut domains = MAIL.lock().unwrap_or_else(|e| e.into_inner()).items();
    domains.extend(MAIL_DOMAINS.iter().map(|d| d.to_string()));
    domains
}

/// 上屏了一个邮箱：后缀不在内置表里、像个域名（qq.com、corp.example.cn）就记住。没设文件时不记。
fn remember_mail_domain(text: &str) {
    let Some((user, domain)) = text.rsplit_once('@') else {
        return;
    };
    let domain = domain.to_ascii_lowercase();
    let looks_like_domain = !user.is_empty()
        && domain.contains('.')
        && !domain.starts_with('.')
        && !domain.ends_with('.')
        && !domain.contains("..")
        && domain.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-');
    if !looks_like_domain || MAIL_DOMAINS.contains(&domain.as_str()) {
        return;
    }
    let mut mail = MAIL.lock().unwrap_or_else(|e| e.into_inner());
    if mail.path.is_some() {
        mail.remember(&domain);
    }
}

/// 表情面板的搜索：query 为空给全部 emoji；否则按拼音（经引擎转成中文词）、英文和
/// 符号名一起找。没有引擎时只按英文和符号名找。
pub fn search_emoji(engine: Option<&Engine>, query: &str, limit: usize) -> Vec<String> {
    let query = query.trim();
    if query.is_empty() {
        return crate::emoji::all()
            .into_iter()
            .take(limit.max(1))
            .map(str::to_string)
            .collect();
    }
    let mut words: Vec<String> = Vec::new();
    if let Some(engine) = engine {
        if query.bytes().all(|b| b.is_ascii_alphabetic() || b == b'\'') {
            let outcome =
                std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| engine.try_input(query)));
            if let Ok(Ok(candidates)) = outcome {
                words = candidates
                    .into_iter()
                    .filter(|c| c.consumed >= query.len() && !c.text.is_ascii())
                    .map(|c| c.text)
                    .take(8)
                    .collect();
            }
        } else if !query.is_ascii() {
            words.push(query.to_string());
        }
    }
    let refs: Vec<&str> = words.iter().map(String::as_str).collect();
    let mut out: Vec<String> = Vec::new();
    let add = |items: Vec<&str>, out: &mut Vec<String>| {
        for item in items {
            if !out.iter().any(|x| x == item) {
                out.push(item.to_string());
            }
        }
    };
    let symbols = crate::symbols::search(query, limit);
    let (named, prefixed): (Vec<_>, Vec<_>) =
        symbols.into_iter().partition(|s| s.names.contains(&query));
    // 符号名完全对上的、关键词完全对上的 emoji、以名字开头的符号、英文、关键词里包含这个词的
    add(named.into_iter().map(|s| s.text).collect(), &mut out);
    add(crate::emoji::search_words_exact(&refs, limit), &mut out);
    add(prefixed.into_iter().map(|s| s.text).collect(), &mut out);
    add(crate::emoji::search_english(query, limit), &mut out);
    add(
        crate::emoji::search_words_containing(&refs, limit),
        &mut out,
    );
    out.truncate(limit.max(1));
    out
}

/// 已经选好、还没上屏的一个词（长句先选开头的词）。
#[derive(Clone, Debug)]
struct Selection {
    text: String,
    /// 学习时记的文字（见 Item::learn）。
    learn: String,
    pinyin: String,
    /// 用掉的原始输入字节数。
    bytes: usize,
}

/// 刚上屏的一次选词，等着看用户是不是马上删掉。
#[derive(Clone, Debug)]
struct Undo {
    /// 这次上屏记了学习的词
    words: Vec<String>,
    /// 上屏了几个字
    chars: usize,
    /// 已经退格删了几个
    deleted: usize,
}

/// 候选列表里的一项。
#[derive(Clone, Debug, Default)]
struct Item {
    text: String,
    pinyin: String,
    /// 用掉了剩余输入的多少字节；小于剩余长度说明是句首词。
    consumed: usize,
    /// emoji 候选：选中时上屏 commit，记进最近用过的 emoji，不学习选词。
    emoji: bool,
    commit: String,
    /// emoji 本身（句尾推荐显示「开心😊」，这里是「😊」）。
    emoji_text: String,
    /// 学习时记的文字：引擎给的原文。和 text 不一样的只有加了空格的混打候选
    /// （显示「我在 GitHub」，引擎里是「我在GitHub」）——按显示的记，引擎下次就对不上了。
    learn: String,
    /// 日期、时间候选：选它不上屏，竖排展开各种格式（快照里带日历图标）。
    date: Option<DateKind>,
}

impl Item {
    fn learn_text(&self) -> &str {
        if self.learn.is_empty() {
            &self.text
        } else {
            &self.learn
        }
    }
}

/// 候选窗现在该怎么画。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    /// 没在输入：候选窗收起。
    Idle,
    /// 普通候选列表（按页显示）。
    List,
    /// 下键展开的网格。
    Grid,
    /// 表情面板（也是网格）。
    Emoji,
}

/// 一个输入框的状态。
#[derive(Debug, Default)]
pub struct Session {
    /// 全部原始输入（包括已经选过词的部分）；表情面板开着时是搜索词。
    buffer: String,
    selections: Vec<Selection>,
    /// 拼音里的编辑光标（buffer 的字节下标，落在音节之间）；None 是在末尾。
    /// 不在末尾时候选只查光标前那段（nihao|ya 出「你好」），照水杉的 MOVE_*_SEGMENT。
    caret: Option<usize>,
    /// 还没选词的拼音的音节分界（buffer 的字节下标），← → 按它移光标。
    cuts: Vec<usize>,
    items: Vec<Item>,
    /// 普通列表的光标（全局下标）；页码由它算出来。
    cursor: usize,
    /// 网格展开着；grid_cursor 是光标所在候选的全局下标。
    expanded: bool,
    grid_cursor: usize,
    emoji_panel: bool,
    /// 最近上屏的文字（或前端给的光标前文字），用作排序的上文。
    recent: String,
    /// 还没交给前端的上屏文字。
    commit: String,
    /// 上次快照以来学了几次选词（前端据此决定什么时候存用户词库）。
    learned: u32,
    /// 上一个键是交给应用的数字（数字不进编辑区，recent 里没有它）。
    after_digit: bool,
    /// 前端这次按键前刚读过光标前的文字（set_context）：判断前一个字是不是数字时也看它。
    context_fresh: bool,
    /// 原样输入：打拼音途中按了 . 或 @，buffer 是原样文字（women.、g@），候选是整串原样文字
    /// 和补全的邮箱。照微信输入法。
    raw: bool,
    /// v 模式（raw 的一种）：v 后面打数字，候选是中文数字（v234 → 二百三十四、贰佰叁拾肆）。
    number: bool,
    /// 选了日期、时间候选：候选换成各种格式，竖排一页放下（照微信）。退格回到拼音的候选。
    date_menu: Option<DateKind>,
    /// 展开前编辑区里分好音节的拼音（ri'qi）：格式没有拼音，分不出来
    date_preedit: String,
    /// 上屏后光标要往左退几个字（自动补全的右括号），随快照交给前端。
    caret_back: u32,
    /// 这次输入里已经记过学习的词（先选了句首词的，上屏时一起交给 undo）。
    learned_words: Vec<String>,
    /// 刚上屏的那次选词：紧接着用退格把它整个删掉，就撤销这次学习（选错了）。
    undo: Option<Undo>,
    /// 下一个中文双引号 / 单引号是不是右半边（“ ” 、‘ ’ 一开一合交替）。换输入框时从左半边开始。
    double_quote_closes: bool,
    single_quote_closes: bool,
}

impl Session {
    pub fn new() -> Self {
        Self::default()
    }

    // MARK: 给前端的接口

    /// 处理一个按键。返回 true 表示吃掉了，false 表示交还给应用。
    pub fn key(&mut self, engine: Option<&Engine>, key: Key, modifiers: u32) -> bool {
        // 前一个字是不是数字：上一个键是数字，或者前端刚读到的光标前那个字是数字（鼠标点到数字后面）。
        // 两样任一成立就算：终端这类应用给的「光标前文字」和屏幕上的对不上，不能只信它
        let context_digit = std::mem::take(&mut self.context_fresh)
            && self.recent.chars().last().is_some_and(|c| c.is_ascii_digit());
        let after_digit = std::mem::take(&mut self.after_digit) || context_digit;
        self.track_undo(engine, key, modifiers);
        if self.emoji_panel {
            return self.emoji_panel_key(engine, key, modifiers);
        }
        // 带 ⌃ ⌥ ⌘ 的组合键交给应用（⌥ 加字母是在打特殊字符）
        if modifiers & (mods::CONTROL | mods::OPTION | mods::COMMAND) != 0 {
            return false;
        }
        if self.date_menu.is_some() {
            if let Some(handled) = self.date_menu_key(engine, key) {
                return handled;
            }
        }
        if self.raw {
            if let Some(handled) = self.raw_key(engine, key, modifiers) {
                return handled;
            }
        }
        // 大写锁定时字母直接交给应用（输出大写）；打到一半的先上屏
        if modifiers & mods::CAPS_LOCK != 0 {
            if let Some(letter) = key.letter() {
                if !self.composing() {
                    return false;
                }
                self.commit_pending(engine);
                self.commit_plain(&letter.to_string());
                return true;
            }
        }

        if self.composing() {
            if self.expanded && self.grid_key(engine, key) {
                return true;
            }
            match key {
                Key::Backspace => {
                    if let Some(at) = self.caret {
                        // 光标在中间：删光标前的那个字母
                        self.buffer.remove(at - 1);
                        self.caret = Some(at - 1);
                        self.resegment(engine);
                    } else if self.remaining().is_empty() && !self.selections.is_empty() {
                        // 撤销最后一次选词，拼音回到编辑区
                        self.selections.pop();
                    } else {
                        self.buffer.pop();
                    }
                    if self.buffer.is_empty() {
                        self.clear();
                    }
                    self.refresh(engine);
                    return true;
                }
                Key::Escape => {
                    self.clear();
                    return true;
                }
                Key::Space => {
                    self.commit_current(engine);
                    return true;
                }
                Key::Return if modifiers & mods::SHIFT != 0 => {
                    // ⇧⏎：和回车一样上屏，但这次不学（照水杉的 COMMIT_RAW_WITHOUT_LEARNING）
                    self.commit_raw_without_learning(engine);
                    return true;
                }
                Key::Return => {
                    // 回车：已选的词 + 原始字母上屏
                    let tail = self.remaining().to_string();
                    self.commit_all(engine, &tail, "");
                    return true;
                }
                Key::Tab => {
                    // 先上屏打了一半的（和切输入法时一样），Tab 再交给应用：表格、表单里照常跳格
                    let tail = self.remaining().to_string();
                    self.commit_all(engine, &tail, "");
                    return false;
                }
                Key::Delete => {
                    // 光标在拼音中间：删光标后的那个字母；在末尾时没东西可删
                    if let Some(at) = self.caret {
                        self.buffer.remove(at);
                        self.resegment(engine);
                        self.refresh(engine);
                    }
                    return true;
                }
                Key::Home => {
                    // 照水杉的 FIRST_CANDIDATE_OR_HOME：先回到第一个候选，已经在第一个时光标到拼音开头
                    // （停在第一个音节后面：光标前没有拼音就没有候选）
                    if self.cursor > 0 {
                        self.cursor = 0;
                    } else {
                        self.caret_home(engine);
                    }
                    return true;
                }
                Key::End => {
                    // 照水杉的 LAST_CANDIDATE：到这一页最后一个候选；没有候选时光标回到拼音末尾
                    if self.items.is_empty() {
                        if self.caret.take().is_some() {
                            self.refresh(engine);
                        }
                    } else {
                        let (start, len) = self.page_bounds();
                        self.cursor = (start + len).saturating_sub(1).max(start);
                    }
                    return true;
                }
                _ => {}
            }
            // 只打了一个 v 再按数字：进 v 模式（双拼里 v 是声母，不算；设置里默认关）
            if let Key::Char(c) = key {
                if c.is_ascii_digit()
                    && config().v_number
                    && self.buffer == "v"
                    && !engine.is_some_and(|e| e.shuangpin())
                {
                    self.buffer.push(c);
                    self.raw = true;
                    self.number = true;
                    self.refresh_raw();
                    return true;
                }
            }
            if let Some(digit) = key.digit() {
                // 数字按当前页选词
                let start = self.page_start();
                if digit >= 1 && digit <= self.page_len() {
                    self.commit_candidate(engine, start + digit - 1);
                }
                return true;
            }
            if matches!(key, Key::Left | Key::Right) && self.caret_key(engine, key == Key::Left) {
                return true;
            }
            if self.list_key(key) {
                return true;
            }
            if let Key::Char(c) = key {
                // 打字途中按标点：先上屏当前候选，再上屏中文标点
                if c != '\'' {
                    if (c == '.' || c == '@') && config().url_punct {
                        self.start_raw(c);
                        return true;
                    }
                    if let Some(punct) = self.quote_for(c).or_else(|| punct_for(c)) {
                        self.commit_pending(engine);
                        self.commit_punct(punct);
                        return true;
                    }
                }
                // 其他可见字符（/ " + _ 等）：先上屏当前候选，再原样上屏
                if c.is_ascii_graphic() && c != '\'' && !c.is_ascii_alphabetic() {
                    self.commit_pending(engine);
                    self.commit_plain(&c.to_string());
                    return true;
                }
            }
            // 编辑区里光标没法移动，这些键吃掉，免得应用里的光标乱跑
            if key.is_cursor_move() || matches!(key, Key::Tab | Key::Delete) {
                return true;
            }
        } else if let Key::Char(c) = key {
            // 数字原样交给应用；记下来，紧跟着的 . 和 : 也原样输出（3.14、12:30）
            if c.is_ascii_digit() {
                self.after_digit = true;
                if self.space_before(c) {
                    // 前面是汉字：带个空格自己上屏
                    self.commit_plain(&c.to_string());
                    return true;
                }
                self.remember_context(&c.to_string());
                return false;
            }
            if after_digit && ASCII_AFTER_DIGIT.contains(&c) && config().ascii_punct_after_digit {
                return false;
            }
            // 没在输入时，ASCII 标点转成中文标点（引号一开一合交替）；没收录的（+ 等）交给应用
            if let Some(punct) = self.quote_for(c).or_else(|| punct_for(c)) {
                self.commit_punct(punct);
                return true;
            }
        }

        let input = match key {
            // 大写字母原样保留：Hello、iPhone 这类英文候选要用到
            Key::Char(c) if c.is_ascii_alphabetic() => c,
            // 隔音符（xi'an）；开头的隔音符没有意义
            Key::Char('\'') if self.composing() => '\'',
            _ => return false,
        };
        if let Some(at) = self.caret {
            // 光标在中间：字母插在光标处
            self.buffer.insert(at, input);
            self.caret = Some(at + 1);
            self.resegment(engine);
        } else {
            self.buffer.push(input);
        }
        self.refresh(engine);
        true
    }

    /// 上屏后紧接着用退格把刚上屏的字整个删掉：选错了，撤销那次学习。
    ///
    /// 不然顺手按空格上屏了排第一的错词、删掉重选，错词和对的词每次都一起加一，
    /// 对的词永远追不上（万象的 context_reorder 也是这么处理的）。
    /// 中间按了任何别的键（包括带修饰键的退格）就不再等。
    fn track_undo(&mut self, engine: Option<&Engine>, key: Key, modifiers: u32) {
        let plain_backspace = key == Key::Backspace
            && modifiers & (mods::CONTROL | mods::OPTION | mods::COMMAND) == 0
            && !self.composing()
            && !self.emoji_panel;
        if !plain_backspace {
            self.undo = None;
            return;
        }
        let Some(undo) = &mut self.undo else {
            return;
        };
        undo.deleted += 1;
        if undo.deleted < undo.chars {
            return;
        }
        if let (Some(engine), Some(undo)) = (engine, self.undo.take()) {
            for word in &undo.words {
                engine.forget_selection(word);
            }
        }
    }

    /// 鼠标点了当前显示的第 index 个候选。
    pub fn select(&mut self, engine: Option<&Engine>, index: usize) -> bool {
        let global = self.display_start() + index;
        if global >= self.items.len() {
            return false;
        }
        if self.emoji_panel {
            self.commit_emoji(global);
        } else if self.date_menu.is_some() {
            self.commit_date(global);
        } else if self.raw {
            self.cursor = global;
            self.commit_raw();
        } else {
            self.commit_candidate(engine, global);
        }
        true
    }

    /// 翻页：delta < 0 上一页，> 0 下一页。网格里一次翻一屏。
    pub fn page(&mut self, delta: i32) -> bool {
        if self.items.is_empty() || delta == 0 || self.date_menu.is_some() {
            return false;
        }
        if self.expanded {
            let key = if delta < 0 {
                Key::PageUp
            } else {
                Key::PageDown
            };
            self.grid_move(key);
            return true;
        }
        if delta < 0 {
            self.prev_page()
        } else {
            self.next_page()
        }
    }

    /// 展开或收起网格（候选窗右边的 ∨ / ∧）：和按下键展开、Esc 收起一样。
    pub fn toggle_grid(&mut self) -> bool {
        if self.emoji_panel || self.date_menu.is_some() || self.items.len() <= 1 {
            return false;
        }
        if self.expanded {
            self.collapse();
        } else {
            self.expanded = true;
            self.grid_cursor = self.cursor;
        }
        true
    }

    /// 前端读到的光标前文字（应用里真实的上下文）。
    pub fn set_context(&mut self, text: &str) {
        self.recent = utf8_tail(text, CONTEXT_BYTES).to_string();
        self.context_fresh = true;
    }

    /// 失去焦点或切走：commit_pending 为 true 时把已选的词和原始字母上屏（切英文、切输入法），
    /// 否则直接清空（失去焦点时不往别的窗口上屏）。
    pub fn reset(&mut self, engine: Option<&Engine>, commit_pending: bool) {
        self.after_digit = false;
        self.undo = None;
        if !commit_pending {
            self.double_quote_closes = false;
            self.single_quote_closes = false;
        }
        if commit_pending && self.composing() && !self.emoji_panel {
            let tail = self.remaining().to_string();
            self.commit_all(engine, &tail, "");
        }
        if !commit_pending {
            // 失去焦点：上文是上一个输入框的，留着会补错空格、排错序
            self.recent.clear();
        }
        self.clear();
    }

    /// 打开或关闭表情面板。打了一半的拼音拿来当搜索词（xiao → 笑相关的 emoji）。
    pub fn toggle_emoji(&mut self, engine: Option<&Engine>) {
        if self.emoji_panel {
            self.clear();
            return;
        }
        let mut query = String::new();
        if self.composing() {
            if self.selections.is_empty() {
                query = self
                    .remaining()
                    .chars()
                    .filter(char::is_ascii_alphabetic)
                    .map(|c| c.to_ascii_lowercase())
                    .collect();
            } else {
                let tail = self.remaining().to_string();
                self.commit_all(engine, &tail, "");
            }
        }
        self.clear();
        self.emoji_panel = true;
        self.buffer = query;
        self.refresh_emoji(engine);
    }

    pub fn mode(&self) -> Mode {
        if self.emoji_panel {
            Mode::Emoji
        } else if !self.composing() {
            Mode::Idle
        } else if self.expanded && !self.items.is_empty() {
            Mode::Grid
        } else {
            Mode::List
        }
    }

    /// 取走要上屏的文字。
    pub fn take_commit(&mut self) -> String {
        std::mem::take(&mut self.commit)
    }

    /// 编辑区：已选的词 + 还没选的拼音（分好音节）。表情面板时是搜索词。
    pub fn preedit(&self) -> String {
        if self.emoji_panel {
            return self.buffer.clone();
        }
        format!("{}{}", self.selected_text(), self.segmented_remaining())
    }

    /// 当前显示的候选（列表是当前页，网格和表情面板是光标所在的一屏）。
    pub fn shown(&self) -> Vec<String> {
        let (start, end) = self.display_range();
        self.items[start..end]
            .iter()
            .map(|i| i.text.clone())
            .collect()
    }

    /// 全部候选（测试用）。
    pub fn all_candidates(&self) -> Vec<String> {
        self.items.iter().map(|i| i.text.clone()).collect()
    }

    /// 当前状态的 JSON 快照，顺带取走要上屏的文字和学习次数。字段见 docs/02-架构设计.md §3。
    pub fn snapshot(&mut self, handled: bool) -> String {
        let commit = self.take_commit();
        let learned = std::mem::take(&mut self.learned);
        let mode = self.mode();
        let (start, end) = self.display_range();
        let cursor = match mode {
            Mode::Grid | Mode::Emoji => self.grid_cursor,
            _ => self.cursor,
        };
        let mut json = String::with_capacity(256 + (end - start) * 24);
        json.push('{');
        push_field(&mut json, "handled", &handled.to_string());
        push_field(&mut json, "commit", &json_string(&commit));
        push_field(&mut json, "learned", &learned.to_string());
        let mode_name = match mode {
            Mode::Idle => "idle",
            Mode::List => "list",
            Mode::Grid => "grid",
            Mode::Emoji => "emoji",
        };
        push_field(&mut json, "mode", &json_string(mode_name));
        let selected = if self.emoji_panel {
            String::new()
        } else {
            self.selected_text()
        };
        let remaining = if self.emoji_panel {
            self.buffer.clone()
        } else {
            self.segmented_remaining()
        };
        push_field(&mut json, "selected", &json_string(&selected));
        push_field(&mut json, "remaining", &json_string(&remaining));
        if let Some(caret) = self.caret_in_preedit().filter(|_| !self.emoji_panel) {
            push_field(&mut json, "caret", &caret.to_string());
        }
        // 日期、时间格式展开时竖排（照微信），别的都是横排
        push_field(&mut json, "horizontal", &self.date_menu.is_none().to_string());
        push_field(
            &mut json,
            "columns",
            &(if matches!(mode, Mode::Grid | Mode::Emoji) {
                GRID_COLS
            } else {
                0
            })
            .to_string(),
        );
        push_field(&mut json, "first", &start.to_string());
        push_field(
            &mut json,
            "cursor",
            &cursor
                .saturating_sub(start)
                .min((end - start).saturating_sub(1))
                .to_string(),
        );
        push_field(&mut json, "total", &self.items.len().to_string());
        push_field(&mut json, "has_prev", &(start > 0).to_string());
        push_field(&mut json, "has_next", &(end < self.items.len()).to_string());
        push_field(&mut json, "raw", &self.raw.to_string());
        push_field(
            &mut json,
            "caret_back",
            &std::mem::take(&mut self.caret_back).to_string(),
        );
        // whole：选了它整串拼音就打完了（句首词只用掉一部分，候选翻译的译文先不让上屏）
        let remaining = self.remaining().len();
        let candidates: Vec<String> = self.items[start..end]
            .iter()
            .map(|item| {
                // icon：日期、时间候选前面画日历图标（SF Symbols 的名字）
                format!(
                    "{{\"text\":{},\"emoji\":{},\"whole\":{}{}}}",
                    json_string(&item.text),
                    item.emoji,
                    item.consumed >= remaining,
                    if item.date.is_some() { ",\"icon\":\"calendar\"" } else { "" }
                )
            })
            .collect();
        if matches!(mode, Mode::Grid | Mode::Emoji) {
            // 展开时这一屏每一行有几个、每个候选占几列（固定列的网格，长词跨列）
            let (starts, spans) = self.grid_layout();
            let rows: Vec<String> = (0..starts.len())
                .filter(|&r| starts[r] >= start && starts[r] < end)
                .map(|r| (starts.get(r + 1).copied().unwrap_or(self.items.len()).min(end) - starts[r]).to_string())
                .collect();
            let shown: Vec<String> = spans[start..end].iter().map(usize::to_string).collect();
            push_field(&mut json, "rows", &format!("[{}]", rows.join(",")));
            push_field(&mut json, "spans", &format!("[{}]", shown.join(",")));
        }
        json.push_str(&format!("\"candidates\":[{}]", candidates.join(",")));
        json.push('}');
        json
    }

    // MARK: 状态

    fn composing(&self) -> bool {
        !self.buffer.is_empty()
    }

    fn selected_bytes(&self) -> usize {
        self.selections.iter().map(|s| s.bytes).sum()
    }

    /// 还没选词的那部分输入。
    fn remaining(&self) -> &str {
        self.buffer.get(self.selected_bytes()..).unwrap_or("")
    }

    fn selected_text(&self) -> String {
        self.selections.iter().map(|s| s.text.as_str()).collect()
    }

    fn clear(&mut self) {
        self.learned_words.clear();
        self.emoji_panel = false;
        self.raw = false;
        self.number = false;
        self.date_menu = None;
        self.buffer.clear();
        self.selections.clear();
        self.caret = None;
        self.cuts.clear();
        self.items.clear();
        self.expanded = false;
        self.grid_cursor = 0;
        self.cursor = 0;
    }

    /// 还没选词的拼音，按第一个用完它的候选分好音节（hengxiang → heng'xiang）。
    /// 显示的还是用户打的字母；英文、双拼等切不了的原样显示。
    fn segmented_remaining(&self) -> String {
        let input = self.remaining();
        if self.raw {
            return input.to_string();
        }
        if self.caret.is_some() {
            return self.caret_display().0;
        }
        if self.date_menu.is_some() {
            return self.date_preedit.clone();
        }
        if let Some(item) = self.items.iter().find(|i| i.consumed >= input.len()) {
            if let Some(shown) = crate::preedit::segment_input(input, &item.pinyin) {
                return shown;
            }
        }
        input.to_string()
    }

    // MARK: 候选

    fn refresh(&mut self, engine: Option<&Engine>) {
        self.items.clear();
        self.expanded = false;
        self.grid_cursor = 0;
        self.cursor = 0;
        self.normalize_caret();
        if self.caret.is_none() {
            self.cuts.clear();
        }
        let input = self.before_caret().to_string();
        let Some(engine) = engine else { return };
        if input.is_empty() {
            return;
        }
        // 已经选了开头的词时，把它当上文，剩下的部分排序更准
        let context = format!("{}{}", self.recent, self.selected_text());
        engine.set_context(utf8_tail(&context, CONTEXT_BYTES));
        let outcome =
            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| engine.try_input(&input)));
        let Ok(Ok(candidates)) = outcome else { return };
        self.items = candidates
            .into_iter()
            .map(|c| Item {
                consumed: if c.consumed == 0 || c.consumed > input.len() {
                    input.len()
                } else {
                    c.consumed
                },
                text: spaced_mixed_text(&c).unwrap_or_else(|| c.text.clone()),
                learn: c.text,
                pinyin: c.pinyin,
                ..Item::default()
            })
            .collect();
        if self.caret.is_none() {
            let start = self.selected_bytes();
            self.cuts = syllable_cuts(&input, &self.segmented_remaining())
                .into_iter()
                .map(|c| start + c)
                .collect();
        } else {
            // 光标在中间时 emoji 只配得上光标前那段，选了会把后面的拼音丢掉，不推荐
            return;
        }
        if config().emoji_suggest {
            self.add_emoji_suggestions(&input);
        }
        if !engine.shuangpin() {
            self.add_date_entry(&input);
        }
    }

    /// 整串拼音是日期、时间的关键词时，插一个带日历图标的候选：排在同名的词后面，没有就排第二（照微信）。
    fn add_date_entry(&mut self, input: &str) {
        if !self.selections.is_empty() {
            return;
        }
        let Some(kind) = date_keyword(input) else {
            return;
        };
        if DATE_FORMATS.read().unwrap_or_else(|e| e.into_inner()).is_none() {
            return;
        }
        let label = match kind {
            DateKind::Date => "日期",
            DateKind::Time => "时间",
        };
        let at = self
            .items
            .iter()
            .position(|i| i.text == label)
            .map_or(1, |i| i + 1)
            .min(self.items.len());
        self.items.insert(
            at,
            Item {
                text: label.to_string(),
                consumed: input.len(),
                date: Some(kind),
                ..Item::default()
            },
        );
    }

    /// 选了日期、时间候选：候选换成各种格式。
    fn open_date_menu(&mut self, kind: DateKind) {
        let formats = date_formats(kind).unwrap_or_default();
        if formats.is_empty() {
            return;
        }
        let consumed = self.remaining().len();
        self.date_preedit = self.segmented_remaining();
        self.items = formats
            .into_iter()
            .map(|text| Item {
                consumed,
                commit: text.clone(),
                text,
                ..Item::default()
            })
            .collect();
        self.date_menu = Some(kind);
        self.cursor = 0;
        self.expanded = false;
    }

    /// 日期、时间格式展开着时的按键（竖排）。None 表示已经上屏，照常处理这个键。
    fn date_menu_key(&mut self, engine: Option<&Engine>, key: Key) -> Option<bool> {
        let last = self.items.len().saturating_sub(1);
        match key {
            Key::Up => self.cursor = self.cursor.saturating_sub(1),
            Key::Down => self.cursor = (self.cursor + 1).min(last),
            Key::Space | Key::Return => self.commit_date(self.cursor),
            Key::Escape => self.clear(),
            Key::Backspace => {
                // 回到拼音的候选
                self.date_menu = None;
                self.refresh(engine);
            }
            _ => {
                if let Some(digit) = key.digit() {
                    if digit >= 1 && digit <= self.items.len() {
                        self.commit_date(digit - 1);
                    }
                    return Some(true);
                }
                if key.is_cursor_move() || matches!(key, Key::Tab | Key::Delete) {
                    return Some(true);
                }
                // 别的键（字母、标点）：先上屏高亮的格式，再照常处理
                self.commit_date(self.cursor);
                return None;
            }
        }
        Some(true)
    }

    /// 上屏一种日期、时间格式（不学）。
    fn commit_date(&mut self, index: usize) {
        let Some(text) = self.items.get(index).map(|i| i.commit.clone()) else {
            return;
        };
        self.undo = None;
        self.clear();
        self.emit(&text);
    }

    // MARK: 拼音里的光标

    /// 光标前、还没选词的那段输入：候选查的就是它。
    fn before_caret(&self) -> &str {
        let start = self.selected_bytes();
        let end = self.caret.unwrap_or(self.buffer.len());
        self.buffer.get(start..end).unwrap_or("")
    }

    /// 光标退到已选的词上或走到末尾就算在末尾。
    fn normalize_caret(&mut self) {
        if self
            .caret
            .is_some_and(|at| at <= self.selected_bytes() || at >= self.buffer.len())
        {
            self.caret = None;
        }
    }

    /// 光标在中间时改了拼音：整串重新查一次，只为了重新分音节（候选还是只要光标前的）。
    fn resegment(&mut self, engine: Option<&Engine>) {
        self.normalize_caret();
        if self.caret.is_none() {
            return;
        }
        self.cuts.clear();
        let input = self.remaining().to_string();
        let Some(engine) = engine else { return };
        let outcome =
            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| engine.try_input(&input)));
        let Ok(Ok(candidates)) = outcome else { return };
        let Some(whole) = candidates
            .iter()
            .find(|c| c.consumed == 0 || c.consumed >= input.len())
        else {
            return;
        };
        if let Some(shown) = crate::preedit::segment_input(&input, &whole.pinyin) {
            let start = self.selected_bytes();
            self.cuts = syllable_cuts(&input, &shown)
                .into_iter()
                .map(|c| start + c)
                .collect();
        }
    }

    /// ← →：照水杉（MsimeSession.arrow）。高亮在首选上 ← 移光标，→ 没到末尾移光标、
    /// 到了末尾交给 list_key 选下一个；高亮不在首选时交给 list_key 只移候选。
    /// 返回 false 表示交给 list_key。
    fn caret_key(&mut self, engine: Option<&Engine>, backwards: bool) -> bool {
        if !self.items.is_empty() {
            let edits = self.cursor == 0 && (backwards || self.caret.is_some());
            if !edits {
                return false;
            }
        }
        let start = self.selected_bytes();
        let at = self.caret.unwrap_or(self.buffer.len());
        // 只停在音节之间，光标前至少留一个音节；切不出音节（英文、单个音节）就不动
        let target = if backwards {
            self.cuts.iter().rev().copied().find(|&c| c > start && c < at)
        } else {
            Some(self.cuts.iter().copied().find(|&c| c > at).unwrap_or(self.buffer.len()))
        };
        if let Some(target) = target.filter(|&t| t != at) {
            self.caret = (target < self.buffer.len()).then_some(target);
            self.refresh(engine);
        }
        true
    }

    /// Home：光标移到第一个音节后面（光标前至少留一个音节）。切不出音节时不动。
    fn caret_home(&mut self, engine: Option<&Engine>) {
        let start = self.selected_bytes();
        let at = self.caret.unwrap_or(self.buffer.len());
        if let Some(target) = self.cuts.iter().copied().find(|&c| c > start && c < at) {
            self.caret = Some(target);
            self.refresh(engine);
        }
    }

    /// 光标在中间时编辑区显示的拼音（光标处不加分隔符：ni'hao|ya）和光标在里面的位置。
    fn caret_display(&self) -> (String, Option<usize>) {
        let start = self.selected_bytes();
        let input = self.remaining();
        let Some(at) = self.caret else {
            return (input.to_string(), None);
        };
        let mut out = String::with_capacity(input.len() + self.cuts.len());
        let mut caret = None;
        for (i, ch) in input.char_indices() {
            let pos = start + i;
            if pos == at {
                caret = Some(out.len());
            } else if self.cuts.contains(&pos)
                && ch != crate::preedit::SEPARATOR
                && !out.ends_with(crate::preedit::SEPARATOR)
            {
                out.push(crate::preedit::SEPARATOR);
            }
            out.push(ch);
        }
        (out, caret)
    }

    /// 快照里的 caret：光标在 remaining（显示的）里的位置，UTF-16；在末尾时 None。
    fn caret_in_preedit(&self) -> Option<usize> {
        if self.raw {
            return None;
        }
        let (shown, caret) = self.caret_display();
        caret.map(|c| shown[..c].encode_utf16().count())
    }

    fn add_emoji_suggestions(&mut self, input: &str) {
        let Some(top) = self.items.first() else {
            return;
        };
        if top.consumed < input.len() {
            return;
        }
        let top = top.text.clone();
        let suggestions: Vec<Item> = crate::emoji::recommend(&top, 1)
            .into_iter()
            .map(|s| Item {
                // 句尾对上时 commit 是「整句 + emoji」
                emoji_text: s
                    .commit
                    .strip_prefix(top.as_str())
                    .unwrap_or(&s.commit)
                    .to_string(),
                text: s.display,
                consumed: input.len(),
                emoji: true,
                commit: s.commit,
                ..Item::default()
            })
            .collect();
        let at = EMOJI_SLOT.min(self.items.len());
        self.items.splice(at..at, suggestions);
    }

    fn refresh_emoji(&mut self, engine: Option<&Engine>) {
        self.items.clear();
        self.grid_cursor = 0;
        self.expanded = true;
        let mut texts: Vec<String> = if self.buffer.is_empty() {
            recent_emoji()
        } else {
            Vec::new()
        };
        for text in search_emoji(engine, &self.buffer, MAX_EMOJI) {
            if !texts.contains(&text) {
                texts.push(text);
            }
        }
        self.items = texts
            .into_iter()
            .map(|text| Item {
                commit: text.clone(),
                emoji_text: text.clone(),
                text,
                emoji: true,
                ..Item::default()
            })
            .collect();
    }

    // MARK: 上屏

    fn commit_plain(&mut self, text: &str) {
        self.emit(text);
    }

    /// 上屏一段文字：和前一个字之间按设置补空格（中文与英文、中文与数字）。
    fn emit(&mut self, text: &str) {
        let Some(first) = text.chars().next() else {
            return;
        };
        if self.space_before(first) {
            self.commit.push(' ');
            self.remember_context(" ");
        }
        self.commit.push_str(text);
        self.remember_context(text);
    }

    /// 接着上屏 next 时要不要先补一个空格：一边是汉字、一边是英文字母（或数字）。
    fn space_before(&self, next: char) -> bool {
        let Some(prev) = self.recent.chars().last() else {
            return false;
        };
        let config = config();
        let pair = |a: char, b: char| is_cjk(a) && b.is_ascii_alphabetic() || a.is_ascii_alphabetic() && is_cjk(b);
        let digit = |a: char, b: char| is_cjk(a) && b.is_ascii_digit() || a.is_ascii_digit() && is_cjk(b);
        (config.space_cjk_latin && pair(prev, next)) || (config.space_cjk_digit && digit(prev, next))
    }

    /// " 和 ' 对应的中文引号：一开一合交替（“ ” ‘ ’）。开了自动补全时总是出左半边（再补上右半边）。
    fn quote_for(&mut self, c: char) -> Option<&'static str> {
        let (open, close, state) = match c {
            '"' => ("“", "”", &mut self.double_quote_closes),
            '\'' => ("‘", "’", &mut self.single_quote_closes),
            _ => return None,
        };
        if config().auto_pair {
            *state = false;
            return Some(open);
        }
        let quote = if *state { close } else { open };
        *state = !*state;
        Some(quote)
    }

    /// 上屏一个中文标点；开了自动补全时补上右半边，让前端把光标退回中间。
    fn commit_punct(&mut self, punct: &str) {
        self.commit_plain(punct);
        if config().auto_pair {
            if let Some((_, close)) = PAIRS.iter().find(|(open, _)| *open == punct) {
                self.commit_plain(close);
                self.caret_back += close.chars().count() as u32;
            }
        }
    }

    // MARK: 原样输入（网址、邮箱）

    /// 打拼音途中按 . 或 @：整串原样字母（已经选过的词也作废，nihao|women → nihaowomen.）接上这个符号。
    fn start_raw(&mut self, c: char) {
        let mut text: String = self.buffer.chars().filter(|&ch| ch != '\'').collect();
        text.push(c);
        self.clear();
        self.buffer = text;
        self.raw = true;
        self.refresh_raw();
    }

    /// 候选：有 @ 时是补全的邮箱（按 @ 后已经打的前缀过滤），否则（或一个都对不上）是原样文字。
    fn refresh_raw(&mut self) {
        self.items.clear();
        self.cursor = 0;
        self.expanded = false;
        let item = |text: String| Item {
            consumed: text.len(),
            commit: text.clone(),
            text,
            ..Item::default()
        };
        if self.number {
            for text in number_candidates(&self.buffer[1..]) {
                self.items.push(item(text));
            }
            return;
        }
        if let Some(at) = self.buffer.rfind('@') {
            // 照微信输入法：开头对得上的后缀，@ 后面还没有 . 时加「打的 + .com」，最后是原样（重复的只留一个）。
            // @ 后面什么都没打时只列后缀。记住的后缀（用过的公司邮箱等）排在内置的前面，这一点微信没有
            let (user, typed) = (&self.buffer[..at], &self.buffer[at + 1..]);
            let mut texts: Vec<String> = mail_domains()
                .iter()
                .filter(|d| d.starts_with(typed))
                .map(|d| format!("{user}@{d}"))
                .collect();
            if !typed.is_empty() {
                if !typed.contains('.') {
                    texts.push(format!("{}.com", self.buffer));
                }
                texts.push(self.buffer.clone());
            }
            for text in texts {
                if !self.items.iter().any(|i| i.text == text) {
                    self.items.push(item(text));
                }
            }
        }
        if self.items.is_empty() {
            self.items.push(item(self.buffer.clone()));
        }
    }

    /// 原样输入时的按键。None 表示照常处理（已经上屏、退出了原样输入）。
    fn raw_key(&mut self, engine: Option<&Engine>, key: Key, modifiers: u32) -> Option<bool> {
        // 选候选和打拼音时一样：展开着走网格（数字键选这一行的第几个），没展开时方向键、翻页键走列表
        // （到这一页最后一个再往后、↓ 展开）。没展开时数字、- = 是要打进去的字，不当选词、翻页键
        if self.expanded && self.grid_key(engine, key) {
            return Some(true);
        }
        if !matches!(key, Key::Char(_)) && self.list_key(key) {
            return Some(true);
        }
        match key {
            Key::Space | Key::Return => {
                self.commit_raw();
                return Some(true);
            }
            Key::Escape => {
                self.clear();
                return Some(true);
            }
            Key::Backspace => {
                self.buffer.pop();
                if self.buffer.is_empty() {
                    self.clear();
                } else if self.number && self.buffer == "v" {
                    // 数字删光了：回到只打了一个 v
                    self.raw = false;
                    self.number = false;
                    self.refresh(engine);
                } else if !self.number && !self.buffer.contains(['.', '@']) {
                    // . @ 都删掉了：回到打拼音
                    self.raw = false;
                    self.refresh(engine);
                } else {
                    self.refresh_raw();
                }
                return Some(true);
            }
            // v 模式只收数字和一个小数点
            Key::Char(c) if self.number && (c.is_ascii_digit() || c == '.' && !self.buffer.contains('.')) => {
                self.buffer.push(c);
                self.refresh_raw();
                return Some(true);
            }
            Key::Char(c) if !self.number && (c.is_ascii_alphanumeric() || RAW_CHARS.contains(c)) => {
                let c = if modifiers & mods::CAPS_LOCK != 0 {
                    c.to_ascii_uppercase()
                } else {
                    c
                };
                self.buffer.push(c);
                self.refresh_raw();
                return Some(true);
            }
            Key::Tab => {
                // 和打拼音时一样：先上屏，Tab 交给应用
                self.commit_raw();
                return Some(false);
            }
            _ => {}
        }
        if key.is_cursor_move() || key == Key::Delete {
            return Some(true);
        }
        // 别的键（逗号等）：先上屏，再照常处理这个键
        self.commit_raw();
        None
    }

    fn commit_raw(&mut self) {
        let text = self
            .items
            .get(self.cursor)
            .map(|i| i.commit.clone())
            .unwrap_or_else(|| self.buffer.clone());
        if !self.number {
            remember_mail_domain(&text);
        }
        self.clear();
        self.commit_plain(&text);
    }

    /// ⇧⏎：已选的词 + 原始字母上屏，不学。分段选的句首词选的时候已经记过，撤掉。
    fn commit_raw_without_learning(&mut self, engine: Option<&Engine>) {
        let text = format!("{}{}", self.selected_text(), self.remaining());
        if let Some(engine) = engine {
            for word in &self.learned_words {
                engine.forget_selection(word);
            }
        }
        self.undo = None;
        self.clear();
        self.emit(&text);
    }

    /// 已选的词 + tail 一起上屏，记录选词、更新上下文，清空状态。
    fn commit_all(&mut self, engine: Option<&Engine>, tail: &str, tail_pinyin: &str) {
        self.commit_all_learning(engine, tail, tail, tail_pinyin);
    }

    /// 同 commit_all；learn_tail 是学习时记的文字（引擎给的原文，见 Item::learn）。
    fn commit_all_learning(
        &mut self,
        engine: Option<&Engine>,
        tail: &str,
        learn_tail: &str,
        tail_pinyin: &str,
    ) {
        let text = format!("{}{}", self.selected_text(), tail);
        if let Some(engine) = engine.filter(|_| !text.is_empty()) {
            let pinyin = (!tail_pinyin.is_empty()).then_some(tail_pinyin);
            // 带上拼音：选够次数后引擎会自动把这个词收进用户词库
            if !learn_tail.is_empty() {
                engine.record_selection_with_pinyin(learn_tail, pinyin);
                self.learned_words.push(learn_tail.to_string());
            }
            if !self.selections.is_empty() && !tail.is_empty() && !tail_pinyin.is_empty() {
                // 分几次选出来的词用一次就记住（四个字以内，更长的整句照常按次数学）
                let mut whole: Vec<&str> =
                    self.selections.iter().map(|s| s.pinyin.as_str()).collect();
                whole.push(tail_pinyin);
                let learn: String = self
                    .selections
                    .iter()
                    .map(|s| s.learn.as_str())
                    .chain([learn_tail])
                    .collect();
                engine.record_composed_word(&learn, &whole.join(" "));
                self.learned_words.push(learn);
            }
            self.learned += 1;
        }
        // 记下这次上屏学了什么：紧接着被退格删光就撤销（track_undo）
        let words = std::mem::take(&mut self.learned_words);
        self.undo = (!words.is_empty()).then(|| Undo {
            words,
            chars: text.chars().count(),
            deleted: 0,
        });
        self.clear();
        self.emit(&text);
    }

    fn commit_candidate(&mut self, engine: Option<&Engine>, index: usize) {
        let Some(chosen) = self.items.get(index).cloned() else {
            return;
        };
        if let Some(kind) = chosen.date {
            self.open_date_menu(kind);
            return;
        }
        if self.raw {
            // 原样输入（网址、邮箱、v 模式）在网格里选的：照原样上屏
            self.cursor = index;
            self.commit_raw();
            return;
        }
        if chosen.emoji {
            self.commit_emoji(index);
            return;
        }
        if chosen.consumed < self.remaining().len() {
            // 句首词：先放进已选栈，剩下的拼音继续选
            if let Some(engine) = engine {
                engine.record_selection_with_pinyin(
                    chosen.learn_text(),
                    (!chosen.pinyin.is_empty()).then_some(chosen.pinyin.as_str()),
                );
                self.learned_words.push(chosen.learn_text().to_string());
            }
            self.selections.push(Selection {
                learn: chosen.learn_text().to_string(),
                text: chosen.text,
                pinyin: chosen.pinyin,
                bytes: chosen.consumed,
            });
            self.refresh(engine);
        } else {
            self.commit_all_learning(engine, &chosen.text, chosen.learn_text(), &chosen.pinyin);
        }
    }

    /// 选中光标所在的候选；没有候选时上屏原始输入。
    fn commit_current(&mut self, engine: Option<&Engine>) {
        if self.items.is_empty() {
            let tail = self.remaining().to_string();
            self.commit_all(engine, &tail, "");
        } else {
            let index = self.cursor.min(self.items.len() - 1);
            self.commit_candidate(engine, index);
        }
    }

    /// 光标停在句首词上时，选完它还剩半句：接着选第一个候选，直到整句上屏。
    fn commit_pending(&mut self, engine: Option<&Engine>) {
        for _ in 0..COMMIT_GUARD {
            if !self.composing() {
                break;
            }
            self.commit_current(engine);
        }
    }

    fn commit_emoji(&mut self, index: usize) {
        let Some(chosen) = self.items.get(index).cloned() else {
            return;
        };
        let text = format!("{}{}", self.selected_text(), chosen.commit);
        self.clear();
        self.commit_plain(&text);
        remember_emoji(&chosen.emoji_text);
    }

    fn remember_context(&mut self, text: &str) {
        let joined = format!("{}{}", self.recent, text);
        self.recent = utf8_tail(&joined, CONTEXT_BYTES).to_string();
    }

    // MARK: 列表翻页和光标

    /// 每页从第几个开始。给了 row_width 时按宽度分（能放几个放几个，最多 9 个），否则每页 page_size 个。
    fn page_starts(&self) -> Vec<usize> {
        let n = self.items.len();
        let config = config();
        let mut starts = vec![0];
        if self.date_menu.is_some() {
            // 日期、时间格式竖排一页放下（最多 7 种）
            return starts;
        }
        if config.row_width > 0 {
            let budget = config.row_width as f32 / 100.0;
            let mut width = 0.0;
            let mut count = 0;
            for (i, item) in self.items.iter().enumerate() {
                let w = estimate_width(&item.text);
                if count == MAX_PAGE || count > 0 && width + w > budget {
                    starts.push(i);
                    width = 0.0;
                    count = 0;
                }
                width += w;
                count += 1;
            }
        } else {
            starts.extend((config.page_size..n).step_by(config.page_size.max(1)));
        }
        starts
    }

    /// 当前页的起点和长度。
    fn page_bounds(&self) -> (usize, usize) {
        let starts = self.page_starts();
        let page = starts.partition_point(|&s| s <= self.cursor).saturating_sub(1);
        let start = starts[page];
        let end = starts.get(page + 1).copied().unwrap_or(self.items.len());
        (start, end.saturating_sub(start))
    }

    fn page_start(&self) -> usize {
        self.page_bounds().0
    }

    fn page_len(&self) -> usize {
        self.page_bounds().1
    }

    fn prev_page(&mut self) -> bool {
        let starts = self.page_starts();
        let page = starts.partition_point(|&s| s <= self.cursor).saturating_sub(1);
        if page == 0 {
            return false;
        }
        self.cursor = starts[page - 1];
        true
    }

    fn next_page(&mut self) -> bool {
        let (start, len) = self.page_bounds();
        if start + len >= self.items.len() {
            return false;
        }
        self.cursor = start + len;
        true
    }

    /// 列表里的方向键和翻页键：左右键移动候选、上下键翻页，下键展开网格。
    ///
    /// 照系统拼音和微信输入法：走到这一页最后一个再往后、或者按翻页键（+ = PageDown），
    /// 不换成下一行，而是展开成网格，光标落在下一个候选上。
    fn list_key(&mut self, key: Key) -> bool {
        if self.items.is_empty() {
            return false;
        }
        let key = page_key_alias(key);
        if key == Key::Down && self.items.len() > 1 {
            // 照微信输入法：下键展开网格，光标停在当前选中的词上
            self.expanded = true;
            self.grid_cursor = self.cursor;
            return true;
        }
        if key == Key::Left && self.cursor > 0 {
            self.cursor -= 1;
            return true;
        }
        if key == Key::Right && self.cursor + 1 < self.items.len() {
            if self.cursor + 1 == self.page_start() + self.page_len() {
                // 这一页最后一个再往后：展开
                self.expand_at(self.cursor + 1);
            } else {
                self.cursor += 1;
            }
            return true;
        }
        if matches!(key, Key::PageUp | Key::Char('-')) || key == Key::Up {
            return self.prev_page();
        }
        if matches!(key, Key::PageDown | Key::Char('=')) {
            // 翻页就是想看更多候选：展开，光标到下一页的第一个
            let (start, len) = self.page_bounds();
            if start + len >= self.items.len() {
                return false;
            }
            self.expand_at(start + len);
            return true;
        }
        false
    }

    fn expand_at(&mut self, cursor: usize) {
        self.expanded = true;
        self.grid_cursor = cursor.min(self.items.len().saturating_sub(1));
    }

    // MARK: 网格（下键展开、表情面板）

    /// 网格开着时的按键：处理了返回 true；打字、退格、回车、标点先收起，返回 false 照常处理。
    fn grid_key(&mut self, engine: Option<&Engine>, key: Key) -> bool {
        if self.items.is_empty() {
            self.expanded = false;
            return false;
        }
        let key = page_key_alias(key);
        match key {
            Key::Up if self.grid_row(self.grid_cursor) == 0 => {
                self.collapse(); // 第一行再往上：收起
                true
            }
            Key::Left
            | Key::Right
            | Key::Up
            | Key::Down
            | Key::PageUp
            | Key::PageDown
            | Key::Char('-')
            | Key::Char('=') => {
                self.grid_move(key);
                true
            }
            Key::Escape => {
                self.collapse();
                true
            }
            Key::Space => {
                self.commit_candidate(engine, self.grid_cursor);
                true
            }
            _ => {
                if let Some(digit) = key.digit() {
                    if let Some(index) = self.grid_digit(digit) {
                        self.commit_candidate(engine, index);
                    }
                    return true;
                }
                self.collapse();
                false
            }
        }
    }

    fn grid_move(&mut self, key: Key) {
        let n = self.items.len();
        let (starts, spans) = self.grid_layout();
        let row = self.grid_row_in(&starts, self.grid_cursor);
        let last = starts.len() - 1;
        let target = match key {
            Key::Left => {
                self.grid_cursor = self.grid_cursor.saturating_sub(1);
                return;
            }
            Key::Right => {
                if self.grid_cursor + 1 < n {
                    self.grid_cursor += 1;
                }
                return;
            }
            Key::Up if row > 0 => row - 1,
            Key::Down if row < last => row + 1,
            Key::PageDown | Key::Char('=') => (row + GRID_ROWS).min(last),
            Key::PageUp | Key::Char('-') => row.saturating_sub(GRID_ROWS),
            _ => return,
        };
        if target == row {
            return;
        }
        // 到目标行里和现在这个候选的中线最近的那个（长词跨列，列对不齐时也走得直）
        let center = |i: usize| {
            let from = starts[self.grid_row_in(&starts, i)];
            let left: usize = spans[from..i].iter().sum();
            left as f32 + spans[i] as f32 / 2.0
        };
        let here = center(self.grid_cursor);
        let end = starts.get(target + 1).copied().unwrap_or(n);
        self.grid_cursor = (starts[target]..end)
            .min_by(|&a, &b| (center(a) - here).abs().total_cmp(&(center(b) - here).abs()))
            .unwrap_or(starts[target]);
    }

    /// 展开时的排法：每一行从第几个候选开始、每个候选占几列。一行 GRID_COLS 列，放不下就换行
    /// （照水杉 macOS 宿主的展开候选：固定列、长词跨列、行尾可以留空）。
    fn grid_layout(&self) -> (Vec<usize>, Vec<usize>) {
        let mut starts = vec![0];
        let mut spans = Vec::with_capacity(self.items.len());
        let mut used = 0;
        for (i, item) in self.items.iter().enumerate() {
            let span = self.grid_span(&item.text);
            if used > 0 && used + span > GRID_COLS {
                starts.push(i);
                used = 0;
            }
            spans.push(span);
            used += span;
        }
        (starts, spans)
    }

    /// 一个候选占几列：表情面板一个一格；别的问前端（`set_grid_span`），没给时按估的字宽和 row_width 算。
    fn grid_span(&self, text: &str) -> usize {
        if self.emoji_panel {
            return 1;
        }
        if let Some(span) = GRID_SPAN.read().unwrap_or_else(|e| e.into_inner()).as_ref() {
            return span(text).clamp(1, GRID_COLS);
        }
        let row = config().row_width;
        if row == 0 {
            return 1;
        }
        let column = row as f32 / 100.0 / GRID_COLS as f32;
        ((estimate_width(text) / column).ceil() as usize).clamp(1, GRID_COLS)
    }

    fn grid_row_in(&self, starts: &[usize], index: usize) -> usize {
        starts.partition_point(|&s| s <= index).saturating_sub(1)
    }

    /// 光标所在的是展开后的第几行。
    fn grid_row(&self, index: usize) -> usize {
        self.grid_row_in(&self.grid_layout().0, index)
    }

    /// 展开时按数字键：光标所在那一行的第 digit 个。
    fn grid_digit(&self, digit: usize) -> Option<usize> {
        let (starts, _) = self.grid_layout();
        let row = self.grid_row_in(&starts, self.grid_cursor);
        let end = starts.get(row + 1).copied().unwrap_or(self.items.len());
        let index = starts[row] + digit.wrapping_sub(1);
        ((1..=GRID_COLS).contains(&digit) && index < end).then_some(index)
    }

    fn collapse(&mut self) {
        self.expanded = false;
        self.cursor = self.grid_cursor;
    }

    fn emoji_panel_key(&mut self, engine: Option<&Engine>, key: Key, modifiers: u32) -> bool {
        if modifiers & (mods::CONTROL | mods::OPTION | mods::COMMAND) != 0 {
            // 别的组合键（复制粘贴等）：收起面板，交给应用
            self.clear();
            return false;
        }
        match key {
            Key::Escape => {
                self.clear();
                return true;
            }
            Key::Backspace => {
                if self.buffer.is_empty() {
                    self.clear();
                    return true;
                }
                self.buffer.pop();
            }
            Key::Char(c) if c.is_ascii_alphabetic() => self.buffer.push(c.to_ascii_lowercase()),
            Key::Return | Key::Space => {
                if self.items.is_empty() {
                    self.clear();
                } else {
                    self.commit_emoji(self.grid_cursor.min(self.items.len() - 1));
                }
                return true;
            }
            Key::Up if self.grid_row(self.grid_cursor) == 0 => return true, // 第一行再往上：不收起
            _ => {
                let navigates = key.digit().is_some()
                    || key.is_cursor_move()
                    || matches!(key, Key::Char('-') | Key::Char('='));
                if navigates && !self.items.is_empty() {
                    if let Some(digit) = key.digit() {
                        if let Some(index) = self.grid_digit(digit) {
                            self.commit_emoji(index);
                        }
                    } else {
                        self.grid_move(key);
                    }
                }
                return true; // 其他键吃掉，免得打进应用
            }
        }
        self.refresh_emoji(engine);
        true
    }

    /// 当前显示范围：列表是当前页，网格是光标所在的一屏。
    fn display_range(&self) -> (usize, usize) {
        let n = self.items.len();
        if n == 0 {
            return (0, 0);
        }
        if self.expanded {
            // 光标所在的一屏：GRID_ROWS 行一屏
            let (starts, _) = self.grid_layout();
            let first = self.grid_row_in(&starts, self.grid_cursor) / GRID_ROWS * GRID_ROWS;
            let end = starts.get(first + GRID_ROWS).copied().unwrap_or(n);
            return (starts[first], end);
        }
        let start = self.page_start();
        (start.min(n), (start + self.page_len()).min(n))
    }

    fn display_start(&self) -> usize {
        self.display_range().0
    }
}

/// 一页最多几个候选（数字键只有 1–9）。
const MAX_PAGE: usize = 9;

/// 一个候选在横排里大概占多宽（单位：候选字号）：序号、留白，加上字（汉字算 1、ASCII 算 0.6、
/// emoji 等算 1.3）。宁可估宽一点：估窄了候选窗会被撑宽。
fn estimate_width(text: &str) -> f32 {
    const OVERHEAD: f32 = 2.1;
    OVERHEAD
        + text
            .chars()
            .map(|c| {
                if c.is_ascii() {
                    0.6
                } else if is_cjk(c) || ('\u{3000}'..='\u{303F}').contains(&c) || ('\u{FF00}'..='\u{FFEF}').contains(&c) {
                    1.0
                } else {
                    1.3
                }
            })
            .sum::<f32>()
}

/// 只留尾部最多 max_bytes 字节，起点对齐到 UTF-8 字符边界。
/// v 模式的候选：读法（二百三十四）、大写（贰佰叁拾肆）、原样数字、逐位（二三四，只在整数时给）。
/// 整数部分太长（超过 16 位）读不了，只给原样和逐位。
fn number_candidates(text: &str) -> Vec<String> {
    let (int, frac) = match text.split_once('.') {
        Some((int, frac)) => (int, Some(frac)),
        None => (text, None),
    };
    let mut out = Vec::new();
    let frac = frac.filter(|f| !f.is_empty());
    if int.len() <= 16 {
        for upper in [false, true] {
            let mut read = read_integer(int, upper);
            if let Some(frac) = frac {
                read.push('点');
                read.extend(frac.bytes().map(|b| cn_digit(b - b'0', upper)));
            }
            out.push(read);
        }
    }
    out.push(text.trim_end_matches('.').to_string());
    if frac.is_none() && int.len() > 1 {
        out.push(int.bytes().map(|b| if b == b'0' { '〇' } else { cn_digit(b - b'0', false) }).collect());
    }
    out.dedup();
    out
}

fn cn_digit(d: u8, upper: bool) -> char {
    let digits = if upper { "零壹贰叁肆伍陆柒捌玖" } else { "零一二三四五六七八九" };
    digits.chars().nth(d as usize).unwrap_or('零')
}

/// 整数的中文读法：每四位一组（万、亿、万亿），中间的零只读一个，10–19 小写读「十几」。
fn read_integer(digits: &str, upper: bool) -> String {
    let digits = digits.trim_start_matches('0');
    if digits.is_empty() {
        return cn_digit(0, upper).to_string();
    }
    let small = if upper { ["仟", "佰", "拾", ""] } else { ["千", "百", "十", ""] };
    let big = ["", "万", "亿", "万亿"];
    let bytes: Vec<u8> = digits.bytes().map(|b| b - b'0').collect();
    let groups = bytes.len().div_ceil(4);
    let mut out = String::new();
    let mut pending_zero = false;
    for g in 0..groups {
        // 从高到低第 g 组，补齐成 4 位
        let end = bytes.len() - (groups - 1 - g) * 4;
        let start = end.saturating_sub(4);
        let mut group = [0u8; 4];
        group[4 - (end - start)..].copy_from_slice(&bytes[start..end]);
        if group == [0; 4] {
            pending_zero = !out.is_empty();
            continue;
        }
        // 上一组之后有零（整组是零，或这一组不满千）：读一个零
        if !out.is_empty() && (pending_zero || group[0] == 0) {
            out.push(cn_digit(0, upper));
        }
        let mut zero = false;
        let mut part = String::new();
        for (i, &d) in group.iter().enumerate() {
            if d == 0 {
                zero = !part.is_empty();
                continue;
            }
            if zero {
                part.push(cn_digit(0, upper));
                zero = false;
            }
            part.push(cn_digit(d, upper));
            part.push_str(small[i]);
        }
        out.push_str(&part);
        out.push_str(big[groups - 1 - g]);
        pending_zero = false;
    }
    if !upper && out.starts_with("一十") {
        out.remove(0);
    }
    out
}

/// 分好音节的显示（ni'hao'ya）对回用户打的字母（nihaoya），得出音节分界的字节下标（2、5）。
/// 用户自己打的隔音符算在前一个音节里，分界在它后面。对不上返回空。
fn syllable_cuts(raw: &str, shown: &str) -> Vec<usize> {
    let sep = crate::preedit::SEPARATOR as u8;
    let raw = raw.as_bytes();
    let mut cuts = Vec::new();
    let mut i = 0;
    for b in shown.bytes() {
        // segment_input 会并掉连着的隔音符
        while i < raw.len() && raw[i] == sep && b != sep {
            i += 1;
            cuts.push(i);
        }
        if i < raw.len() && raw[i] == b {
            i += 1;
            if b == sep {
                cuts.push(i);
            }
        } else if b == sep {
            cuts.push(i);
        } else {
            return Vec::new();
        }
    }
    cuts.retain(|&c| c > 0 && c < raw.len());
    cuts.dedup();
    cuts
}

/// + 和 = 一样是下一页，_ 和 - 一样是上一页（按着 Shift 也能翻页，不当成符号上屏）。
fn page_key_alias(key: Key) -> Key {
    match key {
        Key::Char('+') => Key::Char('='),
        Key::Char('_') => Key::Char('-'),
        other => other,
    }
}

/// 中英混打的候选（我在 | github）：开了「中英文之间加空格」时，英文词和两边的汉字之间加空格。
///
/// 只动引擎拼出来的混打候选（看分词：有一个词的拼音就是它自己的字母）；
/// 词库里本来就带字母的词（T恤、卡拉OK）不动。
fn spaced_mixed_text(candidate: &crate::Candidate) -> Option<String> {
    if !config().space_cjk_latin || candidate.words.len() < 2 {
        return None;
    }
    let english = |w: &crate::CandidateWord| {
        !w.text.is_empty()
            && w.text.bytes().all(|b| b.is_ascii_alphabetic())
            && w.pinyin.eq_ignore_ascii_case(&w.text)
    };
    if !candidate.words.iter().any(english) {
        return None;
    }
    let mut text = String::new();
    for (i, word) in candidate.words.iter().enumerate() {
        if i > 0 {
            let prev = &candidate.words[i - 1];
            let boundary = english(prev) && word.text.chars().next().is_some_and(is_cjk)
                || english(word) && prev.text.chars().last().is_some_and(is_cjk);
            if boundary {
                text.push(' ');
            }
        }
        text.push_str(&word.text);
    }
    // 分词拼起来要和候选对得上（繁体转换等改过文字的不动）
    (text.replace(' ', "") == candidate.text).then_some(text)
}

/// 按键对应的中文标点：/ 在开了「/ 输入顿号」时是「、」，其余见 symbols::fullwidth_punct。
fn punct_for(c: char) -> Option<&'static str> {
    if c == '/' && config().slash_dunhao {
        return Some("、");
    }
    crate::symbols::fullwidth_punct(c)
}

/// 汉字（中日韩统一表意文字，含扩展 A 和兼容区）。中文标点不算。
fn is_cjk(c: char) -> bool {
    matches!(c, '\u{4E00}'..='\u{9FFF}' | '\u{3400}'..='\u{4DBF}' | '\u{F900}'..='\u{FAFF}'
        | '\u{20000}'..='\u{2FFFF}')
}

fn utf8_tail(text: &str, max_bytes: usize) -> &str {
    if text.len() <= max_bytes {
        return text;
    }
    let mut start = text.len() - max_bytes;
    while !text.is_char_boundary(start) {
        start += 1;
    }
    &text[start..]
}

fn push_field(json: &mut String, name: &str, value: &str) {
    json.push('"');
    json.push_str(name);
    json.push_str("\":");
    json.push_str(value);
    json.push(',');
}

fn json_string(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 2);
    out.push('"');
    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

#[cfg(test)]
mod number_tests {
    use super::*;

    #[test]
    fn reads_chinese_numbers() {
        for (n, lower, upper) in [
            ("0", "零", "零"),
            ("7", "七", "柒"),
            ("10", "十", "壹拾"),
            ("12", "十二", "壹拾贰"),
            ("20", "二十", "贰拾"),
            ("234", "二百三十四", "贰佰叁拾肆"),
            ("1005", "一千零五", "壹仟零伍"),
            ("10005", "一万零五", "壹万零伍"),
            ("100000", "十万", "壹拾万"),
            ("1000001", "一百万零一", "壹佰万零壹"),
            ("100010000", "一亿零一万", "壹亿零壹万"),
            ("10000000000", "一百亿", "壹佰亿"),
            ("2024", "二千零二十四", "贰仟零贰拾肆"),
        ] {
            assert_eq!(read_integer(n, false), lower, "{n}");
            assert_eq!(read_integer(n, true), upper, "{n}");
        }
    }

    #[test]
    fn number_candidates_in_order() {
        assert_eq!(number_candidates("234"), ["二百三十四", "贰佰叁拾肆", "234", "二三四"]);
        assert_eq!(number_candidates("12.5"), ["十二点五", "壹拾贰点伍", "12.5"]);
        assert_eq!(number_candidates("12.05"), ["十二点零五", "壹拾贰点零伍", "12.05"]);
        assert_eq!(number_candidates("12."), ["十二", "壹拾贰", "12", "一二"]);
        assert_eq!(number_candidates("2008"), ["二千零八", "贰仟零捌", "2008", "二〇〇八"]);
        assert_eq!(number_candidates("5"), ["五", "伍", "5"]);
        let long = "12345678901234567";
        assert_eq!(number_candidates(long), [long.to_string(), "一二三四五六七八九〇一二三四五六七".into()]);
    }
}
