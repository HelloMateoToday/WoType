// ProviderTests.swift — 各家：请求怎么拼（签名、参数）、真实回包怎么解析、出错怎么分类。不联网。

import XCTest
@testable import FreeTranslate

final class LanguageTests: XCTestCase {
    func testChineseCodesNormalize() {
        XCTAssertEqual(Language("zh").code, "zh-Hans")
        XCTAssertEqual(Language("zh-CN").code, "zh-Hans")
        XCTAssertEqual(Language("zh_SG").code, "zh-Hans")
        XCTAssertEqual(Language("zh-TW").code, "zh-Hant")
        XCTAssertEqual(Language("zh-Hant-HK").code, "zh-Hant")
        XCTAssertEqual(Language("EN").code, "en")
        XCTAssertEqual(Language.english.nativeName, "English")
        XCTAssertEqual(Language.japanese.chineseName, "日语")
    }

    func testTranslationTargets() {
        XCTAssertEqual(Language.translationTargets.count, 16)
        XCTAssertEqual(Language.translationTargets.first, .english)
        XCTAssertEqual(Language("pt-BR").code, "pt-BR")
        XCTAssertEqual(Language("pt-BR").baseCode, "pt")
        XCTAssertEqual(Language.traditionalChinese.baseCode, "zh-Hant")
        XCTAssertNotNil(Language.brazilianPortuguese.nativeName)
        XCTAssertEqual(Language.brazilianPortuguese.chineseName, "葡萄牙语（巴西）")
        // 每个目标都有显示名（设置界面、B站要用）
        for language in Language.translationTargets {
            XCTAssertNotNil(language.chineseName, language.code)
            XCTAssertNotNil(language.nativeName, language.code)
        }
    }

    func testBrazilianPortugueseCodes() throws {
        XCTAssertEqual(MicrosoftProvider.code(.brazilianPortuguese), "pt")
        XCTAssertEqual(GoogleProvider.code(.brazilianPortuguese), "pt")
        XCTAssertEqual(TransmartProvider.code(.brazilianPortuguese, target: true), "pt")
        XCTAssertEqual(VolcengineProvider.code(.brazilianPortuguese, target: true), "pt")
        XCTAssertTrue(BilibiliProvider().supports(from: nil, to: .brazilianPortuguese))
    }

    func testGuessLanguage() {
        XCTAssertEqual(guessLanguage("我很赞同"), .simplifiedChinese)
        XCTAssertEqual(guessLanguage("今日はいい天気"), .japanese)
        XCTAssertEqual(guessLanguage("안녕하세요"), .korean)
        XCTAssertNil(guessLanguage("Hello world"))
    }
}

final class CryptoTests: XCTestCase {
    func testMD5() {
        XCTAssertEqual(md5Hex("abc"), "900150983cd24fb0d6963f7d28e17f72")
    }

    /// 期望值用 openssl enc -aes-128-ecb 算的
    func testIcibaSignMatchesOpenSSL() {
        XCTAssertEqual(IcibaProvider.sign("我很赞同你的意见"), "FMBdTEkxXlfHUyM//aSoLtRriqVIAJSQ+xmfU0q7dIE=")
    }

