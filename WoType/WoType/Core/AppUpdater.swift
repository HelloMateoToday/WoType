//
//  AppUpdater.swift
//  WoType
//
//  关于页的「检查更新」：查 GitHub 上最新的 Release（不含草稿和预发布），tag（v0.2.0）比 App 的版本号新就提示，
//  点「下载」打开发布页下载安装包。只在用户点按钮时联网查，不自动查、不自动下载安装。
//

import Foundation
import os

final class AppUpdater {

    static let shared = AppUpdater()

    /// 状态变了（关于页据此刷新）
    static let didChange = Notification.Name("WoTypeAppUpdaterDidChange")

    /// 发布安装包的仓库。要是公开的：App 不登录查不到私有仓库的 Release
    static let repository = "HelloMateoToday/WoType"

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        /// 有新版：版本号、发布页
        case available(version: String, page: URL)
        case failed(String)
    }

    private(set) var state: State = .idle {
        didSet { NotificationCenter.default.post(name: Self.didChange, object: self) }
    }

    /// 现在装的版本（Info.plist 的 CFBundleShortVersionString）
    var currentVersion: String { Bundle.main.shortVersion }

    func check() {
        guard state != .checking else { return }
        state = .checking
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!,
                                 timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let current = currentVersion
        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let release = data.flatMap(Self.parseRelease)
            DispatchQueue.main.async {
                if let release {
                    self.state = Self.isNewer(release.version, than: current)
                        ? .available(version: release.version, page: release.page) : .upToDate
                } else if status == 404 {
                    // 还没发布过版本（或仓库不公开）
                    self.state = .failed("还没有可下载的版本")
                } else {
                    self.state = .failed(error?.localizedDescription ?? "读不到发布信息")
                }
                Log.engine.info("检查更新：\(String(describing: self.state), privacy: .public)")
            }
        }.resume()
    }

    /// GitHub 的 releases/latest：tag 去掉开头的 v 当版本号，html_url 是发布页
    nonisolated static func parseRelease(_ data: Data) -> (version: String, page: URL)? {
        struct Payload: Decodable {
            let tag_name: String
            let html_url: URL
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        let version = payload.tag_name.hasPrefix("v") ? String(payload.tag_name.dropFirst()) : payload.tag_name
        return (version, payload.html_url)
    }

    /// 版本号一段一段按数字比（0.10.0 比 0.9.1 新，1.0 和 1.0.0 一样）
    nonisolated static func isNewer(_ version: String, than current: String) -> Bool {
        let parts = { (text: String) in text.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let a = parts(version), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
