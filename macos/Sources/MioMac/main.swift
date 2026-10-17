// MioMac 入口：纯 AppKit 生命周期（没有 storyboard / nib，菜单和窗口都在代码里建）
import AppKit

// 顶层代码在主线程跑，但 Swift 5 模式下不被视为 MainActor 隔离 → 显式断言
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let appDelegate = MioMacAppDelegate()
    app.delegate = appDelegate
    app.setActivationPolicy(.regular)
    withExtendedLifetime(appDelegate) { app.run() }
}
