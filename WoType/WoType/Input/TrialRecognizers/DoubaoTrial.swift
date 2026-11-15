//
//  DoubaoTrial.swift
//  WoType
//
//  体验渠道：豆包输入法的云端识别（docs/21）。仅供体验，随时失效。
//
//  协议（照 Setem 的分析，代码自己写）：
//  - 先在字节的设备注册接口注册一台安卓手机（豆包输入法 1.4.6），拿到 device_id，存在 trial-asr/doubao.json；
//  - wss://frontier-audio-ime-ws.doubao.com/ocean/api/v1/ws，消息是 protobuf：
//    StartTask → TaskStarted，StartSession（声音格式、标点）→ SessionStarted，
//    每 20 ms 一个 TaskRequest（一个 Opus 包，第一个标 1、中间标 3、最后一个空包标 9），FinishSession → SessionFinished；
//  - 回复的 result 是 JSON，results 里每一句一项（见 DoubaoTrial.Transcript）。
//

import Foundation
import os

nonisolated enum DoubaoTrial {
    static let socketURL = "wss://frontier-audio-ime-ws.doubao.com/ocean/api/v1/ws"
    static let registerURL = "https://log-klink.zijieapi.com/service/2/device_register/"
    static let appID = "401734"
    /// 豆包输入法 1.4.6 客户端里的识别密钥
    static let appKey = "OrnqKvSSrs"
    static let statusOK = 20_000_000
    /// TaskRequest 的帧标记
    static let firstFrame: UInt64 = 1, middleFrame: UInt64 = 3, lastFrame: UInt64 = 9

    struct Link: Sendable {
        let socket: TrialSocket
        let device: Device
        let requestID: String
    }

    /// 连上、开始任务和会话。被拒时换一台设备再试一次（Setem 是被拒后重放整段录音；这里还没开始发声音，重连就行）。
    static func connect() async throws -> Link {
        do {
            return try await open(device: Device.load())
        } catch let failure as Rejected {
            Device.reset()
            Log.input.info("豆包输入法：设备被拒（\(failure.message, privacy: .public)），换一台再试")
            do {
                return try await open(device: Device.load())
            } catch {
                Device.reset()
                throw TrialFailure("豆包输入法连不上：" + error.localizedDescription)
            }
        } catch {
            throw TrialFailure("豆包输入法连不上：" + error.localizedDescription)
        }
    }

    /// 服务器拒绝了（事件以 Failed 结尾，或状态码不对）
    struct Rejected: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func open(device: Device) async throws -> Link {
        let url = URL(string: socketURL + "?aid=\(appID)&device_id=\(device.id)")!
        let socket = TrialSocket(url: url, headers: [
            ("User-Agent", device.phone.userAgent),
            ("proto-version", "v2"),
            ("x-custom-keepalive", "true"),
        ])
        let requestID = UUID().uuidString.lowercased()
        // 10 秒内没完成握手就关掉连接，receive 会出错返回
        let watchdog = Task {
            try await Task.sleep(for: .seconds(10))
            socket.close()
        }
        defer { watchdog.cancel() }
        do {
            try await socket.open(timeout: 8)
            try await socket.send(request(method: "StartTask", token: true, requestID: requestID))
            try await expect("TaskStarted", on: socket)
            try await socket.send(request(method: "StartSession", token: true, payload: sessionConfig(device),
                                          requestID: requestID))
            try await expect("SessionStarted", on: socket)
        } catch {
            socket.close()
            throw error
        }
        return Link(socket: socket, device: device, requestID: requestID)
    }

    private static func expect(_ event: String, on socket: TrialSocket) async throws {
        while true {
            let reply = try Reply(try await socket.receive())
            if reply.event.hasSuffix("Failed") || (reply.event == event && reply.status != statusOK) {
                throw Rejected(message: "\(reply.event) \(reply.status) \(reply.message)")
            }
            if reply.event == event { return }
        }
    }

    // MARK: - 消息

    static func request(method: String, token: Bool = false, payload: String? = nil, audio: Data? = nil,
                        requestID: String, frame: UInt64? = nil) -> Data {
        var parts: [Data] = []
        if token { parts.append(TrialProto.field(2, appKey)) }
        parts.append(TrialProto.field(3, "ASR"))
        parts.append(TrialProto.field(5, method))
        if let payload { parts.append(TrialProto.field(6, payload)) }
        if let audio { parts.append(TrialProto.field(7, audio)) }
        parts.append(TrialProto.field(8, requestID))
        if let frame { parts.append(TrialProto.message([TrialProto.varint(9 << 3), TrialProto.varint(Int(frame))])) }
        return TrialProto.message(parts)
    }

    /// 一个 Opus 包（第 index 个，20 ms 一个）
    static func audio(_ link: Link, packet: Data?, index: Int, started: Int) -> Data {
        let meta = "{\"extra\":{},\"timestamp_ms\":\(started + index * 20)}"
        let frame = packet == nil ? lastFrame : index == 0 ? firstFrame : middleFrame
        return request(method: "TaskRequest", payload: meta, audio: packet, requestID: link.requestID, frame: frame)
    }

    static func finish(_ link: Link) -> Data {
        request(method: "FinishSession", token: true, requestID: link.requestID)
    }

    private static func sessionConfig(_ device: Device) -> String {
        let config: [String: Any] = [
            "audio_info": ["channel": 1, "format": "speech_opus", "sample_rate": 16_000],
            "enable_punctuation": true,
            "enable_speech_rejection": true,
            "extra": [
                "app_name": "oime", "cell_compress_rate": 8, "did": device.id,
                "enable_asr_threepass": false, "enable_asr_twopass": true, "input_mode": "stream",
            ] as [String: Any],
        ]
        return String(decoding: (try? JSONSerialization.data(withJSONObject: config)) ?? Data(), as: UTF8.self)
    }

    /// 服务器的一条回复。
    struct Reply {
        var event = ""
        var status = 0
        var message = ""
        /// 识别结果（JSON）
        var result = ""

        init(_ data: Data) throws {
            for field in try TrialProto.read(data) {
                switch field.number {
                case 4: event = field.bytes.map { String(decoding: $0, as: UTF8.self) } ?? ""
                case 5: status = Int(Int32(truncatingIfNeeded: field.value ?? 0))
                case 6: message = field.bytes.map { String(decoding: $0, as: UTF8.self) } ?? ""
                case 7: result = field.bytes.map { String(decoding: $0, as: UTF8.self) } ?? ""
                default: break
                }
            }
        }
    }

    // MARK: - 设备

    /// 注册过的设备：device_id 和注册时用的手机（User-Agent 要和注册时一致）。
    struct Device: Codable, Sendable {
        let id: String
        let phone: Phone

        private static var file: URL { TrialChannel.directory.appendingPathComponent("doubao.json") }

        static func load() async throws -> Device {
            if let data = try? Data(contentsOf: file), let device = try? JSONDecoder().decode(Device.self, from: data),
               !device.id.isEmpty {
                return device
            }
            let device = try await register(Phone.all.randomElement()!)
            try? JSONEncoder().encode(device).write(to: file, options: .atomic)
            return device
        }

        static func reset() { try? FileManager.default.removeItem(at: file) }

        private static func register(_ phone: Phone) async throws -> Device {
            let now = String(Int(Date().timeIntervalSince1970 * 1000))
            let cdid = UUID().uuidString.lowercased()
            var header: [String: Any] = phone.parameters
            header.merge([
                "device_id": 0, "install_id": 0, "cdid": cdid,
                "openudid": String(format: "%016llx", UInt64.random(in: 0...UInt64.max)),
                "clientudid": UUID().uuidString.lowercased(),
                "region": "CN", "tz_name": "Asia/Shanghai", "tz_offset": 28_800, "sim_region": "cn", "carrier_region": "cn",
                "cpu_abi": "arm64-v8a", "build_serial": "unknown", "not_request_sender": 0,
                "sig_hash": "", "google_aid": "", "mc": "", "serial_number": "",
            ]) { _, new in new }
            let body: [String: Any] = ["magic_tag": "ss_app_log", "header": header, "_gen_time": Int(now)!]
            var components = URLComponents(string: registerURL)!
            components.queryItems = phone.parameters.merging(["ssmix": "a", "_rticket": now, "cdid": cdid, "ac": "wifi"]) {
                _, new in new
            }.map { URLQueryItem(name: $0.key, value: $0.value) }
            var request = URLRequest(url: components.url!, timeoutInterval: 10)
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue(phone.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw TrialFailure("设备注册失败")
            }
            let id = reply["device_id_str"] as? String ?? (reply["device_id"] as? NSNumber)?.stringValue ?? ""
            guard !id.isEmpty, id != "0" else { throw TrialFailure("设备注册被拒绝") }
            Log.input.info("豆包输入法：注册了一台设备（\(phone.model, privacy: .public)）")
            return Device(id: id, phone: phone)
        }
    }

    /// 注册时扮演的手机。
    struct Phone: Codable, Sendable {
        let brand: String, model: String, os: String, api: String, build: String, resolution: String, dpi: String

        static let all = [
            Phone(brand: "google", model: "Pixel 8", os: "15", api: "35", build: "AP4A.250205.002",
                  resolution: "1080*2400", dpi: "420"),
            Phone(brand: "google", model: "Pixel 7 Pro", os: "16", api: "36", build: "BP2A.250605.031.A2",
                  resolution: "1080*2340", dpi: "420"),
            Phone(brand: "Xiaomi", model: "23127PN0CC", os: "14", api: "34", build: "UKQ1.230804.001",
                  resolution: "1200*2670", dpi: "440"),
            Phone(brand: "vivo", model: "V2309A", os: "14", api: "34", build: "UP1A.231005.007",
                  resolution: "1260*2800", dpi: "480"),
            Phone(brand: "OPPO", model: "PHZ110", os: "14", api: "34", build: "UKQ1.231108.001",
                  resolution: "1264*2780", dpi: "480"),
        ]

        var userAgent: String {
            "com.bytedance.android.doubaoime/100406010 (Linux; U; Android \(os); en_US; \(model); Build/\(build); "
                + "Cronet/TTNetVersion:94cf429a 2025-11-17 QuicVersion:1f89f732 2025-05-08)"
        }

        var parameters: [String: String] {
            [
                "aid": DoubaoTrial.appID, "app_name": "oime", "channel": "official",
                "version_code": "100406010", "version_name": "1.4.6", "manifest_version_code": "100406010",
                "update_version_code": "100406010", "package": "com.bytedance.android.doubaoime",
                "device_platform": "android", "os": "android", "os_api": api, "os_version": os,
                "device_type": model, "device_brand": brand, "device_model": model,
                "resolution": resolution, "dpi": dpi, "language": "zh", "timezone": "8", "access": "wifi",
                "rom": build, "rom_version": build,
            ]
        }
    }

    // MARK: - 文字

    /// 把一次会话里的识别结果拼成整段文字。
    ///
    /// 2026-11-14 抓的回复（3～40 秒、中间停 1～3 秒）：results 没有 index，第一项一直是到现在为止的整段文字
    /// （说完的句子已经加好标点、改好写法，后面接着正在说的这句）；后面几项是把它拆开的已定稿部分和当前这句，
    /// 或者另一种写法（「下午 3」和「下午三」）。所以只用第一项，后面的不能拿来覆盖（会只剩最后一句）。
    /// Setem 还处理带 index 的分句回复，抓的回复里没见过；万一来了，按 index 排好拼起来。
    struct Transcript {
        private(set) var text = ""
        /// 带 index 的分句（没见过，防万一）
        private var sentences: [Int: String] = [:]

        /// 收一条 result JSON。文字变了返回 true。空文字、坏 JSON 不改。
        mutating func update(_ json: String) -> Bool {
            guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                  let results = object["results"] as? [[String: Any]], let first = results.first else { return false }
            let before = text
            if results.contains(where: { $0["index"] != nil }) {
                // 同一句后来的回复替换前面的
                for result in results {
                    guard let index = result["index"] as? Int, let text = result["text"] as? String, !text.isEmpty else { continue }
                    sentences[index] = text
                }
                text = VoicePCM.joinText(sentences.keys.sorted().compactMap { sentences[$0] })
            } else if let whole = first["text"] as? String, !whole.isEmpty {
                text = whole
            }
            return text != before
        }

    }
}

