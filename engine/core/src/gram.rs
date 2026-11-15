//! 语法模型：读 librime-octagram 的 `.gram` 文件（万象拼音的 wanxiang-lts-zh-hans.gram 就是这种），
//! 按「前文最后几个字 + 候选词」给候选打分。
//!
//! 文件格式、字符编码和打分规则移植自 librime-octagram（BSD 3-Clause，Copyright (c) 2014, RIME Developers），
//! 双数组的查找移植自 darts-clone（librime 自带的 include/darts.h）。
//!
//! 文件布局（小端）：
//! - 0..32：格式名，以 `Rime::Grammar/` 开头
//! - 32：校验和（u32，不用）
//! - 36：双数组的单元个数（u32）
//! - 40：双数组的位置（i32，相对于这个字段自己的偏移）
//! - 之后：darts-clone 双数组，每个单元 4 字节
//!
//! 键是 `encode` 编码后的「前文 + 词」，值是 `log(频次) × 10000` 取整。
//! 文件很大（几百 MB），用内存映射，只有查到的那几页会读进内存。

use std::fs::File;
use std::path::Path;

use anyhow::{bail, Context, Result};
use memmap2::Mmap;

use crate::lm::LanguageModel;

const FORMAT_PREFIX: &[u8] = b"Rime::Grammar/";
/// 一次前缀查询最多取几个结果（octagram 的 kMaxResults）。
const MAX_RESULTS: usize = 8;
const VALUE_SCALE: f64 = 10000.0;
/// 编码时一次最多取几个字（octagram 的 kMaxEncodedUnicode）。
const MAX_ENCODED_UNICODE: usize = 8;

/// 打分参数（octagram 的 grammar/* 配置）。默认值取万象给自己词库调好的那一组。
#[derive(Clone, Debug)]
pub struct GrammarConfig {
    /// 前文 + 词最多看几个字。
    pub collocation_max_length: usize,
    /// 搭配至少几个字才算「强搭配」。
    pub collocation_min_length: usize,
    pub collocation_penalty: f64,
    /// 什么搭配都没查到时的分数。
    pub non_collocation_penalty: f64,
    pub weak_collocation_penalty: f64,
    pub rear_penalty: f64,
    /// 打分乘上这个再交给束搜索。WoType 的词库分和 librime 的尺度不同，
    /// 在万象的评测语料上扫出来 0.4–0.6 最好（docs/05-万象词库与语法模型.md）。
    pub weight: f64,
}

impl Default for GrammarConfig {
    fn default() -> Self {
        Self {
            weight: 0.5,
            collocation_max_length: 6,
            collocation_min_length: 2,
            collocation_penalty: -14.0,
            non_collocation_penalty: -6.0,
            weak_collocation_penalty: -100.0,
            rear_penalty: -18.0,
        }
    }
}

impl GrammarConfig {
    /// 调参用（环境变量 WOTYPE_GRAM_CONFIG）：`max=6,min=2,coll=-14,non=-6,weak=-100,rear=-18,weight=0.5`，
    /// 没写的项不变，写错的忽略。
    pub fn with_overrides(mut self, text: &str) -> Self {
        for item in text.split(',') {
            let Some((key, value)) = item.split_once('=') else {
                continue;
            };
            let Ok(value) = value.trim().parse::<f64>() else {
                continue;
            };
            match key.trim() {
                "max" => self.collocation_max_length = value as usize,
                "min" => self.collocation_min_length = value as usize,
                "coll" => self.collocation_penalty = value,
                "non" => self.non_collocation_penalty = value,
                "weak" => self.weak_collocation_penalty = value,
                "rear" => self.rear_penalty = value,
                "weight" => self.weight = value,
                _ => {}
            }
        }
        self
    }
}

pub struct Grammar {
    mmap: Mmap,
    /// 双数组在文件里的起点（字节）和单元个数。
    array_start: usize,
    array_units: usize,
    pub config: GrammarConfig,
}

impl Grammar {
    pub fn open<P: AsRef<Path>>(path: P) -> Result<Self> {
        let path = path.as_ref();
        let file =
            File::open(path).with_context(|| format!("打不开语法模型 {}", path.display()))?;
        // SAFETY: 只读映射；文件在使用期间被别人改写属于使用错误（和 librime 一样）
        let mmap = unsafe { Mmap::map(&file) }
            .with_context(|| format!("映射语法模型失败 {}", path.display()))?;
        if mmap.len() < 44 || !mmap.starts_with(FORMAT_PREFIX) {
            bail!(
                "不是语法模型文件（文件头不是 Rime::Grammar/）：{}",
                path.display()
            );
        }
        let units = u32::from_le_bytes(mmap[36..40].try_into().unwrap()) as usize;
        let offset = i32::from_le_bytes(mmap[40..44].try_into().unwrap());
        let start = 40i64 + offset as i64;
        if offset == 0 || start < 44 || start as usize + units * 4 > mmap.len() {
            bail!("语法模型文件损坏（双数组位置不对）：{}", path.display());
        }
        let config = std::env::var("WOTYPE_GRAM_CONFIG")
            .map(|text| GrammarConfig::default().with_overrides(&text))
            .unwrap_or_default();
        Ok(Self {
            mmap,
            array_start: start as usize,
            array_units: units,
            config,
        })
    }

