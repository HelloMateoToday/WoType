//
//  RimeEngine.swift
//  WoType
//
//  万象引擎：librime（官方发布包）加万象官方方案（docs/22）。全进程一份，只在主线程用；
//  初始化、部署、结束在一条后台串行队列上做。会话见 RimeSession.swift。
//
//  librime 不在编译时链接：运行时从 Contents/Frameworks/librime.1.dylib 载入（scripts/embed-librime.sh 放进去），
//  插件在它旁边的 rime-plugins/。载入失败时万象用不了，水杉照常。
//  方案和预先编译好的词库（scripts/copy-data.sh）在 App 包的 Data/rime/，是 librime 的共享目录；
//  用户目录是 Application Support/WoType/rime/：学到的词（*.userdb）、改设置时生成的 *.custom.yaml、
//  语法模型（WanxiangGrammarModel 下载到这里，octagram 按 grammar/language 在这里找，有就用）、更新的词库。
//

import Foundation
import os

final class RimeEngine {

    static let shared = RimeEngine()

    /// librime 的函数表；库没载入时为 nil
    private(set) var api: UnsafeMutablePointer<RimeApi>?
    /// 初始化好、可以建会话了。之前会话为 nil，按键交给应用
    private(set) var ready = false
    private var loading = false
    /// 要不要用：start 时设上，unload（切回水杉）时清掉。初始化期间切走了，好了就马上结束
    private var wanted = false
    /// 现在这次初始化用的哪份补丁（设置里模糊音、双拼、纠错，自定义词、快捷短语一变就重来）。
    /// 会话从这里查快捷短语上屏后光标停在哪
    private(set) var loadedCustom: RimeCustom?

    /// 初始化、部署、结束都在这条队列上，前后不交叠
    private let queue = DispatchQueue(label: "WoType.rime", qos: .userInitiated)

    /// 方案名（万象标准版的 wanxiang.schema.yaml）
    static let schema = "wanxiang"

    /// 初始化好了、重新初始化好了（设置页据此刷新）
    static let didLoad = Notification.Name("WoTypeRimeEngineDidLoad")

    /// 共享目录：万象方案和预编译的 build/（只读）。万象的 Lua 只认绝对路径（docs/22），这里都是绝对路径
    nonisolated static var sharedDirectory: URL {
        Paths.bundledData.appendingPathComponent("rime", isDirectory: true)
    }

