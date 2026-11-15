//
//  WeTypeTrial.swift
//  WoType
//
//  体验渠道：微信输入法的云端识别（docs/21）。仅供体验，随时失效。
//
//  协议（照 Setem 的分析，代码自己写）：
//  - wss://wetype.weixin.qq.com/（子协议 wxws_pb），每条消息是包成 protobuf 的一个 HTTP 请求，一问一答；
//    请求头里带签名：SHA-256（固定的几项 + 时间 + 正文 MD5 + uin + trace + task + 签名密钥）；
//  - 握手：/timestamp；用 secp128r1 做 ECDH（/oauth_pubkey_v2，用内置的 bootKey 加密）换出会话密钥；
//    第一次用时注册一台 Mac（设备号 + /gen_uin_v2 拿 uin），存在 trial-asr/wetype.json；再 /api_v2 通知一下；
//  - 识别：每 120 ms（6 个 Opus 包）发一次 /api_v2（cmd 4548），正文是 snappy 压缩后用会话密钥 AES-256-ECB 加密的
//    protobuf；第一包前面有「#!OPUS_RAW_V1」头，每个包前面两字节长度。回复里 4 是到现在为止的整段文字，
//    14 是微信整理过的文字（说完一段以后就有），5 是 1 表示定稿了；松键后发空包问，一般问两次（约 0.2～0.5 秒）定稿。
//    2026-11-14 抓的回复：一段说完停顿后，文字里会插一个换行（分段）。
//

import Foundation
import os