    pub fn with_config(mut self, config: GrammarConfig) -> Self {
        self.config = config;
        self
    }

    #[inline]
    fn unit(&self, id: usize) -> Option<u32> {
        if id >= self.array_units {
            return None;
        }
        let at = self.array_start + id * 4;
        Some(u32::from_le_bytes(
            self.mmap[at..at + 4].try_into().unwrap(),
        ))
    }

    /// 从 node 出发沿 key 往下走；走完整个 key 返回所在节点，走不通返回 None。（darts-clone traverse）
    fn traverse(&self, key: &[u8], mut node: usize) -> Option<usize> {
        let mut unit = self.unit(node)?;
        for &byte in key {
            let id = node ^ unit_offset(unit) ^ byte as usize;
            unit = self.unit(id)?;
            if unit_label(unit) != byte as u32 {
                return None;
            }
            node = id;
        }
        Some(node)
    }

    /// 从 node 出发，key 的各个前缀里在库里的那些：(前缀字节数, 值)。（darts-clone commonPrefixSearch）
    fn common_prefix_search(&self, key: &[u8], node: usize, out: &mut Vec<(usize, u32)>) {
        let Some(mut unit) = self.unit(node) else {
            return;
        };
        let mut pos = node ^ unit_offset(unit);
        for (i, &byte) in key.iter().enumerate() {
            pos ^= byte as usize;
            let Some(next) = self.unit(pos) else { return };
            unit = next;
            if unit_label(unit) != byte as u32 {
                return;
            }
            pos ^= unit_offset(unit);
            if unit_has_leaf(unit) && out.len() < MAX_RESULTS {
                if let Some(leaf) = self.unit(pos) {
                    out.push((i + 1, unit_value(leaf)));
                }
            }
        }
    }

    /// 以 context 开头、后面接 word 的某个前缀的那些键。（octagram GramDb::Lookup）
    fn lookup(&self, context: &[u8], word: &[u8], out: &mut Vec<(usize, u32)>) {
        out.clear();
        if let Some(node) = self.traverse(context, 0) {
            self.common_prefix_search(word, node, out);
        }
    }

    /// 给「前文 context 后面接 word」打分（对数尺度，越大越好）。is_rear：word 在句尾。
    /// 规则照搬 octagram 的 Octagram::Query。
    pub fn query(&self, context: &str, word: &str, is_rear: bool) -> f64 {
        let config = &self.config;
        let mut result = config.non_collocation_penalty;
        if context.is_empty() {
            return result;
        }
        let n = MAX_ENCODED_UNICODE.min(config.collocation_max_length.saturating_sub(1));
        let context_chars: Vec<char> = context.chars().collect();
        let context_len = context_chars.len().min(n);
        let context_tail: String = context_chars[context_chars.len() - context_len..]
            .iter()
            .collect();
        let context_query = encode(&context_tail);
        let word_chars: Vec<char> = word.chars().collect();
        let word_query_len = word_chars.len().min(n);
        let word_head: String = word_chars[..word_query_len].iter().collect();
        let word_query = encode(&word_head);

        let mut matches = Vec::with_capacity(MAX_RESULTS);
        let mut start = 0;
        let mut remaining = context_len;
        while remaining > 0 {
            self.lookup(&context_query[start..], &word_query, &mut matches);
            for &(length, value) in &matches {
                let match_len = unicode_length(&word_query[..length]);
                let collocation_len = remaining + match_len;
                // 整个前文 + 整个词都对上，也算强搭配
                let whole = start == 0 && length == word_query.len();
                let penalty = if collocation_len >= config.collocation_min_length || whole {
                    config.collocation_penalty
                } else {
                    config.weak_collocation_penalty
                };
                result = result.max(scale_value(value) + penalty);
            }
            start = advance(&context_query, start);
            remaining -= 1;
        }
        if is_rear && word_query_len == word_chars.len() {
            self.lookup(&word_query, b"$", &mut matches);
            if let Some(&(_, value)) = matches.first() {
                result = result.max(scale_value(value) + config.rear_penalty);
            }
        }
        result
    }
}

#[inline]
fn unit_has_leaf(unit: u32) -> bool {
    (unit >> 8) & 1 == 1
}

