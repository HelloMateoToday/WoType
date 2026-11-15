//! C ABI：供 fcitx5 的 C++ 插件通过 cdylib 调用。
//!
//! 设计成“不透明句柄 + 候选句柄”，避免 C++ 侧解析 JSON。字符串一律 UTF-8。

// 安全契约见 core/include/wotype_core.h：空指针、句柄生命周期由调用方保证。
#![allow(clippy::missing_safety_doc)]

use std::cell::RefCell;
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int};
use std::panic;
use std::ptr;
use std::sync::Arc;

use crate::lexicon::{Lexicon, MemoryLexicon};
use crate::lm::{BigramLm, LanguageModel};
use crate::Engine;

thread_local! {
    static LAST_ERROR: RefCell<CString> =
        RefCell::new(CString::new("no error").expect("static error string"));
}

fn set_last_error(message: impl Into<String>) {
    let text = message.into().replace('\0', " ");
    let value = CString::new(text)
        .unwrap_or_else(|_| CString::new("unknown error").expect("static error string"));
    LAST_ERROR.with(|slot| *slot.borrow_mut() = value);
}

unsafe fn cstr_to_str<'a>(ptr: *const c_char) -> Option<&'a str> {
    if ptr.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(ptr) }.to_str().ok()
}

/// 引擎句柄。
pub struct WotypeEngineHandle {
    engine: Engine,
}

impl WotypeEngineHandle {
    pub(crate) fn engine(&self) -> &Engine {
        &self.engine
    }
}

/// 一次输入产生的候选集合（预测结果也用这个结构承载）。
pub struct WotypeCandidates {
    texts: Vec<CString>,
    scores: Vec<f64>,
    /// 候选对应的拼音（空格分隔音节）；预测、符号结果为空串。
    pinyins: Vec<CString>,
    /// 候选用掉了输入的多少字节；整句候选等于输入长度。
    consumed: Vec<usize>,
    /// 选中后上屏的文字（emoji 推荐用）；空表示就是 text。
    commits: Vec<CString>,
}

impl WotypeCandidates {
    /// 只有文本和分数的结果（预测、符号）。
    fn plain(texts: Vec<CString>, scores: Vec<f64>) -> Self {
        let n = texts.len();
        Self {
            texts,
            scores,
            pinyins: vec![CString::default(); n],
            consumed: vec![0; n],
            commits: Vec::new(),
        }
    }
}

/// 创建引擎。
///
/// lexicon_tsv_path 必填；bigram_tsv_path 可为 NULL/空串，表示不加载 LM。
/// 失败返回 NULL，错误信息用 wotype_last_error 获取。
#[no_mangle]
pub unsafe extern "C" fn wotype_engine_new(
    lexicon_tsv_path: *const c_char,
    bigram_tsv_path: *const c_char,
) -> *mut WotypeEngineHandle {
    let lexicon_path = match unsafe { cstr_to_str(lexicon_tsv_path) } {
        Some(path) if !path.is_empty() => path,
        _ => {
            set_last_error("lexicon path is null or empty");
            return ptr::null_mut();
        }
    };

    let result = (|| -> anyhow::Result<Engine> {
        let lexicon = MemoryLexicon::from_tsv_path_cached(lexicon_path)?;
        let lexicon: Arc<dyn Lexicon> = Arc::new(lexicon);
        let lm: Arc<dyn LanguageModel> = match unsafe { cstr_to_str(bigram_tsv_path) } {
            Some(path) if !path.is_empty() => crate::lm::load_lm(path)?,
            _ => Arc::new(BigramLm::default()),
        };
        Ok(Engine::new(lexicon, lm))
    })();

    match result {
        Ok(engine) => Box::into_raw(Box::new(WotypeEngineHandle { engine })),
        Err(error) => {
            set_last_error(format!("{error:#}"));
            ptr::null_mut()
        }
    }
}

/// 释放引擎。
#[no_mangle]
pub unsafe extern "C" fn wotype_engine_free(engine: *mut WotypeEngineHandle) {
    if !engine.is_null() {
        drop(unsafe { Box::from_raw(engine) });
    }
}

/// 设置 beam size；返回 0 成功，-1 失败。
#[no_mangle]
pub unsafe extern "C" fn wotype_engine_set_beam_size(
    engine: *mut WotypeEngineHandle,
    beam_size: u32,
) -> c_int {
    match unsafe { engine.as_mut() } {
        Some(handle) => {
            handle.engine.set_beam_size(beam_size as usize);
            0
        }
        None => {
            set_last_error("engine handle is null");
            -1
        }
    }
}

