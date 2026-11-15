//
//  VoiceModels.swift
//  WoType
//
//  语音输入要的两个模型（docs/10-语音输入开发报告.md）：识别 Qwen3-ASR 1.7B、润色 Qwen3.5-2B，
//  都是 MLX 格式，不放进 App 包。用户在设置 › 语音里点「下载」，下 Hugging Face 上的最新版，
//  存到 ~/Library/Application Support/WoType/models/<目录>/。
//
//  - 先问 Hugging Face 最新版的提交号和文件清单（大小、哈希），整个模型按同一个提交号下，不会新旧混在一起；
//  - huggingface.co 连不上时换 hf-mirror.com，照样按清单里的哈希校验；
//  - 每个文件先下到 .partial，断了（取消、断网、退出）下次从断点接着下；
//  - 下完逐个核对：大文件（LFS）核 SHA-256，小文件核 git 的 blob 哈希；不对就删掉重下，坏文件不留；
//  - 已经在目录里、哈希对得上的文件不重下（手动下好放进去的也算）；
//  - 都好了写 version.json（仓库、提交号、文件清单），以后不联网也知道装好了。
//

import CryptoKit
import Foundation
import os

/// 一个模型：从哪个仓库下、放在哪。
nonisolated struct VoiceModelSpec: Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
    let repo: String
    /// 大约多大，还没联网时显示
    let approxBytes: Int64

    /// 识别（必需）。
    static let asr = VoiceModelSpec(
        id: "qwen3-asr-1.7b-8bit", title: "本机 · Qwen3-ASR 1.7B",
        detail: "语音识别，中文、英文、中英混说", repo: "mlx-community/Qwen3-ASR-1.7B-8bit",
        approxBytes: 2_467_859_030)
    /// 润色（可选）。
    static let polish = VoiceModelSpec(
        id: "qwen3.5-2b-4bit", title: "本机 · Qwen3.5-2B",
        detail: "润色和语音翻译", repo: "mlx-community/Qwen3.5-2B-4bit",
        approxBytes: 1_749_081_927)

    static let all = [asr, polish]

    var directory: URL { VoiceModels.root.appendingPathComponent(id, isDirectory: true) }
}

/// 清单里的一个文件。
nonisolated struct VoiceModelFile: Codable, Equatable, Sendable {
    let path: String
    let size: Int64
    /// LFS 文件的 SHA-256（十六进制）
    let sha256: String?
    /// 普通文件的 git blob 哈希（SHA-1，十六进制）
    let blob: String?
}

/// 装好以后写在模型目录里的 version.json。
nonisolated struct VoiceModelVersion: Codable, Sendable {
    let repo: String
    let revision: String
    let files: [VoiceModelFile]
    let downloadedAt: Date
}

@MainActor
final class VoiceModels {

    static let shared = VoiceModels()

    /// 某个模型的状态变了（设置页据此刷新）。
    static let didChange = Notification.Name("WoTypeVoiceModelsDidChange")

    enum State: Equatable {
        case missing
        /// 目录里有下了一部分的文件，点下载会接着下
        case partial
        case connecting
        case downloading(written: Int64, total: Int64)
        case verifying
        case installed(bytes: Int64, revision: String)
        case failed(String)
    }

    nonisolated static var root: URL { Paths.userData.appendingPathComponent("models", isDirectory: true) }

    private(set) var states: [String: State] = [:]
    private var jobs: [String: Task<Void, Never>] = [:]

    /// 检查更新的结果（装好的模型才查；没查过是 nil）。更新就是再下一次：已经对的文件不重下，只下变了的
    enum Update: Equatable {
        case checking
        case upToDate
        case available
        case failed(String)
    }

    private var updates: [String: Update] = [:]

    func update(_ spec: VoiceModelSpec) -> Update? { updates[spec.id] }