#[inline]
fn unit_value(unit: u32) -> u32 {
    unit & ((1 << 31) - 1)
}

#[inline]
fn unit_label(unit: u32) -> u32 {
    unit & ((1 << 31) | 0xFF)
}

#[inline]
fn unit_offset(unit: u32) -> usize {
    ((unit >> 10) << ((unit & (1 << 9)) >> 6)) as usize
}

fn scale_value(value: u32) -> f64 {
    value as f64 / VALUE_SCALE
}

/// 把 UTF-8 文字编码成 octagram 的键：ASCII 一字节，常用汉字（U+4000–U+9FFF）两字节，其余变长。
pub fn encode(text: &str) -> Vec<u8> {
    let mut out = Vec::with_capacity(text.len());
    for c in text.chars() {
        let u = c as u32;
        if u < 0x80 {
            out.push(if u == 0 { 0xE0 } else { u as u8 });
        } else if (0x4000..0xA000).contains(&u) {
            if u & 0xFF == 0 {
                out.push(0xE1);
                out.push(((u >> 8) + 0x40) as u8);
            } else {
                out.push(((u >> 8) + 0x40) as u8);
                out.push((u & 0xFF) as u8);
            }
        } else {
            let mut bits = 32;
            let mut v = u;
            while bits > 0 && v & 0xFE00_0000 == 0 {
                bits -= 7;
                v <<= 7;
            }
            let mut bytes = (bits + 6) / 7;
            out.push(0xE0 | bytes as u8);
            while bytes > 0 {
                bytes -= 1;
                out.push((((v >> 25) & 0x7F) | 0x80) as u8);
                v <<= 7;
            }
        }
    }
    out
}

/// 编码后的下一个字从哪个字节开始。
fn advance(encoded: &[u8], pos: usize) -> usize {
    let b = encoded[pos];
    pos + if b & 0x80 == 0 {
        1
    } else if b & 0xF0 == 0xE0 {
        (b & 0x0F) as usize + 1
    } else {
        2
    }
}

/// 编码后的这一段有几个字。
fn unicode_length(encoded: &[u8]) -> usize {
    let mut pos = 0;
    let mut count = 0;
    while pos < encoded.len() {
        pos = advance(encoded, pos);
        count += 1;
    }
    count
}

/// 把语法模型当语言模型用：按「这条路径最后几个字」打分。
pub struct GrammarLm {
    pub grammar: Grammar,
}

impl LanguageModel for GrammarLm {
    fn score(&self, prev: Option<&str>, cur: &str) -> f64 {
        self.grammar.config.weight * self.grammar.query(prev.unwrap_or(""), cur, false)
    }

    fn context_chars(&self) -> usize {
        self.grammar
            .config
            .collocation_max_length
            .saturating_sub(1)
            .min(MAX_ENCODED_UNICODE)
    }

    fn score_context(&self, _prev: Option<&str>, context: &str, cur: &str, is_rear: bool) -> f64 {
        self.grammar.config.weight * self.grammar.query(context, cur, is_rear)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encodes_like_octagram() {
        assert_eq!(encode("a"), b"a");
        // 中 U+4E2D -> 0x4E+0x40, 0x2D
        assert_eq!(encode("中"), vec![0x8E, 0x2D]);
        // 低字节为 0 的常用汉字：U+4E00 一 -> E1, 0x4E+0x40
        assert_eq!(encode("一"), vec![0xE1, 0x8E]);
        let text = encode("中a一");
        assert_eq!(unicode_length(&text), 3);
        assert_eq!(advance(&text, 0), 2);
    }

    /// 本机有万象的语法模型时才跑（文件几百 MB，不在仓库里）。WOTYPE_GRAM 可指定路径。
    fn grammar() -> Option<Grammar> {
        let path = std::env::var("WOTYPE_GRAM").ok().unwrap_or_else(|| {
            concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../../sample/wanxiang-lts-zh-hans.gram"
            )
            .to_string()
        });
        if !Path::new(&path).exists() {
            eprintln!("没有 {path}，跳过");
            return None;
        }
        Some(Grammar::open(path).expect("打开语法模型"))
    }

    #[test]
    fn real_model_prefers_natural_collocations() {
        let Some(g) = grammar() else { return };
        // 「信用卡还」后面接「款」比「宽」顺
        assert!(g.query("信用卡还", "款日", false) > g.query("信用卡还", "宽日", false));
        assert!(g.query("我在", "排队", false) > g.query("我在", "拍对", false));
        assert!(g.query("今天天气", "不错", false) > g.config.non_collocation_penalty);
        // 没有上文时是 non_collocation_penalty
        assert_eq!(g.query("", "你好", false), g.config.non_collocation_penalty);
    }
}