/// 输入拼音串，返回候选句柄；失败返回 NULL。
#[no_mangle]
pub unsafe extern "C" fn wotype_engine_input(
    engine: *mut WotypeEngineHandle,
    input: *const c_char,
) -> *mut WotypeCandidates {
    let handle = match unsafe { engine.as_ref() } {
        Some(handle) => handle,
        None => {
            set_last_error("engine handle is null");
            return ptr::null_mut();
        }
    };
    let input = match unsafe { cstr_to_str(input) } {
        Some(input) => input,
        None => {
            set_last_error("input is null or not valid UTF-8");
            return ptr::null_mut();
        }
    };

    let outcome = panic::catch_unwind(panic::AssertUnwindSafe(|| handle.engine.try_input(input)));
    match outcome {
        Ok(Ok(candidates)) => {
            let mut texts = Vec::with_capacity(candidates.len());
            let mut scores = Vec::with_capacity(candidates.len());
            let mut pinyins = Vec::with_capacity(candidates.len());
            let mut consumed = Vec::with_capacity(candidates.len());
            for candidate in candidates {
                let text = candidate.text.replace('\0', " ");
                texts.push(CString::new(text).unwrap_or_default());
                scores.push(candidate.score);
                pinyins.push(CString::new(candidate.pinyin.replace('\0', " ")).unwrap_or_default());
                consumed.push(candidate.consumed.min(input.len()));
            }
            Box::into_raw(Box::new(WotypeCandidates {
                texts,
                scores,
                pinyins,
                consumed,
                commits: Vec::new(),
            }))
        }
        Ok(Err(error)) => {
            set_last_error(format!("{error:#}"));
            ptr::null_mut()
        }
        Err(_) => {
            set_last_error("Rust panic while processing input");
            ptr::null_mut()
        }
    }
}

/// 基于上一词的预测（预测词库）。
///
/// 成功返回候选集合句柄（text 是预测词，score 是对数概率），
/// 失败返回 NULL；结果同样用 wotype_candidates_free 释放。
#[no_mangle]
pub unsafe extern "C" fn wotype_engine_predict_next(
    engine: *const WotypeEngineHandle,
    prev_word: *const c_char,
    limit: usize,
) -> *mut WotypeCandidates {
    let outcome = panic::catch_unwind(panic::AssertUnwindSafe(|| {
        if engine.is_null() {
            set_last_error("engine is null");
            return ptr::null_mut();
        }
        let Some(prev) = (unsafe { cstr_to_str(prev_word) }) else {
            set_last_error("prev_word is null or not utf8");
            return ptr::null_mut();
        };
        let items = unsafe { &*engine }.engine.predict_next(prev, limit);
        let mut texts = Vec::with_capacity(items.len());
        let mut scores = Vec::with_capacity(items.len());
        for (word, score) in items {
            match CString::new(word) {
                Ok(text) => {
                    texts.push(text);
                    scores.push(score);
                }
                Err(_) => continue,
            }
        }
        Box::into_raw(Box::new(WotypeCandidates::plain(texts, scores)))
    }));
    match outcome {
        Ok(candidates) => candidates,
        Err(_) => {
            set_last_error("panic in wotype_engine_predict_next");
            ptr::null_mut()
        }
    }
}

/// 记录一次选词，用于历史特征。返回 0 表示成功。
#[no_mangle]
pub unsafe extern "C" fn wotype_engine_record_selection(
    engine: *mut WotypeEngineHandle,
    word: *const c_char,
) -> c_int {
    if engine.is_null() {
        set_last_error("engine is null");
        return -1;
    }
    let Some(word) = (unsafe { cstr_to_str(word) }) else {
        set_last_error("word is null or not utf8");
        return -1;
    };
    unsafe { &*engine }.engine.record_selection(word);
    0
}

/// 设置光标前文本，用于上下文 bigram 特征。返回 0 表示成功。
#[no_mangle]
pub unsafe extern "C" fn wotype_engine_set_context(
    engine: *mut WotypeEngineHandle,
    text: *const c_char,
) -> c_int {
    if engine.is_null() {
        set_last_error("engine is null");
        return -1;
    }
    let Some(text) = (unsafe { cstr_to_str(text) }) else {
        set_last_error("context is null or not utf8");
        return -1;
    };
    unsafe { &*engine }.engine.set_context(text);
    0
}