nonisolated enum WeTypeTrial {
    static let host = "wetype.weixin.qq.com"
    static let signKey = "zN7rB3bL4pO8jW1o"
    static let bootKey = Data("D4Y5U3Y2M0C0T7N4P1P7O2N6E1I2Y1U6".utf8)
    static let version = "2.2.3(657)"
    static let osType = "5", platform = "2", deviceModel = "Mac16,12"
    static let cmdKeyExchange = 2_147_483_646, cmdRegister = 0x7FFF_FDFD, cmdNotify = 8074, cmdVoice = 4548
    /// 第一包声音前面的头
    static let opusHeader = Data("#!OPUS_RAW_V1".utf8) + Data([2, 1, 0])
    /// 一次请求带几个 Opus 包（6 × 20 ms）
    static let packetsPerRequest = 6

    /// 连上、换好密钥的一条连接。请求要一个一个发（一问一答）。
    final class Link: @unchecked Sendable {
        let socket: TrialSocket
        fileprivate var uin = "0"
        fileprivate var device = ""
        fileprivate var key: Data?
        fileprivate var serverPublic = ""
        fileprivate var registerToken = ""
        private var task = 0

        init(socket: TrialSocket) { self.socket = socket }

        /// 一次请求，等回复（timeout 秒内没回就断开连接）。
        func roundtrip(_ path: String, _ body: Data, cmd: Int, compression: String = "1", token: String = "",
                       timeout: TimeInterval = 15) async throws -> Response {
            let keyExchange = cmd == cmdKeyExchange, register = cmd == cmdRegister
            if !(keyExchange || register) { task += 1 }
            let taskID = keyExchange || register ? cmd : task
            let trace = String((0..<16).map { _ in Character(UnicodeScalar(UInt8.random(in: 97...122))) })
            let bodyMD5 = WeTypeCrypto.md5(body)
            let time = String(Int(Date().timeIntervalSince1970 * 1000))
            let signed: [String] = keyExchange
                ? [osType, version, platform, time, bodyMD5, trace, String(cmd)]
                : register
                ? [osType, version, platform, time, bodyMD5, token, trace, String(cmd)]
                : [osType, version, platform, String(cmd), "0", time, bodyMD5, uin, trace, String(taskID)]
            let sign = WeTypeCrypto.sha256(Data((signed.joined() + signKey).utf8))

            var headers: [(String, String)] = []
            if !token.isEmpty { headers.append(("Kb-GenUinToken", token)) }
            headers.append(("Kb-Uin", uin))
            if keyExchange || register { headers.append(("Kb-DeviceCodeRestrictionV2", "1")) }
            if !keyExchange {
                if let key { headers.append(("Kb-SharedKeySuffix", String(String(decoding: key, as: UTF8.self).suffix(4)))) }
                headers += [("Kb-CmdId", String(cmd)), ("Kb-SubCmdId", "0")]
            }
            headers += [
                ("Kb-OsType", osType), ("Kb-Version", version), ("Kb-SystemVersion", "27.0.0"), ("Kb-PackageType", "3"),
                ("Use_DebugNet", "0"), ("Kb-TimeStamp", time), ("Kb-BodyMd5", bodyMD5), ("Kb-TraceId", trace),
                ("Kb-TaskId", String(taskID)), ("Kb-Scene", "2"), ("Kb-Sign", sign), ("Content-Length", String(body.count)),
                ("Kb-CompressionType", compression), ("Content-Type", "application/octet-stream"), ("HOST", host),
            ]
            var http = [TrialProto.field(1, "POST"), TrialProto.field(3, path), TrialProto.field(4, "")]
            for (name, value) in headers {
                http.append(TrialProto.field(5, TrialProto.message([TrialProto.field(1, name), TrialProto.field(2, value)])))
            }
            http.append(TrialProto.field(6, body))
            let frame = TrialProto.message([
                TrialProto.number(1, 0), TrialProto.number(2, 0), TrialProto.number(3, UInt64(taskID)),
                TrialProto.field(5, TrialProto.message(http)),
            ])

            let socket = self.socket
            let watchdog = Task {
                try await Task.sleep(for: .seconds(timeout))
                socket.close()
            }
            defer { watchdog.cancel() }
            try await socket.send(frame)
            return try Response(try await socket.receive())
        }

        /// 用会话密钥加密的请求，状态码不是 200 就抛错，返回解密后的正文。
        fileprivate func secure(_ path: String, _ plain: Data, cmd: Int, compression: String = "1", token: String = "",
                                timeout: TimeInterval = 15) async throws -> (Response, Data) {
            guard let key else { throw TrialFailure("微信会话密钥缺失") }
            let reply = try await roundtrip(path, try WeTypeCrypto.encrypt(plain, key: key), cmd: cmd,
                                            compression: compression, token: token, timeout: timeout)
            guard reply.status == 200, !reply.body.isEmpty else { throw TrialFailure("微信 \(path) 状态 \(reply.status)") }
            return (reply, try WeTypeCrypto.decrypt(reply.body, key: key))
        }

        /// ECDH 换会话密钥。needUin：注册时要服务器另给一个注册用的 token。
        fileprivate func exchangeKey(needUin: Bool) async throws {
            let (secret, publicKey) = Secp128r1.keyPair()
            var request = [TrialProto.field(1, publicKey), TrialProto.field(2, publicKey)]
            if needUin { request.append(TrialProto.number(3, 1)) }
            request.append(TrialProto.field(4, device))
            if !needUin { request.append(TrialProto.number(5, UInt64(uin) ?? 0)) }
            request += [TrialProto.field(7, ""), TrialProto.field(8, deviceModel), TrialProto.field(9, "")]
            let reply = try await roundtrip("/oauth_pubkey_v2",
                                            try WeTypeCrypto.encrypt(TrialProto.message(request), key: bootKey),
                                            cmd: cmdKeyExchange)
            guard reply.status == 200, !reply.body.isEmpty else { throw TrialFailure("微信密钥交换状态 \(reply.status)") }
            let fields = try TrialProto.read(try WeTypeCrypto.decrypt(reply.body, key: bootKey))
            func text(_ number: Int) -> String? {
                fields.first { $0.number == number }?.bytes.map { String(decoding: $0, as: UTF8.self) }
            }
            guard let server = text(2), !server.isEmpty else { throw TrialFailure("微信密钥交换不完整") }
            let token = text(4) ?? ""
            if needUin, token.isEmpty { throw TrialFailure("微信密钥交换不完整") }
            serverPublic = server
            registerToken = token
            key = Data(try Secp128r1.sharedSecret(secret, peer: server).utf8)
        }

        /// 注册一台 Mac：设备号是「MAC」+ 补零的机型 + 12 个随机字母，再接 MD5；然后拿 uin。
        fileprivate func register() async throws {
            uin = "0"
            let body = "MAC" + String(repeating: "0", count: 17 - deviceModel.count) + deviceModel
                + String((0..<12).map { _ in Character(UnicodeScalar(UInt8.random(in: 97...122))) })
            device = body + WeTypeCrypto.md5(Data((body + signKey).utf8))
            try await exchangeKey(needUin: true)
            let request = TrialProto.message([
                TrialProto.field(1, device), TrialProto.field(2, serverPublic), TrialProto.field(4, registerToken),
            ])
            let (_, plain) = try await secure("/gen_uin_v2", request, cmd: cmdRegister, token: registerToken)
            guard let issued = try TrialProto.read(plain).first(where: { $0.number == 2 })?.value, issued != 0 else {
                throw TrialFailure("微信没有给 uin")
            }
            uin = String(issued)
            Log.input.info("微信输入法：注册了一台设备")
        }

        /// 发一次声音。返回到现在为止的文字、整理过的文字（可能是空的）、定稿了没有。
        func voice(id: String, audio: Data?, seq: Int, totalBytes: Int, isEnd: Bool) async throws
            -> (text: String, polished: String, finished: Bool) {
            var inner = [TrialProto.field(2, id)]
            if let audio, !audio.isEmpty { inner.append(TrialProto.field(4, audio)) }
            inner.append(TrialProto.number(5, 5))
            if isEnd { inner.append(TrialProto.number(6, 1)) }
            inner.append(TrialProto.number(7, UInt64(seq)))
            if totalBytes > 0 { inner.append(TrialProto.number(11, UInt64(totalBytes))) }
            inner += [TrialProto.number(22, 1), TrialProto.number(23, 1), TrialProto.number(24, 1)]
            let outer = TrialProto.field(1, TrialProto.message(inner))
            let (reply, decrypted) = try await secure("/api_v2", WeTypeCrypto.snappyCompress(outer), cmd: cmdVoice,
                                                      compression: "2")
            var plain = decrypted
            if (reply.headers["Kb-CompressionType"] ?? reply.headers["CompressionType"]) == "2" {
                plain = try WeTypeCrypto.snappyDecompress(plain)
            }
            let top = try TrialProto.read(plain)
            let fields = try top.first(where: { $0.number == 1 })?.bytes.map(TrialProto.read) ?? top
            func text(_ number: Int) -> String {
                fields.first { $0.number == number }?.bytes.map { String(decoding: $0, as: UTF8.self) } ?? ""
            }
            return (text(4), text(14), fields.first { $0.number == 5 }?.value == 1)
        }
    }

    /// 回复：状态码、头、正文。
    struct Response {
        var status: UInt64 = 0
        var headers: [String: String] = [:]
        var body = Data()

        init(_ data: Data) throws {
            guard let http = try TrialProto.read(data).first(where: { $0.number == 4 })?.bytes else {
                throw TrialFailure("微信回复格式不对")
            }
            for field in try TrialProto.read(http) {
                switch field.number {
                case 2: status = field.value ?? 0
                case 5: body = field.bytes ?? Data()
                default:
                    // 别的长度前缀字段是头：key、value 两项
                    guard let bytes = field.bytes, let pair = try? TrialProto.read(bytes), pair.count >= 2,
                          let name = pair[0].bytes, let value = pair[1].bytes else { continue }
                    headers[String(decoding: name, as: UTF8.self)] = String(decoding: value, as: UTF8.self)
                }
            }
        }
    }

    /// 本机注册过的设备号和 uin
    struct Identity: Codable {
        let device: String
        let uin: String

        static var file: URL { TrialChannel.directory.appendingPathComponent("wetype.json") }

        static func load() -> Identity? {
            (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Identity.self, from: $0) }
        }

        func save() { try? JSONEncoder().encode(self).write(to: Self.file, options: .atomic) }
    }

    /// 连上：/timestamp，换密钥（存过的设备换不了就重新注册），/api_v2 通知。
    static func connect() async throws -> Link {
        let socket = TrialSocket(url: URL(string: "wss://\(host)/")!, headers: [], subprotocols: ["wxws_pb"])
        let link = Link(socket: socket)
        do {
            try await socket.open(timeout: 8)
            _ = try await link.roundtrip("/timestamp", Data(), cmd: 0, timeout: 8)
            if let saved = Identity.load() {
                link.device = saved.device
                link.uin = saved.uin
                do {
                    try await link.exchangeKey(needUin: false)
                } catch {
                    Log.input.info("微信输入法：存的设备用不了（\(error.localizedDescription, privacy: .public)），重新注册")
                    try await link.register()
                }
            } else {
                try await link.register()
            }
            let saved = Identity.load()
            if saved?.device != link.device || saved?.uin != link.uin {
                Identity(device: link.device, uin: link.uin).save()
            }
            _ = try await link.secure("/api_v2", Data(), cmd: cmdNotify, timeout: 8)
            return link
        } catch {
            socket.close()
            throw TrialFailure("微信输入法连不上：" + error.localizedDescription)
        }
    }
}

