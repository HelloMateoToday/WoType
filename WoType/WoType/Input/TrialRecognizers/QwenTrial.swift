//
//  QwenTrial.swift
//  WoType
//
//  体验渠道：千问输入法的云端识别（docs/21）。仅供体验，随时失效。
//
//  协议（照 Setem 的分析，代码自己写）：
//  - wss://voice-input.qianwen.com/ws/v1/voice，网址和请求头里带签名：
//    ut = base64(4E A4 + AES-128-CBC(设备号))，sign = "4ea4" + HMAC-SHA1(ut + 版本 + chid + 时间)；
//  - 消息是 protobuf：先 attach（声音格式 16 kHz 16 位 PCM），服务器回 sessionId、roundId（JSON）；
//    再一块块发 120 ms 的 PCM（asr/send），松键发 asr/complete；
//  - 服务器回 JSON：content.text 是到现在为止的整段文字（不是增量），newRoundId 表示这一轮定稿了。
//

import CommonCrypto
import CryptoKit
import Foundation
import os

nonisolated enum QwenTrial {
    static let host = "voice-input.qianwen.com"
    static let version = "1.2.35.46"
    static let origin = "https://www.qianwen.com"
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) "
        + "Version/17.0 Safari/605.1.15 TONGYI_DESKTOP/0.1.0 QuarkPC/ime_voice"
    static let hmacKey = Data("2d473b000fdb53e617446f805d4eaaacbb324bd16ee9f6d8237abd0ab79c5e48".utf8)
    static let aesKey = Data("a0a6237b2b735a54".utf8)
    /// 一块声音 120 ms（16 kHz、16 位）
    static let chunkBytes = 3840

    /// 连上、attach 完的一条连接。
    struct Link: Sendable {
        let socket: TrialSocket
        let auth: Auth
        let sessionID: String
        let roundID: String
    }

    /// 连上并 attach，拿到 sessionId。失败时换一个设备号（下次重新生成）。
    static func connect() async throws -> Link {
        let auth = try Auth(device: Device.load())
        let socket = TrialSocket(url: auth.url, headers: auth.headers)
        do {
            try await socket.open(timeout: 8)
            try await socket.send(attach(auth))
            // 8 秒内没回 sessionId 就关掉连接，receive 会出错返回
            let watchdog = Task {
                try await Task.sleep(for: .seconds(8))
                socket.close()
            }
            defer { watchdog.cancel() }
            while true {
                let event = Event(try await socket.receive())
                if let session = event.sessionID {
                    return Link(socket: socket, auth: auth, sessionID: session,
                                roundID: event.roundID ?? "ro_\(session)_0")
                }
            }
        } catch {
            socket.close()
            Device.reset()
            throw TrialFailure("千问输入法连不上：" + error.localizedDescription)
        }
    }

    // MARK: - 消息

    private static func now() -> String { String(Int(Date().timeIntervalSince1970 * 1000)) }

    private static func json(_ object: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8), as: UTF8.self)
    }

    static func attach(_ auth: Auth) -> Data {
        let time = now()
        let asr: [String: Any] = [
            "body": [
                "bitDepth": "16", "channel": "mono", "format": "pcm", "sampleRate": "16000",
                // 按键结束，不靠服务器判断说完（停顿再长也不断）
                "type": "manualStreamStop", "maxEndSilence": "180000", "maxStartSilence": "180000",
            ],
            "chid": auth.chid,
            "header": ["clt-acs-reqt": time, "ai_polish_mode": "off"],
            "param": [String: Any](),
            "route": "/app/live/init",
        ]
        let pipeline: [String: Any] = [
            "biz_data": [String: Any](), "biz_id": "ai_command", "chat_client": "native", "client_tm": time,
            "endpoint_config": [String: Any](), "from": "kkframenew_quark_asr", "scene": "voice_input_assistant",
            "ai_polish_mode": "off",
        ]
        return TrialProto.message([
            TrialProto.field(1, "/voice_assistant/channel/attach"),
            TrialProto.field(2, auth.chid),
            TrialProto.entry(3, "clt-acs-reqt", time),
            TrialProto.entry(5, "asrConfig", json(asr)),
            TrialProto.entry(5, "pipelineContext", json(pipeline)),
            TrialProto.entry(5, "trigger", "local_device"),
        ])
    }

    static func audio(_ link: Link, _ pcm: Data) -> Data {
        let audio = TrialProto.message([TrialProto.field(1, "audio"), TrialProto.field(2, "pcm"), TrialProto.field(3, pcm)])
        return TrialProto.message([
            TrialProto.field(1, "/voice_assistant/channel/asr/send"),
            TrialProto.field(2, link.auth.chid),
            TrialProto.entry(3, "clt-acs-reqt", now()),
            TrialProto.entry(4, "roundId", link.roundID),
            TrialProto.entry(4, "sessionId", link.sessionID),
            TrialProto.entry(5, "streamInputState", "process"),
            TrialProto.field(6, audio),
        ])
    }

    static func complete(_ link: Link) -> Data {
        TrialProto.message([
            TrialProto.field(1, "/voice_assistant/channel/asr/complete"),
            TrialProto.field(2, link.auth.chid),
            TrialProto.entry(3, "clt-acs-reqt", now()),
            TrialProto.entry(4, "roundId", link.roundID),
            TrialProto.entry(4, "sessionId", link.sessionID),
        ])
    }

    /// 服务器回的一条消息里我们用得到的东西。
    struct Event {
        var sessionID: String?
        var roundID: String?
        /// 这一轮定稿了
        var finished = false
        /// 到现在为止的整段文字
        var text: String?

        init(_ data: Data) {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let body = object["data"] as? [String: Any]
            if object["route"] as? String == "/voice_assistant/channel/attach",
               let session = body?["sessionId"] as? String, !session.isEmpty {
                sessionID = session
                roundID = (body?["roundId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            }
            if let round = body?["newRoundId"] as? String, !round.isEmpty { finished = true }
            text = Self.findText(object)
        }

        /// 任意一层里的 content.text
        private static func findText(_ value: Any) -> String? {
            if let dictionary = value as? [String: Any] {
                if let text = (dictionary["content"] as? [String: Any])?["text"] as? String, !text.isEmpty { return text }
                for child in dictionary.values { if let text = findText(child) { return text } }
            } else if let array = value as? [Any] {
                for child in array { if let text = findText(child) { return text } }
            }
            return nil
        }
    }

    // MARK: - 签名

    /// 本机的设备号：第一次用时随机生成，存在 trial-asr/qwen.json。连不上时删掉，下次重新生成。
    struct Device: Codable {
        let utdid: String

        private static var file: URL { TrialChannel.directory.appendingPathComponent("qwen.json") }

        static func load() -> Device {
            if let data = try? Data(contentsOf: file), let device = try? JSONDecoder().decode(Device.self, from: data),
               !device.utdid.isEmpty {
                return device
            }
            let id = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let device = Device(utdid: "WT" + id.prefix(20))
            try? JSONEncoder().encode(device).write(to: file, options: .atomic)
            return device
        }

        static func reset() { try? FileManager.default.removeItem(at: file) }
    }

    struct Auth: Sendable {
        let ut: String
        let chid: String
        let time: String
        let sign: String

        init(device: Device) throws {
            ut = try Self.encrypt(Data(device.utdid.utf8))
            chid = UUID().uuidString.lowercased() + "_1"
            time = QwenTrial.now()
            let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data((ut + QwenTrial.version + chid + time).utf8),
                                                             using: SymmetricKey(data: QwenTrial.hmacKey))
            sign = "4ea4" + mac.map { String(format: "%02x", $0) }.joined()
        }

        var url: URL {
            let query = "chid=\(chid)&biz_id=ai_qwen_input&from=kkframenew_quark_asr&uc_param_str=vepffrprsvchut"
                + "&ut=\(Self.escape(ut))&ve=\(QwenTrial.version)&pf=8002&pr=qwen&fr=mac&sv=release&ch=qianwen-ime"
            return URL(string: "wss://\(QwenTrial.host)/ws/v1/voice?" + query)!
        }

        var headers: [(String, String)] {
            [
                ("User-Agent", QwenTrial.userAgent),
                ("Origin", QwenTrial.origin),
                ("Cache-Control", "no-cache"),
                ("clt-acs-ut", Self.escape(ut)),
                ("clt-acs-ve", QwenTrial.version),
                ("clt-acs-kp", ""),
                ("clt-acs-reqt", time),
                ("clt-acs-wsgnver", "1"),
                ("clt-acs-request-params", "chid"),
                ("clt-acs-sign", sign),
                ("clt-acs-caer", "tlbe"),
                ("x-wpk-reqid", chid),
            ]
        }

        private static func escape(_ text: String) -> String {
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
        }

        /// AES-128-CBC（PKCS7，IV 和密钥相同），前面加 4E A4，base64。
        private static func encrypt(_ plain: Data) throws -> String {
            let key = [UInt8](QwenTrial.aesKey)
            var out = [UInt8](repeating: 0, count: plain.count + kCCBlockSizeAES128)
            var written = 0
            let status = plain.withUnsafeBytes { input in
                CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                        key, key.count, key, input.baseAddress, plain.count, &out, out.count, &written)
            }
            guard status == kCCSuccess else { throw TrialFailure("千问签名失败（\(status)）") }
            return (Data([0x4e, 0xa4]) + Data(out.prefix(written))).base64EncodedString()
        }
    }
}