/// 一次听写走豆包。和千问一样：按下就连，连上之前的声音排着；每 20 ms 编一个 Opus 包发出去；
/// 整段录音留着，失败时 VoiceController 改用本机识别。
@MainActor
final class DoubaoTrialRecognizer: SpeechRecognizer {

    var onRevision: (() -> Void)?
    var partial: String { transcript.text }
    private(set) var recording: [Float]? = []

    private var transcript = DoubaoTrial.Transcript()
    private let packets: AsyncStream<Data>
    private let packetSink: AsyncStream<Data>.Continuation
    private let encoder: TrialOpus?
    private var socket: TrialSocket?
    private var session: Task<String, Error>?
    private var receiver: Task<Void, Never>?
    private var sessionFinished = false
    private var failure: Error?
    private var closing = false
    private var stopped = false
    private var completed = false
    private var sentPackets = 0
    private let began = ContinuousClock.now
    private var released: ContinuousClock.Instant?
    private var firstText = true
    /// 第一次听到说话（音量到说话门限）的时候：日志里分开「按键到出字」和「开口到出字」
    private var speechStarted: ContinuousClock.Instant?

    init() {
        (packets, packetSink) = AsyncStream<Data>.makeStream()
        encoder = try? TrialOpus(bitRate: 16_000)
        // 开头先放 200 ms 静音，让服务器先起音，第一个字不丢（Setem 的做法）
        for _ in 0..<10 { encode([Float](repeating: 0, count: 320)) }
        session = Task { try await self.run() }
    }