/// 一次听写走微信。按下就连，连上之前的声音排着；每 120 ms 发一次声音、等一次回复；
/// 松键后发空包问整理过的文字。整段录音留着，失败时 VoiceController 改用本机识别。
@MainActor
final class WeTypeTrialRecognizer: SpeechRecognizer {

    var onRevision: (() -> Void)?
    /// 说话时显示到现在为止的文字；还没有的话显示整理过的
    var partial: String { text.isEmpty ? polished : text }
    private(set) var recording: [Float]? = []

    private var text = ""
    /// 微信整理过的文字（标点、改口），松键后才有；有的话用它
    private var polished = ""
    private let packets: AsyncStream<Data>
    private let packetSink: AsyncStream<Data>.Continuation
    private let encoder: TrialOpus?
    private var socket: TrialSocket?
    private var session: Task<String, Error>?
    private var failure: Error?
    private var closing = false
    private var stopped = false
    private var completed = false
    /// 服务器说定稿了
    private var finished = false
    private let began = ContinuousClock.now
    private var released: ContinuousClock.Instant?
    private var firstText = true
    /// 第一次听到说话（音量到说话门限）的时候：日志里分开「按键到出字」和「开口到出字」
    private var speechStarted: ContinuousClock.Instant?

    init() {
        (packets, packetSink) = AsyncStream<Data>.makeStream()
        encoder = try? TrialOpus(bitRate: 64_000)
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
            self?.failure = TrialFailure("微信输入法没有及时返回结果")
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
        socket?.close()
        recording = nil
    }

