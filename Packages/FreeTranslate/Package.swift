// swift-tools-version: 5.9
//
// FreeTranslate：把各家免费翻译接口（微软、腾讯交互、火山、有道、金山词霸、B站、谷歌……）封装成一个库，
// 多家备选、失败自动换家和冷却。移植自 FluentRead（GPL-3.0），见 README.md。

import PackageDescription

let package = Package(
    name: "FreeTranslate",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "FreeTranslate", targets: ["FreeTranslate"]),
        .executable(name: "free-translate-check", targets: ["free-translate-check"]),
    ],
    targets: [
        .target(name: "FreeTranslate"),
        .executableTarget(name: "free-translate-check", dependencies: ["FreeTranslate"]),
        // Fixtures 是各家接口 2026-11-12 的真实回包；联网测试设 FREE_TRANSLATE_LIVE=1 才跑
        .testTarget(name: "FreeTranslateTests", dependencies: ["FreeTranslate"], resources: [.copy("Fixtures")]),
    ]
)
