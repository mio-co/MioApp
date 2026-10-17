// MioTabs.swift — 内置浏览器多标签页（iOS / iPadOS / Mac Catalyst）
//
// 结构：MioTabsViewController（全屏容器，App 运行期间常驻）里每个标签一个 MioBrowserViewController 子控制器。
// 每个标签的 WKWebView 和它的全部按 WebView 注册的功能（广告拦截 MioAdblockSession、YouTube 防沉迷、后台播放、
// 回车兜底、通行密钥提示，以及翻译 / 阅读 / 媒体 / 用户脚本等）都在 MioBrowserViewController.viewDidLoad 里各自安装 ——
// 这就是 per-tab 的 setup，所以每个标签都生效。所有标签共享同一个持久化数据存储（固定 UUID 的 WKWebsiteDataStore）。
//
// - Mac / iPad：Safari 式顶部工具栏（一行：✕ 后退 前进 刷新 · 居中地址栏 · 分享 Safari … 设置 拦截 标签概览 新建），下面一行标签条；
//   网页区域从标签条下面开始（不被遮挡，页面底部 fixed 元素可点）。滚动隐藏工具栏照旧可选（Mac 默认关）。
// - iPhone：保持底部工具栏（含滚动隐藏），多一个标签按钮（数字图标；点 = 标签概览网格，长按 = 菜单）。
// - 收起：✕ = 回到 Mio 主界面，标签全部留在后台（不销毁），主界面右下角显示「N」角标，点一下回来。
// - 标签上限 50；同时加载的 WebView 数 iPhone 4 / iPad 6 / Mac 12，超出时按最近使用卸载后台标签
//   （保存 interactionState：切回时恢复前进后退历史和滚动位置）。
// - 会话（URL + 标题 + 容器 + 锁定）存在 UserDefaults，App 重启后懒加载恢复。
// - 容器（登录隔离，MioContainerStore.swift）：每个标签的 WKWebView 用它容器的 WKWebsiteDataStore（makeConfiguration(for:)）；
//   新标签选容器 = 锁定的打开者 > 显式指定 > 站点默认容器 > 未锁定的打开者 > 默认容器；锁定的标签打开的子标签同容器并锁定；
//   标签映射（key = "t<id>"）同步给容器模块；删除容器（.mioContainerWillRemove）先关掉它的标签。

import UIKit
import WebKit

// MARK: - Settings / container hooks

enum MioTabsSettings {
    private static let newTabKey = "mio.tabs.newTabURL"
    static let sessionKey = "mio.tabs.session"

    /// 新标签页地址（空 = MioCore 导航）
    static var newTabURL: String {
        get { MioTabStore.normalizeNewTabURL(UserDefaults.standard.string(forKey: newTabKey)) ?? MioTabStore.defaultNewTabURL }
        set {
            let n = MioTabStore.normalizeNewTabURL(newValue)
            UserDefaults.standard.set(n == MioTabStore.defaultNewTabURL ? nil : n, forKey: newTabKey)
        }
    }

    static var customNewTabURL: String? { UserDefaults.standard.string(forKey: newTabKey) }

    /// 上次保存的标签数（主界面角标在浏览器还没打开过时用）
    static var savedTabCount: Int {
        guard let d = UserDefaults.standard.data(forKey: sessionKey),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let t = o["tabs"] as? [Any] else { return 0 }
        return t.count
    }
}

/// 容器模块（feat/containers-core）的接入点。未接入时只有默认容器，相关菜单不显示。
enum MioTabContainers {
    struct Info {
        let id: String
        let name: String
        let color: UIColor
    }
    /// 容器列表（含默认容器）
    static var list: (() -> [Info])?
    /// 容器的数据存储；nil = 用默认（MioBrowserSettings.dataStoreID）
    static var dataStore: ((String) -> WKWebsiteDataStore?)?

    static var all: [Info] { list?() ?? [] }
    static func info(_ id: String) -> Info? { all.first { $0.id == id } }

    private static var connected = false

    /// 接入容器模块（#15 MioContainerStore）：列表 + 数据存储。iOS 16 / macOS 13 及更早只有默认容器（菜单不显示）
    static func connect() {
        guard !connected else { return }
        connected = true
        list = { MioContainerStore.shared.containers.map { .init(id: $0.id, name: $0.name, color: MioContainerStore.color($0.color)) } }
        dataStore = { MioContainerStore.shared.dataStore(for: $0) }
    }

    /// 新标签的容器：锁定的打开者 > 显式指定 > 站点默认容器 > 未锁定的打开者 > 默认容器
    static func forNewTab(url: String?, opener: MioTab?, requested: String?) -> MioTabContainer {
        MioContainerStore.shared.containerForNewTab(url: url.flatMap { URL(string: $0) },
                                                    opener: opener.map { MioTabContainer(containerId: $0.containerID, locked: $0.locked) },
                                                    requested: requested)
    }

    /// 容器模块里的标签 key
    static func key(_ tabID: Int) -> String { "t\(tabID)" }

    static func mirror(_ t: MioTab) {
        guard connected else { return }
        MioContainerStore.shared.setTab(key(t.id), containerId: t.containerID, locked: t.locked)
    }

    static func unmirror(_ tabID: Int) {
        guard connected else { return }
        MioContainerStore.shared.removeTab(key(tabID))
    }
}

// MARK: - Container view controller

final class MioTabsViewController: UIViewController {
    /// App 运行期间常驻（收起浏览器不销毁标签）
    private(set) static var shared: MioTabsViewController?

    let store = MioTabStore()
    private var controllers: [Int: MioBrowserViewController] = [:]
    private var snapshots: [Int: UIImage] = [:]
    private var interactionStates: [Int: Any] = [:]
    private var observations: [Int: [NSKeyValueObservation]] = [:]
    private let contentView = UIView()
    private var saveWork: DispatchWorkItem?
    private var backgroundObserver: NSObjectProtocol?
    private var containerObservers: [NSObjectProtocol] = []

    static var maxLoaded: Int {
        if MioWebKitCompat.isMac { return 12 }
        return UIDevice.current.userInterfaceIdiom == .pad ? 6 : 4
    }

    static func sharedOrRestore() -> MioTabsViewController {
        if let s = shared { return s }
        MioTabContainers.connect()
        let t = MioTabsViewController()
        // 系统不支持多数据存储（iOS 16 / macOS 13）时不能新建 / 删除容器：保留会话里的容器 id
        let known = MioTabContainers.list == nil || !MioContainerStore.isSupported ? nil : MioTabContainers.all.map(\.id)
        t.store.restore(UserDefaults.standard.data(forKey: MioTabsSettings.sessionKey), knownContainers: known)
        // 容器模块的标签映射与恢复出来的标签对齐（容器 / 锁定以会话为准）
        MioContainerStore.shared.retainTabs(t.store.tabs.map { MioTabContainers.key($0.id) })
        t.store.tabs.forEach(MioTabContainers.mirror)
        shared = t
        return t
    }

    /// MioCore 打开外链：新标签打开并显示浏览器
    static func open(_ url: URL, from base: UIViewController?, containerID: String? = nil) {
        let tabs = sharedOrRestore()
        tabs.openTab(url.absoluteString, activate: true, containerID: containerID)
        tabs.presentIfNeeded(from: base)
    }

