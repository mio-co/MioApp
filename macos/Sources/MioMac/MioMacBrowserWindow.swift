// MioMacBrowserWindow.swift — 原生 macOS 浏览器窗口（浏览器是 App 本体，MioCore 是 mio://home 首页）。界面照 Firefox 桌面版：
//
//   ┌───────────────────────────────────────────────────────────────┐
//   │ ● ● ●  [标签][标签][标签……]  +                          ⌄    │  标签条（与红绿灯同一行，40pt）
//   │ ▯ ← → ⟳      [🛡🔒 example.com/path        125% ☆]      🧩 ≡  │  导航栏（40pt，底部 2pt 加载进度条）
//   ├─────────┬─────────────────────────────────────────────────────┤
//   │ 垂直标签 │                     网页（WKWebView）                │  侧边栏可选（滑入滑出）
//   │ （可选） ├─────────────────────────────────────────────────────┤
//   │         │ 🔍 在页面中查找  ↑ ↓  □区分大小写   第 1 个，共 3 个  ✕ │  查找栏（⌘F 从底部滑出）
//   └─────────┴─────────────────────────────────────────────────────┘
//
//   保留：多标签（MioTabStore，与 iOS 同一套规则）、容器、按站点缩放（MioZoomCore）、会话恢复、⌘点后台标签、window.open、
//   alert/confirm、文件上传、模块注入（MioModuleRegistry）。触控板左右滑前进后退 / 双指缩放由 WKWebView 原生手势提供。

import AppKit
import SwiftUI
import WebKit

