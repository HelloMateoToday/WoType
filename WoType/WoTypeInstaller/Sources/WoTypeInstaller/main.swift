//
//  main.swift
//  WoType 安装器
//

import AppKit

// 安装器 --input-sources status|deselect：在新进程里查、改输入法，做完就退出（InputSources.perform）
if let flag = CommandLine.arguments.firstIndex(of: "--input-sources"), CommandLine.arguments.count > flag + 1 {
    exit(InputSources.perform(CommandLine.arguments[flag + 1]))
}

MainActor.assumeIsolated {
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    NSApplication.shared.run()
}
