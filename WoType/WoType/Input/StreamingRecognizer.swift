//
//  StreamingRecognizer.swift
//  WoType
//
//  移植自 Arion apps/desktop/infrastructure/asr/recognizer.go（Streaming、session）和 segments.go，
//  以及 packages/core/domain/correction.go 的 JoinText@d2108fe（AGPL-3.0-only），Go 翻成 Swift。
//  Arion 的 goroutine + channel 换成主线程上的 Task；识别请求走 VoiceService.decode。
//
//  说话时的分段识别：不是真正的流式模型，而是在后台安排有长度上限的整段识别（Qwen 是整段识别的模型）。
//  - 每多 1 秒新声音，把还没定下来的那段识别一遍当草稿（可被下一次替换）；
//  - 音量低于 -42 dBFS 持续 800 ms 算一次停顿，停顿的正中间切开，前面那段识别后定稿，以后不再识别；
//  - 一段最长 20 秒，超过就在后三分之一里最安静的地方切；
//  - 结束时取消还在跑的草稿，把没定稿的声音全部识别（超过 25 秒再切），开头和结尾都不丢。
//

import Foundation

/// 声音的小工具（segments.go）。
enum VoicePCM {
    /// -42 dBFS 的 RMS。断句和「整段没人说话」的判断用同一个门限
    static let speechFloor: Float = 0.008

    /// 有没有一个 20 ms 的片段到了说话门限。比 20 ms 短的算一段。
    /// 非有限数是坏数据，不是安静：Qwen3 识别安静的声音时会把系统提示里的热词念出来。
    static func classify(_ samples: [Float]) -> (speech: Bool, invalid: Bool) {
        let window = 16_000 / 50
        guard !samples.isEmpty else { return (false, false) }
        let step = min(window, samples.count)
        var speech = false
        var start = 0
        while start < samples.count {
            let end = min(start + step, samples.count)
            var energy: Double = 0
            for sample in samples[start..<end] {
                if !sample.isFinite { return (false, true) }
                energy += Double(sample) * Double(sample)
            }
            if (energy / Double(end - start)).squareRoot() >= Double(speechFloor) { speech = true }
            start = end
        }
        return (speech, false)
    }

    /// 把声音切成每段不超过 limit 秒，切在每段后三分之一里能量最低的那个 20 ms 窗口中间。
    static func splitAtQuiet(_ samples: [Float], rate: Int, limit: Int) -> [[Float]] {
        let window = rate / 50
        let max = rate * limit
        var rest = samples[...]
        var out: [[Float]] = []
        while rest.count > max {
            let base = rest.startIndex
            var best = max
            var bestEnergy: Float = -1
            var start = max * 2 / 3
            while start + window <= max {
                var energy: Float = 0
                for s in rest[(base + start)..<(base + start + window)] { energy += s * s }
                if bestEnergy < 0 || energy < bestEnergy {
                    best = start + window / 2
                    bestEnergy = energy
                }
                start += window
            }
            out.append(Array(rest[base..<(base + best)]))
            rest = rest[(base + best)...]
        }
        if !rest.isEmpty { out.append(Array(rest)) }
        return out
    }

    /// 拼几段识别结果：两边都不是汉字（等）、前面也不是空白时中间加一个空格（correction.go JoinText）。
    static func joinText(_ parts: [String]) -> String {
        var out = ""
        for raw in parts {
            let part = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if part.isEmpty { continue }
            if let last = out.unicodeScalars.last, let first = part.unicodeScalars.first,
               !isCJKText(last), !isCJKText(first), !last.properties.isWhitespace {
                out.append(" ")
            }
            out.append(part)
        }
        return out
    }

    /// 汉字、假名、谚文和全角标点（correction.go IsCJK）。
    nonisolated static func isCJKText(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x2E80...0x2FDF, 0x3005...0x3007, 0x3021...0x3029, 0x3038...0x303B, 0x3400...0x4DBF,
             0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x3134F:  // 汉字
            true
        case 0x3040...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F:  // 假名
            true
        case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF:  // 谚文
            true
        case 0x3000...0x303F, 0xFF00...0xFFEF:  // 全角标点
            true
        default:
            false
        }
    }

    static func int16Data(_ samples: [Float]) -> Data {
        var data = Data(count: samples.count * 2)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for (i, s) in samples.enumerated() {
                out[i] = Int16(max(-1, min(1, s)) * 32767).littleEndian
            }
        }
        return data
    }
}

