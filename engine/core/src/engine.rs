//! 旧的万象拼音引擎本体（docs/15），原来就写在 lib.rs 里。
//!
//! 输入预处理 -> 音节图 -> 束搜索（词典 + 二元 LM） -> 特征/线性打分 -> 候选。
//! 2026-11-15 起「万象」改用 librime（docs/22），这里只在 `--features wanxiang` 时编译，留着方便恢复。

use crate::mixed::MixedWord;
use std::collections::hash_map::Entry;
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, RwLock};
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::Result;

pub use crate::beam::{beam_search, beam_search_with_context, BeamConfig, BeamPath, BeamWord};
pub use crate::convert::Converter;
pub use crate::graph::{Edge, EdgeKind, GraphMode, GraphOptions, SyllableGraph};
pub use crate::learn::{LearnedLm, UserPairs};
pub use crate::lexicon::{
    FuzzyLexicon, LexEntry, Lexicon, MemoryLexicon, SyllableKey, UserLexicon,
};
pub use crate::lm::{ArpaLm, BigramLm, LanguageModel};
pub use crate::rank::{
    Feature, FeatureWeights, LinearRanker, LtrModel, Ranker, FEATURE_COUNT, FEATURE_NAMES,
};
pub use crate::syllable::{
    is_valid, parse, split, ParseError, ParsedInput, Syllable, SyllableId, SyllableQuery, SYLLABLES,
};

/// 最终候选。
#[derive(Clone, Debug)]
pub struct Candidate {
    pub text: String,
    pub pinyin: String,
    pub score: f64,
    pub features: Feature,
    pub words: Vec<CandidateWord>,
    /// 这个候选用掉了原始输入的前多少字节。
    ///
    /// 整句候选等于输入长度；句首词候选（长句先选「你好」，剩下的接着打）更短，
    /// 前端上屏后应把剩余部分留在输入框里继续转换。
    pub consumed: usize,
}

/// 候选内的一个分词。
#[derive(Clone, Debug)]
pub struct CandidateWord {
    pub text: String,
    pub pinyin: String,
    pub freq: f64,
    pub known: bool,
}

/// 引擎配置。
#[derive(Clone, Debug)]
pub struct EngineConfig {
    pub beam: BeamConfig,
    pub max_candidates: usize,
    /// 全拼走不通时是否尝试简拼（zg -> 中国）。
    pub jianpin_fallback: bool,
    /// 是否启用模糊音（z/zh、c/ch、s/sh、an/ang、en/eng、in/ing）。
    pub fuzzy: bool,
    /// 靠模糊音才对上的词，每个词扣多少分（自然对数）。原样对上的不扣。
    /// 6 是用评测语料扫出来的（docs/05）：再小，正常拼对的句子会被模糊音组出来的句子抢首选。
    pub fuzzy_penalty: f64,
    /// 是否使用双拼（自然码方案）。
    pub shuangpin: bool,
    /// 是否在候选末尾追加原始输入（英文/未登录串）。
    pub english_candidate: bool,
    /// 是否把候选转成繁体。
    pub traditional: bool,
    /// 选词达到阈值后自动加入用户词库。
    pub auto_learn: bool,
    /// 自动学习阈值（选多少次后进用户词库）。
    pub auto_learn_threshold: u32,
    /// 按错键纠错（相邻键、两键按反、多按/漏按）。双拼下不生效。
    pub typo_correction: bool,
    /// 句首词候选最多几个（0 表示不给）。长句打错时可以先选开头的词。
    pub prefix_candidates: usize,
    /// 前面几页之后把剩下的词全补上（整个输入的同音词、句首词、单字），直到
    /// `max_candidates`。关掉时只给最可能的那几页。
    pub more_candidates: bool,
    /// 有神经语言模型时，按束搜索分数取前几条整句用它重排（0 表示不用）。
    pub nnlm_rerank: usize,
}

/// 分几次选出来的词，多长以内用一次就学（人名、术语、成语大多在四个字以内）。
pub const COMPOSED_WORD_MAX_CHARS: usize = 4;

impl Default for EngineConfig {
    fn default() -> Self {
        Self {
            beam: BeamConfig::default(),
            max_candidates: 10,
            jianpin_fallback: true,
            fuzzy: false,
            fuzzy_penalty: 6.0,
            shuangpin: false,
            english_candidate: true,
            traditional: false,
            auto_learn: true,
            auto_learn_threshold: 3,
            typo_correction: true,
            prefix_candidates: 16,
            more_candidates: true,
            nnlm_rerank: 8,
        }
    }
}

/// 用户历史里的一条记录。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct HistoryEntry {
    pub count: u32,
    /// 上次使用时间（epoch 毫秒）。
    pub last_used_ms: u64,
}

/// 当前时间（epoch 毫秒）。
pub fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// 拼音引擎。
/// 前端提供的「这个字画不画得出来」。
pub type GlyphCheck = Box<dyn Fn(char) -> bool + Send + Sync>;

pub struct Engine {
    /// 原始词库（只读）。
    base_lexicon: Arc<dyn Lexicon>,
    /// 基础词库 + 用户词的合并视图，束搜索实际用它。
    lexicon: Arc<UserLexicon>,
    lm: Arc<dyn LanguageModel>,
    ranker: Arc<dyn Ranker>,
    config: EngineConfig,
    /// 用户选词历史：候选文本 -> (次数, 上次时间)。
    history: RwLock<HashMap<String, HistoryEntry>>,
    /// 光标前已上屏的文本，用于上下文 bigram 特征。
    context: RwLock<String>,
    /// 用户学到的词搭配（上一个词 -> 这个词）。
    pairs: RwLock<UserPairs>,
    /// 最近一次选的词的最后一个词；光标前的文本以它结尾时，下一个词和它组成搭配。
    last_word: RwLock<String>,
    /// 上一次 input() 给出的候选：文本 -> 分词，选词时用它知道整句是哪几个词。
    last_words: RwLock<HashMap<String, Vec<String>>>,
    /// 靠模糊音选的词，连同当时打的拼音（只留字母）一起记：(输入, 词) -> 热度。
    /// 模糊音对上的候选只看这份，不看 `history`：打 lixian 选过「离线」，打 lixiang 不该因此排第一；
    /// 打 yinshi 选过「硬是」，下次打 yinshi 它排前面。见 [`Engine::record_selection_at`]。
    fuzzy_picks: RwLock<HashMap<(String, String), HistoryEntry>>,
    /// 上一次 input() 的输入（只留字母）和其中靠模糊音对上的候选文本，选词时用它判断是不是模糊音选的。
    last_fuzzy: RwLock<(String, HashSet<String>)>,
    /// 简繁字符映射表。
    converter: RwLock<Arc<Converter>>,
    /// 英文词表：小写编码 -> 上屏形式（github -> GitHub）。
    english: RwLock<Arc<crate::english::EnglishWords>>,
    /// 混合编码词表：编码里有字母的词（Azuo -> A座）。
    mixed: RwLock<Arc<crate::mixed::MixedWords>>,
    /// 快捷短语：编码（小写字母）-> 短语，按添加的先后（`set_quick_phrases`）。
    quick_phrases: RwLock<Arc<HashMap<String, Vec<String>>>>,
    /// 前端说哪些字画得出来（`set_glyph_check`），和问过的结果。
    glyph_check: RwLock<Option<GlyphCheck>>,
    glyph_known: RwLock<HashMap<char, bool>>,
    /// 字级神经语言模型（微信输入法的 nlrgpt2，本机有才加载），给整句候选重排。
    nnlm: RwLock<Option<Arc<crate::nnlm::Nnlm>>>,
}

impl Engine {
    pub fn new(lexicon: Arc<dyn Lexicon>, lm: Arc<dyn LanguageModel>) -> Self {
        let merged = Arc::new(UserLexicon::new(lexicon.clone()));
        Self {
            base_lexicon: lexicon,
            lexicon: merged,
            lm,
            ranker: Arc::new(LinearRanker::default()),
            config: EngineConfig::default(),
            history: RwLock::new(HashMap::new()),
            context: RwLock::new(String::new()),
            pairs: RwLock::new(UserPairs::default()),
            last_word: RwLock::new(String::new()),
            last_words: RwLock::new(HashMap::new()),
            fuzzy_picks: RwLock::new(HashMap::new()),
            last_fuzzy: RwLock::new((String::new(), HashSet::new())),
            converter: RwLock::new(Arc::new(Converter::new())),
            english: RwLock::new(Arc::new(crate::english::EnglishWords::default())),
            mixed: RwLock::new(Arc::new(crate::mixed::MixedWords::default())),
            quick_phrases: RwLock::new(Arc::new(HashMap::new())),
            glyph_check: RwLock::new(None),
            glyph_known: RwLock::new(HashMap::new()),
            nnlm: RwLock::new(None),
        }
    }

    /// 加载微信输入法的字级神经语言模型（`nlrgpt2_nnlm.bin`），返回字表大小。
    /// 模型不随 WoType 分发，见 `docs/DATA.md`。
    pub fn load_nnlm<P: AsRef<std::path::Path>>(&self, path: P) -> Result<usize> {
        let model = crate::nnlm::Nnlm::load(path)?;
        let size = model.vocab_size();
        self.set_nnlm(Some(Arc::new(model)));
        Ok(size)
    }

    pub fn set_nnlm(&self, model: Option<Arc<crate::nnlm::Nnlm>>) {
        if let Ok(mut slot) = self.nnlm.write() {
            *slot = model;
        }
    }

    pub fn has_nnlm(&self) -> bool {
        self.nnlm.read().map(|m| m.is_some()).unwrap_or(false)
    }

    /// 设置光标前的文本（上一次上屏的内容）。
    pub fn set_context(&self, text: &str) {
        if let Ok(mut slot) = self.context.write() {
            slot.clear();
            slot.push_str(text);
        }
    }

    pub fn context(&self) -> String {
        self.context.read().map(|s| s.clone()).unwrap_or_default()
    }

    /// 记录一次选词，用于历史特征。时间戳取当前时间。
    pub fn record_selection(&self, word: &str) {
        self.record_selection_at(word, now_ms());
    }

    /// 记录选词；当同一个词选够次数后自动加入用户词库。
    ///
    /// pinyin 是这次上屏时输入的拼音（用于生成用户词条）。词库里已有的词也会被
    /// 加成用户词——这等价于「记住用户的偏好」，不会覆盖原词条。
    pub fn record_selection_with_pinyin(&self, word: &str, pinyin: Option<&str>) {
        self.record_selection(word);
        if !self.config.auto_learn || word.is_empty() {
            return;
        }
        let Some(pinyin) = pinyin.filter(|p| !p.trim().is_empty()) else {
            return;
        };
        let count = self.history_count(word);
        if count < self.config.auto_learn_threshold.max(1) {
            return;
        }
        self.add_learned_word(word, pinyin, count);
    }

    /// 学到的词收进用户词库。count 是选用次数，决定频次。
    fn add_learned_word(&self, word: &str, pinyin: &str, count: u32) {
        // 双拼模式下上游传进来的是键位串（如 "vsgo"），要先展开成全拼，
        // 否则用户词会带着一串无效音节存进去，永远也打不出来。
        let pinyin = if self.config.shuangpin {
            crate::shuangpin::to_full_pinyin(pinyin)
        } else {
            pinyin.to_string()
        };
        if pinyin.trim().is_empty() {
            return;
        }
        // 频次随选用次数增长但有上限，避免用户词压过通用高频词
        let freq = (1000.0 * f64::from(count)).min(50_000.0);
        let _ = self.lexicon.add(&pinyin, word, freq);
    }

    /// 用户分几次选出来、拼成的一个词（最多 [`COMPOSED_WORD_MAX_CHARS`] 个字）（「霜」「频」「阁」→ 霜频阁）：
    /// 记一次选词，并且马上收进用户词库，不用等选够 [`EngineConfig::auto_learn_threshold`] 次。
    ///
    /// 用户特意一段一段挑出来的，就是想要这个词；一次就打出来的整句不走这里，还是按次数学。
    /// 上屏后紧接着退格删掉（[`Engine::forget_selection`]）时次数回到 0，照样从用户词库拿掉。
    /// 照上游 Gloridust/WowType 19eb3a0（#107）。
    pub fn record_composed_word(&self, word: &str, pinyin: &str) {
        // 超过四个字的多半是先选句首词、再选剩下的长句，不是要造的词：照常按次数学
        if word.chars().count() > COMPOSED_WORD_MAX_CHARS {
            self.record_selection_with_pinyin(word, Some(pinyin));
            return;
        }
        self.record_selection(word);
        if !self.config.auto_learn || word.is_empty() || pinyin.trim().is_empty() {
            return;
        }
        // 至少给到「选够次数」那一档的频次，下次一打就排前面
        let count = self
            .history_count(word)
            .max(self.config.auto_learn_threshold.max(1));
        self.add_learned_word(word, pinyin, count);
    }

    /// 带时间戳的选词记录（方便测试）。
    ///
    /// 记两样：这个词的热度，和它跟前后词的搭配（见 [`learn`]）。
    pub fn record_selection_at(&self, word: &str, at_ms: u64) {
        if word.is_empty() {
            return;
        }
        if let Ok(mut history) = self.history.write() {
            let entry = history.entry(word.to_string()).or_insert(HistoryEntry {
                count: 0,
                last_used_ms: at_ms,
            });
            // 先按时间衰减再加 1：很久以前用得多的词不会一直顶着
            let kept = crate::learn::decayed(*entry, at_ms).round() as u32;
            entry.count = kept.saturating_add(1);
            entry.last_used_ms = at_ms;
        }
        // 上一次的候选里它是靠模糊音对上的：另记一份（输入, 词），只在同样的输入上往前提
        let fuzzy_key = self
            .last_fuzzy
            .read()
            .ok()
            .filter(|last| last.1.contains(word))
            .map(|last| (last.0.clone(), word.to_string()));
        if let (Some(key), Ok(mut picks)) = (fuzzy_key, self.fuzzy_picks.write()) {
            let entry = picks.entry(key).or_insert(HistoryEntry {
                count: 0,
                last_used_ms: at_ms,
            });
            let kept = crate::learn::decayed(*entry, at_ms).round() as u32;
            entry.count = kept.saturating_add(1);
            entry.last_used_ms = at_ms;
        }
        // 这个候选是哪几个词拼的（整句「我发给你」= 我 | 发给 | 你）
        let words: Vec<String> = self
            .last_words
            .read()
            .ok()
            .and_then(|m| m.get(word).cloned())
            .filter(|w| !w.is_empty())
            .unwrap_or_else(|| vec![word.to_string()]);
        let start = self.start_word();
        if let Ok(mut pairs) = self.pairs.write() {
            if let Some(prev) = &start {
                pairs.learn(prev, &words[0], at_ms);
            }
            for pair in words.windows(2) {
                pairs.learn(&pair[0], &pair[1], at_ms);
            }
        }
        if let (Ok(mut last), Some(tail)) = (self.last_word.write(), words.last()) {
            last.clear();
            last.push_str(tail);
        }
    }

    /// 光标前的最后一个词：上一次选的词，而且光标前的文本正好以它结尾
    /// （中间换了输入框、删了字，就不算）。
    fn start_word(&self) -> Option<String> {
        let last = self.last_word.read().ok()?.clone();
        if last.is_empty() {
            return None;
        }
        let context = self.context.read().ok()?;
        context.trim_end().ends_with(&last).then_some(last)
    }

    /// 学到的搭配数。
    pub fn pair_count(&self) -> usize {
        self.pairs.read().map(|p| p.len()).unwrap_or(0)
    }

    /// 把用户输入习惯（词的热度、词搭配）存到 TSV。
    pub fn save_history<P: AsRef<std::path::Path>>(&self, path: P) -> Result<()> {
        let history = self
            .history
            .read()
            .map_err(|_| anyhow::anyhow!("history lock poisoned"))?;
        let pairs = self
            .pairs
            .read()
            .map_err(|_| anyhow::anyhow!("pairs lock poisoned"))?;
        let fuzzy = self
            .fuzzy_picks
            .read()
            .map_err(|_| anyhow::anyhow!("fuzzy picks lock poisoned"))?;
        crate::learn::save_history(path, &history, &pairs, &fuzzy)
    }