/// 一次听写走千问。按下语音键就开始连，连上之前的声音先存着；声音每 120 ms 一块发出去，
/// 服务器回的整段文字就是草稿。整段录音也留着：失败时 VoiceController 改用本机识别。
@MainActor
final class QwenTrialRecognizer: SpeechRecognizer {

    var onRevision: (() -> Void)?
    private(set) var partial = ""
    private(set) var recording: [Float]? = []

    private let chunks: AsyncStream<Data>
    private let chunkSink: AsyncStream<Data>.Continuation
    /// 还不够一块的声音。开头先放 200 ms 静音，让服务器先起音，第一个字不丢（Setem 的做法）
    private var pending = Data(count: 16_000 * 2 / 5)
    private var socket: TrialSocket?
    private var session: Task<String, Error>?
    private var receiver: Task<Void, Never>?
    private var finished = false
    private var failure: Error?
    private var closing = false
    private var stopped = false
    /// 发过 asr/complete 了
    private var completed = false
    /// 计时（写日志用）：开始、松键
    private let began = ContinuousClock.now
    private var released: ContinuousClock.Instant?
    private var firstText = true
    /// 第一次听到说话（音量到说话门限）的时候：日志里分开「按键到出字」和「开口到出字」
    private var speechStarted: ContinuousClock.Instant?

