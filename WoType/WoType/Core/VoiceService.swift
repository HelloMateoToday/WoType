//
//  VoiceService.swift
//  WoType
//
//  拉起、使用 WoType Voice（App 包里的 Contents/MacOS/wotype-voice）。
//  请求的发法照 Arion apps/desktop/infrastructure/asr/worker.go@d2108fe（AGPL-3.0-only）的 engine.decode：
//  没声音的不送去识别；一次只识别一段（serial）；声音分块发（chunk），再发 transcribe；可以取消。
//  协议见 WoType/VoiceService/Sources/WoTypeVoice/Worker.swift（Arion 的 protocol 3）。
//
//  润色也在这个进程里跑（Arion 用另一个 llama.cpp 进程）：润色请求带着润色模型的目录，第一次用到才载入。
//
//  和 Arion 不同：Arion 的识别进程一直开着；WoType Voice 闲置 5 分钟自己退出，下次要用再拉起
//  （载入 + 热身约 1~2 秒，录音的同时就在载入）。
//

import Foundation
import os

@MainActor
final class VoiceService {

    static let shared = VoiceService()

    enum Failure: LocalizedError {
        case modelMissing
        case unavailable
        case crashed
        case rejected
        case invalidPCM
        case truncated

        var errorDescription: String? {
            switch self {
            case .modelMissing: "语音模型尚未就绪"
            case .unavailable: "这台 Mac 不支持离线语音识别"
            case .crashed: "语音识别程序意外退出"
            case .rejected: "识别失败"
            case .invalidPCM: "声音数据不对"
            case .truncated: "润色结果太长，没写完"
            }
        }
    }

    /// 一块最多多少字节（5 秒）
    static let chunkBytes = 16_000 * 2 * 5

    private enum State {
        case stopped
        case loading
        case ready
    }

