//
//  RimeLexiconUpdater.swift
//  WoType
//
//  万象（librime）的词库在线更新（docs/22）：从万象的数据仓库（rime-wanxiang-data，CC BY 4.0）下载每天发布的
//  dicts.zip，词表格式和万象方案里的一样，换掉方案的 dicts/ 再编译。
//  App 包里的方案和预编译词库不动（有签名，也是退路）：新词表和编译结果放在 Rime 用户目录的 dicts/、build/，
//  librime 优先用用户目录的；用户点「恢复内置版本」就删掉这两样。
//
//  流程：查 dicts.zip 的更新时间 → 下载 → 解压，只取方案里有的那几张表 →
//  子进程编译（WoType --rime-build，峰值 1.1 GB，放在子进程里内存全还给系统）→ 换上、重新初始化 librime。
//  照旧万象的 WanxiangLexiconUpdater 写的，少了逐个下载词表的退路和词条数统计。
//

import Foundation
import os

final class RimeLexiconUpdater: NSObject, URLSessionDownloadDelegate {

    static let shared = RimeLexiconUpdater()

    /// 状态变了（设置页据此刷新）。
    static let didChange = Notification.Name("WoTypeRimeLexiconUpdaterDidChange")

    /// 发布包里的一份词库。
    struct Release: Equatable {
        let updatedAt: Date
        let url: URL
        let bytes: Int64
    }

    /// 已经装上的那份（dicts/.wotype-version.json）。
    struct Installed: Codable, Equatable {
        var updatedAt: Date
        var installedAt: Date
    }

    enum State: Equatable {
        case idle
        case checking
        case available(Release)
        case downloading(progress: Double)
        case processing
        case upToDate
        case failed(String)
    }

    private(set) var state: State = .idle {
        didSet { NotificationCenter.default.post(name: Self.didChange, object: self) }
    }

    // MARK: - 路径和版本

    /// 更新的词表，librime 编译时优先用（和共享目录的 dicts/ 同名）
    nonisolated static var dictsDirectory: URL { RimeEngine.userDirectory.appendingPathComponent("dicts", isDirectory: true) }
    private nonisolated static var versionFile: URL { dictsDirectory.appendingPathComponent(".wotype-version.json") }

    nonisolated static var installed: Installed? {
        guard let data = try? Data(contentsOf: versionFile) else { return nil }
        return try? decoder.decode(Installed.self, from: data)
    }

