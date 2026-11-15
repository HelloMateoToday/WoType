//
//  WanxiangLexiconUpdater.swift
//  WoType
//
//  在线更新词库：从万象的数据仓库（rime-wanxiang-data，CC BY 4.0）下载最新的词表，
//  转成 WoType 的词库，存到 ~/Library/Application Support/WoType/wanxiang/lexicon/，万象引擎优先用它。
//  App 包里的词库不动（有签名，也是退路）：更新的那份坏了、或者用户点「恢复内置词库」，就用回它。
//
//  流程：查每日发布包 dicts.zip 的更新时间 → 下载（下不了就改成逐个下载词表文件）→
//  子进程解压、转换、校验（WoType --convert-lexicon，引擎的 wanxiang.rs）→ 换上、重新载入引擎。
//  更新的词库没经过评测，所以转换时要校验（词条数、常用词），界面上要能一键退回。
//  2026-11-12 从 76a9241 的 WanxiangLexiconUpdater.swift 取回（docs/15）；水杉的词库更新在 MsimeHost 里。
//

import AppKit
import Foundation
import os

final class WanxiangLexiconUpdater: NSObject, URLSessionDownloadDelegate {

    static let shared = WanxiangLexiconUpdater()

    /// 状态变了（设置页据此刷新）。
    static let didChange = Notification.Name("WoTypeWanxiangLexiconUpdaterDidChange")

    /// 发布包里的一份词库。
    struct Release: Equatable {
        let updatedAt: Date
        let url: URL
        let bytes: Int64
    }

    /// 已经装上的那份（version.json）。
    struct Installed: Codable, Equatable {
        var updatedAt: Date
        var entries: Int
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

    nonisolated static var directory: URL { WanxiangEngine.dataDirectory.appendingPathComponent("lexicon", isDirectory: true) }
    private nonisolated static var versionFile: URL { directory.appendingPathComponent("version.json") }

