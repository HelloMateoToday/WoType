//! 拼音音节表、音节切分与输入串预处理。
//!
//! 说明：
//! - 表里使用 ASCII 的 v 表示 ü（例如 nv/lve/jv/yvan）。
//! - 在 WeType 音节表片段的基础上补齐了标准拼音音节，并保留了 WeType 的
//!   扩展音节：yvan/xvan/jvan/qvan、yve/xve/jve/qve、yvn/xvn/jvn/qvn、
//!   yv/xv/jv/qv、lve/nve、hng/hm/ng、fiao/nou/nun。
//! - 隔音符 ' 只用来强制切分边界，不进入音节文本。
//! - 儿化：尾部 r（如 huar）或隔音符后的 r（如 hua'r）会标记前一个音节为儿化。

use std::fmt;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, RwLock};

/// 音节 ID，对应 SYLLABLES 的下标。
pub type SyllableId = u16;

/// 可出现在音节开头的声母（按长度降序，保证 zh/ch/sh 优先于 z/c/s）。
pub const INITIALS: &[&str] = &[
    "zh", "ch", "sh", "b", "p", "m", "f", "d", "t", "n", "l", "g", "k", "h", "j", "q", "x", "r",
    "z", "c", "s", "y", "w",
];

/// 韵母表。必须按字节序升序排列，供二分查找使用。
pub const FINALS: &[&str] = &[
    "a", "ai", "an", "ang", "ao", "e", "ei", "en", "eng", "er", "hm", "hng", "i", "ia", "ian",
    "iang", "iao", "ie", "in", "ing", "iong", "iu", "ng", "o", "ong", "ou", "u", "ua", "uai",
    "uan", "uang", "ue", "ui", "un", "uo", "v", "van", "ve", "vn",
];

/// 整体认读/叹词类音节，不按“声母+韵母”常规拆分。
const WHOLE_SYLLABLES: &[&str] = &["hm", "hng", "ng"];

/// 最长音节长度（zhuang/chuang/shuang = 6）。
pub const MAX_SYLLABLE_LEN: usize = 6;