    /// App 包里那份方案的发布日期（Data/rime/.release 是「v18.1.13 rime-wanxiang-base.zip 2026-11-14」）。
    nonisolated static var bundledDate: Date? {
        let url = RimeEngine.sharedDirectory.appendingPathComponent(".release")
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let day = text.split(whereSeparator: \.isWhitespace).last else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(day))
    }

    /// 现在用的词库是哪天的。
    nonisolated static var currentDate: Date? { installed?.updatedAt ?? bundledDate }

    private nonisolated static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: - 来源

    private static let releaseAPI = URL(string:
        "https://api.github.com/repos/amzxyz/rime-wanxiang-data/releases/tags/dict-nightly")!

    private var task: URLSessionTask?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    private var release: Release?
    private var timer: Timer?

    private var workDirectory: URL { Paths.caches.appendingPathComponent("rime-lexicon-update", isDirectory: true) }

    // MARK: - 检查

    /// 查有没有新版。then：查完以后（有新版时）接着做什么。
    func check(then: ((Release) -> Void)? = nil) {
        switch state {
        case .checking, .downloading, .processing: return
        default: break
        }
        state = .checking
        var request = URLRequest(url: Self.releaseAPI, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, _, error in
            let release = data.flatMap(Self.parseRelease)
            DispatchQueue.main.async {
                UserDefaults.standard.set(Date(), forKey: "rimeLexiconLastCheck")
                guard let release else {
                    self.state = .failed(error?.localizedDescription ?? "读不到词库的发布信息")
                    return
                }
                self.release = release
                // 比现在用的新才算有更新。随包的只知道是哪一天的：那天之内发布的不算新
                let current = Self.installed?.updatedAt ?? Self.bundledDate?.addingTimeInterval(86400)
                if let current, release.updatedAt <= current {
                    self.state = .upToDate
                } else {
                    self.state = .available(release)
                    then?(release)
                }
            }
        }.resume()
    }

    /// 发布信息里 dicts.zip 那一项。
    nonisolated static func parseRelease(_ data: Data) -> Release? {
        struct Payload: Decodable {
            struct Asset: Decodable {
                let name: String
                let size: Int64
                let updated_at: Date
                let browser_download_url: URL
            }
            let assets: [Asset]
        }
        guard let payload = try? decoder.decode(Payload.self, from: data),
              let asset = payload.assets.first(where: { $0.name == "dicts.zip" }) else { return nil }
        return Release(updatedAt: asset.updated_at, url: asset.browser_download_url, bytes: asset.size)
    }

    // MARK: - 更新

    /// 下载、编译、换上新词库。
    func update() {
        guard case .available(let release) = state else { return }
        self.release = release
        try? FileManager.default.removeItem(at: workDirectory)
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        state = .downloading(progress: 0)
        task = session.downloadTask(with: release.url)
        task?.resume()
        Log.engine.info("开始下载万象词库 dicts.zip")
    }

    func cancel() {
        task?.cancel()
        task = nil
        try? FileManager.default.removeItem(at: workDirectory)
        state = release.map { .available($0) } ?? .idle
    }

    /// 用回 App 包里的词库：删掉更新的词表和它编出来的词库，重新初始化
    func restoreBundled() {
        state = .idle
        RimeEngine.shared.replaceFiles {
            try? FileManager.default.removeItem(at: Self.dictsDirectory)
            Self.removeBuiltTables()
        }
        Log.engine.info("恢复内置的万象词库")
    }

    // MARK: - 下载（回调在主线程）

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                                totalBytesWritten written: Int64, totalBytesExpectedToWrite expected: Int64) {
        MainActor.assumeIsolated {
            let total = expected > 0 ? expected : (release?.bytes ?? 0)
            guard total > 0 else { return }
            let progress = min(Double(written) / Double(total), 1)
            if case .downloading(let old) = state, Int(old * 100) == Int(progress * 100) { return }
            state = .downloading(progress: progress)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // 临时文件出了这个回调就没了，先挪走
        MainActor.assumeIsolated {
            task = nil
            let zip = workDirectory.appendingPathComponent("dicts.zip")
            try? FileManager.default.removeItem(at: zip)
            let ok = (downloadTask.response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? true
            if ok, (try? FileManager.default.moveItem(at: location, to: zip)) != nil {
                install(zip: zip)
            } else {
                fail("下载词库失败")
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        MainActor.assumeIsolated {
            guard self.task === task else { return }
            self.task = nil
            if (error as NSError).code == NSURLErrorCancelled { return }
            fail("下载词库失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 解压、编译、换上

    private func install(zip: URL) {
        state = .processing
        let work = workDirectory
        let release = self.release
        DispatchQueue.global(qos: .utility).async {
            let failure = Self.build(zip: zip, in: work)
            DispatchQueue.main.async {
                if let failure {
                    self.fail(failure)
                    return
                }
                let staged = work.appendingPathComponent("user", isDirectory: true)
                let installed = Installed(updatedAt: release?.updatedAt ?? Date(), installedAt: Date())
                RimeEngine.shared.replaceFiles {
                    Self.moveIn(staged: staged, installed: installed)
                    try? FileManager.default.removeItem(at: work)
                }
                Log.engine.info("万象词库更新完成")
                self.state = .upToDate
            }
        }
    }

    /// 解压 zip，挑出方案里有的词表放进 work/user/dicts/，子进程编译到 work/user/build/。失败时返回原因
    private nonisolated static func build(zip: URL, in work: URL) -> String? {
        let fm = FileManager.default
        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        guard run("/usr/bin/unzip", ["-q", "-o", zip.path, "-d", unpacked.path]).status == 0,
              // 不假设压缩包里的目录结构：找到基础词库在哪个目录
              let source = find("jichu.dict.yaml", under: unpacked)?.deletingLastPathComponent() else {
            return "解压词库失败"
        }
        // 只换方案里本来就有的表（wanxiang.dict.yaml 的 import_tables 引用的、Lua 读的错音表），多出来的不要
        let user = work.appendingPathComponent("user", isDirectory: true)
        let dicts = user.appendingPathComponent("dicts", isDirectory: true)
        try? fm.createDirectory(at: dicts, withIntermediateDirectories: true)
        let bundled = RimeEngine.sharedDirectory.appendingPathComponent("dicts", isDirectory: true)
        for name in (try? fm.contentsOfDirectory(atPath: bundled.path)) ?? [] where name.hasSuffix(".dict.yaml") {
            let file = source.appendingPathComponent(name)
            guard fm.fileExists(atPath: file.path) else { continue }
            try? fm.copyItem(at: file, to: dicts.appendingPathComponent(name))
        }
        // 带上现在的补丁（模糊音、双拼），编出来的拼写表和用的时候一样，换上以后不用再重建
        for name in (try? fm.contentsOfDirectory(atPath: RimeEngine.userDirectory.path)) ?? [] where name.hasSuffix(".custom.yaml") {
            try? fm.copyItem(at: RimeEngine.userDirectory.appendingPathComponent(name), to: user.appendingPathComponent(name))
        }
        guard let executable = Bundle.main.executableURL else { return "找不到 WoType" }
        let result = run(executable.path, ["--rime-build", user.path])
        // 编出来的主词库不能比随包的小太多：格式变了、只下到一半都会小
        let table = "build/wanxiang.table.bin"
        let size = { (url: URL) in ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0 }
        let built = size(user.appendingPathComponent(table))
        let reference = size(RimeEngine.sharedDirectory.appendingPathComponent(table))
        guard result.status == 0, built > 0, built >= reference * 8 / 10 else {
            Log.engine.error("编译万象词库失败（退出码 \(result.status)，\(built) 字节）：\(result.error.suffix(2000), privacy: .public)")
            return "编译词库失败"
        }
        return nil
    }

    /// 换上：词表整个目录换掉，编译结果逐个挪进用户目录的 build/（覆盖同名的；librime 映射着旧文件也不怕，
    /// 挪进来的是新文件）。在 librime 结束之后、重新初始化之前做
    private nonisolated static func moveIn(staged: URL, installed: Installed) {
        let fm = FileManager.default
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(installed).write(to: staged.appendingPathComponent("dicts/.wotype-version.json"))
        try? fm.removeItem(at: dictsDirectory)
        try? fm.moveItem(at: staged.appendingPathComponent("dicts"), to: dictsDirectory)
        let build = RimeEngine.userDirectory.appendingPathComponent("build", isDirectory: true)
        try? fm.createDirectory(at: build, withIntermediateDirectories: true)
        let built = staged.appendingPathComponent("build", isDirectory: true)
        for name in (try? fm.contentsOfDirectory(atPath: built.path)) ?? [] where name.hasSuffix(".bin") {
            let target = build.appendingPathComponent(name)
            try? fm.removeItem(at: target)
            try? fm.moveItem(at: built.appendingPathComponent(name), to: target)
        }
    }

    /// 用户目录 build/ 里万象主词库编出来的文件（恢复内置时删掉，librime 改用 App 包里预编译的）
    private nonisolated static func removeBuiltTables() {
        let build = RimeEngine.userDirectory.appendingPathComponent("build", isDirectory: true)
        for name in ["wanxiang.table.bin", "wanxiang.prism.bin", "wanxiang.reverse.bin"] {
            try? FileManager.default.removeItem(at: build.appendingPathComponent(name))
        }
    }

    private func fail(_ message: String) {
        task = nil
        try? FileManager.default.removeItem(at: workDirectory)
        Log.engine.error("万象词库更新失败：\(message, privacy: .public)")
        state = .failed(message)
    }

    // MARK: - 自动更新

    /// 设置里开了「自动更新词库」：每天查一次，有新版就下载换上（不弹提示）。
    func startAutoUpdate() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoUpdateIfDue() }
        }
        // 启动后等一会儿再查，别和初始化抢
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { self.autoUpdateIfDue() }
    }

    private func autoUpdateIfDue() {
        guard Settings.shared.config.wanxiangAutoUpdateLexicon, Settings.shared.config.pinyinEngine == "wanxiang" else { return }
        let last = UserDefaults.standard.object(forKey: "rimeLexiconLastCheck") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 24 * 3600 else { return }
        check { [weak self] _ in self?.update() }
    }

    // MARK: - 小工具

    /// 跑一个子进程，等它结束。只收 stderr（librime 的日志写在这里），stdout 丢掉
    private nonisolated static func run(_ path: String, _ arguments: [String]) -> (status: Int32, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let err = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = err
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let error = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: error, as: UTF8.self))
    }

    private nonisolated static func find(_ name: String, under directory: URL) -> URL? {
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in files where url.lastPathComponent == name {
            return url
        }
        return nil
    }
}