    /// 读回 [`Engine::save_history`] 存的输入习惯，返回条数。
    pub fn load_history<P: AsRef<std::path::Path>>(&self, path: P) -> Result<usize> {
        let mut history = self
            .history
            .write()
            .map_err(|_| anyhow::anyhow!("history lock poisoned"))?;
        let mut pairs = self
            .pairs
            .write()
            .map_err(|_| anyhow::anyhow!("pairs lock poisoned"))?;
        let mut fuzzy = self
            .fuzzy_picks
            .write()
            .map_err(|_| anyhow::anyhow!("fuzzy picks lock poisoned"))?;
        crate::learn::load_history(path, &mut history, &mut pairs, &mut fuzzy)
    }

    pub fn history_count(&self, word: &str) -> u32 {
        self.history
            .read()
            .ok()
            .and_then(|h| h.get(word).map(|e| e.count))
            .unwrap_or(0)
    }

    pub fn with_config(mut self, config: EngineConfig) -> Self {
        self.config = config;
        self
    }

    pub fn with_ranker(mut self, ranker: Arc<dyn Ranker>) -> Self {
        self.ranker = ranker;
        self
    }

    pub fn set_beam_size(&mut self, beam_size: usize) {
        self.config.beam.beam_size = beam_size.max(1);
    }

    /// 开关模糊音。
    pub fn set_fuzzy(&mut self, on: bool) {
        self.config.fuzzy = on;
    }

    pub fn set_typo_correction(&mut self, on: bool) {
        self.config.typo_correction = on;
    }

    /// 开关双拼（自然码）。
    pub fn set_shuangpin(&mut self, on: bool) {
        self.config.shuangpin = on;
    }

    /// 开关繁体输出。
    pub fn set_traditional(&mut self, on: bool) {
        self.config.traditional = on;
    }

    /// 载入简繁映射表，返回条目数。
    /// 载入英文词表，返回词条数。
    ///
    /// 每行一个词；也直接接受 rime 的 en.dict.yaml（「上屏<TAB>编码」，
    /// 注释和 YAML 头会被跳过）。只收 2~32 个字母的编码。
    pub fn load_english<P: AsRef<std::path::Path>>(&self, path: P) -> Result<usize> {
        let text = std::fs::read_to_string(path)?;
        Ok(self.load_english_str(&text))
    }

    /// 从字符串载入英文词表（追加），返回累计词条数。
    pub fn load_english_str(&self, text: &str) -> usize {
        let current = self
            .english
            .read()
            .map(|words| words.clone())
            .unwrap_or_default();
        let words = Arc::new(current.extended(text));
        let len = words.len();
        if let Ok(mut slot) = self.english.write() {
            *slot = words;
        }
        len
    }

    /// 让前端说一个字画不画得出来；画不出来的字（系统字体里没有，显示成 ?）不出候选。
    ///
    /// 万象的单字表有四万多字，其中一万五千多个扩展区的字 macOS 自带字体里没有。
    /// 只问 U+20000 以后的字（基本平面的字体里都有），每个字只问一次。
    pub fn set_glyph_check(&self, check: Option<GlyphCheck>) {
        if let Ok(mut slot) = self.glyph_check.write() {
            *slot = check;
        }
        if let Ok(mut known) = self.glyph_known.write() {
            known.clear();
        }
    }

    fn drop_unrenderable(&self, candidates: &mut Vec<Candidate>) {
        let rare = |c: char| c as u32 >= 0x20000;
        if !candidates.iter().any(|c| c.text.chars().any(rare)) {
            return;
        }
        let Ok(check) = self.glyph_check.read() else {
            return;
        };
        let Some(check) = check.as_ref() else {
            return;
        };
        let Ok(mut known) = self.glyph_known.write() else {
            return;
        };
        candidates.retain(|c| {
            c.text
                .chars()
                .filter(|ch| rare(*ch))
                .all(|ch| *known.entry(ch).or_insert_with(|| check(ch)))
        });
    }

    /// 载入混合编码词表（万象的 `dicts/mixed.dict.yaml`），整份替换，返回词条数。
    pub fn load_mixed<P: AsRef<std::path::Path>>(&self, path: P) -> Result<usize> {
        let text = std::fs::read_to_string(path)?;
        Ok(self.load_mixed_str(&text))
    }

    pub fn load_mixed_str(&self, text: &str) -> usize {
        let words = Arc::new(crate::mixed::MixedWords::parse(text));
        let len = words.len();
        if let Ok(mut slot) = self.mixed.write() {
            *slot = words;
        }
        len
    }

    /// 换一份快捷短语（WoType 的 quick-phrases.tsv：`编码<TAB>短语`，短语里的换行、制表符写成 \n \t），
    /// 整份替换，返回条数。编码只认 1～32 个英文字母（存成小写），和水杉一样；`#` 开头的是注释。
    pub fn set_quick_phrases(&self, tsv: &str) -> usize {
        let mut phrases: HashMap<String, Vec<String>> = HashMap::new();
        let mut count = 0;
        for line in tsv.lines() {
            if line.starts_with('#') {
                continue;
            }
            let Some((code, text)) = line.split_once('\t') else {
                continue;
            };
            let code = code.trim().to_ascii_lowercase();
            let text = unescape_phrase(text);
            if code.is_empty() || code.len() > 32 || !code.bytes().all(|b| b.is_ascii_lowercase()) || text.is_empty() {
                continue;
            }
            let list = phrases.entry(code).or_default();
            if !list.contains(&text) {
                list.push(text);
                count += 1;
            }
        }
        if let Ok(mut slot) = self.quick_phrases.write() {
            *slot = Arc::new(phrases);
        }
        count
    }

    pub fn shuangpin(&self) -> bool {
        self.config.shuangpin
    }

    pub fn english_len(&self) -> usize {
        self.english.read().map(|m| m.len()).unwrap_or(0)
    }

    pub fn load_conversion<P: AsRef<std::path::Path>>(&self, path: P) -> Result<usize> {
        let conv = Converter::from_tsv_path(path)?;
        let len = conv.len();
        if let Ok(mut slot) = self.converter.write() {
            *slot = Arc::new(conv);
        }
        Ok(len)
    }

    /// 直接装载一张映射表（测试或程序内生成时用）。
    pub fn install_converter(&self, conv: Converter) {
        if let Ok(mut slot) = self.converter.write() {
            *slot = Arc::new(conv);
        }
    }

    pub fn conversion_len(&self) -> usize {
        self.converter.read().map(|c| c.len()).unwrap_or(0)
    }

    /// 把候选（含分词）转成繁体，并合并转换后重复的候选。
    fn apply_traditional(&self, candidates: &mut Vec<Candidate>) {
        let conv = match self.converter.read() {
            Ok(slot) if !slot.is_empty() => slot.clone(),
            _ => return,
        };
        let mut best: HashMap<String, Candidate> = HashMap::new();
        for mut candidate in std::mem::take(candidates) {
            candidate.text = conv.convert(&candidate.text);
            for word in &mut candidate.words {
                word.text = conv.convert(&word.text);
            }
            match best.entry(candidate.text.clone()) {
                Entry::Vacant(slot) => {
                    slot.insert(candidate);
                }
                Entry::Occupied(mut slot) => {
                    if candidate.score > slot.get().score {
                        slot.insert(candidate);
                    }
                }
            }
        }
        let mut list: Vec<Candidate> = best.into_values().collect();
        list.sort_by(|a, b| {
            b.score
                .total_cmp(&a.score)
                .then_with(|| a.text.cmp(&b.text))
        });
        list.truncate(self.config.max_candidates.max(1));
        *candidates = list;
    }

    pub fn set_max_candidates(&mut self, max_candidates: usize) {
        self.config.max_candidates = max_candidates.max(1);
    }

    pub fn lexicon(&self) -> &Arc<UserLexicon> {
        &self.lexicon
    }

    pub fn base_lexicon(&self) -> &Arc<dyn Lexicon> {
        &self.base_lexicon
    }

    /// 添加用户词（拼音可以是 ni hao / nihao / xi'an）。
    pub fn add_user_word(&self, pinyin: &str, word: &str, freq: f64) -> Result<()> {
        self.lexicon.add(pinyin, word, freq)
    }

    /// 删除用户词，返回是否删掉了。
    pub fn remove_user_word(&self, word: &str) -> bool {
        self.lexicon.remove(word)
    }

    pub fn user_words(&self) -> Vec<(String, String, f64)> {
        self.lexicon.words()
    }

    pub fn save_user_dict<P: AsRef<std::path::Path>>(&self, path: P) -> Result<()> {
        self.lexicon.save_tsv(path)
    }

    pub fn load_user_dict<P: AsRef<std::path::Path>>(&self, path: P) -> Result<usize> {
        self.lexicon.load_tsv(path)
    }

    /// 读自定义词文件（custom.tsv），整体替换上一次读到的；文件不存在就清空。
    pub fn load_custom_words<P: AsRef<std::path::Path>>(&self, path: P) -> Result<usize> {
        self.lexicon.load_custom(path)
    }

    pub fn lm(&self) -> &Arc<dyn LanguageModel> {
        &self.lm
    }

    pub fn config(&self) -> &EngineConfig {
        &self.config
    }

    /// 输入拼音串，返回候选；解析失败时返回空列表。
    /// 基于上一词的候选预测（「预测词库」）。
    ///
    /// 返回 (词, 对数概率)，按概率降序。语言模型没接入预测能力时返回空。
    pub fn predict_next(&self, prev: &str, limit: usize) -> Vec<(String, f64)> {
        self.lm.top_next(prev, limit)
    }

    pub fn input(&self, raw: &str) -> Vec<Candidate> {
        self.input_at(raw, now_ms())
    }

    /// 带时间戳的输入：历史特征的时间衰减按 at_ms 计算，便于测试与回放。
    pub fn input_at(&self, raw: &str, at_ms: u64) -> Vec<Candidate> {
        self.try_input_at(raw, at_ms).unwrap_or_default()
    }

    /// 可返回错误的版本，供 CLI/FFI 使用。
    pub fn try_input(&self, raw: &str) -> Result<Vec<Candidate>> {
        self.try_input_at(raw, now_ms())
    }

    pub fn try_input_at(&self, raw: &str, at_ms: u64) -> Result<Vec<Candidate>> {
        let display = raw.trim();
        let normalized = display.to_ascii_lowercase();

        let mut result = if self.config.shuangpin {
            // 双拼：先把键位展开成全拼变体（自然码有少量重叠），每种都跑一遍再合并。
            let variants = crate::shuangpin::to_full_pinyin_variants(&normalized);
            let mut merged: HashMap<String, Candidate> = HashMap::new();
            for variant in &variants {
                for candidate in self.query_plain(variant, at_ms)? {
                    match merged.entry(candidate.text.clone()) {
                        Entry::Vacant(slot) => {
                            slot.insert(candidate);
                        }
                        Entry::Occupied(mut slot) => {
                            if candidate.score > slot.get().score {
                                slot.insert(candidate);
                            }
                        }
                    }
                }
            }
            let mut list: Vec<Candidate> = merged.into_values().collect();
            list.sort_by(|a, b| {
                b.score
                    .total_cmp(&a.score)
                    .then_with(|| a.text.cmp(&b.text))
            });
            list.truncate(self.config.max_candidates.max(1));
            list
        } else {
            self.query_plain(&normalized, at_ms)?
        };

        protect_exact_input(&mut result);
        promote_picked(&mut result);
        if !self.config.shuangpin {
            pin_single_initial(&normalized, &mut result);
        }
        self.promote_custom(&mut result);
        self.append_raw_candidate(display, &mut result);
        self.insert_mixed_english(display, &normalized, at_ms, &mut result)?;
        self.insert_mixed_code(display, &normalized, at_ms, &mut result)?;
        if self.config.traditional {
            self.apply_traditional(&mut result);
        }
        // 快捷短语在简繁转换之后放：短语原样上屏
        self.insert_quick_phrases(&normalized, &mut result);
        for candidate in &mut result {
            candidate.consumed = raw.len();
        }
        if !self.config.shuangpin && self.config.prefix_candidates > 0 {
            let leading = raw.len() - raw.trim_start().len();
            let mut prefix = self.prefix_candidates(&normalized)?;
            prefix_on_syllable_boundaries(&result, &normalized, &mut prefix);
            for candidate in &mut prefix {
                candidate.consumed = leading + letters_to_bytes(display, candidate.consumed);
                if self.config.traditional {
                    if let Ok(conv) = self.converter.read() {
                        if !conv.is_empty() {
                            candidate.text = conv.convert(&candidate.text);
                        }
                    }
                }
            }
            if let Some(head) = sentence_head(&result, &normalized) {
                let mut head = head;
                head.consumed = leading + letters_to_bytes(display, head.consumed);
                prefix.insert(0, head);
            }
            compose_candidates(&mut result, prefix, self.config.max_candidates.max(1));
        }
        if self.config.more_candidates && !self.config.shuangpin {
            self.append_more_candidates(raw, display, &normalized, &mut result)?;
        }
        self.drop_unrenderable(&mut result);
        // 模糊音选词记忆的键：这次打的拼音（只留字母）；双拼用默认的那种全拼展开，和查词时的音节图一致
        let key = if self.config.shuangpin {
            crate::shuangpin::to_full_pinyin_variants(&normalized)
                .first()
                .map(|v| input_key(v))
                .unwrap_or_default()
        } else {
            input_key(&normalized)
        };
        self.promote_remembered(raw.len(), &key, at_ms, &mut result);
        if let Ok(mut last) = self.last_fuzzy.write() {
            let fuzzy = result
                .iter()
                .filter(|c| c.features.fuzzy_count > 0.0)
                .map(|c| c.text.clone())
                .collect();
            *last = (key, fuzzy);
        }
        if let Ok(mut last) = self.last_words.write() {
            last.clear();
            for c in &result {
                if !is_raw_candidate(c) {
                    last.insert(
                        c.text.clone(),
                        c.words.iter().map(|w| w.text.clone()).collect(),
                    );
                }
            }
        }
        Ok(result)
    }

    /// 句首词候选：从输入开头起、但没有用完整个输入的词。
    ///
    /// candidate.consumed 先存「用掉的字母数」，由调用方换算成字节。
    fn prefix_candidates(&self, normalized: &str) -> Result<Vec<Candidate>> {
        let Ok(parsed) = parse(normalized) else {
            return Ok(Vec::new());
        };
        if parsed.len() < 2 {
            return Ok(Vec::new());
        }
        let typo = self.config.typo_correction;
        let full = SyllableGraph::build(
            &parsed,
            GraphOptions {
                mode: GraphMode::Full,
                allow_erhua: true,
                typo,
                completion: false,
            },
        );
        let graph = if full.has_exact_path() || !self.config.jianpin_fallback {
            full
        } else {
            let completion_explains = SyllableGraph::build(
                &parsed,
                GraphOptions {
                    mode: GraphMode::Full,
                    allow_erhua: true,
                    typo: false,
                    completion: true,
                },
            )
            .has_path_without_typo();
            abbrev_graph(&parsed, completion_explains).unwrap_or(full)
        };
        let fuzzy_view;
        let lexicon: &dyn Lexicon = if self.config.fuzzy {
            fuzzy_view = FuzzyLexicon::new(self.lexicon.as_ref(), self.config.fuzzy_penalty);
            &fuzzy_view
        } else {
            self.lexicon.as_ref()
        };
        let words = crate::beam::first_words(
            &graph,
            lexicon,
            &self.config.beam,
            self.config.prefix_candidates,
        );
        Ok(words
            .into_iter()
            .map(|(word, cost)| Candidate {
                text: word.text.clone(),
                pinyin: word.pinyin.clone(),
                score: -cost,
                features: Feature {
                    typo_count: word.typos as f32,
                    typo: if word.typos > 0 { 1.0 } else { 0.0 },
                    fuzzy_count: if word.fuzzy { 1.0 } else { 0.0 },
                    ..Feature::default()
                },
                consumed: word.end,
                words: vec![CandidateWord {
                    text: word.text,
                    pinyin: word.pinyin,
                    freq: word.freq,
                    known: true,
                }],
            })
            .collect())
    }