/// 添加用户词。返回 0 成功，-1 失败（拼音非法等）。
#[no_mangle]
pub unsafe extern "C" fn wotype_engine_add_user_word(
    engine: *mut WotypeEngineHandle,
    pinyin: *const c_char,
    word: *const c_char,
) -> c_int {
    if engine.is_null() {
        set_last_error("engine is null");
        return -1;
    }
    let (Some(pinyin), Some(word)) = (unsafe { cstr_to_str(pinyin) }, unsafe { cstr_to_str(word) })
    else {
        set_last_error("pinyin or word is null/not utf8");
        return -1;
    };
    match unsafe { &*engine }
        .engine
        .add_user_word(pinyin, word, 5000.0)
    {
        Ok(()) => 0,
        Err(e) => {
            set_last_error(format!("{e:#}"));
            -1
        }
    }
}

/// 删除用户词。返回 1 删掉了，0 没找到，-1 出错。
#[no_mangle]
pub unsafe extern "C" fn wotype_engine_remove_user_word(
    engine: *mut WotypeEngineHandle,
    word: *const c_char,
) -> c_int {
    if engine.is_null() {
        set_last_error("engine is null");
        return -1;
    }
    let Some(word) = (unsafe { cstr_to_str(word) }) else {
        set_last_error("word is null or not utf8");
        return -1;
    };
    if unsafe { &*engine }.engine.remove_user_word(word) {
        1
    } else {
        0
    }
}

/// 保存用户词到 TSV。返回 0 成功，-1 失败。
#[no_mangle]
pub unsafe extern "C" fn wotype_engine_save_user_dict(
    engine: *mut WotypeEngineHandle,
    path: *const c_char,
) -> c_int {
    if engine.is_null() {
        set_last_error("engine is null");
        return -1;
    }
    let Some(path) = (unsafe { cstr_to_str(path) }) else {
        set_last_error("path is null or not utf8");
        return -1;
    };
    match unsafe { &*engine }.engine.save_user_dict(path) {
        Ok(()) => 0,
        Err(e) => {
            set_last_error(format!("{e:#}"));
            -1
        }
    }
}

/// 从 TSV 载入用户词，返回载入条数，-1 表示出错。
#[no_mangle]
pub unsafe extern "C" fn wotype_engine_load_user_dict(
    engine: *mut WotypeEngineHandle,
    path: *const c_char,
) -> c_int {
    if engine.is_null() {
        set_last_error("engine is null");
        return -1;
    }
    let Some(path) = (unsafe { cstr_to_str(path) }) else {
        set_last_error("path is null or not utf8");
        return -1;
    };
    match unsafe { &*engine }.engine.load_user_dict(path) {
        Ok(n) => n as c_int,
        Err(e) => {
            set_last_error(format!("{e:#}"));
            -1
        }
    }
}

/// 读自定义词文件（`拼音<TAB>词[<TAB>频次]`，设置界面写的 custom.tsv），整体替换上一次读到的；
/// 文件不存在就清空。返回收下的条数，-1 出错。
#[no_mangle]
pub unsafe extern "C" fn wotype_engine_load_custom_words(
    engine: *mut WotypeEngineHandle,
    path: *const c_char,
) -> c_int {
    if engine.is_null() {
        set_last_error("engine is null");
        return -1;
    }
    let Some(path) = (unsafe { cstr_to_str(path) }) else {
        set_last_error("path is null or not utf8");
        return -1;
    };
    match unsafe { &*engine }.engine.load_custom_words(path) {
        Ok(n) => n as c_int,
        Err(e) => {
            set_last_error(format!("{e:#}"));
            -1
        }
    }
}

/// 保存用户输入习惯（选过的词的热度、词搭配）到 TSV。返回 0 成功，-1 失败。
#[no_mangle]
pub unsafe extern "C" fn wotype_engine_save_history(
    engine: *mut WotypeEngineHandle,
    path: *const c_char,
) -> c_int {
    if engine.is_null() {
        set_last_error("engine is null");
        return -1;
    }
    let Some(path) = (unsafe { cstr_to_str(path) }) else {
        set_last_error("path is null or not utf8");
        return -1;
    };
    match unsafe { &*engine }.engine.save_history(path) {
        Ok(()) => 0,
        Err(e) => {
            set_last_error(format!("{e:#}"));
            -1
        }
    }
}

