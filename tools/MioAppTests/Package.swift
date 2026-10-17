// swift-tools-version:5.9
// App 里不依赖 UIKit / WebKit 的纯逻辑单测（Linux / macOS 都能跑：swift test）。
// Sources/MioWebCompat/MioWebCompat.swift 是指向 ios/App/App/MioWebCompat.swift 的符号链接——测的就是 App 编译的那一份。
// 注入页面的 JS（同一个 Swift 文件里的 MIO_JS_BEGIN/END 段）由 js/*.test.mjs 用 node --test 跑。
import PackageDescription

let package = Package(
    name: "MioAppTests",
    targets: [
        .target(name: "MioWebCompat", path: "Sources/MioWebCompat"),
        .testTarget(name: "MioWebCompatTests", dependencies: ["MioWebCompat"], path: "Tests/MioWebCompatTests"),
        // 软件内更新纯逻辑：Sources/MioUpdateCore/MioUpdateCore.swift → ios/App/App/MioUpdateCore.swift（符号链接）
        .target(name: "MioUpdateCore", path: "Sources/MioUpdateCore"),
        .testTarget(name: "MioUpdateCoreTests", dependencies: ["MioUpdateCore"], path: "Tests/MioUpdateCoreTests"),
    ]
)
