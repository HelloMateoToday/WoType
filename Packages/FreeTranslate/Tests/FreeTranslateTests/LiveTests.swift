// LiveTests.swift — 联网测试：每家真的翻一句。默认跳过，FREE_TRANSLATE_LIVE=1 swift test 才跑。
// 谷歌在国内要代理（走系统代理）。某家接口改了、被封了，这里会先发现。

import XCTest
@testable import FreeTranslate

final class LiveTests: XCTestCase {

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FREE_TRANSLATE_LIVE"] == "1", "设 FREE_TRANSLATE_LIVE=1 才联网测")
    }

    private let http = URLSessionHTTPClient(timeout: 15)

    private func check(_ provider: TranslationProvider) async throws {
        let toEnglish = try await provider.translate(["我很赞同你的意见"], from: nil, to: .english, http: http)
        XCTAssertTrue(toEnglish[0].range(of: "agree", options: .caseInsensitive) != nil, "\(provider.name)：\(toEnglish[0])")
        let toChinese = try await provider.translate(["The weather is nice today."], from: nil, to: .simplifiedChinese, http: http)
        XCTAssertTrue(containsHan(toChinese[0]), "\(provider.name)：\(toChinese[0])")
    }

    func testMicrosoft() async throws { try await check(MicrosoftProvider()) }
    func testTransmart() async throws { try await check(TransmartProvider()) }
    func testVolcengine() async throws { try await check(VolcengineProvider()) }
    func testYoudao() async throws { try await check(YoudaoProvider()) }
    func testIciba() async throws { try await check(IcibaProvider()) }
    func testBilibili() async throws { try await check(BilibiliProvider()) }
    func testGoogle() async throws { try await check(GoogleProvider()) }

    /// 默认目标是英语，也要能翻成别的语言
    func testOtherTargetLanguages() async throws {
        let pool = TranslationPool(http: http)
        let japanese = try await pool.translate("我很赞同你的意见", to: .japanese)
        XCTAssertTrue(guessLanguage(japanese.text) == .japanese || containsHan(japanese.text), "日语：\(japanese.text)")
        let french = try await pool.translate("我很赞同你的意见", to: .french)
        XCTAssertFalse(containsHan(french.text), "法语：\(french.text)")
        let traditional = try await pool.translate("I agree with you.", to: .traditionalChinese)
        XCTAssertTrue(containsHan(traditional.text), "繁体：\(traditional.text)")
    }

    func testLongTextIsChunked() async throws {
        let paragraph = String(repeating: "今天天气很好，我们一起去公园散步。", count: 40)  // 约 680 字，有道要切块
        let result = try await YoudaoProvider().translate([paragraph], from: nil, to: .english, http: http)
        XCTAssertGreaterThan(result[0].count, 500)
    }
}