    /// 查 Hugging Face 上这个仓库的最新提交号，和装好的版本比。
    func checkForUpdate(_ spec: VoiceModelSpec) {
        guard case .installed(_, let revision) = state(spec), updates[spec.id] != .checking else { return }
        setUpdate(spec, .checking)
        Task { [weak self] in
            let result: Update
            do {
                let latest = try await Self.reachableHost(for: spec.repo).revision
                result = latest == revision ? .upToDate : .available
            } catch {
                result = .failed(error.localizedDescription)
            }
            self?.setUpdate(spec, result)
        }
    }

    private func setUpdate(_ spec: VoiceModelSpec, _ update: Update?) {
        updates[spec.id] = update
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private init() {
        for spec in VoiceModelSpec.all { states[spec.id] = Self.localState(spec) }
    }

    func state(_ spec: VoiceModelSpec) -> State { states[spec.id] ?? .missing }

    var isBusy: Bool { !jobs.isEmpty }

    /// 不联网，看本机装没装好（设置页打开时调）。
    func refresh() {
        for spec in VoiceModelSpec.all where jobs[spec.id] == nil {
            set(spec, Self.localState(spec))
        }
    }

    func download(_ spec: VoiceModelSpec) {
        guard jobs[spec.id] == nil else { return }
        updates[spec.id] = nil
        set(spec, .connecting)
        Log.engine.info("开始下载模型 \(spec.repo, privacy: .public)")
        jobs[spec.id] = Task { [weak self] in
            let result: State
            do {
                let version = try await Self.install(spec) { written, total in
                    Task { @MainActor in self?.progress(spec, written: written, total: total) }
                } verifying: {
                    Task { @MainActor in self?.set(spec, .verifying) }
                }
                result = .installed(bytes: version.files.reduce(0) { $0 + $1.size }, revision: version.revision)
                Log.engine.info("模型下载完成 \(spec.repo, privacy: .public)@\(version.revision, privacy: .public)")
            } catch is CancellationError {
                result = Self.localState(spec)
            } catch {
                Log.engine.error("模型下载失败 \(spec.repo, privacy: .public)：\(error.localizedDescription, privacy: .public)")
                result = .failed(error.localizedDescription)
            }
            self?.jobs[spec.id] = nil
            // 下的就是最新版
            if case .installed = result { self?.updates[spec.id] = .upToDate }
            self?.set(spec, result)
        }
    }

    /// 两个都下（已经装好的跳过）。
    func downloadAll() {
        for spec in VoiceModelSpec.all {
            if case .installed = state(spec) { continue }
            download(spec)
        }
    }

    /// 取消：下了一半的文件留着，下次接着下。
    func cancel(_ spec: VoiceModelSpec) {
        jobs[spec.id]?.cancel()
    }

    func remove(_ spec: VoiceModelSpec) {
        cancel(spec)
        updates[spec.id] = nil
        try? FileManager.default.removeItem(at: spec.directory)
        set(spec, .missing)
    }

    private func progress(_ spec: VoiceModelSpec, written: Int64, total: Int64) {
        guard jobs[spec.id] != nil else { return }
        // 回调很密，千分比变了才通知（设置页每次都要重建）
        if case .downloading(let old, let oldTotal) = state(spec), oldTotal == total, total > 0,
           old * 1000 / total == written * 1000 / total { return }
        set(spec, .downloading(written: written, total: total))
    }

    private func set(_ spec: VoiceModelSpec, _ state: State) {
        guard states[spec.id] != state else { return }
        states[spec.id] = state
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    // MARK: - 本机状态

    nonisolated static func installedVersion(_ spec: VoiceModelSpec) -> VoiceModelVersion? {
        let url = spec.directory.appendingPathComponent("version.json")
        guard let data = try? Data(contentsOf: url),
              let version = try? decoder.decode(VoiceModelVersion.self, from: data) else { return nil }
        // 文件被删了、被换了大小：不算装好
        for file in version.files where fileSize(spec.directory.appendingPathComponent(file.path)) != file.size {
            return nil
        }
        return version
    }

    nonisolated private static func localState(_ spec: VoiceModelSpec) -> State {
        if let version = installedVersion(spec) {
            return .installed(bytes: version.files.reduce(0) { $0 + $1.size }, revision: version.revision)
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: spec.directory.path)) ?? []
        return names.isEmpty ? .missing : .partial
    }

    nonisolated private static func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64
    }

