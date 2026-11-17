//
//  main.swift
//  WoType
//
//  输入法进程入口：注册 IMKServer，然后进入事件循环。
//  没有主窗口，也没有 Dock 图标（Info.plist 里 LSBackgroundOnly）。
//

import Cocoa
import InputMethodKit
import os

// WoType --register [--select]：把自己注册到系统（安装器和开发脚本用），已经在输入法列表里的话切换过去，做完就退出。
// 不启用：加进输入法列表由用户在系统设置里做（InputSource.swift）
if CommandLine.arguments.contains("--register") {
    exit(InputSource.register(bundleURL: Bundle.main.bundleURL,
                              select: CommandLine.arguments.contains("--select")))
}

// WoType --leave：当前输入法是 WoType 就切到 ABC 等（开发脚本结束旧进程之前用），做完就退出
if CommandLine.arguments.contains("--leave") {
    exit(InputSource.leave())
}

// WoType --rime-build <目录>：在线更新万象词库时用新词表编译词库，做完就退出（RimeLexiconUpdater）。
// 编译峰值 1.1 GB，放在子进程里，内存不留在输入法进程（docs/22）
if let flag = CommandLine.arguments.firstIndex(of: "--rime-build"), CommandLine.arguments.count > flag + 1 {
    exit(RimeEngine.build(userDirectory: URL(fileURLWithPath: CommandLine.arguments[flag + 1])) ? 0 : 1)
}

/// 被单元测试当作宿主启动时不注册输入法：已安装的 WoType 占着同一个连接名，也不需要准备拼音引擎。
/// WoType --onboarding [--step N] [--mock]：只开新手引导窗口，同样不注册（调试引导不用装，docs/18）。
let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

// 改名前的 WowType 留下的用户数据和设置搬过来
if !isTestHost { Paths.moveFromWowType() }

let connectionName = Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String
    ?? "com.acme.inputmethod.WoType_Connection"

var server: IMKServer?
if !isTestHost && !OnboardingWindowController.isStandalone {
    server = IMKServer(name: connectionName, bundleIdentifier: Bundle.main.bundleIdentifier)
    if server == nil {
        Log.app.fault("IMKServer 创建失败，连接名 \(connectionName, privacy: .public)")
        exit(1)
    }
}

MainActor.assumeIsolated {
    let delegate = AppDelegate(server: server)
    NSApplication.shared.delegate = delegate
    NSApplication.shared.run()
}
