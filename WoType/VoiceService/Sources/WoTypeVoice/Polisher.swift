// 润色模型（Qwen3.5 2B，mlx-swift-lm）。WoType 自己写的：Arion 用 llama.cpp 跑 GGUF，这里用 MLX 跑同一个模型。
// 提示词由输入法拼好（WoType/WoType/Core/VoicePolish.swift，照 Arion 的 selected.go），这里只管生成：
// 温度 0、关掉思考（照 Arion 的 ChatRequest：Temperature 0、enable_thinking false）。
//
// 系统提示有一千多个 token（选同音词的还带十条例子，两千多个），每次都算要一秒左右。所以先把最后一条用户消息
// 之前的部分算进 KV 缓存存着（Arion 的 cache_prompt），润色时复制一份、只算最后一条用户消息：
// - 存的是「前面的消息 + 最后一条用户消息的开头标记」这段 token：在前面的消息后面接两条开头就不同的假消息套
//   聊天模板，取两者相同的开头（用户消息有时以 <source> 开头，带上下文时以 <context> 开头，都能接上）；
// - 真的请求套模板后以这段开头才用缓存，不然从头算（结果一样，只是慢）；
// - Qwen3.5 有线性注意力层，缓存不能往回截，所以存的缓存正好是这段，不多不少。
// 开始说话时输入法发 polish_prepare，载入模型、把这个场景的系统提示先算好。
//
// 润色模型约 1.3 GB：闲置 90 秒就放掉（idleLimit），不跟识别模型一起等到进程闲置退出。
// 下次润色重新载入（不到 1 秒），开始说话时的 polish_prepare 会提前载入，大多赶在说完之前。
//
// 收：
//   {"type":"polish","id":"…","model":"<润色模型目录>","messages":[{"role":"system","content":"…"},{"role":"user","content":"…"}],"max_tokens":256}
//   {"type":"polish_prepare","id":"prepare","model":"…","messages":[…最后一条用户消息之前的消息…]}
//   {"type":"cancel","id":"…"}
// 回：
//   {"type":"polished","id":"…","text":"…","stop":"complete"|"length","prompt_tokens":…,"prompt_seconds":…,"generate_seconds":…}
//   {"type":"cancelled","id":"…"} / {"type":"error","id":"…"}
import Foundation
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// 算好的系统提示：它的 token 和算完的 KV 缓存（只读，用时复制）。
final class PromptPrefix: @unchecked Sendable {
    let tokens: [Int]
    let cache: [KVCache]

    init(tokens: [Int], cache: [KVCache]) {
        self.tokens = tokens
        self.cache = cache
    }
}

private struct PolishOutput: Sendable {
    var text = ""
    var stop = "complete"
    var promptTokens = 0
    var promptSeconds = 0.0
    var generateSeconds = 0.0
}

