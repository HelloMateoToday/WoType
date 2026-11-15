//! 词典抽象与内存实现。
//!
//! 真实 WeType 词库是 LOUDS trie + 音节 ID 编码，后续解析器只需实现
//! Lexicon trait 即可接入；这里的 MemoryLexicon 同时提供 TSV 加载，便于
//! 先用导出的词表跑通整条链路。
//!
//! TSV 格式：拼音<TAB>词<TAB>频次
//! - 多音节拼音用空格或隔音符分隔，例如：xi an / xi'an
//! - 儿化用独立的 r 标记，例如：hua r
//! - 以 # 开头的行和空行会被忽略。

use std::collections::HashMap;
use std::fs;
use std::path::Path;
use std::sync::{Arc, RwLock};

use anyhow::{anyhow, bail, Context, Result};

use crate::syllable::{Syllable, SyllableId, SyllableQuery};

/// 词库快照的魔数与格式版本。格式一变就改版本号，旧快照自动失效。
const CACHE_MAGIC: &[u8; 4] = b"WLC1";
const CACHE_VERSION: u32 = 4;
/// 快照头的字节数。
const CACHE_HEADER_BYTES: usize = 64;

/// 快照里各段的起点（都按 8 字节对齐）和文件总长。
struct CacheLayout {
    entries: usize,
    by_initials: usize,
    keys: usize,
    initials: usize,
    text: usize,
    end: usize,
}

impl CacheLayout {
    /// 数字太大（坏快照）算溢出了返回 None。
    fn new(count: usize, text_len: usize, keys_len: usize) -> Option<Self> {
        // 词条的位置是 u32
        if count > u32::MAX as usize || text_len > u32::MAX as usize || keys_len > u32::MAX as usize {
            return None;
        }
        let align = |n: usize| n.checked_add(7).map(|n| n & !7);
        let entries = CACHE_HEADER_BYTES;
        let by_initials = align(entries.checked_add(count.checked_mul(24)?)?)?;
        let keys = align(by_initials.checked_add(count.checked_mul(4)?)?)?;
        let initials = align(keys.checked_add(keys_len.checked_mul(2)?)?)?;
        let text = align(initials.checked_add(keys_len)?)?;
        let end = text.checked_add(text_len)?;
        Some(Self {
            entries,
            by_initials,
            keys,
            initials,
            text,
            end,
        })
    }
}

/// 占位频次的词估频时给的成词加成（自然对数，约 ×20）。见 `estimate_placeholder_freqs`。
const PLACEHOLDER_BONUS: f64 = 3.0;
/// 同一个频次至少有这么多多音节词才当占位值（小词库、用户词库不处理）。
const PLACEHOLDER_MIN_WORDS: usize = 1000;
/// 切分时每一部分最多几个音节。
const PLACEHOLDER_MAX_PART: usize = 6;

fn cache_path(path: &Path) -> std::path::PathBuf {
    let mut os = path.as_os_str().to_owned();
    os.push(".wcache");
    std::path::PathBuf::from(os)
}

/// 宿主指定的快照目录（`set_cache_dir`）。设了就只用它：macOS 上词库在 App 包里，
/// 快照写进包里会破坏代码签名。
static CACHE_DIR: RwLock<Option<std::path::PathBuf>> = RwLock::new(None);

/// 指定快照目录；之后载入的词库都把快照放这里。空路径表示恢复默认。
pub fn set_cache_dir<P: AsRef<Path>>(dir: P) {
    let dir = dir.as_ref();
    let value = (!dir.as_os_str().is_empty()).then(|| dir.to_path_buf());
    *CACHE_DIR.write().unwrap_or_else(|e| e.into_inner()) = value;
}

/// 快照可能落的位置：宿主指定了目录就只用它；否则先放词库旁边，
/// 写不进去（比如 /usr/share 只读）再放 XDG 缓存目录。
fn cache_paths(path: &Path) -> Vec<std::path::PathBuf> {
    let custom = CACHE_DIR.read().unwrap_or_else(|e| e.into_inner()).clone();
    cache_paths_in(path, custom)
}

fn cache_paths_in(path: &Path, custom: Option<std::path::PathBuf>) -> Vec<std::path::PathBuf> {
    let mut out = Vec::new();
    if custom.is_none() {
        out.push(cache_path(path));
    }
    let dir = custom.or_else(|| {
        std::env::var_os("XDG_CACHE_HOME")
            .map(std::path::PathBuf::from)
            .or_else(|| {
                std::env::var_os("HOME").map(|home| std::path::PathBuf::from(home).join(".cache"))
            })
            .map(|base| base.join("wotype"))
    });
    if let Some(dir) = dir {
        // 用 FNV-1a 给路径算个短名字，避免不同词库撞在一起
        let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
        for byte in path.to_string_lossy().as_bytes() {
            hash ^= u64::from(*byte);
            hash = hash.wrapping_mul(0x1000_0000_01b3);
        }
        out.push(dir.join(format!("{hash:016x}.wcache")));
    }
    out
}

/// 源文件的 (大小, 修改时间秒)。拿不到就不用缓存。
fn source_stamp(path: &Path) -> Option<(u64, u64)> {
    let meta = fs::metadata(path).ok()?;
    let mtime = meta
        .modified()
        .ok()?
        .duration_since(std::time::UNIX_EPOCH)
        .ok()?
        .as_secs();
    Some((meta.len(), mtime))
}

/// 词典条目。
#[derive(Clone, Debug, PartialEq)]
pub struct LexEntry {
    pub word: String,
    pub freq: f64,
    /// 规范音节键（全拼，含儿化标记）。
    pub keys: Vec<SyllableKey>,
    /// 每个音节的首字母，用于简拼匹配。
    pub initials: Vec<u8>,
    /// 读音和查询对不上、靠模糊音规则才查到的（[`FuzzyLexicon`] 标）。
    pub fuzzy: bool,
}

/// 全拼音节键。
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct SyllableKey {
    pub id: SyllableId,
    pub erhua: bool,
}

impl SyllableKey {
    pub fn new(id: SyllableId, erhua: bool) -> Self {
        Self { id, erhua }
    }
}

/// 词典接口。
///
/// query 是一段连续音节；返回所有“音节序列恰好等于 query”的词。
/// 简拼查询用 SyllableQuery::Jianpin，匹配每个音节的首字母。
pub trait Lexicon: Send + Sync {
    /// 返回所有权值而非引用：这样「基础词库 + 用户词库」可以合并返回，
    /// 也能在运行时安全地增删用户词。命中数很小，克隆成本可接受。
    fn lookup(&self, query: &[SyllableQuery]) -> Vec<LexEntry>;

    /// 模糊音查询（z/zh、an/ang 等）。默认不支持。
    fn lookup_fuzzy(&self, _query: &[SyllableQuery]) -> Vec<LexEntry> {
        Vec::new()
    }

    /// 是否存在比 query 更长、且以 query 开头的词。
    ///
    /// 束搜索靠它剪掉不可能成词的音节串；不确定时返回 true（只影响速度，不影响结果）。
    fn has_longer(&self, _query: &[SyllableQuery]) -> bool {
        true
    }

    fn total_freq(&self) -> f64;

    fn len(&self) -> usize;

    fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// 词的一元代价（越大越不可能）。缺省用 -ln(freq/total)。
    fn cost(&self, entry: &LexEntry) -> f64 {
        let total = self.total_freq().max(1.0);
        -((entry.freq.max(0.5)) / total).ln()
    }
}

/// 一个词条在几个大数组里的位置。
///
/// 词库有一百多万条，每条存成独立的 String + 两个 Vec 再加三张哈希索引，内存要五六百 MB；
/// 现在所有词的文字拼成一个大字符串、音节拼成一个大数组，每条只记位置。
///
/// 布局固定（`repr(C)`、没有隐含的填充）：快照里就是这个数组原样写出去，读的时候直接映射。
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
struct Packed {
    freq: f64,
    /// 词在 `text` 里的起点
    text: u32,
    /// 音节在 `keys` / `initials` 里的起点
    keys: u32,
    /// 插入顺序：同一个拼音的词按它排，查出来的顺序和以前用哈希索引时一样
    seq: u32,
    /// 词的字节数
    text_len: u16,
    /// 音节个数
    n_keys: u8,
    /// 凑齐 24 字节，总是 0
    pad: u8,
}

const _: () = assert!(std::mem::size_of::<Packed>() == 24 && std::mem::align_of::<Packed>() == 8);

