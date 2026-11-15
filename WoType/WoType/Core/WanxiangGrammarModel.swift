//
//  WanxiangGrammarModel.swift
//  WoType
//
//  万象的语法模型 wanxiang-lts-zh-hans.gram（约 400 MB，CC BY 4.0）：不放进 App 包，
//  下载到 Rime 用户目录（~/Library/Application Support/WoType/rime/），librime 的 octagram 插件在那里找到就用，
//  按前后文给整句排序（docs/22）。由用户在设置里点「下载」，不想用就删除。
//  「检查更新」查 GitHub 上 LTS 发布里这个文件的更新时间，比本机文件新就能更新（重新下载，换上之前照常用旧的）。
//  2026-11-12 从 76a9241 的 WanxiangGrammarModel.swift 取回。
//

import Foundation
import os

final class WanxiangGrammarModel: NSObject, URLSessionDownloadDelegate {

    static let shared = WanxiangGrammarModel()

    /// 状态变了（设置页据此刷新）。
    static let didChange = Notification.Name("WoTypeWanxiangGrammarModelDidChange")

    nonisolated static let fileName = "wanxiang-lts-zh-hans.gram"
    static let downloadURL = URL(string:
        "https://github.com/amzxyz/RIME-LMDG/releases/download/LTS/wanxiang-lts-zh-hans.gram")!

    enum State: Equatable {
        case missing
        /// total 为 0 表示还不知道总大小
        case downloading(written: Int64, total: Int64)
        case installed(bytes: Int64)
        case failed(String)
    }

    private(set) var state: State = .missing {
        didSet { NotificationCenter.default.post(name: Self.didChange, object: self) }
    }

    /// 检查更新的结果（装好以后才查；nil 是还没查过）
    enum Update: Equatable {
        case checking
        case upToDate
        case available(bytes: Int64)
        case failed(String)
    }

    private(set) var update: Update? {
        didSet { NotificationCenter.default.post(name: Self.didChange, object: self) }
    }

    private static let releaseAPI = URL(string: "https://api.github.com/repos/amzxyz/RIME-LMDG/releases/tags/LTS")!

    private var task: URLSessionDownloadTask?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)

    nonisolated static var fileURL: URL { RimeEngine.userDirectory.appendingPathComponent(fileName) }

    override init() {
        super.init()
        // 直接赋值，不调 refresh()：初始化里发「变了」的通知，收到通知的界面回头读 shared 时它还没建好，
        // dispatch_once 重入直接崩（2026-11-15 引导的选引擎那一页遇到过）
        state = Self.localState()
    }

    /// 文件在不在、是不是语法模型。
    nonisolated static func isValid(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 14)) == Data("Rime::Grammar/".utf8)
    }

    func refresh() {
        if case .downloading = state { return }
        state = Self.localState()
    }

    /// 本机文件的状态：装好了多大，或者没有
    private nonisolated static func localState() -> State {
        let url = fileURL
        guard isValid(url), let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 else {
            return .missing
        }
        return .installed(bytes: size)
    }

    func download() {
        guard task == nil else { return }
        state = .downloading(written: 0, total: 0)
        task = session.downloadTask(with: Self.downloadURL)
        task?.resume()
        Log.engine.info("开始下载语法模型")
    }

    /// 查 LTS 发布里的语法模型是不是比本机的新（按文件的更新时间比）。
    func checkForUpdate() {
        guard case .installed = state, update != .checking else { return }
        update = .checking
        let local = (try? FileManager.default.attributesOfItem(atPath: Self.fileURL.path))?[.modificationDate] as? Date
        var request = URLRequest(url: Self.releaseAPI, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, _, error in
            struct Payload: Decodable {
                struct Asset: Decodable {
                    let name: String
                    let size: Int64
                    let updated_at: Date
                }
                let assets: [Asset]
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let asset = data.flatMap { try? decoder.decode(Payload.self, from: $0) }?.assets.first { $0.name == Self.fileName }
            DispatchQueue.main.async {
                guard let asset else {
                    self.update = .failed(error?.localizedDescription ?? "读不到语法模型的发布信息")
                    return
                }
                if let local, asset.updated_at <= local {
                    self.update = .upToDate
                } else {
                    self.update = .available(bytes: asset.size)
                }
            }
        }.resume()
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = .missing
        refresh()
    }

    /// 删掉语法模型（约 400 MB），引擎改用不带它的
    func remove() {
        guard task == nil else { return }
        try? FileManager.default.removeItem(at: Self.fileURL)
        update = nil
        refresh()
        RimeEngine.shared.reload()
        Log.engine.info("删掉了语法模型")
    }

    // MARK: - URLSessionDownloadDelegate（回调在主线程）

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                                totalBytesWritten written: Int64, totalBytesExpectedToWrite expected: Int64) {
        guard expected > 0 else { return }
        MainActor.assumeIsolated {
            // 回调很密，百分比变了才通知（设置页每次都要重建）
            if case .downloading(let old, let total) = state, total == expected,
               old * 100 / expected == written * 100 / expected { return }
            state = .downloading(written: written, total: expected)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // 临时文件出了这个回调就没了，先挪走
        let target = Self.fileURL
        let staged = target.appendingPathExtension("download")
        let fm = FileManager.default
        try? fm.removeItem(at: staged)
        let moved = (try? fm.moveItem(at: location, to: staged)) != nil && Self.isValid(staged)
        if moved {
            try? fm.removeItem(at: target)
            try? fm.moveItem(at: staged, to: target)
        } else {
            try? fm.removeItem(at: staged)
        }
        MainActor.assumeIsolated {
            task = nil
            if moved {
                Log.engine.info("语法模型下载完成")
                update = .upToDate
                state = .missing
                refresh()
                RimeEngine.shared.reload()
            } else {
                state = .failed("下载到的不是语法模型文件")
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        MainActor.assumeIsolated {
            self.task = nil
            if (error as NSError).code == NSURLErrorCancelled { return }
            Log.engine.error("语法模型下载失败：\(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
        }
    }
}
