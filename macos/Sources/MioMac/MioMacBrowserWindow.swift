// MioMacBrowserWindow.swift — 原生 macOS 浏览器窗口：Safari 风格统一工具栏（后退 / 前进 / 地址栏 / 新标签 / 菜单）、
// 工具栏下的标签条、多标签（MioTabStore，与 iOS / Windows 同一套规则）、容器、按站点缩放（MioZoomCore）。

import AppKit
import WebKit

extension NSToolbarItem.Identifier {
    static let mioBack = NSToolbarItem.Identifier("mio.back")
    static let mioForward = NSToolbarItem.Identifier("mio.forward")
    static let mioAddress = NSToolbarItem.Identifier("mio.address")
    static let mioNewTab = NSToolbarItem.Identifier("mio.newTab")
    static let mioMenu = NSToolbarItem.Identifier("mio.menu")
}

@MainActor
final class MioMacBrowserWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, WKNavigationDelegate, WKUIDelegate {
    static let zoomSitesKey = "mio.zoom.sites"     // = MioDesktopParity（Catalyst）同名 key，存的是 Safari 档位
    static let zoomDefaultKey = "mio.zoom.default"
    static let newTabKey = "mio.tabs.newTabURL"

    let store = MioTabStore()
    private(set) var webViews: [Int: WKWebView] = [:]
    private var observations: [Int: [NSKeyValueObservation]] = [:]
    /// 冒烟用：每个标签最近一次导航结束（成功 / 失败）
    private(set) var finished: Set<Int> = []
    private(set) var lastError: [Int: String] = [:]

    let tabStrip = MioMacTabStrip()
    let webContainer = NSView()
    let addressField = NSTextField()
    private var backItem: NSToolbarItem?
    private var forwardItem: NSToolbarItem?
    private var menuItem: NSMenuToolbarItem?
    var onClose: ((MioMacBrowserWindowController) -> Void)?

    private var zoomTable: MioZoomCore.SiteTable {
        get { MioZoomCore.SiteTable(json: UserDefaults.standard.string(forKey: Self.zoomSitesKey)) }
        set { UserDefaults.standard.set(newValue.json, forKey: Self.zoomSitesKey) }
    }
    private var defaultZoom: Double {
        let v = UserDefaults.standard.double(forKey: Self.zoomDefaultKey)
        return v > 0 ? MioZoomCore.nearest(v) : 1.0
    }

    static var newTabURL: String {
        MioTabStore.normalizeNewTabURL(UserDefaults.standard.string(forKey: newTabKey)) ?? MioTabStore.defaultNewTabURL
    }