/// 能直接按字节映射的类型：没有填充、任何字节内容都是合法的值。
///
/// # Safety
/// 实现它的类型必须满足上面两条。
unsafe trait Pod: Copy + 'static {}
unsafe impl Pod for u8 {}
unsafe impl Pod for u16 {}
unsafe impl Pod for u32 {}
unsafe impl Pod for Packed {}

/// 一个只读数组：自己的 `Vec`，或者映射的快照文件里的一段。
///
/// 映射的那种不占进程的内存（footprint）：用到哪页系统读哪页，内存紧张时随时收回。见 docs/07。
enum Store<T: Pod> {
    Owned(Vec<T>),
    Mapped {
        map: Arc<memmap2::Mmap>,
        offset: usize,
        len: usize,
    },
}

impl<T: Pod> Default for Store<T> {
    fn default() -> Self {
        Store::Owned(Vec::new())
    }
}

impl<T: Pod> Store<T> {
    /// 映射区里从 offset 开始的 len 个 T。越界、没对齐返回 None。
    fn mapped(map: &Arc<memmap2::Mmap>, offset: usize, len: usize) -> Option<Self> {
        let bytes = len.checked_mul(std::mem::size_of::<T>())?;
        if offset.checked_add(bytes)? > map.len() {
            return None;
        }
        if (map.as_ptr() as usize + offset) % std::mem::align_of::<T>() != 0 {
            return None;
        }
        Some(Store::Mapped {
            map: map.clone(),
            offset,
            len,
        })
    }

    /// 要改内容时用：映射的先抄一份到内存。
    fn make_mut(&mut self) -> &mut Vec<T> {
        if let Store::Mapped { .. } = self {
            *self = Store::Owned(self.to_vec());
        }
        match self {
            Store::Owned(vec) => vec,
            Store::Mapped { .. } => unreachable!(),
        }
    }

    fn is_mapped(&self) -> bool {
        matches!(self, Store::Mapped { .. })
    }
}

impl<T: Pod> std::ops::Deref for Store<T> {
    type Target = [T];

    fn deref(&self) -> &[T] {
        match self {
            Store::Owned(vec) => vec,
            // SAFETY: `mapped` 核对过范围和对齐；T 是 Pod，任何字节内容都合法；
            // 映射是只读的，跟着 Arc 活着；快照替换时是写临时文件再改名，不会原地改
            Store::Mapped { map, offset, len } => unsafe {
                std::slice::from_raw_parts(map.as_ptr().add(*offset).cast::<T>(), *len)
            },
        }
    }
}

/// 数组的原始字节（写快照用）。
fn as_bytes<T: Pod>(slice: &[T]) -> &[u8] {
    // SAFETY: T 是 Pod：没有填充，每个字节都初始化过
    unsafe { std::slice::from_raw_parts(slice.as_ptr().cast::<u8>(), std::mem::size_of_val(slice)) }
}

/// 临时用的一大块音节 ID：放在匿名映射里，丢掉时整块还给系统；映射不了就退回 Vec。
enum ScratchIds {
    Mapped(memmap2::MmapMut, usize),
    Owned(Vec<SyllableId>),
}

impl ScratchIds {
    fn new(len: usize, fill: impl Fn(usize) -> SyllableId) -> Self {
        let bytes = len * std::mem::size_of::<SyllableId>();
        match memmap2::MmapMut::map_anon(bytes.max(1)) {
            Ok(mut map) => {
                // SAFETY: 匿名映射按页对齐、长度够 len 个 SyllableId，任何内容都是合法的 u16
                let ids = unsafe {
                    std::slice::from_raw_parts_mut(map.as_mut_ptr().cast::<SyllableId>(), len)
                };
                for (i, id) in ids.iter_mut().enumerate() {
                    *id = fill(i);
                }
                ScratchIds::Mapped(map, len)
            }
            Err(_) => ScratchIds::Owned((0..len).map(fill).collect()),
        }
    }
}

impl std::ops::Deref for ScratchIds {
    type Target = [SyllableId];

    fn deref(&self) -> &[SyllableId] {
        match self {
            // SAFETY: 同 new
            ScratchIds::Mapped(map, len) => unsafe {
                std::slice::from_raw_parts(map.as_ptr().cast::<SyllableId>(), *len)
            },
            ScratchIds::Owned(ids) => ids,
        }
    }
}

/// 模糊音索引：按各音节的规范形式排好的词条编号（有音节没有规范形式的词不在里面）。
///
/// 规范形式不存（以前存了一份，和 `keys` 一样大）：比较时用音节查归类表，一次数组下标。
struct FuzzyIndex {
    order: Vec<u32>,
}

const NO_CANON: SyllableId = SyllableId::MAX;

/// 内存词典。
///
/// 词条按音节键（字典序）排好，查全拼、判断「有没有更长的词」都是二分查找；
/// 简拼和模糊音各用一个排好序的词条编号数组。
///
/// 从快照载入时，几个大数组直接映射文件（`Store::Mapped`），不占进程内存；
/// 映射的数据不逐条核对（那样要把整个文件读一遍），所以取词条内容一律带边界检查，
/// 快照坏了最多查不到词，不会越界。
#[derive(Default)]
pub struct MemoryLexicon {
    /// 按音节键排好；同键的按插入顺序
    entries: Store<Packed>,
    /// 所有词的文字（UTF-8）
    text: Store<u8>,
    /// 音节键：`id | 儿化 << 15`
    keys: Store<u16>,
    /// 和 `keys` 一一对应的首字母，简拼匹配用
    initials: Store<u8>,
    /// 按首字母序列排好的词条编号
    by_initials: Store<u32>,
    /// 模糊音索引和建它时的规则版本。默认不建（模糊音可能没开），第一次模糊查询时再建；
    /// 规则换了（设置里改模糊音）下次查询时重建。
    fuzzy_index: RwLock<Option<(u64, Arc<FuzzyIndex>)>>,
    total_freq: f64,
    /// 加载时被跳过的行数（未知音节等）。
    skipped: usize,
}

fn raw_key(key: SyllableKey) -> u16 {
    (key.id & 0x7fff) | (u16::from(key.erhua) << 15)
}

fn key_from_raw(raw: u16) -> SyllableKey {
    SyllableKey::new(raw & 0x7fff, raw & 0x8000 != 0)
}

impl MemoryLexicon {
    pub fn new() -> Self {
        Self::default()
    }

    /// 插入一个词。pinyin 使用空格/隔音符分隔音节。
    ///
    /// 每次都要重新排序；成批加载走 `from_tsv_str`。
    pub fn insert(&mut self, pinyin: &str, word: &str, freq: f64) -> Result<()> {
        self.push(pinyin, word, freq)?;
        self.finish();
        Ok(())
    }

    /// 解析一行并追加到末尾（不排序，最后统一 `finish`）。
    fn push(&mut self, pinyin: &str, word: &str, freq: f64) -> Result<()> {
        if word.is_empty() {
            bail!("词不能为空");
        }
        if !freq.is_finite() || freq < 0.0 {
            bail!("频次必须是非负有限数，收到 {freq}");
        }
        let keys = parse_pinyin_keys(pinyin)?;
        let initials = keys
            .iter()
            .map(|k| {
                Syllable::from_id(k.id)
                    .map(|s| s.initial_letter())
                    .ok_or_else(|| anyhow!("未知音节 ID: {}", k.id))
            })
            .collect::<Result<Vec<_>>>()?;
        if keys.len() > usize::from(u8::MAX) || word.len() > usize::from(u16::MAX) {
            bail!("词太长");
        }
        let packed = Packed {
            freq,
            text: self.text.len() as u32,
            keys: self.keys.len() as u32,
            seq: self.entries.len() as u32,
            text_len: word.len() as u16,
            n_keys: keys.len() as u8,
            pad: 0,
        };
        self.entries.make_mut().push(packed);
        self.text.make_mut().extend_from_slice(word.as_bytes());
        self.keys.make_mut().extend(keys.iter().map(|&k| raw_key(k)));
        self.initials.make_mut().extend_from_slice(&initials);
        self.total_freq += freq;
        Ok(())
    }

