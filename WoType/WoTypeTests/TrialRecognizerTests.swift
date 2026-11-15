//
//  TrialRecognizerTests.swift
//  WoTypeTests
//
//  识别方式的设置和体验渠道（docs/21）。不连网：只测消息怎么拼、服务器的回复怎么读。
//

import Foundation
import Testing
@testable import WoType

struct TrialRecognizerTests {

    @MainActor @Test func recognizerChoiceRoundTrips() throws {
        #expect(VoiceRecognizer(name: "local") == .local)
        #expect(VoiceRecognizer(name: "trial.qwen") == .trial(.qwen))
        #expect(VoiceRecognizer(name: "trial.doubao") == .trial(.doubao))
        #expect(VoiceRecognizer(name: "trial.wetype") == .trial(.wetype))
        #expect(VoiceRecognizer(name: "cloud.abc-123") == .cloud("abc-123"))
        #expect(VoiceRecognizer.cloud("abc-123").name == "cloud.abc-123")
        #expect(VoiceRecognizer(name: "cloud.") == .local)
        // 认不得的（以后删掉的渠道）读成本机
        #expect(VoiceRecognizer(name: "trial.gone") == .local)
        #expect(VoiceRecognizer(name: "") == .local)

        var config = Config()
        #expect(config.voiceRecognizer == .local)
        config.voiceRecognizer = .trial(.qwen)
        config.voiceTrialAccepted = ["qwen"]
        let decoded = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        #expect(decoded.voiceRecognizer == .trial(.qwen))
        #expect(decoded.voiceTrialAccepted == ["qwen"])
        // 老配置里没有这两项
        let old = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        #expect(old.voiceRecognizer == .local)
        #expect(old.voiceTrialAccepted.isEmpty)
    }

    @Test func protobufFieldsAreLengthPrefixed() {
        #expect(TrialProto.varint(1) == Data([1]))
        #expect(TrialProto.varint(300) == Data([0xac, 0x02]))
        // 字段 1、长度 2、"ab"
        #expect(TrialProto.field(1, "ab") == Data([0x0a, 2, 0x61, 0x62]))
        // map 的一项：字段 3，里面是 key（字段 1）和 value（字段 2）
        #expect(TrialProto.entry(3, "k", "v") == Data([0x1a, 6, 0x0a, 1, 0x6b, 0x12, 1, 0x76]))
        // 3840 字节的声音：长度要两个字节的 varint
        let audio = TrialProto.field(3, Data(count: 3840))
        #expect(audio.prefix(3) == Data([0x1a, 0x80, 0x1e]))
        #expect(audio.count == 3 + 3840)
    }

    @Test func qwenSignsEachConnection() throws {
        let device = QwenTrial.Device(utdid: "WT0123456789ABCDEF0123")
        let auth = try QwenTrial.Auth(device: device)
        #expect(auth.sign.hasPrefix("4ea4"))
        #expect(auth.sign.count == 4 + 40)  // HMAC-SHA1 是 20 字节
        // ut：4E A4 加 AES 的密文（22 字节明文补成 32）
        let ut = try #require(Data(base64Encoded: auth.ut))
        #expect(ut.prefix(2) == Data([0x4e, 0xa4]))
        #expect(ut.count == 2 + 32)
        #expect(auth.chid.hasSuffix("_1"))
        #expect(auth.url.host == "voice-input.qianwen.com")
        #expect(auth.headers.contains { $0.0 == "clt-acs-sign" && $0.1 == auth.sign })
        // 每次连接的 chid 不一样
        #expect(try QwenTrial.Auth(device: device).chid != auth.chid)
    }

    @Test func qwenReadsServerEvents() {
        let attach = QwenTrial.Event(Data("""
            {"route":"/voice_assistant/channel/attach","data":{"sessionId":"s1","roundId":"r1"}}
            """.utf8))
        #expect(attach.sessionID == "s1")
        #expect(attach.roundID == "r1")
        #expect(!attach.finished)

        let draft = QwenTrial.Event(Data("""
            {"route":"/voice_assistant/channel/asr","data":{"payload":[{"content":{"text":"明天下午"}}]}}
            """.utf8))
        #expect(draft.text == "明天下午")
        #expect(draft.sessionID == nil)

        let done = QwenTrial.Event(Data("""
            {"data":{"sessionId":"s1","newRoundId":"r2"}}
            """.utf8))
        #expect(done.finished)
        // 别的路由带的 sessionId 不当作 attach 的回复
        #expect(done.sessionID == nil)

        let junk = QwenTrial.Event(Data("not json".utf8))
        #expect(junk.text == nil && junk.sessionID == nil && !junk.finished)
    }

