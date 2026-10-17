// MioMobileChromeCore.swift — 手机端内置浏览器（iPhone）照搬 iOS 27 Safari 布局的纯逻辑（不依赖 UIKit，单测在 tools/MioAppTests）
//
// - 三种布局（设置里可选，默认紧凑）：
//   紧凑 compact：页面上方没有任何栏；底部一条悬浮胶囊：后退 · 页面菜单 · 地址栏（域名 + 进度 + 刷新/停止）· 标签按钮
//   底部 bottom：经典 iOS 底部，地址栏一行 + 下面工具按钮一行（后退 前进 分享 存到 Mio 标签）
//   顶部 top：地址栏在顶部，工具按钮在底部
//   三种布局向下滚动都收缩成一个小域名胶囊 / 域名条（不是完全消失），向上滚动或点它恢复。
// - 地址栏手势：左右滑动切换标签（最后一个再往左 = 新建标签，Safari 行为），上滑 = 标签概览。
// - 页面菜单：所有原来散在底部工具栏 / 顶栏的功能都收进来。

import Foundation

/// 手机端浏览器布局（UserDefaults mio.browser.layout / Android BrowserPrefs "browser.layout"）
enum MioBrowserLayout: String, CaseIterable, Equatable {
    case compact, bottom, top

    static let defaultLayout: MioBrowserLayout = .compact

    static func parse(_ raw: String?) -> MioBrowserLayout {
        MioBrowserLayout(rawValue: (raw ?? "").trimmingCharacters(in: .whitespaces).lowercased()) ?? defaultLayout
    }

    var title: String {
        switch self {
        case .compact: return "紧凑"
        case .bottom: return "底部"
        case .top: return "顶部"
        }
    }

    var detail: String {
        switch self {
        case .compact: return "页面上方无栏，底部悬浮一条胶囊（后退、页面菜单、地址栏、标签）"
        case .bottom: return "地址栏和工具按钮都在底部"
        case .top: return "地址栏在顶部，工具按钮在底部"
        }
    }

    /// 地址栏在页面上方
    var addressOnTop: Bool { self == .top }
    /// 地址栏下面 / 底部还有一行工具按钮（后退 前进 分享 存到 Mio 标签）
    var hasToolbarRow: Bool { self != .compact }
    /// 页面菜单按钮放在地址栏里（底部 / 顶部布局；紧凑布局是胶囊里单独的按钮）
    var menuInAddressBar: Bool { self != .compact }
}

enum MioMobileChromeCore {
    // MARK: 域名显示