    /// 排序、建简拼编号，作废模糊索引。
    fn finish(&mut self) {
        let mut entries = std::mem::take(self.entries.make_mut());
        entries.sort_unstable_by(|a, b| {
            self.entry_keys(a)
                .cmp(self.entry_keys(b))
                .then(a.seq.cmp(&b.seq))
        });
        entries.shrink_to_fit();
        self.entries = Store::Owned(entries);
        let mut order: Vec<u32> = (0..self.entries.len() as u32).collect();
        order.sort_unstable_by(|&a, &b| {
            let (a, b) = (self.entry(a), self.entry(b));
            self.entry_initials(a)
                .cmp(self.entry_initials(b))
                .then(a.seq.cmp(&b.seq))
        });
        self.by_initials = Store::Owned(order);
        self.text.make_mut().shrink_to_fit();
        self.keys.make_mut().shrink_to_fit();
        self.initials.make_mut().shrink_to_fit();
        *self.fuzzy_index.get_mut().unwrap_or_else(|e| e.into_inner()) = None;
    }

    /// 第 i 个词条；编号越界（快照坏了）时给一个空词条。
    fn entry(&self, i: u32) -> &Packed {
        const EMPTY: Packed = Packed {
            freq: 0.0,
            text: 0,
            keys: 0,
            seq: 0,
            text_len: 0,
            n_keys: 0,
            pad: 0,
        };
        self.entries.get(i as usize).unwrap_or(&EMPTY)
    }

    fn entry_keys(&self, e: &Packed) -> &[u16] {
        self.keys
            .get(e.keys as usize..e.keys as usize + e.n_keys as usize)
            .unwrap_or(&[])
    }

    fn entry_initials(&self, e: &Packed) -> &[u8] {
        self.initials
            .get(e.keys as usize..e.keys as usize + e.n_keys as usize)
            .unwrap_or(&[])
    }

    fn entry_word(&self, e: &Packed) -> &str {
        self.text
            .get(e.text as usize..e.text as usize + e.text_len as usize)
            .and_then(|bytes| std::str::from_utf8(bytes).ok())
            .unwrap_or("")
    }

    fn to_entry(&self, e: &Packed) -> LexEntry {
        LexEntry {
            word: self.entry_word(e).to_string(),
            freq: e.freq,
            keys: self.entry_keys(e).iter().map(|&raw| key_from_raw(raw)).collect(),
            initials: self.entry_initials(e).to_vec(),
            fuzzy: false,
        }
    }

    /// 音节键正好是 `key` 的词条（`entries` 的下标范围）。
    fn full_range(&self, key: &[u16]) -> std::ops::Range<usize> {
        let lo = self.entries.partition_point(|e| self.entry_keys(e) < key);
        let hi = lo + self.entries[lo..].partition_point(|e| self.entry_keys(e) == key);
        lo..hi
    }

    /// 首字母正好是 `initials` 的词条（`by_initials` 的下标范围）。
    fn initials_range(&self, initials: &[u8]) -> std::ops::Range<usize> {
        let at = |i: &u32| self.entry_initials(self.entry(*i));
        let lo = self.by_initials.partition_point(|i| at(i) < initials);
        let hi = lo + self.by_initials[lo..].partition_point(|i| at(i) == initials);
        lo..hi
    }