/// 合法音节表，按字节序升序排列。
///
/// 顺序即音节 ID。新增条目时必须保持有序，单元测试会检查。
pub const SYLLABLES: &[&str] = &[
    "a", "ai", "an", "ang", "ao", "ba", "bai", "ban", "bang", "bao", "bei", "ben", "beng", "bi",
    "bian", "biao", "bie", "bin", "bing", "bo", "bu", "ca", "cai", "can", "cang", "cao", "ce",
    "cen", "ceng", "cha", "chai", "chan", "chang", "chao", "che", "chen", "cheng", "chi", "chong",
    "chou", "chu", "chua", "chuai", "chuan", "chuang", "chui", "chun", "chuo", "ci", "cong", "cou",
    "cu", "cuan", "cui", "cun", "cuo", "da", "dai", "dan", "dang", "dao", "de", "dei", "den",
    "deng", "di", "dia", "dian", "diao", "die", "ding", "diu", "dong", "dou", "du", "duan", "dui",
    "dun", "duo", "e", "ei", "en", "eng", "er", "fa", "fan", "fang", "fei", "fen", "feng", "fiao",
    "fo", "fou", "fu", "ga", "gai", "gan", "gang", "gao", "ge", "gei", "gen", "geng", "gong",
    "gou", "gu", "gua", "guai", "guan", "guang", "gui", "gun", "guo", "ha", "hai", "han", "hang",
    "hao", "he", "hei", "hen", "heng", "hm", "hng", "hong", "hou", "hu", "hua", "huai", "huan",
    "huang", "hui", "hun", "huo", "ji", "jia", "jian", "jiang", "jiao", "jie", "jin", "jing",
    "jiong", "jiu", "ju", "juan", "jue", "jun", "jv", "jvan", "jve", "jvn", "ka", "kai", "kan",
    "kang", "kao", "ke", "kei", "ken", "keng", "kong", "kou", "ku", "kua", "kuai", "kuan", "kuang",
    "kui", "kun", "kuo", "la", "lai", "lan", "lang", "lao", "le", "lei", "leng", "li", "lia",
    "lian", "liang", "liao", "lie", "lin", "ling", "liu", "lo", "long", "lou", "lu", "luan", "lun",
    "luo", "lv", "lve", "ma", "mai", "man", "mang", "mao", "me", "mei", "men", "meng", "mi",
    "mian", "miao", "mie", "min", "ming", "miu", "mo", "mou", "mu", "na", "nai", "nan", "nang",
    "nao", "ne", "nei", "nen", "neng", "ng", "ni", "nian", "niang", "niao", "nie", "nin", "ning",
    "niu", "nong", "nou", "nu", "nuan", "nun", "nuo", "nv", "nve", "o", "ou", "pa", "pai", "pan",
    "pang", "pao", "pei", "pen", "peng", "pi", "pian", "piao", "pie", "pin", "ping", "po", "pou",
    "pu", "qi", "qia", "qian", "qiang", "qiao", "qie", "qin", "qing", "qiong", "qiu", "qu", "quan",
    "que", "qun", "qv", "qvan", "qve", "qvn", "ran", "rang", "rao", "re", "ren", "reng", "ri",
    "rong", "rou", "ru", "rua", "ruan", "rui", "run", "ruo", "sa", "sai", "san", "sang", "sao",
    "se", "sen", "seng", "sha", "shai", "shan", "shang", "shao", "she", "shei", "shen", "sheng",
    "shi", "shou", "shu", "shua", "shuai", "shuan", "shuang", "shui", "shun", "shuo", "si", "song",
    "sou", "su", "suan", "sui", "sun", "suo", "ta", "tai", "tan", "tang", "tao", "te", "tei",
    "teng", "ti", "tian", "tiao", "tie", "ting", "tong", "tou", "tu", "tuan", "tui", "tun", "tuo",
    "wa", "wai", "wan", "wang", "wei", "wen", "weng", "wo", "wu", "xi", "xia", "xian", "xiang",
    "xiao", "xie", "xin", "xing", "xiong", "xiu", "xu", "xuan", "xue", "xun", "xv", "xvan", "xve",
    "xvn", "ya", "yan", "yang", "yao", "ye", "yi", "yin", "ying", "yo", "yong", "you", "yu",
    "yuan", "yue", "yun", "yv", "yvan", "yve", "yvn", "za", "zai", "zan", "zang", "zao", "ze",
    "zei", "zen", "zeng", "zha", "zhai", "zhan", "zhang", "zhao", "zhe", "zhei", "zhen", "zheng",
    "zhi", "zhong", "zhou", "zhu", "zhua", "zhuai", "zhuan", "zhuang", "zhui", "zhun", "zhuo",
    "zi", "zong", "zou", "zu", "zuan", "zui", "zun", "zuo",
];

fn bsearch(table: &'static [&'static str], text: &str) -> Option<usize> {
    table.binary_search_by(|s| (*s).cmp(text)).ok()
}

/// 模糊音规则的种类。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FuzzyKind {
    /// 声母互换，韵母不变（z = zh）。
    Initial,
    /// 韵母互换，声母不变（an = ang）。
    Final,
    /// 整个音节互换（hui = fei）。
    Syllable,
}

/// 一条模糊音规则（设置里的一个开关）。`id` 存进配置文件，形如 `z=zh`。
#[derive(Clone, Copy, Debug)]
pub struct FuzzyRule {
    pub id: &'static str,
    pub kind: FuzzyKind,
    pub a: &'static str,
    pub b: &'static str,
}

const fn rule(id: &'static str, kind: FuzzyKind, a: &'static str, b: &'static str) -> FuzzyRule {
    FuzzyRule { id, kind, a, b }
}

