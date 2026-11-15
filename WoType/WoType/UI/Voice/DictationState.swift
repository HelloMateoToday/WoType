//
//  DictationState.swift
//  WoType
//
//  移植自 Arion apps/desktop/ui/entities/dictation/dictation.go@d2108fe（AGPL-3.0-only）：
//  浮窗的阶段（PhaseOf）、结果停留多久、失败提示、结果的说法（OutcomeLabel）、显示哪段文字（Text）。
//  Arion 的 runtime.Dictation 换成这里的 DictationState（只留浮窗用到的字段）；
//  文案用 Arion 的简体中文文案（ui/shared/copy/locales/zh-CN.json），提到 Arion 的地方换成 WoType。
//

import Foundation

/// 一次语音的状态（Arion 的 domain.SessionState）。
enum SessionState: Equatable {
    case idle
    /// 麦克风在打开
    case preparing
    /// 在录音
    case capturing
    /// 录完了，在识别（rewriting：在润色）
    case finalizing
    /// 最终文字定了，还没插入
    case reviewing
    case committing
    case completed
    case failed
    case cancelled
}

/// 浮窗看到的那部分状态（Arion 的 runtime.Dictation）。
struct DictationState {
    var state = SessionState.idle
    /// 进入这个状态的时间
    var changed = Date.distantPast
    var sessionID = ""
    /// 说话时的草稿
    var draft = ""
    /// 最终文字（有了就显示它）
    var final = ""
    var rewriting = false
    /// 最近的音量（0~1，每 20 ms 一个，最多 48 个）
    var levels: [Float] = []
    /// 完成时怎么说（「已插入」「已复制」）
    var outcome = DictationCopy.inserted
    /// 失败的原因（completed 但有 failure 也算失败）
    var failure: Notice?
    /// 语音键还按着（提示说「松开结束」还是「结束听写」）
    var holding = false
    /// 键帽上的字
    var keyLegend = "fn"
    /// 云端润色失败、改用本机整理的文字时的提示（结果之后显示，Arion 的 PolishNote）；
    /// 云端识别失败、改用本机识别时也用它（docs/21）
    var polishNote: Notice?

    static let levelHistory = 48

    var isActive: Bool {
        switch state {
        case .preparing, .capturing, .finalizing, .reviewing, .committing: true
        default: false
        }
    }
}

/// 失败的说明：标题和下一步怎么做。
struct Notice: Equatable {
    var title: String
    var hint: String?
}

/// 浮窗的样子（Arion 的 dictation.Phase）。
enum DictationPhase: Equatable {
    case hidden
    case preparing
    case listening
    case transcribing
    /// 润色在整理文字
    case polishing
    /// 最终文字定了，插入前
    case reviewing
    case inserting
    case done
    /// 结果之后：云端润色没成功的提示
    case note
    case failed
    case cancelled
}

enum Dictation {
    /// 结果停多久再收起
    static let doneVisible: TimeInterval = 1.1
    static let failedVisible: TimeInterval = 3.6
    static let cancelledVisible: TimeInterval = 0.7
    /// 云端提示在结果之后停多久（dictation.go 的 PolishNoteVisible）
    static let noteVisible: TimeInterval = 3.2

    /// now 时浮窗的样子。
    static func phase(_ d: DictationState, at now: Date) -> DictationPhase {
        let since = now.timeIntervalSince(d.changed)
        switch d.state {
        case .preparing: return .preparing
        case .capturing: return .listening
        case .finalizing: return d.rewriting ? .polishing : .transcribing
        case .reviewing: return .reviewing
        case .committing: return .inserting
        case .completed:
            if d.failure != nil { return since < failedVisible ? .failed : .hidden }
            if since < doneVisible { return .done }
            return d.polishNote != nil && since < doneVisible + noteVisible ? .note : .hidden
        case .failed: return since < failedVisible ? .failed : .hidden
        case .cancelled: return since < cancelledVisible ? .cancelled : .hidden
        case .idle: return .hidden
        }
    }

    /// 结果还要停多久（安排下一帧）。
    static func remaining(_ d: DictationState, at now: Date) -> TimeInterval {
        var visible: TimeInterval
        switch d.state {
        case .completed:
            visible = d.failure != nil ? failedVisible : doneVisible + (d.polishNote != nil ? noteVisible : 0)
        case .failed: visible = failedVisible
        case .cancelled: visible = cancelledVisible
        default: return 0
        }
        visible -= now.timeIntervalSince(d.changed)
        return max(visible, 0)
    }

    /// 说话时浮窗显示的文字：有最终文字就用它，否则用草稿。
    static func text(_ d: DictationState) -> String {
        d.final.isEmpty ? d.draft : d.final
    }
}

/// Arion 的简体中文文案（只留语音浮窗用到的）。
enum DictationCopy {
    static let listening = "正在聆听…"
    static let transcribing = "正在转写…"
    static let inserted = "已插入"
    static let copied = "已复制"
    static let cancelled = "已取消"
    static let learned = "已记住"
    static let undo = "撤销"
    static let releaseHint = "松开结束"
    static let finishHint = "结束听写"

    static let micDenied = Notice(title: "需要麦克风权限", hint: "请在「系统设置 › 隐私与安全性 › 麦克风」里打开 WoType")
    static let modelMissing = Notice(title: "语音模型尚未就绪", hint: "请在设置 › 语音输入中下载")
    static let discontinuity = Notice(title: "麦克风已停止", hint: "输入设备已变更或断开")
    static let device = Notice(title: "麦克风不可用", hint: "请在设置中选择其他输入设备")
    static let targetChanged = Notice(title: "焦点已移动，未插入文字", hint: "文字已复制，可以直接粘贴")
    static let secure = Notice(title: "无法在密码框中听写", hint: "WoType 不会在安全输入框中录音")
    static let noSpeech = Notice(title: "未检测到语音", hint: "请在设置中检查麦克风音量")
    static let busy = Notice(title: "仍在转写中", hint: nil)
    static let generic = Notice(title: "听写已停止", hint: nil)
}
