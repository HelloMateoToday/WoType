// 移植自 Arion apps/desktop/native/mlx-asr/Sources/ArionASR/Worker.swift@d2108fe（AGPL-3.0-only）。
// Arion 的 Swift 代码，协议（protocol 3）、请求的检查和识别的参数照搬。和 Arion 不同：
// - 载入用 main.swift 的 loadASRModel（同样在临时目录里用链接载入，不改模型目录）；
// - 载入后先用半秒静音热身一次（第一次识别要编译 Metal 着色器，约 3 秒）；
// - 闲置 5 分钟、或者标准输入关了（输入法退出）就退出，模型的内存还回去；
// - 润色也在这个进程里（Polisher.swift，请求见那里），和识别各管各的；
// - 内存：MLX 的缓存限到 128 MB（main.swift 的 limitMLXCache），每段识别完清掉；系统内存紧张时放掉润色模型，
//   很紧张、又没在识别时直接退出（memoryPressure）。
//
// 常驻模式：输入法拉起 `wotype-voice worker <识别模型目录>`，标准输入输出一行一条 JSON。
//
// 收：
//   {"type":"chunk","id":"…","seq":0,"pcm":"<base64，16 kHz 单声道 16 位小端>"}   一段声音分几块发，seq 从 0 数
//   {"type":"transcribe","id":"…","sample_rate":16000,"prompt":"热词"}             发完了，开始识别
//   {"type":"cancel","id":"…"}
// 回：
//   {"type":"ready","protocol":3,"version":"…","capabilities":["prompt"]}
//   {"type":"end","id":"…","text":"…","stop":"complete"}
//   {"type":"cancelled","id":"…"}
//   {"type":"error","id":"…"}
//   {"type":"fatal"}                                                                 载入失败，之后退出
import Darwin
import Foundation
import MLX
import MLXAudioSTT
import MLXRandom

struct Request: Decodable, Sendable {
    let type: String
    let id: String
    var seq: Int?
    var pcm: String?
    var sample_rate: Int?
    var prompt: String?
    // 润色（Polisher.swift）
    var model: String?
    var messages: [[String: String]]?
    var max_tokens: Int?
}

struct Response: Encodable {
    let type: String
    var id: String?
    var text: String?
    var stop: String?
    var `protocol`: Int?
    var version: String?
    var capabilities: [String]?
    // 润色用了多久（输入法写进日志）
    var prompt_tokens: Int?
    var prompt_seconds: Double?
    var generate_seconds: Double?
}