/// 可选的模糊音规则，按设置界面的顺序（声母、韵母、整音节）。
pub const FUZZY_RULES: &[FuzzyRule] = &[
    rule("z=zh", FuzzyKind::Initial, "z", "zh"),
    rule("c=ch", FuzzyKind::Initial, "c", "ch"),
    rule("s=sh", FuzzyKind::Initial, "s", "sh"),
    rule("g=k", FuzzyKind::Initial, "g", "k"),
    rule("h=f", FuzzyKind::Initial, "h", "f"),
    rule("n=l", FuzzyKind::Initial, "n", "l"),
    rule("r=l", FuzzyKind::Initial, "r", "l"),
    rule("an=ang", FuzzyKind::Final, "an", "ang"),
    rule("en=eng", FuzzyKind::Final, "en", "eng"),
    rule("in=ing", FuzzyKind::Final, "in", "ing"),
    rule("an=ai", FuzzyKind::Final, "an", "ai"),
    rule("eng=ong", FuzzyKind::Final, "eng", "ong"),
    rule("ian=iang", FuzzyKind::Final, "ian", "iang"),
    rule("uan=uang", FuzzyKind::Final, "uan", "uang"),
    rule("un=ong", FuzzyKind::Final, "un", "ong"),
    rule("un=iong", FuzzyKind::Final, "un", "iong"),
    rule("hui=fei", FuzzyKind::Syllable, "hui", "fei"),
    rule("huang=wang", FuzzyKind::Syllable, "huang", "wang"),
];

/// 默认开启的规则：平翘舌和前后鼻音（WoType 原来写死的那几组）。
pub const DEFAULT_FUZZY_RULES: &[&str] = &["z=zh", "c=ch", "s=sh", "an=ang", "en=eng", "in=ing", "ian=iang", "uan=uang"];

/// 当前规则下每个音节的规范 ID（同一类里字典序最小的音节）。
struct FuzzyMap {
    canon: Vec<SyllableId>,
    generation: u64,
}

static FUZZY_MAP: RwLock<Option<Arc<FuzzyMap>>> = RwLock::new(None);
static FUZZY_GENERATION: AtomicU64 = AtomicU64::new(0);

fn build_fuzzy_map(rule_ids: &[&str], generation: u64) -> FuzzyMap {
    // 并查集：互相能模糊的音节归成一类（an=ang 和 an=ai 都开时，ai、an、ang 是一类）
    let mut parent: Vec<usize> = (0..SYLLABLES.len()).collect();
    fn find(parent: &mut [usize], mut x: usize) -> usize {
        while parent[x] != x {
            parent[x] = parent[parent[x]];
            x = parent[x];
        }
        x
    }
    let union = |parent: &mut Vec<usize>, a: usize, b: usize| {
        let (ra, rb) = (find(parent, a), find(parent, b));
        // 根取 ID 小的（字典序小的），zhang 的规范形式是 zan
        if ra != rb {
            let (lo, hi) = if ra < rb { (ra, rb) } else { (rb, ra) };
            parent[hi] = lo;
        }
    };
    for rule in FUZZY_RULES.iter().filter(|r| rule_ids.contains(&r.id)) {
        match rule.kind {
            FuzzyKind::Syllable => {
                if let (Some(a), Some(b)) = (bsearch(SYLLABLES, rule.a), bsearch(SYLLABLES, rule.b)) {
                    union(&mut parent, a, b);
                }
            }
            FuzzyKind::Initial | FuzzyKind::Final => {
                for (id, text) in SYLLABLES.iter().enumerate() {
                    let Some((initial, final_)) = split(text) else { continue };
                    let swapped = match rule.kind {
                        FuzzyKind::Initial if initial == rule.a => format!("{}{final_}", rule.b),
                        FuzzyKind::Final if final_ == rule.a => format!("{initial}{}", rule.b),
                        _ => continue,
                    };
                    if let Some(other) = bsearch(SYLLABLES, &swapped) {
                        union(&mut parent, id, other);
                    }
                }
            }
        }
    }
    let canon = (0..SYLLABLES.len()).map(|i| find(&mut parent, i) as SyllableId).collect();
    FuzzyMap { canon, generation }
}