    func accept(_ frame: [Float]) throws {
        if stopped || closing { throw VoiceService.Failure.rejected }
        recording?.append(contentsOf: frame)
        if speechStarted == nil, VoicePCM.classify(frame).speech { speechStarted = .now }
        // 连接断了也照样录：松开后改用本机识别
        guard failure == nil else { return }
        encode(frame)
    }

    private func encode(_ frame: [Float]) {
        guard let encoder else { return }
        let samples = frame.map { Int16(max(-1, min(1, $0)) * 32767) }
        for packet in encoder.encode(samples) { packetSink.yield(packet) }
    }

    func finish() async throws -> String {
        if closing { throw VoiceService.Failure.rejected }
        stopped = true
        released = .now
        packetSink.finish()
        // 最多等 10 秒加录音时长的四分之一（Setem 的 10 秒 + 帧数 / 200）
        let seconds = Double(recording?.count ?? 0) / 16_000
        let watchdog = Task { [weak self] in
            try await Task.sleep(for: .seconds(10 + seconds / 4))
            self?.failure = TrialFailure("豆包输入法没有及时返回结果")
            self?.socket?.close()
        }
        defer { watchdog.cancel() }
        guard let session else { throw VoiceService.Failure.rejected }
        return try await session.value
    }

    func close() {
        closing = true
        packetSink.finish()
        session?.cancel()
        receiver?.cancel()
        socket?.close()
        recording = nil
    }

