// MioPageTools.swift — 内置浏览器：阅读模式、强制深色、存到 Mio（iOS / Mac Catalyst）
//
// 挂在 MioBrowserViewController 上（只有几处挂钩：创建、用户脚本、工具栏按钮、地址栏按钮、主框架导航、didFinish）。
// 页面里的 JS 是 www/mio-browser/{reader,dark,mio-save}.js（App 包 public/mio-browser/），都在独立的 WKContentWorld 里运行，
// 页面脚本看不到也改不了它们；纯逻辑与设置在 MioReaderCore.swift。
//
//  - 阅读模式：每次页面加载完（以及 SPA 换地址后）判断是否像文章，像就在地址栏右侧显示按钮；点开后在独立的 WKWebView 里
//    显示提取出来的正文（禁用网页 JS + CSP），白 / 米 / 深背景、字体、字号，「完成」返回原页。
//  - 强制深色：document-start 注入 dark.js（按站点 + 全局开关）；同时把 WebView 外观切成深色，网站自带的
//    prefers-color-scheme: dark 直接生效，没有深色的网站用智能反色；判断出「自带深色」的站点记下来，下次不先反色。
//  - 存到 Mio：在 App 主窗口（已登录 MioCore 的 WebView，同源）里用 fetch 调 MioCore API，复用会话 Cookie /
//    Cloudflare Access；设置里填了 API 令牌（存钥匙串）时另加 Bearer。

import UIKit
import WebKit
import Security

// MARK: - 钥匙串里的 MioCore API 令牌

enum MioCoreToken {
    private static let service = "xyz.mio.app.miocore"
    private static let account = "api-token"

    static func read() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
              let s = String(data: d, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    @discardableResult
    static func save(_ token: String?) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let t = token?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(t.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static var isSet: Bool { read() != nil }
}

// MARK: - 共享

enum MioPageToolsShared {
    static let store = MioPageToolsStore()
    static let readerWorld = WKContentWorld.world(name: "mio-reader")
    static let darkWorld = WKContentWorld.world(name: "mio-dark")
    static let saveWorld = WKContentWorld.world(name: "mio-save")
    static let darkMessage = "mioDark"

    static let readerSource: String? = MioPageScripts.bundledSource("reader")
    static let darkSource: String? = MioPageScripts.bundledSource("dark")
    static let saveSource: String? = MioPageScripts.bundledSource("mio-save")

    /// 设置变了：让浏览器重建用户脚本（MioBrowserViewController 监听这个通知）
    static func settingsChanged() {
        NotificationCenter.default.post(name: .mioBrowserSettingsDidChange, object: nil)
    }

    /// App 主窗口里已打开 MioCore 的 WKWebView（iOS：Capacitor bridge；Mac：MioDesktopViewController）
    static func mainWebView(excluding: WKWebView?) -> WKWebView? {
        func find(_ v: UIView) -> WKWebView? {
            if let w = v as? WKWebView, w !== excluding, w.url?.host == MioShellTheme.host { return w }
            for s in v.subviews { if let w = find(s) { return w } }
            return nil
        }
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            for window in ws.windows {
                guard let root = window.rootViewController else { continue }
                var vc: UIViewController? = root
                while let c = vc {
                    if let w = find(c.view) { return w }
                    vc = c.presentedViewController
                    if vc is MioBrowserViewController { break }
                }
            }
        }
        return nil
    }

    static func toast(_ text: String, ok: Bool = true, in view: UIView?) {
        guard let view = view else { return }
        let label = PaddingLabel()
        label.text = (ok ? "✓ " : "⚠︎ ") + text
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.82)
        label.layer.cornerRadius = 12
        label.clipsToBounds = true
        label.alpha = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -72),
            label.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.86),
        ])
        UIAccessibility.post(notification: .announcement, argument: text)
        UIView.animate(withDuration: 0.2) { label.alpha = 1 }
        UIView.animate(withDuration: 0.3, delay: ok ? 2.0 : 4.0, options: []) { label.alpha = 0 } completion: { _ in label.removeFromSuperview() }
    }

    final class PaddingLabel: UILabel {
        override func drawText(in rect: CGRect) { super.drawText(in: rect.insetBy(dx: 14, dy: 9)) }
        override var intrinsicContentSize: CGSize {
            let s = super.intrinsicContentSize
            return CGSize(width: s.width + 28, height: s.height + 18)
        }
    }
}