    /// 全部词条（按音节键排好）。
    pub fn entries(&self) -> impl Iterator<Item = LexEntry> + '_ {
        self.entries.iter().map(|e| self.to_entry(e))
    }

    /// 从 TSV 加载，并在旁边维护一份二进制快照。
    ///
    /// 55 万词库的 TSV 解析要 1.3 秒，快照能把这部分省掉。快照按
    /// 「源文件大小 + mtime + 格式版本」校验，词库更新后自动重建。
    pub fn from_tsv_path_cached<P: AsRef<Path>>(path: P) -> Result<Self> {
        let path = path.as_ref();
        let Some((len, mtime)) = source_stamp(path) else {
            return Self::from_tsv_path(path);
        };
        let candidates = cache_paths(path);
        for cache in &candidates {
            if let Some(lex) = Self::map_cache(cache, len, mtime) {
                return Ok(lex);
            }
        }
        let lex = Self::from_tsv_path(path)?;
        // 写失败不算错误：只读目录会退到 XDG 缓存目录，那里也不行就算了（词库留在内存里）
        for cache in &candidates {
            if lex.write_cache(cache, len, mtime).is_ok() {
                // 写好了就换成映射它：刚解析出来的几十 MB 数组可以还给系统
                if let Some(mapped) = Self::map_cache(cache, len, mtime) {
                    // 刚解析出来的数组放掉。注意 macOS 的分配器不会把这一百多 MB 还给系统
                    // （催也不还），所以宿主最好让一个子进程先把快照建好，见 cache_ready
                    let skipped = lex.skipped;
                    drop(lex);
                    return Ok(MemoryLexicon { skipped, ..mapped });
                }
                break;
            }
        }
        Ok(lex)
    }

    /// 这个词库有没有能直接映射的快照。
    ///
    /// 没有的话 `from_tsv_path_cached` 要解析 TSV，用掉一百多 MB 而且释放后系统收不回去；
    /// 常驻的进程可以先让一个子进程调一次 `from_tsv_path_cached` 把快照建好，自己再载入。
    pub fn cache_ready<P: AsRef<Path>>(path: P) -> bool {
        let path = path.as_ref();
        let Some((len, mtime)) = source_stamp(path) else {
            return false;
        };
        cache_paths(path)
            .iter()
            .any(|cache| Self::map_cache(cache, len, mtime).is_some())
    }

    /// 删掉这个词库的快照（词库本身要删了：在线更新的词库被换掉、恢复内置词库）。
    pub fn remove_cache<P: AsRef<Path>>(path: P) {
        for cache in cache_paths(path.as_ref()) {
            let _ = fs::remove_file(cache);
        }
    }

    /// 映射一个快照文件；打不开、对不上就返回 None。
    fn map_cache(cache: &Path, src_len: u64, src_mtime: u64) -> Option<MemoryLexicon> {
        let file = fs::File::open(cache).ok()?;
        // SAFETY: 映射是只读的；快照是自己写的，替换时是先写临时文件再改名，不会原地改
        let map = unsafe { memmap2::Mmap::map(&file) }.ok()?;
        Self::read_cache(Arc::new(map), src_len, src_mtime)
    }

    /// 快照就是几个大数组原样写出去（各段按 8 字节对齐），读的时候直接映射。
    ///
    /// 布局：64 字节的头（魔数、版本、源文件大小和修改时间、总频次、词条数、文字字节数、音节数），
    /// 然后依次是 entries、by_initials、keys、initials、text。
    fn write_cache(&self, cache: &Path, src_len: u64, src_mtime: u64) -> Result<()> {
        use std::io::Write;
        let layout = CacheLayout::new(self.entries.len(), self.text.len(), self.keys.len())
            .ok_or_else(|| anyhow!("词库太大，写不了快照"))?;
        if self.by_initials.len() != self.entries.len() || self.initials.len() != self.keys.len() {
            bail!("词库内部长度对不上");
        }
        let mut header = Vec::with_capacity(CACHE_HEADER_BYTES);
        header.extend_from_slice(CACHE_MAGIC);
        header.extend_from_slice(&CACHE_VERSION.to_le_bytes());
        header.extend_from_slice(&src_len.to_le_bytes());
        header.extend_from_slice(&src_mtime.to_le_bytes());
        // 词频是估过的（见 estimate_placeholder_freqs），总频次单独存，别从估值里加
        header.extend_from_slice(&self.total_freq.to_le_bytes());
        header.extend_from_slice(&(self.entries.len() as u64).to_le_bytes());
        header.extend_from_slice(&(self.text.len() as u64).to_le_bytes());
        header.extend_from_slice(&(self.keys.len() as u64).to_le_bytes());
        header.resize(CACHE_HEADER_BYTES, 0);

        if let Some(parent) = cache.parent() {
            fs::create_dir_all(parent).ok();
        }
        let tmp = cache.with_extension("wcache.tmp");
        let write = || -> std::io::Result<()> {
            let mut out = std::io::BufWriter::new(fs::File::create(&tmp)?);
            let mut written = 0usize;
            let mut section = |out: &mut std::io::BufWriter<fs::File>, at: usize, bytes: &[u8]| {
                // 补零到这一段的起点
                out.write_all(&vec![0u8; at - written])?;
                out.write_all(bytes)?;
                written = at + bytes.len();
                std::io::Result::Ok(())
            };
            section(&mut out, 0, &header)?;
            section(&mut out, layout.entries, as_bytes(&self.entries))?;
            section(&mut out, layout.by_initials, as_bytes(&self.by_initials))?;
            section(&mut out, layout.keys, as_bytes(&self.keys))?;
            section(&mut out, layout.initials, &self.initials)?;
            section(&mut out, layout.text, &self.text)?;
            out.flush()
        };
        write().with_context(|| format!("写词库快照失败: {}", tmp.display()))?;
        fs::rename(&tmp, cache)
            .with_context(|| format!("替换词库快照失败: {}", cache.display()))?;
        Ok(())
    }

    /// 读快照：只核对头和各段的范围，数组直接映射。格式不对、和源文件对不上、
    /// 长度对不上的一律返回 None（退回解析 TSV）。
    fn read_cache(map: Arc<memmap2::Mmap>, src_len: u64, src_mtime: u64) -> Option<MemoryLexicon> {
        // 数组按小端原样存的，大端机器上不能直接映射
        if cfg!(target_endian = "big") {
            return None;
        }
        let header = map.get(..CACHE_HEADER_BYTES)?;
        let u64_at = |at: usize| Some(u64::from_le_bytes(header.get(at..at + 8)?.try_into().ok()?));
        if header.get(..4)? != CACHE_MAGIC
            || u32::from_le_bytes(header.get(4..8)?.try_into().ok()?) != CACHE_VERSION
        {
            return None;
        }
        if u64_at(8)? != src_len || u64_at(16)? != src_mtime {
            return None;
        }
        let total = f64::from_bits(u64_at(24)?);
        let count = usize::try_from(u64_at(32)?).ok()?;
        let text_len = usize::try_from(u64_at(40)?).ok()?;
        let keys_len = usize::try_from(u64_at(48)?).ok()?;
        let layout = CacheLayout::new(count, text_len, keys_len)?;
        // 文件大小要正好对上：被截断的、后面多出东西的都不要
        if map.len() != layout.end || !total.is_finite() {
            return None;
        }
        Some(MemoryLexicon {
            entries: Store::mapped(&map, layout.entries, count)?,
            by_initials: Store::mapped(&map, layout.by_initials, count)?,
            keys: Store::mapped(&map, layout.keys, keys_len)?,
            initials: Store::mapped(&map, layout.initials, keys_len)?,
            text: Store::mapped(&map, layout.text, text_len)?,
            fuzzy_index: RwLock::new(None),
            total_freq: total,
            skipped: 0,
        })
    }

    /// 几个大数组是不是映射的快照文件（否则在内存里）。
    pub fn is_mapped(&self) -> bool {
        self.entries.is_mapped()
    }

    /// 从 TSV 文本加载。
    pub fn from_tsv_str(data: &str) -> Result<Self> {
        let mut lex = Self::new();
        for (line_no, raw) in data.lines().enumerate() {
            let line = raw.trim_end();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let mut cols = line.split('\t');
            let pinyin = cols.next().unwrap_or("");
            let word = cols.next().unwrap_or("");
            let freq = cols.next().unwrap_or("");
            if cols.next().is_some() || pinyin.is_empty() || word.is_empty() || freq.is_empty() {
                bail!("第 {} 行应为 3 列：拼音<TAB>词<TAB>频次", line_no + 1);
            }
            let freq: f64 = freq
                .parse()
                .with_context(|| format!("第 {} 行频次不是数字: {freq}", line_no + 1))?;
            // 音节不认识（各地方言音、冷僻拼音）时跳过这一行，
            // 不要让一条脏数据毁掉整个词库。
            match lex.push(pinyin, word, freq) {
                Ok(()) => {}
                Err(_) => lex.skipped += 1,
            }
        }
        lex.finish();
        Ok(lex)
    }

    /// 给「占位频次」的词估一个频次。
    ///
    /// rime-ice 的 ext / tencent 两个词表（加起来五十多万词，占整个词库一半以上）
    /// 所有词的频次都是同一个占位值 100。按字面当频次用，这些词就比任何常用字
    /// 拼出来的句子都冷门得多：`bujianyi` 里「不建议」排在「不见一」「部件」后面，
    /// 第一页根本看不到。
    ///
    /// 做法：找出多音节词里占比很高的那个频次（占位值），把这些词按自己的拼音
    /// 和字切成词库里已有的词，频次取「各部分概率相乘」再乘一个成词加成
    /// [`PLACEHOLDER_BONUS`]——词库收了它，说明这几个字常挨着用，相当于没有
    /// 二元模型时给它补上搭配分。不会低于原值，也不会高过最冷门的那一部分。
    fn estimate_placeholder_freqs(&mut self, min_words: usize) {
        let mut hist: HashMap<u64, usize> = HashMap::new();
        let mut multi = 0usize;
        for entry in self.entries.iter() {
            if entry.n_keys >= 2 {
                multi += 1;
                *hist.entry(entry.freq.to_bits()).or_default() += 1;
            }
        }
        let Some((&bits, &count)) = hist.iter().max_by_key(|(_, &c)| c) else {
            return;
        };
        if count < min_words || count * 4 < multi {
            return;
        }
        let placeholder = f64::from_bits(bits);
        let bonus = std::env::var("WOTYPE_PLACEHOLDER_BONUS")
            .ok()
            .and_then(|v| v.parse::<f64>().ok())
            .unwrap_or(PLACEHOLDER_BONUS);
        let total = self.total_freq.max(1.0);
        let mut updates = Vec::new();
        for (idx, entry) in self.entries.iter().enumerate() {
            if entry.freq != placeholder || entry.n_keys < 2 {
                continue;
            }
            let keys = self.entry_keys(entry);
            let chars: Vec<char> = self.entry_word(entry).chars().collect();
            let n = chars.len();
            if n != keys.len() {
                continue; // 儿化、混了字母数字的词，字和音节对不齐
            }
            // best[j]：前 j 个字切成已有词的最小代价；rarest[j]：这种切法里最冷门部分的频次
            let mut best = vec![f64::INFINITY; n + 1];
            let mut rarest = vec![f64::INFINITY; n + 1];
            best[0] = 0.0;
            for i in 0..n {
                if !best[i].is_finite() {
                    continue;
                }
                for j in (i + 1)..=n.min(i + PLACEHOLDER_MAX_PART) {
                    if j - i == n {
                        continue; // 不能用自己
                    }
                    let range = self.full_range(&keys[i..j]);
                    if range.is_empty() {
                        continue;
                    }
                    let part: String = chars[i..j].iter().collect();
                    let freq = self.entries[range]
                        .iter()
                        .filter(|e| self.entry_word(e) == part)
                        .map(|e| e.freq)
                        .fold(0.0f64, f64::max);
                    if freq <= 0.0 {
                        continue;
                    }
                    let cost = best[i] - (freq / total).ln();
                    if cost < best[j] {
                        best[j] = cost;
                        rarest[j] = rarest[i].min(freq);
                    }
                }
            }
            if !best[n].is_finite() {
                continue;
            }
            let estimate = (total * (bonus - best[n]).exp()).min(rarest[n]);
            if estimate > entry.freq {
                updates.push((idx, estimate));
            }
        }
        for (idx, freq) in updates {
            self.entries.make_mut()[idx].freq = freq;
        }
    }

    fn build_fuzzy_index(&self, table: &crate::syllable::FuzzyTable) -> FuzzyIndex {
        // 排序时要比很多次，先把各音节的规范形式算好放在临时数组里，排完就丢。
        // 临时数组有好几 MB：用 Vec 的话释放后 macOS 的分配器扣着不还，所以放在匿名映射里
        let canon = ScratchIds::new(self.keys.len(), |i| {
            table.canon(self.keys[i] & 0x7fff).unwrap_or(NO_CANON)
        });
        let canon: &[SyllableId] = &canon;
        let at = |i: u32| {
            let e = self.entry(i);
            canon
                .get(e.keys as usize..e.keys as usize + e.n_keys as usize)
                .unwrap_or(&[])
        };
        let total = self.entries.len() as u32;
        let count = (0..total).filter(|&i| !at(i).contains(&NO_CANON)).count();
        let mut order: Vec<u32> = Vec::with_capacity(count);
        order.extend((0..total).filter(|&i| !at(i).contains(&NO_CANON)));
        order.sort_unstable_by(|&a, &b| {
            at(a)
                .cmp(at(b))
                .then(self.entry(a).seq.cmp(&self.entry(b).seq))
        });
        FuzzyIndex { order }
    }

    /// 当前规则下的模糊音索引（规则换过就重建）。
    fn fuzzy_index_for(&self, table: &crate::syllable::FuzzyTable) -> Arc<FuzzyIndex> {
        if let Some((generation, index)) = self
            .fuzzy_index
            .read()
            .unwrap_or_else(|e| e.into_inner())
            .as_ref()
        {
            if *generation == table.generation() {
                return index.clone();
            }
        }
        let index = Arc::new(self.build_fuzzy_index(table));
        *self.fuzzy_index.write().unwrap_or_else(|e| e.into_inner()) =
            Some((table.generation(), index.clone()));
        index
    }

    /// 加载时被跳过的行数。
    pub fn skipped(&self) -> usize {
        self.skipped
    }

    /// 从 TSV 文件加载。
    pub fn from_tsv_path<P: AsRef<Path>>(path: P) -> Result<Self> {
        let path = path.as_ref();
        let data = fs::read_to_string(path)
            .with_context(|| format!("读取词典失败: {}", path.display()))?;
        let mut lex = Self::from_tsv_str(&data)?;
        lex.estimate_placeholder_freqs(PLACEHOLDER_MIN_WORDS);
        Ok(lex)
    }
}

