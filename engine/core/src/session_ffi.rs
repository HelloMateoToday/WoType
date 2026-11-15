//! 输入会话的 C ABI（见 `session.rs`）。
//!
//! 每个输入框一个会话句柄；引擎句柄每次调用都传进来，还没载入好时传 NULL。
//! 快照字符串归会话所有，下一次调用这个会话的任何函数前有效。

// 安全契约见 core/include/wotype_core.h：空指针、句柄生命周期由调用方保证。
#![allow(clippy::missing_safety_doc)]

use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int};
use std::path::PathBuf;

use crate::ffi::WotypeEngineHandle;
use crate::session::{self, Key, Session, SessionConfig};
use crate::Engine;

/// 会话句柄。
pub struct WotypeSession {
    session: Session,
    snapshot: CString,
}

// 特殊键（和 wotype_core.h 的 WOTYPE_KEY_* 一致）；可打印字符直接用码点
const KEY_BACKSPACE: u32 = 0x1000;
const KEY_RETURN: u32 = 0x1001;
const KEY_ESCAPE: u32 = 0x1002;
const KEY_TAB: u32 = 0x1003;
const KEY_DELETE: u32 = 0x1004;
const KEY_LEFT: u32 = 0x1005;
const KEY_RIGHT: u32 = 0x1006;
const KEY_UP: u32 = 0x1007;
const KEY_DOWN: u32 = 0x1008;
const KEY_PAGE_UP: u32 = 0x1009;
const KEY_PAGE_DOWN: u32 = 0x100A;
const KEY_HOME: u32 = 0x100B;
const KEY_END: u32 = 0x100C;

fn key_from_code(code: u32) -> Option<Key> {
    Some(match code {
        KEY_BACKSPACE => Key::Backspace,
        KEY_RETURN => Key::Return,
        KEY_ESCAPE => Key::Escape,
        KEY_TAB => Key::Tab,
        KEY_DELETE => Key::Delete,
        KEY_LEFT => Key::Left,
        KEY_RIGHT => Key::Right,
        KEY_UP => Key::Up,
        KEY_DOWN => Key::Down,
        KEY_PAGE_UP => Key::PageUp,
        KEY_PAGE_DOWN => Key::PageDown,
        KEY_HOME => Key::Home,
        KEY_END => Key::End,
        0x20 => Key::Space,
        _ => Key::Char(char::from_u32(code).filter(|c| !c.is_control())?),
    })
}

unsafe fn engine_ref<'a>(engine: *const WotypeEngineHandle) -> Option<&'a Engine> {
    unsafe { engine.as_ref() }.map(WotypeEngineHandle::engine)
}

/// 新建会话。
#[no_mangle]
pub extern "C" fn wotype_session_new() -> *mut WotypeSession {
    Box::into_raw(Box::new(WotypeSession {
        session: Session::new(),
        snapshot: CString::default(),
    }))
}

/// 释放会话。
#[no_mangle]
pub unsafe extern "C" fn wotype_session_free(session: *mut WotypeSession) {
    if !session.is_null() {
        drop(unsafe { Box::from_raw(session) });
    }
}

/// 处理一个按键，返回 1 表示吃掉了，0 表示交还给应用。
#[no_mangle]
pub unsafe extern "C" fn wotype_session_key(
    session: *mut WotypeSession,
    engine: *const WotypeEngineHandle,
    key: u32,
    modifiers: u32,
) -> c_int {
    let (Some(handle), Some(key)) = (unsafe { session.as_mut() }, key_from_code(key)) else {
        return 0;
    };
    handle
        .session
        .key(unsafe { engine_ref(engine) }, key, modifiers) as c_int
}

/// 鼠标点了当前显示的第 index 个候选。返回 1 表示选上了。
#[no_mangle]
pub unsafe extern "C" fn wotype_session_select(
    session: *mut WotypeSession,
    engine: *const WotypeEngineHandle,
    index: usize,
) -> c_int {
    let Some(handle) = (unsafe { session.as_mut() }) else {
        return 0;
    };
    handle.session.select(unsafe { engine_ref(engine) }, index) as c_int
}

/// 翻页：delta < 0 上一页，> 0 下一页。返回 1 表示翻了。
#[no_mangle]
pub unsafe extern "C" fn wotype_session_page(session: *mut WotypeSession, delta: c_int) -> c_int {
    let Some(handle) = (unsafe { session.as_mut() }) else {
        return 0;
    };
    handle.session.page(delta) as c_int
}

/// 展开或收起网格（候选窗右边的 ∨ / ∧）。返回 1 表示变了。
#[no_mangle]
pub unsafe extern "C" fn wotype_session_toggle_grid(session: *mut WotypeSession) -> c_int {
    let Some(handle) = (unsafe { session.as_mut() }) else {
        return 0;
    };
    handle.session.toggle_grid() as c_int
}

/// 光标前的文字（应用里真实的上下文）；NULL 表示清空。
#[no_mangle]
pub unsafe extern "C" fn wotype_session_set_context(
    session: *mut WotypeSession,
    text: *const c_char,
) {
    let Some(handle) = (unsafe { session.as_mut() }) else {
        return;
    };
    let text = if text.is_null() {
        ""
    } else {
        unsafe { CStr::from_ptr(text) }.to_str().unwrap_or("")
    };
    handle.session.set_context(text);
}

/// 失去焦点或切走：commit_pending 非 0 时把已选的词和原始字母放进下一次快照的上屏文字。
#[no_mangle]
pub unsafe extern "C" fn wotype_session_reset(
    session: *mut WotypeSession,
    engine: *const WotypeEngineHandle,
    commit_pending: c_int,
) {
    let Some(handle) = (unsafe { session.as_mut() }) else {
        return;
    };
    handle
        .session
        .reset(unsafe { engine_ref(engine) }, commit_pending != 0);
}