actor Polisher {
    private var container: ModelContainer?
    private var directory: String?
    private var loading: Task<ModelContainer, Error>?
    private var tasks: [String: Task<Void, Never>] = [:]
    /// 按「最后一条用户消息之前的消息」存的前缀，最多 4 个（几个场景、选同音词），先进先出
    private var prefixes: [String: PromptPrefix] = [:]
    private var prefixOrder: [String] = []

    private static let thinkingOff: [String: any Sendable] = ["enable_thinking": false]

    /// 润色模型闲置多久放掉
    static let idleLimit: Duration = .seconds(90)
    /// 正在算的 polish_prepare 和润色请求有几个：不为 0 时不放掉模型
    private var busy = 0
    private var idleTimer: Task<Void, Never>?

    /// 没在载入、准备、润色
    var isIdle: Bool { busy == 0 && loading == nil }

    func submit(_ request: Request) {
        switch request.type {
        case "polish_prepare":
            guard let model = request.model, let messages = request.messages, !messages.isEmpty else { return }
            Task { await self.prepare(model: model, messages: messages) }
        case "polish":
            guard let model = request.model, let messages = request.messages, !messages.isEmpty,
                  let maxTokens = request.max_tokens, (1...4096).contains(maxTokens) else {
                reply(Response(type: "error", id: request.id))
                return
            }
            let id = request.id
            tasks[id] = Task {
                await self.run(id: id, model: model, messages: messages, maxTokens: maxTokens)
            }
        default:
            break
        }
    }

    /// 取消一个润色请求；不是润色的 id 返回 false。
    func cancel(_ id: String) -> Bool {
        guard let task = tasks[id] else { return false }
        task.cancel()
        return true
    }

    private func prepare(model: String, messages: [[String: String]]) async {
        busy += 1
        defer { finished() }
        let key = Self.key(messages)
        guard prefixes[key] == nil, let container = try? await load(model) else { return }
        let prefix = try? await container.perform { context in try Self.buildPrefix(messages, context) }
        if let prefix { store(prefix, for: key) }
    }

    private static func key(_ messages: [[String: String]]) -> String {
        messages.map { ($0["role"] ?? "") + "\u{0}" + ($0["content"] ?? "") }.joined(separator: "\u{1}")
    }

    private func run(id: String, model: String, messages: [[String: String]], maxTokens: Int) async {
        busy += 1
        defer {
            tasks[id] = nil
            finished()
        }
        do {
            let container = try await load(model)
            try Task.checkCancellation()
            let head = Array(messages.dropLast())
            let key = Self.key(head)
            let existing = head.isEmpty ? nil : prefixes[key]
            let chat: [[String: any Sendable]] = messages.map { $0 }
            let parameters = GenerateParameters(maxTokens: maxTokens, temperature: 0)
            let (output, prefix) = try await container.perform { context in
                var prefix = existing
                if prefix == nil, !head.isEmpty { prefix = try Self.buildPrefix(head, context) }
                let tokens = try context.tokenizer.applyChatTemplate(
                    messages: chat, tools: nil, additionalContext: Self.thinkingOff)
                var cache: [KVCache]?
                var input = tokens
                if let prefix, tokens.count > prefix.tokens.count, tokens.starts(with: prefix.tokens) {
                    cache = prefix.cache.map { $0.copy() }
                    input = Array(tokens[prefix.tokens.count...])
                }
                MLXRandom.seed(42)
                var output = PolishOutput()
                let stream = try generate(input: LMInput(tokens: MLXArray(input)), cache: cache,
                                          parameters: parameters, context: context)
                for await item in stream {
                    if Task.isCancelled { break }
                    switch item {
                    case .chunk(let chunk):
                        output.text += chunk
                    case .info(let info):
                        if case .length = info.stopReason { output.stop = "length" }
                        output.promptTokens = info.promptTokenCount
                        output.promptSeconds = info.promptTime
                        output.generateSeconds = info.generateTime
                    default:
                        break
                    }
                }
                return (output, prefix)
            }
            if let prefix, prefixes[key] == nil { store(prefix, for: key) }
            try Task.checkCancellation()
            reply(Response(type: "polished", id: id, text: output.text, stop: output.stop,
                           prompt_tokens: output.promptTokens, prompt_seconds: output.promptSeconds,
                           generate_seconds: output.generateSeconds))
        } catch is CancellationError {
            reply(Response(type: "cancelled", id: id))
        } catch {
            reply(Response(type: "error", id: id))
        }
    }

    /// 算前缀：前面的消息后面接两条不同的假消息套模板，相同的开头就是「前面的消息 + 用户消息开头」，算进缓存。
    private static func buildPrefix(_ head: [[String: String]], _ context: ModelContext) throws -> PromptPrefix? {
        func tokens(_ user: String) throws -> [Int] {
            let chat: [[String: any Sendable]] = (head + [["role": "user", "content": user]]).map { $0 }
            return try context.tokenizer.applyChatTemplate(messages: chat, tools: nil, additionalContext: thinkingOff)
        }
        let a = try tokens("甲")
        let b = try tokens("z")
        let shared = zip(a, b).prefix { $0 == $1 }.count
        guard shared > 1 else { return nil }
        let prefix = Array(a[..<shared])
        let cache = try context.model.newCache(parameters: nil)
        // 构造时就把整段算进缓存了（顺带算出第一个生成的 token，不要它）。不能再调 next()：
        // 那会把这个生成的 token 也喂进缓存，缓存多出一个 token，后面的结果就变了
        _ = try TokenIterator(input: LMInput(tokens: MLXArray(prefix)), model: context.model, cache: cache,
                              parameters: GenerateParameters(maxTokens: 1, temperature: 0))
        eval(cache)
        return PromptPrefix(tokens: prefix, cache: cache)
    }

    private func store(_ prefix: PromptPrefix, for key: String) {
        prefixes[key] = prefix
        prefixOrder.append(key)
        while prefixOrder.count > 4 {
            prefixes[prefixOrder.removeFirst()] = nil
        }
    }

    /// 载入润色模型（同一个目录只载入一次；正在载入时等它）。
    private func load(_ model: String) async throws -> ModelContainer {
        if let container, directory == model { return container }
        if let loading, directory == model { return try await loading.value }
        container = nil
        prefixes = [:]
        prefixOrder = []
        directory = model
        let task = Task {
            try await loadModelContainer(from: URL(fileURLWithPath: model, isDirectory: true),
                                         using: #huggingFaceTokenizerLoader())
        }
        loading = task
        defer { loading = nil }
        let loaded = try await task.value
        if directory == model { container = loaded }
        return loaded
    }

    /// 准备、润色做完一个：清掉缓存，重新开始计闲置时间。
    private func finished() {
        busy -= 1
        Memory.clearCache()
        idleTimer?.cancel()
        idleTimer = Task {
            try? await Task.sleep(for: Self.idleLimit)
            guard !Task.isCancelled else { return }
            self.unload()
        }
    }

    /// 放掉润色模型和算好的前缀（闲置到时、内存紧张时）；正在用就不放。
    func unload() {
        guard isIdle, container != nil else { return }
        idleTimer?.cancel()
        idleTimer = nil
        container = nil
        directory = nil
        prefixes = [:]
        prefixOrder = []
        Memory.clearCache()
    }

    func shutdown() async {
        idleTimer?.cancel()
        for task in tasks.values {
            task.cancel()
            await task.value
        }
        container = nil
        prefixes = [:]
    }
}