    nonisolated private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: - 下载

    nonisolated private static let hosts = ["https://huggingface.co", "https://hf-mirror.com"]

    /// 哪个地址通（先官方，6 秒连不上换镜像）。
    nonisolated private static func reachableHost(for repo: String) async throws -> (host: String, revision: String) {
        var lastError: Error = URLError(.cannotConnectToHost)
        for host in hosts {
            var request = URLRequest(url: URL(string: "\(host)/api/models/\(repo)")!)
            request.timeoutInterval = 6
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let sha = object["sha"] as? String, sha.count == 40 else {
                    throw DownloadError.badResponse("\(host) 没给出模型版本")
                }
                return (host, sha)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// 这个提交号下的文件清单（不要 .gitattributes、README 这类说明文件）。
    nonisolated private static func manifest(host: String, repo: String, revision: String) async throws -> [VoiceModelFile] {
        var request = URLRequest(url: URL(string: "\(host)/api/models/\(repo)/tree/\(revision)")!)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw DownloadError.badResponse("拿不到文件清单")
        }
        let files = items.compactMap { item -> VoiceModelFile? in
            guard item["type"] as? String == "file", let path = item["path"] as? String,
                  let size = (item["size"] as? NSNumber)?.int64Value,
                  !path.hasPrefix("."), path != "README.md", !path.contains("/") else { return nil }
            let lfs = (item["lfs"] as? [String: Any])?["oid"] as? String
            return VoiceModelFile(path: path, size: size, sha256: lfs, blob: lfs == nil ? item["oid"] as? String : nil)
        }
        guard files.contains(where: { $0.path == "config.json" }) else {
            throw DownloadError.badResponse("文件清单里没有 config.json")
        }
        return files
    }

    nonisolated private static func install(
        _ spec: VoiceModelSpec,
        progress: @escaping @Sendable (Int64, Int64) -> Void,
        verifying: @escaping @Sendable () -> Void
    ) async throws -> VoiceModelVersion {
        let (host, revision) = try await reachableHost(for: spec.repo)
        let files = try await manifest(host: host, repo: spec.repo, revision: revision)
        let fm = FileManager.default
        let dir = spec.directory
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // 已经对的文件不重下（第一次核大文件要几秒）。要换的旧文件先留着，新的下完核对过再替换：
        // 更新时少拿掉一会儿是一会儿
        verifying()
        var pending: [VoiceModelFile] = []
        for file in files {
            let url = dir.appendingPathComponent(file.path)
            if fileSize(url) == file.size, try await verify(url, file) { continue }
            pending.append(file)
        }
        let total = files.reduce(0) { $0 + $1.size }
        var done = total - pending.reduce(0) { $0 + $1.size }

        // 空间够不够（留 1 GB 余量）
        let need = pending.reduce(Int64(0)) { $0 + $1.size - (fileSize(dir.appendingPathComponent($1.path + ".partial")) ?? 0) }
        if let free = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, free < need + 1_073_741_824 {
            throw DownloadError.noSpace(need)
        }

        progress(done, total)
        for file in pending {
            let url = dir.appendingPathComponent(file.path)
            let partial = dir.appendingPathComponent(file.path + ".partial")
            let source = URL(string: "\(host)/\(spec.repo)/resolve/\(revision)/\(file.path)")!
            let base = done
            try await PartialDownload.run(from: source, to: partial, expected: file.size) { written in
                progress(base + written, total)
            }
            verifying()
            guard try await verify(partial, file) else {
                try? fm.removeItem(at: partial)
                throw DownloadError.checksum(file.path)
            }
            try? fm.removeItem(at: url)
            try fm.moveItem(at: partial, to: url)
            done += file.size
            progress(done, total)
        }

        // 清单里没有的旧文件（上一个版本留下的）删掉
        let keep = Set(files.map(\.path) + ["version.json"])
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where !keep.contains(name) {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
        let version = VoiceModelVersion(repo: spec.repo, revision: revision, files: files, downloadedAt: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(version).write(to: dir.appendingPathComponent("version.json"), options: .atomic)
        return version
    }

    /// 核对一个文件：LFS 核 SHA-256，普通文件核 git blob 哈希（SHA-1 of "blob <大小>\0" + 内容）。
    nonisolated private static func verify(_ url: URL, _ file: VoiceModelFile) async throws -> Bool {
        guard fileSize(url) == file.size else { return false }
        return try await Task.detached(priority: .utility) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? handle.close() }
            if let expected = file.sha256 {
                var hasher = SHA256()
                while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
                    try Task.checkCancellation()
                    hasher.update(data: chunk)
                }
                return hex(hasher.finalize()) == expected.lowercased()
            }
            guard let expected = file.blob else { return true }
            var hasher = Insecure.SHA1()
            hasher.update(data: Data("blob \(file.size)\0".utf8))
            while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hex(hasher.finalize()) == expected.lowercased()
        }.value
    }