    func testAESDecryptMatchesOpenSSL() throws {
        let encrypted = try XCTUnwrap(Data(base64Encoded: "WiDzvY0oMH/2S/HAqKxD3lZ4GxvijkcxrGaNTam0+hFLEbEJBsEMV7K2CGbQEks7"))
        let plain = try XCTUnwrap(aesECB(encrypted, key: IcibaProvider.responseKey, encrypt: false))
        XCTAssertEqual(String(decoding: plain, as: UTF8.self), #"{"err_no":0,"out":"I agree with you"}"#)
    }

    func testHTMLEntities() {
        XCTAssertEqual(escapeHTML(#"a<b>&"c"'d"#), "a&lt;b&gt;&amp;&quot;c&quot;&#39;d")
        XCTAssertEqual(decodeHTML("a&lt;b&gt;&amp;lt;&#39;&#x4E2D;"), "a<b>&lt;'中")
    }
}

final class MicrosoftTests: XCTestCase {
    func testRequest() throws {
        let request = try MicrosoftProvider().request(["a<b", "你好"], from: nil, to: .simplifiedChinese)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString,
                       "https://edge.microsoft.com/translate/translatetext?from=&to=zh-Hans&isEnterpriseClient=false")
        XCTAssertEqual(request.bodyJSON as? [String], ["a&lt;b", "你好"])
    }

    func testParseRealResponse() throws {
        XCTAssertEqual(try MicrosoftProvider().parse(fixture("microsoft.json"), count: 1), ["I completely agree with your opinion"])
    }

    func testWrongCountIsInvalid() {
        XCTAssertThrowsError(try MicrosoftProvider().parse(fixture("microsoft.json"), count: 2))
    }

    func testBatchesAtThirtyTwo() async throws {
        let http = FakeHTTP { request, _ in
            let count = (request.bodyJSON as? [String])?.count ?? 0
            let items = Array(repeating: #"{"translations":[{"text":"x"}]}"#, count: count).joined(separator: ",")
            return response("[\(items)]")
        }
        let result = try await MicrosoftProvider().translate(Array(repeating: "你好", count: 40), from: nil, to: .english, http: http)
        XCTAssertEqual(result.count, 40)
        XCTAssertEqual(http.requests.count, 2)
    }
}

final class WebProviderTests: XCTestCase {
    func testTransmartRequestAndResponse() throws {
        let request = try TransmartProvider().request("我很赞同", from: nil, to: .traditionalChinese)
        let body = try XCTUnwrap(request.bodyJSON as? [String: Any])
        XCTAssertEqual((body["source"] as? [String: Any])?["lang"] as? String, "auto")
        XCTAssertEqual((body["target"] as? [String: Any])?["lang"] as? String, "zh-tw")
        let header = try XCTUnwrap(body["header"] as? [String: Any])
        XCTAssertEqual(header["fn"] as? String, "auto_translation")
        XCTAssertTrue((header["client_key"] as? String)?.hasPrefix("browser-chrome-110.0.0-Mac OS-") == true)
        XCTAssertEqual(try TransmartProvider().parse(fixture("transmart.json")), "I agree with you.")
    }

    func testTransmartHindiUnsupported() {
        XCTAssertFalse(TransmartProvider().supports(from: nil, to: .hindi))
        XCTAssertThrowsError(try TransmartProvider().parse(response(#"{"header":{"ret_code":"Unsupported-Language"}}"#))) { error in
            XCTAssertEqual(error as? TranslationError, .unsupported)
        }
    }

    func testTransmartAuthFailedIsBlocked() {
        XCTAssertThrowsError(try TransmartProvider().parse(response(#"{"header":{"ret_code":"Auth-Failed"}}"#))) { error in
            guard case TranslationError.blocked = error else { return XCTFail("\(error)") }
        }
    }

    func testVolcengineGuessesSourceForChinese() throws {
        // 火山的 auto 识别出中文就原样返回：有汉字时要明确写 zh
        let chinese = try XCTUnwrap(try VolcengineProvider().request("我很赞同", from: nil, to: .english).bodyJSON as? [String: Any])
        XCTAssertEqual(chinese["source_language"] as? String, "zh")
        let english = try XCTUnwrap(try VolcengineProvider().request("Hello", from: nil, to: .simplifiedChinese).bodyJSON as? [String: Any])
        XCTAssertEqual(english["source_language"] as? String, "auto")
        XCTAssertEqual(english["target_language"] as? String, "zh")
        XCTAssertEqual(try VolcengineProvider().parse(fixture("volcengine.json")), "I do agree with you.")
    }

    func testVolcengineBadStatus() {
        XCTAssertThrowsError(try VolcengineProvider().parse(response(#"{"base_resp":{"status_code":1}}"#)))
    }
}

final class ChineseWebProviderTests: XCTestCase {
    func testYoudaoSignAndTimestamp() {
        // 期望值用 Python hashlib 算的
        XCTAssertEqual(YoudaoProvider.sign("我很赞同你的意见", timestamp: "1700000000005"), "b79b229de446f7caac19667bc4cb8f49")
        let provider = YoudaoProvider(clock: { Date(timeIntervalSince1970: 1_700_000_000) })
        XCTAssertEqual(provider.timestamp("我很赞同你的意见"), "1700000000004")
    }

    func testYoudaoRequest() throws {
        let provider = YoudaoProvider(clock: { Date(timeIntervalSince1970: 1_700_000_000) })
        let request = try provider.request("我很赞同你的意见", from: nil, to: .english)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.field("q"), "我很赞同你的意见")
        XCTAssertEqual(request.field("from"), "zh-CHS")
        XCTAssertEqual(request.field("to"), "en")
        XCTAssertEqual(request.field("t"), "1700000000004")
        XCTAssertEqual(request.field("sign"), YoudaoProvider.sign("我很赞同你的意见", timestamp: "1700000000004"))
        XCTAssertEqual(request.field("keyfrom"), "webfanyi.webmain")
    }

    func testYoudaoOnlyChineseEnglish() {
        XCTAssertTrue(YoudaoProvider().supports(from: nil, to: .english))
        XCTAssertTrue(YoudaoProvider().supports(from: .english, to: .simplifiedChinese))
        XCTAssertFalse(YoudaoProvider().supports(from: nil, to: .japanese))
        XCTAssertFalse(YoudaoProvider().supports(from: .simplifiedChinese, to: .traditionalChinese))
    }

    func testYoudaoParse() throws {
        XCTAssertEqual(try YoudaoProvider().parse(fixture("youdao.json"), direction: ("zh-CHS", "en")), "I quite agree with you")
        // 方向反了
        XCTAssertThrowsError(try YoudaoProvider().parse(fixture("youdao.json"), direction: ("en", "zh-CHS")))
    }

    func testIcibaRequestAndRealResponse() throws {
        let request = try IcibaProvider().request("我很赞同你的意见", from: nil, to: .english)
        XCTAssertEqual(request.field("from"), "zh")
        XCTAssertEqual(request.field("to"), "en")
        XCTAssertEqual(request.field("client"), "6")
        XCTAssertEqual(request.field("auth_user"), "key_web_new_fanyi")
        XCTAssertEqual(request.field("sign"), "FMBdTEkxXlfHUyM//aSoLtRriqVIAJSQ+xmfU0q7dIE=")
        XCTAssertEqual(try IcibaProvider().parse(fixture("iciba.json")), "I strongly agree with your opinion.")
    }

    func testIcibaBusinessErrors() throws {
        func encrypted(_ json: String) -> HTTPResponse {
            let content = aesECB(Data(json.utf8), key: IcibaProvider.responseKey, encrypt: true)!.base64EncodedString()
            return response(#"{"status":1,"content":"\#(content)"}"#)
        }
        XCTAssertThrowsError(try IcibaProvider().parse(encrypted(#"{"err_no":429}"#))) { error in
            guard case TranslationError.rateLimited = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try IcibaProvider().parse(encrypted(#"{"err_no":402}"#))) { error in
            guard case TranslationError.quota = error else { return XCTFail("\(error)") }
        }
    }
}

final class BilibiliTests: XCTestCase {
    func testRequest() throws {
        let body = try XCTUnwrap(try BilibiliProvider().request("我很赞同", from: nil, to: .english).bodyJSON as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "Index-Translate-35B-A3B")
        XCTAssertEqual(body["stream"] as? Bool, false)
        let content = try XCTUnwrap(((body["messages"] as? [[String: Any]])?.first)?["content"] as? String)
        XCTAssertTrue(content.hasPrefix("请将以下文本翻译为English"))
        XCTAssertTrue(content.hasSuffix("\n\n我很赞同"))
    }

    func testParse() throws {
        XCTAssertFalse(try BilibiliProvider().parse(fixture("bilibili.json")).isEmpty)
        XCTAssertEqual(try BilibiliProvider().parse(response(
            #"{"choices":[{"finish_reason":"stop","message":{"content":"<think>x</think> Hello "}}]}"#)), "Hello")
        XCTAssertThrowsError(try BilibiliProvider().parse(response(
            #"{"choices":[{"finish_reason":"length","message":{"content":"Hel"}}]}"#)))
        XCTAssertThrowsError(try BilibiliProvider().parse(response(
            #"{"choices":[{"finish_reason":"stop","message":{"content":"<think>never closed"}}]}"#)))
    }

    func testSupportsNamedLanguagesOnly() {
        XCTAssertTrue(BilibiliProvider().supports(from: nil, to: .japanese))
        XCTAssertFalse(BilibiliProvider().supports(from: nil, to: Language("sw")))
    }
}

final class GoogleTests: XCTestCase {
    func testParseRealResponses() throws {
        let google = GoogleProvider()
        XCTAssertEqual(try google.parse(.list, fixture("google_list.json"), count: 1), ["I very much agree with your opinion"])
        XCTAssertEqual(try google.parse(.html, fixture("google_html.json"), count: 1), ["I agree with your opinion."])
        XCTAssertEqual(try google.parse(.batchPrimary, fixture("google_batch.txt"), count: 1), ["I very much agree with your opinion"])
    }

    func testHTMLRequest() throws {
        let request = try GoogleProvider().request(.html, ["a<b"], from: nil, to: .simplifiedChinese)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Goog-API-Key"), GoogleProvider.browserKey)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json+protobuf")
        let body = try XCTUnwrap(request.bodyJSON as? [Any])
        let first = try XCTUnwrap(body.first as? [Any])
        XCTAssertEqual(first[0] as? [String], ["<pre>a&lt;b</pre>"])
        XCTAssertEqual(first[1] as? String, "auto")
        XCTAssertEqual(first[2] as? String, "zh-CN")
    }

    func testFallsBackToNextEndpoint() async throws {
        let http = FakeHTTP([response("oops", status: 500), fixture("google_list.json")])
        let result = try await GoogleProvider().translate(["我很赞同你的意见"], from: nil, to: .english, http: http)
        XCTAssertEqual(result, ["I very much agree with your opinion"])
        XCTAssertEqual(http.requests.count, 2)
        XCTAssertTrue(http.requests[1].url!.absoluteString.hasPrefix(GoogleProvider.listEndpoint))
    }

    func testCaptchaPageIsBlocked() {
        XCTAssertThrowsError(try GoogleProvider().parse(.list, response("<!DOCTYPE html><html>captcha</html>"), count: 1)) { error in
            guard case TranslationError.blocked = error else { return XCTFail("\(error)") }
        }
    }
}

final class TextChunkTests: XCTestCase {
    func testSplitPrefersSentenceEnds() {
        let line = "第一句话写在这里。第二句话也写在这里。第三句。"
        let pieces = TextChunks.split(line, limit: 12)
        XCTAssertEqual(pieces, ["第一句话写在这里。", "第二句话也写在这里。", "第三句。"])
    }

    func testKeepsNewlinesAndBlankLines() async throws {
        let translated = try await TextChunks.translate("  你好\n\n世界  ", limit: 100) { "<\($0)>" }
        XCTAssertEqual(translated, "  <你好>\n\n<世界>  ")
    }

    func testHTTPErrorClassification() {
        XCTAssertEqual(TranslationError.http(429, retryAfter: 9), .rateLimited(retryAfter: 9))
        if case .quota = TranslationError.http(456) {} else { XCTFail() }
        if case .blocked = TranslationError.http(403) {} else { XCTFail() }
        if case .request = TranslationError.http(400) {} else { XCTFail() }
        if case .unavailable = TranslationError.http(503) {} else { XCTFail() }
        if case .unavailable = TranslationError.http(408) {} else { XCTFail() }
    }
}
