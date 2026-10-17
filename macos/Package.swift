// swift-tools-version:5.9
// MioMac — 原生 macOS（AppKit）版 Mio 浏览器壳（可行性验证 / 骨架，feat/mac-native）。
//
// 为什么不是 Mac Catalyst：Catalyst 进程里的 WKWebView 按 iOS 配置编译，MediaSource / ManagedMediaSource 都是 undefined，
// YouTube 桌面版只能拿到 360p 渐进式 mp4；AppKit 的 WKWebView 与 Safari 同一套 WebKit 配置，有 MSE（CI 冒烟里有证据）。
//
// 结构：
//   Sources/MioMac/Shared/MioDesktopParityCore.swift → 符号链接到 ios/App/App（MioZoomCore：Safari 缩放档位）。
//   apple/MioKit（本地 SwiftPM 依赖，线路 C）→ 全部浏览器逻辑：Mio 扩展模块 + 注册表 + 设置数据模型、广告拦截（WKContentRuleList）、
//                                    用户脚本引擎、容器、MioCore 本机桥、mio:// 方案、标签 / UA / 注入脚本核心。iOS fork 用同一个包。
//   Sources/MioMac/Chrome/*.swift    → Firefox 桌面风格的界面（标签条、导航栏、面板、设置窗口、动画）。
//   Sources/MioMac/*.swift           → AppKit 壳：窗口、MioKit 宿主（MioMacKit）、菜单 / 快捷键、CI 冒烟。
//
// 用 SwiftPM 而不是在 App.xcodeproj 里加 target：不碰 project.pbxproj，Linux 上也能单测纯逻辑。
// 打包成 .app：scripts/bundle.sh（Info.plist + 可执行文件 + MioKit 资源包 + ad-hoc 签名）。签名 / 公证 / Sparkle 见 docs/mac-native-migration.md。
import PackageDescription

let package = Package(
    name: "MioMac",
    platforms: [.macOS(.v14)], // WKWebsiteDataStore(forIdentifier:)（容器）需要 macOS 14
    dependencies: [
        .package(path: "../apple/MioKit"),
    ],
    targets: [
        .executableTarget(
            name: "MioMac",
            dependencies: [.product(name: "MioKit", package: "MioKit")],
            path: "Sources/MioMac"
        ),
    ]
)