    /// 更新过的词库（没更新过是 nil）。
    nonisolated static var installedLexicon: URL? {
        let url = directory.appendingPathComponent("lexicon.tsv")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    nonisolated static var installedEnglish: URL? {
        let url = directory.appendingPathComponent("english.txt")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    nonisolated static var installedMixed: URL? {
        let url = directory.appendingPathComponent("mixed.txt")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    nonisolated static var installed: Installed? {
        guard installedLexicon != nil, let data = try? Data(contentsOf: versionFile) else { return nil }
        return try? decoder.decode(Installed.self, from: data)
    }

    /// App 包里那份词库的日期（Data/VERSION 是「2026-11-10.c6c4d96」）。
    nonisolated static var bundledDate: Date? {
        guard let url = WanxiangEngine.bundled("VERSION"), let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(text.prefix(10)))
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
    /// 发布包下不了时逐个下载词表：和引擎的 wanxiang::TABLES 一致，加英文词表、混合编码词表
    private static let rawBase = "https://raw.githubusercontent.com/amzxyz/rime-wanxiang-data/wanxiang/dicts/"
    private static let tables = ["zi", "jichu", "duoyin", "diming", "mingren", "yiren", "en", "mixed"]

    /// 语法模型和词库同步发布：词库更新过以后，语法模型可能也该更新了（设置页据此提示）。
    static var grammarMayBeStale: Bool {
        get { UserDefaults.standard.bool(forKey: "lexiconUpdatedSinceGrammar") }
        set { UserDefaults.standard.set(newValue, forKey: "lexiconUpdatedSinceGrammar") }
    }

    private var task: URLSessionTask?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    private var release: Release?
    /// 这次更新是不是用户点的（是的话更新完提示要不要更新语法模型）。
    private var manual = false
    private var timer: Timer?

    private var workDirectory: URL { Paths.caches.appendingPathComponent("lexicon-update", isDirectory: true) }

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
                UserDefaults.standard.set(Date(), forKey: "lexiconLastCheck")
                guard let release else {
                    self.state = .failed(error?.localizedDescription ?? "读不到词库的发布信息")
                    return
                }
                self.release = release
                // 比现在用的新才算有更新。内置词库只知道是哪一天的：那天之内发布的不算新
                let current = Self.installed?.updatedAt ?? Self.bundledDate?.addingTimeInterval(86400)
                // 调试用：defaults write com.acme.inputmethod.WoType lexiconForceUpdate -bool YES
                // 以后检查时总当作有新版（测下载、转换、换上这几步）
                let force = UserDefaults.standard.bool(forKey: "lexiconForceUpdate")
                if let current, release.updatedAt <= current, !force {
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

    /// 下载并换上新词库。manual：用户点的（更新完提示语法模型）。
    func update(manual: Bool) {
        guard case .available(let release) = state else { return }
        self.manual = manual
        self.release = release
        try? FileManager.default.removeItem(at: workDirectory)
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        state = .downloading(progress: 0)
        // 调试用：defaults write … lexiconSkipZip -bool YES，不下发布包，直接走逐个下载词表的退路
        if UserDefaults.standard.bool(forKey: "lexiconSkipZip") {
            downloadTables()
            return
        }
        task = session.downloadTask(with: release.url)
        task?.resume()
        Log.engine.info("开始下载词库 dicts.zip")
    }

    func cancel() {
        task?.cancel()
        task = nil
        try? FileManager.default.removeItem(at: workDirectory)
        state = release.map { .available($0) } ?? .idle
    }

    /// 用回 App 包里的词库。
    func restoreBundled() {
        Self.removeInstalledCache()
        try? FileManager.default.removeItem(at: Self.directory)
        Self.grammarMayBeStale = false
        state = .idle
        WanxiangEngine.shared.reload()
        Log.engine.info("恢复内置词库")
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
            let zip = workDirectory.appendingPathComponent("dicts.zip")
            try? FileManager.default.removeItem(at: zip)
            let ok = (downloadTask.response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? true
            if ok, (try? FileManager.default.moveItem(at: location, to: zip)) != nil {
                task = nil
                install(zip: zip)
            } else {
                task = nil
                downloadTables()
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        MainActor.assumeIsolated {
            guard self.task === task else { return }
            self.task = nil
            if (error as NSError).code == NSURLErrorCancelled { return }
            // 发布包下不了（国内常这样）：改成逐个下载词表文件
            Log.engine.error("dicts.zip 下载失败，改为逐个下载词表：\(error.localizedDescription, privacy: .public)")
            downloadTables()
        }
    }

    /// 逐个下载词表文件到 workDirectory/dicts/。
    private func downloadTables(_ index: Int = 0) {
        let dicts = workDirectory.appendingPathComponent("dicts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dicts, withIntermediateDirectories: true)
        guard index < Self.tables.count else {
            install(dicts: dicts)
            return
        }
        state = .downloading(progress: Double(index) / Double(Self.tables.count))
        let name = "\(Self.tables[index]).dict.yaml"
        let download = URLSession.shared.downloadTask(with: URL(string: Self.rawBase + name)!) { location, response, error in
            let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            let target = dicts.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: target)
            let moved = ok && location.map { (try? FileManager.default.moveItem(at: $0, to: target)) != nil } ?? false
            DispatchQueue.main.async {
                guard self.task != nil else { return }  // 取消了
                self.task = nil
                if moved {
                    self.downloadTables(index + 1)
                } else if (error as NSError?)?.code != NSURLErrorCancelled {
                    self.fail("下载词库失败：\(error?.localizedDescription ?? name)")
                }
            }
        }
        task = download
        download.resume()
    }

    // MARK: - 解压、转换、换上

    private func install(zip: URL) {
        state = .processing
        let work = workDirectory
        DispatchQueue.global(qos: .utility).async {
            let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
            let unzip = Self.run("/usr/bin/unzip", ["-q", "-o", zip.path, "-d", unpacked.path])
            // 不假设压缩包里的目录结构：找到基础词库在哪个目录
            let dicts = unzip.status == 0 ? Self.find("jichu.dict.yaml", under: unpacked)?.deletingLastPathComponent() : nil
            DispatchQueue.main.async {
                if let dicts {
                    self.install(dicts: dicts)
                } else {
                    Log.engine.error("dicts.zip 解压失败，改为逐个下载词表")
                    self.downloadTables()
                }
            }
        }
    }

    private func install(dicts: URL) {
        state = .processing
        let work = workDirectory
        let release = self.release
        // 词条数不能比现在少太多：格式变了、只下到一半都会少
        let minimum = (Self.installed?.entries).map { $0 * 8 / 10 } ?? 1_000_000
        DispatchQueue.global(qos: .utility).async {
            let staged = work.appendingPathComponent("lexicon", isDirectory: true)
            try? FileManager.default.removeItem(at: staged)
            let formatter = ISO8601DateFormatter()
            let source = release.map { "，rime-wanxiang-data \(formatter.string(from: $0.updatedAt))" } ?? ""
            guard let executable = Bundle.main.executableURL else { return }
            let result = Self.run(executable.path,
                                  ["--convert-lexicon", dicts.path, staged.path, String(minimum), source])
            let entries = Int(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
            var failure: String?
            if result.status != 0 || entries == nil {
                failure = result.error.isEmpty ? "转换词库失败" : result.error
            } else {
                // 换上：先写版本信息，再整个目录挪过去
                let installed = Installed(updatedAt: release?.updatedAt ?? Date(), entries: entries ?? 0, installedAt: Date())
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                do {
                    try encoder.encode(installed).write(to: staged.appendingPathComponent("version.json"))
                    Self.removeInstalledCache()
                    try? FileManager.default.removeItem(at: Self.directory)
                    try FileManager.default.moveItem(at: staged, to: Self.directory)
                } catch {
                    failure = "换上新词库失败：\(error.localizedDescription)"
                }
            }
            try? FileManager.default.removeItem(at: work)
            DispatchQueue.main.async {
                if let failure {
                    self.fail(failure)
                    return
                }
                Log.engine.info("词库更新完成：\(entries ?? 0) 条")
                Self.grammarMayBeStale = WanxiangGrammarModel.isValid(WanxiangGrammarModel.fileURL)
                self.state = .upToDate
                WanxiangEngine.shared.reload()
                if self.manual { self.offerGrammarUpdate() }
            }
        }
    }

    private func fail(_ message: String) {
        task = nil
        try? FileManager.default.removeItem(at: workDirectory)
        Log.engine.error("词库更新失败：\(message, privacy: .public)")
        state = .failed(message)
    }

    /// 词库更新好了：语法模型和词库是同步发布的，问要不要一并更新（约 400 MB，要用户确认）。
    ///
    /// 提示挂在设置窗口上，不用阻塞式的弹窗：那会卡住整个输入法进程，弹窗开着时打不了字。
    /// 设置窗口没开着就不问，「拼音引擎 → 万象」的语法模型那一行会一直提示。
    private func offerGrammarUpdate() {
        guard Self.grammarMayBeStale, let window = SettingsWindowController.visibleWindow else { return }
        let alert = NSAlert()
        alert.messageText = "词库已更新。要一并更新语法模型吗？"
        alert.informativeText = "语法模型和词库是同步发布的，一起更新更准。需要重新下载约 400 MB；"
            + "下载完成前照常使用现在的模型。也可以以后在「语法模型」里更新。"
        alert.addButton(withTitle: "暂不更新")
        alert.addButton(withTitle: "更新语法模型")
        alert.beginSheetModal(for: window) { response in
            if response == .alertSecondButtonReturn { WanxiangGrammarModel.shared.download() }
        }
    }

    // MARK: - 自动更新

    /// 设置里开了「自动更新词库」：每天查一次，有新版就下载换上（不弹提示）。
    func startAutoUpdate() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoUpdateIfDue() }
        }
        // 启动后等一会儿再查，别和载入词库抢
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { self.autoUpdateIfDue() }
    }

    private func autoUpdateIfDue() {
        guard Settings.shared.config.wanxiangAutoUpdateLexicon, Settings.shared.config.pinyinEngine == "wanxiang" else { return }
        let last = UserDefaults.standard.object(forKey: "lexiconLastCheck") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 24 * 3600 else { return }
        check { [weak self] _ in self?.update(manual: false) }
    }

    // MARK: - 小工具

    /// 更新的那份词库要换掉、删掉了：它的快照（几十 MB，在缓存目录里）一起删。
    private nonisolated static func removeInstalledCache() {
        guard let lexicon = installedLexicon else { return }
        wotype_set_cache_dir(Paths.caches.path)
        wotype_lexicon_remove_cache(lexicon.path)
    }

    private nonisolated static func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return (-1, "", error.localizedDescription)
        }
        let output = out.fileHandleForReading.readDataToEndOfFile()
        let error = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self), String(decoding: error, as: UTF8.self))
    }

    private nonisolated static func find(_ name: String, under directory: URL) -> URL? {
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in files where url.lastPathComponent == name {
            return url
        }
        return nil
    }
}