    /// 地址栏 / 收缩胶囊里显示的域名：小写、去掉端口 / 账号 / 路径和 www.（与 Safari 一样）
    static func displayHost(_ url: String?) -> String {
        guard let s = url?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return "" }
        var host: String
        if let r = s.range(of: "://") {
            host = String(s[r.upperBound...])
        } else {
            host = s
        }
        if let i = host.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { host = String(host[..<i]) }
        if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        if host.hasPrefix("[") {
            // IPv6 字面量：保留方括号里的内容
            if let end = host.firstIndex(of: "]") { return String(host[host.index(after: host.startIndex)..<end]).lowercased() }
            return host.lowercased()
        }
        if let colon = host.lastIndex(of: ":") { host = String(host[..<colon]) }
        host = host.lowercased()
        if host.hasPrefix("www."), host.dropFirst(4).contains(".") { host = String(host.dropFirst(4)) }
        return host
    }

    // MARK: 地址栏手势

    enum Swipe: Equatable { case none, previousTab, nextTab, overview }

    /// 地址栏上的拖动手势结束时分类。dx / dy：位移（pt，向右 / 向下为正）；vx / vy：速度（pt/s）
    /// - 左滑（dx < 0）= 下一个标签（右边那个），右滑 = 上一个；上滑 = 标签概览
    /// - 方向必须明显占优（另一方向的 1.5 倍），轻微抖动不算
    static func classifySwipe(dx: Double, dy: Double, vx: Double = 0, vy: Double = 0) -> Swipe {
        let ax = abs(dx), ay = abs(dy)
        let horizontal = ax > ay * 1.5
        let vertical = ay > ax * 1.5
        if horizontal && (ax >= 50 || (ax >= 20 && abs(vx) >= 500)) {
            return dx < 0 ? .nextTab : .previousTab
        }
        if vertical && dy < 0 && (ay >= 40 || (ay >= 15 && vy <= -600)) {
            return .overview
        }
        return .none
    }

    enum TabSwitch: Equatable { case none, select(Int), newTab }

    /// 滑动切换标签的目标：下一个到最后时新建标签（Safari），上一个到最前时不动
    static func tabSwitch(ids: [Int], active: Int?, swipe: Swipe) -> TabSwitch {
        guard let a = active, let i = ids.firstIndex(of: a) else { return ids.isEmpty ? (swipe == .nextTab ? .newTab : .none) : .select(ids[0]) }
        switch swipe {
        case .nextTab: return i + 1 < ids.count ? .select(ids[i + 1]) : .newTab
        case .previousTab: return i > 0 ? .select(ids[i - 1]) : .none
        default: return .none
        }
    }

    // MARK: 内容让位（webView 铺满整个屏幕，栏浮在上面，用 contentInset 让出位置）

    struct Geometry: Equatable {
        var viewHeight: Double
        var safeTop: Double
        var safeBottom: Double
        /// 底部栏（紧凑胶囊 / 底部布局的两行 / 顶部布局的工具行）可见时的最上沿 y；没有底部栏 = viewHeight
        var bottomChromeMinY: Double
        /// 收缩后的底部域名胶囊最上沿 y（紧凑 / 底部布局）
        var collapsedPillMinY: Double
        /// 顶部布局：顶部栏展开 / 收缩时的最下沿 y
        var topChromeMaxY: Double
        var collapsedTopMaxY: Double

        init(viewHeight: Double, safeTop: Double, safeBottom: Double, bottomChromeMinY: Double, collapsedPillMinY: Double,
             topChromeMaxY: Double = 0, collapsedTopMaxY: Double = 0) {
            self.viewHeight = viewHeight
            self.safeTop = safeTop
            self.safeBottom = safeBottom
            self.bottomChromeMinY = bottomChromeMinY
            self.collapsedPillMinY = collapsedPillMinY
            self.topChromeMaxY = topChromeMaxY
            self.collapsedTopMaxY = collapsedTopMaxY
        }
    }

    /// 返回 (top, bottom) contentInset。
    /// - 紧凑 / 底部：顶部只让出状态栏（页面上方没有栏，内容可以滚到状态栏下面）；底部让出栏 / 胶囊
    /// - 顶部：顶部让出地址栏（收缩时让出域名条）；底部让出工具行（收缩时只让出安全区）
    static func contentInsets(layout: MioBrowserLayout, collapsed: Bool, g: Geometry) -> (top: Double, bottom: Double) {
        let gap = 6.0
        switch layout {
        case .compact, .bottom:
            let minY = collapsed ? g.collapsedPillMinY : g.bottomChromeMinY
            return (max(0, g.safeTop), max(g.safeBottom, g.viewHeight - minY + (collapsed ? 2 : gap)))
        case .top:
            let top = collapsed ? g.collapsedTopMaxY : g.topChromeMaxY
            let bottom = collapsed ? g.safeBottom : max(g.safeBottom, g.viewHeight - g.bottomChromeMinY)
            return (max(g.safeTop, top), max(0, bottom))
        }
    }

    /// 自动收缩状态机（MioToolbarAutoHide）的「到顶」位置：收缩时的顶部 inset
    static func hiddenTopInset(layout: MioBrowserLayout, g: Geometry) -> Double {
        layout == .top ? max(g.safeTop, g.collapsedTopMaxY) : max(0, g.safeTop)
    }

    // MARK: 页面菜单

    /// 页面菜单条目（id 与 Android 一致；平台不支持的条目由调用方过滤）
    enum MenuItem: String, CaseIterable, Equatable {
        // 页面
        case forward, share, findInPage, requestDesktop, openExternal
        // 翻译
        case translateBilingual, translateOnly, translateOff, translateAuto, translateTarget, translateSettings
        // 阅读与外观
        case reader, darkSite, darkAll, pageToolsSettings
        // 存到 Mio
        case saveBookmark, saveNote, saveClip
        // 拦截与隐私
        case adblock, adblockSite, webrtcSite, userScripts, youtubeFocus, adblockSettings
        // 容器
        case openInContainer, siteContainer
        // Mio
        case settings, backToMio
    }

    struct MenuSection: Equatable {
        let title: String
        let items: [MenuItem]
    }

    /// 当前页面的状态（决定哪些条目出现）
    struct MenuContext: Equatable {
        var isWebPage: Bool = true
        var host: String? = nil
        var translateAvailable: Bool = true
        /// 翻译模式：off / bilingual / translation
        var translateMode: String = "off"
        var adblockEnabled: Bool = true
        var webrtcGuardEnabled: Bool = true
        var findSupported: Bool = true
        var desktopSupported: Bool = true
        /// 系统支持容器（iOS 17+ / Android MULTI_PROFILE）
        var containersSupported: Bool = true

        init(isWebPage: Bool = true, host: String? = nil, translateAvailable: Bool = true, translateMode: String = "off",
             adblockEnabled: Bool = true, webrtcGuardEnabled: Bool = true, findSupported: Bool = true, desktopSupported: Bool = true,
             containersSupported: Bool = true) {
            self.containersSupported = containersSupported
            self.isWebPage = isWebPage
            self.host = host
            self.translateAvailable = translateAvailable
            self.translateMode = translateMode
            self.adblockEnabled = adblockEnabled
            self.webrtcGuardEnabled = webrtcGuardEnabled
            self.findSupported = findSupported
            self.desktopSupported = desktopSupported
        }
    }

    static func menuSections(_ c: MenuContext) -> [MenuSection] {
        let hasHost = !(c.host ?? "").isEmpty
        var page: [MenuItem] = [.forward]
        if c.isWebPage { page.append(.share) }
        if c.isWebPage && c.findSupported { page.append(.findInPage) }
        if c.isWebPage && c.desktopSupported { page.append(.requestDesktop) }
        page.append(.openExternal)

        var translate: [MenuItem] = []
        if c.isWebPage && c.translateAvailable {
            translate = [.translateBilingual, .translateOnly]
            if c.translateMode != "off" { translate.append(.translateOff) }
            if hasHost { translate.append(.translateAuto) }
        }
        translate += [.translateTarget, .translateSettings]

        var look: [MenuItem] = []
        if c.isWebPage { look.append(.reader) }
        if hasHost { look.append(.darkSite) }
        look += [.darkAll, .pageToolsSettings]

        var privacy: [MenuItem] = [.adblock]
        if hasHost && c.adblockEnabled { privacy.append(.adblockSite) }
        if hasHost && c.webrtcGuardEnabled { privacy.append(.webrtcSite) }
        privacy += [.userScripts, .youtubeFocus, .adblockSettings]

        var out: [MenuSection] = [MenuSection(title: "页面", items: page), MenuSection(title: "翻译", items: translate),
                                  MenuSection(title: "阅读与外观", items: look)]
        if c.isWebPage { out.append(MenuSection(title: "存到 Mio", items: [.saveBookmark, .saveNote, .saveClip])) }
        if c.isWebPage && hasHost && c.containersSupported {
            out.append(MenuSection(title: "容器", items: [.openInContainer, .siteContainer]))
        }
        out.append(MenuSection(title: "拦截与隐私", items: privacy))
        out.append(MenuSection(title: "Mio", items: [.settings, .backToMio]))
        return out
    }

    /// 条目标题（开关类条目的状态由 UI 另外显示勾选 / 开关）
    static func title(_ item: MenuItem, desktop: Bool = false, systemBrowser: String = "Safari", targetLanguage: String = "") -> String {
        switch item {
        case .forward: return "前进"
        case .share: return "分享"
        case .findInPage: return "查找页面内容"
        case .requestDesktop: return desktop ? "请求移动网站" : "请求桌面网站"
        case .openExternal: return "用 \(systemBrowser) 打开"
        case .translateBilingual: return "翻译：双语对照"
        case .translateOnly: return "翻译：仅显示译文"
        case .translateOff: return "显示原文"
        case .translateAuto: return "总是翻译此网站"
        case .translateTarget: return targetLanguage.isEmpty ? "译为…" : "译为 \(targetLanguage)"
        case .translateSettings: return "翻译设置…"
        case .reader: return "阅读模式"
        case .darkSite: return "此网站强制深色"
        case .darkAll: return "所有网站强制深色"
        case .pageToolsSettings: return "阅读、深色与存到 Mio 设置…"
        case .saveBookmark: return "存为导航书签"
        case .saveNote: return "存为笔记"
        case .saveClip: return "推到云剪贴板"
        case .adblock: return "广告拦截"
        case .adblockSite: return "在此网站拦截广告"
        case .webrtcSite: return "此网站允许 WebRTC（网页通话）"
        case .userScripts: return "用户脚本…"
        case .youtubeFocus: return "YouTube 防沉迷"
        case .adblockSettings: return "拦截设置…"
        case .openInContainer: return "在容器中打开此页…"
        case .siteContainer: return "此网站始终用某容器打开…"
        case .settings: return "浏览器设置…"
        case .backToMio: return "回到 Mio 导航"
        }
    }

    /// 原来底部工具栏 / 顶栏上的每个入口在页面菜单（或胶囊 / 标签按钮）里的去处。单测保证一个都不丢。
    static let legacyToolbarEntries: [String: String] = [
        "back": "capsule.back",
        "forward": "menu.forward",
        "reload": "capsule.reload",
        "share": "menu.share",
        "translate": "menu.translateBilingual",
        "safari": "menu.openExternal",
        "pageTools": "menu.saveBookmark",
        "reader": "menu.reader",
        "settings": "menu.settings",
        "shield": "menu.adblock",
        "tabs": "capsule.tabs",
        "close": "tabsMenu.backToMio",
    ]
}
