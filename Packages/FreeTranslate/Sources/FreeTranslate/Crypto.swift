// Crypto.swift — 有道、金山词霸网页接口要的签名：MD5（十六进制小写）、AES-128-ECB + PKCS7（Base64），
// 和 FluentRead 用的 crypto-js 结果一致。

import CommonCrypto
import CryptoKit
import Foundation

func md5Hex(_ text: String) -> String {
    Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// AES-ECB/PKCS7，key 按 UTF-8 取字节（crypto-js 的 enc.Utf8.parse）。
func aesECB(_ data: Data, key: String, encrypt: Bool) -> Data? {
    let keyData = Data(key.utf8)
    guard [kCCKeySizeAES128, kCCKeySizeAES192, kCCKeySizeAES256].contains(keyData.count) else { return nil }
    var output = Data(count: data.count + kCCBlockSizeAES128)
    let outputCapacity = output.count
    var written = 0
    let status = output.withUnsafeMutableBytes { out in
        data.withUnsafeBytes { input in
            keyData.withUnsafeBytes { key in
                CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                        key.baseAddress, keyData.count, nil,
                        input.baseAddress, data.count,
                        out.baseAddress, outputCapacity, &written)
            }
        }
    }
    guard status == kCCSuccess else { return nil }
    return output.prefix(written)
}