    @Test func protobufReadsBackWhatItWrites() throws {
        let message = TrialProto.message([
            TrialProto.field(4, "SessionFinished"),
            TrialProto.varint(5 << 3), TrialProto.varint(20_000_000),
            TrialProto.field(7, Data(count: 300)),
        ])
        let fields = try TrialProto.read(message)
        #expect(fields.map(\.number) == [4, 5, 7])
        #expect(fields[0].bytes == Data("SessionFinished".utf8))
        #expect(fields[1].value == 20_000_000)
        #expect(fields[2].bytes?.count == 300)
        // 截断的不能读
        #expect(throws: TrialFailure.self) { try TrialProto.read(message.prefix(message.count - 1)) }
    }

    @Test func doubaoRepliesAndRequests() throws {
        // 回复：4 事件、5 状态码、6 说明、7 结果
        let reply = try DoubaoTrial.Reply(TrialProto.message([
            TrialProto.field(4, "TaskStarted"), TrialProto.varint(5 << 3), TrialProto.varint(DoubaoTrial.statusOK),
            TrialProto.field(6, "OK"), TrialProto.field(7, "{}"),
        ]))
        #expect(reply.event == "TaskStarted")
        #expect(reply.status == DoubaoTrial.statusOK)
        #expect(reply.message == "OK")
        #expect(reply.result == "{}")

        // 声音：第一个包标 1、中间标 3、最后的空包标 9
        let link = DoubaoTrial.Link(socket: TrialSocket(url: URL(string: "wss://example.invalid/")!, headers: []),
                                    device: DoubaoTrial.Device(id: "1", phone: DoubaoTrial.Phone.all[0]),
                                    requestID: "r")
        func frame(_ data: Data) throws -> UInt64? { try TrialProto.read(data).first { $0.number == 9 }?.value }
        #expect(try frame(DoubaoTrial.audio(link, packet: Data([1]), index: 0, started: 0)) == DoubaoTrial.firstFrame)
        #expect(try frame(DoubaoTrial.audio(link, packet: Data([1]), index: 5, started: 0)) == DoubaoTrial.middleFrame)
        let last = try TrialProto.read(DoubaoTrial.audio(link, packet: nil, index: 6, started: 1000))
        #expect(last.first { $0.number == 9 }?.value == DoubaoTrial.lastFrame)
        #expect(!last.contains { $0.number == 7 })
        #expect(last.first { $0.number == 6 }?.bytes == Data("{\"extra\":{},\"timestamp_ms\":1120}".utf8))
        // 开始任务带密钥，声音不带
        #expect(try TrialProto.read(DoubaoTrial.finish(link)).contains { $0.number == 2 })
        #expect(try !TrialProto.read(DoubaoTrial.audio(link, packet: Data([1]), index: 1, started: 0)).contains { $0.number == 2 })
    }

