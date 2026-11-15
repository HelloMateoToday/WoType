// swift-tools-version:6.2
// WoType Voice：语音识别的小程序（docs/10-语音输入开发报告.md）。
// 模型只在这个进程里载入，输入法进程不碰；闲置一段时间自己退出。
import PackageDescription

let package = Package(
    name: "WoTypeVoice",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "wotype-voice", targets: ["WoTypeVoice"])],
    dependencies: [
        // v0.1.9。按提交号锁定：它的 Package.swift 里有 unsafeFlags，按版本号依赖会被 SwiftPM 拒绝
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", revision: "0e03fee81e87e6d6a186fb72610589bd92fc87cd"),
        // 润色模型。最新的发布版 3.32.3 只认 mlx-swift 0.32，和 mlx-audio-swift 要的 0.33 冲突，所以锁 main 上的提交；
        // 再往后一个提交（c9a9a3d）漏了 import os，在 Xcode 27 上编不过
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", revision: "ec4c966a663895cd052a9c58d06a1e6f3d96d01b"),
        // mlx-swift-lm 读本地模型用的分词器（#huggingFaceTokenizerLoader 展开后要这两个）
        .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "WoTypeVoice",
            dependencies: [
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
    ]
)