    private func run() async throws -> String {
        do {
            guard encoder != nil else { throw TrialFailure("Opus 编码器建不起来") }
            let link = try await DoubaoTrial.connect()
            socket = link.socket
            Log.input.info("豆包输入法：连上了，用了 \(Self.ms(since: self.began), privacy: .public)")
            if closing { link.socket.close(); throw CancellationError() }
            receiver = Task { await self.receive(link.socket) }
            let started = Int(Date().timeIntervalSince1970 * 1000)
            for await packet in packets {
                if let failure { throw failure }
                try await link.socket.send(DoubaoTrial.audio(link, packet: packet, index: sentPackets, started: started))
                sentPackets += 1
            }
            if closing { throw CancellationError() }
            try await link.socket.send(DoubaoTrial.audio(link, packet: nil, index: sentPackets, started: started))
            try await link.socket.send(DoubaoTrial.finish(link))
            completed = true
            // 等 SessionFinished（整个结束阶段由 finish 里的计时兜底）
            while !sessionFinished, failure == nil {
                try await Task.sleep(for: .milliseconds(20))
            }
            link.socket.close()
            let waited = released.map { Self.ms(since: $0) } ?? "-"
            let state = sessionFinished ? "定稿了" : "没等到定稿（\(failure?.localizedDescription ?? "-")）"
            Log.input.info("豆包输入法：松键后 \(waited, privacy: .public) 出结果，\(state, privacy: .public)，\(self.partial.count) 字")
            if partial.isEmpty, let failure { throw failure }
            return partial
        } catch {
            socket?.close()
            if !closing, failure == nil { failure = error }
            Log.input.error("豆包输入法：\(error.localizedDescription, privacy: .public)")
            // 声音都发完了、已经有字：用它。没发完的话后面的话会丢，改用本机
            if !closing, completed, !partial.isEmpty { return partial }
            throw failure ?? error
        }
    }

    private func receive(_ socket: TrialSocket) async {
        do {
            while !closing {
                let reply = try DoubaoTrial.Reply(try await socket.receive())
                if !reply.result.isEmpty, transcript.update(reply.result) {
                    if firstText {
                        firstText = false
                        let spoken = speechStarted.map { "，开口后 " + Self.ms(since: $0) } ?? ""
                        Log.input.info("豆包输入法：第一个字，按键后 \(Self.ms(since: self.began), privacy: .public)\(spoken, privacy: .public)")
                    }
                    onRevision?()
                }
                if reply.event.hasSuffix("Failed") {
                    throw TrialFailure("豆包输入法：\(reply.event) \(reply.message)")
                }
                if reply.event == "SessionFinished" {
                    sessionFinished = true
                    return
                }
            }
        } catch {
            if !closing, !sessionFinished, failure == nil { failure = error }
        }
    }

    private static func ms(since start: ContinuousClock.Instant) -> String {
        let elapsed = ContinuousClock.now - start
        return "\(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000) ms"
    }
}