fn fuzzy_map() -> Arc<FuzzyMap> {
    if let Some(map) = FUZZY_MAP.read().unwrap_or_else(|e| e.into_inner()).as_ref() {
        return map.clone();
    }
    let mut slot = FUZZY_MAP.write().unwrap_or_else(|e| e.into_inner());
    slot.get_or_insert_with(|| Arc::new(build_fuzzy_map(DEFAULT_FUZZY_RULES, 0))).clone()
}

/// 换一组模糊音规则（不认识的 id 忽略），返回认出来的条数。词库的模糊索引会在下次查询时重建。
pub fn set_fuzzy_rules(rule_ids: &[&str]) -> usize {
    let known: Vec<&str> = rule_ids.iter().copied().filter(|id| FUZZY_RULES.iter().any(|r| r.id == *id)).collect();
    let generation = FUZZY_GENERATION.fetch_add(1, Ordering::SeqCst) + 1;
    *FUZZY_MAP.write().unwrap_or_else(|e| e.into_inner()) = Some(Arc::new(build_fuzzy_map(&known, generation)));
    known.len()
}

/// 当前模糊音规则的快照：查一大批音节时先取一次，免得每次都拿锁。
#[derive(Clone)]
pub struct FuzzyTable(Arc<FuzzyMap>);

impl FuzzyTable {
    /// 音节在这组规则下的规范 ID。
    pub fn canon(&self, id: SyllableId) -> Option<SyllableId> {
        self.0.canon.get(id as usize).copied()
    }

    /// 规则每换一次加一，词库据此判断模糊索引要不要重建。
    pub fn generation(&self) -> u64 {
        self.0.generation
    }
}

pub fn fuzzy_table() -> FuzzyTable {
    FuzzyTable(fuzzy_map())
}

/// 模糊音归一：把当前规则下互相能模糊的音节映射到同一个规范形式（同一类里字典序最小的音节）。
pub fn fuzzy_canon(text: &str) -> String {
    match bsearch(SYLLABLES, text) {
        Some(id) => SYLLABLES[fuzzy_map().canon[id] as usize].to_string(),
        None => text.to_string(),
    }
}

/// 音节在模糊音下的规范 ID。
pub fn fuzzy_id(id: SyllableId) -> Option<SyllableId> {
    fuzzy_map().canon.get(id as usize).copied()
}

/// 别的写法 -> 表里的写法（照上游 Gloridust/WowType 932ffd2、7cffc5c）。
///
/// - lüe、nüe 照《汉语拼音方案》也写成 lue、nue（u 上省掉两点不会和别的音节混），
///   很多人就这么打；表里用 v 表示 ü，所以这里换成 lve、nve。
/// - j、q、x、y 后面的 ü 写成 u（ju 居、qu 去）。用 v 打（jv、qvan）的人也不少；
///   表里虽然有 jv、qvan 这些扩展音节，词库却都记在 ju、quan 下面，
///   以前打 qv、xv、yv 一个候选都没有。l、n 后面的 v 不动：lv（绿）和 lu（路）是两个音节。
pub fn canonical(text: &str) -> &str {
    match text {
        "lue" => "lve",
        "nue" => "nve",
        "jv" => "ju",
        "jvan" => "juan",
        "jve" => "jue",
        "jvn" => "jun",
        "qv" => "qu",
        "qvan" => "quan",
        "qve" => "que",
        "qvn" => "qun",
        "xv" => "xu",
        "xvan" => "xuan",
        "xve" => "xue",
        "xvn" => "xun",
        "yv" => "yu",
        "yvan" => "yuan",
        "yve" => "yue",
        "yvn" => "yun",
        _ => text,
    }
}