    private var state = State.stopped
    private var process: Process?
    private var input: FileHandle?
    private var pending: [String: CheckedContinuation<String, Error>] = [:]
    /// 进程还在载入时先排着，好了再发
    private var queued: [Data] = []
    private var nextID = 0
    /// 一次只识别一段：后来的在这里等
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    nonisolated static var executable: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/wotype-voice")
    }

    /// 识别模型装好了没有（没装好按语音键只提示去下载）。
    nonisolated static var modelReady: Bool { VoiceModels.installedVersion(.asr) != nil }

    /// 按下语音键时调：没在跑就拉起来，开始载入模型。
    func prepare() {
        guard state == .stopped, Self.modelReady else { return }
        start()
    }

    /// 识别一段 16 kHz 单声道的声音。没有一个 20 ms 到说话门限的，不送去识别，直接返回空。
    func decode(_ samples: [Float], hotwords: [String] = []) async throws -> String {
        try Task.checkCancellation()
        let (speech, invalid) = VoicePCM.classify(samples)
        if invalid { throw Failure.invalidPCM }
        // 没声音的不送：Qwen3 会把系统提示里的热词当成识别结果念出来
        if !speech { return "" }
        guard Self.modelReady else { throw Failure.modelMissing }
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        if state == .stopped { start() }
        guard state != .stopped else { throw Failure.unavailable }

        let text = try await complete(samples, prompt: hotwords.joined(separator: " "))
        guard !hotwords.isEmpty, VoiceCorrection.hotwordEcho(text, hotwords: hotwords) else { return text }
        // 念的是热词表（Arion worker.go 的 decode）：同样的声音不带热词再识别一次，只用这次的结果，
        // 有声音的一段不会被整个扔掉，热词表也不会上屏
        Log.engine.info("识别结果是热词表的复读，不带热词重新识别")
        try Task.checkCancellation()
        return try await complete(samples, prompt: "")
    }

    private func complete(_ samples: [Float], prompt: String) async throws -> String {
        nextID += 1
        let id = "v\(nextID)"
        let pcm = VoicePCM.int16Data(samples)
        var seq = 0
        var offset = 0
        while offset < pcm.count {
            let end = min(offset + Self.chunkBytes, pcm.count)
            send(["type": "chunk", "id": id, "seq": seq, "pcm": pcm[offset..<end].base64EncodedString()])
            seq += 1
            offset = end
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                send(["type": "transcribe", "id": id, "sample_rate": 16_000, "prompt": prompt])
            }
        } onCancel: {
            Task { @MainActor in VoiceService.shared.send(["type": "cancel", "id": id]) }
        }
    }

    /// 润色模型装好了没有。
    nonisolated static var polishReady: Bool { VoiceModels.installedVersion(.polish) != nil }

    /// 润色：把对话发给润色模型，返回它的回答。超过 maxTokens 没写完算失败（truncated）。
    /// 和识别不排队：润色在识别全部做完以后才发。
    func polish(messages: [[String: String]], maxTokens: Int) async throws -> String {
        try Task.checkCancellation()
        guard Self.polishReady else { throw Failure.modelMissing }
        if state == .stopped { start() }
        guard state != .stopped else { throw Failure.unavailable }
        nextID += 1
        let id = "p\(nextID)"
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                send(["type": "polish", "id": id, "model": VoiceModelSpec.polish.directory.path,
                      "messages": messages, "max_tokens": maxTokens])
            }
        } onCancel: {
            Task { @MainActor in VoiceService.shared.send(["type": "cancel", "id": id]) }
        }
    }

    /// 开始说话时调：先载入润色模型、把这几条消息（最后一条用户消息之前的部分）算好存着，说完润色时只算说的那段。
    func preparePolish(messages: [[String: String]]) {
        guard Self.polishReady else { return }
        if state == .stopped { start() }
        guard state != .stopped else { return }
        send(["type": "polish_prepare", "id": "prepare", "model": VoiceModelSpec.polish.directory.path, "messages": messages])
    }

    private func acquire() async {
        while busy {
            await withCheckedContinuation { waiters.append($0) }
        }
        busy = true
    }

    private func release() {
        busy = false
        if !waiters.isEmpty { waiters.removeFirst().resume() }
    }

    // MARK: - 进程

    private func start() {
        guard FileManager.default.isExecutableFile(atPath: Self.executable.path) else {
            Log.engine.error("App 包里没有 wotype-voice（Intel Mac 或者没编进来）")
            return
        }
        let process = Process()
        process.executableURL = Self.executable
        process.arguments = ["worker", VoiceModelSpec.asr.directory.path]
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let reader = LineSplitter { line in
            Task { @MainActor in VoiceService.shared.received(line) }
        }
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                reader.append(data)
            }
        }
        process.terminationHandler = { finished in
            let status = finished.terminationStatus
            Task { @MainActor in VoiceService.shared.terminated(finished, status: status) }
        }
        do {
            try process.run()
        } catch {
            Log.engine.error("拉起 wotype-voice 失败：\(error.localizedDescription, privacy: .public)")
            return
        }
        self.process = process
        input = stdin.fileHandleForWriting
        state = .loading
        Log.engine.info("拉起 wotype-voice，载入识别模型")
    }

    private func send(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(10)
        if state == .ready {
            write(data)
        } else {
            queued.append(data)
        }
    }

    private func write(_ data: Data) {
        do {
            try input?.write(contentsOf: data)
        } catch {
            Log.engine.error("发给 wotype-voice 失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    private func received(_ line: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let type = object["type"] as? String else { return }
        let id = object["id"] as? String
        switch type {
        case "ready":
            state = .ready
            Log.engine.info("识别模型好了")
            let waiting = queued
            queued = []
            waiting.forEach(write)
        case "end":
            guard let id, let continuation = pending.removeValue(forKey: id) else { return }
            continuation.resume(returning: object["text"] as? String ?? "")
        case "polished":
            guard let id, let continuation = pending.removeValue(forKey: id) else { return }
            if object["stop"] as? String == "length" {
                continuation.resume(throwing: Failure.truncated)
            } else {
                continuation.resume(returning: object["text"] as? String ?? "")
            }
        case "cancelled":
            guard let id, let continuation = pending.removeValue(forKey: id) else { return }
            continuation.resume(throwing: CancellationError())
        case "error":
            guard let id, let continuation = pending.removeValue(forKey: id) else { return }
            continuation.resume(throwing: Failure.rejected)
        case "fatal":
            Log.engine.error("wotype-voice：模型载入失败")
            fail(Failure.modelMissing)
        default:
            break
        }
    }

    private func terminated(_ finished: Process, status: Int32) {
        guard finished === process else { return }
        Log.engine.info("wotype-voice 退出（\(status)）")
        process = nil
        input = nil
        state = .stopped
        // 闲置退出时没有等着的请求；有的话就是崩了
        fail(Failure.crashed)
    }

    private func fail(_ error: Error) {
        queued = []
        let waiting = pending
        pending = [:]
        waiting.values.forEach { $0.resume(throwing: error) }
    }
}

/// 把管道里读到的字节切成一行一行（读回调在后台线程）。
private nonisolated final class LineSplitter: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()
    private let onLine: (String) -> Void

    init(onLine: @escaping (String) -> Void) {
        self.onLine = onLine
    }

    func append(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 10) {
            lines.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        lock.unlock()
        lines.forEach(onLine)
    }
}
