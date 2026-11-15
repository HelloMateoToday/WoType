//
//  XAIRecognizer.swift
//  WoType
//
//  云端识别：xAI 的流式语音识别（docs/21）。文档：https://docs.x.ai/developers/rest-api-reference/inference/speech-to-text
//
//  wss://api.x.ai/v1/stt，请求头 Authorization: Bearer <密钥>，参数放在网址里（16 kHz 16 位 PCM、要草稿、模型、语言）。
//  指定了语言就传 language，能写数字的语言再加 format=true（「八点」→「8 点」）；自动识别时都不传。
//  不传热词（keyterm）：2026-11-14 实测，听不清时 xAI 会把热词当结果念出来（「帮我查一下明天的天气」→「万象拼音万象拼音」）；
//  词库的写法识别完以后 VoiceCorrection 还会再换一遍。
//  先等 transcript.created 再发声音；每 100 ms 发一块；松键发 {"type":"audio.done"}，等 transcript.done（整段文字）。
//  transcript.partial 的 text 只是当前这一小段：is_final=false 是还会变的草稿，true 是这段定了，后面来的是下一段；
//  一句话说完（speech_final=true）还会再来一次整句，和前面定了的几小段重叠（实测：1.16 秒起 9.03 秒、40 字，
//  盖住前面 11 字、29 字两段）。所以定稿按时间（start、duration）存，新定稿盖住的旧段换掉，不然每句话出现两遍。
//  transcript.done 的 text 实测一直是空的，结果用拼起来的。
//  用系统的 URLSession（走系统代理：国内连 xAI 一般要代理）。
//

import Foundation
import os

@MainActor
final class XAIRecognizer: SpeechRecognizer {

    var onRevision: (() -> Void)?
    var partial: String { done ?? VoicePCM.joinText(locked.map(\.text) + [current]) }
    private(set) var recording: [Float]? = []

    private let key: String
    private let model: String
    private let language: CloudSpeechLanguage
    /// 定了的几段（按开始时间排好）、正在说的这段、最后的整段文字
    private var locked: [(start: Double, end: Double, text: String)] = []
    private var current = ""
    private var done: String?
    private let chunks: AsyncStream<Data>
    private let chunkSink: AsyncStream<Data>.Continuation
    private var pending = Data()
    private var socket: URLSessionWebSocketTask?
    private var session: Task<String, Error>?
    private var failure: Error?
    private var closing = false
    private var stopped = false
    private var completed = false
    private let began = ContinuousClock.now
    private var released: ContinuousClock.Instant?
    private var firstText = true
    private var speechStarted: ContinuousClock.Instant?

    /// 一块声音 100 ms
    private static let chunkBytes = 3_200

    init(key: String, model: String, language: CloudSpeechLanguage) {
        self.key = key
        self.model = model
        self.language = language
        (chunks, chunkSink) = AsyncStream<Data>.makeStream()
        session = Task { try await self.run() }
    }

    func accept(_ frame: [Float]) throws {
        if stopped || closing { throw VoiceService.Failure.rejected }
        recording?.append(contentsOf: frame)
        if speechStarted == nil, VoicePCM.classify(frame).speech { speechStarted = .now }
        // 连接断了也照样录：松开后改用本机识别
        guard failure == nil else { return }
        pending.append(VoicePCM.int16Data(frame))
        while pending.count >= Self.chunkBytes {
            chunkSink.yield(Data(pending.prefix(Self.chunkBytes)))
            pending = Data(pending.dropFirst(Self.chunkBytes))
        }
    }

    func finish() async throws -> String {
        if closing { throw VoiceService.Failure.rejected }
        stopped = true
        released = .now
        if !pending.isEmpty { chunkSink.yield(pending) }
        pending = Data()
        chunkSink.finish()
        // 最多等 10 秒加录音时长的四分之一
        let seconds = Double(recording?.count ?? 0) / 16_000
        let watchdog = Task { [weak self] in
            try await Task.sleep(for: .seconds(10 + seconds / 4))
            self?.failure = CloudSpeechFailure("xAI 没有及时返回结果")
            self?.socket?.cancel(with: .goingAway, reason: nil)
        }
        defer { watchdog.cancel() }
        guard let session else { throw VoiceService.Failure.rejected }
        return try await session.value
    }

    func close() {
        closing = true
        chunkSink.finish()
        session?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        recording = nil
    }