/// 打开或关闭表情面板。
#[no_mangle]
pub unsafe extern "C" fn wotype_session_toggle_emoji(
    session: *mut WotypeSession,
    engine: *const WotypeEngineHandle,
) {
    let Some(handle) = (unsafe { session.as_mut() }) else {
        return;
    };
    handle.session.toggle_emoji(unsafe { engine_ref(engine) });
}

/// 当前状态的 JSON 快照（顺带取走要上屏的文字）。handled 原样写进快照。
#[no_mangle]
pub unsafe extern "C" fn wotype_session_snapshot(
    session: *mut WotypeSession,
    handled: c_int,
) -> *const c_char {
    let Some(handle) = (unsafe { session.as_mut() }) else {
        return std::ptr::null();
    };
    handle.snapshot = CString::new(handle.session.snapshot(handled != 0)).unwrap_or_default();
    handle.snapshot.as_ptr()
}

/// 所有会话共用的设置：每页个数（3–9）、是否推荐 emoji、数字后的 . : 是否原样输出，
/// 其余开关按位放在 options 里（`WOTYPE_OPT_*`）。
#[no_mangle]
pub extern "C" fn wotype_session_configure(
    page_size: u32,
    emoji_suggest: c_int,
    ascii_punct_after_digit: c_int,
    options: u32,
) {
    session::configure(SessionConfig {
        page_size: page_size as usize,
        // 一行的宽度单独设（wotype_session_set_row_width），这里保留原值
        row_width: session::config().row_width,
        emoji_suggest: emoji_suggest != 0,
        ascii_punct_after_digit: ascii_punct_after_digit != 0,
        url_punct: options & OPT_URL_PUNCT != 0,
        slash_dunhao: options & OPT_SLASH_DUNHAO != 0,
        auto_pair: options & OPT_AUTO_PAIR != 0,
        space_cjk_latin: options & OPT_SPACE_CJK_LATIN != 0,
        space_cjk_digit: options & OPT_SPACE_CJK_DIGIT != 0,
        v_number: options & OPT_V_NUMBER != 0,
    });
}

/// 一行能放多宽（单位：候选字号的 1/100）；给了就按宽度分页，最多 9 个。0 表示按每页个数。
#[no_mangle]
pub extern "C" fn wotype_session_set_row_width(width: u32) {
    session::configure(SessionConfig {
        row_width: width,
        ..session::config()
    });
}

/// 展开时一个候选占几列：前端按候选窗真实的字宽量（文字 -> 1～6 列）。NULL 取消，改按估的字宽算。
/// 回调在调会话函数的那个线程里调用。
#[no_mangle]
pub extern "C" fn wotype_session_set_grid_span(span: Option<extern "C" fn(*const c_char) -> u32>) {
    session::set_grid_span(span.map(|f| {
        Box::new(move |text: &str| {
            let text = CString::new(text).unwrap_or_default();
            f(text.as_ptr()) as usize
        }) as session::GridSpan
    }));
}

/// 日期、时间候选的各种格式（照微信输入法：riqi / rq、shijian / sj 时出一个带日历图标的候选）。
/// 前端按本地时区、农历排好：kind 0 是日期、1 是时间，每行一种写进 buf（UTF-8，最多 len 字节，
/// 不用带结尾的 0），返回写了多少字节。NULL 取消，不再出日期时间候选。回调在调会话函数的线程里调用。
#[no_mangle]
pub extern "C" fn wotype_session_set_date_formats(
    formats: Option<extern "C" fn(u32, *mut c_char, usize) -> usize>,
) {
    session::set_date_formats(formats.map(|f| {
        Box::new(move |kind: session::DateKind| {
            let mut buf = vec![0u8; 2048];
            let written = f(kind as u32, buf.as_mut_ptr().cast(), buf.len()).min(buf.len());
            String::from_utf8_lossy(&buf[..written])
                .lines()
                .filter(|line| !line.is_empty())
                .map(str::to_string)
                .collect()
        }) as session::DateFormats
    }));
}

/// `wotype_session_configure` 的 options 各位，和 wotype_core.h 里的 WOTYPE_OPT_* 一致。
const OPT_URL_PUNCT: u32 = 1;
const OPT_SLASH_DUNHAO: u32 = 2;
const OPT_AUTO_PAIR: u32 = 4;
const OPT_SPACE_CJK_LATIN: u32 = 8;
const OPT_SPACE_CJK_DIGIT: u32 = 16;
const OPT_V_NUMBER: u32 = 32;

/// 记住的邮箱后缀存在哪个文件（上屏过的、不在内置表里的后缀，只存 @ 后面的部分）；NULL 表示不记。
#[no_mangle]
pub unsafe extern "C" fn wotype_session_set_mail_domains_path(path: *const c_char) {
    session::set_mail_domains_path(unsafe { optional_path(path) });
}

/// C 字符串转路径：NULL 或空串是 None。
unsafe fn optional_path(path: *const c_char) -> Option<PathBuf> {
    if path.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(path) }
        .to_str()
        .ok()
        .filter(|p| !p.is_empty())
        .map(PathBuf::from)
}

/// 最近用过的 emoji 存在哪个文件；NULL 表示不存。
#[no_mangle]
pub unsafe extern "C" fn wotype_session_set_recent_emoji_path(path: *const c_char) {
    session::set_recent_emoji_path(unsafe { optional_path(path) });
}
