// MioCloseAfterExternal.swift — 「跳转系统浏览器后自动关闭标签页」（默认关）
//
// 内置浏览器的「用 Safari 打开」（工具栏按钮、⌘⇧O / 菜单「浏览器 › 用 Safari 打开」、通行密钥提示、设置页「用 Safari 打开当前网页」）
// 交给系统后：开关开启且 UIApplication.open 的 completion 报告 success == true 时，关闭内置浏览器（与点 ✕ 相同：dismiss 回到主界面，App 不退出）。
// 打开失败（success == false）不关闭。iOS 与 Mac Catalyst 共用（Catalyst 上 UIApplication.open 由系统转给 NSWorkspace）。
// 只依赖 Foundation：tools/MioAppTests 在 Linux 上单测（open / close 注入）。

import Foundation

enum MioCloseAfterExternal {
    static let enabledKey = "mio.closeTab.afterExternal"

    /// 设置开关（UserDefaults，默认关）
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    static func setEnabled(_ on: Bool, _ defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: enabledKey)
    }

    static var enabled: Bool {
        get { isEnabled() }
        set { setEnabled(newValue) }
    }

    static func shouldClose(enabled: Bool, opened: Bool) -> Bool { enabled && opened }

    /// 把 url 交给系统浏览器；open 的回调报告成功且开关开启时调用 close。
    /// - Parameters:
    ///   - open: 真正的打开动作（App 里是 UIApplication.shared.open(_:options:completionHandler:)），回调参数 = 是否成功
    ///   - close: 关闭当前标签页
    ///   - completion: 可选，报告 (opened, closed)
    static func handOff(_ url: URL,
                        enabled: Bool,
                        open: (URL, @escaping (Bool) -> Void) -> Void,
                        close: @escaping () -> Void,
                        completion: ((Bool, Bool) -> Void)? = nil) {
        open(url) { ok in
            let c = shouldClose(enabled: enabled, opened: ok)
            if c { close() }
            completion?(ok, c)
        }
    }
}