/// 读回用户输入习惯，返回条数，-1 表示出错（文件不存在也是 -1）。
#[no_mangle]
pub unsafe extern "C" fn wotype_engine_load_history(
    engine: *mut WotypeEngineHandle,
    path: *const c_char,
) -> c_int {
    if engine.is_null() {
        set_last_error("engine is null");
        return -1;
    }
    let Some(path) = (unsafe { cstr_to_str(path) }) else {
        set_last_error("path is null or not utf8");
        return -1;
    };
    match unsafe { &*engine }.engine.load_history(path) {
        Ok(n) => n as c_int,
        Err(e) => {
            set_last_error(format!("{e:#}"));
            -1
        }
    }
}

/// 每次输入最多返回多少个整句候选（句首词候选另算）。返回 0 成功，-1 失败。
#[no_mangle]
pub unsafe extern "C" fn wotype_engine_set_max_candidates(
    engine: *mut WotypeEngineHandle,
    max_candidates: u32,
) -> c_int {
    if engine.is_null() {
        set_last_error("engine is null");
        return -1;
    }
    unsafe { &mut *engine }
        .engine
        .set_max_candidates(max_candidates as usize);
    0
}

/// 开关按错键纠错（相邻键、两键按反、多按/漏按）。返回 0 成功，-1 失败。
#[no_mangle]
pub unsafe extern "C" fn wotype_engine_set_typo_correction(
    engine: *mut WotypeEngineHandle,
    on: c_int,
) -> c_int {
    if engine.is_null() {
        set_last_error("engine is null");
        return -1;
    }
    unsafe { &mut *engine }.engine.set_typo_correction(on != 0);
    0
}

/// 设置「这个字画不画得出来」的回调（参数是码位）；画不出来的字不出候选。传 NULL 取消。
/// 只会拿 U+20000 以后的字来问，每个字问一次；回调要能在任意线程调用。
#[no_mangle]
pub unsafe extern "C" fn wotype_engine_set_glyph_check(
    engine: *mut WotypeEngineHandle,
    check: Option<extern "C" fn(u32) -> bool>,
) {
    if engine.is_null() {
        return;
    }
    let check = check.map(|f| Box::new(move |c: char| f(c as u32)) as crate::GlyphCheck);
    unsafe { &*engine }.engine.set_glyph_check(check);
}

/// 换一份快捷短语（quick-phrases.tsv 的内容），整份替换；NULL 或空串清空。返回条数，失败返回 -1。
///
/// # Safety
/// `engine` 必须是 `wotype_engine_new` 返回的有效句柄；`tsv` 为 NULL 或有效的 UTF-8 C 字符串。
#[no_mangle]
pub unsafe extern "C" fn wotype_engine_set_quick_phrases(
    engine: *mut WotypeEngineHandle,
    tsv: *const c_char,
) -> c_int {
    if engine.is_null() {
        set_last_error("engine is null");
        return -1;
    }
    let tsv = unsafe { cstr_to_str(tsv) }.unwrap_or("");
    unsafe { &*engine }.engine.set_quick_phrases(tsv).min(c_int::MAX as usize) as c_int
}

/// 载入混合编码词表（万象的 dicts/mixed.dict.yaml：Azuo -> A座），整份替换，返回词条数；失败返回 -1。
#[no_mangle]
pub unsafe extern "C" fn wotype_engine_load_mixed(
    engine: *mut WotypeEngineHandle,
    path: *const c_char,
) -> c_int {
    if engine.is_null() {
        set_last_error("engine is null");
        return -1;
    }
    let Some(path) = (unsafe { cstr_to_str(path) }) else {
        set_last_error("path is null or not utf8");
        return -1;
    };
    match unsafe { &*engine }.engine.load_mixed(path) {
        Ok(n) => n.min(c_int::MAX as usize) as c_int,
        Err(e) => {
            set_last_error(e.to_string());
            -1
        }
    }
}