pub fn is_valid(text: &str) -> bool {
    bsearch(SYLLABLES, canonical(text)).is_some()
}

/// 查音节 ID（lue、qv 这样的别的写法也认，见 [`canonical`]）。
pub fn id_of(text: &str) -> Option<SyllableId> {
    bsearch(SYLLABLES, canonical(text)).map(|i| i as SyllableId)
}

/// 把音节拆成声母 + 韵母；零声母音节的声母为空串。
///
/// 返回的字符串都是静态表里的规范形式。
pub fn split(text: &str) -> Option<(&'static str, &'static str)> {
    let text = canonical(text);
    if !is_valid(text) {
        return None;
    }
    if WHOLE_SYLLABLES.contains(&text) {
        let final_ = FINALS[bsearch(FINALS, text)?];
        return Some(("", final_));
    }
    for initial in INITIALS {
        if let Some(rest) = text.strip_prefix(initial) {
            if rest.is_empty() {
                continue;
            }
            if let Some(final_) = bsearch(FINALS, rest) {
                return Some((initial, FINALS[final_]));
            }
        }
    }
    // 零声母：a/an/er 等。
    let final_ = FINALS[bsearch(FINALS, text)?];
    Some(("", final_))
}

/// 一个具体音节。
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Syllable {
    pub id: SyllableId,
    pub text: &'static str,
    pub initial: &'static str,
    pub final_: &'static str,
}

impl Syllable {
    /// 由文本构造音节。
    pub fn from_text(text: &str) -> Option<Self> {
        let id = id_of(text)?;
        let (initial, final_) = split(text)?;
        Some(Self {
            id,
            text: SYLLABLES[id as usize],
            initial,
            final_,
        })
    }

    /// 由 ID 构造音节。
    pub fn from_id(id: SyllableId) -> Option<Self> {
        let text = *SYLLABLES.get(id as usize)?;
        Self::from_text(text)
    }

    /// 首字母（简拼用的那一维）。
    pub fn initial_letter(&self) -> u8 {
        self.text.as_bytes()[0]
    }

    /// 转成词典查询键。
    pub fn query(&self, erhua: bool) -> SyllableQuery {
        SyllableQuery::Full { id: self.id, erhua }
    }
}

/// 音节图/束搜索向词典查询时使用的音节引用。
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SyllableQuery {
    /// 全拼：按音节 ID 精确匹配；儿化单独标记。
    Full { id: SyllableId, erhua: bool },
    /// 简拼：只给出该音节的首字母。
    Jianpin { letter: u8 },
}

impl SyllableQuery {
    /// 用于展示/日志的拼音文本。
    pub fn display(self) -> String {
        match self {
            Self::Full { id, erhua } => {
                let text = Syllable::from_id(id).map(|s| s.text).unwrap_or("?");
                if erhua {
                    format!("{text}r")
                } else {
                    text.to_string()
                }
            }
            Self::Jianpin { letter } => jianpin_text(letter).to_string(),
        }
    }

    pub fn is_jianpin(self) -> bool {
        matches!(self, Self::Jianpin { .. })
    }
}

/// 两字母声母 zh/ch/sh 的简拼在查询里的写法：用大写字母和单字母的 z/c/s 区分开。
///
/// 只打 `z` 时 z 和 zh 开头的音节都算（`zg` -> 中国），打了 `zh` 就只算 zh 开头的
/// （`zhch` -> 支持，`zhchi` -> 支持）。
pub const JIANPIN_ZH: u8 = b'Z';
pub const JIANPIN_CH: u8 = b'C';
pub const JIANPIN_SH: u8 = b'S';

/// 两个字母（zh/ch/sh）对应的简拼写法；不是这三个返回 None。
pub fn jianpin_digraph(first: u8, second: u8) -> Option<u8> {
    match (first, second) {
        (b'z', b'h') => Some(JIANPIN_ZH),
        (b'c', b'h') => Some(JIANPIN_CH),
        (b's', b'h') => Some(JIANPIN_SH),
        _ => None,
    }
}