    /// 连上并等到 transcript.created（10 秒）。密钥不对之类的握手失败按状态码说明。
    nonisolated static func url(model: String, language: CloudSpeechLanguage) -> URL {
        var components = URLComponents(string: "wss://api.x.ai/v1/stt")!
        var items = [
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "encoding", value: "pcm"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "model", value: model),
        ]
        if !language.code.isEmpty { items.append(URLQueryItem(name: "language", value: language.code)) }
        if language.formats { items.append(URLQueryItem(name: "format", value: "true")) }
        components.queryItems = items
        return components.url!
    }

    nonisolated static func connect(key: String, model: String, language: CloudSpeechLanguage) async throws
        -> URLSessionWebSocketTask {
        var request = URLRequest(url: url(model: model, language: language), timeoutInterval: 10)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        let watchdog = Task {
            try await Task.sleep(for: .seconds(10))
            task.cancel(with: .goingAway, reason: nil)
        }
        defer { watchdog.cancel() }
        do {
            while true {
                let event = Event(try await task.receive())
                if event.type == "transcript.created" { return task }
                if event.type == "error" { throw CloudSpeechFailure("xAI：" + event.message) }
            }
        } catch {
            task.cancel(with: .goingAway, reason: nil)
            if let response = task.response as? HTTPURLResponse, response.statusCode != 101 {
                throw CloudSpeechFailure.status(response.statusCode, provider: .xai)
            }
            throw CloudSpeechFailure.network(error, provider: .xai)
        }
    }

    private func run() async throws -> String {
        do {
            let task = try await Self.connect(key: key, model: model, language: language)
            socket = task
            Log.input.info("xAI：连上了，用了 \(Self.ms(since: self.began), privacy: .public)")
            if closing { task.cancel(with: .goingAway, reason: nil); throw CancellationError() }
            let receiver = Task { await self.receive(task) }
            for await chunk in chunks {
                if let failure { throw failure }
                try await task.send(.data(chunk))
            }
            if closing { throw CancellationError() }
            try await task.send(.string(#"{"type":"audio.done"}"#))
            completed = true
            await receiver.value
            task.cancel(with: .normalClosure, reason: nil)
            let waited = released.map { Self.ms(since: $0) } ?? "-"
            let state = done != nil ? "定稿了" : "没等到定稿（\(failure?.localizedDescription ?? "-")）"
            Log.input.info("xAI：松键后 \(waited, privacy: .public) 出结果，\(state, privacy: .public)，\(self.partial.count) 字")
            if done == nil, let failure, partial.isEmpty { throw failure }
            return partial
        } catch {
            socket?.cancel(with: .goingAway, reason: nil)
            if !closing, failure == nil { failure = error }
            Log.input.error("xAI：\((self.failure ?? error).localizedDescription, privacy: .public)")
            // 声音都发完了、已经有字：用它。没发完的话后面的话会丢，改用本机
            if !closing, completed, !partial.isEmpty { return partial }
            throw failure ?? error
        }
    }

    /// 收到 transcript.done 或出错为止。
    private func receive(_ task: URLSessionWebSocketTask) async {
        do {
            while !closing {
                let event = Event(try await task.receive())
                let before = partial
                switch event.type {
                case "transcript.partial":
                    if event.isFinal {
                        // 盖住的旧段（整句定稿盖住前面几小段、同一段又定一次）换成这次的
                        let end = event.start + event.duration
                        locked.removeAll { $0.start >= event.start - 0.05 && $0.end <= end + 0.05 }
                        if !event.text.isEmpty { locked.append((event.start, end, event.text)) }
                        locked.sort { $0.start < $1.start }
                        // 定下来的只是正在说的这段的前一部分：后面的先留着，等下一次草稿（约 0.5 秒后）来换。
                        // 清空的话结尾先缩回去再长出来，浮窗整行跟着来回挪（2026-11-14 录屏：「集合，坐大」→「集」→「集合，坐大巴」）
                        current = Self.remainder(of: current, after: event.text)
                    } else {
                        current = Self.trimEllipsis(event.text)
                    }
                case "transcript.done":
                    // 文档说是整段文字，2026-11-14 实测一直是空的：用拼起来的
                    done = event.text.isEmpty ? VoicePCM.joinText(locked.map(\.text) + [current]) : event.text
                case "error":
                    throw CloudSpeechFailure("xAI：" + event.message)
                default:
                    break
                }
                if partial != before {
                    if firstText {
                        firstText = false
                        let spoken = speechStarted.map { "，开口后 " + Self.ms(since: $0) } ?? ""
                        Log.input.info("xAI：第一个字，按键后 \(Self.ms(since: self.began), privacy: .public)\(spoken, privacy: .public)")
                    }
                    onRevision?()
                }
                if done != nil { return }
            }
        } catch {
            if !closing, done == nil, failure == nil { failure = CloudSpeechFailure.network(error, provider: .xai) }
        }
    }

    /// 服务器的一条 JSON 消息。
    nonisolated struct Event {
        var type = ""
        var text = ""
        var isFinal = false
        var start = 0.0
        var duration = 0.0
        var message = ""

        init(_ message: URLSessionWebSocketTask.Message) {
            switch message {
            case .string(let string): self.init(Data(string.utf8))
            case .data(let bytes): self.init(bytes)
            @unknown default: self.init(Data())
            }
        }

        init(_ data: Data) {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            type = object["type"] as? String ?? ""
            text = object["text"] as? String ?? ""
            isFinal = object["is_final"] as? Bool ?? false
            start = (object["start"] as? NSNumber)?.doubleValue ?? 0
            duration = (object["duration"] as? NSNumber)?.doubleValue ?? 0
            message = object["message"] as? String ?? (object["error"] as? String)
                ?? ((object["error"] as? [String: Any])?["message"] as? String) ?? "出错了"
        }
    }

    /// 草稿 draft 里去掉开头定下来的 locked 以后剩下的部分；对不上（写法改了）就是空的。比的时候不管标点、空白
    nonisolated static func remainder(of draft: String, after locked: String) -> String {
        let draft = Array(draft), locked = Array(locked)
        var i = 0, j = 0
        while j < locked.count {
            if i < draft.count && draft[i] == locked[j] { i += 1; j += 1 }
            else if Typewriter.isSeparator(locked[j]) { j += 1 }
            else if i < draft.count && Typewriter.isSeparator(draft[i]) { i += 1 }
            else { return "" }
        }
        while i < draft.count && Typewriter.isSeparator(draft[i]) { i += 1 }
        return String(draft[i...])
    }

    /// 没定的草稿结尾带「...」（xAI 表示还没说完），下一次就没了。留着的话浮窗里每次更新结尾都一缩一伸（2026-11-14 录屏）
    nonisolated static func trimEllipsis(_ text: String) -> String {
        var text = text
        while text.hasSuffix("...") || text.hasSuffix("…") {
            text = String(text.dropLast(text.hasSuffix("…") ? 1 : 3))
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    private static func ms(since start: ContinuousClock.Instant) -> String {
        let elapsed = ContinuousClock.now - start
        return "\(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000) ms"
    }
}