    /// 翻页用的长尾：前面几页之后，把输入能对上的词全补上，直到 `max_candidates`。
    ///
    /// 照着微信输入法：先是整个输入的同音词（按词频），再是句首词（长的在前），
    /// 最后是第一个音节的单字。前面已经有的不重复；排第一的结果没纠错时不补纠错出来的词。
    fn append_more_candidates(
        &self,
        raw: &str,
        display: &str,
        normalized: &str,
        result: &mut Vec<Candidate>,
    ) -> Result<()> {
        let max = self.config.max_candidates.max(1);
        if result.len() >= max {
            return Ok(());
        }
        let Ok(parsed) = parse(normalized) else {
            return Ok(());
        };
        if parsed.is_empty() {
            return Ok(());
        }
        let typo = self.config.typo_correction;
        let full = SyllableGraph::build(
            &parsed,
            GraphOptions {
                mode: GraphMode::Full,
                allow_erhua: true,
                typo,
                completion: true,
            },
        );
        let graph = if full.has_exact_path() || !self.config.jianpin_fallback {
            full
        } else {
            let completion_explains = full.has_path_without_typo();
            abbrev_graph(&parsed, completion_explains).unwrap_or(full)
        };
        let fuzzy_view;
        let lexicon: &dyn Lexicon = if self.config.fuzzy {
            fuzzy_view = FuzzyLexicon::new(self.lexicon.as_ref(), self.config.fuzzy_penalty);
            &fuzzy_view
        } else {
            self.lexicon.as_ref()
        };
        let words = crate::beam::all_first_words(&graph, lexicon, &self.config.beam, max);
        if words.is_empty() {
            return Ok(());
        }
        let total = graph.len();
        let exact_top = result
            .iter()
            .find(|c| !is_raw_candidate(c))
            .map(|c| c.features.typo_count == 0.0)
            .unwrap_or(false);
        let to_candidate = |word: BeamWord, cost: f64| Candidate {
            text: word.text.clone(),
            pinyin: word.pinyin.clone(),
            score: -cost,
            features: Feature {
                typo_count: word.typos as f32,
                typo: if word.typos > 0 { 1.0 } else { 0.0 },
                fuzzy_count: if word.fuzzy { 1.0 } else { 0.0 },
                ..Feature::default()
            },
            consumed: word.end,
            words: vec![CandidateWord {
                text: word.text,
                pinyin: word.pinyin,
                freq: word.freq,
                known: true,
            }],
        };
        let mut whole = Vec::new();
        let mut heads = Vec::new();
        for (word, cost) in words {
            if exact_top && word.typos > 0 {
                continue;
            }
            if word.end >= total {
                whole.push(to_candidate(word, cost));
            } else if word.completion == 0 {
                heads.push(to_candidate(word, cost));
            }
        }
        // 句首词只留在音节边界上的（不把一个音节拆开）
        prefix_on_syllable_boundaries(result, normalized, &mut heads);
        let leading = raw.len() - raw.trim_start().len();
        let mut seen: HashMap<String, ()> = result.iter().map(|c| (c.text.clone(), ())).collect();
        let converter = if self.config.traditional {
            self.converter.read().ok()
        } else {
            None
        };
        for mut candidate in whole.into_iter().chain(heads) {
            if result.len() >= max {
                break;
            }
            if let Some(conv) = converter.as_ref().filter(|c| !c.is_empty()) {
                candidate.text = conv.convert(&candidate.text);
            }
            if seen.insert(candidate.text.clone(), ()).is_some() {
                continue;
            }
            candidate.consumed = if candidate.consumed >= total {
                raw.len()
            } else {
                leading + letters_to_bytes(display, candidate.consumed)
            };
            result.push(candidate);
        }
        for i in 1..result.len() {
            if result[i].score >= result[i - 1].score {
                result[i].score = result[i - 1].score - 1e-3;
            }
        }
        Ok(())
    }

    /// 全拼下输入能否不靠纠错、补全切成完整音节。
    fn is_plain_pinyin(&self, display: &str) -> bool {
        if self.config.shuangpin {
            return false;
        }
        let Ok(parsed) = parse(&display.to_ascii_lowercase()) else {
            return false;
        };
        SyllableGraph::build(
            &parsed,
            GraphOptions {
                mode: GraphMode::Full,
                allow_erhua: true,
                typo: false,
                completion: false,
            },
        )
        .has_complete_path()
    }

    /// 英文/未登录输入：保证原始输入本身可以作为候选上屏。
    ///
    /// 放在第几位：
    /// - 拼音完整、没纠错的中文排前面，原始串垫底（she -> 社 设 ……）；
    /// - 输入是已知英文词，而中文要靠纠错才凑得出来：英文排第一
    ///   （hello、github、python 不该被改成乱码中文）；中文只差最后一个音节没打完
    ///   （bug、diy）时排第二；拼音本身就完整（she、long）时排第六；
    /// - 不认识的串：中文全是未登录兜底时排第一，中文纠了 2 处以上排第二，其余垫底。
    ///
    /// 原始串一定留在列表里，不会被截断挤掉。
    fn append_raw_candidate(&self, display: &str, candidates: &mut Vec<Candidate>) {
        if !self.config.english_candidate || display.is_empty() || display.len() > 32 {
            return;
        }
        if !display.bytes().any(|b| b.is_ascii_alphabetic()) {
            return;
        }
        // 全小写输入且词表里有标准写法时用标准写法（github -> GitHub）
        let english = self
            .english
            .read()
            .ok()
            .and_then(|m| m.get(display).map(str::to_string));
        let text = match &english {
            Some(word) if display.bytes().all(|b| !b.is_ascii_uppercase()) => word.clone(),
            _ => display.to_string(),
        };
        if candidates
            .iter()
            .any(|c| c.text.eq_ignore_ascii_case(&text))
        {
            return;
        }
        // 输入本身是不是一串完整的拼音（she、me、long），或者已经有不靠纠错和
        // 补全的完整中文候选（双拼下只能看后者）
        // 全拼混简拼（he l l o -> 合理了哦）是硬凑出来的，不算
        let exact = self.is_plain_pinyin(display)
            || candidates.iter().any(|c| {
                c.features.coverage_score >= 1.0
                    && c.features.typo_count == 0.0
                    && c.features.prefix_completion == 0.0
                    && !c.words.iter().any(|w| !w.known)
                    && !is_mixed_jianpin(c)
            });
        // 第一个中文候选在中间就有只打了声母的音节（hello -> he l l o）：
        // 不像是还在打拼音，英文排第一
        let inner_abbrev = candidates
            .first()
            .is_some_and(|c| is_mixed_jianpin(c) && abbrev_before_last(c));
        // 打了大写（Hello）却只能凑成混简拼（he l l o -> 合理了哦）：要的是原样上屏
        let literal = display.bytes().any(|b| b.is_ascii_uppercase())
            && candidates.first().is_some_and(is_mixed_jianpin);
        let top_typos = candidates
            .first()
            .map(|c| c.features.typo_count)
            .unwrap_or(0.0);
        let has_known_word = candidates
            .first()
            .map(|c| c.words.iter().any(|w| w.known))
            .unwrap_or(false);
        // 第一名是几个词凑的整句（ok -> 哦 | 可）：不是「一个词还没打完」（上游 dd49547，#147）
        let top_sentence = candidates.first().is_some_and(is_sentence);
        let position = if english.is_some() {
            if exact {
                // 本身就是拼音的英文词（fan、long、she）：前 5 个留给中文
                Some(5)
            } else if top_typos == 0.0 && has_known_word && !inner_abbrev && !top_sentence {
                // 中文只是最后一个音节没打完（bug -> 不过、diy -> 第一），
                // 用户多半还在打拼音，英文排第二
                Some(1)
            } else {
                Some(0)
            }
        } else if exact {
            // 拼音完整的中文，原始拼音串没必要出现
            return;
        } else if !has_known_word {
            Some(0)
        } else if literal {
            Some(0)
        } else if top_typos >= 2.0 {
            Some(1)
        } else {
            None
        };
        let max = self.config.max_candidates.max(1);
        let at = position.unwrap_or(candidates.len()).min(candidates.len());
        // 分数夹在前后两个候选之间，后面无论怎么重新排序（繁体转换会重排）位置都不变
        let score = match (
            at.checked_sub(1).and_then(|i| candidates.get(i)),
            candidates.get(at),
        ) {
            (None, None) => -1.0,
            (None, Some(next)) => next.score + 1.0,
            (Some(prev), None) => prev.score - 1.0,
            (Some(prev), Some(next)) => (prev.score + next.score) / 2.0,
        };
        let raw = Candidate {
            text,
            pinyin: display.to_ascii_lowercase(),
            score,
            features: Feature::default(),
            words: vec![CandidateWord {
                text: display.to_string(),
                pinyin: String::new(),
                freq: 0.0,
                known: english.is_some(),
            }],
            consumed: display.len(),
        };
        candidates.insert(at, raw);
        if candidates.len() > max {
            // 截掉的是原始串以外的最后一个
            let drop = if at == candidates.len() - 1 {
                candidates.len() - 2
            } else {
                candidates.len() - 1
            };
            candidates.remove(drop);
        }
    }

    /// 混合编码的词：输入里有词表里的一个编码，`Azuo` → A座、`OKla` → OK啦、`shenmeAdian` → 什么A点。
    ///
    /// 这些编码多半也能当拼音读（a'zuo → 啊做），所以整串正好是一个编码时：
    /// - 打了大写字母（Azuo）：就是冲着它来的，排第一；
    /// - 全小写（azuo）：排第二，不抢正常拼音的首选；
    /// - 编码整个是拼音的（fenbei → dB、hezi → Hz）：排第五，前面留给正常的词（分贝、盒子、合资…）；
    /// - 编码的分段和首选的音节对不上的（jia 是「家」的 jia，不是吉A 的 ji'a）：不出，要打 jiA。
    ///
    /// 编码前后还有拼音时（`insert_mixed_sentence`）前后两段各查一遍拼成一句，位置同上面前两条。
    /// 选过以后由选词记忆提到前面（`promote_remembered`）。
    /// 整串输入正好是快捷短语的编码：短语放进候选，排在第 `QUICK_PHRASE_AT + 1` 个（照水杉：第一页的最后），
    /// 候选不够就排在最后。拼音留空：上屏只记热度，不当成词收进用户词库。
    fn insert_quick_phrases(&self, normalized: &str, candidates: &mut Vec<Candidate>) {
        let phrases = match self.quick_phrases.read() {
            Ok(phrases) if !phrases.is_empty() => Arc::clone(&phrases),
            _ => return,
        };
        let Some(list) = phrases.get(normalized) else {
            return;
        };
        let mut at = QUICK_PHRASE_AT.min(candidates.len());
        for text in list {
            if candidates.iter().any(|c| &c.text == text) {
                continue;
            }
            let score = score_between(candidates, at);
            candidates.insert(
                at,
                Candidate {
                    text: text.clone(),
                    pinyin: String::new(),
                    score,
                    features: Feature::default(),
                    words: vec![CandidateWord {
                        text: text.clone(),
                        pinyin: String::new(),
                        freq: 0.0,
                        known: true,
                    }],
                    consumed: normalized.len(),
                },
            );
            at += 1;
        }
    }

    fn insert_mixed_code(
        &self,
        display: &str,
        normalized: &str,
        at_ms: u64,
        candidates: &mut Vec<Candidate>,
    ) -> Result<()> {
        if self.config.shuangpin || !normalized.bytes().all(|b| b.is_ascii_lowercase()) {
            return Ok(());
        }
        let mixed = match self.mixed.read() {
            Ok(mixed) if mixed.len() > 0 => Arc::clone(&mixed),
            _ => return Ok(()),
        };
        let typed_upper = display.bytes().any(|b| b.is_ascii_uppercase());
        let plain_pinyin = self.is_plain_pinyin(normalized);
        // 整串是拼音时，首选把它切成了哪些音节：编码的分段要和它对得上
        // （首选是补全、纠错出来的就不知道，不卡）
        let ends = if plain_pinyin {
            candidates
                .iter()
                .find(|c| !is_raw_candidate(c))
                .and_then(|top| syllable_ends(top, normalized.len()))
        } else {
            None
        };
        let aligned = |start: usize, segments: &str| {
            let Some(ends) = &ends else {
                return true;
            };
            let mut at = start;
            (start == 0 || ends.contains(&start))
                && segments.split(' ').all(|segment| {
                    at += segment.len();
                    ends.contains(&at)
                })
        };

        // 编码本身是个英文词（iphone → iPhone 18 Pro、zip → 7-Zip）：首选让给英文词，和整个是拼音的一档
        let is_english = |code: &str| {
            self.english
                .read()
                .is_ok_and(|english| english.get(code).is_some())
        };
        let english = is_english(normalized);
        // 两档各自往后排：带字母的在前，整个是拼音的在后
        let mut lettered_at = if typed_upper { 0 } else { 1 };
        let mut pinyin_at = 4;
        let mut last = 0;
        for MixedWord { word, segments, lettered } in mixed.get(normalized) {
            if candidates.iter().any(|c| c.text == word) {
                continue;
            }
            if !typed_upper && !aligned(0, segments) {
                continue;
            }
            let at = if !english && (lettered || !plain_pinyin) {
                lettered_at = lettered_at.min(candidates.len());
                lettered_at += 1;
                pinyin_at += 1;
                lettered_at - 1
            } else {
                pinyin_at = pinyin_at.max(lettered_at).min(candidates.len());
                pinyin_at += 1;
                pinyin_at - 1
            };
            last = last.max(at + 1);
            let score = score_between(candidates, at);
            candidates.insert(
                at,
                Candidate {
                    text: word.to_string(),
                    pinyin: segments.to_string(),
                    score,
                    features: Feature::default(),
                    words: vec![CandidateWord {
                        text: word.to_string(),
                        pinyin: segments.to_string(),
                        freq: 0.0,
                        known: true,
                    }],
                    consumed: display.len(),
                },
            );
        }
        let max = self.config.max_candidates.max(1);
        candidates.truncate(max.max(last));
        if last == 0 {
            self.insert_mixed_sentence(
                display,
                normalized,
                at_ms,
                &mixed,
                &|start, end, segments| {
                    !is_english(&normalized[start..end]) && (typed_upper || aligned(start, segments))
                },
                candidates,
            )?;
        }
        Ok(())
    }

    /// 句子里夹着混合编码的词：`shenmeAdian` → 什么A点、`qubzhan` → 去B站。
    ///
    /// 只认编码带字母的词（整个是拼音的 hezi → Hz 到处都能切出来；编码本身是英文词的归中英混打管），
    /// 它前后的部分各自是完整的拼音。
    /// 打了大写时编码要把大写字母都包进去；全小写、整串又是拼音时，编码的分段要和首选的音节对得上
    /// （jiagu 是 jia'gu，切不出 ji + A股）。前后两段各查一遍，几种切法取中文部分分数最高的。
    fn insert_mixed_sentence(
        &self,
        display: &str,
        normalized: &str,
        at_ms: u64,
        mixed: &crate::mixed::MixedWords,
        allowed: &dyn Fn(usize, usize, &str) -> bool,
        candidates: &mut Vec<Candidate>,
    ) -> Result<()> {
        const MAX_SPLITS: usize = 4;
        let n = normalized.len();
        if n > 48 {
            return Ok(());
        }
        let upper: Vec<usize> = display
            .bytes()
            .enumerate()
            .filter(|(_, b)| b.is_ascii_uppercase())
            .map(|(i, _)| i)
            .collect();
        let typed_upper = !upper.is_empty();
        // display 可能带隔音符，位置就和 normalized 对不上了：这种不管
        if typed_upper && display.len() != n {
            return Ok(());
        }
        let pinyin_or_empty = |part: &str| part.is_empty() || self.is_plain_pinyin(part);
        // (起点, 终点, 词, 分好段的编码)，编码长的在前
        let mut splits: Vec<(usize, usize, &str, &str)> = Vec::new();
        'search: for len in (2..n).rev() {
            for start in 0..=n - len {
                let end = start + len;
                if typed_upper && !upper.iter().all(|i| (start..end).contains(i)) {
                    continue;
                }
                let Some(found) = mixed.get(&normalized[start..end]).find(|m| m.lettered) else {
                    continue;
                };
                if allowed(start, end, found.segments)
                    && pinyin_or_empty(&normalized[..start])
                    && pinyin_or_empty(&normalized[end..])
                {
                    splits.push((start, end, found.word, found.segments));
                    if splits.len() >= MAX_SPLITS {
                        break 'search;
                    }
                }
            }
        }

