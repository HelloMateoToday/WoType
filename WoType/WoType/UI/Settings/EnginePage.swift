//
//  EnginePage.swift
//  WoType
//
//  设置里的「拼音引擎」页（docs/15）：水杉、万象两个引擎，同一时间用一个，在第一个分组「选择引擎」里启用。
//  下面只显示在用的那个引擎的「整句模型」「词库」（写法两边一样），切换后换成另一个的。水杉的词库组里还有云候选。
//  模型、词库的行统一：右边一个主按钮（下载 / 更新 / 检查更新）和「⋯」（删除、恢复内置版本）。
//  模糊音、双拼方案在「拼音设置」页，跟着当前引擎走。
//  万象的语法模型和词库 2026-11-12 从 76a9241 的设置页取回；2026-11-15 万象改用 librime（docs/22），
//  词库更新换成 RimeLexiconUpdater。
//

import Cocoa

final class EnginePage: SettingsPage {
    override var pageTitle: String { "拼音引擎" }
    override var pageSubtitle: String { "两个引擎同一时间用一个，各自的词库分开记。" }

    /// 引擎准备好、词库更新进度、模型下载进度（水杉和万象的）：刷新这一页
    private var observers: [NSObjectProtocol] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        observers = [MsimeHost.didBecomeReady, MsimeHost.lexiconDidChange, MsimeHost.settledModelDidChange,
                     RimeEngine.didLoad, WanxiangGrammarModel.didChange, RimeLexiconUpdater.didChange].map {
            NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in self?.reload() }
        }
        MsimeHost.shared.refreshLexicon()
        WanxiangGrammarModel.shared.refresh()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    override func build() -> [NSView] {
        let wanxiang = config.pinyinEngine == "wanxiang"
        return [
            SettingsKit.sectionTitle("选择引擎"),
            SettingsKit.card([engineRow("msime"), engineRow("wanxiang")]),
            SettingsKit.sectionTitle("整句模型"),
            SettingsKit.card(wanxiang ? wanxiangGrammarRows() : modelRows()),
            SettingsKit.sectionTitle("词库"),
            SettingsKit.card(wanxiang ? wanxiangLexiconRows() : lexiconRows() + [cloudRow()]),
        ]
    }

    /// 「选择引擎」里的一行：名字、长处，右边「启用」（在用的是「✓ 使用中」，不能点）。
    private func engineRow(_ engine: String) -> NSView {
        let inUse = config.pinyinEngine == engine
        let button = SettingButton(title: inUse ? "✓ 使用中" : "启用") { [weak self] in
            self?.update { $0.pinyinEngine = engine }
        }
        button.isEnabled = !inUse
        return engine == "wanxiang"
            ? SettingsKit.row(title: "万象", detail: "整句更准，常用词靠前，选过的往前排。",
                              help: "万象拼音的 Rime 方案（librime），词库、学词和整句都照万象。语法模型要另外下载（约 400 MB）。",
                              icon: SettingsIcon(symbol: "character.book.closed.fill", color: .systemGreen),
                              accessory: button)
            : SettingsKit.row(title: "水杉", detail: "词准，打字最快，跟着水杉更新词库和模型。",
                              help: "水杉输入法的引擎、词库和神经模型，每次按键几乎没有延迟。",
                              icon: SettingsIcon(symbol: "leaf.fill", color: .systemTeal),
                              accessory: button)
    }

    // MARK: - 云候选

    /// 正在检查能不能连上 Google（开关先停在打开、不能点）
    private var checkingCloud = false

    private func cloudRow() -> NSView {
        let detail: String
        if checkingCloud {
            detail = "正在检查能不能连上 Google…"
        } else {
            detail = "停顿时向 Google 要一个本地没有的新词，带 ☁️。"
        }
        let toggle = SettingSwitch(isOn: config.cloudCandidates || checkingCloud) { [weak self] on in
            self?.cloudToggled(on)
        }
        toggle.isEnabled = !checkingCloud
        return SettingsKit.row(title: "云候选", detail: detail,
                               help: "打字停顿时，把还没上屏的拼音发给 Google 输入工具，拿回一个候选，补本地词库没有的新词、网络用语。\n\n"
                                   + "已经输入的文字、词库和输入记录不会发送。需要能访问 Google。",
                               icon: SettingsIcon(symbol: "cloud.fill", color: .systemCyan), accessory: toggle)
    }

    /// 打开时先试一次 Google：连不上就说用不了、开关退回去；连得上再确认一次数据要走网络。关掉直接关。
    private func cloudToggled(_ on: Bool) {
        guard on else {
            update { $0.cloudCandidates = false }
            return
        }
        checkingCloud = true
        reload()
        CloudCandidates.checkGoogle { [weak self] reachable in
            guard let self else { return }
            self.checkingCloud = false
            let alert = NSAlert()
            if reachable {
                alert.messageText = "开启云候选？"
                alert.informativeText = "开启后，打字停顿时会把还没上屏的拼音通过网络发给 Google 输入工具，候选里会多一个带 ☁️ 的云候选。"
                    + "已经输入的文字、词库和输入记录不会发送。网络慢或断开时照常用本地候选。"
                alert.addButton(withTitle: "开启")
                alert.addButton(withTitle: "取消")
            } else {
                alert.alertStyle = .warning
                alert.messageText = "无法使用云候选"
                alert.informativeText = "连不上 Google 输入工具（inputtools.google.com）。云候选的数据从 Google 获取，"
                    + "现在的网络访问不了它，开启了也不会出现云候选。请检查网络或代理后再试。"
                alert.addButton(withTitle: "好")
            }
            let finish = { [weak self] (response: NSApplication.ModalResponse) in
                guard let self else { return }
                if reachable, response == .alertFirstButtonReturn {
                    self.update { $0.cloudCandidates = true }
                } else {
                    self.reload()
                }
            }
            if let window = self.view.window {
                alert.beginSheetModal(for: window, completionHandler: finish)
            } else {
                finish(alert.runModal())
            }
        }
    }
}