@MainActor
final class StreamingRecognizer {

    let rate = 16_000
    /// 停顿多久算一段结束（Arion 模型清单里 endpointSilenceMs 800）
    let silence = Int(0.8 * 16_000)
    let hotwords: [String]

    /// 草稿变了（revision 加一）时调
    var onRevision: (() -> Void)?

    private var samples: [Float] = []
    private var segments: [String] = []
    private var tail = ""
    private var decoded = 0
    private var scheduled = 0
    private(set) var revision: UInt64 = 0
    private var failure: Error?
    private var closed = false
    private var finishing = false
    private var quiet = 0
    private var speech = false
    private var endpoints: [Int] = []
    /// 后台的草稿识别（Arion 的 preview goroutine）
    private var previewTask: Task<Void, Never>?
    private var wakePending = false

    init(hotwords: [String] = []) {
        self.hotwords = hotwords
    }

    /// 收一帧声音（20 ms）。
    func accept(_ frame: [Float]) throws {
        if closed || finishing { throw VoiceService.Failure.rejected }
        if let failure { throw failure }
        samples.append(contentsOf: frame)
        var energy: Double = 0
        for sample in frame { energy += Double(sample) * Double(sample) }
        // -42 dBFS RMS 加 800 ms 安静界定一段，开头和结尾的声音都不丢；真正的切点在停顿的正中间
        if !frame.isEmpty && (energy / Double(frame.count)).squareRoot() >= Double(VoicePCM.speechFloor) {
            speech = true
            quiet = 0
        } else {
            quiet += frame.count
            if speech && quiet >= silence {
                endpoints.append(samples.count - quiet / 2)
                speech = false
                wake()
            }
        }
        // 每多 1 秒新声音安排一次可替换的草稿识别
        if samples.count - scheduled >= rate {
            scheduled = samples.count
            wake()
        }
    }

    private func wake() {
        wakePending = true
        if previewTask == nil {
            previewTask = Task { await self.preview() }
        }
    }

    private func preview() async {
        defer { previewTask = nil }
        while wakePending {
            wakePending = false
            if finishing || closed || Task.isCancelled { return }
            var n = samples.count
            let commit = n > rate * 20 || !endpoints.isEmpty
            if let first = endpoints.first {
                n = first
            } else if commit {
                n = VoicePCM.splitAtQuiet(samples, rate: rate, limit: 20)[0].count
            }
            let piece = Array(samples[0..<n])
            let text: String
            do {
                text = try await VoiceService.shared.decode(piece, hotwords: hotwords)
            } catch {
                if Task.isCancelled || error is CancellationError || finishing || closed { return }
                failure = error
                return
            }
            if Task.isCancelled || finishing || closed { return }
            if commit {
                // 安静的一段没有结果。不要关一个空段
                if !text.isEmpty { segments.append(text) }
                endpoints = endpoints.compactMap { $0 > n ? $0 - n : nil }
                samples = Array(samples[n...])
                decoded = 0
                scheduled = 0
                tail = ""
                if samples.count >= rate { wakePending = true }
            } else {
                tail = text
                decoded = n
            }
            revision += 1
            onRevision?()
        }
    }

    /// 现在的草稿：定稿的几段加上还在变的尾巴。
    var partial: String { VoicePCM.joinText(segments + [tail]) }

    var error: Error? { failure }

    /// 结束：取消过时的草稿识别，把所有没定稿的声音识别完。
    func finish() async throws -> String {
        if closed { throw VoiceService.Failure.rejected }
        finishing = true
        if let previewTask {
            previewTask.cancel()
            await previewTask.value
        }
        if let failure { throw failure }
        if decoded != samples.count {
            tail = try await Self.decodeAll(samples, hotwords: hotwords)
        }
        revision += 1
        return partial
    }

    /// 一整段声音在本机识别完（超过 25 秒切开）。云端识别失败时也用它重新识别整段录音（docs/21）。
    static func decodeAll(_ samples: [Float], hotwords: [String]) async throws -> String {
        var parts: [String] = []
        for piece in VoicePCM.splitAtQuiet(samples, rate: 16_000, limit: 25) {
            parts.append(try await VoiceService.shared.decode(piece, hotwords: hotwords))
        }
        return VoicePCM.joinText(parts)
    }

    func close() {
        previewTask?.cancel()
        closed = true
        samples = []
    }
}
