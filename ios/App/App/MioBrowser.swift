// MioBrowser.swift — App 内置浏览器（全屏 WKWebView）+ Capacitor 插件 MioBrowser（仅 iOS）+ 拦截设置页 + 后台规则刷新
//
// JS（MioCore 页面里）：
//   Capacitor.Plugins.MioBrowser.open({ url })            内置浏览器打开（设置了「默认用 Safari」则交给 Safari）
//   Capacitor.Plugins.MioBrowser.open({ url, mode: 'safari' | 'inapp' })
//   Capacitor.Plugins.MioBrowser.openSettings()
//   Capacitor.Plugins.MioBrowser.getInfo()              → { version, adblock, preferSafari, rulesUpdatedAt, scriptlets }

import UIKit
import WebKit
import AVFoundation
import BackgroundTasks
#if canImport(Capacitor) && !targetEnvironment(macCatalyst)
import Capacitor
#endif

// MARK: - Preferences

enum MioBrowserSettings {
    private static let preferSafariKey = "mio.browser.preferSafari"
    private static let backgroundPlaybackKey = "mio.browser.backgroundPlayback"

    /// 外链默认交给 Safari（关掉内置浏览器）
    static var preferSafari: Bool {
        get { UserDefaults.standard.bool(forKey: preferSafariKey) }
        set { UserDefaults.standard.set(newValue, forKey: preferSafariKey) }
    }

    /// 后台 / 锁屏继续播放（让页面以为自己一直在前台）
    static var backgroundPlayback: Bool {
        get { UserDefaults.standard.object(forKey: backgroundPlaybackKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: backgroundPlaybackKey) }
    }

    /// 内置浏览器专用的持久化数据（Cookie / 存储），与 MioCore 主界面的 WebView 分开
    static let dataStoreID = UUID(uuidString: "6D696F00-6272-6F77-7365-720000000001")!

    static var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}

// MARK: - WebKit 兼容（UA / 内容模式 / MediaSource），纯逻辑在 MioWebCompat.swift

enum MioWebKitCompat {
    /// Mac Catalyst，或「为 iPad 设计」的 iOS 包跑在 Apple 芯片 Mac 上
    static let isMac: Bool = {
        #if targetEnvironment(macCatalyst)
        return true
        #else
        return ProcessInfo.processInfo.isiOSAppOnMac
        #endif
    }()

    static var profile: MioBrowserProfile {
        MioWebCompat.profile(isMacCatalyst: isMac, isPad: UIDevice.current.userInterfaceIdiom == .pad)
    }

    /// 与本机系统 WebKit 对应的 Safari 版本号
    static let safariVersion: String = {
        let pv = ProcessInfo.processInfo.operatingSystemVersion
        if isMac {
            let plist = NSDictionary(contentsOfFile: "/System/Library/CoreServices/SystemVersion.plist") as? [String: Any]
            let v = MioWebCompat.macOSVersion(systemVersionPlist: plist, processVersion: (pv.majorVersion, pv.minorVersion))
            return MioWebCompat.safariVersion(macOSMajor: v.major, minor: v.minor)
        }
        // iPad：Safari 版本 = iPadOS 版本
        return "\(pv.majorVersion).\(pv.minorVersion)"
    }()

    static var desktopUserAgent: String { MioWebCompat.desktopUserAgent(safariVersion: safariVersion) }

    /// Mac 上确保 MediaSource（MSE）开启：没有 MSE 时 YouTube 只能给渐进式 mp4（最高 360p）。
    /// iPad 布局的 Catalyst 默认应已开启；这里用 WKPreferences 的私有开关兜底（先 responds(to:) 检查，ObjC 异常也接住）。
    /// 免签名包不经 App Review，私有开关只在 Mac 上设置，iPhone 不动。
    @discardableResult
    static func enableMediaSource(_ prefs: WKPreferences) -> [String: Bool] {
        var applied: [String: Bool] = [:]
        for (key, setter) in [("mediaSourceEnabled", "_setMediaSourceEnabled:"), ("managedMediaSourceEnabled", "_setManagedMediaSourceEnabled:")] {
            guard prefs.responds(to: NSSelectorFromString(setter)) else { applied[key] = false; continue }
            // KVC：key "mediaSourceEnabled" 会找到 _setMediaSourceEnabled:（set<Key>: 找不到时找 _set<Key>:）
            let exc = MioObjCSafe.catching { prefs.setValue(true, forKey: key) }
            applied[key] = exc == nil
            if let exc = exc { NSLog("⚡️ Mio browser: %@ threw %@", key, exc.reason ?? exc.name.rawValue) }
        }
        NSLog("⚡️ Mio browser MSE prefs: %@", "\(applied)")
        return applied
    }

    #if targetEnvironment(macCatalyst)
    /// 诊断：回车键冒泡到视图控制器 = 第一响应者（WKWebView）没有消费它
    static func logUnhandledReturn(_ presses: Set<UIPress>, in responder: UIResponder) {
        guard presses.contains(where: { $0.key?.keyCode == .keyboardReturnOrEnter || $0.key?.keyCode == .keypadEnter }) else { return }
        NSLog("⚡️ Mio: Return key reached %@ unhandled (first responder: WKWebView did not consume it)", String(describing: type(of: responder)))
    }
    #endif
}

// MARK: - Capacitor plugin（iOS；Mac Catalyst 由 MioDesktop.swift 的 window.MioDesktop.browser 提供同样的接口）

