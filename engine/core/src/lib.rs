//! WoType 的 Rust 核心：语音输入的润色规则（polish），并链进水杉输入法的宿主层。
//!
//! 拼音有两个引擎可以切换：水杉（msime-host-api，docs/12）和万象（librime + 万象方案，docs/22，在 Swift 那边）。
//! 水杉和这里编进同一个静态库：一个进程只能链接一个 Rust 静态库。
//!
//! 旧的万象引擎（docs/15）代码还在，只在 `--features wanxiang` 时编译：模块见下面，本体在 engine.rs。

// 本库不直接调用它，引用一下才会被链进静态库，msime_client_* 由 Swift 调用
extern crate msime_host_api;

pub mod polish;
pub mod polish_ffi;

#[cfg(feature = "wanxiang")]
mod engine;
#[cfg(feature = "wanxiang")]
pub use engine::*;
#[cfg(feature = "wanxiang")]
mod english;
#[cfg(feature = "wanxiang")]
mod mixed;
#[cfg(feature = "wanxiang")]
pub mod beam;
#[cfg(feature = "wanxiang")]
pub mod convert;
#[cfg(feature = "wanxiang")]
pub mod emoji;
#[cfg(feature = "wanxiang")]
pub mod ffi;
#[cfg(feature = "wanxiang")]
pub mod gram;
#[cfg(feature = "wanxiang")]
pub mod graph;
#[cfg(feature = "wanxiang")]
pub mod learn;
#[cfg(feature = "wanxiang")]
pub mod lexicon;
#[cfg(feature = "wanxiang")]
pub mod lm;
#[cfg(feature = "wanxiang")]
pub mod nnlm;
#[cfg(feature = "wanxiang")]
pub mod preedit;
#[cfg(feature = "wanxiang")]
pub mod rank;
#[cfg(feature = "wanxiang")]
pub mod session;
#[cfg(feature = "wanxiang")]
pub mod session_ffi;
#[cfg(feature = "wanxiang")]
pub mod shuangpin;
#[cfg(feature = "wanxiang")]
pub mod syllable;
#[cfg(feature = "wanxiang")]
pub mod symbols;
#[cfg(feature = "wanxiang")]
pub mod train;
#[cfg(feature = "wanxiang")]
pub mod wanxiang;
#[cfg(feature = "wanxiang")]
pub mod wordlm;
