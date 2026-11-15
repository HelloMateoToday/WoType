//
//  AppDelegate.swift
//  WoType
//

import Cocoa
import InputMethodKit
import os

class AppDelegate: NSObject, NSApplicationDelegate {

    /// 作为单元测试宿主时为 nil。
    let server: IMKServer?

    init(server: IMKServer?) {
        self.server = server
        super.init()
    }

    /// 输入法是 LSBackgroundOnly，系统会把它当后台程序降优先级（App Nap、排到能效核）：
    /// 实测同样的按键处理慢 7 倍（docs/12）。整个进程声明为延迟敏感的用户活动，一直持有
    /// （水杉每键中位数 5.1 → 3.9 ms；改主线程 QoS 试过，没有效果）
    private var latencyActivity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        if OnboardingWindowController.isStandalone {
            setupMainMenu()
            OnboardingWindowController.shared.open(from: OnboardingWindowController.stepArgument)
            return
        }
        guard server != nil else { return }
        latencyActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "响应按键")
        setupMainMenu()
        Log.app.info("WoType \(Bundle.main.shortVersion, privacy: .public) 启动")
        // 水杉在后台准备（校验词库、回放学习记录，几十毫秒），好了以前按键交给应用（docs/12）。
        // 准备好后查大模型、同步自定义词；设置里开了「自动更新词库」才去查新词库
        PinyinEngines.current.prepare()
        // 钥匙串里的云端密钥搬进本机文件（以后不读钥匙串）；老版本的云端设置（每个服务商一个）换成模型列表
        CloudPolish.shared.moveFromKeychain()
        CloudPolish.shared.migrate()
        // 划词翻译「翻译并显示」的全局热键（只在 WoType 是当前输入法时注册）
        SelectionTranslation.shared.start()
        // 第一次装好：启动后弹出新手引导，只弹这一次（不管最后点没点「完成」，docs/18）。
        // 安装器的「开始使用」带 --show-onboarding 启动，也弹（docs/19）
        if !OnboardingWindowController.wasShown || CommandLine.arguments.contains("--show-onboarding") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { OnboardingWindowController.shared.open() }
        }
        // WoType 已经在跑时，安装器的「开始使用」发通知请它打开引导
        DistributedNotificationCenter.default().addObserver(
            forName: OnboardingWindowController.showRequest, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { OnboardingWindowController.shared.open() }
            }
    }

    /// 在访达里再打开一次 WoType.app：显示设置窗口（新手引导还没弹过时显示引导）。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard server != nil else { return false }
        if OnboardingWindowController.wasShown {
            SettingsWindowController.shared.open()
        } else {
            OnboardingWindowController.shared.open()
        }
        return false
    }

    // 关掉设置窗口时输入法不能跟着退出
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        OnboardingWindowController.isStandalone
    }

    // MARK: - 主菜单

    /// 设置窗口打开时（App 临时切成前台）用的菜单。文本框里的 ⌘C ⌘V ⌘A ⌘Z 要靠「编辑」菜单才能用。
    /// 没有「退出」：退出会把输入法进程也退掉。
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 WoType", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 WoType", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        addSubmenu(appMenu, title: "WoType", to: mainMenu)

        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        addSubmenu(editMenu, title: "编辑", to: mainMenu)

        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        addSubmenu(windowMenu, title: "窗口", to: mainMenu)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    private func addSubmenu(_ menu: NSMenu, title: String, to mainMenu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        mainMenu.addItem(item)
    }

    @objc private func showSettings() {
        SettingsWindowController.shared.open()
    }

    @objc private func showAbout() {
        SettingsWindowController.shared.open(page: "about")
    }
}

extension Bundle {
    var shortVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
}