        // (中文部分的分数, 文字, 拼音, 分词)
        let mut best: Option<(f64, String, Vec<String>, Vec<CandidateWord>)> = None;
        for (start, end, word, segments) in splits {
            let mut total = 0.0;
            let mut text = String::new();
            let mut pinyin: Vec<String> = Vec::new();
            let mut words = Vec::new();
            let mut complete = true;
            for (part, is_code) in [
                (&normalized[..start], false),
                (&normalized[start..end], true),
                (&normalized[end..], false),
            ] {
                if part.is_empty() {
                    continue;
                }
                if is_code {
                    text.push_str(word);
                    pinyin.push(segments.to_string());
                    words.push(CandidateWord {
                        text: word.to_string(),
                        pinyin: segments.to_string(),
                        freq: 0.0,
                        known: true,
                    });
                    continue;
                }
                let Some(top) = self.query_plain(part, at_ms)?.into_iter().next() else {
                    complete = false;
                    break;
                };
                total += top.score;
                text.push_str(&top.text);
                pinyin.push(top.pinyin);
                words.extend(top.words);
            }
            if complete && best.as_ref().map_or(true, |(score, ..)| total > *score) {
                best = Some((total, text, pinyin, words));
            }
        }
        let Some((_, text, pinyin, words)) = best else {
            return Ok(());
        };
        if candidates.iter().any(|c| c.text == text) {
            return Ok(());
        }
        let at = usize::from(!typed_upper).min(candidates.len());
        let score = score_between(candidates, at);
        candidates.insert(
            at,
            Candidate {
                text,
                pinyin: pinyin.join(" "),
                score,
                features: Feature::default(),
                words,
                consumed: display.len(),
            },
        );
        let max = self.config.max_candidates.max(1);
        if candidates.len() > max {
            candidates.pop();
        }
        Ok(())
    }

    /// 中英混打：拼音中间（或前后）夹着一个英文词，`wozaigithub` → 我在GitHub、
    /// `zhegeappbucuo` → 这个app不错。
    ///
    /// 只在整串不是完整拼音时找；英文词要词表里有、至少 3 个字母、本身不是拼音
    /// （不然 she、long、fan 到处都能切出来），它前后的部分各自是完整的拼音。
    /// 找到了就把前后两段各查一遍，拼成一个候选；只认一个英文词，取最长的。
    fn insert_mixed_english(
        &self,
        display: &str,
        normalized: &str,
        at_ms: u64,
        candidates: &mut Vec<Candidate>,
    ) -> Result<()> {
        const MIN_WORD: usize = 3;
        let n = normalized.len();
        if !self.config.english_candidate
            || self.config.shuangpin
            || n <= MIN_WORD
            || n > 48
            || !normalized.bytes().all(|b| b.is_ascii_lowercase())
            || self.is_plain_pinyin(normalized)
            // 整串本身就是一个英文词（hello 不要切成 hell + 哦）
            || self.english.read().is_ok_and(|english| english.get(normalized).is_some())
        {
            return Ok(());
        }
        // 能切出来的几种切法（英文词长的在前，最多看 4 种）
        const MAX_SPLITS: usize = 4;
        let splits: Vec<(usize, usize, String)> = self
            .english
            .read()
            .map(|english| {
                let pinyin_or_empty = |part: &str| part.is_empty() || self.is_plain_pinyin(part);
                (MIN_WORD..n.min(33))
                    .rev()
                    .flat_map(|len| (0..=n - len).map(move |start| (start, start + len)))
                    .filter_map(|(start, end)| {
                        let word = english.get(&normalized[start..end])?;
                        (!self.is_plain_pinyin(&normalized[start..end])
                            && pinyin_or_empty(&normalized[..start])
                            && pinyin_or_empty(&normalized[end..]))
                        .then(|| (start, end, word.to_string()))
                    })
                    .take(MAX_SPLITS)
                    .collect()
            })
            .unwrap_or_default();

        // 每种切法把前后两段各查一遍，取中文部分分数最高的（womenthe：我们the 而不是 我ment和）
        // (中文部分的分数, 文字, 拼音, 分词)
        let mut best: Option<(f64, String, Vec<String>, Vec<CandidateWord>)> = None;
        for (start, end, word) in splits {
            // 用户自己打了大写（wozaiGitHub）就照他打的
            let typed = &display[start..end];
            let word = if typed.bytes().any(|b| b.is_ascii_uppercase()) {
                typed.to_string()
            } else {
                word
            };
            let mut total = 0.0;
            let mut parts: Vec<String> = Vec::new();
            let mut pinyin: Vec<String> = Vec::new();
            let mut words = Vec::new();
            let mut complete = true;
            for (part, is_english) in [
                (&normalized[..start], false),
                (&normalized[start..end], true),
                (&normalized[end..], false),
            ] {
                if part.is_empty() {
                    continue;
                }
                if is_english {
                    parts.push(word.clone());
                    pinyin.push(part.to_string());
                    words.push(CandidateWord {
                        text: word.clone(),
                        pinyin: part.to_string(),
                        freq: 0.0,
                        known: true,
                    });
                    continue;
                }
                let Some(top) = self.query_plain(part, at_ms)?.into_iter().next() else {
                    complete = false;
                    break;
                };
                total += top.score;
                parts.push(top.text);
                pinyin.push(top.pinyin);
                words.extend(top.words);
            }
            if complete && best.as_ref().map_or(true, |(score, ..)| total > *score) {
                best = Some((total, parts.concat(), pinyin, words));
            }
        }
        let Some((_, text, pinyin, words)) = best else {
            return Ok(());
        };
        if candidates.iter().any(|c| c.text == text) {
            return Ok(());
        }
        // 第一个中文候选只是最后一个音节没打完（tamenbus → 他们不是）：多半还在打拼音，排第二；
        // 否则中文是靠纠错、混简拼硬凑的（我在意徒步），排第一
        let still_typing = candidates.first().is_some_and(|c| {
            !is_raw_candidate(c)
                && c.features.typo_count == 0.0
                && c.words.iter().all(|w| w.known)
                && !(is_mixed_jianpin(c) && abbrev_before_last(c))
        });
        let at = usize::from(still_typing).min(candidates.len());
        let score = match (
            at.checked_sub(1).and_then(|i| candidates.get(i)),
            candidates.get(at),
        ) {
            (None, None) => -1.0,
            (None, Some(next)) => next.score + 1.0,
            (Some(prev), None) => prev.score - 1.0,
            (Some(prev), Some(next)) => (prev.score + next.score) / 2.0,
        };
        candidates.insert(
            at,
            Candidate {
                text,
                pinyin: pinyin.join(" "),
                score,
                features: Feature::default(),
                words,
                consumed: display.len(),
            },
        );
        let max = self.config.max_candidates.max(1);
        if candidates.len() > max {
            candidates.pop();
        }
        Ok(())
    }

    /// 单条全拼输入的完整查询。开模糊音时只跑一遍：模糊视图里读音完全对上的词不扣分，
    /// 模糊来的词逐个扣 fuzzy_penalty（见 FuzzyLexicon）。
    fn query_plain(&self, normalized: &str, at_ms: u64) -> Result<Vec<Candidate>> {
        let mut result = self.run_query(normalized, at_ms, self.config.fuzzy)?;
        if self.config.fuzzy {
            result.truncate(self.config.max_candidates.max(1));
        }
        Ok(result)
    }

    /// 跑一次查询；fuzzy=true 时用模糊视图（读音对上的不扣分，模糊来的扣分）。
    ///
    /// 末音节补全（zhongg -> 中国、zhonggu -> 中国）和纠错都做成了音节图里的边，
    /// 一次搜索就能同时给出精确、补全、纠错三类候选。
    fn run_query(&self, normalized: &str, at_ms: u64, fuzzy: bool) -> Result<Vec<Candidate>> {
        let parsed = parse(normalized)?;
        if parsed.is_empty() {
            return Ok(Vec::new());
        }
        let typo = self.config.typo_correction && !self.config.shuangpin;
        let full = SyllableGraph::build(
            &parsed,
            GraphOptions {
                mode: GraphMode::Full,
                allow_erhua: true,
                typo,
                completion: true,
            },
        );
        // 不靠补全、纠错就能完整解析：直接用全拼。
        // 但能切成音节不等于词库里有词：hm、hng 这类叹词音节词库不收，以前只给出原样的 hm。
        // 一个认识的词都凑不出来就接着试简拼（照上游 7cffc5c，#105）。
        if full.has_exact_path() {
            let found = self.query_once(&full, at_ms, fuzzy)?;
            let any_known = found
                .iter()
                .any(|c| !c.words.is_empty() && c.words.iter().all(|w| w.known));
            if !self.config.jianpin_fallback || any_known {
                return Ok(found);
            }
        }
        // 否则简拼（zg、jzm）、全拼混简拼（kyi、yongzwen）与全拼补全/纠错都试，按分数合并
        let mut merged: Vec<Candidate> = Vec::new();
        if self.config.jianpin_fallback {
            if let Some(jianpin) = abbrev_graph(&parsed, full.has_path_without_typo()) {
                let mut found = self.query_once(&jianpin, at_ms, fuzzy)?;
                if jianpin.mode() == GraphMode::Mixed {
                    // 混简拼里拿声母、单个字母兜底凑出来的（h e l l o -> "hello"）没有意义
                    found.retain(|c| c.words.iter().all(|w| w.known));
                }
                merged.extend(found);
            }
        }
        if full.has_complete_path() {
            merged.extend(self.query_once(&full, at_ms, fuzzy)?);
        }
        let mut result = dedupe_by_text(merged);
        result.sort_by(|a, b| {
            b.score
                .total_cmp(&a.score)
                .then_with(|| a.text.cmp(&b.text))
        });
        result.truncate(self.config.max_candidates.max(1));
        Ok(result)
    }

    fn query_once(&self, graph: &SyllableGraph, at_ms: u64, fuzzy: bool) -> Result<Vec<Candidate>> {
        // fuzzy 时用包装视图：精确查不到再退到模糊音。
        let fuzzy_view;
        let lexicon: &dyn Lexicon = if fuzzy {
            fuzzy_view = FuzzyLexicon::new(self.lexicon.as_ref(), self.config.fuzzy_penalty);
            &fuzzy_view
        } else {
            self.lexicon.as_ref()
        };
        let start = self.start_word();
        let pairs = self
            .pairs
            .read()
            .map_err(|_| anyhow::anyhow!("pairs lock poisoned"))?;
        let lm = LearnedLm {
            base: self.lm.as_ref(),
            pairs: &pairs,
            start: start.as_deref(),
            at_ms,
        };
        let context = self.context();
        let mut paths = beam_search_with_context(graph, lexicon, &lm, &self.config.beam, &context);
        drop(pairs);
        if paths.is_empty() {
            return Ok(Vec::new());
        }

        // 有完整覆盖路径时只保留完整覆盖，避免 西an / xi安 这类半拼音候选。
        // 否则退而求其次，保留有部分词典命中的路径；全未登录时保留兜底路径。
        if paths.iter().any(|p| p.coverage >= 1.0) {
            paths.retain(|p| p.coverage >= 1.0);
        } else if paths.iter().any(|p| p.coverage > 0.0) {
            paths.retain(|p| p.coverage > 0.0);
        }

        let best_score = paths
            .iter()
            .map(|p| p.score)
            .fold(f64::NEG_INFINITY, f64::max);

        let nnlm = self.nnlm_scores(&paths);
        let key = String::from_utf8_lossy(&graph.input().letters).into_owned();
        let candidates: Vec<Candidate> = paths
            .into_iter()
            .zip(nnlm)
            .map(|(path, nnlm)| self.make_candidate(path, best_score, at_ms, nnlm, &key))
            .collect();

        let mut deduped = dedupe_by_text(candidates);
        deduped.sort_by(|a, b| {
            b.score
                .total_cmp(&a.score)
                .then_with(|| a.text.cmp(&b.text))
        });
        deduped.truncate(self.config.max_candidates.max(1));
        Ok(deduped)
    }

    /// 每条路径的神经语言模型特征：log P(整句 | 光标前的文本) 减去这批里最好的那条，≤ 0。
    ///
    /// 只算束搜索分数最高的 `nnlm_rerank` 条（模型一步约 1 ms，同一前缀会缓存）；
    /// 其余的给比算过的最差那条还低一点的值。没有模型时全是 0。
    fn nnlm_scores(&self, paths: &[BeamPath]) -> Vec<f32> {
        let mut out = vec![0.0f32; paths.len()];
        let limit = self.config.nnlm_rerank;
        if limit == 0 || paths.len() < 2 {
            return out;
        }
        let Some(model) = self.nnlm.read().ok().and_then(|m| m.clone()) else {
            return out;
        };
        let mut order: Vec<usize> = (0..paths.len()).collect();
        order.sort_by(|&a, &b| paths[b].score.total_cmp(&paths[a].score));
        let context = model.context_tokens(&self.context());
        let scored: Vec<(usize, f64)> = order
            .iter()
            .take(limit)
            .map(|&i| (i, model.score(&context, &paths[i].text)))
            .collect();
        let best = scored.iter().map(|s| s.1).fold(f64::NEG_INFINITY, f64::max);
        let worst = scored.iter().map(|s| s.1).fold(f64::INFINITY, f64::min);
        for &(i, s) in &scored {
            out[i] = (s - best).max(-NNLM_FLOOR) as f32;
        }
        let rest = ((worst - best) - 2.0).max(-NNLM_FLOOR) as f32;
        for &i in order.iter().skip(limit) {
            out[i] = rest;
        }
        out
    }

    /// key：这次查的拼音（只留字母），模糊音对上的候选按它查选词记忆。
    fn make_candidate(
        &self,
        path: BeamPath,
        best_score: f64,
        at_ms: u64,
        nnlm: f32,
        key: &str,
    ) -> Candidate {
        let mut feature = self.make_feature(&path, best_score, at_ms, key);
        feature.head_word_nnlm = nnlm;
        let rank_score = self.ranker.score(&feature) as f64;
        let score = path.score + rank_score;
        Candidate {
            text: path.text,
            pinyin: path.pinyin,
            score,
            features: feature,
            words: path
                .words
                .into_iter()
                .map(|w| CandidateWord {
                    text: w.text,
                    pinyin: w.pinyin,
                    freq: w.freq,
                    known: w.known,
                })
                .collect(),
            consumed: 0,
        }
    }

    fn make_feature(&self, path: &BeamPath, best_score: f64, at_ms: u64, key: &str) -> Feature {
        // 靠模糊音对上的候选只看在这个输入上选过几次（fuzzy_picks），不看词本身的热度，
        // 末词也不算：在别的拼音上选过的词不该串到这里（见 Engine::fuzzy_picks）
        let fuzzy_count = path.words.iter().filter(|w| w.fuzzy).count();
        let fuzzy_entry = (fuzzy_count > 0)
            .then(|| {
                self.fuzzy_picks
                    .read()
                    .ok()
                    .and_then(|p| p.get(&(key.to_string(), path.text.clone())).copied())
            })
            .flatten();
        // 历史：整句命中与末词命中都算。
        //
        // 排序用热度（30 天半衰期衰减后的次数，取 ln(1+热度)），见 [`learn`]。
        // 末词只算多字词，而且算一半：选过「种地」，「我想种地」也该靠前；
        // 选过「你」不能把所有以「你」结尾的整句都抬上来。
        let history_hot_val = self
            .history
            .read()
            .ok()
            .map(|history| {
                let exact = if fuzzy_count > 0 {
                    fuzzy_entry.map(|e| crate::learn::decayed(e, at_ms))
                } else {
                    history.get(&path.text).map(|e| crate::learn::decayed(*e, at_ms))
                }
                .unwrap_or(0.0);
                let tail = path
                    .words
                    .last()
                    .filter(|_| fuzzy_count == 0)
                    .filter(|w| path.words.len() >= 2 && w.text.chars().count() >= 2)
                    .and_then(|w| history.get(&w.text))
                    .map(|e| crate::learn::decayed(*e, at_ms))
                    .unwrap_or(0.0);
                ((1.0 + exact + 0.5 * tail).ln() as f32, exact as f32)
            })
            .unwrap_or((0.0, 0.0));
        let (history_hot_val, picked) = history_hot_val;
        let (history_count, _history_use, history_time_diff) = self
            .history
            .read()
            .ok()
            .map(|history| {
                let exact = if fuzzy_count > 0 {
                    fuzzy_entry
                } else {
                    history.get(&path.text).copied()
                };
                let tail = path
                    .words
                    .last()
                    .filter(|_| fuzzy_count == 0)
                    .and_then(|w| history.get(&w.text))
                    .copied();
                let merged = match (exact, tail) {
                    (Some(a), Some(b)) if b.count > a.count => b,
                    (Some(a), _) => a,
                    (None, Some(b)) => b,
                    (None, None) => HistoryEntry {
                        count: 0,
                        last_used_ms: at_ms,
                    },
                };
                let seconds = at_ms.saturating_sub(merged.last_used_ms) as f64 / 1000.0;
                (
                    merged.count as f32,
                    merged.count as f32,
                    (1.0 + seconds).ln() as f32,
                )
            })
            .unwrap_or((0.0, 0.0, 0.0));

        // 上下文：用候选首词去查二元分。
        //
        // 取键要同时试「上一个词」和「上一个字」：词级 LM 用前者，
        // 字级 LM（例如从语料统计的字二元）用后者。中文上下文通常没有空格，
        // 只取 split_whitespace().last() 会把整段文本当成一个词，查不到任何 bigram。
        let (with_context, context_bigram_score) = self
            .context
            .read()
            .map(|context| {
                let context = context.trim();
                let Some(candidate) = path.words.first() else {
                    return (0.0, 0.0);
                };
                if context.is_empty() {
                    return (0.0, 0.0);
                }
                let mut best: Option<f32> = None;
                let mut consider = |prev: &str| {
                    if prev.is_empty() {
                        return;
                    }
                    let score = self.lm.score(Some(prev), &candidate.text) as f32;
                    best = Some(best.map_or(score, |b: f32| b.max(score)));
                };
                if let Some(word) = context.split_whitespace().last() {
                    consider(word);
                }
                let mut buf = [0u8; 4];
                if let Some(ch) = context.chars().last() {
                    consider(ch.encode_utf8(&mut buf));
                }
                (1.0, best.unwrap_or(0.0))
            })
            .unwrap_or((0.0, 0.0));

        Feature {
            kind: if path.words.len() <= 1 { 0.0 } else { 1.0 },
            prob: (path.score - best_score).exp().clamp(0.0, 1.0) as f32,
            coverage_score: path.coverage,
            lm_score_with_previous_txt: path.lm_score as f32,
            full_jianpin: if path.jianpin { 1.0 } else { 0.0 },
            ltr_valid: if self.ranker.has_ltr() { 1.0 } else { 0.0 },
            history_count,
            // 这个候选本身（整个文本）被选过的热度，不含末词命中
            history_use_count: picked,
            history_time_diff,
            history_hot_val,
            with_context,
            context_bigram_score,
            typo_count: path.typos as f32,
            prefix_completion: (path.completion as f32).min(3.0),
            typo: if path.typos > 0 { 1.0 } else { 0.0 },
            fuzzy_count: fuzzy_count as f32,
            // 用户词等特征还没有数据源，保持 0；NNLM 在 make_candidate 里填。
            ..Feature::default()
        }
    }
}

