//
//  WeTypeCrypto.swift
//  WoType
//
//  微信输入法体验渠道用到的加密和压缩（docs/21）：secp128r1 的 ECDH、AES-256-ECB、snappy、MD5 / SHA-256。
//  系统库不带 secp128r1；Swift 的 UInt128 要 macOS 15，WoType 支持 14，所以 128 位运算自己写（U128）。
//

import CommonCrypto
import CryptoKit
import Foundation

// MARK: - 128 位无符号整数

nonisolated struct U128: Comparable, Sendable {
    var hi: UInt64
    var lo: UInt64

    init(_ hi: UInt64, _ lo: UInt64) {
        self.hi = hi
        self.lo = lo
    }

    init(_ value: UInt64) { self.init(0, value) }

    /// 最多 32 位十六进制
    init?<S: StringProtocol>(hex: S) {
        guard !hex.isEmpty, hex.count <= 32 else { return nil }
        let padded = String(repeating: "0", count: 32 - hex.count) + hex
        guard let hi = UInt64(padded.prefix(16), radix: 16), let lo = UInt64(padded.suffix(16), radix: 16) else { return nil }
        self.init(hi, lo)
    }

    /// 32 位大写十六进制
    var hex: String { Self.hex64(hi) + Self.hex64(lo) }

    private static func hex64(_ value: UInt64) -> String {
        let digits = String(value, radix: 16, uppercase: true)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }

    var isZero: Bool { hi == 0 && lo == 0 }

    func bit(_ index: Int) -> Bool { index < 64 ? (lo >> index) & 1 == 1 : (hi >> (index - 64)) & 1 == 1 }

    static func < (a: U128, b: U128) -> Bool { a.hi != b.hi ? a.hi < b.hi : a.lo < b.lo }

    /// 和，有没有溢出
    func adding(_ other: U128) -> (U128, overflow: Bool) {
        let (lo, carry) = lo.addingReportingOverflow(other.lo)
        let (hi1, o1) = hi.addingReportingOverflow(other.hi)
        let (hi2, o2) = hi1.addingReportingOverflow(carry ? 1 : 0)
        return (U128(hi2, lo), o1 || o2)
    }

    /// 差（小减大时绕回）
    func subtracting(_ other: U128) -> U128 {
        let (lo, borrow) = lo.subtractingReportingOverflow(other.lo)
        return U128(hi &- other.hi &- (borrow ? 1 : 0), lo)
    }

    /// 完整的 256 位积
    func multipliedFullWidth(by other: U128) -> (high: U128, low: U128) {
        let p00 = lo.multipliedFullWidth(by: other.lo)
        let p01 = lo.multipliedFullWidth(by: other.hi)
        let p10 = hi.multipliedFullWidth(by: other.lo)
        let p11 = hi.multipliedFullWidth(by: other.hi)
        // 第 1 个 64 位：p00 高位 + p01 低位 + p10 低位
        var carry1: UInt64 = 0
        var w1 = p00.high
        (w1, carry1) = Self.add(w1, p01.low, carry1)
        (w1, carry1) = Self.add(w1, p10.low, carry1)
        // 第 2 个：p01 高位 + p10 高位 + p11 低位 + 进位
        var carry2: UInt64 = 0
        var w2 = carry1
        (w2, carry2) = Self.add(w2, p01.high, carry2)
        (w2, carry2) = Self.add(w2, p10.high, carry2)
        (w2, carry2) = Self.add(w2, p11.low, carry2)
        let w3 = p11.high &+ carry2
        return (U128(w3, w2), U128(w1, p00.low))
    }

    private static func add(_ a: UInt64, _ b: UInt64, _ carry: UInt64) -> (UInt64, UInt64) {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return (sum, carry + (overflow ? 1 : 0))
    }

    /// [1, upper) 里随机一个
    static func random(below upper: U128) -> U128 {
        while true {
            let value = U128(UInt64.random(in: 0...UInt64.max), UInt64.random(in: 0...UInt64.max))
            if !value.isZero, value < upper { return value }
        }
    }
}

