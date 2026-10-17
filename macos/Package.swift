// swift-tools-version:5.9
// MioMac — 原生 macOS（AppKit）版 Mio 浏览器壳（可行性验证 / 骨架，feat/mac-native）。
//
// 为什么不是 Mac Catalyst：Catalyst 进程里的 WKWebView 按 iOS 配置编译，MediaSource / ManagedMediaSource 都是 undefined，
// YouTube 桌面版只能拿到 360p 渐进式 mp4；AppKit 的 WKWebView 与 Safari 同一套 WebKit 配置，有 MSE（CI 冒烟里有证据）。
//
// 结构：
//   Sources/MioMac/Shared/*.swift  → 符号链接到 ios/App/App/ 下只依赖 Foundation 的核心（标签 / 容器 / 缩放 / UA / 注入脚本 /
//                                    用户脚本 / 翻译 / 阅读 / WebRTC / 更新 纯逻辑）。iOS target 编译原文件，这里编译同一份——一套 Swift 代码。
//   Sources/MioMac/Kit/*.swift     → v0.4.0 两端共用的新层（只依赖 Foundation / SwiftUI）：MioModule 模块接口 + 内置模块、
//                                    SwiftUI 设置页（Safari 分区 + Mio 分区）、SwiftUI 侧边栏。iOS 以后直接编译同一批文件。
//   Sources/MioMac/*.swift         → AppKit 壳：窗口 + Safari 风格工具栏 / 侧边栏 + 标签条 + 菜单 / 快捷键 + CI 冒烟。
//
// 用 SwiftPM 而不是在 App.xcodeproj 里加 target：不碰 project.pbxproj（与 iOS 布局改动零冲突），Linux 上也能单测纯逻辑。
// 打包成 .app：scripts/bundle.sh（Info.plist + 可执行文件 + ad-hoc 签名）。签名 / 公证 / Sparkle 见 docs/mac-native-migration.md。
import PackageDescription

let package = Package(
    name: "MioMac",
    platforms: [.macOS(.v14)], // WKWebsiteDataStore(forIdentifier:)（容器）需要 macOS 14
    targets: [
        .executableTarget(
            name: "MioMac",
            path: "Sources/MioMac"
        ),
    ]
)
