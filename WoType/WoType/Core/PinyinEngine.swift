//
//  PinyinEngine.swift
//  WoType
//
//  拼音引擎的接口：水杉（MsimeHost / MsimeSession，默认）和万象（RimeEngine / RimeSession，librime，docs/22）可以切换（docs/15）。
//  InputController、设置、启动只认这里的协议，不直接碰某个引擎；两边都返回 Snapshot。
//  每个引擎的逻辑都在它自己的文件里，这里只做转接。
//

import Foundation
import os

/// 一次输入的会话：按键交进去，快照拿出来。只在主线程用。
protocol PinyinSession: AnyObject {
    /// 处理一个按键。preceding：空编辑区打标点时光标前那个字（数字后的 . : 原样输出），没有是 0
    func key(_ key: UInt32, modifiers: UInt32, preceding: UInt32) -> Snapshot?
    /// 点了候选窗里的第 index 个
    func select(_ index: Int) -> Snapshot?
    /// 展开或收起候选（候选窗右边的 ∨ / ∧）
    func toggleGrid() -> Snapshot?
    /// 展开时滚动几行（触控板、滚轮）
    func scrollGrid(_ rows: Int) -> Snapshot?
    /// 结束组字。commitPending：已选的词和原始字母上屏；false 时全丢掉
    func reset(commitPending: Bool) -> Snapshot?
    /// 输入框拿到、失去焦点
    func setFocused(_ focused: Bool)
    /// 撤掉组字，上屏给定的文字（候选翻译的译文）
    func commitText(_ text: String) -> Snapshot?
    /// 已输入的字母原样上屏（打到一半切英文）
    func commitRaw() -> Snapshot?
    /// 两次上屏之间要不要补空格（中英文、数字之间），返回补好的文字
    func spacedCommit(_ text: String, preceding: UInt32, application: String) -> String
    /// 要不要在新输入开头读光标前的文字当上文（万象用它排序、补空格）
    var wantsContext: Bool { get }
    /// 光标前的文字，只对紧接着的那一次按键有效
    func setContext(_ text: String)
}

extension PinyinSession {
    var wantsContext: Bool { false }
    func setContext(_ text: String) {}
}

/// 一个拼音引擎：准备数据、给出会话。
protocol PinyinEngine: AnyObject {
    /// 后台准备（载入词库、模型），好了以前 session(idle:) 返回 nil，按键交给应用
    func prepare()
    /// 设置改了：交给引擎的那几项变了就重新准备
    func settingsChanged(_ config: Config)
    /// 切到另一个引擎：放掉占的东西（万象放掉几百 MB 的词库；水杉的会话很轻，留着）
    func stop()
    /// 现在开着的会话（失去焦点、切英文时用，不新建）
    var openSession: PinyinSession? { get }
    /// 按键用的会话；还没准备好时为 nil。idle：现在没有组字，要重建会话只在这时重建
    func session(idle: Bool) -> PinyinSession?
    /// 引擎自己更新了候选（不是按键引起的，比如停顿后重排）：交给当前的输入框
    var onSettled: ((Snapshot) -> Void)? { get set }
}

enum PinyinEngines {
    /// 当前的拼音引擎（设置里的 pinyinEngine，默认水杉）
    static var current: PinyinEngine { engine(Settings.shared.config.pinyinEngine) }

    static func engine(_ name: String) -> PinyinEngine {
        name == "wanxiang" ? RimeEngine.shared : MsimeHost.shared
    }

    static var all: [PinyinEngine] { [MsimeHost.shared, RimeEngine.shared] }

    /// 设置里换了引擎（Settings.update 调，这时 current 已经是新的）：旧的打了一半的丢掉、停下，新的开始准备。
    /// 输入框下次按键就用新引擎的会话
    static func switched(from previous: String) {
        let old = engine(previous)
        _ = old.openSession?.reset(commitPending: false)
        old.openSession?.setFocused(false)
        old.stop()
        CandidatePanel.shared.hide()
        current.prepare()
        Log.input.info("拼音引擎换成 \(Settings.shared.config.pinyinEngine, privacy: .public)")
    }
}

// MARK: - 水杉

extension MsimeSession: PinyinSession {}

extension MsimeHost: PinyinEngine {
    func prepare() {
        prepareInBackground(again: false)
    }

    func settingsChanged(_ config: Config) {
        prepareInBackground(again: options != nil && preparedSettings != MsimeSettings(config))
    }

    var openSession: PinyinSession? { session }

    func session(idle: Bool) -> PinyinSession? {
        currentSession(idle: idle)
    }

    func stop() {}
}