extension EnginePage {
    /// 整句模型：选不用、小模型、大模型，管大模型的下载和删除。
    func modelRows() -> [NSView] {
        var rows: [NSView] = []
        let host = MsimeHost.shared
        let models = ["none", "small", "large", "fluent"]
        let modelDetail: String
        switch config.msimeModel {
        case "none": modelDetail = "不用模型排序，最快。"
        case "large":
            modelDetail = host.settledModelInstalled ? "停顿时用大模型再排一遍，最准。" : "大模型还没下载，下载好之前和小模型一样。"
        case "fluent":
            modelDetail = host.settledModelInstalled ? "按键时不跑模型，最跟手。" : "大模型还没下载，下载好之前和「不用」一样。"
        default: modelDetail = "每次按键用小模型给整句排序。"
        }
        rows.append(SettingsKit.row(
            title: "整句模型", detail: modelDetail,
            help: "不用：不用神经模型给整句排序，最快。\n"
                + "小模型：每次按键用小模型（随 App 带，4.5 MB）排序。\n"
                + "大模型：每次按键用小模型，打字停顿时再用大模型把整句排一遍，最准。\n"
                + "流畅优先：按键时不跑模型，停顿一下再用大模型排好；连打时首选可能在停下的瞬间换一次。\n\n"
                + "大模型和流畅优先要先下载大模型（约 24 MB）。",
            icon: SettingsIcon(symbol: "brain.head.profile", color: .systemPink),
            accessory: SettingPopUp(items: ["不用", "小模型", "大模型", "流畅优先"],
                                    selected: models.firstIndex(of: config.msimeModel) ?? 1) { [weak self] index in
                self?.update { $0.msimeModel = models[index] }
            }))

        let detail: String
        let accessory: NSView
        switch host.settledModelState {
        case "installed":
            detail = "24 MB · 已下载"
            accessory = SettingsKit.resourceAccessory(nil, more: [("删除…", { [weak self] in
                self?.confirm("删除大模型？", "会释放约 24 MB，选「大模型」「流畅优先」时要重新下载。", action: "删除") {
                    host.removeSettledModel()
                }
            })])
        case "installing":
            detail = "正在下载 \(Int(host.settledModelProgress * 100))%"
            accessory = SettingsKit.progress(host.settledModelProgress) { host.cancelSettledModelDownload() }
        default:
            detail = "约 24 MB，选「大模型」「流畅优先」要先下载。"
            accessory = SettingsKit.resourceAccessory(SettingButton(title: "下载") { host.downloadSettledModel() })
        }
        rows.append(SettingsKit.row(title: "大模型", detail: detail,
                                    icon: SettingsIcon(symbol: "arrow.down.circle.fill", color: .systemBlue),
                                    accessory: accessory))
        return rows
    }

