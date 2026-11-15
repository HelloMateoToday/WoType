//
//  TrialTransport.swift
//  WoType
//
//  体验渠道（docs/21）：调用输入法客户端的内部识别接口，不是官方开放接口，仅供体验，随时失效。
//  这个文件夹以后可能整个删掉：删掉后把 VoiceRecognizer.trial、设置里的「体验渠道」一起去掉。
//
//  协议照 Setem（sample/voice input/Setem-main）的分析结果，代码是 WoType 自己写的
//  （Setem 的上游 VoiceKey 没有许可证，不复制它的代码）。
//

import AudioToolbox
import Foundation
import Network

/// 体验渠道。
nonisolated enum TrialChannel: String, CaseIterable, Codable, Sendable {
    case doubao
    case wetype
    case qwen

    var title: String {
        switch self {
        case .doubao: "豆包输入法"
        case .wetype: "微信输入法"
        case .qwen: "千问输入法"
        }
    }

    /// 录音发到谁的服务器
    var vendor: String {
        switch self {
        case .doubao: "字节（豆包）"
        case .wetype: "腾讯（微信）"
        case .qwen: "阿里（千问）"
        }
    }

    @MainActor func makeRecognizer() -> SpeechRecognizer {
        switch self {
        case .doubao: DoubaoTrialRecognizer()
        case .wetype: WeTypeTrialRecognizer()
        case .qwen: QwenTrialRecognizer()
        }
    }

    /// 测试：连上并完成握手，返回用了多久。
    func test() async throws -> Duration {
        let clock = ContinuousClock()
        let began = clock.now
        switch self {
        case .doubao:
            let link = try await DoubaoTrial.connect()
            link.socket.close()
        case .wetype:
            let link = try await WeTypeTrial.connect()
            link.socket.close()
        case .qwen:
            let link = try await QwenTrial.connect()
            link.socket.close()
        }
        return clock.now - began
    }

    /// 渠道生成的设备身份等放在这里（WoType 数据文件夹下的 trial-asr）
    static var directory: URL {
        let url = Paths.userData.appendingPathComponent("trial-asr", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// 体验渠道的错误（文字直接给浮窗和设置页看）。
nonisolated struct TrialFailure: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// WebSocket 连接（Network 框架）。千问的服务器只认 HTTP/1.1 的升级握手，URLSession 会用 HTTP/2，
/// 所以 TLS 里只报 http/1.1。所有方法可以在任何线程调；close 以后挂着的收发都会出错返回。
nonisolated final class TrialSocket: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "WoType.TrialSocket")

    init(url: URL, headers: [(String, String)], subprotocols: [String] = [], bypassProxy: Bool = true) {
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.maximumMessageSize = 16 << 20
        websocket.setAdditionalHeaders(headers)
        if !subprotocols.isEmpty { websocket.setSubprotocols(subprotocols) }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        let parameters = NWParameters(tls: tls)
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        // 国内的服务器：不走系统代理（Setem 也这样）
        parameters.preferNoProxies = bypassProxy
        connection = NWConnection(to: .url(url), using: parameters)
    }

    deinit { connection.cancel() }

    /// 连上（含 WebSocket 握手）。超时、被拒、没网都抛错。
    func open(timeout: TimeInterval) async throws {
        let connection = self.connection
        let queue = self.queue
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let once = Once(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: once.resume(nil)
                    case .failed(let error): once.resume(error)
                    case .waiting(let error): connection.cancel(); once.resume(error)
                    case .cancelled: once.resume(TrialFailure("连接已关闭"))
                    default: break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) {
                    // 已经连上的不能动：2026-11-14 这里不管连没连上都 cancel，说到 8 秒时连接被自己断掉
                    if once.resume(TrialFailure("连接超时")) { connection.cancel() }
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    func send(_ data: Data) async throws {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "send", metadata: [metadata])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, contentContext: context, isComplete: true,
                            completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    /// 收下一条文本或二进制消息。对方关了连接抛错。
    func receive() async throws -> Data {
        while true {
            let (data, opcode) = try await receiveMessage()
            switch opcode {
            case .text, .binary: return data
            case .close: throw TrialFailure("服务器关闭了连接")
            default: continue
            }
        }
    }

    private func receiveMessage() async throws -> (Data, NWProtocolWebSocket.Opcode) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receiveMessage { content, context, _, error in
                if let error { return continuation.resume(throwing: error) }
                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                    as? NWProtocolWebSocket.Metadata
                guard let metadata else {
                    return continuation.resume(throwing: TrialFailure("服务器关闭了连接"))
                }
                continuation.resume(returning: (content ?? Data(), metadata.opcode))
            }
        }
    }

    func close() { connection.cancel() }

    /// 连接状态和超时谁先到谁返回，只返回一次。
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?

        init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }

        /// 返回这次是不是第一次（真的返回了）
        @discardableResult func resume(_ error: Error?) -> Bool {
            let pending: CheckedContinuation<Void, Error>? = lock.withLock {
                defer { continuation = nil }
                return continuation
            }
            guard let pending else { return false }
            if let error { pending.resume(throwing: error) } else { pending.resume() }
            return true
        }
    }
}