#if canImport(Capacitor) && !targetEnvironment(macCatalyst)

@objc(MioBrowserPlugin)
public class MioBrowserPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "MioBrowserPlugin"
    public let jsName = "MioBrowser"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "open", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "openSettings", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getInfo", returnType: CAPPluginReturnPromise),
    ]

    @objc func open(_ call: CAPPluginCall) {
        guard let raw = call.getString("url"), let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            call.reject("invalid url")
            return
        }
        let mode = call.getString("mode") ?? "auto"
        DispatchQueue.main.async {
            if mode == "safari" || (mode == "auto" && MioBrowserSettings.preferSafari) {
                UIApplication.shared.open(url)
                call.resolve(["opened": "safari"])
                return
            }
            MioBrowserViewController.open(url, from: self.bridge?.viewController)
            call.resolve(["opened": "inapp"])
        }
    }

    @objc func openSettings(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard let presenter = MioBrowserViewController.topPresenter(self.bridge?.viewController) else {
                call.reject("no view controller")
                return
            }
            let nav = UINavigationController(rootViewController: MioBrowserSettingsViewController(currentHost: nil))
            presenter.present(nav, animated: true)
            call.resolve()
        }
    }

    @objc func getInfo(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            let snap = MioAdblock.shared.snapshot
            var info: [String: Any] = [
                "version": MioBrowserSettings.appVersion,
                "adblock": MioAdblockSettings.enabled,
                "preferSafari": MioBrowserSettings.preferSafari,
                "ruleLists": snap.ruleListCount,
            ]
            if let d = snap.state.lastCheck { info["rulesCheckedAt"] = ISO8601DateFormatter().string(from: d) }
            if let s = snap.state.scriptlets { info["scriptlets"] = s.version }
            call.resolve(info)
        }
    }
}
#endif

// MARK: - Background refresh (BGAppRefreshTask)

enum MioAdblockBackground {
    /// 任务名后缀；完整 identifier 从 Info.plist 的 BGTaskSchedulerPermittedIdentifiers 里找，不在代码里写死。
    /// 侧载工具（iloader / isideload、SideStore…）会把 CFBundleIdentifier 改成 xyz.mio.app.<TEAMID>，
    /// 但不改 BGTaskSchedulerPermittedIdentifiers；identifier 和 plist / bundle id 对不上时
    /// BGTaskScheduler.register 抛 NSInternalInconsistencyException → 启动即闪退（v0.2.0 / v0.3.0）。
    static let taskSuffix = "adblock-refresh"

    /// 实际注册成功的 identifier；nil = 后台刷新不可用（降级为前台超过 24h 检查更新）
    private(set) static var registeredID: String?
    private static var attempted = false

    /// 候选：Info.plist 里声明的、以 adblock-refresh 结尾的 identifier；优先「当前 bundle id + 后缀」
    static func candidateIDs(permitted: [String], bundleID: String?) -> [String] {
        let matching = permitted.filter { $0.hasSuffix("." + taskSuffix) }
        guard let bid = bundleID, !bid.isEmpty else { return matching }
        let preferred = "\(bid).\(taskSuffix)"
        return matching.sorted { a, b in (a == preferred ? 0 : 1) < (b == preferred ? 0 : 1) }
    }

    /// 必须在 didFinishLaunching 结束前调用。任何失败都只记录日志，不影响启动。
    static func register() {
        guard !attempted else { return }
        attempted = true
        let info = Bundle.main.infoDictionary ?? [:]
        let permitted = info["BGTaskSchedulerPermittedIdentifiers"] as? [String] ?? []
        let modes = info["UIBackgroundModes"] as? [String] ?? []
        guard modes.contains("fetch") || modes.contains("processing") else {
            NSLog("⚡️ Mio adblock BG: UIBackgroundModes 没有 fetch，跳过后台刷新")
            return
        }
        for id in candidateIDs(permitted: permitted, bundleID: Bundle.main.bundleIdentifier) {
            var ok = false
            let exc = MioObjCSafe.catching {
                ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) { task in
                    guard let task = task as? BGAppRefreshTask else {
                        task.setTaskCompleted(success: false)
                        return
                    }
                    handle(task)
                }
            }
            if let exc = exc {
                NSLog("⚡️ Mio adblock BG register %@ threw %@: %@", id, exc.name.rawValue, exc.reason ?? "")
                continue
            }
            if ok {
                registeredID = id
                NSLog("⚡️ Mio adblock BG registered %@", id)
                return
            }
            NSLog("⚡️ Mio adblock BG register %@ returned false", id)
        }
        NSLog("⚡️ Mio adblock BG: 没有可用的 identifier（permitted=%@, bundle=%@），只在前台检查更新",
              permitted.joined(separator: ","), Bundle.main.bundleIdentifier ?? "?")
    }

    static func schedule() {
        guard let id = registeredID else { return }
        let req = BGAppRefreshTaskRequest(identifier: id)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 6 * 3600)
        var submitError: Error?
        let exc = MioObjCSafe.catching {
            do {
                try BGTaskScheduler.shared.submit(req)
            } catch {
                submitError = error
            }
        }
        if let exc = exc {
            NSLog("⚡️ Mio adblock BG schedule threw %@: %@", exc.name.rawValue, exc.reason ?? "")
        } else if let e = submitError {
            NSLog("⚡️ Mio adblock BG schedule failed: %@", "\(e)")
        }
    }

    private static func handle(_ task: BGAppRefreshTask) {
        schedule()
        task.expirationHandler = { MioAdblock.shared.cancelWork() }
        MioAdblock.shared.checkForUpdates(force: false) { ok, msg in
            NSLog("⚡️ Mio adblock BG refresh: %@", msg)
            task.setTaskCompleted(success: ok)
        }
    }
}