    nonisolated private static func hex<D: Digest>(_ digest: D) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    enum DownloadError: LocalizedError {
        case badResponse(String)
        case checksum(String)
        case noSpace(Int64)

        var errorDescription: String? {
            switch self {
            case .badResponse(let message): message
            case .checksum(let name): "\(name) 校验不通过，已删除，请重试"
            case .noSpace(let bytes): "磁盘空间不够，还需要 \(bytes / 1_073_741_824 + 2) GB"
            }
        }
    }
}

/// 把一个地址下到 .partial 文件：文件已经有一部分就用 Range 接着下；边收边写，不占内存。
private final class PartialDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: @Sendable (Int64) -> Void
    private var handle: FileHandle?
    private var written: Int64 = 0
    private var lastReport: Int64 = 0
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?

    private init(destination: URL, onProgress: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    static func run(from source: URL, to destination: URL, expected: Int64,
                    onProgress: @escaping @Sendable (Int64) -> Void) async throws {
        let fm = FileManager.default
        var existing = (try? fm.attributesOfItem(atPath: destination.path))?[.size] as? Int64 ?? 0
        if existing > expected {
            try? fm.removeItem(at: destination)
            existing = 0
        }
        if existing == expected { return }
        if !fm.fileExists(atPath: destination.path) {
            fm.createFile(atPath: destination.path, contents: nil)
        }
        let download = PartialDownload(destination: destination, onProgress: onProgress)
        download.written = existing
        var request = URLRequest(url: source)
        request.timeoutInterval = 60
        if existing > 0 { request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }
        // 回调放在自己的串行队列上：写文件不能卡主线程
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: .default, delegate: download, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.addOperation {
                    download.continuation = continuation
                    task.resume()
                }
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        do {
            let handle = try FileHandle(forWritingTo: destination)
            if status == 206 {
                try handle.seekToEnd()
            } else if status == 200 {
                // 服务器不认 Range：从头来
                try handle.truncate(atOffset: 0)
                written = 0
            } else {
                throw VoiceModels.DownloadError.badResponse("下载出错（HTTP \(status)）")
            }
            self.handle = handle
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
            written += Int64(data.count)
            if written - lastReport >= 1 << 20 {
                lastReport = written
                onProgress(written)
            }
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        onProgress(written)
        if let failure {
            continuation?.resume(throwing: failure)
        } else if let error {
            continuation?.resume(throwing: (error as NSError).code == NSURLErrorCancelled ? CancellationError() : error)
        } else {
            continuation?.resume()
        }
        continuation = nil
    }
}
