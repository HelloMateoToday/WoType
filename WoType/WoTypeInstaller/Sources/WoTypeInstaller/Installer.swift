//
//  Installer.swift
//  WoType 安装器
//
//  安装、卸载真正做的事。安装和 scripts/install-dev.sh 的步骤一样（docs/19）：
//  结束旧进程 → 原地覆盖到 ~/Library/Input Methods → 检查签名 → 注册。不启用、不切换：加进输入法列表由用户照着教程在系统设置里做（docs/19）。
//  费时的几步标 @concurrent，在后台做；界面在 InstallerWindowController。
//

import AppKit
import os

enum InstallError: LocalizedError {
    case missingPayload
    case copyFailed(String, Int32)
    case badSignature(OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingPayload: "安装包不完整，找不到要安装的 WoType.app。"
        case .copyFailed(let path, let code): "复制「\(path)」失败：\(String(cString: strerror(code)))。"
        case .badSignature(let status): "WoType.app 的签名检查没通过（OSStatus \(status)），安装包可能已经损坏，请重新下载。"
        }
    }
}

nonisolated enum Installer {

    static let bundleID = "com.acme.inputmethod.WoType"

    /// 看日志：log show --last 10m --predicate 'subsystem == "com.acme.inputmethod.WoTypeInstaller"'
    static let log = Logger(subsystem: "com.acme.inputmethod.WoTypeInstaller", category: "installer")

    /// 安装包里带的 WoType.app（scripts/make-installer.sh 放进去的）。
    static var payload: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Library/WoType.app", isDirectory: true)
    }

    /// 只给当前用户装，不用输管理员密码。
    static var destination: URL {
        library.appendingPathComponent("Input Methods/WoType.app", isDirectory: true)
    }

    private static var library: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    }

    private static var executable: URL {
        destination.appendingPathComponent("Contents/MacOS/WoType")
    }

    /// WoType 的新手引导弹过没有（docs/18，UserDefaults 的 onboardingShown）。弹过的话装好后不会再弹
    static var onboardingShown: Bool {
        UserDefaults(suiteName: bundleID)?.bool(forKey: "onboardingShown") ?? false
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: destination.path)
    }

    /// 读 Info.plist 里的版本号。不用 Bundle(url:)：它会缓存，装完再读还是旧的
    static func version(of app: URL) -> AppVersion? {
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard let short = info?["CFBundleShortVersionString"] as? String else { return nil }
        return AppVersion(short: short, build: info?["CFBundleVersion"] as? String ?? "")
    }

    // MARK: - 安装

    /// 结束装好的 WoType 和它的语音小程序（都在 Contents/MacOS 下）。先 TERM，三秒还没退再 KILL。
    @concurrent static func stopWoType() async {
        let pattern = NSRegularExpression.escapedPattern(for: destination.path + "/Contents/MacOS/")
        guard run("/usr/bin/pkill", ["-f", pattern]).status == 0 else { return }  // 本来就没在跑
        for _ in 0..<30 {
            try? await Task.sleep(for: .milliseconds(100))
            if run("/usr/bin/pgrep", ["-f", pattern]).status != 0 { return }
        }
        run("/usr/bin/pkill", ["-KILL", "-f", pattern])
    }

    /// 把安装包里的 WoType.app 原地覆盖到目标位置，再删掉新版里没有的旧文件（rsync -a --delete 的做法）。
    /// 不先删整个 App：install-dev.sh 里记着，2026-11-12 两次重装后 WoType 从输入法菜单里消失过，
    /// 怀疑是 App 不在的那一下被系统拿掉了。progress 报（已复制字节数, 总字节数），最多 20 次一秒
    @concurrent static func copyPayload(progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let fm = FileManager.default
        let source = payload.path, target = destination.path
        guard fm.fileExists(atPath: source), let walker = fm.enumerator(atPath: source) else {
            throw InstallError.missingPayload
        }
        var entries: [(path: String, type: FileAttributeType, size: Int64)] = []
        while let path = walker.nextObject() as? String {
            let attributes = walker.fileAttributes ?? [:]
            entries.append((path, attributes[.type] as? FileAttributeType ?? .typeUnknown,
                            (attributes[.size] as? NSNumber)?.int64Value ?? 0))
        }
        let total = entries.reduce(0) { $0 + ($1.type == .typeRegular ? $1.size : 0) }
        var done: Int64 = 0
        var lastReport = Date.distantPast
        let report = { (bytes: Int64) in
            guard bytes == total || Date().timeIntervalSince(lastReport) > 0.05 else { return }
            lastReport = Date()
            progress(bytes, total)
        }

        try fm.createDirectory(atPath: target, withIntermediateDirectories: true)
        for entry in entries {
            let from = source + "/" + entry.path, to = target + "/" + entry.path
            // attributesOfItem 不跟着符号链接走，看到的是这一项自己
            let existing = (try? fm.attributesOfItem(atPath: to))?[.type] as? FileAttributeType
            switch entry.type {
            case .typeDirectory:
                if existing == .typeDirectory { continue }
                if existing != nil { try fm.removeItem(atPath: to) }
                try fm.createDirectory(atPath: to, withIntermediateDirectories: true)
            case .typeSymbolicLink:
                if existing != nil { try fm.removeItem(atPath: to) }
                try fm.createSymbolicLink(atPath: to, withDestinationPath: fm.destinationOfSymbolicLink(atPath: from))
            default:
                if existing == .typeDirectory { try fm.removeItem(atPath: to) }
                let base = done
                try copyFile(from, to, displayPath: entry.path) { report(base + $0) }
                done += entry.size
                report(done)
            }
        }

        let wanted = Set(entries.map(\.path))
        if let old = fm.enumerator(atPath: target) {
            var stale: [String] = []
            while let path = old.nextObject() as? String {
                guard !wanted.contains(path) else { continue }
                stale.append(path)
                old.skipDescendants()
            }
            for path in stale { try fm.removeItem(atPath: target + "/" + path) }
        }
        progress(total, total)
    }

    /// copyfile(3) 复制一个文件，带上权限（可执行位），每复制一段报一次进度。
    /// 不带扩展属性：从下载的 DMG 里读出来的文件带着 com.apple.quarantine，不该抄到装好的 App 上
    private static func copyFile(_ from: String, _ to: String, displayPath: String,
                                 progress: @escaping (Int64) -> Void) throws {
        let state = copyfile_state_alloc()
        defer { copyfile_state_free(state) }
        let context = CopyProgress(progress)
        let callback: copyfile_callback_t = { what, stage, state, _, _, context in
            if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS, let state, let context {
                var copied: off_t = 0
                copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
                Unmanaged<CopyProgress>.fromOpaque(context).takeUnretainedValue().report(Int64(copied))
            }
            return COPYFILE_CONTINUE
        }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(context).toOpaque())
        let result = withExtendedLifetime(context) {
            copyfile(from, to, state, copyfile_flags_t(COPYFILE_DATA | COPYFILE_STAT | COPYFILE_UNLINK))
        }
        if result != 0 { throw InstallError.copyFailed(displayPath, errno) }
    }

    /// 检查装好的 App 签名完整（连里面的语音小程序一起），没被改过、没缺文件。
    @concurrent static func verify() async throws {
        var code: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(destination as CFURL, [], &code)
        if status == errSecSuccess, let code {
            let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
            status = SecStaticCodeCheckValidity(code, flags, nil)
        }
        if status != errSecSuccess { throw InstallError.badSignature(status) }
    }

    /// 打开 WoType 的新手引导当使用教程（docs/19）：WoType 在跑就发通知请它打开，没在跑就带 --show-onboarding 正常启动它。
    /// 引导要在输入法进程里，用户才能边看边用 WoType：单独运行的引导（--onboarding）和输入法是同一个 App，
    /// 开着时系统不再启动输入法，WoType 就打不出字（2026-11-13 实测）
    static func showOnboarding() async {
        let pattern = NSRegularExpression.escapedPattern(for: executable.path) + "$"
        if run("/usr/bin/pgrep", ["-f", pattern]).status == 0 {
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("com.acme.inputmethod.WoType.showOnboarding"), object: nil, userInfo: nil, deliverImmediately: true)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["--show-onboarding"]
        configuration.addsToRecentItems = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: destination, configuration: configuration)
        } catch {
            log.error("WoType 打不开：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 由 WoType 自己注册（InputSource.register），不启用、不切换；返回注册以后的状态。
    /// 系统还认不出来就隔一秒再注册一次（install-dev.sh 里遇到过第一次不灵）
    @concurrent static func register() async -> InputSources.Status {
        for attempt in 1...2 {
            let (status, output) = run(executable.path, ["--register"])
            log.info("WoType --register 退出码 \(status)：\(output, privacy: .public)")
            let state = await inputStatus()
            if state.found || attempt == 2 { return state }
            try? await Task.sleep(for: .seconds(1))
        }
        return await inputStatus()
    }

    // MARK: - 输入法

    /// WoType 认出来没有、启用没有、是不是当前输入法。
    @concurrent static func inputStatus() async -> InputSources.Status {
        let flags = inputSources("status").output.split(whereSeparator: \.isWhitespace).suffix(3).map { $0 == "1" }
        guard flags.count == 3 else { return InputSources.Status(found: false, enabled: false, selected: false) }
        return InputSources.Status(found: flags[0], enabled: flags[1], selected: flags[2])
    }

    /// 当前是 WoType 就先切到 ABC（不停用，原因见 InputSources）。
    @concurrent static func deselectWoType() async {
        inputSources("deselect")
    }

    /// 在新进程里跑 InputSources（见那边的说明）。
    @discardableResult
    private static func inputSources(_ command: String) -> (status: Int32, output: String) {
        run(Bundle.main.executablePath!, ["--input-sources", command])
    }

    // MARK: - 卸载

    /// 卸载最后删 App（等用户在系统设置里移除以后再删，docs/19）：这期间系统可能又把 WoType 拉起来了，先结束再删
    static func removeAppNow() throws {
        run("/usr/bin/pkill", ["-KILL", "-f", NSRegularExpression.escapedPattern(for: destination.path + "/Contents/MacOS/")])
        try FileManager.default.removeItem(at: destination)
    }

    @concurrent static func removeApp() async throws {
        try FileManager.default.removeItem(at: destination)
    }

    /// 用户词库、设置、下载的模型、缓存、偏好设置，还有给过的麦克风和辅助功能权限。
    @concurrent static func removeUserData() async {
        for url in userDataFolders + [
            library.appendingPathComponent("Caches/\(bundleID)"),
            library.appendingPathComponent("HTTPStorages/\(bundleID)"),
            library.appendingPathComponent("HTTPStorages/\(bundleID).binarycookies"),
        ] {
            try? FileManager.default.removeItem(at: url)
        }
        // 经 defaults 删，cfprefsd 里缓存的那份才跟着清掉
        run("/usr/bin/defaults", ["delete", bundleID])
        for service in ["Microphone", "Accessibility"] {
            run("/usr/bin/tccutil", ["reset", service, bundleID])
        }
    }

    /// 词库、设置、下载的模型和缓存一共多大（卸载确认框里显示）。
    @concurrent static func userDataSize() async -> Int64 {
        var total: Int64 = 0
        for folder in userDataFolders {
            guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
            else { continue }
            while let url = walker.nextObject() as? URL {
                total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }

    private static var userDataFolders: [URL] {
        [library.appendingPathComponent("Application Support/WoType"), library.appendingPathComponent("Caches/WoType")]
    }

    // MARK: -

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }
}

/// copyfile 的进度回调是 C 函数，靠这个对象把闭包带进去。
private nonisolated final class CopyProgress {
    let report: (Int64) -> Void
    init(_ report: @escaping (Int64) -> Void) { self.report = report }
}

/// 版本号加构建号。构建号是打包时的时间（scripts/make-installer.sh，如 202611132050），
/// 同一个版本号打了好几次包也分得出哪个新；以前开发编的是 1
nonisolated struct AppVersion: Equatable {
    let short: String
    let build: String

    /// 0.1.0（202611132050）；没有正经构建号的只写版本号
    var display: String {
        build.isEmpty || build == "1" ? short : "\(short)（\(build)）"
    }

    /// 先比版本号，一样再比构建号
    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let shorts = lhs.short.compare(rhs.short, options: .numeric)
        if shorts != .orderedSame { return shorts == .orderedAscending }
        return lhs.build.compare(rhs.build, options: .numeric) == .orderedAscending
    }
}