/// 载入英文词表（每行一个词，或 rime 的 en.dict.yaml），返回累计词条数；失败返回 -1。
#[no_mangle]
pub unsafe extern "C" fn wotype_engine_load_english(
    engine: *mut WotypeEngineHandle,
    path: *const c_char,
) -> c_int {
    if engine.is_null() {
        set_last_error("engine is null");
        return -1;
    }
    let Some(path) = (unsafe { cstr_to_str(path) }) else {
        set_last_error("path is null or not utf8");
        return -1;
    };
    match unsafe { &*engine }.engine.load_english(path) {
        Ok(n) => n.min(c_int::MAX as usize) as c_int,
        Err(e) => {
            set_last_error(format!("{e:#}"));
            -1
        }
    }
}

/// 载入字级神经语言模型（微信输入法的 nlrgpt2_nnlm.bin）。返回字表大小，失败返回 -1。
#[no_mangle]
pub unsafe extern "C" fn wotype_engine_load_nnlm(
    engine: *mut WotypeEngineHandle,
    path: *const c_char,
) -> c_int {
    if engine.is_null() {
        set_last_error("engine is null");
        return -1;
    }
    let Some(path) = (unsafe { cstr_to_str(path) }) else {
        set_last_error("path is null or not utf8");
        return -1;
    };
    match unsafe { &*engine }.engine.load_nnlm(path) {
        Ok(n) => n.min(c_int::MAX as usize) as c_int,
        Err(e) => {
            set_last_error(format!("{e:#}"));
            -1
        }
    }
}

/// 开关模糊音（z/zh、an/ang 等）。返回 0 成功，-1 失败。
#[no_mangle]
pub unsafe extern "C" fn wotype_engine_set_fuzzy(
    engine: *mut WotypeEngineHandle,
    on: c_int,
) -> c_int {
    if engine.is_null() {
        set_last_error("engine is null");
        return -1;
    }
    unsafe { &mut *engine }.engine.set_fuzzy(on != 0);
    0
}

/// 开关双拼（自然码）。返回 0 成功，-1 失败。
#[no_mangle]
pub unsafe extern "C" fn wotype_engine_set_shuangpin(
    engine: *mut WotypeEngineHandle,
    on: c_int,
) -> c_int {
    if engine.is_null() {
        set_last_error("engine is null");
        return -1;
    }
    unsafe { &mut *engine }.engine.set_shuangpin(on != 0);
    0
}

/// 开关繁体输出。返回 0 成功，-1 失败。
#[no_mangle]
pub unsafe extern "C" fn wotype_engine_set_traditional(
    engine: *mut WotypeEngineHandle,
    on: c_int,
) -> c_int {
    if engine.is_null() {
        set_last_error("engine is null");
        return -1;
    }
    unsafe { &mut *engine }.engine.set_traditional(on != 0);
    0
}

/// 载入简繁映射表（简体<TAB>繁体），返回条目数；失败返回 -1。
#[no_mangle]
pub unsafe extern "C" fn wotype_engine_load_conversion(
    engine: *mut WotypeEngineHandle,
    path: *const c_char,
) -> c_int {
    if engine.is_null() {
        set_last_error("engine is null");
        return -1;
    }
    let Some(path) = (unsafe { cstr_to_str(path) }) else {
        set_last_error("path is null or not utf8");
        return -1;
    };
    match unsafe { &*engine }.engine.load_conversion(path) {
        Ok(n) => n as c_int,
        Err(e) => {
            set_last_error(format!("{e:#}"));
            -1
        }
    }
}

thread_local! {
    static PUNCT_BUF: RefCell<CString> =
        RefCell::new(CString::new("，").expect("static punct"));
}

/// ASCII 标点转中文标点。返回的指针在下一次调用前有效，未收录返回 NULL。
#[no_mangle]
pub extern "C" fn wotype_fullwidth_punct(code: c_int) -> *const c_char {
    let Some(ch) = char::from_u32(code as u32) else {
        return ptr::null();
    };
    let Some(text) = crate::symbols::fullwidth_punct(ch) else {
        return ptr::null();
    };
    PUNCT_BUF.with(|slot| {
        *slot.borrow_mut() = CString::new(text).unwrap_or_default();
        slot.borrow().as_ptr()
    })
}