// MARK: - Browser view controller

final class MioBrowserViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, UITextFieldDelegate {
    private static weak var current: MioBrowserViewController?
    /// 最近一次 YouTube 页面的媒体诊断（UA / MediaSource / 清晰度），Mac 冒烟测试读取
    static var lastMediaProbe: String?
    private static let passkeyMessage = "mioPasskey"

    /// 已打开就在当前浏览器里加载，否则全屏弹出
    static func open(_ url: URL, from base: UIViewController?) {
        if let vc = current, vc.presentingViewController != nil {
            vc.load(url)
            return
        }
        guard let presenter = topPresenter(base) else { return }
        let vc = MioBrowserViewController(url: url)
        vc.modalPresentationStyle = .fullScreen
        presenter.present(vc, animated: true)
        current = vc
    }

    static func topPresenter(_ base: UIViewController?) -> UIViewController? {
        var top = base ?? UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.windows.first(where: { $0.isKeyWindow })?.rootViewController }
            .first
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    private let initialURL: URL
    private var webView: WKWebView!
    private var adblock: MioAdblockSession!
    private let topBar = UIView()
    private let addressField = UITextField()
    private let shieldButton = UIButton(type: .system)
    private let progress = UIProgressView(progressViewStyle: .bar)
    private let toolbar = UIToolbar()
    private var backItem: UIBarButtonItem!
    private var forwardItem: UIBarButtonItem!
    private var reloadItem: UIBarButtonItem!
    private var observations: [NSKeyValueObservation] = []
    private var changeObserver: NSObjectProtocol?
    private let profile = MioWebKitCompat.profile
    /// 桌面模式下 m.youtube.com → www 的改写记录（防止站点来回重定向时死循环）
    private var desktopRewrites: [Date] = []
    private var passkeyHintedHosts: Set<String> = []