impl Lexicon for MemoryLexicon {
    fn lookup(&self, query: &[SyllableQuery]) -> Vec<LexEntry> {
        if query.is_empty() {
            return Vec::new();
        }

        let all_full = query
            .iter()
            .all(|q| matches!(q, SyllableQuery::Full { .. }));
        let all_jianpin = query
            .iter()
            .all(|q| matches!(q, SyllableQuery::Jianpin { .. }));

        if all_full {
            let key: Vec<u16> = query
                .iter()
                .map(|q| match q {
                    SyllableQuery::Full { id, erhua } => raw_key(SyllableKey::new(*id, *erhua)),
                    _ => unreachable!(),
                })
                .collect();
            return self.entries[self.full_range(&key)]
                .iter()
                .map(|e| self.to_entry(e))
                .collect();
        }

        if all_jianpin && !query.iter().any(needs_initial_check) {
            let key: Vec<u8> = query
                .iter()
                .map(|q| match q {
                    SyllableQuery::Jianpin { letter } => *letter,
                    _ => unreachable!(),
                })
                .collect();
            return self.by_initials[self.initials_range(&key)]
                .iter()
                .map(|&i| self.to_entry(self.entry(i)))
                .collect();
        }

        // 全拼混简拼（k yi -> 可以）、zh/ch/sh 简拼：先按首字母查，再逐个比对
        let Some(initials) = query_initials(query) else {
            return Vec::new();
        };
        self.by_initials[self.initials_range(&initials)]
            .iter()
            .map(|&i| self.entry(i))
            .filter(|e| keys_match(self.entry_keys(e), self.entry_initials(e), query))
            .map(|e| self.to_entry(e))
            .collect()
    }

    /// 词条是排好序的：以 query 开头的更长的词，紧跟在正好等于 query 的那些后面。
    fn has_longer(&self, query: &[SyllableQuery]) -> bool {
        if query.is_empty() {
            return false;
        }
        if query.iter().any(|q| q.is_jianpin()) {
            // 简拼、混合查询按声母剪（只看声母会少剪一些，不会错剪）
            let Some(initials) = query_initials(query) else {
                return true;
            };
            let next = self.initials_range(&initials).end;
            return self.by_initials.get(next).is_some_and(|&i| {
                self.entry_initials(self.entry(i))
                    .starts_with(&initials)
            });
        }
        let key: Vec<u16> = query
            .iter()
            .filter_map(|q| match q {
                SyllableQuery::Full { id, erhua } => Some(raw_key(SyllableKey::new(*id, *erhua))),
                SyllableQuery::Jianpin { .. } => None,
            })
            .collect();
        let next = self.full_range(&key).end;
        self.entries
            .get(next)
            .is_some_and(|e| self.entry_keys(e).starts_with(&key))
    }

    fn lookup_fuzzy(&self, query: &[SyllableQuery]) -> Vec<LexEntry> {
        if query.is_empty() {
            return Vec::new();
        }
        let table = crate::syllable::fuzzy_table();
        let mut key = Vec::with_capacity(query.len());
        for q in query {
            match q {
                SyllableQuery::Full { id, erhua } => {
                    if *erhua {
                        return Vec::new();
                    }
                    match table.canon(*id) {
                        Some(canon) => key.push(canon),
                        None => return Vec::new(),
                    }
                }
                SyllableQuery::Jianpin { .. } => return Vec::new(),
            }
        }
        let index = self.fuzzy_index_for(&table);
        // 词条各音节的规范形式和 key 比大小（索引里的词每个音节都有规范形式）
        let compare = |i: &u32| {
            self.entry_keys(self.entry(*i))
                .iter()
                .map(|&raw| table.canon(raw & 0x7fff).unwrap_or(NO_CANON))
                .cmp(key.iter().copied())
        };
        let lo = index.order.partition_point(|i| compare(i).is_lt());
        let hi = lo + index.order[lo..].partition_point(|i| compare(i).is_eq());
        index.order[lo..hi]
            .iter()
            .map(|&i| self.to_entry(self.entry(i)))
            .collect()
    }

    fn total_freq(&self) -> f64 {
        self.total_freq
    }

    fn len(&self) -> usize {
        self.entries.len()
    }
}

/// 给束搜索用的视图：精确查不到时回退到模糊音。
pub struct FuzzyLexicon<'a> {
    inner: &'a dyn Lexicon,
    /// 模糊来的词（读音和输入对不上，靠模糊音规则才对上）扣多少分（自然对数）。
    penalty: f64,
}

impl<'a> FuzzyLexicon<'a> {
    pub fn new(inner: &'a dyn Lexicon, penalty: f64) -> Self {
        Self { inner, penalty }
    }
}

impl Lexicon for FuzzyLexicon<'_> {
    /// 模糊索引查出来的已经包含读音完全对上的词（规范形式相同），所以只查它一次：
    /// 读音完全对上的不扣分，模糊来的词频乘 e^(-penalty)（代价加 penalty）。
    ///
    /// 以前是只在原样查不到时才退到模糊音（zidao 原样有「自导」，「知道」永远出不来），
    /// 后来改成原样、模糊各查一次再逐条去重，太慢；引擎也不用再分原样、模糊各跑一遍束搜索。
    fn lookup(&self, query: &[SyllableQuery]) -> Vec<LexEntry> {
        let mut entries = self.inner.lookup_fuzzy(query);
        if entries.is_empty() {
            // 简拼、儿化查不了模糊索引
            return self.inner.lookup(query);
        }
        let factor = (-self.penalty).exp();
        for entry in &mut entries {
            let exact = entry.keys.len() == query.len()
                && entry.keys.iter().zip(query).all(|(key, q)| {
                    matches!(q, SyllableQuery::Full { id, erhua } if *id == key.id && *erhua == key.erhua)
                });
            if !exact {
                entry.freq *= factor;
                entry.fuzzy = true;
            }
        }
        entries
    }

    fn lookup_fuzzy(&self, query: &[SyllableQuery]) -> Vec<LexEntry> {
        self.inner.lookup_fuzzy(query)
    }

    fn total_freq(&self) -> f64 {
        self.inner.total_freq()
    }

    fn len(&self) -> usize {
        self.inner.len()
    }
}

/// 用户词库：在基础词库之上叠加用户自己添加的词。
///
/// 用户词以 (拼音, 词, 频次) 保存，改动时重建一份小的 MemoryLexicon；
/// 用户词通常只有几百到几千条，重建成本可以忽略。
pub struct UserLexicon {
    base: Arc<dyn Lexicon>,
    words: RwLock<Vec<(String, String, f64)>>,
    /// 自定义词（设置里添加的，存在 custom.tsv）：只读，整份替换，不写回用户词库。
    custom: RwLock<Vec<(String, String, f64)>>,
    snapshot: RwLock<Arc<MemoryLexicon>>,
}

/// 自定义词默认频次：和最常用的词差不多，所以排在同音词前面。
pub const CUSTOM_WORD_FREQ: f64 = 5_000_000.0;

impl UserLexicon {
    pub fn new(base: Arc<dyn Lexicon>) -> Self {
        Self {
            base,
            words: RwLock::new(Vec::new()),
            custom: RwLock::new(Vec::new()),
            snapshot: RwLock::new(Arc::new(MemoryLexicon::new())),
        }
    }