@MainActor
final class MioMacBrowserWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    static let zoomSitesKey = "mio.zoom.sites"     // = MioDesktopParity（Catalyst）同名 key，存的是 Safari 档位
    static let zoomDefaultKey = "mio.zoom.default"
    static let newTabKey = "mio.tabs.newTabURL"
    static let sidebarKey = "mio.mac.sidebarVisible"
    static let sessionKey = "mio.mac.tabs.session"
    static let sessionPinnedKey = "mio.mac.tabs.pinned"

    let store = MioTabStore()
    private(set) var webViews: [Int: WKWebView] = [:]
    private var observations: [Int: [NSKeyValueObservation]] = [:]
    /// 冒烟用：每个标签最近一次导航结束（成功 / 失败）
    private(set) var finished: Set<Int> = []
    private(set) var lastError: [Int: String] = [:]
    private(set) var pinned: Set<Int> = []
    private(set) var muted: Set<Int> = []
    private(set) var audible: Set<Int> = []
    var favicons: [Int: NSImage] = [:]

    let root = MioMacFlippedView()
    let tabBar = MioMacTabBar()
    let navBar = MioMacNavBar()
    let webContainer = NSView()
    let sidebarContainer = NSView()
    let verticalTabs = MioMacVerticalTabsModel()
    let findBar = MioMacFindBar()
    let zoomHUD = MioMacZoomHUD()
    let toast = MioMacToast()
    private var tabBarHeight: NSLayoutConstraint?
    private var sidebarWidth: NSLayoutConstraint?
    private var findBarHeight: NSLayoutConstraint?
    private(set) var sidebarVisible = false
    private(set) var findBarVisible = false
    private(set) var verticalTabsMode = false
    private var audioTimer: Timer?

    var onClose: ((MioMacBrowserWindowController) -> Void)?
    /// 模块动作「打开设置」交给 App（设置窗口是全局的）
    var onOpenSettings: ((MioMacPrefsPane) -> Void)?
    /// 标签拖出成新窗口：App 建新窗口并接收这个 WKWebView
    var onDetach: ((MioMacBrowserWindowController, WKWebView, MioTab, Bool, NSPoint) -> Void)?
    var onNewWindow: (() -> Void)?

    static let sidebarWidthValue: CGFloat = 250

    private var zoomTable: MioZoomCore.SiteTable {
        get { MioZoomCore.SiteTable(json: UserDefaults.standard.string(forKey: Self.zoomSitesKey)) }
        set { UserDefaults.standard.set(newValue.json, forKey: Self.zoomSitesKey) }
    }
    var defaultZoom: Double {
        let v = UserDefaults.standard.double(forKey: Self.zoomDefaultKey)
        return v > 0 ? MioZoomCore.nearest(v) : 1.0
    }

    /// mio://home 实际加载的地址（设置里自定义了主页就用自定义的）
    static var homeLoadURL: String { MioMacHome.loadURL(custom: UserDefaults.standard.string(forKey: newTabKey)) }
    /// 新标签页 = Mio 首页
    static var newTabURL: String { homeLoadURL }

    init(size requested: NSSize = NSSize(width: 1280, height: 820)) {
        var size = requested
        if let vf = NSScreen.main?.visibleFrame { size = NSSize(width: min(requested.width, vf.width - 40), height: min(requested.height, vf.height - 30)) }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Mio"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true   // 标签条画在标题栏位置（Firefox 在 macOS 上的样子）
        w.minSize = NSSize(width: 560, height: 380)
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed // 标签由我们自己的标签条管理（与 MioTabStore 一致），不用系统窗口标签
        w.collectionBehavior.insert(.fullScreenPrimary)
        w.animationBehavior = .documentWindow
        super.init(window: w)
        w.delegate = self
        buildContent()
        w.setContentSize(size)
        w.center()
        applyPreferences(animated: false)
        startAudioPolling()
        NotificationCenter.default.addObserver(self, selector: #selector(reduceMotionChanged(_:)),
                                               name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - UI

    private func buildContent() {
        guard let w = window else { return }
        w.contentView = root
        root.wantsLayer = true
        for v in [sidebarContainer, webContainer, findBar, navBar, tabBar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        webContainer.wantsLayer = true
        webContainer.setAccessibilityIdentifier("mio.web")
        findBar.layer?.masksToBounds = true
        findBar.isHidden = true
        sidebarContainer.wantsLayer = true
        sidebarContainer.layer?.masksToBounds = true
        let host = NSHostingView(rootView: MioMacVerticalTabsView(model: verticalTabs))
        host.translatesAutoresizingMaskIntoConstraints = false
        sidebarContainer.addSubview(host)
        let edge = NSView()
        edge.wantsLayer = true
        edge.layer?.backgroundColor = MioTheme.cg(MioTheme.separator, in: root)
        edge.translatesAutoresizingMaskIntoConstraints = false
        sidebarContainer.addSubview(edge)

        let tbh = tabBar.heightAnchor.constraint(equalToConstant: MioMacTabBar.height)
        let sw = sidebarContainer.widthAnchor.constraint(equalToConstant: 0)
        let fh = findBar.heightAnchor.constraint(equalToConstant: 0)
        tabBarHeight = tbh; sidebarWidth = sw; findBarHeight = fh
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: root.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tbh,
            navBar.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            navBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            navBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            navBar.heightAnchor.constraint(equalToConstant: MioMacNavBar.height),
            sidebarContainer.topAnchor.constraint(equalTo: navBar.bottomAnchor),
            sidebarContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebarContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sw,
            host.topAnchor.constraint(equalTo: sidebarContainer.topAnchor),
            host.bottomAnchor.constraint(equalTo: sidebarContainer.bottomAnchor),
            host.trailingAnchor.constraint(equalTo: edge.leadingAnchor),
            host.widthAnchor.constraint(equalToConstant: Self.sidebarWidthValue - 1),
            edge.topAnchor.constraint(equalTo: sidebarContainer.topAnchor),
            edge.bottomAnchor.constraint(equalTo: sidebarContainer.bottomAnchor),
            edge.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
            edge.widthAnchor.constraint(equalToConstant: 1),
            webContainer.topAnchor.constraint(equalTo: navBar.bottomAnchor),
            webContainer.leadingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
            webContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            webContainer.bottomAnchor.constraint(equalTo: findBar.topAnchor),
            findBar.leadingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
            findBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            findBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            fh,
        ])

        // 标签条
        tabBar.onSelect = { [weak self] id in self?.select(id) }
        tabBar.onClose = { [weak self] id in self?.closeTab(id) }
        tabBar.onNewTab = { [weak self] in self?.newTab(); self?.focusAddressBar() }
        tabBar.onMove = { [weak self] id, to in self?.moveTab(id, to: to) }
        tabBar.onDetach = { [weak self] id, p in self?.detachTab(id, at: p) }
        tabBar.onToggleMute = { [weak self] id in self?.toggleMute(id) }
        tabBar.onListAll = { [weak self] v in self?.showAllTabsPanel(from: v) }
        tabBar.contextMenu = { [weak self] id in self?.tabContextMenu(id) }
        tabBar.canDetach = { [weak self] in (self?.store.count ?? 0) > 1 }

        // 垂直标签
        verticalTabs.onSelect = { [weak self] id in self?.select(id) }
        verticalTabs.onClose = { [weak self] id in self?.closeTab(id) }
        verticalTabs.onNewTab = { [weak self] cid in self?.newTab(containerID: cid); self?.focusAddressBar() }
        verticalTabs.onMove = { [weak self] id, to in self?.moveTab(id, to: to) }
        verticalTabs.onHome = { [weak self] in self?.newTab(url: MioMacHome.address) }
        verticalTabs.onToggleMute = { [weak self] id in self?.toggleMute(id) }

        // 导航栏
        navBar.sidebarButton.onClick = { [weak self] in self?.toggleSidebar(nil) }
        navBar.backButton.onClick = { [weak self] in self?.goBack(nil) }
        navBar.forwardButton.onClick = { [weak self] in self?.goForward(nil) }
        navBar.reloadButton.onClick = { [weak self] in
            guard let self, let wv = self.activeWebView else { return }
            if wv.isLoading { wv.stopLoading() } else { wv.reload() }
        }
        navBar.extensionsButton.onClick = { [weak self] in self?.showExtensionsPanel() }
        navBar.menuButton.onClick = { [weak self] in self?.showAppMenu() }
        let bar = navBar.urlBar
        bar.suggestionsFor = { [weak self] q in self?.suggestions(for: q) ?? [] }
        bar.onPick = { [weak self] s in self?.pickSuggestion(s) }
        bar.onSubmit = { [weak self] text in self?.submitAddress(text) }
        bar.onEscapeToPage = { [weak self] in if let wv = self?.activeWebView { self?.window?.makeFirstResponder(wv) } }
        bar.starButton.onClick = { [weak self] in self?.toggleBookmark(nil) }
        bar.zoomButton.onClick = { [weak self] in self?.zoomReset(nil) }
        bar.identityButton.onClick = { [weak self] in self?.showIdentityPanel() }
        bar.shieldButton.onClick = { [weak self] in self?.showShieldPanel() }

        findBar.onClose = { [weak self] in self?.hideFindBar() }
    }

    // MARK: - 偏好（垂直标签、外观、减少动态效果）

    func applyPreferences(animated: Bool = true) {
        let vertical = UserDefaults.standard.bool(forKey: MioMacPreferencesView.verticalTabsKey)
        let modeChanged = vertical != verticalTabsMode
        verticalTabsMode = vertical
        let full = window?.styleMask.contains(.fullScreen) ?? false
        let change = {
            self.tabBarHeight?.constant = vertical ? 0 : MioMacTabBar.height
            self.tabBar.alphaValue = vertical ? 0 : 1
            self.navBar.leadingInset = vertical && !full ? MioTrafficLights.reservedWidth : 8
            self.root.layoutSubtreeIfNeeded()
        }
        if animated { MioMotion.animate(MioMotion.normal, change) } else { change() }
        tabBar.isHidden = false
        if modeChanged || !animated {
            let wantSidebar = vertical || UserDefaults.standard.bool(forKey: Self.sidebarKey)
            setSidebar(visible: wantSidebar, animated: animated)
        }
        verticalTabs.reduceMotion = MioMotion.reduce
        positionTrafficLights()
    }

    @objc private func reduceMotionChanged(_ n: Notification) {
        verticalTabs.reduceMotion = MioMotion.reduce
    }

    func positionTrafficLights() {
        guard let w = window else { return }
        MioTrafficLights.keepCentered(w, rowHeight: MioMacTabBar.height)
    }

    // MARK: - 侧边栏（滑入滑出）

    @objc func toggleSidebar(_ sender: Any?) {
        setSidebar(visible: !sidebarVisible, animated: true)
        if !verticalTabsMode { UserDefaults.standard.set(sidebarVisible, forKey: Self.sidebarKey) }
    }

    func setSidebar(visible: Bool, animated: Bool = true) {
        sidebarVisible = visible
        navBar.sidebarButton.isActive = visible
        let w: CGFloat = visible ? Self.sidebarWidthValue : 0
        if animated {
            MioMotion.animate(MioMotion.slow, timing: MioMotion.easeInOut, {
                self.sidebarWidth?.constant = w
                self.root.layoutSubtreeIfNeeded()
            })
        } else {
            sidebarWidth?.constant = w
        }
    }

    // MARK: - 查找栏（底部滑出）

    @objc func showFindBar(_ sender: Any?) {
        findBar.webView = activeWebView
        if !findBarVisible {
            findBarVisible = true
            findBar.isHidden = false
            MioMotion.animate(MioMotion.normal, {
                self.findBarHeight?.constant = MioMacFindBar.height
                self.root.layoutSubtreeIfNeeded()
            })
        }
        findBar.focus()
    }

    func hideFindBar() {
        guard findBarVisible else { return }
        findBarVisible = false
        MioMotion.animate(MioMotion.fast + 0.04, {
            self.findBarHeight?.constant = 0
            self.root.layoutSubtreeIfNeeded()
        }, completion: { [weak self] in
            guard let self, !self.findBarVisible else { return }
            self.findBar.isHidden = true
        })
        if let wv = activeWebView { window?.makeFirstResponder(wv) }
    }

    @objc func findNext(_ sender: Any?) { if findBarVisible { findBar.find(backwards: false) } else { showFindBar(sender) } }
    @objc func findPrevious(_ sender: Any?) { if findBarVisible { findBar.find(backwards: true) } else { showFindBar(sender) } }

    // MARK: - Modules

    var currentPage: MioPageContext {
        MioPageContext(url: activeWebView?.url, title: activeWebView?.title ?? "")
    }

    func performModuleAction(_ action: MioModuleAction) {
        switch action {
        case .none: break
        case .openURL(let u, let inNewTab):
            let s = u.absoluteString == MioCoreModuleHome.legacyNav ? MioMacHome.address : u.absoluteString
            if inNewTab || activeWebView == nil { newTab(url: s) } else { navigate(activeWebView, to: s) }
        case .evaluateJavaScript(let js):
            activeWebView?.evaluateJavaScript(js, completionHandler: nil)
        case .openSettings(let section):
            onOpenSettings?(MioMacPrefsPane(section: section))
        case .reload:
            reinstallModuleScripts()
            activeWebView?.reload()
        }
    }

    /// 模块开关 / 设置变了：所有标签重装注入脚本（下次载入生效）
    func reinstallModuleScripts() {
        for (_, wv) in webViews { MioMacWebKit.installScripts(wv.configuration.userContentController) }
        refreshChrome()
    }

    // MARK: - Tabs

    var activeWebView: WKWebView? { store.activeID.flatMap { webViews[$0] } }
    var activeTabID: Int? { store.activeID }

    private func makeWebView(containerID: String, configuration: WKWebViewConfiguration? = nil) -> WKWebView {
        let config = configuration ?? MioMacWebKit.configuration(containerID: containerID)
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.customUserAgent = MioMacWebKit.desktopUserAgent
        wv.allowsBackForwardNavigationGestures = true   // 触控板双指左右滑：前进 / 后退（带系统的页面滑动动画）
        wv.allowsMagnification = true                    // 触控板双指捏合缩放
        wv.allowsLinkPreview = true
        wv.isInspectable = true
        wv.underPageBackgroundColor = MioTheme.toolbar
        wv.translatesAutoresizingMaskIntoConstraints = false
        return wv
    }

    private func attach(_ wv: WKWebView, id: Int) {
        wv.navigationDelegate = self
        wv.uiDelegate = self
        webViews[id] = wv
        let handler: (WKWebView) -> Void = { [weak self] w in self?.webViewChanged(w) }
        let progress: (WKWebView) -> Void = { [weak self] w in self?.progressChanged(w) }
        observations[id] = [
            wv.observe(\.title, options: [.new]) { w, _ in MainActor.assumeIsolated { handler(w) } },
            wv.observe(\.url, options: [.new]) { w, _ in MainActor.assumeIsolated { handler(w) } },
            wv.observe(\.canGoBack, options: [.new]) { w, _ in MainActor.assumeIsolated { handler(w) } },
            wv.observe(\.canGoForward, options: [.new]) { w, _ in MainActor.assumeIsolated { handler(w) } },
            wv.observe(\.isLoading, options: [.new]) { w, _ in MainActor.assumeIsolated { progress(w) } },
            wv.observe(\.estimatedProgress, options: [.new]) { w, _ in MainActor.assumeIsolated { progress(w) } },
        ]
    }

    private func detachObservers(_ id: Int) {
        observations[id]?.forEach { $0.invalidate() }
        observations[id] = nil
    }

    /// 「mio://home」/ 空 → 首页实际地址
    func resolveTabURL(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return Self.homeLoadURL }
        return MioMacHome.isHomeAddress(s) ? Self.homeLoadURL : s
    }

    func isHome(_ url: URL?) -> Bool { MioMacHome.isHomePage(url, loadURL: Self.homeLoadURL) }

    /// 新建标签。configuration 非空 = 页面 window.open / target=_blank 打开（WebKit 自己加载，不能再 load）
    @discardableResult
    func newTab(url: String? = nil, containerID: String? = nil, activate: Bool = true, fromActive: Bool = false,
                configuration: WKWebViewConfiguration? = nil) -> (id: Int, webView: WKWebView)? {
        let target = resolveTabURL(url)
        guard let t = store.add(target, title: nil, activate: activate, fromActive: fromActive, containerID: containerID) else {
            NSSound.beep()
            return nil
        }
        keepPinnedFirst(newID: t.id)
        let wv = makeWebView(containerID: t.containerID, configuration: configuration)
        attach(wv, id: t.id)
        if configuration == nil, let u = URL(string: t.url) { wv.load(URLRequest(url: u)) }
        refreshTabs()
        if store.activeID == t.id { showActive() }
        return (t.id, wv)
    }

    /// 新标签不能插进固定区
    private func keepPinnedFirst(newID: Int) {
        let pc = store.tabs.filter { pinned.contains($0.id) }.count
        if let i = store.index(of: newID), i < pc, !pinned.contains(newID) { store.move(from: i, to: pc) }
    }

    func select(_ id: Int) {
        guard store.select(id) else { return }
        refreshTabs()
        showActive()
    }

    func selectRelative(_ delta: Int) {
        guard store.selectRelative(delta) else { return }
        refreshTabs()
        showActive()
    }

    func selectNumber(_ n: Int) {
        guard store.selectNumber(n) else { return }
        refreshTabs()
        showActive()
    }

    func moveTab(_ id: Int, to index: Int) {
        guard let from = store.index(of: id) else { return }
        let pc = store.tabs.filter { pinned.contains($0.id) }.count
        var to = index
        if pinned.contains(id) { to = min(to, max(0, pc - 1)) } else { to = max(to, pc) }
        guard store.move(from: from, to: to) else { refreshTabs(); return }
        refreshTabs()
    }

    func closeTab(_ id: Int? = nil) {
        guard let id = id ?? store.activeID else { return }
        let wasLast = store.count == 1
        guard store.close(id) != nil else { return }
        if let wv = webViews.removeValue(forKey: id) {
            detachObservers(id)
            wv.stopLoading()
            wv.navigationDelegate = nil
            wv.uiDelegate = nil
            wv.removeFromSuperview()
        }
        finished.remove(id)
        lastError[id] = nil
        pinned.remove(id); muted.remove(id); audible.remove(id); favicons[id] = nil
        if wasLast || store.tabs.isEmpty {
            window?.performClose(nil) // Firefox：关掉最后一个标签 = 关窗口
            if window?.isVisible == true { window?.close() }
            return
        }
        refreshTabs()
        showActive()
    }

    func reopenClosedTab() {
        guard let t = store.reopenClosed() else { NSSound.beep(); return }
        keepPinnedFirst(newID: t.id)
        let wv = makeWebView(containerID: t.containerID)
        attach(wv, id: t.id)
        if let u = URL(string: t.url) { wv.load(URLRequest(url: u)) }
        refreshTabs()
        showActive()
    }

    func togglePin(_ id: Int) {
        guard let from = store.index(of: id) else { return }
        let pc = store.tabs.filter { pinned.contains($0.id) }.count
        if pinned.contains(id) {
            pinned.remove(id)
            store.move(from: from, to: pc - 1)
        } else {
            pinned.insert(id)
            store.move(from: from, to: pc)
        }
        refreshTabs()
    }

    func toggleMute(_ id: Int) {
        let on = !muted.contains(id)
        if on { muted.insert(id) } else { muted.remove(id) }
        applyMute(id)
        refreshTabs()
    }

    private func applyMute(_ id: Int) {
        guard let wv = webViews[id] else { return }
        let on = muted.contains(id)
        // 公开 API 没有「静音整页」：把页面里所有媒体元素静音，并对之后新加的媒体生效
        let js = """
        (function(on){window.__mioMuted=on;var f=function(r){(r||document).querySelectorAll('video,audio').forEach(function(m){m.muted=on;});};f();
        if(!window.__mioMuteObs&&on){window.__mioMuteObs=new MutationObserver(function(){if(window.__mioMuted)f();});
        window.__mioMuteObs.observe(document.documentElement,{childList:true,subtree:true});}})(\(on ? "true" : "false"))
        """
        wv.evaluateJavaScript(js, completionHandler: nil)
    }

    func duplicateTab(_ id: Int) {
        guard let t = store.tab(id) else { return }
        _ = store.select(id)
        newTab(url: webViews[id]?.url?.absoluteString ?? t.url, containerID: t.containerID, activate: true, fromActive: true)
    }

    func closeOtherTabs(_ id: Int) {
        for t in store.tabs where t.id != id && !pinned.contains(t.id) { closeTab(t.id) }
    }

    func closeTabsToRight(_ id: Int) {
        guard let i = store.index(of: id) else { return }
        for t in store.tabs.suffix(from: i + 1) { closeTab(t.id) }
    }

    func reopenInContainer(_ id: Int, containerID: String) {
        guard let t = store.tab(id), let i = store.index(of: id) else { return }
        let url = webViews[id]?.url?.absoluteString ?? t.url
        guard let n = store.add(url, title: t.title, activate: store.activeID == id, index: i + 1, containerID: containerID, openerID: .some(nil)) else { return }
        let wv = makeWebView(containerID: n.containerID)
        attach(wv, id: n.id)
        if let u = URL(string: n.url) { wv.load(URLRequest(url: u)) }
        closeTab(id)
        refreshTabs()
        showActive()
    }

    /// 标签拖出成新窗口（同一个 WKWebView 搬过去，页面状态不丢）
    func detachTab(_ id: Int, at screenPoint: NSPoint) {
        guard store.count > 1, let t = store.tab(id), let wv = webViews[id] else { return }
        let wasPinned = pinned.contains(id)
        detachObservers(id)
        webViews[id] = nil
        wv.removeFromSuperview()
        _ = store.close(id)
        finished.remove(id); lastError[id] = nil; pinned.remove(id); muted.remove(id); audible.remove(id); favicons[id] = nil
        refreshTabs()
        showActive()
        onDetach?(self, wv, t, wasPinned, screenPoint)
    }

    /// 接收拖出来的标签
    func adopt(_ wv: WKWebView, tab: MioTab, pinned isPinned: Bool) {
        guard let t = store.add(wv.url?.absoluteString ?? tab.url, title: wv.title ?? tab.title, activate: true,
                                containerID: tab.containerID, locked: tab.locked, openerID: .some(nil)) else { return }
        attach(wv, id: t.id)
        if isPinned { pinned.insert(t.id) }
        finished.insert(t.id)
        refreshTabs()
        showActive()
    }

    /// 只把当前标签的 WKWebView 放进窗口；后台标签留在内存里（恢复的会话里没加载过的标签此时才创建）
    private func showActive() {
        guard let t = store.active else { return }
        if webViews[t.id] == nil {
            let wv = makeWebView(containerID: t.containerID)
            attach(wv, id: t.id)
            if let u = URL(string: t.url) { wv.load(URLRequest(url: u)) }
        }
        guard let wv = webViews[t.id] else { return }
        for v in webContainer.subviews where v !== wv && v is WKWebView { v.removeFromSuperview() }
        if wv.superview !== webContainer {
            webContainer.addSubview(wv, positioned: .below, relativeTo: nil)
            NSLayoutConstraint.activate([
                wv.topAnchor.constraint(equalTo: webContainer.topAnchor),
                wv.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),
                wv.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
                wv.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            ])
        }
        findBar.webView = wv
        applyZoom(wv)
        refreshChrome()
        if !navBar.urlBar.isFocused && !findBarVisible { window?.makeFirstResponder(wv) }
    }

    private func tabID(of wv: WKWebView) -> Int? {
        webViews.first(where: { $0.value === wv })?.key
    }

    private func webViewChanged(_ wv: WKWebView) {
        guard let id = tabID(of: wv) else { return }
        store.update(id, url: wv.url?.absoluteString, title: wv.title)
        refreshTabs()
        if id == store.activeID { refreshChrome() }
    }

    private func progressChanged(_ wv: WKWebView) {
        guard let id = tabID(of: wv) else { return }
        tabBar.setLoading(id, wv.isLoading)
        if id == store.activeID {
            navBar.setLoading(wv.isLoading)
            navBar.progress.set(progress: wv.estimatedProgress, loading: wv.isLoading)
        }
        if !wv.isLoading { refreshTabs() }
    }

    func title(for t: MioTab) -> String {
        if isHome(URL(string: t.url)) && (t.title.isEmpty || t.title.lowercased().contains("mio")) { return t.title.isEmpty ? "Mio" : t.title }
        if !t.title.isEmpty { return t.title }
        let h = MioTabStore.displayHost(t.url)
        return h.isEmpty ? "新标签页" : h
    }

    func refreshTabs() {
        let state = MioMacWebKit.containerState()
        // 固定标签总在最前（恢复会话 / 移动之后再校正一次）
        let pinnedIDs = store.tabs.filter { pinned.contains($0.id) }.map(\.id)
        for (k, id) in pinnedIDs.enumerated() { if let i = store.index(of: id), i != k { store.move(from: i, to: k) } }
        let items: [MioMacTabBar.Item] = store.tabs.map { t in
            let color = t.containerID == MioContainerCore.defaultId ? nil : MioMacWebKit.colorFor(container: state.get(t.containerID))
            return MioMacTabBar.Item(id: t.id, title: title(for: t), color: color, pinned: pinned.contains(t.id),
                                     loading: webViews[t.id]?.isLoading ?? false, audible: audible.contains(t.id), muted: muted.contains(t.id),
                                     favicon: favicons[t.id], isHome: isHome(URL(string: t.url)))
        }
        tabBar.reload(tabs: items, activeID: store.activeID, animated: window?.isVisible ?? false)
        let vt = items.map { i in
            MioMacVerticalTabsModel.Tab(id: i.id, title: i.title, host: MioTabStore.displayHost(store.tab(i.id)?.url ?? ""), pinned: i.pinned,
                                        loading: i.loading, audible: i.audible, muted: i.muted, isHome: i.isHome, favicon: i.favicon, containerColor: i.color)
        }
        if verticalTabs.tabs != vt { verticalTabs.tabs = vt }
        if verticalTabs.activeID != store.activeID { verticalTabs.activeID = store.activeID }
        if verticalTabs.containers != state.containers { verticalTabs.containers = state.containers }
    }

    func refreshChrome() {
        let wv = activeWebView
        navBar.backButton.isEnabled = wv?.canGoBack ?? false
        navBar.forwardButton.isEnabled = wv?.canGoForward ?? false
        let url = wv?.url ?? store.active.flatMap { URL(string: $0.url) }
        navBar.urlBar.setDisplay(url: url, isHome: isHome(url))
        navBar.urlBar.setStarred(MioMacBrowserData.shared.bookmarks.contains(url?.absoluteString), animated: false)
        let z = wv.map { Double($0.pageZoom) } ?? defaultZoom
        navBar.urlBar.setZoom(z, isDefault: MioZoomCore.isDefault(z, default: 1.0))
        navBar.setLoading(wv?.isLoading ?? false)
        navBar.progress.set(progress: wv?.estimatedProgress ?? 1, loading: wv?.isLoading ?? false)
        window?.title = (wv?.title).flatMap { $0.isEmpty ? nil : $0 } ?? "Mio"
    }

    // MARK: - Zoom（Safari 档位，按站点记住；⌘+/- 弹缩放提示）

    private func applyZoom(_ wv: WKWebView) {
        let z = CGFloat(zoomTable.zoom(for: MioZoomCore.siteKey(url: wv.url), default: defaultZoom))
        if abs(wv.pageZoom - z) > 0.001 { wv.pageZoom = z }
    }

    private func setZoom(_ level: Double, zoomingIn: Bool?) {
        guard let wv = activeWebView else { return }
        var t = zoomTable
        t.set(level, for: MioZoomCore.siteKey(url: wv.url), default: defaultZoom)
        zoomTable = t
        wv.pageZoom = CGFloat(level)
        refreshChrome()
        zoomHUD.show(level: level, zoomingIn: zoomingIn, in: webContainer)
    }

    @objc func zoomIn(_ sender: Any?) { if let wv = activeWebView { setZoom(MioZoomCore.zoomIn(from: Double(wv.pageZoom)), zoomingIn: true) } }
    @objc func zoomOut(_ sender: Any?) { if let wv = activeWebView { setZoom(MioZoomCore.zoomOut(from: Double(wv.pageZoom)), zoomingIn: false) } }
    @objc func zoomReset(_ sender: Any?) {
        activeWebView?.setMagnification(1, centeredAt: .zero)
        setZoom(defaultZoom, zoomingIn: nil)
    }

    // MARK: - Actions

    @objc func goBack(_ sender: Any?) { activeWebView?.goBack() }
    @objc func goForward(_ sender: Any?) { activeWebView?.goForward() }
    @objc func reload(_ sender: Any?) { activeWebView?.reload() }
    @objc func goHome(_ sender: Any?) { navigate(activeWebView, to: MioMacHome.address) }
    @objc func newTabAction(_ sender: Any?) { newTab(); focusAddressBar() }

    @objc func toggleBookmark(_ sender: Any?) {
        guard let wv = activeWebView, let u = wv.url?.absoluteString else { return }
        let on = MioMacBrowserData.shared.toggleBookmark(url: u, title: wv.title ?? "")
        navBar.urlBar.setStarred(on, animated: true)
        toast.show(on ? "已添加到书签" : "已移除书签", button: nil, in: webContainer)
    }

    @objc func printPage(_ sender: Any?) {
        guard let wv = activeWebView, let w = window else { return }
        let op = wv.printOperation(with: NSPrintInfo.shared)
        op.view?.frame = wv.bounds
        op.runModal(for: w, delegate: nil, didRun: nil, contextInfo: nil)
    }

    @objc func showWebInspector(_ sender: Any?) {
        // WKWebView 没有公开的「打开检查器」：用 _inspector.show（不存在就提示右键检查元素）
        guard let wv = activeWebView else { return }
        let sel = NSSelectorFromString("_inspector")
        if wv.responds(to: sel), let insp = wv.perform(sel)?.takeUnretainedValue() as? NSObject, insp.responds(to: NSSelectorFromString("show")) {
            insp.perform(NSSelectorFromString("show"))
        } else {
            toast.show("右键网页 › 检查元素 打开开发者工具", button: nil, in: webContainer)
        }
    }

    @objc func moveTabToNewWindow(_ sender: Any?) {
        guard let id = store.activeID, let w = window else { return }
        detachTab(id, at: NSPoint(x: w.frame.midX + 40, y: w.frame.midY - 40))
    }

    @objc func openInSafari(_ sender: Any?) {
        guard let u = activeWebView?.url else { return }
        if let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") {
            NSWorkspace.shared.open([u], withApplicationAt: safari, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(u)
        }
    }

    func focusAddressBar() {
        window?.makeFirstResponder(navBar.urlBar.field)
    }

    /// 在标签里打开地址（mio://home → 首页实际地址）
    func navigate(_ wv: WKWebView?, to s: String) {
        let target = resolveTabURL(s)
        guard let u = URL(string: target) else { return }
        guard let wv else { newTab(url: target); return }
        wv.load(URLRequest(url: u))
        window?.makeFirstResponder(wv)
    }

    func submitAddress(_ text: String) {
        guard let url = MioMacAddressInput.resolve(text) else { return }
        navigate(activeWebView, to: url.absoluteString)
    }

    func suggestions(for q: String) -> [MioSuggestion] {
        let resolved = MioMacAddressInput.resolve(q)
        let isSearch = resolved?.absoluteString.hasPrefix(MioMacAddressInput.searchBase + "?") ?? true
        let tabs = store.tabs.map { MioSuggest.OpenTab(id: $0.id, title: title(for: $0), url: $0.url) }
        let data = MioMacBrowserData.shared
        return MioSuggest.build(query: q, resolved: resolved, isSearch: isSearch, tabs: tabs, bookmarks: data.bookmarks.items,
                                history: data.history.entries, activeTabID: store.activeID)
    }

    func pickSuggestion(_ s: MioSuggestion) {
        if s.kind == .switchTab, let id = s.tabID {
            select(id)
            return
        }
        navigate(activeWebView, to: s.url)
    }

    // MARK: - Session

    func saveSession() {
        UserDefaults.standard.set(store.serialize(), forKey: Self.sessionKey)
        // 固定标签：按 serialize() 的顺序（只保存 http(s) 标签）记下标
        let kept = store.tabs.filter { MioTabStore.isHTTP($0.url) }
        let idx = kept.enumerated().filter { pinned.contains($0.element.id) }.map(\.offset)
        UserDefaults.standard.set(idx, forKey: Self.sessionPinnedKey)
    }

    /// 恢复上次的标签（只建当前标签的 WKWebView，其他点到时再加载）
    @discardableResult
    func restoreSession() -> Int {
        let known = [MioContainerCore.defaultId] + MioMacWebKit.containerState().containers.map { $0.id }
        let n = store.restore(UserDefaults.standard.data(forKey: Self.sessionKey), knownContainers: known)
        if n > 0 {
            let idx = (UserDefaults.standard.array(forKey: Self.sessionPinnedKey) as? [Int]) ?? []
            for i in idx where store.tabs.indices.contains(i) { pinned.insert(store.tabs[i].id) }
            refreshTabs()
            showActive()
        }
        return n
    }

    // MARK: - 声音（播放中图标）

    private func startAudioPolling() {
        audioTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollAudio() }
        }
    }

    private func pollAudio() {
        for (id, wv) in webViews {
            wv.requestMediaPlaybackState { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let playing = state == .playing
                    if playing != self.audible.contains(id) {
                        if playing { self.audible.insert(id) } else { self.audible.remove(id) }
                        self.refreshTabs()
                    }
                }
            }
        }
    }

    /// 冒烟用：不放视频也能显示「正在播放」图标
    func debugSetAudible(_ id: Int, _ on: Bool) {
        if on { audible.insert(id) } else { audible.remove(id) }
        refreshTabs()
    }

    // MARK: - 网站图标

    private func loadFavicon(_ wv: WKWebView, id: Int) {
        guard let host = wv.url?.host?.lowercased(), !isHome(wv.url) else { return }
        if let cached = MioMacBrowserData.shared.favicons[host] { favicons[id] = cached; refreshTabs(); return }
        let js = "(function(){var l=document.querySelector('link[rel~=\"icon\"][sizes=\"32x32\"],link[rel~=\"icon\"],link[rel=\"shortcut icon\"],link[rel=\"apple-touch-icon\"]');return l?l.href:(location.origin+'/favicon.ico');})()"
        wv.evaluateJavaScript(js) { [weak self] v, _ in
            MainActor.assumeIsolated {
                guard let s = v as? String, let u = URL(string: s), ["http", "https"].contains(u.scheme ?? "") else { return }
                MioMacBrowserData.shared.fetchFavicon(u, host: host) { img in
                    guard let self, let img else { return }
                    self.favicons[id] = img
                    self.refreshTabs()
                }
            }
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        if !verticalTabsMode { UserDefaults.standard.set(sidebarVisible, forKey: Self.sidebarKey) }
        if !store.tabs.isEmpty { saveSession() }
        for (_, wv) in webViews { wv.stopLoading() }
        audioTimer?.invalidate()
        if let w = window { MioTrafficLights.stopObserving(w) }
        MioMacPopupPanel.current?.dismiss(animated: false)
        navBar.urlBar.dropdown.hide(animated: false)
        onClose?(self)
    }

    func windowDidResize(_ notification: Notification) { positionTrafficLights() }
    func windowDidBecomeKey(_ notification: Notification) { positionTrafficLights() }
    func windowDidResignKey(_ notification: Notification) { positionTrafficLights() }

    func windowWillEnterFullScreen(_ notification: Notification) {
        // 全屏没有红绿灯：标签条 / 导航栏左边的留白收回来（带动画）
        tabBar.leadingInset = 8
        if verticalTabsMode { navBar.leadingInset = 8 }
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        tabBar.leadingInset = MioTrafficLights.reservedWidth
        if verticalTabsMode { navBar.leadingInset = MioTrafficLights.reservedWidth }
    }

    func windowDidExitFullScreen(_ notification: Notification) { positionTrafficLights() }
    func windowDidEnterFullScreen(_ notification: Notification) { refreshChrome() }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if let id = tabID(of: webView) { finished.remove(id); lastError[id] = nil }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        applyZoom(webView)
        webViewChanged(webView)
        if let id = tabID(of: webView), muted.contains(id) { applyMute(id) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webViewChanged(webView)
        guard let id = tabID(of: webView) else { return }
        finished.insert(id)
        if let u = webView.url?.absoluteString, !isHome(webView.url) {
            MioMacBrowserData.shared.recordHistory(url: u, title: webView.title ?? "")
        }
        if muted.contains(id) { applyMute(id) }
        loadFavicon(webView, id: id)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadFailed(webView, error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadFailed(webView, error)
    }

    private func loadFailed(_ webView: WKWebView, _ error: Error) {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if let id = tabID(of: webView) { lastError[id] = "\(ns.domain) \(ns.code) \(ns.localizedDescription)"; finished.insert(id) }
        webViewChanged(webView)
        progressChanged(webView)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else { return .allow }
        if scheme == MioMacHome.address.components(separatedBy: ":").first {
            // mio://home → 首页实际地址（其他 mio:// 地址留给 MioKit 的方案处理，现在忽略）
            if MioMacHome.isHomeAddress(url.absoluteString) { navigate(webView, to: MioMacHome.address) }
            return .cancel
        }
        if !["http", "https", "about", "blob", "data", "file", "javascript"].contains(scheme) {
            NSWorkspace.shared.open(url) // mailto: / tel: / 其他 App 的 scheme 交给系统
            return .cancel
        }
        // ⌘点链接 → 后台新标签（Firefox / Safari 行为）；⇧⌘点 → 前台
        if navigationAction.navigationType == .linkActivated, navigationAction.modifierFlags.contains(.command), scheme == "http" || scheme == "https" {
            let container = tabID(of: webView).flatMap { store.tab($0)?.containerID }
            newTab(url: url.absoluteString, containerID: container, activate: navigationAction.modifierFlags.contains(.shift), fromActive: true)
            return .cancel
        }
        return .allow
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    // MARK: - WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let container = tabID(of: webView).flatMap { store.tab($0)?.containerID }
        let url = navigationAction.request.url?.absoluteString ?? "about:blank"
        return newTab(url: url, containerID: container, activate: true, fromActive: true, configuration: configuration)?.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let id = tabID(of: webView) { closeTab(id) }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        let a = NSAlert()
        a.messageText = frame.request.url?.host ?? "网页"
        a.informativeText = message
        a.addButton(withTitle: "好")
        a.runModal()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let a = NSAlert()
        a.messageText = frame.request.url?.host ?? "网页"
        a.informativeText = message
        a.addButton(withTitle: "好")
        a.addButton(withTitle: "取消")
        return a.runModal() == .alertFirstButtonReturn
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = parameters.allowsMultipleSelection
        p.canChooseDirectories = parameters.allowsDirectories
        p.canChooseFiles = true
        return p.runModal() == .OK ? p.urls : nil
    }
}

/// MioCore 模块（共享 Kit）默认的旧导航地址：Mac 版把它映射到 mio://home
enum MioCoreModuleHome {
    static let legacyNav = MioTabStore.defaultNewTabURL
}

// MARK: - 历史 / 书签 / 网站图标（窗口之间共享，存在 UserDefaults）

@MainActor
final class MioMacBrowserData {
    static let shared = MioMacBrowserData()
    static let historyKey = "mio.mac.history"
    static let bookmarksKey = "mio.mac.bookmarks"

    private(set) var history: MioHistoryList
    private(set) var bookmarks: MioBookmarkList
    var favicons: [String: NSImage] = [:]
    private var pending: [String: [(NSImage?) -> Void]] = [:]
    private var saveWork: DispatchWorkItem?
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        return URLSession(configuration: c)
    }()

    private init() {
        history = MioHistoryList(json: UserDefaults.standard.data(forKey: Self.historyKey))
        bookmarks = MioBookmarkList(json: UserDefaults.standard.data(forKey: Self.bookmarksKey))
    }

    func recordHistory(url: String, title: String) {
        history.record(url: url, title: title, at: Date().timeIntervalSince1970)
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { if let self { UserDefaults.standard.set(self.history.json, forKey: Self.historyKey) } }
        }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: w)
    }

    func clearHistory() {
        history.clear()
        UserDefaults.standard.set(history.json, forKey: Self.historyKey)
    }

    @discardableResult
    func toggleBookmark(url: String, title: String) -> Bool {
        let on = bookmarks.toggle(url: url, title: title)
        UserDefaults.standard.set(bookmarks.json, forKey: Self.bookmarksKey)
        return on
    }

    func fetchFavicon(_ url: URL, host: String, completion: @escaping (NSImage?) -> Void) {
        if let img = favicons[host] { completion(img); return }
        if pending[host] != nil { pending[host]?.append(completion); return }
        pending[host] = [completion]
        session.dataTask(with: url) { data, _, _ in
            let img = data.flatMap { NSImage(data: $0) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let img { img.size = NSSize(width: 16, height: 16); self.favicons[host] = img }
                    let cbs = self.pending.removeValue(forKey: host) ?? []
                    for cb in cbs { cb(img) }
                }
            }
        }.resume()
    }
}
