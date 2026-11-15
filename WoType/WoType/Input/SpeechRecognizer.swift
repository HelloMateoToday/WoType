//
//  SpeechRecognizer.swift
//  WoType
//
//  一次听写的识别器（docs/21）：VoiceController 只用这几个动作，本机（StreamingRecognizer）、
//  体验渠道（TrialRecognizers/）和以后的云端官方接口各自实现。
//

import Foundation

@MainActor
protocol SpeechRecognizer: AnyObject {
    /// 草稿变了时调
    var onRevision: (() -> Void)? { get set }
    /// 现在的草稿
    var partial: String { get }
    /// 云端识别时留着的整段录音：失败了用它改走本机识别。本机识别是 nil
    var recording: [Float]? { get }
    /// 收一帧声音（20 ms、16 kHz 单声道）
    func accept(_ frame: [Float]) throws
    /// 结束：等最终文字
    func finish() async throws -> String
    func close()
}

extension StreamingRecognizer: SpeechRecognizer {
    var recording: [Float]? { nil }
}

/// 识别方式（Config.voiceRecognizer）：本机、添加的某个云端识别（CloudSpeechModel 的 id），或某个体验渠道。
/// 存成字符串（local、cloud.<id>、trial.qwen），认不得的（比如以后删掉的渠道）读成本机。
nonisolated enum VoiceRecognizer: Equatable, Codable, Sendable {
    case local
    case cloud(String)
    case trial(TrialChannel)

    var name: String {
        switch self {
        case .local: "local"
        case .cloud(let id): "cloud." + id
        case .trial(let channel): "trial." + channel.rawValue
        }
    }

    init(name: String) {
        if name.hasPrefix("trial."), let channel = TrialChannel(rawValue: String(name.dropFirst("trial.".count))) {
            self = .trial(channel)
        } else if name.hasPrefix("cloud."), name.count > "cloud.".count {
            self = .cloud(String(name.dropFirst("cloud.".count)))
        } else {
            self = .local
        }
    }

    init(from decoder: Decoder) throws {
        self.init(name: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(name)
    }
}