    /// 添加或更新一个用户词。拼音可以是 ni hao / nihao / xi'an。
    pub fn add(&self, pinyin: &str, word: &str, freq: f64) -> Result<()> {
        if word.is_empty() || pinyin.trim().is_empty() {
            bail!("用户词的拼音和词都不能为空");
        }
        // 先单独校验一次，拼音非法时不要污染词库。
        // 注意不能借用 from_tsv_str：它对未知音节是「跳过」而不是报错。
        parse_pinyin_keys(pinyin.trim()).context("用户词拼音无法解析")?;

        {
            let mut words = self.words.write().unwrap();
            if let Some(slot) = words.iter_mut().find(|(_, w, _)| w == word) {
                slot.0 = pinyin.trim().to_string();
                slot.2 = freq;
            } else {
                words.push((pinyin.trim().to_string(), word.to_string(), freq));
            }
        }
        self.rebuild();
        Ok(())
    }

    /// 删除用户词，返回是否删掉了东西。
    pub fn remove(&self, word: &str) -> bool {
        let removed = {
            let mut words = self.words.write().unwrap();
            let before = words.len();
            words.retain(|(_, w, _)| w != word);
            words.len() != before
        };
        if removed {
            self.rebuild();
        }
        removed
    }

    pub fn words(&self) -> Vec<(String, String, f64)> {
        self.words.read().map(|w| w.clone()).unwrap_or_default()
    }

    pub fn clear(&self) {
        if let Ok(mut words) = self.words.write() {
            words.clear();
        }
        self.rebuild();
    }

    /// 把用户词写成 TSV（与 lexicon 格式一致）。
    pub fn save_tsv<P: AsRef<Path>>(&self, path: P) -> Result<()> {
        let words = self.words();
        if words.is_empty() {
            bail!("用户词库为空");
        }
        let mut out = String::from("# 用户词库\n");
        for (pinyin, word, freq) in words {
            out.push_str(&format!("{}\t{}\t{}\n", pinyin, word, freq as i64));
        }
        fs::write(path.as_ref(), out)
            .with_context(|| format!("写入用户词库失败: {}", path.as_ref().display()))
    }

    /// 从 TSV 载入用户词，追加到现有内容。
    pub fn load_tsv<P: AsRef<Path>>(&self, path: P) -> Result<usize> {
        let data = fs::read_to_string(path.as_ref())
            .with_context(|| format!("读取用户词库失败: {}", path.as_ref().display()))?;
        let mut added = 0;
        for line in data.lines() {
            if line.trim().is_empty() || line.starts_with('#') {
                continue;
            }
            let mut cols = line.split('\t');
            let (Some(pinyin), Some(word)) = (cols.next(), cols.next()) else {
                continue;
            };
            let freq = cols.next().and_then(|f| f.parse().ok()).unwrap_or(1000.0);
            if self.add(pinyin, word, freq).is_ok() {
                added += 1;
            }
        }
        Ok(added)
    }

    /// 用一份自定义词整体替换现有的。格式 `拼音<TAB>词[<TAB>频次]`，
    /// 拼音不合法的行跳过。返回收下的条数。
    pub fn set_custom_tsv(&self, data: &str) -> usize {
        let mut custom = Vec::new();
        for line in data.lines() {
            let line = line.trim_end_matches('\r');
            if line.trim().is_empty() || line.starts_with('#') {
                continue;
            }
            let mut cols = line.split('\t');
            let (Some(pinyin), Some(word)) = (cols.next(), cols.next()) else {
                continue;
            };
            let (pinyin, word) = (pinyin.trim().to_ascii_lowercase(), word.trim());
            // 手写的 custom.tsv 可能不分音节（nihao）：自己切开
            let Some(pinyin) = (if parse_pinyin_keys(&pinyin).is_ok() {
                Some(pinyin)
            } else {
                split_syllables(&pinyin)
            }) else {
                continue;
            };
            if word.is_empty() {
                continue;
            }
            let freq = cols
                .next()
                .and_then(|f| f.trim().parse::<f64>().ok())
                .filter(|f| f.is_finite() && *f > 0.0)
                .unwrap_or(CUSTOM_WORD_FREQ);
            custom.push((pinyin, word.to_string(), freq));
        }
        let count = custom.len();
        if let Ok(mut slot) = self.custom.write() {
            *slot = custom;
        }
        self.rebuild();
        count
    }

    /// 从文件读自定义词（整体替换）；文件不存在就清空。
    pub fn load_custom<P: AsRef<Path>>(&self, path: P) -> Result<usize> {
        let path = path.as_ref();
        match fs::read_to_string(path) {
            Ok(data) => Ok(self.set_custom_tsv(&data)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(self.set_custom_tsv("")),
            Err(e) => Err(e).with_context(|| format!("读取自定义词失败: {}", path.display())),
        }
    }

    /// 是不是设置里添加的自定义词。
    pub fn is_custom(&self, word: &str) -> bool {
        self.custom
            .read()
            .map(|c| c.iter().any(|(_, w, _)| w == word))
            .unwrap_or(false)
    }

    pub fn custom_words(&self) -> Vec<(String, String, f64)> {
        self.custom.read().map(|w| w.clone()).unwrap_or_default()
    }

    fn rebuild(&self) {
        let mut words = self.words.read().map(|w| w.clone()).unwrap_or_default();
        words.extend(self.custom_words());
        let mut tsv = String::new();
        for (pinyin, word, freq) in &words {
            tsv.push_str(&format!("{}\t{}\t{}\n", pinyin, word, freq));
        }
        if let Ok(lexicon) = MemoryLexicon::from_tsv_str(&tsv) {
            if let Ok(mut slot) = self.snapshot.write() {
                *slot = Arc::new(lexicon);
            }
        }
    }
}

impl Lexicon for UserLexicon {
    fn lookup(&self, query: &[SyllableQuery]) -> Vec<LexEntry> {
        let mut result = self.base.lookup(query);
        if let Ok(snapshot) = self.snapshot.read() {
            result.extend(snapshot.lookup(query));
        }
        result
    }

    fn has_longer(&self, query: &[SyllableQuery]) -> bool {
        self.base.has_longer(query)
            || self
                .snapshot
                .read()
                .map(|s| s.has_longer(query))
                .unwrap_or(true)
    }

    fn lookup_fuzzy(&self, query: &[SyllableQuery]) -> Vec<LexEntry> {
        let mut result = self.base.lookup_fuzzy(query);
        if let Ok(snapshot) = self.snapshot.read() {
            result.extend(snapshot.lookup_fuzzy(query));
        }
        result
    }

    fn total_freq(&self) -> f64 {
        self.base.total_freq() + self.snapshot.read().map(|s| s.total_freq()).unwrap_or(0.0)
    }