/// 简拼写法对应的拼音文本（`Z` -> `zh`，`g` -> `g`）。
pub fn jianpin_text(letter: u8) -> &'static str {
    const SINGLE: [&str; 26] = [
        "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r",
        "s", "t", "u", "v", "w", "x", "y", "z",
    ];
    match letter {
        JIANPIN_ZH => "zh",
        JIANPIN_CH => "ch",
        JIANPIN_SH => "sh",
        b'a'..=b'z' => SINGLE[(letter - b'a') as usize],
        _ => "?",
    }
}

/// 简拼写法对应的首字母（词条按首字母建索引）：`Z` -> `z`。
pub fn jianpin_first_letter(letter: u8) -> u8 {
    letter.to_ascii_lowercase()
}

/// 简拼写法是否只认某个两字母声母；是的话返回那个声母。
pub fn jianpin_required_initial(letter: u8) -> Option<&'static str> {
    matches!(letter, JIANPIN_ZH | JIANPIN_CH | JIANPIN_SH).then(|| jianpin_text(letter))
}

/// 候选拼音里的一个音节是不是只打了声母（`z`、`zh`，不算 `zhi`）。
pub fn is_abbrev_syllable(text: &str) -> bool {
    match text.as_bytes() {
        [letter] => is_jianpin_letter(*letter),
        [a, b] => jianpin_digraph(*a, *b).is_some(),
        _ => false,
    }
}

/// 简拼首字母是否合法（a/o/e/i/u/v 不能单独作声母）。
pub fn is_jianpin_letter(letter: u8) -> bool {
    matches!(
        letter,
        b'b' | b'c'
            | b'd'
            | b'f'
            | b'g'
            | b'h'
            | b'j'
            | b'k'
            | b'l'
            | b'm'
            | b'n'
            | b'p'
            | b'q'
            | b'r'
            | b's'
            | b't'
            | b'w'
            | b'x'
            | b'y'
            | b'z'
    )
}

/// 预处理后的输入串。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ParsedInput {
    /// 去掉隔音符后的小写字母。
    pub letters: Vec<u8>,
    /// 必须发生切分的位置（隔音符位置），已去重且升序。
    pub forced_boundaries: Vec<usize>,
    /// 这些位置之前需要附加儿化标记（如 hua'r 中的位置 3）。
    pub erhua_at: Vec<usize>,
}

impl ParsedInput {
    pub fn len(&self) -> usize {
        self.letters.len()
    }

    pub fn is_empty(&self) -> bool {
        self.letters.is_empty()
    }

    pub fn text(&self) -> String {
        String::from_utf8_lossy(&self.letters).into_owned()
    }

    /// [start, end) 内部是否有强制切分点。
    pub fn forced_between(&self, start: usize, end: usize) -> bool {
        self.forced_boundaries.iter().any(|&b| b > start && b < end)
    }

    /// 结束于 pos 的音节是否需要标记儿化。
    pub fn has_erhua(&self, pos: usize) -> bool {
        self.erhua_at.contains(&pos)
    }
}

/// 输入预处理错误。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ParseError {
    InvalidChar(char),
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidChar(c) => write!(f, "非法字符 {c:?}：拼音输入只允许 a-z 和隔音符 '"),
        }
    }
}

impl std::error::Error for ParseError {}

