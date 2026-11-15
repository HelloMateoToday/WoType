//
//  VoiceRecorder.swift
//  WoType
//
//  语音输入的录音：麦克风 → 16 kHz 单声道，切成 20 ms 一帧（320 个点）交给语音控制器，
//  和 Arion 的录音（infrastructure/audio/capture.go：F32、单声道、16 kHz、20 ms 一帧）给出的一样。
//  Arion 用 miniaudio，WoType 用 AVAudioEngine：
//  - 输入法激活时先建好 AVAudioEngine 并 prepare()（不会亮麦克风指示灯），按键时只 start()：
//    阶段 0 量过，每次按键才新建要 100~160 ms，开头的字会丢（docs/10 第 13 节）；
//  - 麦克风多半是 48 kHz，用 AVAudioConverter 转成 16 kHz（带抗混叠）；
//  - 设置里选的输入设备（没选或拔掉了用系统默认），和软件增益（照 Arion application/gain.go：
//    -6 到 +12 dB，只放大 WoType 录到的声音，不改系统的输入音量）。
//

import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import os

@MainActor
final class VoiceRecorder {

    static let shared = VoiceRecorder()

    /// 一帧多少个点（20 ms）
    nonisolated static let frameSamples = 320

    /// 收到一帧（主线程）
    var onFrame: (([Float]) -> Void)?
    /// 设置页的音量表：每一帧的音量（主线程）
    var onMonitor: ((Float) -> Void)?

    private var engine: AVAudioEngine?
    /// 引擎接的是哪个设备（设置里的 UID；空是系统默认）
    private var engineDevice = ""
    private var recording = false
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    /// 录音线程上凑不满一帧的零头
    private let remainder = OSAllocatedUnfairLock(initialState: [Float]())

    static var authorized: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    /// 输入法激活时调：已经授权就先把录音准备好。
    func prepare() {
        let wanted = Settings.shared.config.voiceInputDevice
        // 设置里换了设备：不在录音时重建
        if engine != nil, engineDevice != wanted, !recording { engine = nil }
        guard engine == nil, Self.authorized else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode  // 取一次 inputNode，引擎才会接上麦克风
        if !wanted.isEmpty, var device = AudioDevices.device(uid: wanted), let unit = input.audioUnit {
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &device, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr { Log.input.error("换输入设备失败：\(status)") }
        }
        engine.prepare()
        self.engine = engine
        engineDevice = wanted
    }

    /// 开始录音。没授权返回 false（第一次会弹系统授权窗）。
    func start() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Log.input.info("麦克风授权结果：\(granted ? "允许" : "拒绝", privacy: .public)")
            }
            return false
        default:
            return false
        }
        guard !recording else { return true }
        prepare()
        guard let engine else { return false }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, let converter = AVAudioConverter(from: format, to: target) else {
            Log.input.error("麦克风格式不支持：\(format.description, privacy: .public)")
            return false
        }
        remainder.withLock { $0 = [] }
        let remainder = remainder
        let target = target
        let gain = Float(pow(10, Double(Settings.shared.config.voiceGain) / 20))
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            // 录音线程：转格式、切成 20 ms 一帧
            let ratio = target.sampleRate / format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if supplied {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let channel = out.floatChannelData?[0] else { return }
            var converted = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
            if gain != 1 {
                for i in converted.indices { converted[i] = max(-1, min(1, converted[i] * gain)) }
            }
            let samples = converted
            let frames: [[Float]] = remainder.withLock { rest in
                rest.append(contentsOf: samples)
                var frames: [[Float]] = []
                while rest.count >= Self.frameSamples {
                    frames.append(Array(rest.prefix(Self.frameSamples)))
                    rest.removeFirst(Self.frameSamples)
                }
                return frames
            }
            guard !frames.isEmpty else { return }
            Task { @MainActor in
                frames.forEach { frame in
                    self?.onFrame?(frame)
                    self?.onMonitor?(VoiceRecorder.level(frame))
                }
            }
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            Log.input.error("录音启动失败：\(error.localizedDescription, privacy: .public)")
            // 设备换了（拔了耳机）之类：下次重新建
            self.engine = nil
            return false
        }
        recording = true
        return true
    }

    var isRecording: Bool { recording }

    /// 停止录音。凑不满一帧的零头也交出去，结尾不丢。
    func stop() {
        guard recording, let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.prepare()
        recording = false
        let rest = remainder.withLock { rest -> [Float] in
            defer { rest = [] }
            return rest
        }
        // 排在录音线程已经送出的帧后面，顺序不乱
        if !rest.isEmpty { Task { @MainActor in self.onFrame?(rest) } }
    }

    /// 一帧的音量（0~1）：Arion application/dictation.go 的 Level，RMS 换成 dBFS，-60~-10 映射到 0~1。
    nonisolated static func level(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Double = 0
        for s in samples { sum += Double(s) * Double(s) }
        let rms = (sum / Double(samples.count)).squareRoot()
        let db = 20 * log10(rms + 1e-9)
        return Float(max(0, min(1, (db + 60) / 50)))
    }
}
