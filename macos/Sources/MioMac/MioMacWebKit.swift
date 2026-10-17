// MioMacWebKit.swift — Mac 原生壳与 MioKit（apple/MioKit，线路 C）的接线。浏览器逻辑全部在 MioKit，这里只做宿主：
//
//   - MioMacKit.shared：一个 MioKitContainer（UserDefaults.standard，v0.3.x 同名 key）+ 广告拦截编译器（MioContentBlocker）
//     + 容器数据存储（MioContainerDataStores）+ mio:// 方案处理（MioSchemeHandler）+ 保存到 Mio（MioSaveRunner）
//   - 每个 WKWebView 一个 MioWebViewModules（模块脚本、消息通道、MioCore 桥、内容规则、用户脚本 GM 通道）。
//     window.open 打开的新标签和打开者共用同一个 WKUserContentController，所以按 controller 记账、引用计数
//   - MioCoreBridgeDelegate（openTab / getDeviceInfo / saveToMio / 权限询问）与 MioUserScriptHost（GM_openInTab / 剪贴板 / @connect 询问 / 通知）
//   - 设置变化（.mioSettingsDidChange）→ 每个 WebView 重装脚本 + 按白名单重挂规则；规则编译完成（.mioContentRulesDidChange）→ 重挂规则
//
// UA：AppKit WKWebView 有 MSE，用桌面 Safari UA 即可拿到 YouTube DASH 高清（Catalyst 版没有 MSE，见 docs/mac-native-migration.md）。

import AppKit
import WebKit
@preconcurrency import MioKit

@MainActor
enum MioMacWebKit {
    static var safariVersion: String {
        let pv = ProcessInfo.processInfo.operatingSystemVersion
        let plist = NSDictionary(contentsOfFile: "/System/Library/CoreServices/SystemVersion.plist") as? [String: Any]
        let v = MioWebCompat.macOSVersion(systemVersionPlist: plist, processVersion: (pv.majorVersion, pv.minorVersion))
        return MioWebCompat.safariVersion(macOSMajor: v.major, minor: v.minor)
    }

    static var desktopUserAgent: String { MioWebCompat.desktopUserAgent(safariVersion: safariVersion) }

    /// 用户建的容器（不含默认容器）
    static var userContainers: [MioContainer] { MioMacKit.shared.kit.containers.containers.filter { !$0.isDefault } }