// MARK: - 挂在浏览器上的控制器

final class MioPageTools: NSObject, WKScriptMessageHandler {
    private weak var webView: WKWebView?
    private weak var host: UIViewController?
    private var store: MioPageToolsStore { MioPageToolsShared.store }
    private var readerCheckToken = 0
    private(set) var readerable = false
    private var saving = false

    /// 地址栏右侧的阅读模式按钮（检测到文章时显示）
    let readerButton = UIButton(type: .system)
    /// 工具栏「存到 Mio」按钮（菜单：存书签 / 笔记 / 剪贴板，阅读模式，深色开关，设置）
    private(set) lazy var barItem: UIBarButtonItem = {
        let item = UIBarButtonItem(image: UIImage(systemName: "tray.and.arrow.down"), style: .plain, target: nil, action: nil)
        item.accessibilityLabel = "存到 Mio"
        item.menu = makeMenu()
        return item
    }()

    init(webView: WKWebView, host: UIViewController) {
        self.webView = webView
        self.host = host
        super.init()
        readerButton.setImage(UIImage(systemName: "doc.plaintext"), for: .normal)
        readerButton.accessibilityLabel = "阅读模式"
        readerButton.frame = CGRect(x: 0, y: 0, width: 34, height: 30)
        readerButton.isHidden = true
        readerButton.addTarget(self, action: #selector(readerTapped), for: .touchUpInside)
        webView.configuration.userContentController.add(MioWeakScriptHandler(self), contentWorld: MioPageToolsShared.darkWorld, name: MioPageToolsShared.darkMessage)
        applyAppearance(for: webView.url)
    }

    func detach() {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: MioPageToolsShared.darkMessage, contentWorld: MioPageToolsShared.darkWorld)
    }

    // MARK: 用户脚本（MioBrowserViewController.extraScripts 里调用）

    static func userScripts() -> [WKUserScript] {
        let s = MioPageToolsShared.store
        let global = s.darkGlobal, sites = s.darkSites
        guard MioForceDarkPolicy.needsScript(global: global, sites: sites), let src = MioPageToolsShared.darkSource else { return [] }
        let json = MioForceDarkPolicy.configJSON(global: global, sites: sites, nativeHosts: s.darkNativeHosts)
        return [WKUserScript(source: MioPageScripts.darkInstallScript(source: src, configJSON: json),
                             injectionTime: .atDocumentStart, forMainFrameOnly: true, in: MioPageToolsShared.darkWorld)]
    }

    // MARK: 浏览器挂钩

    /// 主框架开始导航：外观（prefers-color-scheme）按新站点设置；隐藏阅读按钮直到新页面判断完
    func willNavigate(to url: URL) {
        applyAppearance(for: url)
        setReaderable(false)
    }

    func didFinish() {
        checkReaderable(delay: 0.3)
    }

    /// SPA 换地址（history.pushState）不会触发 didFinish
    func urlChanged() {
        barItem.menu = makeMenu()
        checkReaderable(delay: 1.2)
    }

    private func applyAppearance(for url: URL?) {
        guard let wv = webView else { return }
        let on = store.isDarkEnabled(host: url?.host)
        wv.overrideUserInterfaceStyle = on ? .dark : .unspecified
        if on {
            wv.backgroundColor = UIColor(white: 0.07, alpha: 1)
            if #available(iOS 15.0, macCatalyst 15.0, *) { wv.underPageBackgroundColor = UIColor(white: 0.07, alpha: 1) }
        } else {
            wv.backgroundColor = .systemBackground
            if #available(iOS 15.0, macCatalyst 15.0, *) { wv.underPageBackgroundColor = nil }
        }
    }

    private func setReaderable(_ on: Bool) {
        readerable = on
        readerButton.isHidden = !on
    }

