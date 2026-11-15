//
//  Log.swift
//  WoType
//
//  日志走统一日志系统，用下面的命令看：
//    log stream --level debug --predicate 'subsystem == "com.acme.inputmethod.WoType"'
//

import Foundation
import os

nonisolated enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.acme.inputmethod.WoType"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let engine = Logger(subsystem: subsystem, category: "engine")
    static let input = Logger(subsystem: subsystem, category: "input")
}