/// 符号检索。query 为拼音或中文名前缀，结果放在候选结构里（score 恒为 0）。
#[no_mangle]
pub unsafe extern "C" fn wotype_symbol_search(
    query: *const c_char,
    limit: usize,
) -> *mut WotypeCandidates {
    let Some(query) = (unsafe { cstr_to_str(query) }) else {
        set_last_error("query is null or not utf8");
        return ptr::null_mut();
    };
    let mut texts = Vec::new();
    let mut scores = Vec::new();
    for symbol in crate::symbols::search(query, limit) {
        match CString::new(symbol.text) {
            Ok(text) => {
                texts.push(text);
                scores.push(0.0);
            }
            Err(_) => continue,
        }
    }
    Box::into_raw(Box::new(WotypeCandidates::plain(texts, scores)))
}

/// 打字时的 emoji 推荐：text 是首选候选的文字。结果的 text 是显示文字，
/// 上屏文字用 wotype_candidates_commit 取（整个词对上时只有 emoji，句尾对上时是整句 + emoji）。
#[no_mangle]
pub unsafe extern "C" fn wotype_emoji_recommend(
    text: *const c_char,
    limit: usize,
) -> *mut WotypeCandidates {
    let Some(text) = (unsafe { cstr_to_str(text) }) else {
        set_last_error("text is null or not utf8");
        return ptr::null_mut();
    };
    let suggestions = crate::emoji::recommend(text, limit);
    let mut texts = Vec::new();
    let mut commits = Vec::new();
    for suggestion in suggestions {
        if let (Ok(display), Ok(commit)) = (
            CString::new(suggestion.display),
            CString::new(suggestion.commit),
        ) {
            texts.push(display);
            commits.push(commit);
        }
    }
    let scores = vec![0.0; texts.len()];
    let mut out = WotypeCandidates::plain(texts, scores);
    out.commits = commits;
    Box::into_raw(Box::new(out))
}

/// 表情面板的搜索：query 为空给全部 emoji；否则按拼音（经引擎转成中文词）、英文和
/// 符号名一起找。engine 可为 NULL（只按英文和符号名找）。
#[no_mangle]
pub unsafe extern "C" fn wotype_engine_emoji_search(
    engine: *const WotypeEngineHandle,
    query: *const c_char,
    limit: usize,
) -> *mut WotypeCandidates {
    let Some(query) = (unsafe { cstr_to_str(query) }) else {
        set_last_error("query is null or not utf8");
        return ptr::null_mut();
    };
    let engine = unsafe { engine.as_ref() }.map(WotypeEngineHandle::engine);
    let results = crate::session::search_emoji(engine, query, limit);
    let texts: Vec<CString> = results
        .into_iter()
        .take(limit.max(1))
        .filter_map(|t| CString::new(t).ok())
        .collect();
    let scores = vec![0.0; texts.len()];
    Box::into_raw(Box::new(WotypeCandidates::plain(texts, scores)))
}

/// 选中后上屏的文字：emoji 推荐的结果可能和显示的不一样，其他候选就是 text。越界返回 NULL。
#[no_mangle]
pub unsafe extern "C" fn wotype_candidates_commit(
    candidates: *const WotypeCandidates,
    index: usize,
) -> *const c_char {
    unsafe { candidates.as_ref() }
        .and_then(|c| c.commits.get(index).or_else(|| c.texts.get(index)))
        .map(|text| text.as_ptr())
        .unwrap_or(ptr::null())
}

/// 记录选词并可携带拼音：选够次数后自动加入用户词库。pinyin 可为 NULL。
#[no_mangle]
pub unsafe extern "C" fn wotype_engine_record_selection_ex(
    engine: *mut WotypeEngineHandle,
    word: *const c_char,
    pinyin: *const c_char,
) -> c_int {
    if engine.is_null() {
        set_last_error("engine is null");
        return -1;
    }
    let Some(word) = (unsafe { cstr_to_str(word) }) else {
        set_last_error("word is null or not utf8");
        return -1;
    };
    let pinyin = unsafe { cstr_to_str(pinyin) }.filter(|p| !p.is_empty());
    unsafe { &*engine }
        .engine
        .record_selection_with_pinyin(word, pinyin);
    0
}

/// 候选数量。
#[no_mangle]
pub unsafe extern "C" fn wotype_candidates_len(candidates: *const WotypeCandidates) -> usize {
    unsafe { candidates.as_ref() }
        .map(|c| c.texts.len())
        .unwrap_or(0)
}