    init(size: NSSize = NSSize(width: 1280, height: 820)) {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Mio"
        w.titleVisibility = .hidden
        w.toolbarStyle = .unified
        w.minSize = NSSize(width: 520, height: 360)
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed // 标签由我们自己的标签条管理（与 MioTabStore 一致），不用系统窗口标签
        super.init(window: w)
        w.delegate = self
        buildContent()
        buildToolbar()
        w.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - UI

    private func buildContent() {
        guard let content = window?.contentView else { return }
        tabStrip.translatesAutoresizingMaskIntoConstraints = false
        webContainer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tabStrip)
        content.addSubview(webContainer)
        NSLayoutConstraint.activate([
            tabStrip.topAnchor.constraint(equalTo: content.topAnchor),
            tabStrip.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tabStrip.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tabStrip.heightAnchor.constraint(equalToConstant: MioMacTabStrip.height),
            webContainer.topAnchor.constraint(equalTo: tabStrip.bottomAnchor),
            webContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        tabStrip.onSelect = { [weak self] id in self?.select(id) }
        tabStrip.onClose = { [weak self] id in self?.closeTab(id) }
        tabStrip.onNewTab = { [weak self] in self?.newTab() }
    }

    private func buildToolbar() {
        let tb = NSToolbar(identifier: "mio.browser.toolbar")
        tb.delegate = self
        tb.displayMode = .iconOnly
        tb.allowsUserCustomization = false
        tb.centeredItemIdentifiers = [.mioAddress]
        window?.toolbar = tb
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.mioBack, .mioForward, .flexibleSpace, .mioAddress, .flexibleSpace, .mioNewTab, .mioMenu]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func button(_ symbol: String, _ label: String, _ action: Selector) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            item.label = label
            item.toolTip = label
            item.isBordered = true
            item.target = self
            item.action = action
            item.autovalidates = false
            return item
        }
        switch id {
        case .mioBack:
            let i = button("chevron.left", "后退", #selector(goBack(_:)))
            backItem = i
            return i
        case .mioForward:
            let i = button("chevron.right", "前进", #selector(goForward(_:)))
            forwardItem = i
            return i
        case .mioNewTab:
            return button("plus", "新建标签页", #selector(newTabAction(_:)))
        case .mioAddress:
            let item = NSToolbarItem(itemIdentifier: id)
            addressField.placeholderString = "搜索或输入网站名称"
            addressField.bezelStyle = .roundedBezel
            addressField.isBordered = true
            addressField.usesSingleLineMode = true
            addressField.lineBreakMode = .byTruncatingTail
            addressField.cell?.isScrollable = true
            addressField.cell?.sendsActionOnEndEditing = false
            addressField.target = self
            addressField.action = #selector(addressEntered(_:))
            addressField.translatesAutoresizingMaskIntoConstraints = false
            let wide = addressField.widthAnchor.constraint(equalToConstant: 560)
            wide.priority = .defaultLow
            NSLayoutConstraint.activate([
                addressField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
                addressField.widthAnchor.constraint(lessThanOrEqualToConstant: 760),
                wide,
            ])
            item.view = addressField
            item.label = "地址"
            item.visibilityPriority = .high
            return item
        case .mioMenu:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "菜单")
            item.label = "菜单"
            item.showsIndicator = false
            item.menu = buildPageMenu()
            menuItem = item
            return item
        default:
            return nil
        }
    }

    /// 工具栏「…」菜单：容器新标签、缩放、重新载入、用 Safari 打开
    func buildPageMenu() -> NSMenu {
        let m = NSMenu(title: "菜单")
        let z = activeWebView.map { Double($0.pageZoom) } ?? defaultZoom
        m.addItem(withTitle: "放大", action: #selector(zoomIn(_:)), keyEquivalent: "").target = self
        m.addItem(withTitle: "缩小", action: #selector(zoomOut(_:)), keyEquivalent: "").target = self
        m.addItem(withTitle: "实际大小（当前 \(MioZoomCore.label(z))）", action: #selector(zoomReset(_:)), keyEquivalent: "").target = self
        m.addItem(.separator())
        let containers = NSMenuItem(title: "在容器中新建标签页", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "容器")
        let state = MioMacWebKit.containerState()
        for c in [MioContainerCore.defaultContainer] + state.containers {
            let it = NSMenuItem(title: c.name, action: #selector(newContainerTab(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = c.id
            if let color = MioMacWebKit.colorFor(container: c) {
                it.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?.withSymbolConfiguration(.init(paletteColors: [color]))
            }
            sub.addItem(it)
        }
        containers.submenu = sub
        m.addItem(containers)
        m.addItem(.separator())
        m.addItem(withTitle: "重新载入", action: #selector(reload(_:)), keyEquivalent: "").target = self
        m.addItem(withTitle: "用 Safari 打开", action: #selector(openInSafari(_:)), keyEquivalent: "").target = self
        return m
    }

    // MARK: - Tabs

    var activeWebView: WKWebView? { store.activeID.flatMap { webViews[$0] } }
    var activeTabID: Int? { store.activeID }

    private func makeWebView(containerID: String, configuration: WKWebViewConfiguration? = nil) -> WKWebView {
        let config = configuration ?? MioMacWebKit.configuration(containerID: containerID)
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.customUserAgent = MioMacWebKit.desktopUserAgent
        wv.allowsBackForwardNavigationGestures = true
        wv.allowsMagnification = true
        wv.isInspectable = true
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.translatesAutoresizingMaskIntoConstraints = false
        return wv
    }

    private func attach(_ wv: WKWebView, id: Int) {
        webViews[id] = wv
        let handler: (WKWebView) -> Void = { [weak self] w in self?.webViewChanged(w) }
        observations[id] = [
            wv.observe(\.title, options: [.new]) { w, _ in MainActor.assumeIsolated { handler(w) } },
            wv.observe(\.url, options: [.new]) { w, _ in MainActor.assumeIsolated { handler(w) } },
            wv.observe(\.canGoBack, options: [.new]) { w, _ in MainActor.assumeIsolated { handler(w) } },
            wv.observe(\.canGoForward, options: [.new]) { w, _ in MainActor.assumeIsolated { handler(w) } },
        ]
    }

    /// 新建标签。configuration 非空 = 页面 window.open / target=_blank 打开（WebKit 自己加载，不能再 load）
    @discardableResult
    func newTab(url: String? = nil, containerID: String? = nil, activate: Bool = true, fromActive: Bool = false,
                configuration: WKWebViewConfiguration? = nil) -> (id: Int, webView: WKWebView)? {
        guard let t = store.add(url ?? Self.newTabURL, title: nil, activate: activate, fromActive: fromActive, containerID: containerID) else {
            NSSound.beep()
            return nil
        }
        let wv = makeWebView(containerID: t.containerID, configuration: configuration)
        attach(wv, id: t.id)
        if configuration == nil, let u = URL(string: t.url) { wv.load(URLRequest(url: u)) }
        refreshTabs()
        if store.activeID == t.id { showActive() }
        return (t.id, wv)
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

    func closeTab(_ id: Int? = nil) {
        guard let id = id ?? store.activeID, store.close(id) != nil else { return }
        if let wv = webViews.removeValue(forKey: id) {
            observations[id] = nil
            wv.stopLoading()
            wv.navigationDelegate = nil
            wv.uiDelegate = nil
            wv.removeFromSuperview()
        }
        finished.remove(id)
        lastError[id] = nil
        if store.tabs.isEmpty {
            window?.close()
            return
        }
        refreshTabs()
        showActive()
    }

    func reopenClosedTab() {
        guard let t = store.reopenClosed() else { NSSound.beep(); return }
        let wv = makeWebView(containerID: t.containerID)
        attach(wv, id: t.id)
        if let u = URL(string: t.url) { wv.load(URLRequest(url: u)) }
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
        for v in webContainer.subviews where v !== wv { v.removeFromSuperview() }
        if wv.superview !== webContainer {
            webContainer.addSubview(wv)
            NSLayoutConstraint.activate([
                wv.topAnchor.constraint(equalTo: webContainer.topAnchor),
                wv.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),
                wv.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
                wv.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            ])
        }
        applyZoom(wv)
        refreshChrome()
        if addressField.currentEditor() == nil { window?.makeFirstResponder(wv) }
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

    func refreshTabs() {
        let state = MioMacWebKit.containerState()
        tabStrip.reload(tabs: store.tabs.map { t in
            let title = t.title.isEmpty ? (MioTabStore.displayHost(t.url).isEmpty ? "新标签页" : MioTabStore.displayHost(t.url)) : t.title
            return MioMacTabStrip.Item(id: t.id, title: title, color: t.containerID == MioContainerCore.defaultId ? nil : MioMacWebKit.colorFor(container: state.get(t.containerID)))
        }, activeID: store.activeID)
    }

    func refreshChrome() {
        let wv = activeWebView
        backItem?.isEnabled = wv?.canGoBack ?? false
        forwardItem?.isEnabled = wv?.canGoForward ?? false
        if addressField.currentEditor() == nil {
            addressField.stringValue = MioMacAddressInput.displayText(wv?.url ?? store.active.flatMap { URL(string: $0.url) })
        }
        window?.title = (wv?.title).flatMap { $0.isEmpty ? nil : $0 } ?? "Mio"
        menuItem?.menu = buildPageMenu()
    }

    // MARK: - Zoom（Safari 档位，按站点记住）

    private func applyZoom(_ wv: WKWebView) {
        let z = CGFloat(zoomTable.zoom(for: MioZoomCore.siteKey(url: wv.url), default: defaultZoom))
        if abs(wv.pageZoom - z) > 0.001 { wv.pageZoom = z }
    }

    private func setZoom(_ level: Double) {
        guard let wv = activeWebView else { return }
        var t = zoomTable
        t.set(level, for: MioZoomCore.siteKey(url: wv.url), default: defaultZoom)
        zoomTable = t
        wv.pageZoom = CGFloat(level)
        refreshChrome()
    }

    @objc func zoomIn(_ sender: Any?) { if let wv = activeWebView { setZoom(MioZoomCore.zoomIn(from: Double(wv.pageZoom))) } }
    @objc func zoomOut(_ sender: Any?) { if let wv = activeWebView { setZoom(MioZoomCore.zoomOut(from: Double(wv.pageZoom))) } }
    @objc func zoomReset(_ sender: Any?) { setZoom(defaultZoom) }

    // MARK: - Actions

    @objc func goBack(_ sender: Any?) { activeWebView?.goBack() }
    @objc func goForward(_ sender: Any?) { activeWebView?.goForward() }
    @objc func reload(_ sender: Any?) { activeWebView?.reload() }
    @objc func newTabAction(_ sender: Any?) { newTab(); focusAddressBar() }

    @objc func newContainerTab(_ sender: NSMenuItem) {
        newTab(containerID: sender.representedObject as? String)
        focusAddressBar()
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
        window?.makeFirstResponder(addressField)
        addressField.selectText(nil)
    }

    @objc func addressEntered(_ sender: NSTextField) {
        guard let url = MioMacAddressInput.resolve(sender.stringValue) else { return }
        if activeWebView == nil { newTab(url: url.absoluteString); return }
        activeWebView?.load(URLRequest(url: url))
        if let wv = activeWebView { window?.makeFirstResponder(wv) }
    }

    // MARK: - Session

    static let sessionKey = "mio.mac.tabs.session"

    func saveSession() {
        UserDefaults.standard.set(store.serialize(), forKey: Self.sessionKey)
    }

    /// 恢复上次的标签（只建当前标签的 WKWebView，其他点到时再加载）
    @discardableResult
    func restoreSession() -> Int {
        let known = [MioContainerCore.defaultId] + MioMacWebKit.containerState().containers.map { $0.id }
        let n = store.restore(UserDefaults.standard.data(forKey: Self.sessionKey), knownContainers: known)
        if n > 0 { refreshTabs(); showActive() }
        return n
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        if !store.tabs.isEmpty { saveSession() }
        for (_, wv) in webViews { wv.stopLoading() }
        onClose?(self)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if let id = tabID(of: webView) { finished.remove(id); lastError[id] = nil }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        applyZoom(webView)
        webViewChanged(webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webViewChanged(webView)
        if let id = tabID(of: webView) { finished.insert(id) }
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
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else { return .allow }
        if !["http", "https", "about", "blob", "data", "file", "javascript"].contains(scheme) {
            NSWorkspace.shared.open(url) // mailto: / tel: / 其他 App 的 scheme 交给系统
            return .cancel
        }
        // ⌘点链接 → 后台新标签（Safari 行为）
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

// MARK: - 标签条

@MainActor
final class MioMacTabStrip: NSView {
    struct Item: Equatable {
        let id: Int
        let title: String
        let color: NSColor?
    }

    static let height: CGFloat = 30

    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onNewTab: (() -> Void)?
    private let stack = NSStackView()
    private(set) var items: [Item] = []
    private(set) var activeID: Int?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onNewTab?() } // 双击空白处新建标签（Safari 行为）
    }

    func reload(tabs: [Item], activeID: Int?) {
        guard tabs != items || activeID != self.activeID else { return }
        items = tabs
        self.activeID = activeID
        for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() }
        for t in tabs {
            let v = MioMacTabItemView(item: t, active: t.id == activeID)
            v.onSelect = { [weak self] in self?.onSelect?(t.id) }
            v.onClose = { [weak self] in self?.onClose?(t.id) }
            stack.addArrangedSubview(v)
        }
    }
}

@MainActor
final class MioMacTabItemView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    let label = NSTextField(labelWithString: "")
    let close = NSButton()
    let active: Bool
    private let accent = NSView()

    init(item: MioMacTabStrip.Item, active: Bool) {
        self.active = active
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        toolTip = item.title
        label.stringValue = item.title
        label.lineBreakMode = .byTruncatingTail
        label.alignment = .center
        label.font = .systemFont(ofSize: 12, weight: active ? .semibold : .regular)
        label.textColor = active ? .labelColor : .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭标签页")
        close.isBordered = false
        close.bezelStyle = .inline
        close.imageScaling = .scaleProportionallyDown
        close.target = self
        close.action = #selector(closeTapped)
        close.translatesAutoresizingMaskIntoConstraints = false
        accent.wantsLayer = true
        accent.layer?.backgroundColor = item.color?.cgColor ?? NSColor.clear.cgColor
        accent.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        addSubview(close)
        addSubview(accent)
        NSLayoutConstraint.activate([
            close.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 14),
            close.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: close.trailingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            accent.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            accent.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            accent.bottomAnchor.constraint(equalTo: bottomAnchor),
            accent.heightAnchor.constraint(equalToConstant: 2),
        ])
        updateLayer()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = active ? NSColor.controlBackgroundColor.cgColor : NSColor.clear.cgColor
    }

    override func mouseDown(with event: NSEvent) { onSelect?() }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { onClose?() } // 中键关闭
    }

    @objc private func closeTapped() { onClose?() }
}