    fn len(&self) -> usize {
        self.base.len() + self.snapshot.read().map(|s| s.len()).unwrap_or(0)
    }
}

/// 查询每个音节的声母（全拼音节取首字母，和词条的 initials 一样）。
fn query_initials(query: &[SyllableQuery]) -> Option<Vec<u8>> {
    query
        .iter()
        .map(|q| match q {
            SyllableQuery::Full { id, .. } => Syllable::from_id(*id).map(|s| s.initial_letter()),
            SyllableQuery::Jianpin { letter } => {
                Some(crate::syllable::jianpin_first_letter(*letter))
            }
        })
        .collect()
}

/// 简拼查询要不要逐条核对声母（zh/ch/sh 的简拼只按首字母查不够）。
fn needs_initial_check(query: &SyllableQuery) -> bool {
    matches!(query, SyllableQuery::Jianpin { letter }
        if crate::syllable::jianpin_required_initial(*letter).is_some())
}

/// 一个词条（音节键、首字母）是否符合混合查询。
fn keys_match(keys: &[u16], initials: &[u8], query: &[SyllableQuery]) -> bool {
    if keys.len() != query.len() {
        return false;
    }
    query
        .iter()
        .zip(keys.iter().map(|&raw| key_from_raw(raw)))
        .enumerate()
        .all(|(i, (q, key))| match q {
            SyllableQuery::Full { id, erhua } => key.id == *id && key.erhua == *erhua,
            SyllableQuery::Jianpin { letter } => {
                match crate::syllable::jianpin_required_initial(*letter) {
                    Some(initial) => {
                        Syllable::from_id(key.id).is_some_and(|s| s.initial == initial)
                    }
                    None => initials.get(i) == Some(letter),
                }
            }
        })
}

/// 解析词表里的拼音字段。
///
/// 允许：
/// - 单音节：xian
/// - 多音节：xi an / xi'an
/// - 儿化：hua r
///
/// 多音节不允许写成无分隔的连写，因为无法唯一切分（如 fangan）。
/// 把连着写的拼音切成音节（`nihao` -> `ni hao`）：音节数最少，一样多时前面的音节取长的
/// （`fangan` -> `fang an`，想要 fan gan 就自己加空格或隔音符）。切不开返回 None。
pub fn split_syllables(text: &str) -> Option<String> {
    let text = text.trim();
    if text.is_empty() || !text.bytes().all(|b| b.is_ascii_lowercase()) {
        return None;
    }
    let n = text.len();
    // best[i]：text[i..] 最少切成几个音节，以及第一个音节的长度
    let mut best: Vec<Option<(usize, usize)>> = vec![None; n + 1];
    best[n] = Some((0, 0));
    for i in (0..n).rev() {
        for len in (1..=crate::syllable::MAX_SYLLABLE_LEN.min(n - i)).rev() {
            if !crate::syllable::is_valid(&text[i..i + len]) {
                continue;
            }
            if let Some((count, _)) = best[i + len] {
                if best[i].map_or(true, |(c, _)| count + 1 < c) {
                    best[i] = Some((count + 1, len));
                }
            }
        }
    }
    best[0]?;
    let mut parts = Vec::new();
    let mut i = 0;
    while i < n {
        let (_, len) = best[i]?;
        parts.push(&text[i..i + len]);
        i += len;
    }
    Some(parts.join(" "))
}

pub fn parse_pinyin_keys(pinyin: &str) -> Result<Vec<SyllableKey>> {
    let pinyin = pinyin.trim();
    if pinyin.is_empty() {
        bail!("拼音不能为空");
    }

    // 单音节优先：xian 必须解析成一个音节，而不是 xi + an。
    if !pinyin.contains([' ', '\t', '\'']) {
        let syl = Syllable::from_text(pinyin)
            .ok_or_else(|| anyhow!("未知音节: {pinyin}（多音节请用空格分隔）"))?;
        return Ok(vec![SyllableKey::new(syl.id, false)]);
    }

    let mut keys: Vec<SyllableKey> = Vec::new();
    for token in pinyin.split([' ', '\t', '\'']) {
        let token = token.trim();
        if token.is_empty() {
            continue;
        }
        if token == "r" {
            match keys.last_mut() {
                Some(last) if !last.erhua => last.erhua = true,
                Some(_) => bail!("重复的儿化标记"),
                None => bail!("儿化标记 r 前面没有音节"),
            }
            continue;
        }
        let syl = Syllable::from_text(token).ok_or_else(|| anyhow!("未知音节: {token}"))?;
        keys.push(SyllableKey::new(syl.id, false));
    }
    if keys.is_empty() {
        bail!("拼音不能为空");
    }
    Ok(keys)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lex() -> MemoryLexicon {
        MemoryLexicon::from_tsv_str(
            "xian\t先\t1000\nxi an\t西安\t500\nzhong guo\t中国\t800\nhua r\t花儿\t100\n",
        )
        .unwrap()
    }

    #[test]
    fn full_lookup() {
        let lex = lex();
        let xian = Syllable::from_text("xian").unwrap();
        let found = lex.lookup(&[xian.query(false)]);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].word, "先");
    }

    #[test]
    fn apostrophe_and_multi_syllable() {
        let lex = lex();
        let xi = Syllable::from_text("xi").unwrap();
        let an = Syllable::from_text("an").unwrap();
        let found = lex.lookup(&[xi.query(false), an.query(false)]);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].word, "西安");
    }

    #[test]
    fn mixed_lookup_and_prune() {
        let mut lex = MemoryLexicon::new();
        lex.insert("zhong wen", "中文", 100.0).unwrap();
        lex.insert("zheng wen", "正文", 50.0).unwrap();
        lex.insert("zhong guo ren", "中国人", 80.0).unwrap();
        let wen = Syllable::from_text("wen").unwrap().query(false);
        let guo = Syllable::from_text("guo").unwrap().query(false);
        let z = SyllableQuery::Jianpin { letter: b'z' };
        let words: Vec<String> = lex.lookup(&[z, wen]).into_iter().map(|e| e.word).collect();
        assert_eq!(words.len(), 2, "{words:?}");
        assert!(words.contains(&"中文".to_string()));
        // 剪枝按声母：z guo 后面还有中国人，z wen 后面没有更长的词
        assert!(lex.has_longer(&[z, guo]));
        assert!(!lex.has_longer(&[z, wen]));
        assert!(lex.has_longer(&[z]));
        assert!(!lex.has_longer(&[SyllableQuery::Jianpin { letter: b'q' }]));
    }

    #[test]
    fn jianpin_lookup() {
        let lex = lex();
        let found = lex.lookup(&[
            SyllableQuery::Jianpin { letter: b'z' },
            SyllableQuery::Jianpin { letter: b'g' },
        ]);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].word, "中国");
    }

    #[test]
    fn digraph_jianpin_lookup() {
        let mut lex = MemoryLexicon::new();
        lex.insert("zhi chi", "支持", 100.0).unwrap();
        lex.insert("zi chi", "自持", 10.0).unwrap();
        lex.insert("zhi ci", "至此", 50.0).unwrap();
        let words = |q: &[SyllableQuery]| {
            let mut w: Vec<String> = lex.lookup(q).into_iter().map(|e| e.word).collect();
            w.sort();
            w
        };
        let zh = SyllableQuery::Jianpin { letter: b'Z' };
        let ch = SyllableQuery::Jianpin { letter: b'C' };
        let z = SyllableQuery::Jianpin { letter: b'z' };
        let c = SyllableQuery::Jianpin { letter: b'c' };
        let chi = Syllable::from_text("chi").unwrap().query(false);
        assert_eq!(words(&[zh, ch]), vec!["支持"]);
        assert_eq!(words(&[zh, c]), vec!["支持", "至此"]);
        assert_eq!(words(&[z, c]), vec!["支持", "自持", "至此"]);
        assert_eq!(words(&[zh, chi]), vec!["支持"]);
        assert_eq!(words(&[z, chi]), vec!["支持", "自持"]);
        assert!(lex.has_longer(&[zh]));
    }

    #[test]
    fn erhua_lookup() {
        let lex = lex();
        let hua = Syllable::from_text("hua").unwrap();
        let found = lex.lookup(&[hua.query(true)]);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].word, "花儿");
        assert!(lex.lookup(&[hua.query(false)]).is_empty());
    }

    #[test]
    fn rejects_ambiguous_concatenation() {
        assert!(parse_pinyin_keys("fangan").is_err());
    }

    #[test]
    fn total_freq_and_cost() {
        let lex = lex();
        assert_eq!(lex.total_freq(), 2400.0);
        let entry = lex.entries().next().unwrap();
        assert!(lex.cost(&entry) > 0.0);
    }

    #[test]
    fn lenient_loading_skips_unknown_syllables() {
        // 「cei」不在音节表里，整行跳过而不是让整个词库失败
        let lex = MemoryLexicon::from_tsv_str("ni hao\t你好\t100\ncei\t呲\t5\n").unwrap();
        assert_eq!(lex.len(), 1);
        assert_eq!(lex.skipped(), 1);
    }

    #[test]
    fn structural_errors_still_fail() {
        assert!(MemoryLexicon::from_tsv_str("只有两列\t词\n").is_err());
        assert!(MemoryLexicon::from_tsv_str("ni hao\t你好\tabc\n").is_err());
    }

    fn temp_lexicon(tag: &str, body: &str) -> std::path::PathBuf {
        let path =
            std::env::temp_dir().join(format!("wotype_lex_{}_{}.tsv", tag, std::process::id()));
        let _ = std::fs::remove_file(&path);
        let _ = std::fs::remove_file(cache_path(&path));
        std::fs::write(&path, body).expect("写临时词库失败");
        path
    }

    fn cleanup(path: &std::path::Path) {
        let _ = std::fs::remove_file(path);
        let _ = std::fs::remove_file(cache_path(path));
    }

    #[test]
    fn split_syllables_prefers_fewest_and_longest_first() {
        assert_eq!(split_syllables("nihao").as_deref(), Some("ni hao"));
        assert_eq!(split_syllables("fangan").as_deref(), Some("fang an"));
        assert_eq!(split_syllables("xian").as_deref(), Some("xian"));
        assert_eq!(
            split_syllables("zhongguoren").as_deref(),
            Some("zhong guo ren")
        );
        assert_eq!(split_syllables("github"), None);
        assert_eq!(split_syllables("Ni"), None);
    }

    #[test]
    fn cache_roundtrip_matches_tsv() {
        let path = temp_lexicon("rt", "ni hao\t你好\t100\nzhong guo\t中国\t50\n");
        let first = MemoryLexicon::from_tsv_path_cached(&path).unwrap();
        assert!(cache_path(&path).exists(), "第一次加载应当写出快照");
        // 直接读快照：读不回来时 from_tsv_path_cached 会悄悄退回解析 TSV，看不出问题
        let (len, mtime) = source_stamp(&path).unwrap();
        let second =
            MemoryLexicon::map_cache(&cache_path(&path), len, mtime).expect("快照应当能读回来");
        assert!(first.is_mapped() && second.is_mapped(), "写完快照就映射它");
        let parsed = MemoryLexicon::from_tsv_path(&path).unwrap();
        assert!(!parsed.is_mapped());
        assert_eq!(parsed.len(), second.len());
        assert_eq!(&*parsed.entries, &*second.entries);
        assert_eq!(&*parsed.text, &*second.text);
        assert_eq!(&*parsed.keys, &*second.keys);
        assert_eq!(&*parsed.initials, &*second.initials);
        assert_eq!(&*parsed.by_initials, &*second.by_initials);
        assert_eq!(first.total_freq, second.total_freq);
        cleanup(&path);
    }

    #[test]
    fn stale_cache_is_ignored() {
        let path = temp_lexicon("stale", "ni hao\t你好\t100\n");
        let first = MemoryLexicon::from_tsv_path_cached(&path).unwrap();
        assert_eq!(first.len(), 1);
        // 源文件变了（内容更长），旧快照必须失效
        std::fs::write(
            &path,
            "ni hao\t你好\t100\nzhong guo\t中国\t50\nshi jie\t世界\t30\n",
        )
        .unwrap();
        let second = MemoryLexicon::from_tsv_path_cached(&path).unwrap();
        assert_eq!(second.len(), 3, "源文件更新后应当重新解析");
        cleanup(&path);
    }

    #[test]
    fn custom_cache_dir_never_writes_next_to_lexicon() {
        let path = Path::new("/Applications/WoType.app/Contents/Resources/Data/lexicon.tsv");
        let dir = std::path::PathBuf::from("/tmp/wotype-cache");
        let paths = cache_paths_in(path, Some(dir.clone()));
        assert_eq!(paths.len(), 1);
        assert!(
            paths[0].starts_with(&dir),
            "快照应当只写到指定目录：{paths:?}"
        );
        assert_eq!(
            cache_paths_in(path, None)[0],
            cache_path(path),
            "默认仍先放词库旁边"
        );
    }

    #[test]
    fn corrupt_cache_falls_back_to_tsv() {
        let path = temp_lexicon("corrupt", "ni hao\t你好\t100\n");
        let _ = MemoryLexicon::from_tsv_path_cached(&path).unwrap();
        std::fs::write(cache_path(&path), b"not a cache").unwrap();
        let lex = MemoryLexicon::from_tsv_path_cached(&path).unwrap();
        assert_eq!(lex.len(), 1, "快照损坏时应回退到 TSV");
        cleanup(&path);
    }
    #[test]
    fn truncated_or_padded_cache_is_rejected() {
        let path = temp_lexicon("trunc", "ni hao\t你好\t100\nzhong guo\t中国\t50\n");
        drop(MemoryLexicon::from_tsv_path_cached(&path).unwrap());
        let (len, mtime) = source_stamp(&path).unwrap();
        let cache = cache_path(&path);
        let good = std::fs::read(&cache).unwrap();
        assert!(MemoryLexicon::map_cache(&cache, len, mtime).is_some());
        // 截断、后面多出东西、头里的数字改大：都不认
        for bad in [
            good[..good.len() - 1].to_vec(),
            good[..CACHE_HEADER_BYTES].to_vec(),
            [good.clone(), vec![0]].concat(),
            {
                let mut data = good.clone();
                data[32..40].copy_from_slice(&u64::MAX.to_le_bytes());
                data
            },
        ] {
            std::fs::write(&cache, &bad).unwrap();
            assert!(MemoryLexicon::map_cache(&cache, len, mtime).is_none());
            let lex = MemoryLexicon::from_tsv_path_cached(&path).unwrap();
            assert_eq!(lex.len(), 2, "退回解析 TSV");
            drop(lex);
        }
        cleanup(&path);
    }

    #[test]
    fn garbage_inside_cache_never_panics() {
        // 映射的快照不逐条核对：里面的位置是乱的也只能查不到词，不能越界
        let path = temp_lexicon("garbage", "ni hao\t你好\t100\nzhong guo\t中国\t50\nni\t你\t9\n");
        drop(MemoryLexicon::from_tsv_path_cached(&path).unwrap());
        let (len, mtime) = source_stamp(&path).unwrap();
        let cache = cache_path(&path);
        let mut data = std::fs::read(&cache).unwrap();
        for byte in &mut data[CACHE_HEADER_BYTES..] {
            *byte = 0xff;
        }
        std::fs::write(&cache, &data).unwrap();
        let lex = MemoryLexicon::map_cache(&cache, len, mtime).expect("头是好的");
        let ni = SyllableQuery::Full {
            id: Syllable::from_text("ni").unwrap().id,
            erhua: false,
        };
        let _ = lex.lookup(&[ni]);
        let _ = lex.lookup(&[SyllableQuery::Jianpin { letter: b'n' }]);
        let _ = lex.lookup_fuzzy(&[ni]);
        let _ = lex.has_longer(&[ni]);
        assert!(lex.entries().all(|e| e.word.is_empty()));
        cleanup(&path);
    }

    #[test]
    fn mapped_lexicon_answers_like_the_parsed_one() {
        let path = temp_lexicon(
            "same",
            "ni hao\t你好\t100\nni hao\t拟好\t5\nzhong guo\t中国\t50\nni\t你\t9\nzi dao\t自导\t3\nzhi dao\t知道\t80\n",
        );
        assert!(!MemoryLexicon::cache_ready(&path), "还没建快照");
        let mapped = MemoryLexicon::from_tsv_path_cached(&path).unwrap();
        assert!(MemoryLexicon::cache_ready(&path));
        let parsed = MemoryLexicon::from_tsv_path(&path).unwrap();
        assert!(mapped.is_mapped() && !parsed.is_mapped());
        let full = |text: &str| SyllableQuery::Full {
            id: Syllable::from_text(text).unwrap().id,
            erhua: false,
        };
        let queries = [
            vec![full("ni"), full("hao")],
            vec![full("ni")],
            vec![full("zi"), full("dao")],
            vec![SyllableQuery::Jianpin { letter: b'n' }, SyllableQuery::Jianpin { letter: b'h' }],
            vec![full("ni"), SyllableQuery::Jianpin { letter: b'h' }],
        ];
        for query in &queries {
            assert_eq!(mapped.lookup(query), parsed.lookup(query));
            assert_eq!(mapped.lookup_fuzzy(query), parsed.lookup_fuzzy(query));
            assert_eq!(mapped.has_longer(query), parsed.has_longer(query));
        }
        assert_eq!(mapped.total_freq(), parsed.total_freq());
        cleanup(&path);
    }

    #[test]
    fn placeholder_weight_words_get_estimated_from_their_parts() {
        let mut lex = MemoryLexicon::from_tsv_str(
            "bu\t不\t3000000\njian yi\t建议\t500000\nbu jian\t不见\t250000\nyi\t一\t35000000\n\
             bu jian yi\t不建议\t100\nbu jian ying\t不坚硬\t100\nhao\t好\t9000\n\
             zhe ge\t这个\t100\n",
        )
        .unwrap();
        let total = lex.total_freq;
        lex.estimate_placeholder_freqs(2);
        let freq = |w: &str| lex.entries().find(|e| e.word == w).unwrap().freq;
        // 不建议 = 不 × 建议 × 加成，高过「不见 + 一」这句
        let cost = |f: f64| -(f / total).ln();
        assert!(cost(freq("不建议")) < cost(freq("不见")) + cost(freq("一")));
        // 不会高过最冷门的那部分
        assert!(freq("不建议") <= 500000.0);
        // 切不开的词保持原样；总频次不变
        assert_eq!(freq("不坚硬"), 100.0);
        assert_eq!(freq("这个"), 100.0);
        assert_eq!(lex.total_freq, total);
    }
}
