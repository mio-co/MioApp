// MioLinkOpening.swift — 链接 / 弹窗开在哪：当前标签、前台新标签、后台新标签（只依赖 Foundation，Linux 上单测）。
//
// Mac 照 Firefox 桌面版：
//   - 普通左键点 target=_blank、页面 window.open（用户手势触发）→ 前台新标签（Firefox browser.tabs.loadDivertedInBackground = false）
//   - ⌘ 点链接 / 中键点链接 → 后台新标签（browser.tabs.loadInBackground = true）；⇧⌘ / ⇧中键 → 前台新标签
//   - 普通左键点同标签链接 → 交给 WebKit（当前标签跳转）
// iOS / iPadOS：新标签一律前台（Firefox iOS 默认；⌘ 点只在接了键盘的 iPad 上有，也开前台）。
//
// Cloudflare Access 登录弹窗是否在打开者标签继续由 MioAccessAuth.popupDisposition 先判断，这里只管「新标签开在前台还是后台」。

import Foundation

public enum MioLinkOpening {
    public enum Disposition: Equatable {
        /// 交给 WebKit：当前标签跳转（同标签链接）
        case currentTab
        case foregroundTab
        case backgroundTab
    }

    public enum Platform: Equatable { case mac, ios }

    /// 修饰键（与 NSEvent.ModifierFlags / UIKeyModifierFlags 无关的纯数据，宿主自己换算）
    public struct Modifiers: OptionSet, Equatable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let control = Modifiers(rawValue: 1 << 3)
    }

    /// WKNavigationAction.buttonNumber（macOS）是 WebKit 的按键位掩码：左键 1、右键 2、中键 4（没有鼠标事件时 0）
    public static let middleButtonMask = 4

    public static func isMiddleButton(_ buttonNumber: Int) -> Bool {
        buttonNumber & middleButtonMask != 0
    }

    /// ⌘ 点 / 中键点：要开新标签（不管链接本身有没有 target=_blank）
    public static func wantsNewTab(modifiers: Modifiers, buttonNumber: Int) -> Bool {
        modifiers.contains(.command) || isMiddleButton(buttonNumber)
    }

    /// 页面里的点链接（decidePolicyFor，navigationType == linkActivated）：
    /// ⌘ / 中键点 http(s) 链接 → 新标签（Mac 后台，带 ⇧ 前台；iOS 前台）；其余 → currentTab（交给 WebKit：同标签跳转，或 target=_blank 走 createWebViewWith）
    public static func linkActivation(platform: Platform, isLinkActivated: Bool, isHTTP: Bool,
                                      modifiers: Modifiers, buttonNumber: Int) -> Disposition {
        guard isLinkActivated, isHTTP, wantsNewTab(modifiers: modifiers, buttonNumber: buttonNumber) else { return .currentTab }
        return newTabPlacement(platform: platform, modifiers: modifiers, buttonNumber: buttonNumber)
    }

    /// 新窗口请求（createWebViewWith：target=_blank、window.open、⌘ / 中键点 target=_blank）开在前台还是后台
    public static func newWindow(platform: Platform, modifiers: Modifiers, buttonNumber: Int) -> Disposition {
        newTabPlacement(platform: platform, modifiers: modifiers, buttonNumber: buttonNumber)
    }

    static func newTabPlacement(platform: Platform, modifiers: Modifiers, buttonNumber: Int) -> Disposition {
        guard platform == .mac else { return .foregroundTab }
        guard wantsNewTab(modifiers: modifiers, buttonNumber: buttonNumber) else { return .foregroundTab }
        return modifiers.contains(.shift) ? .foregroundTab : .backgroundTab
    }
}
