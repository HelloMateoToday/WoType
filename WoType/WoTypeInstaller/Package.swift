// swift-tools-version:6.2
// WoType 安装器：DMG 里双击的那个 App，安装、卸载 WoType 输入法（docs/19-安装程序.md）。
// scripts/make-installer.sh 编译它、包成「安装 WoType.app」，要装的 WoType.app 放在它的 Contents/Library/ 里。
import PackageDescription

let package = Package(
    name: "WoTypeInstaller",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "WoTypeInstaller", targets: ["WoTypeInstaller"])],
    targets: [
        .executableTarget(
            name: "WoTypeInstaller",
            // 和 WoType 一样，默认都在主线程；后台做的事标 @concurrent
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ]
)