/// 拼 protobuf 的几个小工具（只写，字段都是长度前缀的）。
nonisolated enum TrialProto {
    static func varint(_ value: Int) -> Data {
        var value = UInt64(value)
        var out = Data()
        while value >= 0x80 {
            out.append(UInt8(value & 0x7f) | 0x80)
            value >>= 7
        }
        out.append(UInt8(value))
        return out
    }

    static func field(_ number: Int, _ bytes: Data) -> Data {
        message([varint(number << 3 | 2), varint(bytes.count), bytes])
    }

    /// 几个字段按顺序拼起来
    static func message(_ parts: [Data]) -> Data {
        var out = Data()
        for part in parts { out.append(part) }
        return out
    }

    static func field(_ number: Int, _ text: String) -> Data { field(number, Data(text.utf8)) }

    /// varint 字段
    static func number(_ number: Int, _ value: UInt64) -> Data {
        message([varint(number << 3), varint(Int(value))])
    }

    /// 读一条消息的字段：长度前缀的是 bytes，varint 是 number（别的类型跳过）。读不了抛错。
    static func read(_ data: Data) throws -> [(number: Int, bytes: Data?, value: UInt64?)] {
        let buffer = [UInt8](data)
        var i = 0
        func varint() throws -> UInt64 {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while i < buffer.count, shift < 64 {
                let byte = buffer[i]
                i += 1
                value |= UInt64(byte & 0x7f) << shift
                if byte < 0x80 { return value }
                shift += 7
            }
            throw TrialFailure("回复格式不对")
        }
        var fields: [(Int, Data?, UInt64?)] = []
        while i < buffer.count {
            let tag = try varint()
            let number = Int(tag >> 3)
            switch tag & 7 {
            case 0: fields.append((number, nil, try varint()))
            case 1: i += 8
            case 5: i += 4
            case 2:
                let count = Int(try varint())
                guard count >= 0, i + count <= buffer.count else { throw TrialFailure("回复格式不对") }
                fields.append((number, Data(buffer[i..<(i + count)]), nil))
                i += count
            default: throw TrialFailure("回复格式不对")
            }
            guard i <= buffer.count else { throw TrialFailure("回复格式不对") }
        }
        return fields
    }

    /// map<string, string> 的一项
    static func entry(_ number: Int, _ key: String, _ value: String) -> Data {
        field(number, message([field(1, key), field(2, value)]))
    }
}

/// Opus 编码（系统 AudioToolbox 自带，不用另带 libopus）：16 kHz 单声道 16 位，每 20 ms（320 点）出一个包。
nonisolated final class TrialOpus {
    private var converter: AudioConverterRef?
    private var maxPacket: UInt32 = 1500

    init(bitRate: UInt32) throws {
        var input = AudioStreamBasicDescription(
            mSampleRate: 16_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16,
            mReserved: 0)
        var output = AudioStreamBasicDescription(
            mSampleRate: 16_000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: 320, mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        guard AudioConverterNew(&input, &output, &converter) == noErr, let converter else {
            throw TrialFailure("Opus 编码器建不起来")
        }
        var rate = bitRate
        AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &rate)
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioConverterGetProperty(converter, kAudioConverterPropertyMaximumOutputPacketSize, &size, &maxPacket)
    }

    deinit { if let converter { AudioConverterDispose(converter) } }

    /// 编一帧（320 点）。正常是一个包。
    func encode(_ frame: [Int16]) -> [Data] {
        guard let converter else { return [] }
        let feed = Feed(frame)
        var out = [UInt8](repeating: 0, count: Int(maxPacket))
        var packets: [Data] = []
        while true {
            var count: UInt32 = 1
            var description = AudioStreamPacketDescription()
            let status = out.withUnsafeMutableBytes { raw -> OSStatus in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 1, mDataByteSize: maxPacket, mData: raw.baseAddress))
                return AudioConverterFillComplexBuffer(converter, { _, count, data, _, user in
                    let feed = Unmanaged<Feed>.fromOpaque(user!).takeUnretainedValue()
                    guard !feed.used else {
                        count.pointee = 0
                        return TrialOpus.drained
                    }
                    feed.used = true
                    count.pointee = UInt32(feed.samples.count)
                    feed.samples.withUnsafeMutableBytes { bytes in
                        data.pointee.mBuffers.mData = bytes.baseAddress
                        data.pointee.mBuffers.mDataByteSize = UInt32(bytes.count)
                    }
                    return noErr
                }, Unmanaged.passUnretained(feed).toOpaque(), &count, &list, &description)
            }
            if count > 0 {
                let start = Int(description.mStartOffset)
                packets.append(Data(out[start..<(start + Int(description.mDataByteSize))]))
            }
            if status != noErr || count == 0 { break }
        }
        return packets
    }

    /// 这一帧给完了（自己定的状态码，让编码器停下等下一帧）
    fileprivate static let drained: OSStatus = 100

    private final class Feed {
        var samples: [Int16]
        var used = false
        init(_ samples: [Int16]) { self.samples = samples }
    }
}