    private func checkReaderable(delay: TimeInterval) {
        readerCheckToken += 1
        let token = readerCheckToken
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, token == self.readerCheckToken, let wv = self.webView, let src = MioPageToolsShared.readerSource else { return }
            guard let s = wv.url?.scheme?.lowercased(), s == "http" || s == "https" else { self.setReaderable(false); return }
            wv.callAsyncJavaScript(MioPageScripts.readerableBody(source: src), arguments: [:], in: nil, in: MioPageToolsShared.readerWorld) { [weak self] result in
                guard let self = self, token == self.readerCheckToken else { return }
                if case .success(let v) = result { self.setReaderable((v as? Bool) == true) } else { self.setReaderable(false) }
            }
        }
    }

    // MARK: 菜单

    func makeMenu() -> UIMenu {
        let save = UIMenu(title: "存到 Mio", options: .displayInline, children: MioSaveKind.allCases.map { kind in
            UIAction(title: kind.title, subtitle: kind.subtitle, image: UIImage(systemName: kind.systemImage)) { [weak self] _ in self?.save(kind) }
        })
        let reader = UIAction(title: "阅读模式", image: UIImage(systemName: "doc.plaintext")) { [weak self] _ in self?.openReader(force: true) }
        let hostName = webView?.url?.host
        var dark: [UIMenuElement] = []
        if let h = hostName {
            let on = store.isDarkEnabled(host: h)
            dark.append(UIAction(title: "此网站深色", subtitle: MioForceDarkPolicy.normalize(h), image: UIImage(systemName: "moon"), state: on ? .on : .off) { [weak self] _ in
                self?.setSiteDark(!on)
            })
        }
        dark.append(UIAction(title: "所有网站深色", image: UIImage(systemName: "moon.stars"), state: store.darkGlobal ? .on : .off) { [weak self] _ in
            guard let self = self else { return }
            self.store.darkGlobal = !self.store.darkGlobal
            self.afterDarkChange()
        })
        let settings = UIAction(title: "阅读、深色与存到 Mio 设置…", image: UIImage(systemName: "slider.horizontal.3")) { [weak self] _ in self?.openSettings() }
        return UIMenu(title: "", children: [save, UIMenu(title: "", options: .displayInline, children: [reader] + dark), settings])
    }

    private func setSiteDark(_ on: Bool) {
        guard let h = webView?.url?.host else { return }
        // 和全局一致时去掉站点设置（跟随全局），否则记为站点例外
        store.setDark(host: h, enabled: on == store.darkGlobal ? nil : on)
        if store.isDarkEnabled(host: h) != on { store.setDark(host: h, enabled: on) }
        afterDarkChange()
    }

    private func afterDarkChange() {
        MioPageToolsShared.settingsChanged()   // 浏览器重建用户脚本
        barItem.menu = makeMenu()
        applyAppearance(for: webView?.url)
        if webView?.url != nil { webView?.reload() }
    }

    func openSettings() {
        let vc = MioPageToolsSettingsViewController(currentHost: webView?.url?.host)
        let nav = UINavigationController(rootViewController: vc)
        host?.present(nav, animated: true)
    }

    @objc private func readerTapped() { openReader(force: false) }

    // MARK: 阅读模式

    func openReader(force: Bool) {
        guard let wv = webView, let src = MioPageToolsShared.readerSource else { return }
        let prefs = store.readerPrefs.jsPrefs(systemDark: host?.traitCollection.userInterfaceStyle == .dark)
        wv.callAsyncJavaScript(MioPageScripts.extractBody(source: src), arguments: ["prefs": prefs, "force": force], in: nil, in: MioPageToolsShared.readerWorld) { [weak self] result in
            guard let self = self else { return }
            guard case .success(let v) = result, let out = v as? [String: Any], let page = out["page"] as? String else {
                MioPageToolsShared.toast("这个页面没有可提取的正文", ok: false, in: self.host?.view)
                return
            }
            let url = URL(string: out["url"] as? String ?? "") ?? wv.url
            let vc = MioReaderViewController(html: page, baseURL: url, extracted: out, tools: self)
            vc.modalPresentationStyle = .fullScreen
            self.host?.present(vc, animated: true)
        }
    }

    /// 阅读视图里的链接：回到浏览器打开
    func openFromReader(_ url: URL) {
        webView?.load(URLRequest(url: url))
    }

    // MARK: 存到 Mio

    /// 从当前页面收集：URL、标题、选中文字、正文（markdown）
    func save(_ kind: MioSaveKind, extracted: [String: Any]? = nil, from presenter: UIViewController? = nil) {
        guard !saving else { return }
        let toastView = (presenter ?? host)?.view
        if let e = extracted {
            send(kind, payload: e, toastView: toastView)
            return
        }
        guard let wv = webView, let url = wv.url, let s = url.scheme?.lowercased(), s == "http" || s == "https" else {
            MioPageToolsShared.toast("只能保存网页", ok: false, in: toastView)
            return
        }
        guard let src = MioPageToolsShared.readerSource, kind == .note else {
            // 书签 / 剪贴板只要地址和标题
            var payload: [String: Any] = ["url": url.absoluteString, "title": wv.title ?? ""]
            if kind == .bookmark, let src = MioPageToolsShared.readerSource {
                // 书签描述用页面摘要（og:description），失败就不带
                wv.callAsyncJavaScript(MioPageScripts.extractBody(source: src), arguments: ["prefs": [String: Any](), "force": false], in: nil, in: MioPageToolsShared.readerWorld) { [weak self] r in
                    if case .success(let v) = r, let out = v as? [String: Any], let a = out["article"] as? [String: Any] {
                        payload["article"] = ["excerpt": a["excerpt"] ?? ""] as [String: Any]
                    }
                    self?.send(kind, payload: payload, toastView: toastView)
                }
                return
            }
            send(kind, payload: payload, toastView: toastView)
            return
        }
        wv.callAsyncJavaScript(MioPageScripts.extractBody(source: src), arguments: ["prefs": [String: Any](), "force": true], in: nil, in: MioPageToolsShared.readerWorld) { [weak self] r in
            var payload: [String: Any] = ["url": url.absoluteString, "title": wv.title ?? ""]
            if case .success(let v) = r, let out = v as? [String: Any] {
                payload["selection"] = out["selection"] ?? ""
                if let a = out["article"] { payload["article"] = a }
            }
            self?.send(kind, payload: payload, toastView: toastView)
        }
    }

    private func send(_ kind: MioSaveKind, payload raw: [String: Any], toastView: UIView?) {
        guard let src = MioPageToolsShared.saveSource else {
            MioPageToolsShared.toast("App 包里缺少 mio-save.js", ok: false, in: toastView)
            return
        }
        guard let main = MioPageToolsShared.mainWebView(excluding: webView) else {
            MioPageToolsShared.toast("主窗口没有打开 MioCore，请先在主窗口登录", ok: false, in: toastView)
            return
        }
        // 只传 MioSave 用得到的字段（阅读视图 HTML 不传）
        var payload: [String: Any] = [:]
        for k in ["url", "title", "selection"] { if let v = raw[k] { payload[k] = v } }
        if let a = raw["article"] as? [String: Any] {
            var art: [String: Any] = [:]
            for k in ["title", "byline", "siteName", "excerpt", "markdown"] { if let v = a[k], !(v is NSNull) { art[k] = v } }
            payload["article"] = art
        }
        var opts: [String: Any] = ["origin": "https://\(MioShellTheme.host)", "category": store.saveCategory]
        if let t = MioCoreToken.read() { opts["token"] = t }
        saving = true
        main.callAsyncJavaScript(MioPageScripts.saveBody(source: src), arguments: ["kind": kind.rawValue, "payload": payload, "opts": opts],
                                 in: nil, in: MioPageToolsShared.saveWorld) { [weak self] result in
            self?.saving = false
            let msg: (ok: Bool, text: String)
            switch result {
            case .success(let v): msg = MioSaveKind.message(for: v as? [String: Any])
            case .failure(let e): msg = (false, "保存失败：\(e.localizedDescription)")
            }
            MioPageToolsShared.toast(msg.text, ok: msg.ok, in: toastView)
        }
    }

    // MARK: WKScriptMessageHandler（dark.js 上报「网站是否自带深色」）

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == MioPageToolsShared.darkMessage, message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any], let h = body["host"] as? String else { return }
        let native = (body["verdict"] as? String) == "native"
        let r = MioForceDarkPolicy.updateNativeHosts(store.darkNativeHosts, host: h, native: native)
        guard r.changed else { return }
        store.darkNativeHosts = r.list
        MioPageToolsShared.settingsChanged()   // 下次加载这个站点时不再先反色
    }
}

