//
//  Paths.swift
//  WoType
//
//  数据放哪里（见 docs/02-架构设计.md §5）：
//    只读数据   WoType.app/Contents/Resources/Data/
//    用户数据   ~/Library/Application Support/WoType/
//    缓存       ~/Library/Caches/WoType/
//

import Foundation
import os

nonisolated enum Paths {
    /// App 包里的只读数据：词库、语言模型、英文词表、简繁表。
    static var bundledData: URL {
        Bundle.main.resourceURL!.appendingPathComponent("Data", isDirectory: true)
    }

    /// 用户词库、输入习惯、自定义词、配置。
    static var userData: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ensure(base.appendingPathComponent("WoType", isDirectory: true))
    }

    /// 词库快照等可以随时删掉重建的东西。
    static var caches: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return ensure(base.appendingPathComponent("WoType", isDirectory: true))
    }

    static func bundled(_ name: String) -> URL? {
        let url = bundledData.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 改名前叫 WowType（Bundle ID com.hereorcode.inputmethod.WowType）：第一次启动把用户数据目录挪过来、
    /// 旧的 UserDefaults（新手引导、快捷键等）抄过来。缓存不挪，用到时重建。要在第一次用 userData 之前调
    static func moveFromWowType() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = base.appendingPathComponent("WowType", isDirectory: true)
        let new = base.appendingPathComponent("WoType", isDirectory: true)
        if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) {
            do {
                try fm.moveItem(at: old, to: new)
                Log.app.info("用户数据从 Application Support/WowType 挪到 WoType")
            } catch {
                Log.app.error("挪不动旧的用户数据：\(error.localizedDescription, privacy: .public)")
            }
        }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "movedFromWowType") else { return }
        if let domain = defaults.persistentDomain(forName: "com.hereorcode.inputmethod.WowType") {
            for (key, value) in domain where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
            Log.app.info("旧的 UserDefaults 抄过来 \(domain.count) 项")
        }
        defaults.set(true, forKey: "movedFromWowType")
    }

    private static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