    /// 水杉的词库：版本、检查更新（水杉自己的在线更新），「⋯」里恢复随 App 的词库；自动更新开关。
    func lexiconRows() -> [NSView] {
        let host = MsimeHost.shared
        let status = host.lexicon
        // 版本是发布名（dict-v2.1.2），只显示数字
        let version = status.map { $0.version.replacingOccurrences(of: "dict-v", with: "") + " 版" } ?? "随 App 发布"
        let check = { SettingButton(title: "检查更新") { host.refreshLexicon(command: "check") } }
        let detail: String
        let primary: NSView
        switch status?.phase {
        case "checking"?:
            detail = "正在检查…"
            primary = SettingsKit.spinner()
        case "downloading"?:
            let total = status?.totalBytes ?? 0, done = status?.downloadedBytes ?? 0
            detail = total > 0 ? "正在下载 \(done * 100 / total)%（\(done / 1_048_576) / \(total / 1_048_576) MB）" : "正在下载…"
            let bar = NSProgressIndicator()
            bar.style = .bar
            bar.isIndeterminate = total == 0
            bar.doubleValue = total > 0 ? Double(done) / Double(total) * 100 : 0
            bar.widthAnchor.constraint(equalToConstant: 120).isActive = true
            primary = bar
        case "current"?:
            detail = version + " · 已是最新"
            primary = check()
        case "ready"?:
            detail = version + " · 已更新"
            primary = check()
        case "failed"?, "interrupted"?:
            detail = "更新失败\(status?.error.map { "：\($0)" } ?? "")。现在的词库没有变。"
            primary = SettingButton(title: "重试") { host.refreshLexicon(command: "check") }
        default:
            detail = version
            primary = check()
        }
        var more: [(title: String, action: () -> Void)] = []
        if status?.canRollback == true {
            more.append(("恢复内置版本…", { [weak self] in
                self?.confirm("恢复内置词库？", "退回随 App 发布的版本。学到的词不受影响。", action: "恢复") {
                    host.refreshLexicon(command: "rollback")
                }
            }))
        }
        return [
            SettingsKit.row(title: "水杉词库", detail: detail,
                            help: "水杉词库从水杉的发布页更新。更新后觉得不好用，可以在「⋯」里退回随 App 发布的版本。",
                            icon: SettingsIcon(symbol: "text.book.closed.fill", color: .systemOrange),
                            accessory: SettingsKit.resourceAccessory(primary, more: more)),
            SettingsKit.row(title: "自动更新词库", detail: "每天检查一次，有新版自动换上。",
                            icon: SettingsIcon(symbol: "arrow.triangle.2.circlepath", color: .systemTeal),
                            accessory: SettingSwitch(isOn: config.autoUpdateLexicon) { [weak self] on in
                                self?.update { $0.autoUpdateLexicon = on }
                                host.setLexiconAutoUpdate(on)
                            }),
        ]
    }