/// 模糊音选词记忆的键：输入里的小写字母（去掉隔音符等）。
fn input_key(text: &str) -> String {
    text.chars().filter(|c| c.is_ascii_lowercase()).collect()
}

/// 第 k 个字母之后在原始串里的字节位置（跳过紧随其后的隔音符）。
fn letters_to_bytes(raw: &str, letters: usize) -> usize {
    let bytes = raw.as_bytes();
    let mut seen = 0usize;
    let mut idx = 0usize;
    while idx < bytes.len() && seen < letters {
        if bytes[idx].is_ascii_alphabetic() {
            seen += 1;
        }
        idx += 1;
    }
    while idx < bytes.len() && bytes[idx] == b'\'' {
        idx += 1;
    }
    idx
}

/// 把句首词候选并入整句候选。
///
/// 整句是一个词时（shijie -> 世界）句首词放在最后；整句由多个词拼成时
/// （长句）第二名往后的整句只是小改动，价值不如句首词，所以句首词紧跟第一名。
/// 词频低于这个数的词不受「精确优先」保护（rime-ice 里约排在 20 万名以后，多是生僻或凑出来的条目）。
const EXACT_PROTECT_MIN_FREQ: f64 = 1000.0;
/// 神经语言模型特征最低到多少（自然对数），免得一条特别离谱的把分数拉得太开。
const NNLM_FLOOR: f64 = 20.0;

/// 拼音打全了、而且正好是一个实在的词时，这个词必须排第一。
///
/// 补全和纠错的分数里带着词频，高频词补出来以后可能比用户打全了的低频词还高：
/// `zhongdi` 会出「重点」（zhong dian）而不是「种地」，`ka` 出「看」，`beiji` 出「北京」。
/// 用户按空格上屏的是第一个——打到一半时补全排第二只是多按一个键，
/// 打全了却被换成别的词就是打错字。所以排在这个词前面的补全/纠错候选都挪到它后面。
///
/// 同理，整个输入就是一个词时，几个单字硬凑出来的候选（`shidan` 拆成「是 | 但」）
/// 也不该压过它（「实弹」）。
///
/// 「实在的词」：精确匹配（不靠纠错和补全）、要么整个输入是一个词，要么最后一个词
/// 至少两个字（这时只和「前面的词一样、只有最后一个词不同」的候选比）；每个词的词频不低于 [`EXACT_PROTECT_MIN_FREQ`]，或者是用户选过的。
/// 最后是个单字的精确结果（`zhonggu` 拆成「中 | 骨」）不算，用户多半还没打完，
/// 补全照常可以排第一。
fn protect_exact_input(candidates: &mut Vec<Candidate>) {
    let multi = |w: &CandidateWord| w.pinyin.split_whitespace().count() >= 2;
    let is_exact = |c: &Candidate| {
        c.features.coverage_score >= 1.0
            && c.features.typo_count == 0.0
            && c.features.prefix_completion == 0.0
            && !c.words.is_empty()
            && c.words.iter().all(|w| w.known)
    };
    let solid = |c: &Candidate| {
        is_exact(c)
            && (c.words.len() == 1 || c.words.last().map(multi).unwrap_or(false))
            && (c.features.history_count > 0.0
                || c.words.iter().all(|w| w.freq >= EXACT_PROTECT_MIN_FREQ))
    };
    let Some(anchor) = candidates.iter().position(solid) else {
        return;
    };
    if anchor == 0 {
        return;
    }
    let whole_word = candidates[anchor].words.len() == 1;
    // 精确结果是几个词拼的（我在 | 种地）时，只管开头一样、只是后面换了词的拼凑结果
    // （我 | 在重点）；一个整词盖住全部输入的（从善如流 vs 从善 | 入理）是更强的证据，不动
    let head_text: String = {
        let words = &candidates[anchor].words;
        words[..words.len() - 1]
            .iter()
            .map(|w| w.text.as_str())
            .collect()
    };
    let same_head =
        |c: &Candidate| whole_word || (c.words.len() >= 2 && c.text.starts_with(&head_text));
    let yields = |c: &Candidate| {
        let corrected = c.features.typo_count > 0.0 || c.features.prefix_completion > 0.0;
        (corrected && same_head(c))
            || (whole_word && c.words.len() >= 2 && !c.words.iter().any(multi))
    };
    if !candidates[..anchor].iter().any(yields) {
        return;
    }
    let mut ahead = Vec::new();
    let mut keep = Vec::with_capacity(candidates.len());
    for (i, c) in candidates.drain(..).enumerate() {
        if i < anchor && yields(&c) {
            ahead.push(c);
        } else {
            keep.push(c);
        }
    }
    let at = keep
        .iter()
        .position(solid)
        .map(|i| i + 1)
        .unwrap_or(keep.len());
    keep.splice(at..at, ahead);
    // 分数改成单调递减，后面再按分数重排（繁体转换）顺序也不变
    for i in 1..keep.len() {
        if keep[i].score >= keep[i - 1].score {
            keep[i].score = keep[i - 1].score - 1e-3;
        }
    }
    *candidates = keep;
}

/// 用户上次给这串输入选过的候选往前放（微信输入法的 FirstUserCandidateRanker /
/// SingleUserWordCanbeSecond）：词和整句放第一，单字只放到第二——
/// 偶尔选一次生僻字，不该让它以后一直顶掉最常用的字。
///
/// 只看「这个候选本身被选过」（不算末词命中），而且要精确匹配（不是纠错、补全出来的），
/// 比第一个候选被选得更多才换。
/// 用户在设置里加的自定义词排最前（语言模型不认识它们，光靠词频排不上来）。
impl Engine {
    fn promote_custom(&self, candidates: &mut [Candidate]) {
        let custom = |c: &Candidate| c.words.len() == 1 && self.lexicon.is_custom(&c.text);
        if candidates.iter().any(custom) {
            // 稳定排序：自定义词之间、其余候选之间都保持原来的顺序
            candidates.sort_by_key(|c| !custom(c));
        }
    }

    /// 选词记忆的最后一步，对所有候选一视同仁：用完整串输入的候选里，
    /// 选得最多的（按半衰期衰减后的次数）排第一；一样多时最近选的在前。
    ///
    /// 放在所有候选都生成、排好之后：普通中文候选、中英混打、英文词不管哪来的都管，
    /// 没打完的拼音、简拼、纠错出来的候选也管。以前只有 [`promote_picked`] 管一部分，
    /// yuanc（最后一个音节没打完）、main（英文词）、你好呀english（混打）各漏过一次，
    /// 见 docs/bugs/05、06。思路同 Rime 的用户词典调频：次数加时间衰减。
    ///
    /// 不动的：
    /// - 第一个是自定义词（用户自己加的，固定排第一）；
    /// - 单字只提到第二：shi、de 这类输入每次要的字不一样，首选不跟着单字来回变；
    /// - 不是英文词的原样字母（nihao、wsm）：回车上屏过也算一次选词，不能排到中文前面。
    fn promote_remembered(
        &self,
        input_len: usize,
        key: &str,
        at_ms: u64,
        candidates: &mut Vec<Candidate>,
    ) {
        let Some(first) = candidates.first() else {
            return;
        };
        if first.words.len() == 1 && self.lexicon.is_custom(&first.text) {
            return;
        }
        let Ok(history) = self.history.read() else {
            return;
        };
        let Ok(fuzzy_picks) = self.fuzzy_picks.read() else {
            return;
        };
        // (衰减后的次数, 上次选的时间)
        let hot = |c: &Candidate| -> (f64, u64) {
            if c.consumed < input_len || (is_raw_candidate(c) && !c.words[0].known) {
                return (0.0, 0);
            }
            // 靠纠错凑出来的不提：选「提前」时打的是 tiqian，打 riqi 不该因为它选过就排到「日期」前面
            if c.features.typo_count > 0.0 {
                return (0.0, 0);
            }
            // 模糊音对上的只看在这个输入上选过没有：选「离线」时打的是 lixian，打 lixiang 不该提它
            if c.features.fuzzy_count > 0.0 {
                return fuzzy_picks
                    .get(&(key.to_string(), c.text.clone()))
                    .map(|e| (crate::learn::decayed(*e, at_ms), e.last_used_ms))
                    .unwrap_or((0.0, 0));
            }
            let lookup = |text: &str| {
                history
                    .get(text)
                    .map(|e| (crate::learn::decayed(*e, at_ms), e.last_used_ms))
            };
            // 混打候选以前按「英文词两边带空格」的文字记过（我在 GitHub），也认
            lookup(&c.text)
                .or_else(|| legacy_spaced_text(c).and_then(|spaced| lookup(&spaced)))
                .unwrap_or((0.0, 0))
        };
        let scores: Vec<(f64, u64)> = candidates.iter().map(hot).collect();
        drop(history);
        drop(fuzzy_picks);
        let Some(best) = (0..candidates.len())
            .filter(|&i| scores[i].0 > 0.0)
            // 次数多的；一样多看谁最近选过；再一样就留原来靠前的
            .max_by(|&a, &b| {
                scores[a]
                    .0
                    .total_cmp(&scores[b].0)
                    .then(scores[a].1.cmp(&scores[b].1))
                    .then(b.cmp(&a))
            })
        else {
            return;
        };
        let target = usize::from(candidates[best].text.chars().count() <= 1).min(candidates.len() - 1);
        if best <= target {
            return;
        }
        let chosen = candidates.remove(best);
        candidates.insert(target, chosen);
        // 分数跟着位置走，后面再按分数排（繁体转换等）位置也不变
        for i in (0..target + 1).rev() {
            if i + 1 < candidates.len() && candidates[i].score <= candidates[i + 1].score {
                candidates[i].score = candidates[i + 1].score + 1e-3;
            }
        }
    }

    /// 撤销一次选词记录（上屏后马上用退格整个删掉：选错了，不算学习）。
    ///
    /// 次数减一；这次选词正好让它被自动收进用户词库的，也拿出来。
    pub fn forget_selection(&self, word: &str) {
        let Ok(mut history) = self.history.write() else {
            return;
        };
        let Some(entry) = history.get_mut(word) else {
            return;
        };
        entry.count = entry.count.saturating_sub(1);
        let count = entry.count;
        if count == 0 {
            history.remove(word);
        }
        drop(history);
        // 刚才是靠模糊音选的：那一份也撤一次
        let fuzzy_key = self
            .last_fuzzy
            .read()
            .ok()
            .map(|last| (last.0.clone(), word.to_string()));
        if let (Some(key), Ok(mut picks)) = (fuzzy_key, self.fuzzy_picks.write()) {
            if let Some(entry) = picks.get_mut(&key) {
                entry.count = entry.count.saturating_sub(1);
                if entry.count == 0 {
                    picks.remove(&key);
                }
            }
        }
        if self.config.auto_learn && count < self.config.auto_learn_threshold.max(1) {
            self.lexicon.remove(word);
        }
        if let Ok(mut last) = self.last_word.write() {
            if last.as_str() == word {
                last.clear();
            }
        }
    }
}

/// 混打候选「英文词两边带空格」的写法（我在 GitHub）；不是混打候选返回 None。
fn legacy_spaced_text(candidate: &Candidate) -> Option<String> {
    let english = |w: &CandidateWord| {
        !w.text.is_empty()
            && w.text.bytes().all(|b| b.is_ascii_alphabetic())
            && w.pinyin.eq_ignore_ascii_case(&w.text)
    };
    if candidate.words.len() < 2 || !candidate.words.iter().any(english) {
        return None;
    }
    let mut text = String::new();
    for (i, word) in candidate.words.iter().enumerate() {
        if i > 0 && (english(word) || english(&candidate.words[i - 1])) {
            text.push(' ');
        }
        text.push_str(&word.text);
    }
    Some(text)
}