/// 解析输入串：小写 a-z + 隔音符 '。
///
/// 例：
/// - xi'an -> letters=xian, forced=[2]
/// - hua'r -> letters=hua, erhua_at=[3]
/// - huar  -> letters=huar（儿化由音节图识别尾部 r）
/// - r     -> letters=r（前面没有音节时 r 就是普通字母，简拼 r -> 人、日）
pub fn parse(input: &str) -> Result<ParsedInput, ParseError> {
    let mut letters = Vec::with_capacity(input.len());
    let mut forced_boundaries = Vec::new();
    let mut erhua_at = Vec::new();

    for chunk in input.split('\'') {
        if chunk.is_empty() {
            continue;
        }
        // 隔开的一个 r 是儿化标记（hua'r）。前面还没有字母时不是儿化：单独打 r 是简拼，
        // 以前这里报错，整个输入作废，打 r 一个候选都没有。
        if chunk == "r" && !letters.is_empty() {
            let pos = letters.len();
            if !erhua_at.contains(&pos) {
                erhua_at.push(pos);
            }
            continue;
        }

        // 在追加本段之前记录强制边界。
        if !letters.is_empty() {
            let pos = letters.len();
            if forced_boundaries.last().copied() != Some(pos) {
                forced_boundaries.push(pos);
            }
        }
        for c in chunk.chars() {
            if !c.is_ascii_lowercase() {
                return Err(ParseError::InvalidChar(c));
            }
            letters.push(c as u8);
        }
    }

    Ok(ParsedInput {
        letters,
        forced_boundaries,
        erhua_at,
    })
}

