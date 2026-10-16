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
    static let taskID = "xyz.mio.app.adblock-refresh"

    /// 必须在 didFinishLaunching 结束前注册
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            handle(task)
        }
    }

    static func schedule() {
        let req = BGAppRefreshTaskRequest(identifier: taskID)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 6 * 3600)
        do {
            try BGTaskScheduler.shared.submit(req)
        } catch {
            NSLog("⚡️ Mio adblock BG schedule failed: %@", "\(error)")
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

final class MioBrowserViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, UITextFieldDelegate {
    private static weak var current: MioBrowserViewController?

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

    init(url: URL) {
        initialURL = url
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        observations.forEach { $0.invalidate() }
        if let o = changeObserver { NotificationCenter.default.removeObserver(o) }
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
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        config.applicationNameForUserAgent = "Version/\(major).0 Mobile/15E148 Safari/604.1"

        webView = WKWebView(frame: .zero, configuration: config)
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
        let safari = UIBarButtonItem(image: UIImage(systemName: "safari"), style: .plain, target: self, action: #selector(safariTapped))
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

    /// 后台播放：页面始终认为自己可见（YouTube 在 visibilitychange 时会暂停）
    private static func extraScripts() -> [WKUserScript] {
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
        UIApplication.shared.open(webView.url ?? initialURL)
    }

    @objc private func settingsTapped() {
        let nav = UINavigationController(rootViewController: MioBrowserSettingsViewController(currentHost: webView.url?.host))
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

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme != "http" && scheme != "https" && scheme != "about" && scheme != "blob" && scheme != "data" {
            // tel: mailto: itms-apps: 以及各种 App 链接交给系统
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        if navigationAction.targetFrame?.isMainFrame ?? true, scheme == "http" || scheme == "https" {
            adblock.prepareMainFrame(url)
            updateShield()
        }
        decisionHandler(.allow)
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
        case toggleAdblock, toggleSite(String), list(MioFilterList), scriptlets, lastCheck, updateNow, allowlistEntry(String), allowlistAdd, preferSafari, backgroundPlayback, licenses, version
    }

    private let currentHost: String?
    private var sections: [(title: String?, footer: String?, rows: [Row])] = []
    private var observer: NSObjectProtocol?
    private var updating = false

    init(currentHost: String?) {
        self.currentHost = currentHost
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

        s.append(("外链", "MioCore 里点外部链接默认在内置浏览器打开；打开后也可点工具栏的指南针图标改用 Safari。", [.preferSafari, .backgroundPlayback]))
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