// MARK: - secp128r1

/// secp128r1（SEC 2）上的 ECDH。点是仿射坐标，nil 是无穷远点。
nonisolated enum Secp128r1 {
    typealias Point = (x: U128, y: U128)?

    static let p = U128(0xFFFF_FFFD_FFFF_FFFF, 0xFFFF_FFFF_FFFF_FFFF)
    static let a = U128(0xFFFF_FFFD_FFFF_FFFF, 0xFFFF_FFFF_FFFF_FFFC)
    static let b = U128(0xE875_79C1_1079_F43D, 0xD824_993C_2CEE_5ED3)
    static let n = U128(0xFFFF_FFFE_0000_0000, 0x75A3_0D1B_9038_A115)
    static let g: Point = (U128(0x161F_F752_8B89_9B2D, 0x0C28_607C_A52C_5B86),
                           U128(0xCF5A_C839_5BAF_EB13, 0xC02D_A292_DDED_7A83))

    /// 新的一对密钥：私钥，公钥（"04" + x + y，大写十六进制）
    static func keyPair() -> (secret: U128, publicKey: String) {
        while true {
            let secret = U128.random(below: n)
            if let point = multiply(secret, g) { return (secret, "04" + point.x.hex + point.y.hex) }
        }
    }

    /// 和对方公钥算出的共享点的 x（32 位大写十六进制）。公钥不对抛错。
    static func sharedSecret(_ secret: U128, peer publicKey: String) throws -> String {
        guard publicKey.count == 66, publicKey.hasPrefix("04"),
              let x = U128(hex: publicKey.dropFirst(2).prefix(32)), let y = U128(hex: publicKey.suffix(32)),
              isOnCurve((x, y)), let shared = multiply(secret, (x, y)) else {
            throw TrialFailure("微信服务器的公钥不对")
        }
        return shared.x.hex
    }

    static func isOnCurve(_ point: Point) -> Bool {
        guard let (x, y) = point else { return true }
        // y² = x³ + ax + b
        return mul(y, y) == add(add(mul(mul(x, x), x), mul(a, x)), b)
    }

    static func multiply(_ k: U128, _ point: Point) -> Point {
        var result: Point = nil
        for index in stride(from: 127, through: 0, by: -1) {
            result = addPoints(result, result)
            if k.bit(index) { result = addPoints(result, point) }
        }
        return result
    }

    static func addPoints(_ p1: Point, _ p2: Point) -> Point {
        guard let (x1, y1) = p1 else { return p2 }
        guard let (x2, y2) = p2 else { return p1 }
        let slope: U128
        if x1 == x2 {
            // 互为相反点（含 y = 0 的倍点）
            guard y1 == y2, !y1.isZero else { return nil }
            slope = mul(add(mul(U128(3), mul(x1, x1)), a), inverse(add(y1, y1)))
        } else {
            slope = mul(sub(y2, y1), inverse(sub(x2, x1)))
        }
        let x3 = sub(sub(mul(slope, slope), x1), x2)
        return (x3, sub(mul(slope, sub(x1, x3)), y1))
    }

    // 模 p 的运算。p = 2^128 - 2^97 - 1，所以 2^128 ≡ 2^97 + 1

    static func add(_ x: U128, _ y: U128) -> U128 {
        let (sum, overflow) = x.adding(y)
        return overflow || !(sum < p) ? sum.subtracting(p) : sum
    }

    static func sub(_ x: U128, _ y: U128) -> U128 {
        x < y ? x.subtracting(y).adding(p).0 : x.subtracting(y)
    }

    static func mul(_ x: U128, _ y: U128) -> U128 {
        let fold = U128(1 << 33, 1)  // 2^97 + 1
        var (high, low) = x.multipliedFullWidth(by: y)
        while !high.isZero {
            let (h2, l2) = high.multipliedFullWidth(by: fold)
            let (sum, carry) = low.adding(l2)
            low = sum
            high = carry ? h2.adding(U128(1)).0 : h2
        }
        while !(low < p) { low = low.subtracting(p) }
        return low
    }

    /// 费马小定理：x^(p-2)
    static func inverse(_ x: U128) -> U128 {
        let exponent = p.subtracting(U128(2))
        var result = U128(1)
        for index in stride(from: 127, through: 0, by: -1) {
            result = mul(result, result)
            if exponent.bit(index) { result = mul(result, x) }
        }
        return result
    }
}