// MARK: - 阅读视图

final class MioReaderViewController: UIViewController, WKNavigationDelegate {
    private let html: String
    private let baseURL: URL?
    private let extracted: [String: Any]
    private weak var tools: MioPageTools?
    private var webView: WKWebView!
    private let bar = UIToolbar()
    private var prefs: MioReaderPrefs { MioPageToolsShared.store.readerPrefs }

    init(html: String, baseURL: URL?, extracted: [String: Any], tools: MioPageTools) {
        self.html = html
        self.baseURL = baseURL
        self.extracted = extracted
        self.tools = tools
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        effectiveTheme == "dark" ? .lightContent : .darkContent
    }

    private var effectiveTheme: String {
        (prefs.jsPrefs(systemDark: traitCollection.userInterfaceStyle == .dark)["theme"] as? String) ?? "light"
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let config = WKWebViewConfiguration()
        // 正文里的脚本已经去掉，这里再禁用网页 JS（App 自己 evaluate 的切换主题脚本不受影响）
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        if #available(iOS 17.0, macCatalyst 17.0, *) {
            config.websiteDataStore = WKWebsiteDataStore(forIdentifier: MioBrowserSettings.dataStoreID)
        }
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.allowsLinkPreview = true
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)

        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)
        let done = UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(doneTapped))
        done.accessibilityHint = "返回原网页"
        let aa = UIBarButtonItem(image: UIImage(systemName: "textformat.size"), style: .plain, target: nil, action: nil)
        aa.accessibilityLabel = "阅读设置"
        aa.menu = prefsMenu()
        let save = UIBarButtonItem(image: UIImage(systemName: "tray.and.arrow.down"), style: .plain, target: nil, action: nil)
        save.accessibilityLabel = "存到 Mio"
        save.menu = UIMenu(title: "存到 Mio", children: MioSaveKind.allCases.map { kind in
            UIAction(title: kind.title, subtitle: kind.subtitle, image: UIImage(systemName: kind.systemImage)) { [weak self] _ in
                guard let self = self else { return }
                self.tools?.save(kind, extracted: self.payloadForSave(kind), from: self)
            }
        })
        let flex = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        bar.items = [done, flex, save, aa]

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
        applyChrome()
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    private func payloadForSave(_ kind: MioSaveKind) -> [String: Any] {
        var p: [String: Any] = ["url": extracted["url"] ?? baseURL?.absoluteString ?? "", "title": extracted["title"] ?? ""]
        if let s = extracted["selection"] { p["selection"] = s }
        if let a = extracted["article"] { p["article"] = a }
        return p
    }

    private func applyChrome() {
        let theme = effectiveTheme
        let bg: UIColor
        switch theme {
        case "dark": bg = UIColor(red: 0x12 / 255, green: 0x12 / 255, blue: 0x12 / 255, alpha: 1)
        case "sepia": bg = UIColor(red: 0xf6 / 255, green: 0xef / 255, blue: 0xe1 / 255, alpha: 1)
        default: bg = .white
        }
        view.backgroundColor = bg
        webView.backgroundColor = bg
        webView.scrollView.backgroundColor = bg
        if #available(iOS 15.0, macCatalyst 15.0, *) { webView.underPageBackgroundColor = bg }
        overrideUserInterfaceStyle = theme == "dark" ? .dark : .light
        setNeedsStatusBarAppearanceUpdate()
    }

    private func prefsMenu() -> UIMenu {
        let p = prefs
        let themes = UIMenu(title: "背景", options: .displayInline, children: MioReaderPrefs.Theme.allCases.map { t in
            UIAction(title: MioReaderPrefs(theme: t).themeTitle, state: p.theme == t ? .on : .off) { [weak self] _ in self?.update { $0.theme = t } }
        })
        let fonts = UIMenu(title: "字体", options: .displayInline, children: MioReaderPrefs.Font.allCases.map { f in
            UIAction(title: MioReaderPrefs(font: f).fontTitle, state: p.font == f ? .on : .off) { [weak self] _ in self?.update { $0.font = f } }
        })
        let smaller = UIAction(title: "字号变小", image: UIImage(systemName: "textformat.size.smaller")) { [weak self] _ in self?.update { $0.fontSize -= 1 } }
        let larger = UIAction(title: "字号变大（\(p.fontSize)）", image: UIImage(systemName: "textformat.size.larger")) { [weak self] _ in self?.update { $0.fontSize += 1 } }
        if #available(iOS 16.0, macCatalyst 16.0, *) {
            smaller.attributes = .keepsMenuPresented
            larger.attributes = .keepsMenuPresented
        }
        if p.fontSize <= MioReaderPrefs.fontSizeRange.lowerBound { smaller.attributes.insert(.disabled) }
        if p.fontSize >= MioReaderPrefs.fontSizeRange.upperBound { larger.attributes.insert(.disabled) }
        let sizes = UIMenu(title: "字号", options: .displayInline, children: [smaller, larger])
        return UIMenu(title: "阅读设置", children: [themes, fonts, sizes])
    }

    private func update(_ change: (inout MioReaderPrefs) -> Void) {
        var p = prefs
        change(&p)
        p.fontSize = MioReaderPrefs.clamp(p.fontSize)
        MioPageToolsShared.store.readerPrefs = p
        let js = Self.applyPrefsJS(p.jsPrefs(systemDark: traitCollection.userInterfaceStyle == .dark))
        webView.evaluateJavaScript(js, completionHandler: nil)
        applyChrome()
        if let aa = bar.items?.last { aa.menu = prefsMenu() }
    }

    /// 与 reader.js 的 applyPrefsScript 相同（这里不依赖页面里的 JS：阅读视图禁用了网页脚本）
    static func applyPrefsJS(_ p: [String: Any]) -> String {
        let theme = (p["theme"] as? String) ?? "light"
        let font = (p["font"] as? String) ?? "sans"
        let size = (p["fontSize"] as? Int) ?? 18
        return "(function(d){d.setAttribute('data-theme','\(theme)');d.setAttribute('data-font','\(font)');d.style.setProperty('--fs','\(size)px');return true;})(document.documentElement)"
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard prefs.theme == .auto, previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle else { return }
        update { _ in }
    }

    @objc private func doneTapped() { dismiss(animated: true) }

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(title: "退出阅读模式", action: #selector(doneTapped), input: UIKeyCommand.inputEscape),
         UIKeyCommand(title: "退出阅读模式", action: #selector(doneTapped), input: "r", modifierFlags: [.command, .shift])]
    }

    // 链接：回到浏览器打开
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            decisionHandler(.cancel)
            if let s = url.scheme?.lowercased(), s == "http" || s == "https" {
                dismiss(animated: true) { [weak self] in self?.tools?.openFromReader(url) }
            } else {
                UIApplication.shared.open(url)
            }
            return
        }
        decisionHandler(.allow)
    }
}

