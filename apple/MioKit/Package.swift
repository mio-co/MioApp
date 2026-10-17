// swift-tools-version:5.9
// MioKit — Mio v0.4.0 的共享 Swift package：iOS（apple/ios，firefox-ios fork）和 Mac 原生壳（macos/）共用的浏览器逻辑。
// 不依赖 UIKit / AppKit；WebKit 部分用 #if canImport(WebKit) 包起来，所以纯逻辑在 Linux 上也能 swift test。
// 接入方式与接口见 README.md。
import PackageDescription

let package = Package(
    name: "MioKit",
    defaultLocalization: "zh-Hans",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "MioKit", targets: ["MioKit"]),
    ],
    dependencies: [
        // AdGuard/EasyList 规则 → WKContentRuleList JSON（GPL-3.0，与 v0.3.x App 同一版本，见仓库 NOTICE）
        .package(url: "https://github.com/AdguardTeam/SafariConverterLib.git", exact: "4.3.1"),
    ],
    targets: [
        .target(
            name: "MioKit",
            dependencies: [
                // 只在 Apple 平台链接（FilterEngine 在 Linux 上编不过）；Linux 单测用内置的 MioBasicFilterConverter。
                // 这个 product 同时带 ContentBlockerConverter（规则 → WKContentRuleList）和 FilterEngine（scriptlet / 扩展 CSS 高级规则）
                .product(name: "ContentBlockerConverter", package: "SafariConverterLib", condition: .when(platforms: [.iOS, .macOS])),
            ],
            path: "Sources/MioKit",
            resources: [.copy("Resources/js"), .copy("Resources/filters"), .copy("Resources/adguard")]
        ),
        .testTarget(name: "MioKitTests", dependencies: ["MioKit"], path: "Tests/MioKitTests"),
    ]
)
