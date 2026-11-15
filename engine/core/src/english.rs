//! 英文词表：小写编码 -> 上屏形式（github -> GitHub）。
//!
//! 七万多个词，以前放在 `HashMap<String, String>` 里要八九 MB（哈希表加十几万个小字符串）；
//! 现在所有词按小写排好拼成一个字符串，另记每个词的起点，二分查找，不到 1 MB。见 docs/07。

/// 排好序的英文词表。编码就是词的小写形式，所以只存词本身。
#[derive(Default)]
pub(crate) struct EnglishWords {
    /// 所有词按小写的字典序拼在一起
    text: String,
    /// 每个词的起点，最后多一个总长度
    starts: Vec<u32>,
}

fn lower(word: &str) -> impl Iterator<Item = u8> + '_ {
    word.bytes().map(|b| b.to_ascii_lowercase())
}

impl EnglishWords {
    pub(crate) fn len(&self) -> usize {
        self.starts.len().saturating_sub(1)
    }

    fn word(&self, i: usize) -> &str {
        &self.text[self.starts[i] as usize..self.starts[i + 1] as usize]
    }

    /// 查一个词（不分大小写），返回词表里的写法。
    pub(crate) fn get(&self, word: &str) -> Option<&str> {
        let (mut lo, mut hi) = (0, self.len());
        while lo < hi {
            let mid = (lo + hi) / 2;
            match lower(self.word(mid)).cmp(lower(word)) {
                std::cmp::Ordering::Less => lo = mid + 1,
                std::cmp::Ordering::Greater => hi = mid,
                std::cmp::Ordering::Equal => return Some(self.word(mid)),
            }
        }
        None
    }

    /// 在现有的词后面再加一批（每行一个词，或 rime 的「上屏<TAB>编码」），返回新的词表。
    ///
    /// 只收 2~32 个字母、上屏和编码一致的条目（缩写 January<TAB>Jan 不要）。
    /// 同一个词有大小写两种写法时留全小写的（march 而不是 March），否则留先出现的。
    pub(crate) fn extended(&self, text: &str) -> Self {
        let mut words: Vec<&str> = (0..self.len()).map(|i| self.word(i)).collect();
        for line in text.lines() {
            let line = line.trim_end_matches('\r');
            if line.starts_with('#') || line.trim().is_empty() {
                continue;
            }
            let mut cols = line.split('\t');
            let word = cols.next().unwrap_or("").trim();
            let code = cols.next().map(str::trim).unwrap_or(word);
            if code.len() < 2 || code.len() > 32 || !code.bytes().all(|b| b.is_ascii_alphabetic()) {
                continue;
            }
            if word.is_empty() || !word.eq_ignore_ascii_case(code) {
                continue;
            }
            words.push(word);
        }
        // 稳定排序：同一个词的几种写法保持出现的先后
        words.sort_by(|a, b| lower(a).cmp(lower(b)));
        let mut out = Self {
            text: String::with_capacity(words.iter().map(|w| w.len()).sum()),
            starts: Vec::with_capacity(words.len() + 1),
        };
        let mut i = 0;
        while i < words.len() {
            let mut j = i + 1;
            while j < words.len() && words[j].eq_ignore_ascii_case(words[i]) {
                j += 1;
            }
            let chosen = words[i..j]
                .iter()
                .find(|w| w.bytes().all(|b| !b.is_ascii_uppercase()))
                .unwrap_or(&words[i]);
            out.starts.push(out.text.len() as u32);
            out.text.push_str(chosen);
            i = j;
        }
        out.starts.push(out.text.len() as u32);
        out.starts.shrink_to_fit();
        out.text.shrink_to_fit();
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lookup_and_dedupe() {
        let words = EnglishWords::default().extended(
            "# 注释\nhello\thello\nGitHub\tGitHub\nJanuary\tJan\nMarch\nmarch\nApple\nAPPLE\nx\nab1\n",
        );
        assert_eq!(words.len(), 4);
        assert_eq!(words.get("github"), Some("GitHub"));
        assert_eq!(words.get("GITHUB"), Some("GitHub"));
        assert_eq!(words.get("march"), Some("march"), "大小写两种写法留全小写的");
        assert_eq!(words.get("apple"), Some("Apple"), "都带大写时留先出现的");
        assert_eq!(words.get("jan"), None, "缩写不要");
        assert_eq!(words.get("january"), None);
        assert_eq!(words.get("x"), None, "太短");
        assert_eq!(words.get("hell"), None);

        // 追加：已有的写法优先，除非新来的是全小写
        let more = words.extended("github\nHELLO\nzoo\n");
        assert_eq!(more.len(), 5);
        assert_eq!(more.get("github"), Some("github"));
        assert_eq!(more.get("hello"), Some("hello"));
        assert_eq!(more.get("zoo"), Some("zoo"));
    }
}