    /// 主界面角标：回到浏览器（没有标签就开新标签页）
    static func showBrowser(from base: UIViewController?) {
        let tabs = sharedOrRestore()
        if tabs.store.isEmpty { tabs.openTab(MioTabsSettings.newTabURL, activate: true) }
        tabs.presentIfNeeded(from: base)
    }

    static var isPresented: Bool { shared?.presentingViewController != nil }

    init() {
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.saveNow()
        }
        // 删除容器：先关掉它的标签（释放 WKWebView，数据存储才删得掉）；改名 / 换色：刷新标签条
        containerObservers.append(NotificationCenter.default.addObserver(forName: .mioContainerWillRemove, object: nil, queue: .main) { [weak self] n in
            if let id = n.userInfo?["containerId"] as? String { self?.closeContainerTabs(id) }
        })
        containerObservers.append(NotificationCenter.default.addObserver(forName: .mioContainersDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.refreshChrome()
        })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let o = backgroundObserver { NotificationCenter.default.removeObserver(o) }
        containerObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        contentView.frame = view.bounds
        contentView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(contentView)
        showActive()
    }

    override var childForStatusBarStyle: UIViewController? { activeController }
    override var childForHomeIndicatorAutoHidden: UIViewController? { activeController }

    var activeController: MioBrowserViewController? { store.activeID.flatMap { controllers[$0] } }

    func presentIfNeeded(from base: UIViewController?) {
        MioTabsBadge.remove()
        guard presentingViewController == nil, !isBeingPresented else { return }
        guard let presenter = MioBrowserViewController.topPresenter(base), presenter !== self else { return }
        presenter.present(self, animated: true)
    }

    /// 收起：回到主界面，标签留在后台；主界面显示角标
    func hideBrowser() {
        guard let presenter = presentingViewController else { return }
        activeController.map { takeSnapshot($0) }
        saveNow()
        presenter.dismiss(animated: true) { [weak self] in
            guard let self = self, !self.store.isEmpty else { return }
            MioTabsBadge.show(on: MioTabsBadge.host(for: presenter), count: self.store.count)
        }
    }

    // MARK: tabs

    /// 新标签。from = 打开它的标签（继承容器 / 锁定；插在它右边）
    @discardableResult
    func openTab(_ url: String, activate: Bool, from: MioBrowserViewController? = nil, containerID: String? = nil) -> MioTab? {
        let target = MioTabStore.isHTTP(url) ? url : MioTabsSettings.newTabURL
        let fromActive = from != nil && from?.tabID == store.activeID
        let opener = from?.tabID.flatMap { store.tab($0) }
        let c = MioTabContainers.forNewTab(url: MioTabStore.isHTTP(url) ? url : nil, opener: opener, requested: containerID)
        guard let tab = store.add(target, activate: activate, fromActive: fromActive, containerID: c.containerId, locked: c.locked) else {
            toast("最多同时打开 \(store.maxTabs) 个标签")
            return nil
        }
        MioTabContainers.mirror(tab)
        let proceed = { [weak self] in
            guard let self = self, self.store.tab(tab.id) != nil else { return }
            if activate || !self.isViewLoaded { self.showActive() } else { _ = self.ensureController(tab.id); self.refreshChrome() }
        }
        if URL(string: target)?.host == MioShellTheme.host {
            // 新标签页 = MioCore：先把主界面的登录 Cookie（Cloudflare Access 等）同步到浏览器的数据存储
            MioTabsCookieSync.syncSiteCookies(to: dataStore(for: tab.containerID), completion: proceed)
        } else {
            proceed()
        }
        scheduleSave()
        return tab
    }

    func newTab(containerID: String? = nil) {
        openTab(MioTabsSettings.newTabURL, activate: true, containerID: containerID)
    }

    func select(_ id: Int) {
        guard id != store.activeID else { return }
        activeController.map { takeSnapshot($0) }
        if store.select(id) {
            showActive()
            scheduleSave()
        }
    }

    /// 统一的关闭标签（✕、⌘W、window.close()、跳转系统浏览器后自动关闭）。最后一个标签关掉 → 收起浏览器（App 不退出）
    func closeTab(_ id: Int) {
        teardown(id)
        snapshots[id] = nil
        interactionStates[id] = nil
        guard store.close(id) != nil else { return }
        MioTabContainers.unmirror(id)
        scheduleSave()
        if store.isEmpty {
            saveNow()
            guard let presenter = presentingViewController else { return }
            presenter.dismiss(animated: true) { MioTabsBadge.remove() }
            return
        }
        showActive()
    }

    func closeTab(_ vc: MioBrowserViewController) {
        if let id = vc.tabID { closeTab(id) }
    }

    func reopenClosed() {
        guard let t = store.reopenClosed() else { return }
        MioTabContainers.mirror(t)
        showActive()
        scheduleSave()
    }

    /// 锁定 / 解锁标签的容器（锁定后它打开的标签 / 弹窗都在同一容器并锁定）
    func setLocked(_ id: Int, _ locked: Bool) {
        guard store.setLocked(id, locked), let t = store.tab(id) else { return }
        MioTabContainers.mirror(t)
        refreshChrome()
        scheduleSave()
    }

    /// 删除容器：关掉它的所有标签（数据随后被清除，所以也从「最近关闭」里去掉）
    @discardableResult
    func closeContainerTabs(_ containerID: String) -> [Int] {
        guard containerID != MioTabStore.defaultContainer else { return [] }
        let ids = store.tabs.filter { $0.containerID == containerID }.map(\.id)
        for id in ids { closeTab(id) }
        _ = store.removeContainer(containerID)
        return ids
    }

    /// 标签菜单里的容器项：在容器中重新打开、锁定在此容器（只有默认容器时为空）
    func containerMenuItems(for id: Int) -> [UIMenuElement] {
        let list = MioTabContainers.all
        guard list.count > 1, let t = store.tab(id) else { return [] }
        let reopen = list.map { c in
            UIAction(title: c.name, image: UIImage(systemName: "circle.fill")?.withTintColor(c.color, renderingMode: .alwaysOriginal),
                     state: c.id == t.containerID ? .on : .off) { [weak self] _ in
                guard c.id != t.containerID else { return }
                self?.openTab(t.url, activate: true, containerID: c.id)
            }
        }
        var items: [UIMenuElement] = []
        // 锁定的标签不能换容器
        if !t.locked { items.append(UIMenu(title: "在容器中重新打开", image: UIImage(systemName: "person.2.square.stack"), children: reopen)) }
        return items + [
            UIAction(title: "锁定在此容器", image: UIImage(systemName: t.locked ? "lock.fill" : "lock.open"), state: t.locked ? .on : .off) { [weak self] _ in
                self?.setLocked(id, !t.locked)
            },
        ]
    }

    /// 新建标签页（选择容器）菜单项
    func newTabContainerItems() -> [UIMenuElement] {
        let list = MioTabContainers.all
        guard list.count > 1 else { return [] }
        return list.map { c in
            UIAction(title: c.name, image: UIImage(systemName: "circle.fill")?.withTintColor(c.color, renderingMode: .alwaysOriginal)) { [weak self] _ in
                self?.newTab(containerID: c.id)
            }
        }
    }

    func closeOthers(_ id: Int) {
        store.select(id)
        for t in store.tabs where t.id != id { closeTab(t.id) }
    }

    func move(from: Int, to: Int) {
        if store.move(from: from, to: to) {
            refreshChrome()
            scheduleSave()
        }
    }

    func dataStore(for containerID: String) -> WKWebsiteDataStore? {
        if let s = MioTabContainers.dataStore?(containerID) { return s }
        if #available(iOS 17.0, macCatalyst 17.0, *) { return WKWebsiteDataStore(forIdentifier: MioBrowserSettings.dataStoreID) }
        return .default()
    }

    func controller(for id: Int) -> MioBrowserViewController? { controllers[id] }
    func snapshot(for id: Int) -> UIImage? { snapshots[id] }

    @discardableResult
    private func ensureController(_ id: Int) -> MioBrowserViewController? {
        if let vc = controllers[id] { return vc }
        guard let tab = store.tab(id), let url = URL(string: tab.url) ?? URL(string: MioTabsSettings.newTabURL) else { return nil }
        let vc = MioBrowserViewController(url: url)
        vc.tabID = id
        vc.containerID = tab.containerID
        if let s = interactionStates.removeValue(forKey: id) { vc.restoreInteractionState = s }
        controllers[id] = vc
        addChild(vc)
        vc.view.frame = contentView.bounds
        vc.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        vc.view.isHidden = id != store.activeID
        contentView.addSubview(vc.view)
        vc.didMove(toParent: self)
        if let wv = vc.webView {
            let sync: (WKWebView) -> Void = { [weak self] wv in
                guard let self = self else { return }
                let u = wv.url?.absoluteString
                if self.store.update(id, url: (u.map { MioTabStore.isHTTP($0) } ?? false) ? u : nil, title: wv.title) {
                    self.scheduleSave()
                    self.refreshChrome()
                }
            }
            observations[id] = [
                wv.observe(\.url, options: [.new]) { wv, _ in sync(wv) },
                wv.observe(\.title, options: [.new]) { wv, _ in sync(wv) },
            ]
        }
        enforceLimit()
        return vc
    }

    private func teardown(_ id: Int) {
        observations[id]?.forEach { $0.invalidate() }
        observations[id] = nil
        guard let vc = controllers.removeValue(forKey: id) else { return }
        vc.webView?.stopLoading()
        vc.willMove(toParent: nil)
        vc.view.removeFromSuperview()
        vc.removeFromParent()
    }

    /// 后台标签卸载：保存历史 / 滚动位置（iOS 15+ interactionState）和截图，释放 WebView
    private func unload(_ id: Int) {
        guard id != store.activeID, let vc = controllers[id] else { return }
        takeSnapshot(vc)
        if let wv = vc.webView { interactionStates[id] = wv.interactionState }
        teardown(id)
    }

    private func enforceLimit() {
        for id in store.toUnload(maxLoaded: Self.maxLoaded, isLoaded: { controllers[$0.id] != nil }) { unload(id) }
    }

    private func showActive() {
        guard isViewLoaded, let id = store.activeID, let vc = ensureController(id) else { return }
        for (tid, c) in controllers { c.view.isHidden = tid != id }
        MioBrowserViewController.current = vc
        setNeedsStatusBarAppearanceUpdate()
        refreshChrome()
    }

    func takeSnapshot(_ vc: MioBrowserViewController) {
        guard let id = vc.tabID, let wv = vc.webView, wv.window != nil, wv.bounds.width > 0 else { return }
        let cfg = WKSnapshotConfiguration()
        cfg.snapshotWidth = NSNumber(value: Double(min(wv.bounds.width, 480)))
        wv.takeSnapshot(with: cfg) { [weak self] img, _ in
            if let img = img { self?.snapshots[id] = img }
        }
    }

    /// 标签条 / 标签按钮跟着刷新（只刷当前标签那一份工具栏）
    func refreshChrome() {
        activeController?.tabChrome?.reload(count: store.count)
        if let overview = presentedViewController as? MioTabOverviewViewController { overview.reload() }
    }

    func showOverview() {
        activeController.map { takeSnapshot($0) }
        let vc = MioTabOverviewViewController(tabs: self)
        if MioWebKitCompat.isMac || UIDevice.current.userInterfaceIdiom == .pad {
            vc.modalPresentationStyle = .formSheet
            vc.preferredContentSize = CGSize(width: 760, height: 560)
        } else {
            vc.modalPresentationStyle = .fullScreen
        }
        // 截图是异步的：稍等再弹出，当前标签的缩略图是最新的
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self = self, self.presentedViewController == nil else { return }
            self.present(vc, animated: true)
        }
    }

    func toast(_ text: String) {
        let label = UILabel()
        label.text = "  \(text)  "
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .systemBackground
        label.backgroundColor = UIColor.label.withAlphaComponent(0.85)
        label.layer.cornerRadius = 10
        label.clipsToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.heightAnchor.constraint(equalToConstant: 36),
        ])
        UIView.animate(withDuration: 0.3, delay: 1.8, options: [], animations: { label.alpha = 0 }, completion: { _ in label.removeFromSuperview() })
    }

    // MARK: persistence

    func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        UserDefaults.standard.set(store.serialize(), forKey: MioTabsSettings.sessionKey)
    }

    // MARK: keyboard（Mac 上 ⌘T / ⌘W / ⌘⇧T / ⌘⇧W 在菜单栏，见 AppDelegate.buildMenu）

    override var keyCommands: [UIKeyCommand]? {
        var c: [UIKeyCommand] = [
            UIKeyCommand(title: "下一个标签页", action: #selector(mioNextTab(_:)), input: "\t", modifierFlags: .control),
            UIKeyCommand(title: "上一个标签页", action: #selector(mioPreviousTab(_:)), input: "\t", modifierFlags: [.control, .shift]),
            UIKeyCommand(title: "下一个标签页", action: #selector(mioNextTab(_:)), input: "]", modifierFlags: [.command, .shift]),
            UIKeyCommand(title: "上一个标签页", action: #selector(mioPreviousTab(_:)), input: "[", modifierFlags: [.command, .shift]),
            UIKeyCommand(title: "标签概览", action: #selector(mioShowOverview(_:)), input: "\\", modifierFlags: [.command, .shift]),
        ]
        for n in 1...9 {
            c.append(UIKeyCommand(title: "第 \(n) 个标签页", action: #selector(mioSelectNumber(_:)), input: "\(n)", modifierFlags: .command))
        }
        #if !targetEnvironment(macCatalyst)
        c.append(UIKeyCommand(title: "新建标签页", action: #selector(mioNewTab(_:)), input: "t", modifierFlags: .command))
        c.append(UIKeyCommand(title: "关闭标签页", action: #selector(mioCloseTab(_:)), input: "w", modifierFlags: .command))
        c.append(UIKeyCommand(title: "重新打开关闭的标签页", action: #selector(mioReopenTab(_:)), input: "t", modifierFlags: [.command, .shift]))
        c.append(UIKeyCommand(title: "收起浏览器", action: #selector(mioHideBrowser(_:)), input: "w", modifierFlags: [.command, .shift]))
        #endif
        return c
    }

    @objc func mioNewTab(_ sender: Any?) {
        newTab()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.activeController?.focusAddressField() }
    }
    @objc func mioCloseTab(_ sender: Any?) { if let id = store.activeID { closeTab(id) } }
    @objc func mioReopenTab(_ sender: Any?) { reopenClosed() }
    @objc func mioHideBrowser(_ sender: Any?) { hideBrowser() }
    @objc func mioNextTab(_ sender: Any?) { if let i = store.activeIndex, store.count > 1 { select(store.tabs[(i + 1) % store.count].id) } }
    @objc func mioPreviousTab(_ sender: Any?) { if let i = store.activeIndex, store.count > 1 { select(store.tabs[(i - 1 + store.count) % store.count].id) } }
    @objc func mioShowOverview(_ sender: Any?) { showOverview() }
    @objc func mioSelectNumber(_ sender: UIKeyCommand) {
        guard let n = Int(sender.input ?? "") else { return }
        let i = n == 9 ? store.count - 1 : n - 1
        if store.tabs.indices.contains(i) { select(store.tabs[i].id) }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(mioReopenTab(_:)) { return store.hasClosed }
        return super.canPerformAction(action, withSender: sender)
    }
}

// MARK: - Cookie sync（新标签页打开 MioCore 时复用主界面的登录状态）

enum MioTabsCookieSync {
    /// 主界面（WKWebsiteDataStore.default()）里 mio.300031.xyz 的 Cookie 复制到浏览器的数据存储
    static func syncSiteCookies(to target: WKWebsiteDataStore?, completion: @escaping () -> Void) {
        guard let target = target, target !== WKWebsiteDataStore.default() else { completion(); return }
        let host = MioShellTheme.host
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            let mine = cookies.filter { c in
                let d = c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain
                return host == d || host.hasSuffix("." + d)
            }
            guard !mine.isEmpty else { DispatchQueue.main.async(execute: completion); return }
            let group = DispatchGroup()
            for c in mine {
                group.enter()
                target.httpCookieStore.setCookie(c) { group.leave() }
            }
            group.notify(queue: .main, execute: completion)
        }
    }
}

// MARK: - Browser tab integration（MioBrowserViewController 的标签相关部分）

extension MioBrowserViewController {
    var tabsController: MioTabsViewController? { parent as? MioTabsViewController }

    /// Mac / iPad：Safari 式顶部工具栏 + 标签条；iPhone：底部工具栏加标签按钮
    static var usesTopChrome: Bool { MioWebKitCompat.isMac || UIDevice.current.userInterfaceIdiom == .pad }

    func focusAddressField() {
        showChrome(animated: false)
        addressField.becomeFirstResponder()
    }

    /// buildLayout 最后调用（此时 toolbar.items 已由各功能设好）
    func installTabChrome() {
        let chrome = MioTabChrome(browser: self)
        tabChrome = chrome
        guard Self.usesTopChrome else {
            var items = toolbar.items ?? []
            items.append(UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil))
            items.append(chrome.tabsItem)
            toolbar.items = items
            return
        }
        chrome.installTop()
    }

    // 长按 / 右键链接：「在新标签页中打开」「在容器中打开」，后面跟系统默认菜单项
    @objc(webView:contextMenuConfigurationForElement:completionHandler:)
    func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo, completionHandler: @escaping (UIContextMenuConfiguration?) -> Void) {
        guard let url = elementInfo.linkURL, MioTabStore.isHTTP(url.absoluteString), tabsController != nil else {
            completionHandler(UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { UIMenu(children: $0) })
            return
        }
        let config = UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] suggested in
            var items: [UIMenuElement] = [
                UIAction(title: "在新标签页中打开", image: UIImage(systemName: "plus.square.on.square")) { _ in
                    guard let self = self else { return }
                    self.tabsController?.openTab(url.absoluteString, activate: false, from: self)
                },
                UIAction(title: "在新标签页中打开并切换", image: UIImage(systemName: "arrow.up.right.square")) { _ in
                    guard let self = self else { return }
                    self.tabsController?.openTab(url.absoluteString, activate: true, from: self)
                },
            ]
            let containers = MioTabContainers.all
            if containers.count > 1 {
                let locked = self?.tabID.flatMap { id in self?.tabsController?.store.tab(id) }?.locked ?? false
                let current = self?.containerID ?? MioTabStore.defaultContainer
                let sub = containers.map { c in
                    UIAction(title: c.name, image: UIImage(systemName: "circle.fill")?.withTintColor(c.color, renderingMode: .alwaysOriginal),
                             attributes: locked && c.id != current ? .disabled : []) { _ in
                        guard let self = self else { return }
                        self.tabsController?.openTab(url.absoluteString, activate: true, from: self, containerID: c.id)
                    }
                }
                items.append(UIMenu(title: "在容器中打开", image: UIImage(systemName: "person.2.square.stack"), children: sub))
            }
            return UIMenu(children: [UIMenu(options: .displayInline, children: items)] + suggested)
        }
        completionHandler(config)
    }
}

/// 一个标签的工具栏状态：标签按钮（iPhone 底栏）或 顶部工具栏 + 标签条（Mac / iPad）
final class MioTabChrome {
    weak var browser: MioBrowserViewController?
    private(set) var isTop = false
    let stripHeight: CGFloat = MioWebKitCompat.isMac ? MioMacMetrics.stripHeight : 38
    var top: NSLayoutConstraint?
    private(set) var strip: MioTabStripView?
    private var addressSlot: MioAddressSlot?
    private var boundsObservation: NSKeyValueObservation?
    private(set) lazy var tabsItem: UIBarButtonItem = makeTabsItem()

    init(browser: MioBrowserViewController) {
        self.browser = browser
    }

    private func makeTabsItem() -> UIBarButtonItem {
        let primary = UIAction(title: "标签概览", image: UIImage(systemName: "square.on.square")) { [weak self] _ in
            self?.browser?.tabsController?.showOverview()
        }
        let item = UIBarButtonItem(title: nil, image: UIImage(systemName: "square.on.square"), primaryAction: primary, menu: menu())
        item.accessibilityLabel = "标签页"
        return item
    }

    private func menu() -> UIMenu {
        UIMenu(children: [
            UIAction(title: "新建标签页", image: UIImage(systemName: "plus")) { [weak self] _ in self?.browser?.tabsController?.mioNewTab(nil) },
            UIAction(title: "重新打开关闭的标签页", image: UIImage(systemName: "arrow.uturn.backward")) { [weak self] _ in self?.browser?.tabsController?.reopenClosed() },
            UIAction(title: "关闭此标签页", image: UIImage(systemName: "xmark"), attributes: .destructive) { [weak self] _ in
                guard let b = self?.browser else { return }
                b.tabsController?.closeTab(b)
            },
            UIAction(title: "收起浏览器（标签保留）", image: UIImage(systemName: "chevron.down")) { [weak self] _ in self?.browser?.tabsController?.hideBrowser() },
            // 容器：新建容器标签页 / 在容器中重新打开 / 锁定（每次打开菜单时按当前容器列表生成）
            UIDeferredMenuElement.uncached { [weak self] done in
                guard let b = self?.browser, let tabs = b.tabsController, let id = b.tabID else { done([]); return }
                let newItems = tabs.newTabContainerItems()
                var items: [UIMenuElement] = []
                if !newItems.isEmpty { items.append(UIMenu(title: "新建容器标签页", image: UIImage(systemName: "plus.square.dashed"), children: newItems)) }
                items += tabs.containerMenuItems(for: id)
                done(items.isEmpty ? [] : [UIMenu(options: .displayInline, children: items)])
            },
        ])
    }

    func reload(count: Int) {
        // iPhone：标签按钮显示数字（SF Symbols 有 1.square … 50.square）
        if !isTop {
            let img = (1...50).contains(count) ? UIImage(systemName: "\(count).square") : nil
            tabsItem.image = img ?? UIImage(systemName: "square.on.square")
        }
        strip?.reload()
    }

    /// 顶部工具栏：把底部 UIToolbar 挪到顶部，地址栏 / 拦截按钮作为自定义项放进同一行，下面接标签条
    func installTop() {
        guard let b = browser, let view = b.view, let wv = b.webView else { return }
        isTop = true
        let toolbar = b.toolbar
        // 原来的顶栏（✕ / 地址栏 / 拦截）不再显示：地址栏和拦截按钮搬进工具栏
        b.addressField.removeFromSuperview()
        b.shieldButton.removeFromSuperview()
        b.progress.removeFromSuperview()
        b.topBar.isHidden = true
        toolbar.removeFromSuperview()

        // 工具栏原有的按钮（去掉弹性空白）：前 3 个是 后退 / 前进 / 刷新，其余（分享、Safari、各功能按钮、设置）放地址栏右边
        let isSpacer: (UIBarButtonItem) -> Bool = { $0.customView == nil && $0.image == nil && $0.title == nil && $0.action == nil && $0.primaryAction == nil && $0.menu == nil }
        var buttons = (toolbar.items ?? []).filter { !isSpacer($0) }
        for item in buttons where item.title != nil && item.image == nil && item.accessibilityLabel == "用 Safari 打开" {
            // Mac 上原来是文字按钮「用 Safari 打开 ⌘⇧O」：顶栏里改成图标（菜单栏 ⌘⇧O 照旧）
            item.title = nil
            item.image = UIImage(systemName: "safari")
        }
        let nav = Array(buttons.prefix(3))
        buttons = Array(buttons.dropFirst(min(3, buttons.count)))

        let close = UIBarButtonItem(image: UIImage(systemName: "chevron.down"), style: .plain, target: b, action: #selector(MioBrowserViewController.closeTapped))
        close.accessibilityLabel = "收起浏览器（标签保留在后台）"
        let slot = MioAddressSlot(field: b.addressField)
        addressSlot = slot
        let addressItem = UIBarButtonItem(customView: slot)
        b.shieldButton.translatesAutoresizingMaskIntoConstraints = false
        b.shieldButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
        let shieldItem = UIBarButtonItem(customView: b.shieldButton)
        let newTab = UIBarButtonItem(image: UIImage(systemName: "plus"), style: .plain, target: nil, action: nil)
        newTab.primaryAction = UIAction(image: UIImage(systemName: "plus")) { [weak self] _ in self?.browser?.tabsController?.mioNewTab(nil) }
        newTab.accessibilityLabel = "新建标签页"
        // 长按 / 右键「+」：在某个容器里新建标签页（按当前容器列表生成；只有默认容器时为空）
        newTab.menu = UIMenu(title: "新建标签页（选择容器）", children: [
            UIDeferredMenuElement.uncached { [weak self] done in done(self?.browser?.tabsController?.newTabContainerItems() ?? []) },
        ])
        let flex = { UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil) }
        let right = parityExtraItems() + buttons + [shieldItem, tabsItem, newTab]
        toolbar.items = [close] + nav + [flex(), addressItem, flex()] + right
        slot.reserved = CGFloat(1 + nav.count + right.count) * 44 + 32

        toolbar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toolbar)
        let fill = UIView()
        fill.backgroundColor = .secondarySystemBackground
        fill.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(fill)
        let strip = MioTabStripView(chrome: self)
        strip.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(strip)
        self.strip = strip
        b.progress.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(b.progress)

        // webView 原来贴着安全区顶部、被浮动的顶栏盖住；现在从标签条下面开始
        for c in view.constraints where (c.firstItem as? WKWebView) === wv && c.firstAttribute == .top { c.isActive = false }
        let top = toolbar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
        self.top = top
        NSLayoutConstraint.activate([
            fill.topAnchor.constraint(equalTo: view.topAnchor),
            fill.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            fill.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            fill.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            top,
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            strip.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            strip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            strip.heightAnchor.constraint(equalToConstant: stripHeight),
            b.progress.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            b.progress.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            b.progress.bottomAnchor.constraint(equalTo: strip.bottomAnchor),
            b.progress.heightAnchor.constraint(equalToConstant: 2),
            wv.topAnchor.constraint(equalTo: strip.bottomAnchor),
        ])
        view.bringSubviewToFront(fill)
        view.bringSubviewToFront(b.miniBar)
        boundsObservation = toolbar.observe(\.bounds, options: [.initial, .new]) { [weak slot] tb, _ in
            slot?.toolbarWidth = tb.bounds.width
        }
        strip.reload()
        parityStyleTop(toolbar: toolbar, addressSlot: slot)   // Mac：Safari 尺寸（MioDesktopParity.swift）
    }
}

/// 顶部工具栏里的地址栏：宽度随窗口变化（夹在 160…680），两边弹性空白让它居中
final class MioAddressSlot: UIView {
    private var width: NSLayoutConstraint!
    var reserved: CGFloat = 400 { didSet { update() } }
    var toolbarWidth: CGFloat = 0 { didSet { update() } }

    init(field: UITextField) {
        super.init(frame: CGRect(x: 0, y: 0, width: 400, height: 36))
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        width = widthAnchor.constraint(equalToConstant: 400)
        NSLayoutConstraint.activate([
            width,
            heightAnchor.constraint(equalToConstant: 34),
            field.leadingAnchor.constraint(equalTo: leadingAnchor),
            field.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func update() {
        guard toolbarWidth > 0 else { return }
        let w = max(160, min(680, toolbarWidth - reserved))
        if abs(width.constant - w) > 0.5 {
            width.constant = w
            superview?.setNeedsLayout()
        }
    }
}

// MARK: - Tab strip（Mac / iPad 标签条）

final class MioTabStripView: UIView {
    private weak var chrome: MioTabChrome?
    private let scroll = UIScrollView()
    private let plus = UIButton(type: .system)
    private var cells: [MioTabStripCell] = []

    init(chrome: MioTabChrome) {
        self.chrome = chrome
        super.init(frame: .zero)
        backgroundColor = .secondarySystemBackground
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = false
        addSubview(scroll)
        plus.setImage(UIImage(systemName: "plus"), for: .normal)
        plus.accessibilityLabel = "新建标签页"
        plus.addAction(UIAction { [weak self] _ in self?.tabs?.mioNewTab(nil) }, for: .touchUpInside)
        addSubview(plus)
        let line = UIView()
        line.backgroundColor = .separator
        line.frame = CGRect(x: 0, y: 0, width: 1, height: 1 / UIScreen.main.scale)
        line.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
        addSubview(line)
        line.tag = 99
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var tabs: MioTabsViewController? { chrome?.browser?.tabsController }

    func reload() {
        guard let tabs = tabs else { return }
        let list = tabs.store.tabs
        while cells.count < list.count {
            let c = MioTabStripCell()
            c.strip = self
            scroll.addSubview(c)
            cells.append(c)
        }
        while cells.count > list.count { cells.removeLast().removeFromSuperview() }
        for (i, t) in list.enumerated() {
            let vc = tabs.controller(for: t.id)
            let title = (vc?.webView?.title).flatMap { $0.isEmpty ? nil : $0 } ?? (t.title.isEmpty ? (MioTabStore.displayHost(t.url).isEmpty ? "新标签页" : MioTabStore.displayHost(t.url)) : t.title)
            cells[i].configure(id: t.id, index: i, title: title, active: t.id == tabs.store.activeID, loaded: vc != nil,
                               container: t.containerID == MioTabStore.defaultContainer ? nil : MioTabContainers.info(t.containerID), locked: t.locked)
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let plusW: CGFloat = 36
        plus.frame = CGRect(x: bounds.width - plusW - 4, y: 0, width: plusW, height: bounds.height - 4)
        scroll.frame = CGRect(x: 6, y: 2, width: max(0, bounds.width - plusW - 14), height: bounds.height - 6)
        viewWithTag(99)?.frame = CGRect(x: 0, y: bounds.height - 1 / UIScreen.main.scale, width: bounds.width, height: 1 / UIScreen.main.scale)
        guard !cells.isEmpty else { return }
        let gap: CGFloat = 4
        let avail = scroll.bounds.width - gap * CGFloat(cells.count - 1)
        let w = max(110, min(240, avail / CGFloat(cells.count)))
        for (i, c) in cells.enumerated() {
            c.frame = CGRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: scroll.bounds.height)
        }
        scroll.contentSize = CGSize(width: CGFloat(cells.count) * (w + gap) - gap, height: scroll.bounds.height)
        if let active = cells.first(where: { $0.isActive }) { scroll.scrollRectToVisible(active.frame, animated: false) }
    }

    func select(_ id: Int) { tabs?.select(id) }
    func close(_ id: Int) { tabs?.closeTab(id) }
}

final class MioTabStripCell: UIControl {
    weak var strip: MioTabStripView?
    private(set) var tabID = 0
    private(set) var isActive = false
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let bar = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 8
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)
        closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)), for: .normal)
        closeButton.tintColor = .secondaryLabel
        closeButton.accessibilityLabel = "关闭标签页"
        closeButton.addAction(UIAction { [weak self] _ in
            guard let self = self else { return }
            self.strip?.close(self.tabID)
        }, for: .touchUpInside)
        addSubview(closeButton)
        bar.layer.cornerRadius = 1
        addSubview(bar)
        addAction(UIAction { [weak self] _ in
            guard let self = self else { return }
            self.strip?.select(self.tabID)
        }, for: .touchUpInside)
        // 中键点击关闭（Mac 鼠标 / iPad 触控板）
        let middle = UITapGestureRecognizer(target: self, action: #selector(middleClick))
        middle.buttonMaskRequired = .button(3)
        addGestureRecognizer(middle)
        // 右键 / 长按：UIControl 自带的上下文菜单交互
        isContextMenuInteractionEnabled = true
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(id: Int, index: Int, title: String, active: Bool, loaded: Bool, container: MioTabContainers.Info?, locked: Bool) {
        tabID = id
        isActive = active
        titleLabel.text = (locked ? "🔒 " : "") + title
        titleLabel.textColor = active ? .label : .secondaryLabel
        titleLabel.font = loaded ? .systemFont(ofSize: 12, weight: active ? .semibold : .regular) : .italicSystemFont(ofSize: 12)
        backgroundColor = active ? .systemBackground : .tertiarySystemFill
        bar.backgroundColor = container?.color ?? .clear
        accessibilityLabel = title + (container.map { "，容器 \($0.name)" } ?? "")
        accessibilityTraits = active ? [.button, .selected] : .button
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        closeButton.frame = CGRect(x: bounds.width - 26, y: (bounds.height - 22) / 2, width: 22, height: 22)
        titleLabel.frame = CGRect(x: 10, y: 0, width: max(0, bounds.width - 40), height: bounds.height)
        bar.frame = CGRect(x: 8, y: bounds.height - 3, width: bounds.width - 16, height: 2)
    }

    @objc private func middleClick() { strip?.close(tabID) }

    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        let id = tabID
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let tabs = self?.strip?.tabs else { return nil }
            let url = tabs.store.tab(id)?.url ?? ""
            return UIMenu(children: [
                UIAction(title: "复制链接", image: UIImage(systemName: "link")) { _ in UIPasteboard.general.string = url },
                UIAction(title: "复制标签页", image: UIImage(systemName: "plus.square.on.square")) { _ in
                    tabs.openTab(url, activate: true, containerID: tabs.store.tab(id)?.containerID)
                },
                UIAction(title: "向左移动", image: UIImage(systemName: "arrow.left")) { _ in
                    if let i = tabs.store.index(of: id) { tabs.move(from: i, to: i - 1) }
                },
                UIAction(title: "向右移动", image: UIImage(systemName: "arrow.right")) { _ in
                    if let i = tabs.store.index(of: id) { tabs.move(from: i, to: i + 1) }
                },
                UIMenu(options: .displayInline, children: tabs.containerMenuItems(for: id)),
                UIAction(title: "关闭其他标签页", image: UIImage(systemName: "xmark.square")) { _ in tabs.closeOthers(id) },
                UIAction(title: "关闭标签页", image: UIImage(systemName: "xmark"), attributes: .destructive) { _ in tabs.closeTab(id) },
            ])
        }
    }
}

// MARK: - Tab overview（网格卡片：截图 + 标题 + 域名）

final class MioTabOverviewViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    private weak var tabs: MioTabsViewController?
    private var collection: UICollectionView!
    private let countLabel = UILabel()

    init(tabs: MioTabsViewController) {
        self.tabs = tabs
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 16
        layout.sectionInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collection.backgroundColor = .clear
        collection.dataSource = self
        collection.delegate = self
        collection.register(MioTabCard.self, forCellWithReuseIdentifier: "card")
        collection.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collection)

        let bar = UIToolbar()
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)
        countLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        let reopen = UIBarButtonItem(title: nil, image: UIImage(systemName: "arrow.uturn.backward"), primaryAction: UIAction { [weak self] _ in
            self?.tabs?.reopenClosed()
            self?.reload()
        }, menu: nil)
        reopen.accessibilityLabel = "重新打开关闭的标签页"
        reopen.isEnabled = tabs?.store.hasClosed ?? false
        let add = UIBarButtonItem(title: nil, image: UIImage(systemName: "plus"), primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true) { self?.tabs?.mioNewTab(nil) }
        }, menu: nil)
        add.accessibilityLabel = "新建标签页"
        let hide = UIBarButtonItem(title: nil, image: UIImage(systemName: "chevron.down"), primaryAction: UIAction { [weak self] _ in
            let t = self?.tabs
            self?.dismiss(animated: false) { t?.hideBrowser() }
        }, menu: nil)
        hide.accessibilityLabel = "收起浏览器"
        let done = UIBarButtonItem(title: "完成", image: nil, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }, menu: nil)
        done.style = .done
        let flex = { UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil) }
        bar.items = [hide, reopen, flex(), UIBarButtonItem(customView: countLabel), flex(), add, done]

        NSLayoutConstraint.activate([
            collection.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            collection.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            collection.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            collection.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
        reload()
    }

    func reload() {
        guard isViewLoaded else { return }
        let n = tabs?.store.count ?? 0
        countLabel.text = "\(n) 个标签页"
        countLabel.sizeToFit()
        collection.reloadData()
        if n == 0 { dismiss(animated: true) }
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { tabs?.store.count ?? 0 }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "card", for: indexPath) as! MioTabCard
        guard let tabs = tabs, tabs.store.tabs.indices.contains(indexPath.item) else { return cell }
        let t = tabs.store.tabs[indexPath.item]
        let host = MioTabStore.displayHost(t.url)
        let title = (tabs.controller(for: t.id)?.webView?.title).flatMap { $0.isEmpty ? nil : $0 } ?? (t.title.isEmpty ? host : t.title)
        cell.configure(title: title.isEmpty ? "新标签页" : title, host: host, image: tabs.snapshot(for: t.id), active: t.id == tabs.store.activeID,
                       container: t.containerID == MioTabStore.defaultContainer ? nil : MioTabContainers.info(t.containerID))
        cell.onClose = { [weak self] in
            self?.tabs?.closeTab(t.id)
            self?.reload()
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let w = collectionView.bounds.width - 32
        let columns: CGFloat = w > 900 ? 4 : (w > 560 ? 3 : 2)
        let cw = floor((w - 12 * (columns - 1)) / columns)
        return CGSize(width: cw, height: cw * 1.25 + 40)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let tabs = tabs, tabs.store.tabs.indices.contains(indexPath.item) else { return }
        let id = tabs.store.tabs[indexPath.item].id
        dismiss(animated: true) { tabs.select(id) }
    }
}

final class MioTabCard: UICollectionViewCell {
    var onClose: (() -> Void)?
    private let image = UIImageView()
    private let title = UILabel()
    private let host = UILabel()
    private let close = UIButton(type: .system)
    private let bar = UIView()
    private let placeholder = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemGroupedBackground
        contentView.layer.cornerRadius = 12
        contentView.clipsToBounds = true
        image.contentMode = .scaleAspectFill
        image.clipsToBounds = true
        image.backgroundColor = .tertiarySystemFill
        placeholder.font = .systemFont(ofSize: 34, weight: .bold)
        placeholder.textColor = .tertiaryLabel
        placeholder.textAlignment = .center
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        host.font = .systemFont(ofSize: 11)
        host.textColor = .secondaryLabel
        close.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        close.tintColor = .systemGray
        close.accessibilityLabel = "关闭标签页"
        close.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
        [image, placeholder, title, host, close, bar].forEach { contentView.addSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title t: String, host h: String, image img: UIImage?, active: Bool, container: MioTabContainers.Info?) {
        title.text = t
        host.text = h
        image.image = img
        placeholder.text = img == nil ? String(h.prefix(1)).uppercased() : nil
        contentView.layer.borderWidth = active ? 3 : 0
        contentView.layer.borderColor = UIColor.tintColor.cgColor
        bar.backgroundColor = container?.color ?? .clear
        accessibilityLabel = "\(t)，\(h)" + (active ? "，当前标签" : "")
        isAccessibilityElement = true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let b = contentView.bounds
        image.frame = CGRect(x: 0, y: 0, width: b.width, height: b.height - 40)
        placeholder.frame = image.frame
        bar.frame = CGRect(x: 0, y: b.height - 40, width: b.width, height: 3)
        title.frame = CGRect(x: 10, y: b.height - 37, width: b.width - 20, height: 18)
        host.frame = CGRect(x: 10, y: b.height - 19, width: b.width - 20, height: 14)
        close.frame = CGRect(x: b.width - 34, y: 4, width: 30, height: 30)
    }
}

// MARK: - Main-screen badge（浏览器收起后主界面的「N 个标签」入口）

enum MioTabsBadge {
    private static weak var button: UIButton?

    static func host(for presenter: UIViewController) -> UIView? { presenter.view }

    static func show(on host: UIView?, count: Int) {
        guard let host = host, count > 0 else { remove(); return }
        let b: UIButton
        if let existing = button, existing.superview === host {
            b = existing
        } else {
            button?.removeFromSuperview()
            var cfg = UIButton.Configuration.filled()
            cfg.cornerStyle = .capsule
            cfg.image = UIImage(systemName: "square.on.square")
            cfg.imagePadding = 6
            cfg.baseBackgroundColor = .label
            cfg.baseForegroundColor = .systemBackground
            b = UIButton(configuration: cfg)
            b.accessibilityHint = "回到浏览器"
            b.layer.shadowColor = UIColor.black.cgColor
            b.layer.shadowOpacity = 0.25
            b.layer.shadowRadius = 8
            b.layer.shadowOffset = CGSize(width: 0, height: 2)
            b.translatesAutoresizingMaskIntoConstraints = false
            b.addAction(UIAction { [weak host] _ in
                let vc = host.flatMap { v -> UIViewController? in
                    var r: UIResponder? = v
                    while let n = r { if let c = n as? UIViewController { return c }; r = n.next }
                    return nil
                }
                MioTabsViewController.showBrowser(from: vc)
            }, for: .touchUpInside)
            host.addSubview(b)
            NSLayoutConstraint.activate([
                b.trailingAnchor.constraint(equalTo: host.safeAreaLayoutGuide.trailingAnchor, constant: -14),
                b.bottomAnchor.constraint(equalTo: host.safeAreaLayoutGuide.bottomAnchor, constant: MioWebKitCompat.isMac ? -16 : -84),
                b.heightAnchor.constraint(equalToConstant: 40),
            ])
            button = b
        }
        b.configuration?.title = "\(count)"
        b.accessibilityLabel = "\(count) 个标签"
        host.bringSubviewToFront(b)
    }

    static func remove() {
        button?.removeFromSuperview()
        button = nil
    }

    /// 主界面出现时：App 重启后有上次的标签（或浏览器已收起）→ 显示角标
    static func attachIfNeeded(to vc: UIViewController) {
        guard !MioTabsViewController.isPresented, vc.presentedViewController == nil else { return }
        let n = MioTabsViewController.shared?.store.count ?? MioTabsSettings.savedTabCount
        if n > 0 { show(on: vc.view, count: n) }
    }
}

// MARK: - Mac smoke（MioDesktop.swift 的 CI 冒烟调用）

enum MioTabsSmoke {
    /// 在已打开的浏览器里：新开第 2 个标签、切换、关闭、恢复；检查顶部工具栏和标签条
    static func run(completion: @escaping ([String: Any], Bool) -> Void) {
        guard let tabs = MioTabsViewController.shared, tabs.presentingViewController != nil else {
            completion(["error": "browser not presented"], false)
            return
        }
        var r: [String: Any] = [:]
        let first = tabs.store.activeID
        r["initialCount"] = tabs.store.count
        let firstTop = tabs.activeController?.tabChrome?.isTop ?? false
        r["topChrome"] = firstTop
        tabs.openTab("https://example.com/", activate: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            r["afterOpen"] = tabs.store.count
            let second = tabs.activeController
            r["secondLoadedURL"] = second?.webView?.url?.absoluteString ?? "nil"
            r["distinctWebViews"] = second?.webView !== tabs.controller(for: first ?? -1)?.webView
            r["stripCells"] = tabs.activeController?.tabChrome?.strip?.subviews.first.map { $0.subviews.filter { $0 is MioTabStripCell }.count } ?? -1
            if let f = first { tabs.select(f) }
            r["switchedBack"] = tabs.store.activeID == first && tabs.activeController?.view.isHidden == false
            let wv = tabs.activeController?.webView
            r["webViewBelowChrome"] = (wv?.frame.minY ?? 0) > 40
            if let s = second { tabs.closeTab(s) }
            r["afterClose"] = tabs.store.count
            tabs.reopenClosed()
            r["afterReopen"] = tabs.store.count
            if let id = tabs.store.activeID, id != first { tabs.closeTab(id) }
            r["final"] = tabs.store.count
            let n0 = r["initialCount"] as? Int ?? 0
            let baseOK = (r["afterOpen"] as? Int) == n0 + 1 && (r["distinctWebViews"] as? Bool) == true && (r["switchedBack"] as? Bool) == true
                && (r["afterClose"] as? Int) == n0 && (r["afterReopen"] as? Int) == n0 + 1 && (r["final"] as? Int) == n0
                && (!MioWebKitCompat.isMac || (firstTop && (r["stripCells"] as? Int) == n0 + 1 && (r["webViewBelowChrome"] as? Bool) == true))
            containerCheck(tabs) { cr, containersOK in
                r["containers"] = cr
                let ok = baseOK && containersOK
                r["ok"] = ok
                completion(r, ok)
            }
        }
    }

    /// 容器（iOS 17 / macOS 14+）：容器标签用该容器的数据存储、标签映射、锁定继承、删除容器时关闭其标签
    private static func containerCheck(_ tabs: MioTabsViewController, completion: @escaping (Any, Bool) -> Void) {
        guard MioContainerStore.isSupported else { completion("unsupported", true); return }
        guard let c = try? MioContainerStore.shared.create(name: "smoke-tabs", color: "green") else { completion("create failed", false); return }
        var cr: [String: Any] = [:]
        let before = tabs.store.count
        let t = tabs.openTab("https://example.com/?c", activate: true, containerID: c.id)
        let vc = t.flatMap { tabs.controller(for: $0.id) }
        cr["tabContainer"] = t?.containerID ?? "nil"
        cr["vcContainer"] = vc?.containerId ?? "nil"
        var storeOK = vc?.containerId == c.id
        if #available(iOS 17.0, macCatalyst 17.0, *) {
            let ident = vc?.webView?.configuration.websiteDataStore.identifier?.uuidString.lowercased()
            cr["dataStoreIdentifier"] = ident ?? "nil"
            storeOK = storeOK && ident == c.id.lowercased()
        }
        cr["dataStore"] = storeOK
        cr["mapped"] = t.map { MioContainerStore.shared.tab(MioTabContainers.key($0.id)).containerId == c.id } ?? false
        if let t = t { tabs.setLocked(t.id, true) }
        let child = tabs.openTab("https://example.com/?child", activate: false, from: vc, containerID: MioContainerCore.defaultId)
        cr["childInherits"] = child?.containerID == c.id && child?.locked == true
        cr["listed"] = MioTabContainers.all.contains { $0.id == c.id }
        try? MioContainerStore.shared.remove(c.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            cr["closedOnRemove"] = tabs.store.count == before && !tabs.store.tabs.contains { $0.containerID == c.id }
            let ok = cr["dataStore"] as? Bool == true && cr["mapped"] as? Bool == true && cr["childInherits"] as? Bool == true
                && cr["listed"] as? Bool == true && cr["closedOnRemove"] as? Bool == true
            cr["ok"] = ok
            completion(cr, ok)
        }
    }
}

