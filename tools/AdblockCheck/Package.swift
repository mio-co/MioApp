// swift-tools-version:5.9
// macOS 上验证内置浏览器的拦截核心（与 App 编译同一份 ios/App/App/MioAdblockCore.swift，CI 构建前复制进来）：
// 转换 + WKContentRuleListStore 编译全部内置列表、查询 YouTube 的高级规则，并用 WKWebView 实际加载页面做开 / 关对比。
import PackageDescription

let package = Package(
    name: "AdblockCheck",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/AdguardTeam/SafariConverterLib.git", exact: "4.3.1"),
    ],
    targets: [
        .executableTarget(
            name: "AdblockCheck",
            dependencies: [.product(name: "ContentBlockerConverter", package: "SafariConverterLib")]
        ),
    ]
)
