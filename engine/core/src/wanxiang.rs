//! 把万象拼音的词表（rime-wanxiang / rime-wanxiang-data 的 `dicts` 目录，CC BY 4.0）转成
//! WoType 的词库：`lexicon.tsv`（拼音<TAB>词<TAB>词频）、`english.txt` 和 `mixed.txt`。
//!
//! 和 `tools/wanxiang2tsv.py` + `tools/add_hotwords.py` 做的事一样、输出逐字节相同
//! （有测试对着 `data/lexicon.tsv` 核对）。放进引擎是为了在线更新词库：用户机器上没有 Python。
//! 自己写的，没有用万象仓库里的工具代码（那些没有授权复用）。
//!
//! - 拼音去掉声调、音节之间空格分开；ü 写成 v（lǚ xíng → lv xing）
//! - 同一个词同一个读音出现多次时取词频最大的
//! - 多字词的词频低于 `min_weight` 的不要（单字一律保留，免得生僻字打不出来）
//! - 不读错音错字表 `cuoyin`（万象拿它在打错时给提示，直接当候选不合适）
//! - 热词表：词库里已有的词把词频提到不低于热词词频，没有的按热词表的拼音加在末尾

use std::collections::HashMap;
use std::fs;
use std::io::Write;
use std::path::Path;

use anyhow::{bail, Context, Result};

/// 读哪些词表、按什么顺序（万象默认方案 `wanxiang.dict.yaml` 的 import_tables，去掉 cuoyin）。
pub const TABLES: [&str; 6] = ["zi", "jichu", "duoyin", "diming", "mingren", "yiren"];
/// 多字词的最低词频，和 `scripts/make-data.sh` 的默认值一样（docs/05）。
pub const MIN_WEIGHT: f64 = 50.0;
/// 热词的词频。
const HOTWORD_FREQ: f64 = 30000.0;
/// 转出来的词库里必须有这些词：少一个就说明词表的格式变了，这份词库不能用。
const PROBES: [&str; 8] = ["你好", "中国", "我们", "什么", "知道", "可以", "现在", "时间"];

/// 转换结果。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Converted {
    /// 词库的词条数
    pub entries: usize,
    /// 英文词表的行数（没有英文词表时是 0）
    pub english: usize,
}

/// 去掉声调的拼音：`lǚ xíng` → `lv xing`。带不认识的字符时返回 None（这一行不要）。
pub(crate) fn plain_pinyin(pinyin: &str) -> Option<String> {
    let mut out = String::with_capacity(pinyin.len());
    for ch in pinyin.chars().flat_map(char::to_lowercase) {
        let base = match ch {
            'ā' | 'á' | 'ǎ' | 'à' => 'a',
            'ē' | 'é' | 'ě' | 'è' | 'ê' => 'e',
            'ī' | 'í' | 'ǐ' | 'ì' => 'i',
            'ō' | 'ó' | 'ǒ' | 'ò' => 'o',
            'ū' | 'ú' | 'ǔ' | 'ù' => 'u',
            'ü' | 'ǖ' | 'ǘ' | 'ǚ' | 'ǜ' => 'v',
            'ń' | 'ň' | 'ǹ' => 'n',
            'ḿ' => 'm',
            // 分开写的声调符号：u 后面的分音符（ü）变成 v，其余丢掉
            '\u{0308}' => {
                if out.ends_with('u') {
                    out.pop();
                    out.push('v');
                }
                continue;
            }
            '\u{0300}'..='\u{036f}' => continue,
            c if c.is_whitespace() => ' ',
            c => c,
        };
        out.push(base);
    }
    let joined = out.split(' ').filter(|s| !s.is_empty()).collect::<Vec<_>>().join(" ");
    let valid = !joined.is_empty()
        && joined
            .split(' ')
            .all(|syllable| syllable.bytes().all(|b| b.is_ascii_lowercase()));
    valid.then_some(joined)
}