    private func run() async throws -> String {
        do {
            guard encoder != nil else { throw TrialFailure("Opus 编码器建不起来") }
            let link = try await WeTypeTrial.connect()
            socket = link.socket
            Log.input.info("微信输入法：连上了，用了 \(Self.ms(since: self.began), privacy: .public)")
            if closing { link.socket.close(); throw CancellationError() }
            let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            var seq = 0
            var totalBytes = 0
            func upload(_ batch: [Data], isEnd: Bool) async throws {
                seq += 1
                var framed = seq == 1 ? WeTypeTrial.opusHeader : Data()
                for packet in batch {
                    framed.append(contentsOf: [UInt8(packet.count & 0xff), UInt8(packet.count >> 8)])
                    framed.append(packet)
                }
                totalBytes += framed.count
                try await received(link.voice(id: id, audio: framed, seq: seq, totalBytes: totalBytes, isEnd: isEnd))
            }
            var batch: [Data] = []
            for await packet in packets {
                if let failure { throw failure }
                batch.append(packet)
                if batch.count >= WeTypeTrial.packetsPerRequest {
                    try await upload(batch, isEnd: false)
                    batch.removeAll()
                }
            }
            if closing { throw CancellationError() }
            try await upload(batch, isEnd: true)
            completed = true
            // 松键后用空包问，直到定稿，最多 3 秒。Setem 只在还没有整理过的文字时问，可整理过的文字说完一段就有了，
            // 这样会漏掉最后几个字（2026-11-14 实测「抓紧时间」只到「抓紧时」）
            for _ in 0..<30 where !finished {
                try await Task.sleep(for: .milliseconds(100))
                try await received(link.voice(id: id, audio: nil, seq: 0, totalBytes: 0, isEnd: true))
            }
            link.socket.close()
            let waited = released.map { Self.ms(since: $0) } ?? "-"
            let state = (finished ? "定稿了" : "没等到定稿") + (polished.isEmpty ? "，用原文" : "，用整理好的文字")
            let result = polished.isEmpty ? text : polished
            Log.input.info("微信输入法：松键后 \(waited, privacy: .public) 出结果，\(state, privacy: .public)，\(result.count) 字")
            return result
        } catch {
            socket?.close()
            if !closing, failure == nil { failure = error }
            Log.input.error("微信输入法：\(error.localizedDescription, privacy: .public)")
            // 声音都发完了、已经有字：用它。没发完的话后面的话会丢，改用本机
            if !closing, completed, !partial.isEmpty { return polished.isEmpty ? text : polished }
            throw failure ?? error
        }
    }

    /// 收到一次回复：文字变了就更新草稿。
    private func received(_ reply: (text: String, polished: String, finished: Bool)) {
        let before = partial
        if !reply.text.isEmpty { text = reply.text }
        if !reply.polished.isEmpty { polished = reply.polished }
        if reply.finished { finished = true }
        guard partial != before else { return }
        if firstText {
            firstText = false
            let spoken = speechStarted.map { "，开口后 " + Self.ms(since: $0) } ?? ""
            Log.input.info("微信输入法：第一个字，按键后 \(Self.ms(since: self.began), privacy: .public)\(spoken, privacy: .public)")
        }
        onRevision?()
    }

    private static func ms(since start: ContinuousClock.Instant) -> String {
        let elapsed = ContinuousClock.now - start
        return "\(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000) ms"
    }
}
