//! 润色规则（polish）的 C 接口。文字都是 UTF-8、以 0 结尾；返回文字的函数写进调用方给的缓冲区，
//! 返回需要的字节数（不含结尾的 0），缓冲区不够时只写能放下的完整的字、调用方加大了再调一次。

use crate::polish::{self, Scene};
use std::ffi::{c_char, c_int, CStr};

unsafe fn text<'a>(ptr: *const c_char) -> &'a str {
    if ptr.is_null() {
        return "";
    }
    CStr::from_ptr(ptr).to_str().unwrap_or("")
}

unsafe fn write(result: &str, out: *mut c_char, capacity: usize) -> usize {
    if !out.is_null() && capacity > 0 {
        let mut n = result.len().min(capacity - 1);
        while !result.is_char_boundary(n) {
            n -= 1;
        }
        std::ptr::copy_nonoverlapping(result.as_ptr(), out as *mut u8, n);
        *out.add(n) = 0;
    }
    result.len()
}

const SCENES: [Scene; 5] = [Scene::Chat, Scene::Email, Scene::Work, Scene::Prompt, Scene::Search];

/// 清理口语：删语气词、重复和明确的改口。
#[no_mangle]
pub unsafe extern "C" fn wotype_polish_clean(source: *const c_char, out: *mut c_char, capacity: usize) -> usize {
    write(&polish::clean_speech(text(source)).text, out, capacity)
}

/// 场景：0 日常输入、1 邮件、2 工作消息、3 编程指令、4 搜索。app 是 bundle ID，site 是网页域名（可以是空）。
#[no_mangle]
pub unsafe extern "C" fn wotype_polish_scene(app: *const c_char, site: *const c_char, search_field: c_int) -> c_int {
    let scene = polish::decide_scene(text(app), text(site), search_field != 0);
    SCENES.iter().position(|&s| s == scene).unwrap_or(0) as c_int
}

/// 场景里机械的部分（搜索去掉句末标点、并成一行）。
#[no_mangle]
pub unsafe extern "C" fn wotype_polish_finish(
    scene: c_int,
    source: *const c_char,
    out: *mut c_char,
    capacity: usize,
) -> usize {
    let scene = SCENES.get(scene as usize).copied().unwrap_or(Scene::Chat);
    write(&polish::finish_scene(scene, text(source)), out, capacity)
}

/// 模型的结果能不能上屏：1 能，0 不能（被截断、空的、带标记）。
#[no_mangle]
pub unsafe extern "C" fn wotype_polish_deliverable(candidate: *const c_char, truncated: c_int) -> c_int {
    polish::deliverable(text(candidate), truncated != 0) as c_int
}

/// 提示词用哪种语言：0 中文（只有汉字）、1 英文（只有拉丁字母）、2 混合。
#[no_mangle]
pub unsafe extern "C" fn wotype_polish_route(source: *const c_char) -> c_int {
    match polish::route(text(source)) {
        "han" => 0,
        "latin" => 1,
        _ => 2,
    }
}

// MARK: - 选同音词（polish/spelling.rs）

/// 载入读音表（pypinyin 的字音 JSON、cmudict.dict 的路径），只载一次。成功 1，失败 0。
#[no_mangle]
pub unsafe extern "C" fn wotype_polish_spelling_load(readings: *const c_char, dictionary: *const c_char) -> c_int {
    let (Ok(r), Ok(d)) = (std::fs::read_to_string(text(readings)), std::fs::read_to_string(text(dictionary))) else {
        return 0;
    };
    polish::spelling::load(&r, &d) as c_int
}

/// 上下文按 Arion 的键名放进去，空的不放。
unsafe fn spelling_context(
    screen: *const c_char,
    before: *const c_char,
    after: *const c_char,
    history: *const c_char,
    terms: *const c_char,
) -> std::collections::BTreeMap<String, String> {
    [("Screen", screen), ("Before", before), ("After", after), ("History", history), ("Terms", terms)]
        .into_iter()
        .map(|(k, v)| (k.to_string(), text(v).to_string()))
        .filter(|(_, v)| !v.is_empty())
        .collect()
}