// MARK: - AES、摘要、snappy

nonisolated enum WeTypeCrypto {
    /// AES-256-ECB，PKCS7 补齐
    static func encrypt(_ data: Data, key: Data) throws -> Data { try aes(CCOperation(kCCEncrypt), data, key) }
    static func decrypt(_ data: Data, key: Data) throws -> Data { try aes(CCOperation(kCCDecrypt), data, key) }

    private static func aes(_ operation: CCOperation, _ data: Data, _ key: Data) throws -> Data {
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var written = 0
        let capacity = out.count
        let status = out.withUnsafeMutableBytes { output in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count, nil, input.baseAddress, data.count,
                            output.baseAddress, capacity, &written)
                }
            }
        }
        guard status == kCCSuccess else { throw TrialFailure("微信加解密失败（\(status)）") }
        return out.prefix(written)
    }

    static func md5(_ data: Data) -> String { hex(Data(Insecure.MD5.hash(data: data))) }
    static func sha256(_ data: Data) -> String { hex(Data(SHA256.hash(data: data))) }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02X", $0) }.joined() }

    /// snappy 压缩：只用字面量块（每块最多 60 字节），合法但不真的压缩；上行的包很小，够用
    static func snappyCompress(_ data: Data) -> Data {
        var out = TrialProto.varint(data.count)
        let bytes = [UInt8](data)
        for start in stride(from: 0, to: bytes.count, by: 60) {
            let chunk = bytes[start..<min(start + 60, bytes.count)]
            out.append(UInt8((chunk.count - 1) << 2))
            out.append(contentsOf: chunk)
        }
        return out
    }

    /// snappy 解压（格式见 google/snappy 的 format_description.txt）
    static func snappyDecompress(_ data: Data) throws -> Data {
        let input = [UInt8](data)
        var i = 0
        func byte() throws -> Int {
            guard i < input.count else { throw TrialFailure("微信回复解压失败") }
            defer { i += 1 }
            return Int(input[i])
        }
        func littleEndian(_ count: Int) throws -> Int {
            var value = 0
            for k in 0..<count { value |= try byte() << (8 * k) }
            return value
        }
        var length = 0
        var shift = 0
        while true {
            let b = try byte()
            length |= (b & 0x7f) << shift
            if b < 0x80 { break }
            shift += 7
            guard shift < 35 else { throw TrialFailure("微信回复解压失败") }
        }
        var out: [UInt8] = []
        out.reserveCapacity(length)
        while i < input.count {
            let tag = try byte()
            switch tag & 3 {
            case 0:
                var count = tag >> 2
                if count >= 60 { count = try littleEndian(count - 59) }
                count += 1
                guard i + count <= input.count, out.count + count <= length else { throw TrialFailure("微信回复解压失败") }
                out.append(contentsOf: input[i..<(i + count)])
                i += count
            default:
                let count: Int
                let offset: Int
                switch tag & 3 {
                case 1:
                    count = ((tag >> 2) & 7) + 4
                    offset = ((tag >> 5) << 8) | (try byte())
                case 2:
                    count = (tag >> 2) + 1
                    offset = try littleEndian(2)
                default:
                    count = (tag >> 2) + 1
                    offset = try littleEndian(4)
                }
                guard offset > 0, offset <= out.count, out.count + count <= length else {
                    throw TrialFailure("微信回复解压失败")
                }
                // 可以和自己重叠（offset 比 count 小），一个字节一个字节抄
                for _ in 0..<count { out.append(out[out.count - offset]) }
            }
        }
        guard out.count == length else { throw TrialFailure("微信回复解压失败") }
        return Data(out)
    }
}
