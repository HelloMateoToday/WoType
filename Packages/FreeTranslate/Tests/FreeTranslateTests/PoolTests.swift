// PoolTests.swift — 备选池：按权重挑、失败换家、冷却、结果检查、缓存、超时。用假的翻译服务，不联网。

import XCTest
@testable import FreeTranslate

final class PoolTests: XCTestCase {

    private func pool(_ providers: [TranslationProvider], weights: [String: Double] = [:], attemptTimeout: TimeInterval = 5,
                      now: @escaping @Sendable () -> Date = { Date() }) -> TranslationPool {
        TranslationPool(providers: providers,
                        configuration: .init(weights: weights, attemptTimeout: attemptTimeout, totalTimeout: 10),
                        http: FakeHTTP([response("")]), now: now, random: { 0.5 })
    }

    func testHigherWeightGoesFirst() async throws {
        let a = FakeProvider("a") { $0.map { "A:\($0)" } }
        let b = FakeProvider("b") { $0.map { "B:\($0)" } }
        let result = try await pool([a, b], weights: ["a": 1, "b": 5]).translate("你好", to: .english)
        XCTAssertEqual(result, Translation(text: "B:你好", provider: "b"))
    }

    func testFallsBackAndCoolsDown() async throws {
        let calls = Counter()
        let broken = FakeProvider("broken") { _ in
            calls.increment()
            throw TranslationError.unavailable(message: "down")
        }
        let working = FakeProvider("working") { $0.map { "ok:\($0)" } }
        let pool = pool([broken, working], weights: ["broken": 5, "working": 1])
        let first = try await pool.translate("一", to: .english)
        XCTAssertEqual(first.provider, "working")
        // broken 冷却中，第二次不再试它
        let second = try await pool.translate("二", to: .english)
        XCTAssertEqual(second.provider, "working")
        XCTAssertEqual(calls.count, 1)
        let status = await pool.status().first { $0.id == "broken" }
        XCTAssertNotNil(status?.cooldownUntil)
        XCTAssertNotNil(status?.lastFailure)
    }

    func testRequestErrorDoesNotCoolDown() async throws {
        let calls = Counter()
        let picky = FakeProvider("picky") { texts in
            calls.increment()
            if texts == ["坏"] { throw TranslationError.request(status: 400, message: "bad text") }
            return texts.map { "p:\($0)" }
        }
        let backup = FakeProvider("backup") { $0.map { "b:\($0)" } }
        let pool = pool([picky, backup], weights: ["picky": 5, "backup": 1])
        let bad = try await pool.translate("坏", to: .english)
        XCTAssertEqual(bad.provider, "backup")
        let good = try await pool.translate("好", to: .english)
        XCTAssertEqual(good.provider, "picky")
        XCTAssertEqual(calls.count, 2)
    }

    func testEchoedChineseIsRejected() async throws {
        let echo = FakeProvider("echo") { $0 }
        let real = FakeProvider("real") { $0.map { _ in "translated" } }
        let result = try await pool([echo, real], weights: ["echo": 5, "real": 1]).translate("我很赞同", to: .english)
        XCTAssertEqual(result.provider, "real")
    }

    func testRateLimitUsesRetryAfter() async throws {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let limited = FakeProvider("limited") { _ in throw TranslationError.rateLimited(retryAfter: 100) }
        let other = FakeProvider("other") { $0.map { "o:\($0)" } }
        let pool = pool([limited, other], weights: ["limited": 5, "other": 1], now: { start })
        _ = try await pool.translate("你好", to: .english)
        let until = await pool.status().first { $0.id == "limited" }?.cooldownUntil
        // 100 秒加最多 20% 抖动（random 固定 0.5 → 110 秒）
        XCTAssertEqual(until?.timeIntervalSince(start) ?? 0, 110, accuracy: 0.001)
    }

    func testCacheAvoidsSecondRequest() async throws {
        let calls = Counter()
        let provider = FakeProvider("p") { texts in
            calls.increment()
            return texts.map { "t:\($0)" }
        }
        let pool = pool([provider])
        _ = try await pool.translate("你好", to: .english)
        let again = try await pool.translate(["你好", "世界"], to: .english)
        XCTAssertEqual(again.map(\.text), ["t:你好", "t:世界"])
        XCTAssertEqual(calls.count, 2)  // 第二次只翻了「世界」
    }

    func testSlowProviderTimesOut() async throws {
        let slow = FakeProvider("slow") { texts in
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return texts
        }
        let fast = FakeProvider("fast") { $0.map { "f:\($0)" } }
        let started = Date()
        let result = try await pool([slow, fast], weights: ["slow": 5, "fast": 1], attemptTimeout: 0.2).translate("你好", to: .english)
        XCTAssertEqual(result.provider, "fast")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    func testUnsupportedDirection() async {
        let onlyEnglish = FakeProvider("en", supported: { _, to in to == .english }) { $0 }
        do {
            _ = try await pool([onlyEnglish]).translate("你好", to: .japanese)
            XCTFail("应该不支持")
        } catch {
            XCTAssertEqual(error as? TranslationError, .unsupported)
        }
    }

    func testAllFailedListsEachProvider() async {
        let a = FakeProvider("a") { _ in throw TranslationError.unavailable(message: "x") }
        let b = FakeProvider("b") { _ in throw TranslationError.blocked(status: 403, message: "y") }
        do {
            _ = try await pool([a, b]).translate("你好", to: .english)
            XCTFail("应该全部失败")
        } catch TranslationError.allFailed(let failures) {
            XCTAssertEqual(Set(failures.keys), ["a", "b"])
        } catch {
            XCTFail("\(error)")
        }
    }

    func testBlankTextSkipsProviders() async throws {
        let calls = Counter()
        let provider = FakeProvider("p") { texts in
            calls.increment()
            return texts
        }
        let result = try await pool([provider]).translate("   ", to: .english)
        XCTAssertEqual(result.text, "   ")
        XCTAssertEqual(calls.count, 0)
    }
}