#[cfg(test)]
mod tests {
    fn canon_text(map: &FuzzyMap, text: &str) -> &'static str {
        SYLLABLES[map.canon[bsearch(SYLLABLES, text).unwrap()] as usize]
    }

    #[test]
    fn default_fuzzy_rules_keep_old_behaviour() {
        let map = build_fuzzy_map(DEFAULT_FUZZY_RULES, 0);
        assert_eq!(canon_text(&map, "zhang"), "zan");
        assert_eq!(canon_text(&map, "sheng"), "sen");
        assert_eq!(canon_text(&map, "jiang"), "jian");
        assert_eq!(canon_text(&map, "zhuang"), canon_text(&map, "zuan"), "uan=uang 加 z=zh：zhuang 和 zuan 一类");
        // 没开的规则不生效
        assert_ne!(canon_text(&map, "nan"), canon_text(&map, "lan"));
    }

    #[test]
    fn fuzzy_rules_chain_into_classes() {
        // an=ang 和 an=ai 都开：bai、ban、bang 是一类
        let map = build_fuzzy_map(&["an=ang", "an=ai"], 0);
        let ban = canon_text(&map, "ban");
        assert_eq!(canon_text(&map, "bai"), ban);
        assert_eq!(canon_text(&map, "bang"), ban);
        // n=l、r=l：nan、lan、ran 一类
        let map = build_fuzzy_map(&["n=l", "r=l"], 0);
        assert_eq!(canon_text(&map, "nan"), canon_text(&map, "lan"));
        assert_eq!(canon_text(&map, "ran"), canon_text(&map, "lan"));
        // 整音节
        let map = build_fuzzy_map(&["hui=fei", "huang=wang"], 0);
        assert_eq!(canon_text(&map, "hui"), canon_text(&map, "fei"));
        assert_eq!(canon_text(&map, "huang"), canon_text(&map, "wang"));
        assert_ne!(canon_text(&map, "hu"), canon_text(&map, "fu"), "整音节规则不影响别的音节");
        // un=iong：jun 和 jiong
        let map = build_fuzzy_map(&["un=iong"], 0);
        assert_eq!(canon_text(&map, "jun"), canon_text(&map, "jiong"));
    }

    #[test]
    fn every_fuzzy_rule_changes_something() {
        // 每个开关都至少让两个合法音节变成一样，不能有摆设
        for rule in FUZZY_RULES {
            let map = build_fuzzy_map(&[rule.id], 0);
            assert!(
                map.canon.iter().enumerate().any(|(i, &c)| c as usize != i),
                "规则 {} 没有任何效果",
                rule.id
            );
        }
    }

    use super::*;

    #[test]
    fn syllable_table_is_sorted_and_unique() {
        for pair in SYLLABLES.windows(2) {
            assert!(
                pair[0] < pair[1],
                "音节表未排序或重复: {:?} {:?}",
                pair[0],
                pair[1]
            );
        }
        for pair in FINALS.windows(2) {
            assert!(
                pair[0] < pair[1],
                "韵母表未排序或重复: {:?} {:?}",
                pair[0],
                pair[1]
            );
        }
    }

    #[test]
    fn standard_syllables() {
        assert!(is_valid("xian"));
        assert!(is_valid("xi"));
        assert!(is_valid("an"));
        assert!(is_valid("zhuang"));
        assert!(is_valid("nve"));
        assert!(is_valid("lve"));
        assert!(!is_valid("xiann"));
        assert!(!is_valid("abc"));
        assert!(!is_valid(""));
    }

    #[test]
    fn extended_syllables() {
        for s in [
            "yvan", "xvan", "jvan", "qvan", "yve", "xve", "jve", "qve", "yvn", "xvn", "jvn", "qvn",
            "yv", "xv", "jv", "qv", "hng", "hm", "ng", "fiao", "nou", "nun",
        ] {
            assert!(is_valid(s), "扩展音节缺失: {s}");
        }
    }

    #[test]
    fn split_xian_vs_xi_an() {
        assert_eq!(split("xian"), Some(("x", "ian")));
        assert_eq!(split("xi"), Some(("x", "i")));
        assert_eq!(split("an"), Some(("", "an")));
        assert_eq!(split("er"), Some(("", "er")));
        assert_eq!(split("zhuang"), Some(("zh", "uang")));
        // jv、yvan 是 ju、yuan 的别的写法，按表里的写法拆
        assert_eq!(split("yvan"), Some(("y", "uan")));
        assert_eq!(split("jv"), Some(("j", "u")));
        assert_eq!(split("hng"), Some(("", "hng")));
    }

    #[test]
    fn parse_apostrophe_forces_boundary() {
        let p = parse("xi'an").unwrap();
        assert_eq!(p.letters, b"xian");
        assert_eq!(p.forced_boundaries, vec![2]);
        assert!(p.forced_between(0, 4));
        assert!(!p.forced_between(0, 2));
    }

    #[test]
    fn parse_erhua_marker() {
        let p = parse("hua'r").unwrap();
        assert_eq!(p.letters, b"hua");
        assert!(p.erhua_at.contains(&3));
        assert!(p.forced_boundaries.is_empty());
    }

    #[test]
    fn parse_rejects_non_lowercase() {
        assert_eq!(parse("Xian"), Err(ParseError::InvalidChar('X')));
        assert_eq!(parse("xi1an"), Err(ParseError::InvalidChar('1')));
    }

    #[test]
    fn parse_lone_r_is_a_letter() {
        assert_eq!(parse("r").unwrap().letters, b"r");
        assert!(parse("r").unwrap().erhua_at.is_empty());
        assert_eq!(parse("'r").unwrap().letters, b"r");
    }

    #[test]
    fn alternative_spellings_map_to_the_table() {
        // lüe、nüe 也能写成 lue、nue
        assert_eq!(id_of("lue"), id_of("lve"));
        assert_eq!(id_of("nue"), id_of("nve"));
        assert_eq!(Syllable::from_text("lue").map(|s| s.text), Some("lve"));
        assert_eq!(split("nue"), Some(("n", "ve")));
        // j q x y 后面的 ü 用 v 打：和 u 是同一个音节
        for (v, u) in [("jv", "ju"), ("qv", "qu"), ("xv", "xu"), ("yv", "yu"), ("qvan", "quan"), ("xve", "xue"), ("jvn", "jun")] {
            assert_eq!(id_of(v), id_of(u), "{v} 应等于 {u}");
        }
        // l、n 后面的 v 不动：lv（绿）和 lu（路）是两个音节
        assert_ne!(id_of("lv"), id_of("lu"));
        assert_ne!(id_of("nv"), id_of("nu"));
    }
}