/// 这个 actor 持有常驻的模型，识别一个一个来；生成 token 的时候也能取消。
actor Worker {
    private var model: Qwen3ASRModel?
    private var active: Task<Void, Never>?
    private var activeID: String?
    private var chunks: [String: Data] = [:]
    private var sequences: [String: Int] = [:]
    private let polisher = Polisher()

    func submit(_ request: Request) async {
        if request.type == "polish" || request.type == "polish_prepare" {
            await polisher.submit(request)
            return
        }
        if request.type == "cancel", await polisher.cancel(request.id) {
            return
        }
        if request.type == "cancel" {
            chunks.removeValue(forKey: request.id)
            sequences.removeValue(forKey: request.id)
            if activeID == request.id { active?.cancel() }
            return
        }
        if request.type == "chunk" {
            guard request.seq == sequences[request.id, default: 0],
                  let pcm = request.pcm, let data = Data(base64Encoded: pcm), data.count % 2 == 0,
                  chunks[request.id, default: Data()].count + data.count <= 16000 * 25 * 2 else {
                reply(Response(type: "error", id: request.id))
                return
            }
            chunks[request.id, default: Data()].append(data)
            sequences[request.id, default: 0] += 1
            return
        }
        guard request.type == "transcribe", active == nil else {
            reply(Response(type: "error", id: request.id))
            return
        }
        activeID = request.id
        active = Task { await execute(request) }
    }

    private func execute(_ request: Request) async {
        do {
            guard let model, request.sample_rate == 16000,
                  let data = chunks.removeValue(forKey: request.id), !data.isEmpty else {
                throw WorkerError.invalidRequest
            }
            sequences.removeValue(forKey: request.id)
            let samples: [Float] = data.withUnsafeBytes { bytes in
                stride(from: 0, to: bytes.count, by: 2).map {
                    Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: Int16.self))) / 32768
                }
            }
            guard samples.allSatisfy(\.isFinite) else { throw WorkerError.invalidRequest }
            let audio = MLXArray(samples)
            let context = request.prompt ?? ""
            // 上限由分词器和模型定。不截断热词，也不悄悄丢掉给的上下文
            let (_, _, audioTokens) = model.preprocessAudio(audio)
            let promptTokens = model.buildPrompt(numAudioTokens: audioTokens, context: context).dim(1)
            guard promptTokens <= model.config.textConfig.maxPositionEmbeddings - 128 else {
                throw WorkerError.contextLimit
            }
            MLXRandom.seed(11)
            var output: String?
            for try await event in model.generateStream(audio: audio, maxTokens: 128, temperature: 0, context: context) {
                try Task.checkCancellation()
                if case .result(let result) = event {
                    guard result.generationTokens < 128 else { throw WorkerError.tokenLimit }
                    output = result.text
                }
            }
            try Task.checkCancellation()
            guard let output else { throw WorkerError.noResult }
            reply(Response(type: "end", id: request.id, text: output, stop: "complete"))
        } catch is CancellationError {
            reply(Response(type: "cancelled", id: request.id))
        } catch {
            reply(Response(type: "error", id: request.id))
        }
        active = nil
        activeID = nil
        // 这段识别的中间结果还回去，两段之间只留模型
        Memory.clearCache()
    }

    func load(_ directory: URL) async throws {
        let model = try await loadASRModel(directory)
        // 热身（WoType 加的）
        _ = model.generate(audio: MLXArray.zeros([8_000]), maxTokens: 4, temperature: 0)
        Memory.clearCache()
        self.model = model
        reply(Response(type: "ready", protocol: 3, version: "wotype-mlx-1", capabilities: ["prompt"]))
    }

    /// 系统内存紧张时系统发来的通知；要一直留着，放掉就收不到了
    private var pressure: DispatchSourceMemoryPressure?

    /// 开始听系统的内存压力（WoType 加的）。
    func watchMemoryPressure() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global())
        source.setEventHandler { [weak self, weak source] in
            guard let self, let event = source?.data else { return }
            Task { await self.memoryPressure(critical: event.contains(.critical)) }
        }
        source.resume()
        pressure = source
    }

    /// 内存紧张：放掉润色模型（没在润色的话），清掉缓存。很紧张、又没在识别和润色时整个退出，
    /// 把识别模型也还回去；输入法看到退出，下次按语音键再拉起（载入约 1~2 秒）。
    private func memoryPressure(critical: Bool) async {
        await polisher.unload()
        Memory.clearCache()
        guard critical, await polisher.isIdle else { return }
        // 上面的 await 期间可能来了新的识别请求：退出前紧挨着再查，中间不能再有 await
        guard active == nil, chunks.isEmpty else { return }
        exit(0)
    }

    func shutdown() async {
        active?.cancel()
        await active?.value
        await polisher.shutdown()
        model = nil
    }
}

enum WorkerError: Error { case invalidRequest, noResult, tokenLimit, contextLimit }

/// 第三方库可能往标准输出打印，会把协议弄乱：先复制一份标准输出给协议用，再把标准输出指到 /dev/null。
nonisolated(unsafe) var protocolOutput: FileHandle!

func reply(_ response: Response) {
    guard let data = try? JSONEncoder().encode(response) else { return }
    protocolOutput.write(data + Data([10]))
}

enum WorkerMain {
    /// 闲置多久退出（WoType 加的）
    static let idleLimit: TimeInterval = 300

    static func run(modelDirectory: URL) async {
        protocolOutput = FileHandle(fileDescriptor: dup(STDOUT_FILENO), closeOnDealloc: true)
        let sink = open("/dev/null", O_WRONLY)
        guard sink >= 0, dup2(sink, STDOUT_FILENO) >= 0 else { return }
        close(sink)
        let worker = Worker()
        do { try await worker.load(modelDirectory) } catch { reply(Response(type: "fatal")); return }
        await worker.watchMemoryPressure()
        await Task.detached {
            let lines = LineReader()
            while let line = lines.next(timeout: idleLimit) {
                guard line.utf8.count <= 3 * 1024 * 1024,
                      let request = try? JSONDecoder().decode(Request.self, from: Data(line.utf8)) else { break }
                await worker.submit(request)
            }
            await worker.shutdown()
        }.value
    }
}

/// 按行读标准输入，带超时（闲置退出要用；WoType 加的）。
final class LineReader {
    private var buffer = Data()

    /// 下一行；标准输入关了或者等了 timeout 秒还没有新的一行，返回 nil。
    func next(timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return String(decoding: line, as: UTF8.self)
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            var poller = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, Int32(min(remaining, 60) * 1000))
            if ready < 0 { if errno == EINTR { continue }; return nil }
            if ready == 0 { continue }
            var chunk = [UInt8](repeating: 0, count: 1 << 16)
            let count = read(STDIN_FILENO, &chunk, chunk.count)
            if count <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }
}