    static func colorFor(container: MioContainer?) -> NSColor? {
        guard let c = container, let hex = MioContainerCore.colorHex[c.color] else { return nil }
        return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

@MainActor
final class MioMacKit {
    static let shared = MioMacKit()

    let kit: MioKitContainer
    let blocker: MioContentBlocker
    let dataStores: MioContainerDataStores
    let schemeHandler: MioSchemeHandler
    private lazy var saveRunner = MioSaveRunner(kit: kit, dataStore: dataStores.dataStore(for: MioContainerCore.defaultId))
    /// Cloudflare Access 登录 Cookie（MioCore 在 Access 后面）：默认容器的固定数据存储，钥匙串备份 + 启动补回；
    /// 第一次启动从 v0.3.x Catalyst 主界面用的 .default() 迁移 MioCore / Access 的 Cookie（升级后不用再登）
    private(set) lazy var accessVault = MioAccessCookieVault(prefs: kit.prefs) { [dataStores] in
        dataStores.dataStore(for: MioContainerCore.defaultId)
    }
    /// 主线程算好，桥可能在任意线程要
    nonisolated(unsafe) private let deviceInfo: MioDeviceInfo

    /// 当前浏览器窗口（App 设置）：桥的 openTab、GM_openInTab 打开到这里
    var currentWindow: () -> MioMacBrowserWindowController? = { nil }
    /// 设置变了（模块开关 / 子设置 / 用户脚本 / 容器）：App 刷新窗口和设置页
    var onSettingsChanged: () -> Void = {}
    /// 冒烟：最近一次 .mioSettingsDidChange 的 key
    private(set) var lastChangedKey: String?
    private(set) var settingsChangeCount = 0

    fileprivate final class Entry {
        let mods: MioWebViewModules
        var webViews: [WeakWebView] = []
        init(mods: MioWebViewModules) { self.mods = mods }
        var live: [WKWebView] { webViews.compactMap(\.value) }
    }
    fileprivate struct WeakWebView { weak var value: WKWebView? }
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var observers: [NSObjectProtocol] = []
    private var prepared = false

    private init() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? MioKitInfo.version
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        kit = MioKitContainer(appVersion: version)
        blocker = MioContentBlocker(manager: kit.filters)
        dataStores = MioContainerDataStores(manager: kit.containers)
        schemeHandler = MioSchemeHandler(kit: kit)
        let pv = ProcessInfo.processInfo.operatingSystemVersion
        deviceInfo = MioDeviceInfo(platform: "macos", model: Self.hardwareModel(),
                                   osVersion: "\(pv.majorVersion).\(pv.minorVersion).\(pv.patchVersion)",
                                   appVersion: version, appBuild: build,
                                   locale: Locale.preferredLanguages.first ?? Locale.current.identifier)
        kit.bridge.delegate = self
        let blocker = self.blocker
        kit.adblock.recompile = { await blocker.reload() }

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .mioSettingsDidChange, object: nil, queue: .main) { [weak self] n in
            let key = n.userInfo?["key"] as? String
            MainActor.assumeIsolated { self?.settingsDidChange(key) }
        })
        observers.append(center.addObserver(forName: .mioContentRulesDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reapplyContentRules() }
        })
        observers.append(center.addObserver(forName: .mioContainersDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onSettingsChanged() }
        })
        observers.append(center.addObserver(forName: .mioContainerWillRemove, object: nil, queue: .main) { [weak self] n in
            guard let id = n.userInfo?["containerId"] as? String else { return }
            MainActor.assumeIsolated { self?.containerWillRemove(id) }
        })
        observers.append(center.addObserver(forName: NSApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.kit.translate.cache.flush()
                if let vault = self?.accessVault { Task { await vault.backUp() } }
            }
        })
    }

    /// App 启动：先加载已编译的规则（秒开），需要时编译内置列表；checkUpdates = 每天检查一次订阅
    func prepare(checkUpdates: Bool = true) {
        guard !prepared else { return }
        prepared = true
        let blocker = self.blocker
        Task { await blocker.prepare(checkUpdates: checkUpdates) }
        let vault = accessVault
        Task {
            await vault.migrateOnce(from: .default())
            await vault.restore()
        }
    }

    // MARK: - Cloudflare Access 登录

    /// 主框架载入完成：回到 MioCore（登录完成）→ 备份 Access Cookie；Access 退出页 → 清空备份。只看默认容器
    func didFinishMainFrame(_ wv: WKWebView) {
        guard wv.configuration.websiteDataStore === dataStores.dataStore(for: MioContainerCore.defaultId) else { return }
        accessVault.didFinishMainFrame(wv.url)
    }

    /// Access 登录页（或 MioCore）用 window.open / target=_blank 打开登录地址 → 在打开者标签里继续
    func shouldOpenPopupInOpener(opener: URL?, target: URL?) -> Bool {
        MioAccessAuth.popupDisposition(opener: opener, target: target, prefs: kit.prefs) == .openerTab
    }

    // MARK: - WebView

    /// 新标签的配置：容器数据存储 + mio:// + 桌面 Safari 应用名
    func configuration(containerID: String) -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = dataStores.dataStore(for: containerID)
        c.setURLSchemeHandler(schemeHandler, forURLScheme: MioHomeModel.scheme)
        c.applicationNameForUserAgent = MioWebCompat.desktopApplicationName(safariVersion: MioMacWebKit.safariVersion)
        c.preferences.isElementFullscreenEnabled = true
        c.preferences.javaScriptCanOpenWindowsAutomatically = false
        c.allowsAirPlayForMediaPlayback = true
        return c
    }

    /// WebView 创建后立刻调用（load 之前）：装模块脚本 / 通道 / 桥 / 规则。window.open 的新 WebView 与打开者共用 controller → 只记一次
    func attach(_ wv: WKWebView) {
        let key = ObjectIdentifier(wv.configuration.userContentController)
        if let e = entries[key] {
            if !e.live.contains(where: { $0 === wv }) { e.webViews.append(WeakWebView(value: wv)) }
            return
        }
        let mods = MioWebViewModules(kit: kit, controller: wv.configuration.userContentController, blocker: blocker)
        mods.userScriptBridge.host = self
        mods.install()
        mods.webView = wv
        mods.applyContentRules(topURL: wv.url)
        let e = Entry(mods: mods)
        e.webViews = [WeakWebView(value: wv)]
        entries[key] = e
    }

    /// 关标签：controller 上最后一个 WebView 走了才拆通道
    func detach(_ wv: WKWebView) {
        let key = ObjectIdentifier(wv.configuration.userContentController)
        guard let e = entries[key] else { return }
        e.webViews.removeAll { $0.value == nil || $0.value === wv }
        if e.webViews.isEmpty {
            e.mods.detach()
            entries[key] = nil
        } else if e.mods.webView === wv || e.mods.webView == nil {
            e.mods.webView = e.live.first
        }
    }

    func modules(for wv: WKWebView?) -> MioWebViewModules? {
        guard let wv else { return nil }
        return entries[ObjectIdentifier(wv.configuration.userContentController)]?.mods
    }

    /// 主框架导航开始：按广告拦截白名单挂 / 卸规则；GM 值变了重装脚本
    func willNavigateMainFrame(_ wv: WKWebView, to url: URL?) {
        modules(for: wv)?.willNavigateMainFrame(to: url)
    }

    /// 菜单项：模块 perform + WebKit 能做的部分（evaluateJavaScript / runScript）；返回宿主要处理的动作
    func perform(_ item: MioModuleMenuItem, page: MioPageContext, webView: WKWebView?) async -> MioModuleAction {
        guard let mods = modules(for: webView) else { return kit.registry.perform(item, page: page) }
        mods.webView = webView
        return await mods.perform(item, page: page)
    }

    func pageMenuItems(_ page: MioPageContext) -> [MioModuleMenuItem] {
        kit.registry.menuItems(page: page).filter { $0.placement == .pageMenu }
    }

    func reinstallAll() {
        prune()
        for e in entries.values {
            e.mods.install()
            e.mods.applyContentRules(topURL: e.live.first?.url)
        }
    }

    private func reapplyContentRules() {
        prune()
        for e in entries.values { e.mods.applyContentRules(topURL: e.live.first?.url) }
    }

    private func settingsDidChange(_ key: String?) {
        lastChangedKey = key
        settingsChangeCount += 1
        reinstallAll()
        onSettingsChanged()
    }

    private func prune() {
        for (k, e) in entries where e.live.isEmpty {
            e.mods.detach()
            entries[k] = nil
        }
    }

    /// 删容器：窗口先关掉这个容器的标签（MioMacBrowserWindowController 也监听同一通知），再删数据存储
    private func containerWillRemove(_ id: String) {
        let stores = dataStores
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            await stores.purge(id)
        }
    }

    // MARK: - 保存到 Mio

    func save(kind: String, payloadJSON: String) async -> [String: Any] {
        await saveRunner.save(kind: kind, payloadJSON: payloadJSON)
    }

    fileprivate func saveJSON(kind: String, payloadJSON: String) async -> String {
        let r = await saveRunner.save(kind: kind, payloadJSON: payloadJSON)
        let data = (try? JSONSerialization.data(withJSONObject: r)) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - 宿主动作（主线程）

    fileprivate func openTab(_ url: URL, background: Bool) {
        guard let c = currentWindow() else { return }
        c.newTab(url: url.absoluteString, activate: !background, fromActive: true)
    }

    fileprivate func ask(title: String, message: String, allow: String = "允许", deny: String = "不允许") -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: allow)
        a.addButton(withTitle: deny)
        return a.runModal() == .alertFirstButtonReturn
    }

    fileprivate func askConnect(scriptName: String, host: String) -> (allow: Bool, remember: Bool) {
        let a = NSAlert()
        a.messageText = "用户脚本「\(scriptName)」想访问 \(host)"
        a.informativeText = "脚本在 @connect 里声明了这个网站。允许后它可以带着请求访问 \(host)（不带你的 Cookie）。"
        a.addButton(withTitle: "总是允许")
        a.addButton(withTitle: "仅这一次")
        a.addButton(withTitle: "拒绝")
        switch a.runModal() {
        case .alertFirstButtonReturn: return (true, true)
        case .alertSecondButtonReturn: return (true, false)
        default: return (false, true)
        }
    }

    fileprivate func toast(_ s: String) {
        guard let c = currentWindow() else { return }
        c.toast.show(s, button: nil, in: c.webContainer)
    }

    nonisolated static func permissionTitle(_ p: MioBridgePermission) -> String {
        switch p.rawValue {
        case "photos": return "相册"
        case "deviceControl": return "控制本机"
        case "files": return "文件"
        default: return p.rawValue
        }
    }

    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "Mac" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        let s = String(cString: buf)
        return s.isEmpty ? "Mac" : s
    }
}