/// 和 Python 的 `f"{x:g}"` 一样的写法（6 位有效数字，大数用科学计数法），
/// 这样转出来的词库和 Python 脚本的输出逐字节相同。
fn format_g(value: f64) -> String {
    if value == 0.0 {
        return "0".to_string();
    }
    // 先按 6 位有效数字舍入，再看指数
    let sci = format!("{value:.5e}");
    let (mantissa, exponent) = sci.split_once('e').unwrap_or((&sci, "0"));
    let exponent: i32 = exponent.parse().unwrap_or(0);
    let trim = |s: &str| {
        if s.contains('.') {
            s.trim_end_matches('0').trim_end_matches('.').to_string()
        } else {
            s.to_string()
        }
    };
    if !(-4..6).contains(&exponent) {
        let sign = if exponent < 0 { '-' } else { '+' };
        format!("{}e{sign}{:02}", trim(mantissa), exponent.abs())
    } else {
        trim(&format!("{value:.*}", (5 - exponent).max(0) as usize))
    }
}

/// 词表文件 `...` 之后的正文。
fn body(text: &str) -> Option<&str> {
    text.split_once("\n...\n").map(|(_, body)| body)
}

/// 把 `dicts` 目录转成 `out/lexicon.tsv`、`out/english.txt` 和 `out/mixed.txt`。
///
/// `source` 写在词库开头的注释里（来源、版本）。词条少于 `min_entries`、
/// 或者少了常用词（[`PROBES`]）就报错，不留下半成品。
pub fn convert(
    dicts: &Path,
    hotwords: Option<&Path>,
    out: &Path,
    min_weight: f64,
    min_entries: usize,
    source: &str,
) -> Result<Converted> {
    // (拼音, 词) -> 在 entries 里的位置；entries 保持第一次出现的顺序
    let mut index: HashMap<String, usize> = HashMap::new();
    let mut entries: Vec<(String, String, f64)> = Vec::new();
    let mut tables = Vec::new();
    for table in TABLES {
        let path = dicts.join(format!("{table}.dict.yaml"));
        let text = fs::read_to_string(&path).with_context(|| format!("读词表失败: {}", path.display()))?;
        let Some(body) = body(&text) else {
            continue;
        };
        tables.push(format!("dicts/{table}"));
        for line in body.lines() {
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let mut fields = line.split('\t');
            let (Some(word), Some(pinyin)) = (fields.next(), fields.next()) else {
                continue;
            };
            let Some(pinyin) = plain_pinyin(pinyin) else {
                continue;
            };
            let weight = fields.next().and_then(|w| w.trim().parse::<f64>().ok()).unwrap_or(1.0);
            if pinyin.contains(' ') && weight < min_weight {
                continue;
            }
            let key = format!("{pinyin}\t{word}");
            match index.get(&key) {
                Some(&at) => {
                    if weight > entries[at].2 {
                        entries[at].2 = weight;
                    }
                }
                None if weight > 0.0 => {
                    index.insert(key, entries.len());
                    entries.push((pinyin, word.to_string(), weight));
                }
                None => {}
            }
        }
    }
    drop(index);

    // 热词：已有的词提词频，没有的加在末尾
    let mut hot: Vec<(String, String)> = Vec::new();
    if let Some(path) = hotwords {
        let text = fs::read_to_string(path).with_context(|| format!("读热词表失败: {}", path.display()))?;
        let mut seen = std::collections::HashSet::new();
        for line in text.lines() {
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let mut fields = line.split('\t');
            if let (Some(pinyin), Some(word)) = (fields.next(), fields.next()) {
                if seen.insert(word.to_string()) {
                    hot.push((pinyin.to_string(), word.to_string()));
                }
            }
        }
    }
    let hot_words: HashMap<&str, usize> = hot.iter().enumerate().map(|(i, (_, w))| (w.as_str(), i)).collect();
    let mut hot_seen = vec![false; hot.len()];

    let mut buffer = Vec::with_capacity(entries.len() * 24);
    writeln!(buffer, "# 由万象拼音 rime-wanxiang 转换（CC BY 4.0，https://github.com/amzxyz/rime-wanxiang）{source}")?;
    writeln!(buffer, "# 词表：{}；多字词最低词频 {}", tables.join(", "), format_g(min_weight))?;
    let mut count = 0usize;
    let mut probes = [false; PROBES.len()];
    for (pinyin, word, weight) in &entries {
        let mut weight = format_g(*weight);
        if let Some(&at) = hot_words.get(word.as_str()) {
            hot_seen[at] = true;
            if weight.parse::<f64>().unwrap_or(0.0) < HOTWORD_FREQ {
                weight = format_g(HOTWORD_FREQ);
            }
        }
        if let Some(at) = PROBES.iter().position(|p| p == word) {
            probes[at] = true;
        }
        writeln!(buffer, "{pinyin}\t{word}\t{weight}")?;
        count += 1;
    }
    for ((pinyin, word), seen) in hot.iter().zip(&hot_seen) {
        if !seen {
            writeln!(buffer, "{pinyin}\t{word}\t{}", format_g(HOTWORD_FREQ))?;
            count += 1;
        }
    }

    if count < min_entries {
        bail!("词库只有 {count} 条，少于 {min_entries}：词表的格式可能变了");
    }
    if let Some(missing) = PROBES.iter().zip(probes).find(|(_, found)| !found) {
        bail!("词库里没有「{}」：词表的格式可能变了", missing.0);
    }

    fs::create_dir_all(out).with_context(|| format!("建目录失败: {}", out.display()))?;
    fs::write(out.join("lexicon.tsv"), &buffer).context("写 lexicon.tsv 失败")?;
    // 混合编码词表（A座、OK啦）原样带上，引擎载入时自己解析（mixed.rs）；没有也不算错
    if let Ok(text) = fs::read_to_string(dicts.join("mixed.dict.yaml")) {
        fs::write(out.join("mixed.txt"), text).context("写 mixed.txt 失败")?;
    }
    let english = dicts.join("en.dict.yaml");
    let english_lines = match fs::read_to_string(&english) {
        Ok(text) => {
            fs::write(out.join("english.txt"), &text).context("写 english.txt 失败")?;
            text.lines().count()
        }
        Err(_) => 0,
    };
    Ok(Converted {
        entries: count,
        english: english_lines,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_tones() {
        assert_eq!(plain_pinyin("lǚ xíng").as_deref(), Some("lv xing"));
        assert_eq!(plain_pinyin("nǚ").as_deref(), Some("nv"));
        assert_eq!(plain_pinyin("lüè").as_deref(), Some("lve"));
        assert_eq!(plain_pinyin("Zhōng  guó").as_deref(), Some("zhong guo"));
        // 分开写的声调符号（NFD）
        assert_eq!(plain_pinyin("lu\u{0308}\u{030c}").as_deref(), Some("lv"));
        assert_eq!(plain_pinyin("ma\u{0301}").as_deref(), Some("ma"));
        assert_eq!(plain_pinyin("ń").as_deref(), Some("n"));
        assert_eq!(plain_pinyin("a1"), None);
        assert_eq!(plain_pinyin("'tis"), None);
        assert_eq!(plain_pinyin(""), None);
    }

    #[test]
    fn formats_like_python_g() {
        for (value, want) in [
            (759839.0, "759839"),
            (48288400.0, "4.82884e+07"),
            (1000000.0, "1e+06"),
            (999999.0, "999999"),
            (50.0, "50"),
            (1.0, "1"),
            (0.5, "0.5"),
            (1234.5, "1234.5"),
            (123456.7, "123457"),
            (30000.0, "30000"),
        ] {
            assert_eq!(format_g(value), want, "{value}");
        }
    }

    fn write(dir: &Path, name: &str, body: &str) {
        fs::write(dir.join(name), format!("# 注释\n---\nname: x\n...\n{body}")).unwrap();
    }

    #[test]
    fn converts_merges_and_validates() {
        let dir = std::env::temp_dir().join(format!("wotype_wanxiang_{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let dicts = dir.join("dicts");
        fs::create_dir_all(&dicts).unwrap();
        write(&dicts, "zi.dict.yaml", "你\tnǐ\t900\n好\thǎo\t800\n绿\tlǜ\t3\n");
        let common = PROBES.iter().map(|w| format!("{w}\tnǐ hǎo\t5000\n")).collect::<String>();
        write(
            &dicts,
            "jichu.dict.yaml",
            &format!("{common}旅行\tlǚ xíng\t200\n# 注释行\n低频词\tdī pín cí\t10\n旅行\tlǚ xíng\t300\n坏拼音\tx1 y\t999\n"),
        );
        for table in ["duoyin", "diming", "mingren", "yiren"] {
            write(&dicts, &format!("{table}.dict.yaml"), "");
        }
        write(&dicts, "en.dict.yaml", "GitHub\tGitHub\t10\n");
        write(&dicts, "mixed.dict.yaml", "A座\tA'zuò\n");
        let hot = dir.join("hot.tsv");
        fs::write(&hot, "# 热词\nlv xing\t旅行\nda mo xing\t大模型\n").unwrap();

        let out = dir.join("out");
        let done = convert(&dicts, Some(&hot), &out, MIN_WEIGHT, 5, "").unwrap();
        let text = fs::read_to_string(out.join("lexicon.tsv")).unwrap();
        let lines: Vec<&str> = text.lines().filter(|l| !l.starts_with('#')).collect();
        assert_eq!(done.entries, lines.len());
        assert!(lines.contains(&"lv\t绿\t3"), "单字不看最低词频，ü 写成 v");
        assert!(lines.contains(&"lv xing\t旅行\t30000"), "重复的取大的；热词把词频提上来");
        assert!(lines.contains(&"da mo xing\t大模型\t30000"), "词库里没有的热词加在末尾");
        assert!(!text.contains("低频词") && !text.contains("坏拼音"));
        assert_eq!(lines.last(), Some(&"da mo xing\t大模型\t30000"));
        assert!(fs::read_to_string(out.join("english.txt")).unwrap().contains("GitHub"));
        assert!(fs::read_to_string(out.join("mixed.txt")).unwrap().contains("A座"));

        // 词条太少、少了常用词：报错，不写文件
        let bad = dir.join("bad");
        assert!(convert(&dicts, None, &bad, MIN_WEIGHT, 1000, "").is_err());
        write(&dicts, "jichu.dict.yaml", "旅行\tlǚ xíng\t200\n");
        assert!(convert(&dicts, None, &bad, MIN_WEIGHT, 1, "").is_err());
        assert!(!bad.exists());
        let _ = fs::remove_dir_all(&dir);
    }

    /// 本机有万象的词表和 Python 脚本生成的词库时，核对两边的输出逐字节相同（除了第一行的来源注释）。
    #[test]
    fn matches_the_python_pipeline() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        let dicts = root.join("sample/rime-wanxiang/dicts");
        let expected = root.join("data/lexicon.tsv");
        let hot = root.join("engine/data/hotwords.tsv");
        if !dicts.join("jichu.dict.yaml").exists() || !expected.exists() {
            eprintln!("没有 sample/rime-wanxiang 或 data/lexicon.tsv，跳过");
            return;
        }
        let out = std::env::temp_dir().join(format!("wotype_wanxiang_full_{}", std::process::id()));
        convert(&dicts, Some(&hot), &out, MIN_WEIGHT, 100_000, "").unwrap();
        let ours = fs::read_to_string(out.join("lexicon.tsv")).unwrap();
        let theirs = fs::read_to_string(&expected).unwrap();
        let skip_source = |text: &str| text.split_once('\n').map(|(_, rest)| rest.to_string()).unwrap();
        assert!(skip_source(&ours) == skip_source(&theirs), "和 Python 脚本的输出不一样");
        let _ = fs::remove_dir_all(&out);
    }
}