// MARK: - Settings UI（浏览器设置页「标签页」一节）

enum MioTabsSettingsUI {
    static var footer: String {
        #if targetEnvironment(macCatalyst)
        let keys = "⌘T 新建、⌘W 关闭、⌘⇧T 重新打开、⌃Tab 切换、⌘1…9、⌘⇧W 收起。"
        #else
        let keys = "外接键盘：⌘T 新建、⌘W 关闭、⌘⇧T 重新打开、⌃Tab 切换。"
        #endif
        return "MioCore 里点外链会在新标签打开；网页里的新窗口链接也开新标签，长按 / 右键链接可「在新标签页中打开」。✕ / ⌄ 收起浏览器时标签都留在后台，主界面右下角的数字角标一点即回。App 重启后恢复标签列表。" + keys
    }

    static func configure(_ cell: UITableViewCell) {
        cell.textLabel?.text = "新标签页地址"
        cell.detailTextLabel?.text = MioTabsSettings.customNewTabURL == nil ? "MioCore 导航（默认）" : MioTabsSettings.newTabURL
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
    }

    static func editNewTabPage(from vc: UIViewController, done: @escaping () -> Void) {
        let a = UIAlertController(title: "新标签页地址", message: "留空 = MioCore 导航（沿用主界面的登录状态）", preferredStyle: .alert)
        a.addTextField {
            $0.keyboardType = .URL
            $0.autocapitalizationType = .none
            $0.autocorrectionType = .no
            $0.placeholder = MioTabStore.defaultNewTabURL
            $0.text = MioTabsSettings.customNewTabURL
        }
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        a.addAction(UIAlertAction(title: "恢复默认", style: .default) { _ in
            MioTabsSettings.newTabURL = ""
            done()
        })
        a.addAction(UIAlertAction(title: "保存", style: .default) { _ in
            let t = a.textFields?.first?.text ?? ""
            if MioTabStore.normalizeNewTabURL(t) == nil {
                let e = UIAlertController(title: "无效的网址", message: "只支持 http / https 网址", preferredStyle: .alert)
                e.addAction(UIAlertAction(title: "好", style: .default))
                vc.present(e, animated: true)
                return
            }
            MioTabsSettings.newTabURL = t
            done()
        })
        vc.present(a, animated: true)
    }
}