    @Test func doubaoTranscriptUsesTheWholeTextFirst() {
        // 照 2026-11-14 抓的回复：第一项是整段文字，后面是拆开的部分和另一种写法
        var transcript = DoubaoTrial.Transcript()
        do { let changed = transcript.update(#"{"results":[{"text":"","is_interim":true}],"extra":{"vad_start":true}}"#); #expect(!changed) }
        do { let changed = transcript.update(#"{"results":[{"text":"明天下午 3","is_interim":true},{"text":"明天下午三","is_interim":true}]}"#); #expect(changed) }
        #expect(transcript.text == "明天下午 3")
        do { let changed = transcript.update(#"""
            {"results":[{"text":"第一点，回顾进度。第二点","is_interim":true},
            {"text":"第一点，回顾进度。","is_interim":true,"extra":{"nonstream_result":true}},{"text":"第二点","is_interim":true}]}
            """#); #expect(changed) }
        #expect(transcript.text == "第一点，回顾进度。第二点")
        // 结尾：最后一项是空的
        _ = transcript.update(#"""
            {"results":[{"text":"第一点，回顾进度。第二点，开发完成。","is_interim":false,"is_vad_finished":true},{"text":"","is_interim":true}]}
            """#)
        #expect(transcript.text == "第一点，回顾进度。第二点，开发完成。")
        // 没有结果、坏 JSON、空的第一项：不改
        do { let changed = transcript.update(#"{"results":null,"extra":{"heartbeat_num":3}}"#); #expect(!changed) }
        do { let changed = transcript.update("not json"); #expect(!changed) }
        do { let changed = transcript.update(#"{"results":[{"text":""},{"text":"别的"}]}"#); #expect(!changed) }
        #expect(transcript.text == "第一点，回顾进度。第二点，开发完成。")
    }

    @Test func doubaoTranscriptJoinsIndexedSentences() {
        // 带 index 的分句（抓的回复里没见过，防万一）：按 index 排，同一句后来的替换前面的
        var transcript = DoubaoTrial.Transcript()
        _ = transcript.update(#"{"results":[{"text":"第二句","index":1}]}"#)
        _ = transcript.update(#"{"results":[{"text":"第一","index":0}]}"#)
        _ = transcript.update(#"{"results":[{"text":"第一句。","index":0}]}"#)
        #expect(transcript.text == "第一句。第二句")
    }

    @Test func secp128r1MathIsRight() throws {
        // 曲线参数自洽：G 在曲线上，n·G 是无穷远点
        #expect(Secp128r1.isOnCurve(Secp128r1.g))
        #expect(Secp128r1.multiply(Secp128r1.n, Secp128r1.g) == nil)
        // 模乘、求逆对照 Python 大整数算的结果
        let x = try #require(U128(hex: "0123456789ABCDEF0FEDCBA987654321"))
        let y = try #require(U128(hex: "FFEEDDCCBBAA99887766554433221100"))
        #expect(Secp128r1.mul(x, y).hex == "D8F1BF6BAE38E11D594454EF85171AE1")
        #expect(Secp128r1.inverse(x).hex == "C365F882C62556E354C466BC2E526CF6")
        // ECDH：两边算出同一个共享密钥；公钥格式不对抛错
        let alice = Secp128r1.keyPair(), bob = Secp128r1.keyPair()
        #expect(alice.publicKey.count == 66 && alice.publicKey.hasPrefix("04"))
        let shared = try Secp128r1.sharedSecret(alice.secret, peer: bob.publicKey)
        #expect(shared == (try Secp128r1.sharedSecret(bob.secret, peer: alice.publicKey)))
        #expect(shared.count == 32)
        #expect(throws: TrialFailure.self) { try Secp128r1.sharedSecret(alice.secret, peer: "04" + String(repeating: "1", count: 64)) }
    }

    @Test func weTypeCompressionAndCrypto() throws {
        let raw = Data((0..<500).map { UInt8($0 % 7) })
        #expect(try WeTypeCrypto.snappyDecompress(WeTypeCrypto.snappyCompress(raw)) == raw)
        // 字面量「abcd」再从 4 字节前复制 8 字节（和自己重叠）
        let copied = try WeTypeCrypto.snappyDecompress(Data([12, 3 << 2, 0x61, 0x62, 0x63, 0x64, 0x01 | (4 << 2), 4]))
        #expect(String(decoding: copied, as: UTF8.self) == "abcdabcdabcd")
        #expect(throws: TrialFailure.self) { try WeTypeCrypto.snappyDecompress(Data([12, 0x01 | (4 << 2), 4])) }
        let key = WeTypeTrial.bootKey
        let sealed = try WeTypeCrypto.encrypt(Data("微信".utf8), key: key)
        #expect(sealed.count == 16)
        #expect(try WeTypeCrypto.decrypt(sealed, key: key) == Data("微信".utf8))
        #expect(WeTypeCrypto.md5(Data()) == "D41D8CD98F00B204E9800998ECF8427E")
    }

    @Test func weTypeReadsResponses() throws {
        // 回复：4 是 HTTP 回复，里面 2 状态码、5 正文，别的长度前缀字段是头（key、value）
        let header = TrialProto.field(3, TrialProto.message([TrialProto.field(1, "Kb-CompressionType"), TrialProto.field(2, "2")]))
        let http = TrialProto.message([TrialProto.number(2, 200), header, TrialProto.field(5, Data([1, 2, 3]))])
        let response = try WeTypeTrial.Response(TrialProto.message([TrialProto.number(1, 0), TrialProto.field(4, http)]))
        #expect(response.status == 200)
        #expect(response.headers["Kb-CompressionType"] == "2")
        #expect(response.body == Data([1, 2, 3]))
        #expect(throws: TrialFailure.self) { try WeTypeTrial.Response(TrialProto.number(1, 0)) }
    }

    @MainActor @Test func cloudSpeechSettingsRoundTrip() throws {
        var config = Config()
        config.cloudSpeechModels = [CloudSpeechModel(id: "a", provider: .xai, model: "grok-voice-transcribe-2.0")]
        config.voiceRecognizer = .cloud("a")
        let decoded = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        #expect(decoded.cloudSpeechModels == config.cloudSpeechModels)
        #expect(decoded.voiceRecognizer == .cloud("a"))
        #expect(config.cloudSpeechModels[0].title == "xAI · grok-voice-transcribe-2.0")
        // 不再支持的服务商（试过又没接的 DeepSeek）只丢那一项
        let old = #"{"cloudSpeechModels":[{"id":"d","provider":"deepseek","model":"asr"},{"id":"a","provider":"xai","model":"grok-voice-transcribe-2.0"}]}"#
        let migrated = try JSONDecoder().decode(Config.self, from: Data(old.utf8))
        #expect(migrated.cloudSpeechModels.map(\.id) == ["a"])
        // 语言：默认中文；老配置里没有 language 的按中文；空的是自动识别
        #expect(config.cloudSpeechModels[0].language == "zh")
        let noLanguage = #"{"cloudSpeechModels":[{"id":"a","provider":"xai","model":"grok-voice-transcribe-2.0"}]}"#
        #expect(try JSONDecoder().decode(Config.self, from: Data(noLanguage.utf8)).cloudSpeechModels[0].language == "zh")
        var automatic = config.cloudSpeechModels[0]
        automatic.language = ""
        #expect(automatic.spokenLanguage == .automatic)
        // xAI 密钥不对回 400
        #expect(CloudSpeechFailure.status(400, provider: .xai).message.contains("密钥"))
        #expect(CloudSpeechFailure.status(401, provider: .xai).message.contains("密钥"))
        #expect(CloudSpeechFailure.status(429, provider: .xai).message.contains("稍后再试"))
    }

    @Test func xaiReadsEvents() {
        let created = XAIRecognizer.Event(Data(#"{"type":"transcript.created","id":"83f2"}"#.utf8))
        #expect(created.type == "transcript.created")
        let partial = XAIRecognizer.Event(Data(#"{"type":"transcript.partial","text":"明天下午","words":[],"is_final":false,"speech_final":false,"start":0,"duration":1.2}"#.utf8))
        #expect(partial.type == "transcript.partial" && partial.text == "明天下午" && !partial.isFinal)
        let locked = XAIRecognizer.Event(Data(#"{"type":"transcript.partial","text":"明天下午三点开会","is_final":true}"#.utf8))
        #expect(locked.isFinal)
        let failure = XAIRecognizer.Event(Data(#"{"type":"error","message":"stream timeout"}"#.utf8))
        #expect(failure.type == "error" && failure.message == "stream timeout")
        let nested = XAIRecognizer.Event(Data(#"{"type":"error","error":{"message":"bad audio"}}"#.utf8))
        #expect(nested.message == "bad audio")
    }

    @Test func xaiLanguageParameters() {
        func query(_ url: URL) -> [String: String] {
            Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .map { ($0.name, $0.value ?? "") })
        }
        let languages = CloudSpeechLanguage.xai
        let chinese = query(XAIRecognizer.url(model: "m", language: languages.first { $0.code == "zh" }!))
        #expect(chinese["language"] == "zh" && chinese["format"] == "true")
        // 不能写数字的语言只传 language
        let korean = query(XAIRecognizer.url(model: "m", language: languages.first { $0.code == "ko" }!))
        #expect(korean["language"] == "ko" && korean["format"] == nil)
        // 自动识别都不传
        let automatic = query(XAIRecognizer.url(model: "m", language: .automatic))
        #expect(automatic["language"] == nil && automatic["format"] == nil)
        #expect(automatic["sample_rate"] == "16000" && automatic["model"] == "m")
        // 能写数字的正好是文档里那 11 种，代码不重复
        #expect(Set(languages.filter(\.formats).map(\.code)) == ["ar", "zh", "en", "fr", "de", "ja", "pt", "ru", "es", "sv", "vi"])
        #expect(Set(languages.map(\.code)).count == languages.count && languages.count == 38)
    }

    @Test func xaiDraftDropsTrailingEllipsis() {
        // 没定的草稿结尾带「...」，下一次就没了：不显示，免得浮窗结尾一缩一伸
        #expect(XAIRecognizer.trimEllipsis("到了以后先去酒店放...") == "到了以后先去酒店放")
        #expect(XAIRecognizer.trimEllipsis("先去酒店放…") == "先去酒店放")
        #expect(XAIRecognizer.trimEllipsis("我们出发 ...") == "我们出发")
        #expect(XAIRecognizer.trimEllipsis("明天下午三点开会。") == "明天下午三点开会。")
        #expect(XAIRecognizer.trimEllipsis("...") == "")
    }

    @Test func xaiKeepsUnlockedTailOfDraft() {
        // 定下来的是正在说的这段的前一部分：后面的先留着
        #expect(XAIRecognizer.remainder(of: "集合，坐大", after: "集") == "合，坐大")
        #expect(XAIRecognizer.remainder(of: "到了以后先去酒店放行李，下午两点", after: "到了以后先去酒店放行李，") == "下午两点")
        // 标点不一样也对得上
        #expect(XAIRecognizer.remainder(of: "通知大家周三", after: "通知大家。") == "周三")
        // 整段都定了、或者写法改了：没有剩下的
        #expect(XAIRecognizer.remainder(of: "大概开到五点", after: "大概开到五点。") == "")
        #expect(XAIRecognizer.remainder(of: "大巴去机场", after: "我们周二早上八点在公司门口集合，坐大巴去机场") == "")
    }
}