// MARK: - MioCoreBridgeDelegate（MioKit 可能在任意线程调用）

extension MioMacKit: MioCoreBridgeDelegate {
    nonisolated func bridgeDeviceInfo() -> MioDeviceInfo { deviceInfo }

    nonisolated func bridgeOpenTab(_ url: URL, background: Bool) -> Bool {
        Task { @MainActor in self.openTab(url, background: background) }
        return true
    }

    nonisolated func bridgeSaveToMio(kind: String, payload: [String: Any]) async -> [String: Any] {
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        let resultJSON = await saveJSON(kind: kind, payloadJSON: json)
        let obj = try? JSONSerialization.jsonObject(with: Data(resultJSON.utf8))
        return obj as? [String: Any] ?? ["ok": false, "code": "server", "message": "没有结果"]
    }

    nonisolated func bridgeRequestPermission(_ permission: MioBridgePermission, origin: MioFrameOrigin) async -> Bool {
        let title = "允许 \(origin.description) 使用「\(MioMacKit.permissionTitle(permission))」？"
        return await MainActor.run {
            self.ask(title: title, message: "只有 MioCore 页面能请求本机能力，其他网站拿不到。可以在设置 › 主页里撤销。")
        }
    }
}

// MARK: - MioUserScriptHost（GM API 的平台能力）

extension MioMacKit: MioUserScriptHost {
    nonisolated func userScriptOpenTab(_ url: URL, background: Bool) {
        Task { @MainActor in self.openTab(url, background: background) }
    }

    nonisolated func userScriptSetClipboard(_ text: String, html: Bool) {
        Task { @MainActor in
            let pb = NSPasteboard.general
            pb.clearContents()
            if html { pb.setString(text, forType: .html) }
            pb.setString(text, forType: .string)
        }
    }

    nonisolated func userScriptAskConnect(scriptName: String, host: String) async -> (allow: Bool, remember: Bool) {
        await MainActor.run { self.askConnect(scriptName: scriptName, host: host) }
    }

    nonisolated func userScriptNotification(title: String, text: String) {
        Task { @MainActor in self.toast(title.isEmpty ? text : "\(title)：\(text)") }
    }
}