/// 候选文本（UTF-8，以 NUL 结尾）。索引越界返回 NULL。
#[no_mangle]
pub unsafe extern "C" fn wotype_candidates_text(
    candidates: *const WotypeCandidates,
    index: usize,
) -> *const c_char {
    unsafe { candidates.as_ref() }
        .and_then(|c| c.texts.get(index))
        .map(|text| text.as_ptr())
        .unwrap_or(ptr::null())
}

/// 候选分数。索引越界返回 0。
#[no_mangle]
pub unsafe extern "C" fn wotype_candidates_score(
    candidates: *const WotypeCandidates,
    index: usize,
) -> f64 {
    unsafe { candidates.as_ref() }
        .and_then(|c| c.scores.get(index).copied())
        .unwrap_or(0.0)
}

/// 候选的拼音（空格分隔，按纠错后的音节）；没有拼音或越界返回空串/NULL。
#[no_mangle]
pub unsafe extern "C" fn wotype_candidates_pinyin(
    candidates: *const WotypeCandidates,
    index: usize,
) -> *const c_char {
    unsafe { candidates.as_ref() }
        .and_then(|c| c.pinyins.get(index))
        .map(|text| text.as_ptr())
        .unwrap_or(ptr::null())
}

/// 候选用掉了输入的多少字节。小于输入长度时是句首词候选：
/// 上屏这个词后，剩下的输入（从这个偏移开始）继续留在编辑区。越界返回 0。
#[no_mangle]
pub unsafe extern "C" fn wotype_candidates_consumed(
    candidates: *const WotypeCandidates,
    index: usize,
) -> usize {
    unsafe { candidates.as_ref() }
        .and_then(|c| c.consumed.get(index).copied())
        .unwrap_or(0)
}

/// 释放候选集合。
#[no_mangle]
pub unsafe extern "C" fn wotype_candidates_free(candidates: *mut WotypeCandidates) {
    if !candidates.is_null() {
        drop(unsafe { Box::from_raw(candidates) });
    }
}

thread_local! {
    static SEGMENTED: RefCell<CString> = RefCell::new(CString::default());
}

/// 按候选拼音（空格分隔）给输入分词：hengxiang + "heng xiang" -> heng'xiang。
/// 切不了（英文、双拼、差得太多）返回 NULL；返回的串在同一线程下一次调用前有效。
#[no_mangle]
pub unsafe extern "C" fn wotype_segment_input(
    input: *const c_char,
    pinyin: *const c_char,
) -> *const c_char {
    let (Some(input), Some(pinyin)) = (unsafe { cstr_to_str(input) }, unsafe {
        cstr_to_str(pinyin)
    }) else {
        return ptr::null();
    };
    match crate::preedit::segment_input(input, pinyin).and_then(|s| CString::new(s).ok()) {
        Some(text) => SEGMENTED.with(|slot| {
            *slot.borrow_mut() = text;
            slot.borrow().as_ptr()
        }),
        None => ptr::null(),
    }
}

/// 最近一次错误。返回的指针在下一次调用本 API 前有效。
#[no_mangle]
pub extern "C" fn wotype_last_error() -> *const c_char {
    LAST_ERROR.with(|slot| slot.borrow().as_ptr())
}

/// 换一组模糊音规则：逗号分隔的规则 id（z=zh,an=ang,…，见 syllable::FUZZY_RULES），
/// NULL/空串表示一条都不开。所有引擎共用，返回认出来的条数。
#[no_mangle]
pub unsafe extern "C" fn wotype_set_fuzzy_rules(rules: *const c_char) -> c_int {
    let text = unsafe { cstr_to_str(rules) }.unwrap_or("");
    let ids: Vec<&str> = text.split(',').map(str::trim).filter(|s| !s.is_empty()).collect();
    crate::syllable::set_fuzzy_rules(&ids) as c_int
}

/// 指定词库快照目录，要在 wotype_engine_new 之前调用。NULL/空串恢复默认。
#[no_mangle]
pub unsafe extern "C" fn wotype_set_cache_dir(dir: *const c_char) {
    crate::lexicon::set_cache_dir(unsafe { cstr_to_str(dir) }.unwrap_or(""));
}

/// 词库有没有能直接映射的快照：1 有，0 没有（wotype_engine_new 要解析 TSV）。
#[no_mangle]
pub unsafe extern "C" fn wotype_lexicon_cache_ready(lexicon_path: *const c_char) -> c_int {
    let Some(path) = (unsafe { cstr_to_str(lexicon_path) }) else {
        return 0;
    };
    crate::lexicon::MemoryLexicon::cache_ready(path) as c_int
}