/// 列候选。写出 JSON：{"text":"<给模型的那条用户消息>","hypotheses":[{"id":"e0","status":"unique"},…]}；
/// 读音表没载入时写出空串。compounds 为 1 时英文按字母拼起来也算（润色用），0 是 Arion 例子用的 Prepare。
#[no_mangle]
pub unsafe extern "C" fn wotype_polish_spelling_prepare(
    source: *const c_char,
    scene: *const c_char,
    compounds: c_int,
    screen: *const c_char,
    before: *const c_char,
    after: *const c_char,
    history: *const c_char,
    terms: *const c_char,
    out: *mut c_char,
    capacity: usize,
) -> usize {
    let Some(lexicon) = polish::spelling::lexicon() else { return write("", out, capacity) };
    let context = spelling_context(screen, before, after, history, terms);
    let p = lexicon.prepare(text(source), context, text(scene), compounds != 0);
    let hypotheses = p
        .hypotheses
        .iter()
        .map(|h| format!("{{\"id\":{},\"status\":{}}}", polish::spelling::json_string(&h.id), polish::spelling::json_string(&h.status)))
        .collect::<Vec<_>>()
        .join(",");
    let json = format!(
        "{{\"text\":{},\"hypotheses\":[{}]}}",
        polish::spelling::json_string(&polish::spelling::selection_text(&p)),
        hypotheses
    );
    write(&json, out, capacity)
}

/// 按模型的选择替换。参数和 prepare 一样（重新列一遍候选，结果相同），choices 是一行一个「id<TAB>keep|replace」。
/// 选择不完整、不合规矩时返回 usize::MAX（不写）。
#[no_mangle]
pub unsafe extern "C" fn wotype_polish_spelling_apply(
    source: *const c_char,
    scene: *const c_char,
    compounds: c_int,
    screen: *const c_char,
    before: *const c_char,
    after: *const c_char,
    history: *const c_char,
    terms: *const c_char,
    choices: *const c_char,
    out: *mut c_char,
    capacity: usize,
) -> usize {
    let Some(lexicon) = polish::spelling::lexicon() else { return usize::MAX };
    let context = spelling_context(screen, before, after, history, terms);
    let p = lexicon.prepare(text(source), context, text(scene), compounds != 0);
    let choices = text(choices)
        .lines()
        .filter_map(|line| line.split_once('\t'))
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect();
    match polish::spelling::apply_choices(&p, &choices) {
        Some(result) => write(&result, out, capacity),
        None => usize::MAX,
    }
}

// MARK: - 改错学习（polish/learning.rs）

/// 分词回调：把 text 的词范围（按 Unicode 字符的开始、结束，一对一对）写进 spans（最多 capacity 个数），
/// 返回写了几个词；分不了返回 -1。
pub type WotypeSegmenter = unsafe extern "C" fn(text: *const c_char, spans: *mut u32, capacity: usize) -> isize;

/// 用户改了插入的文字后，找出改了哪些词。写出第一行是结论（learned、unchanged、outside……），
/// 后面一行一对「错误写法<TAB>正确写法」。
#[no_mangle]
pub unsafe extern "C" fn wotype_polish_learn(
    inserted: *const c_char,
    baseline: *const c_char,
    settled: *const c_char,
    segmenter: Option<WotypeSegmenter>,
    out: *mut c_char,
    capacity: usize,
) -> usize {
    let segment = |s: &str| -> Option<Vec<polish::learning::WordSpan>> {
        let callback = segmenter?;
        let c = std::ffi::CString::new(s).ok()?;
        let mut spans = vec![0u32; s.chars().count() * 2 + 2];
        let n = callback(c.as_ptr(), spans.as_mut_ptr(), spans.len());
        if n < 0 || n as usize * 2 > spans.len() {
            return None;
        }
        Some(
            spans[..n as usize * 2]
                .chunks(2)
                .map(|p| polish::learning::WordSpan { start: p[0] as usize, end: p[1] as usize })
                .collect(),
        )
    };
    let edit = polish::learning::FieldEdit { inserted: text(inserted), baseline: text(baseline), settled: text(settled) };
    let (verdict, pairs) = polish::learning::extract_corrections(&edit, Some(&segment));
    let mut result = verdict.name().to_string();
    for (from, to) in pairs {
        result.push('\n');
        result.push_str(&from);
        result.push('\t');
        result.push_str(&to);
    }
    write(&result, out, capacity)
}
