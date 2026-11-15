//
//  VoiceCues.swift
//  WoType
//
//  移植自 Arion apps/desktop/bootstrap/sounds.go@d2108fe（AGPL-3.0-only）：开始、结束录音的提示音。
//  两个 75 ms 的音，开始是 660 → 880 Hz（往上），结束是 880 → 587 Hz（往下）；
//  每个音 6 ms 淡入、按 e^(-28t) 衰减，加一点二次谐波。程序合成，不带音频文件。
//  Arion 在进入「录音」时放开始音、进入「识别」时放结束音（bootstrap/app.go），这里一样。
//

import AppKit

@MainActor
enum VoiceCues {
    private static let start = cue(rising: true)
    private static let stop = cue(rising: false)

    static func playStart() { play(start) }
    static func playStop() { play(stop) }

    private static func play(_ sound: NSSound?) {
        guard Settings.shared.config.voiceSound, let sound else { return }
        sound.stop()
        sound.play()
    }

    /// 合成提示音，写成 WAV 交给 NSSound。
    private static func cue(rising: Bool) -> NSSound? {
        let rate = 44_100
        let notes: [Double] = rising ? [660, 880] : [880, 587]
        let noteSamples = rate * 75 / 1000
        var samples: [Int16] = []
        samples.reserveCapacity(2 * noteSamples)
        for frequency in notes {
            for i in 0..<noteSamples {
                let t = Double(i) / Double(rate)
                let attack = min(1, t / 0.006)
                let release = exp(-t * 28)
                let v = 0.16 * attack * release * (sin(2 * .pi * frequency * t) + 0.25 * sin(4 * .pi * frequency * t))
                samples.append(Int16(max(-1, min(1, v)) * 32767))
            }
        }
        return NSSound(data: wav(samples, rate: rate))
    }

    private static func wav(_ samples: [Int16], rate: Int) -> Data {
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(bytes)
        samples.forEach { u16(UInt16(bitPattern: $0)) }
        return data
    }
}