    /// 挂在设置窗口上的确认框（不用阻塞式的弹窗：会卡住整个输入法进程）。
    private func confirm(_ message: String, _ info: String, action: String, then: @escaping () -> Void) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { then() }
        }
    }

    // MARK: - 万象

    /// 万象的整句模型：语法模型文件那一行（下载 → 进度 → 已下载，删除在「⋯」里）。下载了就用，不想用就删
    func wanxiangGrammarRows() -> [NSView] {
        let model = WanxiangGrammarModel.shared
        let detail: String
        let accessory: NSView
        let remove = { [weak self] (bytes: Int64) -> (title: String, action: () -> Void) in
            ("删除…", { [weak self] in
                self?.confirm("删除语法模型？", "会释放约 \(bytes / 1_048_576) MB，整句没有现在准。以后可以重新下载。",
                              action: "删除") { model.remove() }
            })
        }
        switch model.state {
        case .installed(let bytes):
            let size = "\(bytes / 1_048_576) MB"
            let check = SettingButton(title: "检查更新") { model.checkForUpdate() }
            // 有新版时「更新」（约 400 MB，点了还要再确认一次）；删除一直在「⋯」里
            let update = { (note: String) -> NSView in
                SettingButton(title: "更新") { [weak self] in
                    self?.confirm("更新语法模型？", note + "下载完成前照常使用现在的模型。", action: "下载") {
                        model.download()
                    }
                }
            }
            let primary: NSView
            switch model.update {
            case .available(let newBytes)?:
                detail = "\(size) · 有新版（\(newBytes / 1_048_576) MB）"
                primary = update("会重新下载约 \(newBytes / 1_048_576) MB。")
            case .checking?:
                detail = "\(size) · 正在检查…"
                primary = SettingsKit.spinner()
            case .upToDate?:
                detail = "\(size) · 已是最新"
                primary = check
            case .failed(let message)?:
                detail = "\(size) · 检查失败：\(message)"
                primary = check
            case nil:
                detail = "\(size) · 已下载"
                primary = check
            }
            accessory = SettingsKit.resourceAccessory(primary, more: [remove(bytes)])
        case .downloading(let written, let total):
            accessory = SettingsKit.progress(total > 0 ? Double(written) / Double(total) : nil) { model.cancel() }
            detail = total > 0
                ? "正在下载 \(written * 100 / total)%（\(written / 1_048_576) / \(total / 1_048_576) MB）"
                : "正在连接…"
        case .missing:
            detail = "约 400 MB，下载后按上下文选词，整句更准。"
            accessory = SettingsKit.resourceAccessory(SettingButton(title: "下载") { model.download() })
        case .failed:
            detail = "下载失败，请检查网络后重试。"
            accessory = SettingsKit.resourceAccessory(SettingButton(title: "重试") { model.download() })
        }
        return [SettingsKit.row(title: "语法模型", detail: detail,
                                help: "万象的语法模型（CC BY 4.0），不随 App 带，要另外下载（约 400 MB）。不下也能打字，整句没有下了准。",
                                icon: SettingsIcon(symbol: "brain.head.profile", color: .systemPink),
                                accessory: accessory)]
    }

    /// 万象的词库：现在用的是哪天的、检查和更新；自动更新开关；更新过以后可以恢复内置的。
    func wanxiangLexiconRows() -> [NSView] {
        let updater = RimeLexiconUpdater.shared
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        let day = { (date: Date) in formatter.string(from: date) }
        let updated = RimeLexiconUpdater.installed != nil
        let version = [RimeLexiconUpdater.currentDate.map { "\(day($0)) 版" }, updated ? "已更新" : "随 App 发布"]
            .compactMap { $0 }.joined(separator: " · ")

        let check = { SettingButton(title: "检查更新") { updater.check() } }
        let detail: String
        let primary: NSView
        switch updater.state {
        case .idle:
            detail = version
            primary = check()
        case .checking:
            detail = "正在检查…"
            primary = SettingsKit.spinner()
        case .upToDate:
            detail = version + " · 已是最新"
            primary = check()
        case .available(let release):
            detail = version + " · 有 \(day(release.updatedAt)) 版（\(release.bytes / 1_048_576) MB）"
            primary = SettingButton(title: "更新") { updater.update() }
        case .downloading(let progress):
            detail = "正在下载 \(Int(progress * 100))%"
            primary = SettingsKit.progress(progress) { updater.cancel() }
        case .processing:
            detail = "正在编译词库，大约十几秒…"
            primary = SettingsKit.spinner()
        case .failed(let message):
            detail = "更新失败：\(message)。现在的词库没有变。"
            primary = SettingButton(title: "重试") { updater.check() }
        }
        var more: [(title: String, action: () -> Void)] = []
        if updated {
            more.append(("恢复内置版本…", { [weak self] in
                self?.confirm("恢复内置词库？", "会删掉更新的那份词库，用回随 App 发布的版本。学到的词和输入习惯不受影响。",
                              action: "恢复") { updater.restoreBundled() }
            }))
        }
        return [
            SettingsKit.row(title: "万象词库", detail: detail,
                            help: "从万象拼音的数据仓库下载每天发布的词库。更新后觉得不好用，可以在「⋯」里退回随 App 发布的版本。"
                                + "学到的词、输入习惯不受影响。",
                            icon: SettingsIcon(symbol: "text.book.closed.fill", color: .systemOrange),
                            accessory: SettingsKit.resourceAccessory(primary, more: more)),
            SettingsKit.row(title: "自动更新词库", detail: "每天检查一次，有新版就自动下载并换上。",
                            icon: SettingsIcon(symbol: "arrow.triangle.2.circlepath", color: .systemTeal),
                            accessory: SettingSwitch(isOn: config.wanxiangAutoUpdateLexicon) { [weak self] on in
                                self?.update { $0.wanxiangAutoUpdateLexicon = on }
                            }),
        ]
    }
}