/// 删掉这个词库的快照（词库本身不要了的时候调）。
#[no_mangle]
pub unsafe extern "C" fn wotype_lexicon_remove_cache(lexicon_path: *const c_char) {
    if let Some(path) = unsafe { cstr_to_str(lexicon_path) } {
        crate::lexicon::MemoryLexicon::remove_cache(path);
    }
}

/// 给词库建快照（已经有就什么都不做）：1 建好了，0 没建成。给子进程用，见头文件。
#[no_mangle]
pub unsafe extern "C" fn wotype_lexicon_build_cache(lexicon_path: *const c_char) -> c_int {
    let Some(path) = (unsafe { cstr_to_str(lexicon_path) }) else {
        return 0;
    };
    let built = std::panic::catch_unwind(|| {
        crate::lexicon::MemoryLexicon::from_tsv_path_cached(path).is_ok()
            && crate::lexicon::MemoryLexicon::cache_ready(path)
    });
    built.unwrap_or(false) as c_int
}

/// 把万象的词表目录转成 WoType 的词库（在线更新词库用，给子进程调）。
///
/// 写 `out_dir/lexicon.tsv` 和 `out_dir/english.txt`。`hotwords` 可以是 NULL。
/// 返回词条数；失败返回 -1，原因见 `wotype_last_error`。
#[no_mangle]
pub unsafe extern "C" fn wotype_wanxiang_convert(
    dicts_dir: *const c_char,
    hotwords: *const c_char,
    out_dir: *const c_char,
    min_entries: usize,
    source: *const c_char,
) -> i64 {
    let (Some(dicts), Some(out)) = (unsafe { cstr_to_str(dicts_dir) }, unsafe { cstr_to_str(out_dir) }) else {
        set_last_error("目录参数无效");
        return -1;
    };
    let hotwords = unsafe { cstr_to_str(hotwords) }.filter(|p| !p.is_empty());
    let source = unsafe { cstr_to_str(source) }.unwrap_or("");
    let out = std::path::Path::new(out);
    let result = std::panic::catch_unwind(|| {
        let done = crate::wanxiang::convert(
            std::path::Path::new(dicts),
            hotwords.map(std::path::Path::new),
            out,
            crate::wanxiang::MIN_WEIGHT,
            min_entries,
            source,
        )?;
        anyhow::Ok(done.entries)
    });
    match result {
        Ok(Ok(entries)) => entries as i64,
        Ok(Err(e)) => {
            set_last_error(format!("{e:#}"));
            -1
        }
        Err(_) => {
            set_last_error("转换词库时出错");
            -1
        }
    }
}

/// 版本号。
#[no_mangle]
pub extern "C" fn wotype_version() -> *const c_char {
    concat!(env!("CARGO_PKG_VERSION"), "\0").as_ptr() as *const c_char
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ffi_roundtrip() {
        let lexicon = concat!(env!("CARGO_MANIFEST_DIR"), "/data/demo_lexicon.tsv");
        let lexicon = CString::new(lexicon).unwrap();
        let engine = unsafe { wotype_engine_new(lexicon.as_ptr(), ptr::null()) };
        assert!(!engine.is_null(), "engine_new 失败: 见 last_error");

        let input = CString::new("xian").unwrap();
        let candidates = unsafe { wotype_engine_input(engine, input.as_ptr()) };
        assert!(!candidates.is_null());
        let count = unsafe { wotype_candidates_len(candidates) };
        assert!(count >= 2, "xian 应至少有 先/西安 两个候选，实际 {count}");

        let first = unsafe { wotype_candidates_text(candidates, 0) };
        assert!(!first.is_null());
        let first = unsafe { CStr::from_ptr(first) }.to_str().unwrap();
        assert!(!first.is_empty());

        let len = unsafe { wotype_candidates_consumed(candidates, 0) };
        assert_eq!(len, 4, "整句候选用掉全部输入");
        let pinyin = unsafe { wotype_candidates_pinyin(candidates, 0) };
        assert!(!pinyin.is_null());
        assert!(unsafe { wotype_candidates_pinyin(candidates, 99) }.is_null());

        unsafe {
            wotype_candidates_free(candidates);
            wotype_engine_free(engine);
        }

        let version = wotype_version();
        assert!(!version.is_null());
    }
}