/// 只打一个声母（l、b、zh）时固定排第一的字：词库按读音分的词频把它们排得太后
/// （了 le 348 万，来 1484 万；不 299 万，把 380 万），而且第一个候选不该随上文、选过的字变来变去。
/// 没列的声母照词频排。照上游 Gloridust/WowType 92ce495（#165）。
const SINGLE_INITIAL_TOP: &[(&str, &str)] = &[
    ("b", "不"),
    ("d", "的"),
    ("g", "个"),
    ("h", "和"),
    ("j", "就"),
    ("l", "了"),
    ("n", "你"),
    ("q", "去"),
    ("r", "人"),
    ("s", "是"),
    ("sh", "是"),
    ("t", "他"),
    ("w", "我"),
    ("y", "一"),
    ("z", "在"),
    ("zh", "这"),
];

/// 输入只是一个声母时，把 [`SINGLE_INITIAL_TOP`] 里的字挪到第一个（在选过最多的字前面；
/// 自定义词之后还会排到它前面）。候选里没有这个字就不动。双拼不用：单键是双拼的半个音节。
fn pin_single_initial(input: &str, candidates: &mut Vec<Candidate>) {
    let Some(&(_, top)) = SINGLE_INITIAL_TOP.iter().find(|(key, _)| *key == input) else {
        return;
    };
    if let Some(i) = candidates
        .iter()
        .position(|c| c.text == top && c.words.len() == 1)
    {
        let pinned = candidates.remove(i);
        candidates.insert(0, pinned);
    }
}

fn promote_picked(candidates: &mut Vec<Candidate>) {
    let picked = |c: &Candidate| {
        c.features.history_use_count > 0.0
            && c.features.typo_count == 0.0
            && c.features.prefix_completion == 0.0
            && c.features.full_jianpin == 0.0
    };
    let Some(best) = candidates
        .iter()
        .enumerate()
        .filter(|(_, c)| picked(c))
        .max_by(|a, b| {
            a.1.features
                .history_use_count
                .total_cmp(&b.1.features.history_use_count)
                .then_with(|| b.0.cmp(&a.0))
        })
        .map(|(i, _)| i)
    else {
        return;
    };
    let single = candidates[best].text.chars().count() <= 1;
    let target = if single { 1 } else { 0 };
    if best <= target {
        return;
    }
    // 排在目标位置之前的候选被选得更多，就不动它
    if candidates[..best]
        .iter()
        .take(target + 1)
        .any(|c| c.features.history_use_count >= candidates[best].features.history_use_count)
    {
        return;
    }
    let c = candidates.remove(best);
    candidates.insert(target, c);
    for i in 1..candidates.len() {
        if candidates[i].score >= candidates[i - 1].score {
            candidates[i].score = candidates[i - 1].score - 1e-3;
        }
    }
}

/// 句首词只在多音节输入里有意义，而且只能在音节边界上切。
///
/// 单音节的 `dan` 不该出「大」（da + 剩个 n），`xian` 不该出「下」：
/// 那是把一个打完的音节拆开了，只会把第一页塞满没用的字。
/// 第一个整句候选是精确全拼时，句首词必须正好用完它的前几个音节；
/// 是简拼或纠错结果时没法对齐字母，只要求它至少两个音节。
fn prefix_on_syllable_boundaries(
    result: &[Candidate],
    normalized: &str,
    prefix: &mut Vec<Candidate>,
) {
    let Some(top) = result.iter().find(|c| !is_raw_candidate(c)) else {
        prefix.clear();
        return;
    };
    let syllables: Vec<&str> = top.pinyin.split_whitespace().collect();
    if syllables.len() < 2 {
        prefix.clear();
        return;
    }
    let letters: String = normalized
        .chars()
        .filter(|c| c.is_ascii_alphabetic())
        .collect();
    if top.features.full_jianpin > 0.0 || syllables.concat().len() > letters.len() + 2 {
        // 简拼（zgrm）字母和音节对不上，不按边界筛
        return;
    }
    // 从头对齐：补全和纠错只改动对不上的那一段，前面对得上的音节边界照样可信
    let mut boundaries = Vec::new();
    let mut at = 0;
    for syllable in &syllables[..syllables.len() - 1] {
        if !letters[at..].starts_with(syllable) {
            break;
        }
        at += syllable.len();
        boundaries.push(at);
    }
    let exact = top.features.typo_count == 0.0;
    // consumed 此时还是字母数（隔音符也算一个字符）
    prefix.retain(|p| {
        let used = normalized
            .chars()
            .take(p.consumed)
            .filter(|c| c.is_ascii_alphabetic())
            .count();
        boundaries.contains(&used) && (!exact || p.features.typo_count == 0.0)
    });
    // 整句候选本身的开头（你好中国 -> 你好）最可能是对的，越长越省事，排最前
    let head = |p: &Candidate| top.text.starts_with(&p.text);
    prefix.sort_by_key(|p| std::cmp::Reverse(if head(p) { p.text.chars().count() } else { 0 }));
}

/// 全拼对不上时用的简拼图；走不通时返回 None。
///
/// - 全是声母（zg、jzm）：纯简拼，和以前一样；
/// - 有韵母（kyi、yongzwen）：全拼混简拼，每个音节可以打全也可以只打声母。
///   全拼加补全已经能解释时（打到一半的 yanzhon）不用：结果一样，混简拼的路径却多得多，
///   长句逐键会从几毫秒涨到几十毫秒。`completion_explains` 是「全拼加补全、不靠纠错能走完」。
fn abbrev_graph(
    parsed: &crate::syllable::ParsedInput,
    completion_explains: bool,
) -> Option<SyllableGraph> {
    let all_initials = parsed
        .letters
        .iter()
        .all(|&b| crate::syllable::is_jianpin_letter(b));
    if !all_initials && completion_explains {
        return None;
    }
    let graph = SyllableGraph::build(
        parsed,
        GraphOptions {
            mode: if all_initials {
                GraphMode::Jianpin
            } else {
                GraphMode::Mixed
            },
            allow_erhua: false,
            typo: false,
            completion: false,
        },
    );
    graph.has_complete_path().then_some(graph)
}

/// 全拼和只打声母的音节混着的候选（k yi -> 可以，yong z wen -> 用中文）。
/// 快捷短语排在第几个候选的位置（从 0 数）：第 5 个，落在第一页里又不抢前几个。
const QUICK_PHRASE_AT: usize = 4;

/// 快捷短语文件里的 \n \t \\ 换回换行、制表符、反斜杠（和 Swift 的 QuickPhrases.unescape 一样）。
fn unescape_phrase(text: &str) -> String {
    let mut result = String::with_capacity(text.len());
    let mut escaping = false;
    for c in text.chars() {
        if escaping {
            result.push(match c {
                'n' => '\n',
                't' => '\t',
                other => other,
            });
            escaping = false;
        } else if c == '\\' {
            escaping = true;
        } else {
            result.push(c);
        }
    }
    result
}

fn is_mixed_jianpin(c: &Candidate) -> bool {
    c.features.full_jianpin > 0.0
        && c.pinyin
            .split_whitespace()
            .any(|s| !crate::syllable::is_abbrev_syllable(s))
}

/// 最后一个音节之前就有只打了声母的音节。
fn abbrev_before_last(c: &Candidate) -> bool {
    let syllables: Vec<&str> = c.pinyin.split_whitespace().collect();
    syllables.len() >= 2
        && syllables[..syllables.len() - 1]
            .iter()
            .any(|s| crate::syllable::is_abbrev_syllable(s))
}

/// 原始串 / 英文候选（append_raw_candidate 插进来的）。
fn is_raw_candidate(c: &Candidate) -> bool {
    c.words.len() == 1 && c.words[0].pinyin.is_empty() && c.features.coverage_score == 0.0
}

/// 整个输入是不是只有一个音节、两个音节……（按第一个非原始串候选的拼音数）。
fn syllable_count(result: &[Candidate]) -> usize {
    result
        .iter()
        .find(|c| !is_raw_candidate(c))
        .map(|c| c.pinyin.split_whitespace().count())
        .unwrap_or(0)
}

/// 候选把输入切成的各个音节在输入里的终点（字母数）；拼音和输入的长度对不上（补全、纠错过）时没有。
fn syllable_ends(c: &Candidate, len: usize) -> Option<Vec<usize>> {
    let mut at = 0;
    let ends: Vec<usize> = c
        .pinyin
        .split_whitespace()
        .map(|syllable| {
            at += syllable.len();
            at
        })
        .collect();
    (at == len).then_some(ends)
}

/// 插到 `at` 位置的候选该给的分数：夹在前后两个之间。
fn score_between(candidates: &[Candidate], at: usize) -> f64 {
    match (
        at.checked_sub(1).and_then(|i| candidates.get(i)),
        candidates.get(at),
    ) {
        (None, None) => -1.0,
        (None, Some(next)) => next.score + 1.0,
        (Some(prev), None) => prev.score - 1.0,
        (Some(prev), Some(next)) => (prev.score + next.score) / 2.0,
    }
}

/// 整句候选：几个词拼起来的、用完整个输入的候选。
fn is_sentence(c: &Candidate) -> bool {
    c.words.len() >= 2 && !is_raw_candidate(c)
}

/// 两个候选只差最后一个字（横向候选词 / 横向候选此）。
///
/// 这种候选没必要单独占位置：用户选整句的开头（横向候选），再选最后一个字就行。
fn differs_only_at_tail(a: &str, b: &str) -> bool {
    let a: Vec<char> = a.chars().collect();
    let b: Vec<char> = b.chars().collect();
    a.len() == b.len() && a.len() >= 2 && a[..a.len() - 1] == b[..b.len() - 1]
}

/// 整句候选最多留几个：越长的输入越可能要换个整句，短输入的「整句」多半是两个单字的拼凑。
fn sentence_cap(syllables: usize) -> usize {
    match syllables {
        0..=2 => 1,
        3 => 2,
        _ => 3,
    }
}

/// 第一个整句候选去掉最后一个词（横向候选词 -> 横向候选），作为句首候选。
///
/// 整句只是最后一个词错了时，选它再选最后一个词，比翻页找整句快。
/// 只给精确全拼的整句，开头至少两个音节（一个音节的开头本来就在句首词里）。
/// consumed 先存「用掉的字符数」（隔音符算一个），由调用方换算成字节。
fn sentence_head(result: &[Candidate], normalized: &str) -> Option<Candidate> {
    let top = result.iter().find(|c| !is_raw_candidate(c))?;
    if !is_sentence(top)
        || top.features.typo_count > 0.0
        || top.features.prefix_completion > 0.0
        || top.features.full_jianpin > 0.0
    {
        return None;
    }
    let head_words = &top.words[..top.words.len() - 1];
    let syllables: Vec<&str> = head_words
        .iter()
        .flat_map(|w| w.pinyin.split_whitespace())
        .collect();
    if syllables.len() < 2 || head_words.iter().any(|w| !w.known) {
        return None;
    }
    // 拼音要和输入从头对得上，才能知道切在第几个字母
    let letters: String = normalized
        .chars()
        .filter(|c| c.is_ascii_alphabetic())
        .collect();
    let joined = syllables.concat();
    if !letters.starts_with(&joined) {
        return None;
    }
    let mut seen = 0usize;
    let mut consumed = 0usize;
    for (i, ch) in normalized.chars().enumerate() {
        if ch.is_ascii_alphabetic() {
            seen += 1;
        }
        if seen == joined.len() {
            consumed = i + 1;
            break;
        }
    }
    let chars: usize = head_words.iter().map(|w| w.text.chars().count()).sum();
    Some(Candidate {
        text: top.text.chars().take(chars).collect(),
        pinyin: syllables.join(" "),
        score: top.score,
        features: Feature::default(),
        words: head_words.to_vec(),
        consumed,
    })
}

/// 把整句候选和句首候选排成最终列表，总数不超过 max（原始串/英文候选不会被截掉，位置不变）。
///
/// 照着微信输入法的做法：整句只留几个，而且只差最后一个字的整句不留；
/// 然后是整个输入正好是一个词的候选（同音词），再是句首候选——长的在前、单字在后。
/// 长输入（4 个音节以上）的第一个整句常常不全对，最好的句首候选放第二位。
fn compose_candidates(result: &mut Vec<Candidate>, prefix: Vec<Candidate>, max: usize) {
    let syllables = syllable_count(result);
    let cap = sentence_cap(syllables);
    // 原始串记下原来的位置，排完再插回去
    let raw: Vec<(usize, Candidate)> = result
        .iter()
        .enumerate()
        .filter(|(_, c)| is_raw_candidate(c))
        .map(|(i, c)| (i, c.clone()))
        .collect();
    let whole: Vec<Candidate> = std::mem::take(result)
        .into_iter()
        .filter(|c| !is_raw_candidate(c))
        .collect();

    let mut kept: Vec<Candidate> = Vec::new();
    let mut sentences = 0usize;
    for c in whole {
        if is_sentence(&c) {
            let first = kept.is_empty();
            if !first
                && (sentences >= cap || kept.iter().any(|k| differs_only_at_tail(&k.text, &c.text)))
            {
                continue;
            }
            sentences += 1;
        }
        kept.push(c);
    }

    let mut seen: HashMap<String, ()> = HashMap::new();
    let prefix: Vec<Candidate> = prefix
        .into_iter()
        .filter(|p| !kept.iter().any(|r| r.text == p.text))
        .filter(|p| seen.insert(p.text.clone(), ()).is_none())
        .collect();

    // 排第一的没纠错时，纠错出来的整句/整词放到句首词后面：`bujianyi` 打的就是
    // 不建议，「古剑一」（b 当 g）不该排在「不见」前面
    let exact_first = kept.first().is_some_and(|c| c.features.typo <= 0.0);
    let (kept, corrected): (Vec<Candidate>, Vec<Candidate>) = if exact_first {
        kept.into_iter().partition(|c| c.features.typo <= 0.0)
    } else {
        (kept, Vec::new())
    };
    let long_sentence = syllables >= 4 && kept.first().map(is_sentence).unwrap_or(false);
    let mut merged: Vec<Candidate> =
        Vec::with_capacity(kept.len() + prefix.len() + corrected.len());
    let mut prefix = prefix.into_iter();
    let mut kept = kept.into_iter();
    if long_sentence {
        merged.extend(kept.by_ref().take(1));
        merged.extend(prefix.by_ref().take(1));
    }
    merged.extend(kept);
    merged.extend(prefix);
    merged.extend(corrected);
    merged.truncate(max.saturating_sub(raw.len()).max(1));
    for (at, c) in raw {
        let at = at.min(merged.len());
        merged.insert(at, c);
    }
    // 分数改成单调递减，后面再按分数重排（繁体转换）顺序也不变
    for i in 1..merged.len() {
        if merged[i].score >= merged[i - 1].score {
            merged[i].score = merged[i - 1].score - 1e-3;
        }
    }
    *result = merged;
}