    nonisolated static var userDirectory: URL {
        let url = Paths.userData.appendingPathComponent("rime", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - 启动、结束

    /// 载入库、后台初始化；好了以后 session(idle:) 才给会话。已经好了或正在做就什么都不做
    func start() {
        wanted = true
        guard !ready, !loading else { return }
        guard let api = api ?? Self.loadLibrary() else { return }
        self.api = api
        boot(api, finalizeFirst: false)
    }

    /// 换了语法模型（下载、删除）、补丁（模糊音、双拼、纠错）、词库：结束再重新初始化。期间按键交给应用，不到一秒
    func reload() {
        guard let api, wanted else { return }
        guard ready else {
            // 正在初始化：等它好了再来一遍
            if loading { queue.async { DispatchQueue.main.async { self.reload() } } }
            return
        }
        session = nil
        ready = false
        boot(api, finalizeFirst: true)
    }

    /// 换用户目录里的文件（词库更新、恢复内置）：librime 结束以后在它的队列上做 work，再重新初始化。
    /// 没在用万象时直接做
    func replaceFiles(_ work: @escaping @Sendable () -> Void) {
        guard let api, wanted else {
            queue.async(execute: work)
            return
        }
        guard ready else {
            // 正在初始化：等它好了再来
            if loading { queue.async { DispatchQueue.main.async { self.replaceFiles(work) } } }
            else { queue.async(execute: work) }
            return
        }
        session = nil
        ready = false
        queue.async {
            api.pointee.finalize!()
            work()
        }
        boot(api, finalizeFirst: false)
    }

    /// 自定义词、快捷短语存了：变了就重新部署（只重编自定义短语，0.2 秒）。没在用万象时下次初始化再写
    func refreshCustom() {
        guard ready, RimeCustom(Settings.shared.config) != loadedCustom else { return }
        reload()
    }

    /// 切到水杉：关掉会话、结束 librime（放掉映射进来的词库和语法模型）
    func unload() {
        wanted = false
        session = nil
        guard ready, let api else { return }
        ready = false
        queue.async { api.pointee.finalize!() }
    }

    private func boot(_ api: UnsafeMutablePointer<RimeApi>, finalizeFirst: Bool) {
        loading = true
        let custom = RimeCustom(Settings.shared.config)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        queue.async {
            let started = Date()
            if finalizeFirst { api.pointee.finalize!() }
            custom.write(to: Self.userDirectory)
            var traits = Self.traits(userDirectory: Self.userDirectory, version: version)
            if !Self.didSetup {
                // setup 一个进程只能调一次（注册模块、载入插件）
                api.pointee.setup!(&traits)
                Self.didSetup = true
            }
            api.pointee.initialize!(&traits)
            // 每次都全面检查：不全面的那种发现不了 *.custom.yaml 改了。什么都没变时 0.2 秒；
            // 装好或升级后第一次用 App 包里预编译好的词库，也是 0.2 秒；补丁改了重建拼写表 0.3 秒（docs/22）
            if api.pointee.start_maintenance!(1) != 0 {
                api.pointee.join_maintenance_thread!()
            }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            DispatchQueue.main.async {
                self.loading = false
                guard self.wanted else {
                    self.queue.async { api.pointee.finalize!() }
                    return
                }
                self.loadedCustom = custom
                self.ready = true
                let grammar = WanxiangGrammarModel.isValid(WanxiangGrammarModel.fileURL)
                Log.engine.info("librime 初始化完成，用时 \(ms) ms，语法模型 \(grammar ? "有" : "无", privacy: .public)")
                NotificationCenter.default.post(name: Self.didLoad, object: self)
            }
        }
    }

    /// 只在 queue 上读写
    private nonisolated(unsafe) static var didSetup = false

    private nonisolated static func traits(userDirectory: URL, version: String) -> RimeTraits {
        var traits = RimeTraits()
        traits.data_size = Int32(MemoryLayout<RimeTraits>.stride - MemoryLayout<Int32>.stride)
        traits.shared_data_dir = keep(sharedDirectory.path)
        traits.user_data_dir = keep(userDirectory.path)
        traits.distribution_name = keep("WoType")
        traits.distribution_code_name = keep("WoType")
        traits.distribution_version = keep(version)
        traits.app_name = keep("rime.wotype")
        // 只记错误；空字符串是只写 stderr（输入法进程的 stderr 没人看，不在磁盘上攒日志）
        traits.min_log_level = 2
        traits.log_dir = keep("")
        return traits
    }

    /// librime 可能留着 traits 里的指针，给它一份不释放的拷贝（几个短字符串，每次初始化一份）
    private nonisolated static func keep(_ string: String) -> UnsafePointer<CChar> {
        UnsafePointer(strdup(string)!)
    }

    /// WoType --rime-build <目录>（RimeLexiconUpdater 起的子进程）：拿这个目录当用户目录全面部署一次，
    /// 目录里 dicts/ 的新词表编译到它的 build/。编完 build/ 里有万象主词库就算成功
    static func build(userDirectory: URL) -> Bool {
        guard let api = loadLibrary() else { return false }
        var traits = Self.traits(userDirectory: userDirectory, version: "build")
        api.pointee.setup!(&traits)
        api.pointee.initialize!(&traits)
        if api.pointee.start_maintenance!(1) != 0 {
            api.pointee.join_maintenance_thread!()
        }
        api.pointee.finalize!()
        return FileManager.default.fileExists(atPath: userDirectory.appendingPathComponent("build/wanxiang.table.bin").path)
    }

    private typealias GetApi = @convention(c) () -> UnsafeMutablePointer<RimeApi>?

    /// 从 Contents/Frameworks/ 载入 librime，取函数表
    private static func loadLibrary() -> UnsafeMutablePointer<RimeApi>? {
        let path = Bundle.main.privateFrameworksURL?.appendingPathComponent("librime.1.dylib").path ?? ""
        guard let handle = dlopen(path, RTLD_NOW) else {
            let reason = dlerror().map { String(cString: $0) } ?? "unknown"
            Log.engine.fault("载入不了 librime：\(reason, privacy: .public)")
            return nil
        }
        guard let symbol = dlsym(handle, "rime_get_api") else {
            Log.engine.fault("librime 里没有 rime_get_api")
            return nil
        }
        return unsafeBitCast(symbol, to: GetApi.self)()
    }

    // MARK: - 会话（整个进程一个，切输入框只清空）

    private(set) var session: RimeSession?

    var onSettled: ((Snapshot) -> Void)?
}

extension RimeEngine: PinyinEngine {
    func prepare() {
        start()
        RimeLexiconUpdater.shared.startAutoUpdate()
    }

    func settingsChanged(_ config: Config) {
        // 模糊音、双拼、纠错、快捷短语开关变了：重新初始化（补丁在初始化前写）
        if ready, RimeCustom(config) != loadedCustom {
            reload()
        }
        session?.apply(config)
        // 刚切到万象：还没初始化就开始（好了是空操作）
        start()
    }

    var openSession: PinyinSession? { session }

    func stop() {
        unload()
    }

    func session(idle: Bool) -> PinyinSession? {
        guard ready, let api else { return nil }
        if session == nil {
            session = RimeSession(api: api, schema: Self.schema)
            session?.apply(Settings.shared.config)
        }
        return session
    }
}