    init() {
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
        while pending.count >= QwenTrial.chunkBytes {
            chunkSink.yield(Data(pending.prefix(QwenTrial.chunkBytes)))
            pending = Data(pending.dropFirst(QwenTrial.chunkBytes))
        }
    }

    func finish() async throws -> String {
        if closing { throw VoiceService.Failure.rejected }
        stopped = true
        released = .now
        if !pending.isEmpty {
            // 最后一块补齐静音
            pending.append(Data(count: (QwenTrial.chunkBytes - pending.count % QwenTrial.chunkBytes) % QwenTrial.chunkBytes))
            while !pending.isEmpty {
                chunkSink.yield(Data(pending.prefix(QwenTrial.chunkBytes)))
                pending = Data(pending.dropFirst(QwenTrial.chunkBytes))
            }
        }
        chunkSink.finish()
        // 最多等 10 秒加录音时长的四分之一（Setem 的 10 秒 + 帧数 / 200）
        let seconds = Double(recording?.count ?? 0) / 16_000
        let watchdog = Task { [weak self] in
            try await Task.sleep(for: .seconds(10 + seconds / 4))
            self?.failure = TrialFailure("千问输入法没有及时返回结果")
            self?.socket?.close()
        }
        defer { watchdog.cancel() }
        guard let session else { throw VoiceService.Failure.rejected }
        return try await session.value
    }

    func close() {
        closing = true
        chunkSink.finish()
        session?.cancel()
        receiver?.cancel()
        socket?.close()
        recording = nil
    }

    private func run() async throws -> String {
        do {
            let link = try await QwenTrial.connect()
            socket = link.socket
            Log.input.info("千问输入法：连上了，用了 \(Self.ms(since: self.began), privacy: .public)")
            if closing { link.socket.close(); throw CancellationError() }
            receiver = Task { await self.receive(link.socket) }
            for await chunk in chunks {
                if let failure { throw failure }
                try await link.socket.send(QwenTrial.audio(link, chunk))
            }
            if closing { throw CancellationError() }
            try await link.socket.send(QwenTrial.complete(link))
            completed = true
            // 等这一轮定稿：最多 3 秒，没等到就用最后一次的文字（Setem 等 2 秒）。
            // 2026-11-14 测过：5 分钟（App 的上限）松键后 0.5 秒定稿；千问一次会话只认前 8 分钟左右，多等也没用
            let deadline = ContinuousClock.now + .seconds(3)
            while !finished, failure == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            link.socket.close()
            let waited = released.map { Self.ms(since: $0) } ?? "-"
            Log.input.info("千问输入法：松键后 \(waited, privacy: .public) 出结果，\(self.finished ? "定稿了" : "没等到定稿（\(self.failure?.localizedDescription ?? "超时")）", privacy: .public)，\(self.partial.count) 字")
            if partial.isEmpty, let failure { throw failure }
            return partial
        } catch {
            socket?.close()
            if !closing, failure == nil { failure = error }
            Log.input.error("千问输入法：\(error.localizedDescription, privacy: .public)")
            // 声音都发完了、已经有字：用它，比改用本机从头识别快。没发完的话后面的话会丢，改用本机
            if !closing, completed, !partial.isEmpty { return partial }
            throw failure ?? error
        }
    }

    private static func ms(since start: ContinuousClock.Instant) -> String {
        let elapsed = ContinuousClock.now - start
        return "\(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000) ms"
    }

    private func receive(_ socket: TrialSocket) async {
        do {
            while !closing {
                let event = QwenTrial.Event(try await socket.receive())
                if let text = event.text, text != partial {
                    if firstText {
                        firstText = false
                        let spoken = speechStarted.map { "，开口后 " + Self.ms(since: $0) } ?? ""
                        Log.input.info("千问输入法：第一个字，按键后 \(Self.ms(since: self.began), privacy: .public)\(spoken, privacy: .public)")
                    }
                    partial = text
                    onRevision?()
                }
                if event.finished { finished = true }
            }
        } catch {
            // 自己关的连接（定稿后、取消）不算失败
            if !closing, !finished, failure == nil { failure = error }
        }
    }
}