// MARK: - 设置

final class MioPageToolsSettingsViewController: UITableViewController {
    private enum Row {
        case readerTheme, readerFont, readerSize
        case darkGlobal, darkSite(String), darkEntry(String, Bool), darkClearNative
        case saveCategory, saveToken, saveInfo
    }
    private let currentHost: String?
    private var sections: [(title: String?, footer: String?, rows: [Row])] = []
    private var store: MioPageToolsStore { MioPageToolsShared.store }

    init(currentHost: String?) {
        self.currentHost = currentHost
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "阅读、深色与存到 Mio"
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(doneTapped))
        rebuild()
    }

    @objc private func doneTapped() { dismiss(animated: true) }

    private func rebuild() {
        var s: [(String?, String?, [Row])] = []
        s.append(("阅读模式", "网页像文章时，地址栏右侧出现阅读模式按钮（也可在工具栏「存到 Mio」菜单里打开）。正文由 Mio 自己的提取算法生成，图片保留；「完成」返回原网页。", [.readerTheme, .readerFont, .readerSize]))
        var dark: [Row] = [.darkGlobal]
        if let h = currentHost { dark.append(.darkSite(h)) }
        let entries = store.darkSites.sorted { $0.key < $1.key }.map { Row.darkEntry($0.key, $0.value) }
        dark.append(contentsOf: entries)
        if !store.darkNativeHosts.isEmpty { dark.append(.darkClearNative) }
        s.append(("强制深色", "优先使用网站自带的深色模式（prefers-color-scheme）；网站没有深色时智能反色，图片、视频保持原色。按站点的设置优先于「所有网站深色」，左滑删除站点设置。改动后当前网页会重新加载。", dark))
        s.append(("存到 Mio", "在 App 主窗口已登录的 MioCore（\(MioShellTheme.host)）里保存，复用主窗口的登录状态；会话过期或被 Cloudflare Access 拦下时，可填 MioCore 的 API 令牌（只存在本机钥匙串）。导航书签存到下面的分类，分类不存在时自动创建；导航里已有同一网址时不重复添加。", [.saveCategory, .saveToken, .saveInfo]))
        sections = s.map { (title: $0.0, footer: $0.1, rows: $0.2) }
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].rows.count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { sections[section].title }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? { sections[section].footer }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.selectionStyle = .none
        cell.detailTextLabel?.textColor = .secondaryLabel
        let p = store.readerPrefs
        switch sections[indexPath.section].rows[indexPath.row] {
        case .readerTheme:
            cell.textLabel?.text = "背景"
            cell.detailTextLabel?.text = p.themeTitle
            cell.accessoryType = .disclosureIndicator; cell.selectionStyle = .default
        case .readerFont:
            cell.textLabel?.text = "字体"
            cell.detailTextLabel?.text = p.fontTitle
            cell.accessoryType = .disclosureIndicator; cell.selectionStyle = .default
        case .readerSize:
            cell.textLabel?.text = "字号 \(p.fontSize)"
            let stepper = UIStepper()
            stepper.minimumValue = Double(MioReaderPrefs.fontSizeRange.lowerBound)
            stepper.maximumValue = Double(MioReaderPrefs.fontSizeRange.upperBound)
            stepper.value = Double(p.fontSize)
            stepper.addAction(UIAction { [weak self, weak cell] a in
                guard let self = self, let st = a.sender as? UIStepper else { return }
                var np = self.store.readerPrefs
                np.fontSize = Int(st.value)
                self.store.readerPrefs = np
                cell?.textLabel?.text = "字号 \(np.fontSize)"
            }, for: .valueChanged)
            cell.accessoryView = stepper
        case .darkGlobal:
            cell.textLabel?.text = "所有网站深色"
            cell.accessoryView = makeSwitch(store.darkGlobal) { [weak self] on in
                self?.store.darkGlobal = on
                self?.changed()
            }
        case .darkSite(let h):
            cell.textLabel?.text = "在 \(MioForceDarkPolicy.normalize(h)) 上深色"
            cell.accessoryView = makeSwitch(store.isDarkEnabled(host: h)) { [weak self] on in
                guard let self = self else { return }
                self.store.setDark(host: h, enabled: on == self.store.darkGlobal ? nil : on)
                if self.store.isDarkEnabled(host: h) != on { self.store.setDark(host: h, enabled: on) }
                self.changed()
            }
        case .darkEntry(let h, let on):
            cell.textLabel?.text = h
            cell.detailTextLabel?.text = on ? "深色" : "不深色"
        case .darkClearNative:
            cell.textLabel?.text = "重新检测网站自带深色（\(store.darkNativeHosts.count) 个站点）"
            cell.textLabel?.textColor = .systemBlue
            cell.selectionStyle = .default
        case .saveCategory:
            cell.textLabel?.text = "书签分类"
            cell.detailTextLabel?.text = store.saveCategory
            cell.accessoryType = .disclosureIndicator; cell.selectionStyle = .default
        case .saveToken:
            cell.textLabel?.text = "API 令牌（可选）"
            cell.detailTextLabel?.text = MioCoreToken.isSet ? "已设置" : "未设置"
            cell.accessoryType = .disclosureIndicator; cell.selectionStyle = .default
        case .saveInfo:
            cell.textLabel?.text = "笔记内容"
            cell.detailTextLabel?.text = "标题 + 链接 + 选中文字 + 正文"
        }
        return cell
    }

    private func makeSwitch(_ on: Bool, _ change: @escaping (Bool) -> Void) -> UISwitch {
        let sw = UISwitch()
        sw.isOn = on
        sw.addAction(UIAction { a in if let s = a.sender as? UISwitch { change(s.isOn) } }, for: .valueChanged)
        return sw
    }

    private func changed() {
        MioPageToolsShared.settingsChanged()
        rebuild()
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let cell = tableView.cellForRow(at: indexPath)
        switch sections[indexPath.section].rows[indexPath.row] {
        case .readerTheme:
            let current = store.readerPrefs.theme
            let options: [PickOption] = MioReaderPrefs.Theme.allCases.map { t in
                PickOption(title: MioReaderPrefs(theme: t).themeTitle, selected: current == t) { [weak self] in
                    guard let self = self else { return }
                    var p = self.store.readerPrefs
                    p.theme = t
                    self.store.readerPrefs = p
                    self.rebuild()
                }
            }
            pick("背景", options, from: cell)
        case .readerFont:
            let current = store.readerPrefs.font
            let options: [PickOption] = MioReaderPrefs.Font.allCases.map { f in
                PickOption(title: MioReaderPrefs(font: f).fontTitle, selected: current == f) { [weak self] in
                    guard let self = self else { return }
                    var p = self.store.readerPrefs
                    p.font = f
                    self.store.readerPrefs = p
                    self.rebuild()
                }
            }
            pick("字体", options, from: cell)
        case .darkClearNative:
            store.darkNativeHosts = []
            changed()
        case .saveCategory:
            let a = UIAlertController(title: "书签分类", message: "存为导航书签时放进这个分类（名称或 id），不存在时自动创建", preferredStyle: .alert)
            a.addTextField { $0.text = self.store.saveCategory; $0.clearButtonMode = .whileEditing }
            a.addAction(UIAlertAction(title: "取消", style: .cancel))
            a.addAction(UIAlertAction(title: "保存", style: .default) { [weak self] _ in
                self?.store.saveCategory = a.textFields?.first?.text ?? ""
                self?.rebuild()
            })
            present(a, animated: true)
        case .saveToken:
            let a = UIAlertController(title: "MioCore API 令牌", message: "在 MioCore 设置 › API 令牌里创建（需要 nav:write、notes:write、snippets:write 权限）。只存在本机钥匙串；留空保存即删除。", preferredStyle: .alert)
            a.addTextField { tf in
                tf.isSecureTextEntry = true
                tf.placeholder = MioCoreToken.isSet ? "已设置（输入新令牌以替换）" : "粘贴令牌"
                tf.autocapitalizationType = .none
                tf.autocorrectionType = .no
            }
            a.addAction(UIAlertAction(title: "取消", style: .cancel))
            if MioCoreToken.isSet {
                a.addAction(UIAlertAction(title: "删除令牌", style: .destructive) { [weak self] _ in MioCoreToken.save(nil); self?.rebuild() })
            }
            a.addAction(UIAlertAction(title: "保存", style: .default) { [weak self] _ in
                let t = a.textFields?.first?.text ?? ""
                if !t.isEmpty || !MioCoreToken.isSet { MioCoreToken.save(t) }
                self?.rebuild()
            })
            present(a, animated: true)
        default:
            break
        }
    }

    private struct PickOption {
        let title: String
        let selected: Bool
        let action: () -> Void
    }

    private func pick(_ title: String, _ options: [PickOption], from cell: UITableViewCell?) {
        let a = MioActionList(title: title)
        for o in options {
            a.add(o.title, checked: o.selected) { o.action() }
        }
        a.present(from: self, sourceView: cell)
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        if case .darkEntry = sections[indexPath.section].rows[indexPath.row] { return true }
        return false
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete, case .darkEntry(let h, _) = sections[indexPath.section].rows[indexPath.row] else { return }
        var s = store.darkSites
        s.removeValue(forKey: h)
        store.darkSites = s
        changed()
    }
}