fn dedupe_by_text(candidates: Vec<Candidate>) -> Vec<Candidate> {
    let mut best: HashMap<String, Candidate> = HashMap::new();
    for candidate in candidates {
        match best.entry(candidate.text.clone()) {
            Entry::Vacant(slot) => {
                slot.insert(candidate);
            }
            Entry::Occupied(mut slot) => {
                if candidate.score > slot.get().score {
                    slot.insert(candidate);
                }
            }
        }
    }
    best.into_values().collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lexicon::MemoryLexicon;
    use crate::lm::BigramLm;

    fn engine(tsv: &str) -> Engine {
        let lexicon: Arc<dyn Lexicon> = Arc::new(MemoryLexicon::from_tsv_str(tsv).unwrap());
        let lm: Arc<dyn LanguageModel> = Arc::new(BigramLm::default());
        Engine::new(lexicon, lm)
    }

    fn default_engine() -> Engine {
        engine(concat!(
            "xian\t先\t1000\n",
            "xi an\t西安\t500\n",
            "xi\t西\t400\n",
            "an\t安\t300\n",
            "zhong guo\t中国\t800\n",
            "ni hao\t你好\t100000\n",
            "hua r\t花儿\t100\n",
        ))
    }

    #[test]
    fn history_boosts_selection() {
        let e = engine("shi\t是\t900\nshi\t事\t800\n");
        let first = e.input_at("shi", 1_000_000);
        assert_eq!(first[0].text, "是", "默认按频次");

        for i in 0..5 {
            e.record_selection_at("事", 1_000_000 + i);
        }
        assert_eq!(e.history_count("事"), 5);

        let after = e.input_at("shi", 1_000_100);
        assert_eq!(
            after[0].text,
            "事",
            "选过多次的词应当排到前面: {:?}",
            after.iter().map(|c| c.text.as_str()).collect::<Vec<_>>()
        );
    }

    #[test]
    fn old_selection_still_ranks_above_unused_word() {
        // 以前的历史特征按 ln(1+秒) 扣分：一天前选过的词反而排在没选过的后面
        let e = engine("shi\t是\t900\nshi\t事\t800\n");
        e.record_selection_at("事", 0);
        e.record_selection_at("事", 1);
        let day = 24 * 3600 * 1000;
        let after = e.input_at("shi", day);
        assert_eq!(
            after[0].text,
            "事",
            "{:?}",
            after.iter().map(|c| &c.text).collect::<Vec<_>>()
        );
        // 半年不用就退回去
        let later = e.input_at("shi", 180 * day);
        assert_eq!(later[0].text, "是");
    }

    #[test]
    fn quick_phrases_join_candidates_when_code_matches() {
        let e = engine(concat!(
            "da zi\t打字\t50000\n",
            "di zhi\t地址\t50000\n",
            "da\t大\t500000\n",
            "zi\t字\t500000\n",
        ));
        let n = e.set_quick_phrases("# 注释\ndz\t北京市海淀区\nDZ\t第二个地址\nqm\t张三\\n电话 123\nbad1\tx\nyx\t\n");
        assert_eq!(n, 3, "编码有数字的、短语空的不要；编码大小写当成一样");
        let list = e.input("dz");
        let first = list.iter().position(|c| c.text == "北京市海淀区").expect("短语进了候选");
        let second = list.iter().position(|c| c.text == "第二个地址").unwrap();
        assert_eq!(first, QUICK_PHRASE_AT.min(list.len() - 2));
        assert_eq!(second, first + 1, "同一个编码的按添加的先后");
        assert!(e.input("qm").iter().any(|c| c.text == "张三\n电话 123"), "\\n 换回换行");
        assert!(!e.input("dzs").iter().any(|c| c.text == "北京市海淀区"), "编码要整个对上");
        e.set_quick_phrases("");
        assert!(!e.input("dz").iter().any(|c| c.text == "北京市海淀区"), "清空后不再出现");
    }

    #[test]
    fn custom_words_rank_first_and_reload_replaces() {
        let e = engine(concat!(
            "ni hao\t你好\t332885\n",
            "zhang san\t张三\t20000\n",
            "zhang\t张\t500000\n",
            "san\t三\t500000\n",
        ));
        e.lexicon()
            .set_custom_tsv("# 注释\nni hao\t妮好\nwo de you xiang\t我的邮箱\nbad xx\t坏\n");
        assert_eq!(e.lexicon().custom_words().len(), 2, "不合法的拼音跳过");
        assert_eq!(e.input_at("nihao", 1)[0].text, "妮好");
        assert_eq!(e.input_at("wodeyouxiang", 1)[0].text, "我的邮箱");
        // 自定义词不进用户词库，保存时不会写出去
        assert!(e.user_words().is_empty());

        e.lexicon().set_custom_tsv("zhang san\t章三\n");
        assert_eq!(e.input_at("nihao", 1)[0].text, "你好", "旧的自定义词去掉了");
        assert_eq!(e.input_at("zhangsan", 1)[0].text, "章三");
        e.lexicon().set_custom_tsv("");
        assert_eq!(e.input_at("zhangsan", 1)[0].text, "张三");
    }

    #[test]
    fn learned_pair_fixes_homophone_inside_sentence() {
        let e = engine(concat!(
            "wo men\t我们\t900000\n",
            "zai\t在\t900000\n",
            "zai\t再\t300000\n",
            "tao lun\t讨论\t50000\n",
        ));
        let first = e.input_at("womenzaitaolun", 10);
        assert_eq!(first[0].text, "我们在讨论", "没学之前按词频");
        // 用户一段一段选出「我们再讨论」：我们 -> 再 -> 讨论
        e.set_context("");
        e.record_selection_at("我们", 10);
        e.set_context("我们");
        e.input_at("zaitaolun", 10);
        e.record_selection_at("再", 11);
        e.set_context("我们再");
        e.input_at("taolun", 11);
        e.record_selection_at("讨论", 12);
        e.set_context("");

        let after = e.input_at("womenzaitaolun", 20);
        assert_eq!(
            after[0].text,
            "我们再讨论",
            "{:?}",
            after.iter().map(|c| &c.text).collect::<Vec<_>>()
        );
    }

    #[test]
    fn previous_commit_is_context_for_next_word() {
        let e = engine("zai\t在\t900000\nzai\t再\t300000\nhui tou\t回头\t1000\nhui\t回\t1000\n");
        // 上一次上屏的是「回头」，这次打 zai：学过「回头 -> 再」以后排第一
        e.input_at("huitou", 1);
        e.record_selection_at("回头", 1);
        e.set_context("回头");
        e.input_at("zai", 1);
        e.record_selection_at("再", 2);

        e.set_context("回头");
        e.input_at("huitou", 3);
        e.record_selection_at("回头", 3);
        let with_context = e.input_at("zai", 4);
        assert_eq!(with_context[0].text, "再");

        // 光标前不是「回头」时不受影响（「再」本身选过一次，热度还在，所以换个更远的时间）
        e.set_context("别的");
        let without = e.input_at("zai", 4 + 365 * 24 * 3600 * 1000);
        assert_eq!(without[0].text, "在");
    }

    #[test]
    fn history_survives_save_and_load() {
        let tsv = "shi\t是\t900\nshi\t事\t800\n";
        let e = engine(tsv);
        e.record_selection_at("事", now_ms());
        let dir = std::env::temp_dir().join(format!("wotype-hist-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("history.tsv");
        e.save_history(&path).unwrap();

        let fresh = engine(tsv);
        assert!(fresh.load_history(&path).unwrap() >= 1);
        assert_eq!(fresh.input("shi")[0].text, "事");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn characters_without_a_glyph_are_not_offered() {
        // 𠼞 是扩展 B 区的字，macOS 自带字体里没有，候选窗里显示成 ?
        let e = engine("a\t啊\t9000\na\t𠼞\t10\na\t𠀀\t9\na gu\t阿古\t100\ngu\t古\t500\n");
        let texts = |e: &Engine| -> Vec<String> { e.input("a").into_iter().map(|c| c.text).collect() };
        assert!(texts(&e).contains(&"𠼞".to_string()), "没设回调时不筛");
        e.set_glyph_check(Some(Box::new(|c| c != '𠼞')));
        let list = texts(&e);
        assert!(!list.contains(&"𠼞".to_string()), "画不出来的不出：{list:?}");
        assert!(list.contains(&"𠀀".to_string()), "画得出来的扩展区字照出：{list:?}");
        assert_eq!(list[0], "啊");
        e.set_glyph_check(None);
        assert!(texts(&e).contains(&"𠼞".to_string()));
    }

    #[test]
    fn long_input_keeps_few_sentences_then_words_and_chars() {
        let e = engine(concat!(
            "heng xiang\t横向\t5000\n",
            "hou xuan ci\t候选词\t3000\n",
            "hou xuan\t候选\t4000\n",
            "heng\t横\t3000\nheng\t恒\t2000\nheng\t衡\t1000\n",
            "ci\t此\t90000\nci\t次\t80000\nci\t词\t70000\nci\t刺\t20000\n",
            "xiang\t向\t5000\nhou\t后\t9000\nxuan\t选\t8000\n",
        ));
        let list = e.input("hengxianghouxuanci");
        let texts: Vec<&str> = list.iter().map(|c| c.text.as_str()).collect();
        let sentences = list
            .iter()
            .filter(|c| c.words.len() >= 2 && c.consumed == 18)
            .count();
        assert!(sentences <= 3, "整句最多 3 个：{texts:?}");
        // 只差最后一个字的整句不重复出现
        let tail_variants = texts
            .iter()
            .filter(|t| t.starts_with("横向候选") && t.chars().count() == 5)
            .count();
        assert_eq!(tail_variants, 1, "{texts:?}");
        assert!(texts.contains(&"横向"), "{texts:?}");
        assert!(texts.contains(&"横"), "后面要有单字：{texts:?}");
        let word = texts.iter().position(|t| *t == "横向").unwrap();
        let single = texts.iter().position(|t| *t == "横").unwrap();
        assert!(word < single, "词在单字前面：{texts:?}");
    }

    #[test]
    fn sentence_head_is_offered_for_long_input() {
        let e = engine(concat!(
            "wo\t我\t900000\n",
            "jin tian\t今天\t100000\n",
            "wan shang\t晚上\t100000\n",
            "yao\t要\t500000\n",
            "jia ban\t加班\t20000\n",
            "jia ban\t甲板\t19000\n",
        ));
        let list = e.input("wojintianwanshangyaojiaban");
        let head = list
            .iter()
            .find(|c| c.text == "我今天晚上要")
            .unwrap_or_else(|| panic!("{:?}", list.iter().map(|c| &c.text).collect::<Vec<_>>()));
        assert_eq!(head.consumed, "wojintianwanshangyao".len());
    }

    #[test]
    fn context_bigram_boosts_first_word() {
        let mut lm = BigramLm::new().with_backoff(0.001);
        lm.add_unigram("今天", 10.0);
        lm.add_unigram("天", 5.0);
        lm.add_unigram("田", 5.0);
        lm.add_bigram("今天", "天", 8.0);

        let lexicon: Arc<dyn Lexicon> =
            Arc::new(MemoryLexicon::from_tsv_str("tian\t田\t200\ntian\t天\t100\n").unwrap());
        let e = Engine::new(lexicon, Arc::new(lm));

        let before = e.input_at("tian", 1);
        assert_eq!(before[0].text, "田", "没有上下文时按频次");

        e.set_context("今天");
        let after = e.input_at("tian", 1);
        assert_eq!(
            after[0].text,
            "天",
            "上下文应当把 天 提上来: {:?}",
            after.iter().map(|c| c.text.as_str()).collect::<Vec<_>>()
        );
        let tian = after.iter().find(|c| c.text == "天").unwrap();
        let tian_farm = after.iter().find(|c| c.text == "田").unwrap();
        assert!(tian.features.with_context == 1.0);
        assert!(
            tian.features.context_bigram_score > tian_farm.features.context_bigram_score,
            "{} vs {}",
            tian.features.context_bigram_score,
            tian_farm.features.context_bigram_score
        );
    }

    #[test]
    fn user_word_is_usable() {
        let e = engine("ni hao\t你好\t10\n");
        assert!(e.add_user_word("wo wo te", "我特", 5000.0).is_ok());
        assert_eq!(e.user_words().len(), 1);
        let cands = e.input("wowote");
        assert!(
            cands.iter().any(|c| c.text == "我特"),
            "用户词应当能输入: {:?}",
            cands.iter().map(|c| c.text.as_str()).collect::<Vec<_>>()
        );
        assert!(e.remove_user_word("我特"));
        let after = e.input("wowote");
        assert!(!after.iter().any(|c| c.text == "我特"));
    }

    #[test]
    fn invalid_user_pinyin_rejected() {
        let e = engine("ni hao\t你好\t10\n");
        assert!(e.add_user_word("zzz", "坏词", 1.0).is_err());
        assert!(e.user_words().is_empty());
    }

    #[test]
    fn partial_tail_yields_completions() {
        let e = default_engine();
        let c = e.input("nih");
        assert!(
            c.iter().any(|x| x.text == "你好"),
            "nih 应当补全出 你好: {:?}",
            c.iter().map(|x| x.text.as_str()).collect::<Vec<_>>()
        );
        let c = e.input("zhongg");
        assert!(
            c.iter().any(|x| x.text == "中国"),
            "zhongg 应当补全出 中国: {:?}",
            c.iter().map(|x| x.text.as_str()).collect::<Vec<_>>()
        );
    }

    #[test]
    fn incomplete_last_syllable_prefers_real_word() {
        let e = default_engine();
        let c = e.input("niha");
        assert_eq!(c[0].text, "你好", "niha 应当优先给出 你好");
    }

    #[test]
    fn fuzzy_matches_zh_z() {
        let lexicon: Arc<dyn Lexicon> =
            Arc::new(MemoryLexicon::from_tsv_str("zhi dao\t知道\t5000\n").unwrap());
        let lm: Arc<dyn LanguageModel> = Arc::new(BigramLm::default());
        let mut e = Engine::new(lexicon, lm);
        // 纠错会把 zidao 当成漏按 h，这里只测模糊音开关
        e.set_typo_correction(false);
        assert!(
            !e.input("zidao").iter().any(|c| c.text == "知道"),
            "默认关闭模糊音时不应命中"
        );
        e.set_fuzzy(true);
        assert!(
            e.input("zidao").iter().any(|c| c.text == "知道"),
            "开启后 zi dao 应当匹配 zhi dao"
        );
    }

    #[test]
    fn fuzzy_also_applies_when_exact_reading_has_words() {
        // zi dao 原样就有「自导」：以前只在原样查不到时才退到模糊音，「知道」出不来
        let lexicon: Arc<dyn Lexicon> = Arc::new(
            MemoryLexicon::from_tsv_str("zhi dao\t知道\t500000\nzi dao\t自导\t300\n").unwrap(),
        );
        let lm: Arc<dyn LanguageModel> = Arc::new(BigramLm::default());
        let mut e = Engine::new(lexicon, lm);
        e.set_typo_correction(false);
        e.set_fuzzy(true);
        let texts: Vec<String> = e.input("zidao").into_iter().map(|c| c.text).collect();
        assert!(
            texts.contains(&"知道".to_string()) && texts.contains(&"自导".to_string()),
            "{texts:?}"
        );
    }

    #[test]
    fn fuzzy_matches_nasal() {
        let lexicon: Arc<dyn Lexicon> =
            Arc::new(MemoryLexicon::from_tsv_str("shang dian\t商店\t5000\n").unwrap());
        let lm: Arc<dyn LanguageModel> = Arc::new(BigramLm::default());
        let mut e = Engine::new(lexicon, lm);
        e.set_fuzzy(true);
        assert!(
            e.input("sangdian").iter().any(|c| c.text == "商店"),
            "sang dian 应当匹配 shang dian"
        );
    }

    #[test]
    fn shuangpin_input() {
        let lexicon: Arc<dyn Lexicon> = Arc::new(
            MemoryLexicon::from_tsv_str("zhong guo\t中国\t8000\nni hao\t你好\t10000\n").unwrap(),
        );
        let lm: Arc<dyn LanguageModel> = Arc::new(BigramLm::default());
        let mut e = Engine::new(lexicon, lm);
        assert!(
            !e.input("vsgo").iter().any(|c| c.text == "中国"),
            "默认全拼模式下 vsgo 不应命中"
        );
        e.set_shuangpin(true);
        assert!(
            e.input("vsgo").iter().any(|c| c.text == "中国"),
            "双拼 vsgo 应当命中 中国"
        );
        assert!(
            e.input("nihk").iter().any(|c| c.text == "你好"),
            "双拼 nihk 应当命中 你好"
        );
    }

    #[test]
    fn english_input_yields_raw_candidate() {
        let e = default_engine();
        let c = e.input("hello");
        assert_eq!(c.first().map(|x| x.text.as_str()), Some("hello"));
        assert!(c.iter().any(|x| x.text == "hello"));

        // 原始大小写要保留
        let c = e.input("Hello");
        assert_eq!(c[0].text, "Hello");

        // 只有未登录兜底时，原始串排最前
        let c = e.input("ok");
        assert_eq!(
            c[0].text,
            "ok",
            "{:?}",
            c.iter().map(|x| &x.text).collect::<Vec<_>>()
        );
    }

    #[test]
    fn known_english_word_beats_typo_corrected_chinese() {
        let e = engine(concat!(
            "he\t和\t9000\n",
            "lo\t咯\t500\n",
            "she\t设\t5000\n",
            "shen\t神\t9000\n",
            "ni hao\t你好\t100000\n",
        ));
        assert_eq!(
            e.load_english_str("hello\thello\nshe\tshe\nGitHub\tGitHub\nJanuary\tJan\n"),
            3
        );
        let texts =
            |input: &str| -> Vec<String> { e.input(input).into_iter().map(|c| c.text).collect() };

        // 中文只能靠纠错凑出来时，已知英文词排第一
        assert_eq!(texts("hello")[0], "hello");
        // 全小写输入用词表里的写法，自己打了大写就照原样
        assert_eq!(texts("github")[0], "GitHub");
        assert_eq!(texts("Github")[0], "Github");
        // 本身就是完整拼音的英文词，中文在前，英文排第 6（候选不足时排最后）
        let she = texts("she");
        let pos = she.iter().position(|t| t == "she").expect("应当有 she");
        assert!(pos == 5 || (pos >= 1 && pos == she.len() - 1), "{she:?}");
        // 缩写编码（Jan -> January）不当作英文词
        assert!(!texts("jan").iter().any(|t| t == "January"));
    }

    #[test]
    fn exact_word_is_not_overridden_by_completion_or_typo() {
        // 重点的词频比种地高 20 倍，补全（zhongdi -> zhong dian）的分数会比精确词高
        let e = engine(concat!(
            "zhong dian\t重点\t500988\n",
            "zhong di\t种地\t25085\n",
            "zhong\t中\t900000\n",
            "di\t地\t800000\n",
            "ka\t卡\t402256\n",
            "kan\t看\t1500000\n",
            "zhong guo\t中国\t500000\n",
            "gu\t骨\t90000\n",
            "shi\t是\t9000000\n",
            "dan\t但\t900000\n",
            "shi dan\t实弹\t3175\n",
            "shi dang\t适当\t300000\n",
            "ta\t他\t3000000\n",
            "ta me\t他么\t333\n",
            "ta men\t他们\t3000000\n",
        ));
        let texts =
            |input: &str| -> Vec<String> { e.input(input).into_iter().map(|c| c.text).collect() };
        let zhongdi = texts("zhongdi");
        assert_eq!(zhongdi[0], "种地", "{zhongdi:?}");
        assert!(
            zhongdi.iter().any(|t| t == "重点"),
            "补全仍然在候选里：{zhongdi:?}"
        );
        assert_eq!(texts("ka")[0], "卡");
        // 整个输入是一个词时，单字凑出来的（是 | 但）也不能压过它
        assert_eq!(texts("shidan")[0], "实弹");
        // 精确结果只是单字拼凑（中 | 骨）时用户多半没打完，补全照常排第一
        assert_eq!(texts("zhonggu")[0], "中国");
        // 生僻词（词频低于下限）不受保护
        assert_eq!(texts("tame")[0], "他们");
    }

    #[test]
    fn prefix_candidates_do_not_split_a_syllable() {
        let e = engine(concat!(
            "dan\t但\t900000\n",
            "da\t大\t900000\n",
            "ni hao\t你好\t100000\n",
            "ni\t你\t900000\n",
            "zhong guo\t中国\t500000\n",
        ));
        let dan: Vec<String> = e.input("dan").into_iter().map(|c| c.text).collect();
        assert!(!dan.iter().any(|t| t == "大"), "单音节不出句首词：{dan:?}");
        let long = e.input("nihaozhongguo");
        assert_eq!(long[0].text, "你好中国");
        let head = long
            .iter()
            .position(|c| c.text == "你好")
            .expect("应当有句首词 你好");
        assert!(
            head <= 1,
            "{:?}",
            long.iter().map(|c| &c.text).collect::<Vec<_>>()
        );
        assert!(long.len() <= e.config.max_candidates.max(1));
    }

    #[test]
    fn later_pages_list_every_homophone_and_head_word() {
        let mut tsv = String::new();
        for i in 0..40 {
            tsv.push_str(&format!("shi\t字{i}\t{}\n", 1000 - i));
        }
        tsv.push_str("shi jie\t世界\t9000\nshi jie\t视界\t50\njie\t界\t500\n");
        let mut e = engine(&tsv);
        e.set_max_candidates(300);
        let one: Vec<String> = e.input("shi").into_iter().map(|c| c.text).collect();
        for i in 0..40 {
            assert!(one.contains(&format!("字{i}")), "缺 字{i}: {one:?}");
        }
        let two = e.input("shijie");
        assert_eq!(two[0].text, "世界");
        let texts: Vec<&str> = two.iter().map(|c| c.text.as_str()).collect();
        assert!(texts.contains(&"视界"), "{texts:?}");
        // 翻到后面能选第一个音节的任意一个字，只用掉 shi
        let head = two.iter().find(|c| c.text == "字39").expect("单字在后面");
        assert_eq!(head.consumed, 3);

        let mut off = engine(&tsv);
        off.set_max_candidates(300);
        off.config.more_candidates = false;
        assert!(off.input("shi").len() < 40);
    }

    #[test]
    fn raw_candidate_survives_a_full_list() {
        let mut e = engine(concat!(
            "he\t和\t9000\nhe\t何\t8000\nhe\t合\t7000\n",
            "lo\t咯\t500\nluo\t落\t400\n",
        ));
        e.set_max_candidates(3);
        // hrlo 不是拼音（r 是 e 的邻键），中文全靠纠错，列表还是满的
        let c = e.input("hrlo");
        assert!(
            c.iter().any(|x| x.text == "hrlo"),
            "原始串不该被截掉: {:?}",
            c.iter().map(|x| &x.text).collect::<Vec<_>>()
        );
    }

    #[test]
    fn full_pinyin_does_not_add_raw_candidate() {
        let e = default_engine();
        assert!(
            !e.input("nihao").iter().any(|c| c.text == "nihao"),
            "完整覆盖时不应插入原始拼音串"
        );
    }

    #[test]
    fn traditional_candidates() {
        let lexicon: Arc<dyn Lexicon> =
            Arc::new(MemoryLexicon::from_tsv_str("zhong guo\t中国\t8000\n").unwrap());
        let lm: Arc<dyn LanguageModel> = Arc::new(BigramLm::default());
        let mut e = Engine::new(lexicon, lm);
        e.install_converter(Converter::from_tsv_str("国\t國\n").unwrap());
        assert_eq!(e.input("zhongguo")[0].text, "中国");
        e.set_traditional(true);
        assert_eq!(e.input("zhongguo")[0].text, "中國");
        // 分词文本也要跟着转
        assert_eq!(e.input("zhongguo")[0].words[0].text, "中國");
    }

    #[test]
    fn auto_learn_promotes_word() {
        let lexicon: Arc<dyn Lexicon> =
            Arc::new(MemoryLexicon::from_tsv_str("ni hao\t你好\t10000\n").unwrap());
        let lm: Arc<dyn LanguageModel> = Arc::new(BigramLm::default());
        let e = Engine::new(lexicon, lm);

        // 词库里没有「我特」，初始只能拿到原始串
        assert!(!e.input("wote").iter().any(|c| c.text == "我特"));

        // 选不够次数不学
        e.record_selection_with_pinyin("我特", Some("wo te"));
        e.record_selection_with_pinyin("我特", Some("wo te"));
        assert!(!e.input("wote").iter().any(|c| c.text == "我特"));

        // 第三次达到阈值
        e.record_selection_with_pinyin("我特", Some("wo te"));
        assert_eq!(e.user_words().len(), 1);
        assert!(
            e.input("wote").iter().any(|c| c.text == "我特"),
            "自动学习后应当能打出 我特"
        );
    }

    #[test]
    fn auto_learn_can_be_disabled() {
        let lexicon: Arc<dyn Lexicon> =
            Arc::new(MemoryLexicon::from_tsv_str("ni hao\t你好\t10000\n").unwrap());
        let lm: Arc<dyn LanguageModel> = Arc::new(BigramLm::default());
        let config = EngineConfig {
            auto_learn: false,
            ..EngineConfig::default()
        };
        let e = Engine::new(lexicon, lm).with_config(config);
        for _ in 0..5 {
            e.record_selection_with_pinyin("我特", Some("wo te"));
        }
        assert!(e.user_words().is_empty());
    }

    #[test]
    fn context_disambiguates_homophones() {
        // 同一拼音，两个候选：先（高频）、西安（低频）
        let lexicon: Arc<dyn Lexicon> =
            Arc::new(MemoryLexicon::from_tsv_str("xian\t先\t50000\nxi an\t西安\t1000\n").unwrap());
        // TSV 加载器会把二元组计数也记进一元，所以这里额外给「先」补一条
        // 高频搭配，让它在**没有上下文**时仍然靠词频胜出。
        let lm: Arc<dyn LanguageModel> = Arc::new(
            BigramLm::from_bigram_tsv_str("我\t西安\t9990\n我\t先\t10\n先\t的\t100000\n").unwrap(),
        );
        let e = Engine::new(lexicon, lm);

        // 没有上下文时，词频决定：先
        assert_eq!(e.input("xian")[0].text, "先");

        // 有上下文「我」之后，语言模型应当把 西安 顶上来
        e.set_context("我");
        assert_eq!(e.input("xian")[0].text, "西安", "上下文应当消除同音词歧义");
    }

    #[test]
    fn arpa_context_disambiguates() {
        let lexicon: Arc<dyn Lexicon> =
            Arc::new(MemoryLexicon::from_tsv_str("xian\t先\t50000\nxi an\t西安\t1000\n").unwrap());
        let arpa = "\\data\\\nngram 1=3\nngram 2=2\n\n\\1-grams:\n-1.0\t我\n-1.0\t先\n-1.0\t西安\n\n\\2-grams:\n-0.01\t我 西安\n-4.0\t我 先\n\n\\end\\\n";
        let lm: Arc<dyn LanguageModel> =
            Arc::new(ArpaLm::from_arpa_str(arpa).expect("ARPA 解析失败"));
        let e = Engine::new(lexicon, lm);
        assert_eq!(e.input("xian")[0].text, "先");
        e.set_context("我");
        assert_eq!(e.input("xian")[0].text, "西安");
    }

    #[test]
    fn context_uses_last_character() {
        // 中文上下文通常没有空格，必须能退到「最后一个字」去查 bigram
        let lexicon: Arc<dyn Lexicon> =
            Arc::new(MemoryLexicon::from_tsv_str("shi\t是\t50000\nshi\t事\t30000\n").unwrap());
        let lm: Arc<dyn LanguageModel> = Arc::new(
            BigramLm::from_bigram_tsv_str(
                "做\t事\t9990\n做\t是\t10\n是\t的\t100000\n事\t的\t100000\n",
            )
            .unwrap(),
        );
        let e = Engine::new(lexicon, lm);
        assert_eq!(e.input("shi")[0].text, "是");

        e.set_context("我今天做");
        assert_eq!(
            e.input("shi")[0].text,
            "事",
            "多字上下文应当用最后一个字查二元组"
        );
    }

    #[test]
    fn completion_does_not_extend_unknown_head() {
        // shesh：只能是 she + sh*，不能把 shesh 整体当成能解析的头
        let e = engine("she shi\t设施\t500\nshe\t设\t100\n");
        assert!(e.input("shesh").iter().any(|c| c.text == "设施"));
    }

    #[test]
    fn completion_extends_the_last_syllable() {
        // 「shesh」尾巴是 sh，应当能补成 设施(she shi)
        let lexicon: Arc<dyn Lexicon> = Arc::new(
            MemoryLexicon::from_tsv_str(
                "she shi\t设施\t9000\nshe sha\t射杀\t500\nshe shou\t射手\t400\n",
            )
            .unwrap(),
        );
        let e = Engine::new(lexicon, Arc::new(BigramLm::default()));
        let list = e.input("shesh");
        assert!(
            list.iter().take(3).any(|c| c.text == "设施"),
            "应当补出 设施: {:?}",
            list.iter().map(|c| &c.text).collect::<Vec<_>>()
        );
    }

    #[test]
    fn input_xian() {
        let e = default_engine();
        let cands = e.input("xian");
        let texts: Vec<&str> = cands.iter().map(|c| c.text.as_str()).collect();
        assert!(texts.contains(&"先"), "{:?}", texts);
        assert!(texts.contains(&"西安"), "{:?}", texts);
    }

    #[test]
    fn apostrophe_does_not_yield_xian_word() {
        let e = default_engine();
        let cands = e.input("xi'an");
        let texts: Vec<&str> = cands.iter().map(|c| c.text.as_str()).collect();
        assert!(texts.contains(&"西安"), "{:?}", texts);
        // 强制切分后不应再出现单音节 xian 对应的 先。
        assert!(!texts.contains(&"先"), "{:?}", texts);
    }

    #[test]
    fn jianpin_fallback() {
        let e = default_engine();
        let cands = e.input("zg");
        assert!(cands.iter().any(|c| c.text == "中国"), "{:?}", cands);
    }

    #[test]
    fn mixed_full_and_initial_only_syllables() {
        // 有的音节只打声母（省略韵母）：k yi -> 可以，yong z wen -> 用中文
        let e = engine(concat!(
            "ke yi\t可以\t50000\n",
            "ke\t可\t20000\n",
            "kui\t亏\t3000\n",
            "yi\t一\t100000\n",
            "yong\t用\t30000\n",
            "zhong wen\t中文\t20000\n",
            "zheng wen\t正文\t2000\n",
            "zen\t怎\t5000\n",
            "wen\t文\t10000\n",
        ));
        assert_eq!(e.input("kyi")[0].text, "可以");
        assert_eq!(e.input("yongzwen")[0].text, "用中文");
        // 打全了照旧
        assert_eq!(e.input("keyi")[0].text, "可以");
        assert_eq!(e.input("yongzhongwen")[0].text, "用中文");
    }

    #[test]
    fn stretched_mixed_parse_does_not_bury_raw_input() {
        // 没有英文词表时，Hello 被混简拼凑成「合理了哦」，原样输入不能垫底
        let e = engine(concat!(
            "he li\t合理\t50000\n",
            "le o\t了哦\t30000\n",
            "ke yi\t可以\t50000\n",
        ));
        assert_eq!(e.input("Hello")[0].text, "Hello");
        // 省略在词里面的照旧
        assert_eq!(e.input("kyi")[0].text, "可以");
    }

    #[test]
    fn erhua() {
        let e = default_engine();
        let cands = e.input("huar");
        assert!(cands.iter().any(|c| c.text == "花儿"), "{:?}", cands);
    }

    #[test]
    fn empty_input() {
        let e = default_engine();
        assert!(e.input("").is_empty());
        assert!(e.input("   ").is_empty());
    }

    #[test]
    fn unknown_input_falls_back_to_pinyin() {
        let e = engine("");
        let cands = e.input("xian");
        assert!(!cands.is_empty());
        assert_eq!(cands[0].text, "xian");
    }

    #[test]
    fn ltr_valid_reflects_ranker() {
        struct NullLtr;
        impl crate::rank::LtrModel for NullLtr {
            fn score(&self, _feature: &Feature) -> f32 {
                0.0
            }
        }
        let lexicon: Arc<dyn Lexicon> =
            Arc::new(MemoryLexicon::from_tsv_str("xian\t先\t1000\n").unwrap());
        let lm: Arc<dyn LanguageModel> = Arc::new(BigramLm::default());
        let ranker = Arc::new(LinearRanker::default().with_ltr(Arc::new(NullLtr), 1.0));
        let e = Engine::new(lexicon, lm).with_ranker(ranker);
        let cands = e.input("xian");
        assert!(!cands.is_empty());
        assert_eq!(cands[0].features.ltr_valid, 1.0);
    }
}