    init(url: URL) {
        initialURL = url
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        observations.forEach { $0.invalidate() }
        if let o = changeObserver { NotificationCenter.default.removeObserver(o) }
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.passkeyMessage)
        adblock?.detach()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .default }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let config = WKWebViewConfiguration()
        if #available(iOS 17.0, macCatalyst 17.0, *) {
            config.websiteDataStore = WKWebsiteDataStore(forIdentifier: MioBrowserSettings.dataStoreID)
        } else {
            config.websiteDataStore = .default()
        }
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = true
        // 不带 Safari 标识时 Google 登录会拒绝（disallowed_useragent），YouTube 也会给降级页面
        switch profile {
        case .mobile:
            // iPhone：保持原来的手机 UA
            let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
            config.applicationNameForUserAgent = MioWebCompat.mobileApplicationName(iOSMajor: major)
        case .desktop:
            // Mac / iPad：与系统 Safari 桌面版一致。以前 Mac 上也带 "Mobile/15E148"，YouTube 当成 iPhone →
            // m.youtube.com + 只给渐进式 mp4（360p）。customUserAgent 在下面 WKWebView 建好后设置。
            config.applicationNameForUserAgent = MioWebCompat.desktopApplicationName(safariVersion: MioWebKitCompat.safariVersion)
            config.defaultWebpagePreferences.preferredContentMode = .desktop
            if MioWebKitCompat.isMac {
                MioWebKitCompat.enableMediaSource(config.preferences)
            }
        }
        config.userContentController.add(MioWeakScriptHandler(self), name: Self.passkeyMessage)

        webView = WKWebView(frame: .zero, configuration: config)
        if profile == .desktop {
            webView.customUserAgent = MioWebKitCompat.desktopUserAgent
        }
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.backgroundColor = .systemBackground
        if #available(iOS 16.4, macCatalyst 16.4, *) { webView.isInspectable = true }

        adblock = MioAdblockSession(configuration: config)
        adblock.webView = webView
        adblock.extraScripts = Self.extraScripts()

        buildLayout()
        observe()
        activateAudioSession()

        changeObserver = NotificationCenter.default.addObserver(forName: .mioAdblockDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.updateShield()
        }
        load(initialURL)
    }

    // MARK: layout

    private func buildLayout() {
        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.backgroundColor = .secondarySystemBackground
        view.addSubview(topBar)

        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark"), for: .normal)
        close.accessibilityLabel = "关闭"
        close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        addressField.borderStyle = .none
        addressField.backgroundColor = .tertiarySystemBackground
        addressField.layer.cornerRadius = 10
        addressField.font = .systemFont(ofSize: 15)
        addressField.textAlignment = .center
        addressField.keyboardType = .webSearch
        addressField.autocapitalizationType = .none
        addressField.autocorrectionType = .no
        addressField.returnKeyType = .go
        addressField.clearButtonMode = .whileEditing
        addressField.delegate = self
        addressField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        addressField.leftViewMode = .always

        shieldButton.addTarget(self, action: #selector(shieldTapped), for: .touchUpInside)
        shieldButton.accessibilityLabel = "广告拦截"

        let row = UIStackView(arrangedSubviews: [close, addressField, shieldButton])
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(row)

        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.trackTintColor = .clear
        topBar.addSubview(progress)

        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)

        toolbar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toolbar)

        backItem = UIBarButtonItem(image: UIImage(systemName: "chevron.backward"), style: .plain, target: self, action: #selector(backTapped))
        forwardItem = UIBarButtonItem(image: UIImage(systemName: "chevron.forward"), style: .plain, target: self, action: #selector(forwardTapped))
        reloadItem = UIBarButtonItem(image: UIImage(systemName: "arrow.clockwise"), style: .plain, target: self, action: #selector(reloadTapped))
        let share = UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.up"), style: .plain, target: self, action: #selector(shareTapped))
        #if targetEnvironment(macCatalyst)
        // Mac：文字按钮更显眼（通行密钥 / 钥匙串登录要去 Safari），快捷键 ⌘⇧O
        let safari = UIBarButtonItem(title: "用 Safari 打开 ⌘⇧O", style: .plain, target: self, action: #selector(safariTapped))
        #else
        let safari = UIBarButtonItem(image: UIImage(systemName: "safari"), style: .plain, target: self, action: #selector(safariTapped))
        #endif
        safari.accessibilityLabel = "用 Safari 打开"
        let settings = UIBarButtonItem(image: UIImage(systemName: "gearshape"), style: .plain, target: self, action: #selector(settingsTapped))
        settings.accessibilityLabel = "浏览器设置"
        let flex = { UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil) }
        toolbar.items = [backItem, flex(), forwardItem, flex(), reloadItem, flex(), share, flex(), safari, flex(), settings]

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            row.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            row.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            row.bottomAnchor.constraint(equalTo: topBar.bottomAnchor, constant: -8),
            addressField.heightAnchor.constraint(equalToConstant: 36),
            close.widthAnchor.constraint(equalToConstant: 32),
            shieldButton.widthAnchor.constraint(equalToConstant: 32),

            progress.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),
            progress.bottomAnchor.constraint(equalTo: topBar.bottomAnchor),
            progress.heightAnchor.constraint(equalToConstant: 2),

            webView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: toolbar.topAnchor),

            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
        updateShield()
        updateButtons()
    }

    private func observe() {
        observations = [
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
                guard let self = self else { return }
                self.progress.setProgress(Float(wv.estimatedProgress), animated: true)
                self.progress.isHidden = wv.estimatedProgress >= 1
            },
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in self?.updateAddress(); self?.updateShield() },
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in self?.updateAddress() },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in self?.updateButtons() },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in self?.updateButtons() },
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in self?.updateButtons() },
        ]
    }

    private func updateAddress() {
        guard !addressField.isFirstResponder else { return }
        let host = webView.url?.host ?? initialURL.host ?? ""
        let title = webView.title ?? ""
        addressField.text = title.isEmpty ? host : "\(title) — \(host)"
    }

    private func updateButtons() {
        backItem?.isEnabled = webView.canGoBack
        forwardItem?.isEnabled = webView.canGoForward
        reloadItem?.image = UIImage(systemName: webView.isLoading ? "xmark" : "arrow.clockwise")
    }

    private func updateShield() {
        let host = webView?.url?.host ?? initialURL.host
        let on = MioAdblockSettings.enabled && !MioAdblockSettings.isAllowlisted(host)
        shieldButton.setImage(UIImage(systemName: on ? "shield.lefthalf.filled" : "shield.slash"), for: .normal)
        shieldButton.tintColor = on ? .systemGreen : .secondaryLabel
    }

    // MARK: loading

    func load(_ url: URL) {
        loadViewIfNeeded()
        // 规则还在首次编译时最多等 4 秒，避免第一次打开 YouTube 就漏掉
        waitForRules(deadline: Date().addingTimeInterval(4)) { [weak self] in
            self?.webView.load(URLRequest(url: url))
        }
    }

    private func waitForRules(deadline: Date, then: @escaping () -> Void) {
        if MioAdblock.shared.snapshot.ready || !MioAdblockSettings.enabled || Date() > deadline {
            then()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.waitForRules(deadline: deadline, then: then)
        }
    }

    private func activateAudioSession() {
        guard MioBrowserSettings.backgroundPlayback else { return }
        do {
            // 只设类别不主动激活：网页真正开始播放时 WebKit 才激活会话（不会一打开浏览器就打断其他 App 的音乐）。
            // .playback + UIBackgroundModes audio → 切到后台 / 锁屏后继续出声，锁屏和控制中心显示正在播放
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
        } catch {
            NSLog("⚡️ Mio browser audio session: %@", "\(error)")
        }
    }

    /// 内置浏览器额外的用户脚本（MioAdblockSession 重建脚本时会一起加回去）
    private static func extraScripts() -> [WKUserScript] {
        var scripts: [WKUserScript] = [
            // 第三方站点的通行密钥用不了时提示改用 Safari（不绕过系统限制）
            WKUserScript(source: MioWebCompat.passkeyHintScript, injectionTime: .atDocumentStart, forMainFrameOnly: true),
        ]
        if MioWebKitCompat.isMac {
            // Mac：textarea / contenteditable 回车不换行的兜底（所有 frame，评论框常在 iframe 里）
            scripts.append(WKUserScript(source: MioWebCompat.returnKeyFixScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        return scripts + backgroundPlaybackScripts()
    }

    /// 后台播放：页面始终认为自己可见（YouTube 在 visibilitychange 时会暂停）
    private static func backgroundPlaybackScripts() -> [WKUserScript] {
        guard MioBrowserSettings.backgroundPlayback else { return [] }
        let js = """
        (function(){try{
        Object.defineProperty(document,'hidden',{configurable:true,get:function(){return false;}});
        Object.defineProperty(document,'visibilityState',{configurable:true,get:function(){return 'visible';}});
        Object.defineProperty(document,'webkitHidden',{configurable:true,get:function(){return false;}});
        Object.defineProperty(document,'webkitVisibilityState',{configurable:true,get:function(){return 'visible';}});
        var stop=function(e){e.stopImmediatePropagation();};
        document.addEventListener('visibilitychange',stop,true);
        document.addEventListener('webkitvisibilitychange',stop,true);
        }catch(e){}})();
        """
        return [WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true)]
    }

    // MARK: actions

    @objc private func closeTapped() {
        webView.stopLoading()
        dismiss(animated: true)
    }

    @objc private func backTapped() { webView.goBack() }
    @objc private func forwardTapped() { webView.goForward() }

    @objc private func reloadTapped() {
        if webView.isLoading { webView.stopLoading() } else if webView.url != nil { webView.reload() } else { load(initialURL) }
    }

    @objc private func shareTapped() {
        guard let url = webView.url else { return }
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let pop = vc.popoverPresentationController {
            pop.barButtonItem = toolbar.items?[6]
        }
        present(vc, animated: true)
    }

    @objc private func safariTapped() {
        openInSafari()
    }

    /// 当前页面交给 Safari（通行密钥 / iCloud 钥匙串只能在 Safari 里用）
    func openInSafari() {
        var url = webView.url ?? initialURL
        if let s = url.scheme?.lowercased(), s != "http" && s != "https" { url = initialURL }   // 错误页（about:blank）
        UIApplication.shared.open(url)
    }

    /// 菜单「浏览器 › 用 Safari 打开」（⌘⇧O，Mac 菜单栏 / AppDelegate.buildMenu）和 iPad 键盘快捷键
    @objc func mioOpenInSafari(_ sender: Any?) {
        openInSafari()
    }

    @objc private func focusAddress() {
        addressField.becomeFirstResponder()
    }

    override var keyCommands: [UIKeyCommand]? {
        var commands = [
            UIKeyCommand(title: "刷新", action: #selector(reloadTapped), input: "r", modifierFlags: .command),
            UIKeyCommand(title: "后退", action: #selector(backTapped), input: "[", modifierFlags: .command),
            UIKeyCommand(title: "前进", action: #selector(forwardTapped), input: "]", modifierFlags: .command),
            UIKeyCommand(title: "打开位置…", action: #selector(focusAddress), input: "l", modifierFlags: .command),
        ]
        #if !targetEnvironment(macCatalyst)
        // Mac 上这一项在菜单栏里（同一快捷键不能既在菜单又在 keyCommands）
        commands.append(UIKeyCommand(title: "用 Safari 打开", action: #selector(mioOpenInSafari(_:)), input: "o", modifierFlags: [.command, .shift]))
        #endif
        return commands
    }

    #if targetEnvironment(macCatalyst)
    /// 诊断：回车键一路冒泡到这里说明 WKWebView 没有消费它（页面里回车不换行时看日志）
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        MioWebKitCompat.logUnhandledReturn(presses, in: self)
        super.pressesBegan(presses, with: event)
    }
    #endif

    @objc private func settingsTapped() {
        let nav = UINavigationController(rootViewController: MioBrowserSettingsViewController(currentHost: webView.url?.host, currentURL: webView.url))
        present(nav, animated: true)
    }

    @objc private func shieldTapped() {
        let host = webView.url?.host
        let alert = UIAlertController(title: host ?? "广告拦截", message: nil, preferredStyle: .actionSheet)
        if !MioAdblockSettings.enabled {
            alert.message = "广告拦截已关闭"
            alert.addAction(UIAlertAction(title: "开启广告拦截", style: .default) { [weak self] _ in
                MioAdblockSettings.enabled = true
                self?.webView.reload()
            })
        } else if let host = host {
            if MioAdblockSettings.isAllowlisted(host) {
                alert.message = "此站点在白名单中，不拦截"
                alert.addAction(UIAlertAction(title: "恢复拦截此站点", style: .default) { [weak self] _ in
                    MioAdblockSettings.setAllowlisted(host, false)
                    self?.webView.reload()
                })
            } else {
                alert.message = "正在拦截广告和跟踪器"
                alert.addAction(UIAlertAction(title: "此站点不拦截（加入白名单）", style: .default) { [weak self] _ in
                    MioAdblockSettings.setAllowlisted(host, true)
                    self?.webView.reload()
                })
            }
        }
        alert.addAction(UIAlertAction(title: "拦截设置…", style: .default) { [weak self] _ in self?.settingsTapped() })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let pop = alert.popoverPresentationController {
            pop.sourceView = shieldButton
            pop.sourceRect = shieldButton.bounds
        }
        present(alert, animated: true)
    }

    // MARK: address field

    func textFieldDidBeginEditing(_ textField: UITextField) {
        textField.textAlignment = .left
        textField.text = webView.url?.absoluteString ?? initialURL.absoluteString
        DispatchQueue.main.async { textField.selectAll(nil) }
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        textField.textAlignment = .center
        updateAddress()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        let text = (textField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        textField.resignFirstResponder()
        guard !text.isEmpty else { return true }
        if let url = Self.url(fromInput: text) { load(url) }
        return true
    }

    static func url(fromInput text: String) -> URL? {
        if let u = URL(string: text), let s = u.scheme?.lowercased(), s == "http" || s == "https", u.host != nil { return u }
        if !text.contains(" "), text.contains("."), let u = URL(string: "https://" + text), u.host != nil { return u }
        var comps = URLComponents(string: "https://www.google.com/search")!
        comps.queryItems = [URLQueryItem(name: "q", value: text)]
        return comps.url
    }

    // MARK: WKNavigationDelegate

    // 带 preferences 的版本：WebKit 实现了它就不再调用旧的 decidePolicyFor(_:decisionHandler:)
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences, decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        let isMain = navigationAction.targetFrame?.isMainFrame ?? true
        if profile == .desktop, isMain {
            // 每次主框架导航（包括服务端重定向）都按桌面版请求，与 Safari 桌面版一致；内容模式只对主框架有意义，子框架不动
            preferences.preferredContentMode = .desktop
        }
        guard let url = navigationAction.request.url else { decisionHandler(.cancel, preferences); return }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme != "http" && scheme != "https" && scheme != "about" && scheme != "blob" && scheme != "data" {
            // tel: mailto: itms-apps: 以及各种 App 链接交给系统
            UIApplication.shared.open(url)
            decisionHandler(.cancel, preferences)
            return
        }
        if isMain, profile == .desktop, let desktop = MioWebCompat.desktopURL(for: url), allowDesktopRewrite() {
            // m.youtube.com → www.youtube.com（旧链接 / 历史记录 / 旧 Cookie 触发的重定向）
            decisionHandler(.cancel, preferences)
            DispatchQueue.main.async { [weak self] in self?.webView.load(URLRequest(url: desktop)) }
            return
        }
        if isMain, scheme == "http" || scheme == "https" {
            adblock.prepareMainFrame(url)
            updateShield()
        }
        decisionHandler(.allow, preferences)
    }

    /// 10 秒内最多改写 3 次：站点坚持把桌面版重定向回手机版时不跟它打架
    private func allowDesktopRewrite() -> Bool {
        let now = Date()
        desktopRewrites = desktopRewrites.filter { now.timeIntervalSince($0) < 10 }
        guard desktopRewrites.count < 3 else { return false }
        desktopRewrites.append(now)
        return true
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        if let url = webView.url { adblock.prepareMainFrame(url) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showError(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showError(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 诊断：YouTube 上记录 UA / MediaSource / 播放器拿到的最高清晰度（Mac 或 Debug）
        guard let host = webView.url?.host?.lowercased(), host == "youtube.com" || host.hasSuffix(".youtube.com") else { return }
        #if !DEBUG
        guard MioWebKitCompat.isMac else { return }
        #endif
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak webView] in
            webView?.evaluateJavaScript(MioWebCompat.mediaProbeScript) { result, error in
                let s = (result as? String) ?? "error: \(String(describing: error))"
                MioBrowserViewController.lastMediaProbe = s
                NSLog("⚡️ Mio browser media probe: %@", s)
            }
        }
    }

    // MARK: WKScriptMessageHandler（通行密钥提示）

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.passkeyMessage, message.frameInfo.isMainFrame else { return }
        let host = webView.url?.host ?? (message.body as? [String: Any])?["host"] as? String ?? ""
        guard !passkeyHintedHosts.contains(host) else { return }
        passkeyHintedHosts.insert(host)
        NSLog("⚡️ Mio browser: WebAuthn failed on %@ (%@)", host, "\(message.body)")
        let a = UIAlertController(
            title: "请在 Safari 中使用通行密钥",
            message: "\(host.isEmpty ? "此网站" : host) 想用通行密钥（Passkey）或 iCloud 钥匙串登录。Mio 不是经 App Store 签名分发的 App，系统不允许它使用这些功能（需要 Apple 审批的浏览器权限）。用 Safari 打开此页面即可正常登录。",
            preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        a.addAction(UIAlertAction(title: "用 Safari 打开", style: .default) { [weak self] _ in self?.openInSafari() })
        presentPanel(a, fallback: {})
    }

    private func showError(_ error: Error) {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && (ns.code == 102 || ns.code == 101 || ns.code == 204) { return }
        let failing = (ns.userInfo[NSURLErrorFailingURLStringErrorKey] as? String) ?? ""
        let esc = { (s: String) in
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="color-scheme" content="light dark"><style>body{font-family:-apple-system;padding:48px 24px;color:#1f2937}
        @media (prefers-color-scheme: dark){body{color:#e5e7eb;background:#000}}code{font-size:12px;color:#6b7280;word-break:break-all}
        a{display:inline-block;margin-top:16px;padding:10px 20px;background:#f0a3bf;color:#fff;border-radius:10px;text-decoration:none}</style></head>
        <body><h3>无法打开网页</h3><p>\(esc(ns.localizedDescription))</p><p><code>\(esc(ns.domain)) \(ns.code)<br>\(esc(failing))</code></p>
        \(failing.isEmpty ? "" : "<a href=\"\(esc(failing))\">重试</a>")</body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    // MARK: WKUIDelegate

    /// target=_blank / window.open：在当前浏览器里打开
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = UIAlertController(title: frame.request.url?.host, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
        presentPanel(a, fallback: completionHandler)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: frame.request.url?.host, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler(true) })
        presentPanel(a) { completionHandler(false) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let a = UIAlertController(title: frame.request.url?.host, message: prompt, preferredStyle: .alert)
        a.addTextField { $0.text = defaultText }
        a.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(nil) })
        a.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler(a.textFields?.first?.text) })
        presentPanel(a) { completionHandler(nil) }
    }

    private func presentPanel(_ alert: UIAlertController, fallback: @escaping () -> Void) {
        guard presentedViewController == nil, view.window != nil else { fallback(); return }
        present(alert, animated: true)
    }

    func webViewDidClose(_ webView: WKWebView) {
        dismiss(animated: true)
    }
}

// MARK: - Settings

final class MioBrowserSettingsViewController: UITableViewController {
    private enum Row {
        case toggleAdblock, toggleSite(String), list(MioFilterList), scriptlets, lastCheck, updateNow, allowlistEntry(String), allowlistAdd, preferSafari, backgroundPlayback, passkeyInfo, openInSafari(URL), licenses, version
    }

    private let currentHost: String?
    private let currentURL: URL?
    private var sections: [(title: String?, footer: String?, rows: [Row])] = []
    private var observer: NSObjectProtocol?
    private var updating = false

    init(currentHost: String?, currentURL: URL? = nil) {
        self.currentHost = currentHost
        if let u = currentURL, let s = u.scheme?.lowercased(), s == "http" || s == "https" {
            self.currentURL = u
        } else {
            self.currentURL = nil
        }
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let o = observer { NotificationCenter.default.removeObserver(o) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "浏览器与广告拦截"
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(doneTapped))
        observer = NotificationCenter.default.addObserver(forName: .mioAdblockDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.rebuild()
        }
        rebuild()
    }

    @objc private func doneTapped() { dismiss(animated: true) }

    private func rebuild() {
        let snap = MioAdblock.shared.snapshot
        var s: [(String?, String?, [Row])] = []
        var first: [Row] = [.toggleAdblock]
        if let host = currentHost { first.append(.toggleSite(host)) }
        s.append((nil, "拦截基于 AdGuard 开源组件：网络与元素隐藏规则编译为 WebKit 内容拦截列表，脚本类规则（Scriptlets）在页面最早时刻注入。", first))

        var rules: [Row] = MioFilterCatalog.lists.map { .list($0) }
        rules.append(.scriptlets)
        let busy = snap.busy.map { "当前：\($0)。" } ?? ""
        s.append(("过滤规则", "\(busy)已加载 \(snap.ruleListCount) 个内容拦截列表。启动时和后台刷新时超过 24 小时自动从 AdGuard 官方源检查更新（ETag / If-Modified-Since），失败时继续用已有规则或 App 内置版本。", rules))
        s.append((nil, nil, [.lastCheck, .updateNow]))

        var allow: [Row] = MioAdblockSettings.allowlist.map { .allowlistEntry($0) }
        allow.append(.allowlistAdd)
        s.append(("白名单（不拦截的网站）", "包含其所有子域名。左滑删除。", allow))

        s.append(("外链", "MioCore 里点外部链接默认在内置浏览器打开；打开后也可点工具栏的「用 Safari 打开」（\(Self.safariHint)）改用 Safari。", [.preferSafari, .backgroundPlayback]))
        var login: [Row] = [.passkeyInfo]
        if let u = currentURL { login.append(.openInSafari(u)) }
        s.append(("通行密钥与钥匙串", Self.passkeyFooter, login))
        s.append((nil, nil, [.licenses, .version]))
        sections = s.map { (title: $0.0, footer: $0.1, rows: $0.2) }
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].rows.count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { sections[section].title }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? { sections[section].footer }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private func fmt(_ d: Date?) -> String { d.map { Self.dateFormatter.string(from: $0) } ?? "—" }

    #if targetEnvironment(macCatalyst)
    static let safariHint = "菜单「浏览器 › 用 Safari 打开」或 ⌘⇧O"
    #else
    static let safariHint = "指南针图标，外接键盘 ⌘⇧O"
    #endif

    /// 为什么内置浏览器里用不了通行密钥 / iCloud 钥匙串（不尝试绕过）
    static let passkeyFooter = "第三方网站的通行密钥（Passkey）和 iCloud 钥匙串自动填充，系统只开放给获得 Apple 审批的浏览器权限、并经 App Store 签名分发的 App。Mio 是免签名安装包，拿不到这项权限，所以内置浏览器里无法使用它们——这不是设置问题，也无法绕过。需要这样登录的网站请用 Safari 打开（\(safariHint)）；网页调用通行密钥失败时 Mio 也会提示。"

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.selectionStyle = .none
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.detailTextLabel?.numberOfLines = 0
        let snap = MioAdblock.shared.snapshot
        switch sections[indexPath.section].rows[indexPath.row] {
        case .toggleAdblock:
            cell.textLabel?.text = "拦截广告和跟踪器"
            cell.accessoryView = makeSwitch(MioAdblockSettings.enabled) { MioAdblockSettings.enabled = $0 }
        case .toggleSite(let host):
            cell.textLabel?.text = "在 \(host) 上拦截"
            cell.detailTextLabel?.text = MioAdblockSettings.allowlistEntry(for: host).map { "白名单：\($0)" }
            cell.accessoryView = makeSwitch(!MioAdblockSettings.isAllowlisted(host)) { MioAdblockSettings.setAllowlisted(host, !$0) }
        case .list(let list):
            let m = snap.state.lists[list.key]
            cell.textLabel?.text = list.name
            var parts: [String] = []
            if let m = m {
                if m.safariRules > 0 { parts.append("\(m.safariRules) 条拦截 + \(m.advancedRules) 条高级") }
                if let v = m.version { parts.append("v\(v)") }
                if list.remote {
                    parts.append(m.source == "remote" ? "下载于 \(fmt(m.fetchedAt))" : "App 内置版")
                } else {
                    parts.append("App 内置")
                }
                if m.parts > 1 { parts.append("拆分为 \(m.parts) 个列表") }
                if m.discarded > 0 { parts.append("超限丢弃 \(m.discarded)") }
                if let e = m.error { parts.append("⚠️ \(e)") }
            } else {
                parts.append("未加载")
            }
            cell.detailTextLabel?.text = parts.joined(separator: " · ")
        case .scriptlets:
            cell.textLabel?.text = "AdGuard Scriptlets"
            if let sm = snap.state.scriptlets {
                cell.detailTextLabel?.text = "v\(sm.version) · " + (sm.source == "remote" ? "远程更新于 \(fmt(sm.fetchedAt))（SHA-256 已校验）" : "App 内置版")
            } else {
                cell.detailTextLabel?.text = "未加载"
            }
        case .lastCheck:
            cell.textLabel?.text = "上次检查"
            var d = fmt(snap.state.lastCheck)
            if let msg = snap.state.lastCheckMessage { d += "\n" + msg }
            if let c = snap.state.compiledAt { d += "\n编译于 \(fmt(c))" }
            cell.detailTextLabel?.text = d
        case .updateNow:
            cell.textLabel?.text = updating || snap.busy != nil ? "更新中…" : "立即更新规则"
            cell.textLabel?.textColor = .systemBlue
            cell.selectionStyle = .default
        case .allowlistEntry(let host):
            cell.textLabel?.text = host
        case .allowlistAdd:
            cell.textLabel?.text = "添加网站…"
            cell.textLabel?.textColor = .systemBlue
            cell.selectionStyle = .default
        case .preferSafari:
            cell.textLabel?.text = "外链默认用 Safari 打开"
            cell.accessoryView = makeSwitch(MioBrowserSettings.preferSafari) { MioBrowserSettings.preferSafari = $0 }
        case .backgroundPlayback:
            cell.textLabel?.text = "后台 / 锁屏继续播放"
            cell.detailTextLabel?.text = "对之后打开的页面生效"
            cell.accessoryView = makeSwitch(MioBrowserSettings.backgroundPlayback) { MioBrowserSettings.backgroundPlayback = $0 }
        case .passkeyInfo:
            cell.textLabel?.text = "内置浏览器不支持通行密钥 / 钥匙串自动填充"
            cell.detailTextLabel?.text = "账号密码可手动输入；通行密钥登录请用 Safari"
        case .openInSafari(let url):
            cell.textLabel?.text = "用 Safari 打开当前网页"
            cell.textLabel?.textColor = .systemBlue
            cell.detailTextLabel?.text = url.host
            cell.selectionStyle = .default
        case .licenses:
            cell.textLabel?.text = "开源许可"
            cell.detailTextLabel?.text = "SafariConverterLib、AdGuard Scriptlets、ExtendedCss（GPL-3.0）；过滤列表：AdGuard（CC BY-SA 3.0 / GPL-3.0）、EasyList / EasyPrivacy（GPL-3.0 / CC BY-SA 3.0）。详见仓库 NOTICE。"
        case .version:
            cell.textLabel?.text = "Mio"
            cell.detailTextLabel?.text = MioBrowserSettings.appVersion
        }
        return cell
    }

    private func makeSwitch(_ on: Bool, _ change: @escaping (Bool) -> Void) -> UISwitch {
        let sw = UISwitch()
        sw.isOn = on
        sw.addAction(UIAction { action in
            if let s = action.sender as? UISwitch { change(s.isOn) }
        }, for: .valueChanged)
        return sw
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section].rows[indexPath.row] {
        case .updateNow:
            guard !updating else { return }
            updating = true
            rebuild()
            MioAdblock.shared.checkForUpdates(force: true) { [weak self] ok, msg in
                self?.updating = false
                self?.rebuild()
                let a = UIAlertController(title: ok ? "更新完成" : "更新未完成", message: msg, preferredStyle: .alert)
                a.addAction(UIAlertAction(title: "好", style: .default))
                self?.present(a, animated: true)
            }
        case .allowlistAdd:
            let a = UIAlertController(title: "添加到白名单", message: "输入域名，例如 example.com", preferredStyle: .alert)
            a.addTextField {
                $0.keyboardType = .URL
                $0.autocapitalizationType = .none
                $0.autocorrectionType = .no
                $0.text = self.currentHost.map { MioAdblockSettings.normalize($0) }
            }
            a.addAction(UIAlertAction(title: "取消", style: .cancel))
            a.addAction(UIAlertAction(title: "添加", style: .default) { _ in
                if let t = a.textFields?.first?.text, !t.isEmpty { MioAdblockSettings.setAllowlisted(t, true) }
            })
            present(a, animated: true)
        case .openInSafari(let url):
            UIApplication.shared.open(url)
        default:
            break
        }
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        if case .allowlistEntry = sections[indexPath.section].rows[indexPath.row] { return true }
        return false
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete, case .allowlistEntry(let host) = sections[indexPath.section].rows[indexPath.row] else { return }
        MioAdblockSettings.allowlist = MioAdblockSettings.allowlist.filter { $0 != host }
    }
}
