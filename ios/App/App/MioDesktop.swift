// MioDesktop.swift — Mac（Mac Catalyst）主界面：不用 Capacitor（它的 xcframework 没有 Catalyst 切片），
// 纯 WKWebView 加载 MioCore（/mio/nav），并在页面里暴露与 Windows 壳相同的 window.MioDesktop.browser：
//   MioDesktop.browser.open({ url, mode? })  → App 内置浏览器（MioBrowserViewController，带 AdGuard 拦截；设置了「默认用系统浏览器」则交给 Safari）
//   MioDesktop.browser.openSettings()        → 拦截设置
//   MioDesktop.browser.getInfo()
// MioCore 的 src/utils/appShell.ts 检测到 MioDesktop.browser 后接管站外链接。复用 MioBrowser.swift / MioAdblockCore.swift。
// 这个文件 iOS 上也会编译（不被使用），所以不依赖任何 Catalyst 专有 API（专有的放在 #if targetEnvironment(macCatalyst) 里）。

import UIKit
import WebKit

final class MioDesktopViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKScriptMessageHandlerWithReply {
    /// 主界面里允许直接跳转的站点（Cloudflare Access 登录、Google / GitHub 身份提供方）
    static let allowedHosts = ["mio.300031.xyz", "*.cloudflareaccess.com", "accounts.google.com", "github.com"]

    private(set) var webView: WKWebView!
    private var cover: MioLaunchCover?
    private var coverDone = false
    private var sawBoot = false
    private let startedAt = CACurrentMediaTime()
    private var updateTimer: Timer?
    /// CI 冒烟测试：MIO_SMOKE_OUT=<json 路径> 时打开公开的站点首页 /，检查 window.MioDesktop.browser、调用 open、等拦截规则就绪，写结果后退出
    private static let smokeOut = ProcessInfo.processInfo.environment["MIO_SMOKE_OUT"]
    private var smokeStarted = false

    static func configure(_ scene: UIWindowScene) {
        #if targetEnvironment(macCatalyst)
        scene.sizeRestrictions?.minimumSize = CGSize(width: 480, height: 420)
        scene.title = "Mio"
        if let titlebar = scene.titlebar {
            titlebar.titleVisibility = .visible
            titlebar.toolbar = nil
        }
        #endif
    }

    static func hostAllowed(_ host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        return allowedHosts.contains { p in
            if p.hasPrefix("*.") { return host.hasSuffix(String(p.dropFirst(1))) }
            return host == p || host.hasSuffix("." + p)
        }
    }

    // MARK: lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = MioShellTheme.background

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let ucc = config.userContentController
        ucc.add(MioWeakScriptHandler(self), name: "mioShell")
        ucc.addScriptMessageHandler(MioWeakReplyHandler(self), contentWorld: .page, name: "mioDesktop")
        ucc.addUserScript(WKUserScript(source: Self.bridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        #if targetEnvironment(macCatalyst)
        // Mac：textarea / contenteditable 回车 / Shift+回车不换行的兜底（与内置浏览器同一份脚本，见 MioWebCompat.swift）
        ucc.addUserScript(WKUserScript(source: MioWebCompat.returnKeyFixScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        #endif

        let webView = WKWebView(frame: view.bounds, configuration: config)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.backgroundColor = MioShellTheme.background
        webView.scrollView.backgroundColor = MioShellTheme.background
        webView.isOpaque = false
        if #available(iOS 15.0, macCatalyst 15.0, *) {
            webView.underPageBackgroundColor = MioShellTheme.background
        }
        if #available(iOS 16.4, macCatalyst 16.4, *) {
            webView.isInspectable = true
        }
        view.addSubview(webView)
        self.webView = webView

        let cover = MioLaunchCover(frame: view.bounds)
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(cover)
        self.cover = cover
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.hideCover("timeout") }

        if Self.smokeOut != nil {
            webView.load(URLRequest(url: URL(string: "https://\(MioShellTheme.host)/")!))
        } else {
            webView.load(URLRequest(url: MioShellTheme.home))
        }

        // Mac 上 App 常驻：每小时看一次，距上次检查满 24 小时就更新拦截规则（iOS 靠回到前台 / BGAppRefreshTask）
        updateTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            if MioAdblock.shared.needsUpdateCheck && MioAdblock.shared.snapshot.busy == nil {
                MioAdblock.shared.checkForUpdates(force: false)
            }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 浏览器收起 / App 重启后有上次的标签：右下角显示标签数角标
        MioTabsBadge.attachIfNeeded(to: self)
    }

    deinit {
        updateTimer?.invalidate()
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    private func hideCover(_ reason: String) {
        guard !coverDone, let cover = cover else { return }
        coverDone = true
        print("⚡️ Mio (mac) launch cover hidden (\(reason)) at +\(Int((CACurrentMediaTime() - startedAt) * 1000)) ms")
        UIView.animate(withDuration: 0.2, animations: { cover.alpha = 0 }, completion: { _ in
            cover.removeFromSuperview()
            self.cover = nil
        })
    }

    // MARK: keyboard（⌘R 刷新、⌘[ ⌘] 前进后退、⌘, 浏览器设置；⌘⇧O 用 Safari 打开在菜单栏，见 AppDelegate.buildMenu）
    //
    // 回车键：这里和 Capacitor（Mac 上不链接）都没有注册 Return / Enter 的 UIKeyCommand，也没有拦截 pressesBegan；
    // 回车不换行的兜底在注入的 MioWebCompat.returnKeyFixScript 里，下面的 pressesBegan 只记录诊断日志。

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(title: "刷新", action: #selector(reloadPage), input: "r", modifierFlags: .command),
            UIKeyCommand(title: "后退", action: #selector(goBack), input: "[", modifierFlags: .command),
            UIKeyCommand(title: "前进", action: #selector(goForward), input: "]", modifierFlags: .command),
            UIKeyCommand(title: "浏览器设置", action: #selector(openBrowserSettings), input: ",", modifierFlags: .command),
        ]
    }

    @objc private func reloadPage() {
        if webView.url == nil || webView.url?.host != MioShellTheme.host { webView.load(URLRequest(url: MioShellTheme.home)) } else { webView.reload() }
    }
    @objc private func goBack() { if webView.canGoBack { webView.goBack() } }
    @objc private func goForward() { if webView.canGoForward { webView.goForward() } }
    /// 菜单「浏览器 › 用 Safari 打开」（⌘⇧O）：主界面当前页面交给 Safari
    @objc func mioOpenInSafari(_ sender: Any?) {
        var url = webView.url ?? MioShellTheme.home
        if let s = url.scheme?.lowercased(), s != "http" && s != "https" { url = MioShellTheme.home }
        UIApplication.shared.open(url)
    }

    #if targetEnvironment(macCatalyst)
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        MioWebKitCompat.logUnhandledReturn(presses, in: self)
        super.pressesBegan(presses, with: event)
    }
    #endif

    @objc func openBrowserSettings() {
        guard let presenter = MioBrowserViewController.topPresenter(self) else { return }
        let nav = UINavigationController(rootViewController: MioBrowserSettingsViewController(currentHost: nil))
        presenter.present(nav, animated: true)
    }

    // MARK: bridge

    /// window.MioDesktop（只在 MioCore 站点的主框架注入）
    static let bridgeScript = """
    (function () {
      if (location.hostname !== '\(MioShellTheme.host)' || window.MioDesktop) return;
      var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.mioDesktop;
      if (!h) return;
      function call(method, args) { return h.postMessage({ method: method, args: args || {} }); }
      var browser = Object.freeze({
        open: function (o) { return call('open', { url: String((o && o.url) || ''), mode: String((o && o.mode) || 'auto') }); },
        openSettings: function () { return call('openSettings'); },
        getInfo: function () { return call('getInfo'); }
      });
      Object.defineProperty(window, 'MioDesktop', { value: Object.freeze({ platform: 'mac', shell: 'catalyst', browser: browser }), enumerable: true });
    })();
    """

    // boot-loader.js → mioShell
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "mioShell" else { return }
        let body = message.body as? [String: Any]
        let type = (body?["type"] as? String) ?? (message.body as? String) ?? ""
        switch type {
        case "boot": sawBoot = true
        case "ready", "failed": hideCover(type)
        default: break
        }
    }

    // window.MioDesktop.browser.* → Promise
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.name == "mioDesktop", message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.host == MioShellTheme.host,
              message.frameInfo.securityOrigin.protocol == "https" else {
            replyHandler(nil, "forbidden")
            return
        }
        let body = message.body as? [String: Any] ?? [:]
        let method = body["method"] as? String ?? ""
        let args = body["args"] as? [String: Any] ?? [:]
        switch method {
        case "open":
            let raw = (args["url"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                replyHandler(nil, "invalid url")
                return
            }
            let mode = args["mode"] as? String ?? "auto"
            replyHandler(["opened": openExternal(url, mode: mode)], nil)
        case "openSettings":
            openBrowserSettings()
            replyHandler(true, nil)
        case "getInfo":
            let snap = MioAdblock.shared.snapshot
            var info: [String: Any] = [
                "version": MioBrowserSettings.appVersion,
                "platform": "mac",
                "adblock": MioAdblockSettings.enabled,
                "preferSafari": MioBrowserSettings.preferSafari,
                "ruleLists": snap.ruleListCount,
            ]
            if let d = snap.state.lastCheck { info["rulesCheckedAt"] = ISO8601DateFormatter().string(from: d) }
            if let s = snap.state.scriptlets { info["scriptlets"] = s.version }
            replyHandler(info, nil)
        default:
            replyHandler(nil, "unknown method")
        }
    }

    private func runSmoke(_ out: String) {
        let js = """
        const r = { host: location.hostname, open: typeof (window.MioDesktop && window.MioDesktop.browser && window.MioDesktop.browser.open), platform: window.MioDesktop && window.MioDesktop.platform };
        try { r.opened = await window.MioDesktop.browser.open({ url: 'https://www.youtube.com/' }); } catch (e) { r.openError = String(e); }
        try { r.info = await window.MioDesktop.browser.getInfo(); } catch (e) { r.infoError = String(e); }
        return JSON.stringify(r);
        """
        webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { [weak self] result in
            var report: [String: Any] = [:]
            switch result {
            case .success(let v): report["page"] = (v as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } ?? "\(String(describing: v))"
            case .failure(let e): report["pageError"] = "\(e)"
            }
            let started = Date()
            var ytFocus: [String: Any]?
            var tabsOK = false
            var media: [String: Any]?
            var translate: [String: Any]?
            // 用户脚本 + WebRTC 控制（MioUserScripts.swift 的 MioUserScriptSmoke）
            var extrasOK = false
            var actionListOK = false
            func finish() {
                let top = MioBrowserViewController.topPresenter(self)
                let presented = top is MioBrowserViewController || top is MioTabsViewController
                report["browserPresented"] = presented
                report["adblockReady"] = MioAdblock.shared.snapshot.ready
                report["ruleLists"] = MioAdblock.shared.snapshot.ruleListCount
                report["browserProfile"] = MioWebKitCompat.profile.rawValue
                report["mediaSourcePrefs"] = MioWebKitCompat.mediaSourcePrefs
                report["browserUserAgent"] = MioWebKitCompat.desktopUserAgent
                // 内置浏览器打开 YouTube 后的诊断：门槛只看页面里的 UA 是桌面 Safari（不含 Mobile）且没被跳到 m.youtube.com。
                // MediaSource/ManagedMediaSource 只记录不作门槛：Mac Catalyst 版 WebKit 编译时就关掉了 ENABLE(MEDIA_SOURCE)
                // （WTF/PlatformEnableCocoa.h：!PLATFORM(MACCATALYST)），偏好开了也没有 window.MediaSource，真机同样如此。
                var desktopOK = false
                if let probe = MioBrowserViewController.lastMediaProbe,
                   let obj = try? JSONSerialization.jsonObject(with: Data(probe.utf8)) as? [String: Any] {
                    report["browserProbe"] = obj
                    let ua = obj["ua"] as? String ?? ""
                    let mse = (obj["mediaSource"] as? String) == "function" || (obj["managedMediaSource"] as? String) == "function"
                    report["mseAvailable"] = mse
                    NSLog("⚡️ Mio smoke: MSE available in browser = %@ (informational, not a gate)", mse ? "yes" : "no")
                    let desktopSafariUA = ua.contains("Macintosh") && ua.contains("Safari/") && ua.contains("Version/") && !ua.contains("Mobile")
                    desktopOK = desktopSafariUA && (obj["host"] as? String) != "m.youtube.com"
                } else {
                    report["browserProbe"] = MioBrowserViewController.lastMediaProbe ?? "none"
                }
                report["desktopOK"] = desktopOK
                // YouTube 防沉迷：真实 WKWebView + YouTube（Trusted Types）里脚本已注入、样式在、进入 /shorts/ 能弹出提醒
                var ytFocusOK = true
                if MioBrowserSettings.youtubeFocus, let yt = ytFocus {
                    report["youtubeFocus"] = yt
                    ytFocusOK = (yt["installed"] as? Bool) == true && (yt["style"] as? Bool) == true
                        && (yt["reminder"] as? Bool) == true && ((yt["count"] as? Int) ?? 0) >= 1
                } else if MioBrowserSettings.youtubeFocus {
                    report["youtubeFocus"] = "not checked (no YouTube page)"
                }
                report["youtubeFocusOK"] = ytFocusOK
                // 媒体（MioMedia.swift）：YouTube 页面里媒体脚本已注入、SponsorBlock 纯逻辑可用；EME（YouTube / Spotify）只记录
                report["media"] = media ?? "not checked"
                let mediaOK = (media?["ok"] as? Bool) == true
                report["mediaOK"] = mediaOK
                report["translate"] = translate ?? ["checked": false]
                let translateOK = (translate?["installed"] as? Bool) == true && (translate?["bridge"] as? Bool) == true
                report["translateOK"] = translateOK
                let page = report["page"] as? [String: Any]
                report["tabsOK"] = tabsOK
                let ok = presented && MioAdblock.shared.snapshot.ready && (page?["open"] as? String) == "function" && desktopOK && ytFocusOK && mediaOK && translateOK && extrasOK && tabsOK && actionListOK
                report["actionListOK"] = actionListOK
                report["ok"] = ok
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: out))
                }
                exit(ok ? 0 : 1)
            }
            func waitProbe(_ deadline: Date) {
                if MioBrowserViewController.lastMediaProbe != nil || Date() > deadline {
                    MioBrowserViewController.smokeEvaluate(MioWebCompat.youtubeFocusSmokeScript) { result, error in
                        if let s = result as? String, let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] {
                            ytFocus = obj
                        } else if let e = error {
                            NSLog("⚡️ Mio smoke: youtube focus check failed: %@", "\(e)")
                        }
                        MioMediaSmoke.run { m in
                            media = m
                            MioTranslate.smokeCheck(network: true) { t in
                                translate = t
                                MioUserScriptSmoke.run { r, ok in
                                    report["userscriptsWebRTC"] = r
                                    extrasOK = ok
                                    NSLog("⚡️ Mio smoke: userscripts/WebRTC %@ %@", ok ? "OK" : "FAILED", "\(r)")
                                    // 多标签页（MioTabs.swift）：第二个标签、切换、关闭、恢复；顶部工具栏 + 标签条；网页在工具栏下面；容器标签
                                    MioTabsSmoke.run { r, ok in
                                        report["tabs"] = r
                                        tabsOK = ok
                                        NSLog("⚡️ Mio smoke: tabs %@ %@", ok ? "OK" : "FAILED", "\(r)")
                                        // YouTube 高清（MioYouTubeHD.swift）：MSE / 可用画质
                                        MioYouTubeHDSmoke.run { r, ok in
                                            report["youtubeHD"] = r
                                            report["youtubeHDOK"] = ok
                                            // 翻译「翻译成」等选项列表（MioActionList.swift）：纵向 popover，不再是横向一排
                                            MioActionListSmoke.run { r, ok in
                                                report["actionList"] = r
                                                actionListOK = ok
                                                finish()
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { waitProbe(deadline) }
                }
            }
            func poll() {
                if MioAdblock.shared.snapshot.ready || Date().timeIntervalSince(started) > 90 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { waitProbe(Date().addingTimeInterval(25)) }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { poll() }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { poll() }
        }
    }

    @discardableResult
    private func openExternal(_ url: URL, mode: String = "auto") -> String {
        if mode == "safari" || mode == "system" || (mode == "auto" && MioBrowserSettings.preferSafari) {
            UIApplication.shared.open(url)
            return "system"
        }
        MioBrowserViewController.open(url, from: self)
        return "inapp"
    }

    // MARK: navigation

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow)
            return
        }
        if scheme != "http" && scheme != "https" {
            if ["about", "blob", "data"].contains(scheme) {
                decisionHandler(.allow)
            } else {
                if ["mailto", "tel", "sms", "facetime", "maps"].contains(scheme) { UIApplication.shared.open(url) }
                decisionHandler(.cancel)
            }
            return
        }
        let mainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        // 用户点了站外链接（页面没交给 MioDesktop.browser 的情况）：内置浏览器打开；跳转 / 表单（登录流程）照常
        if mainFrame && navigationAction.navigationType == .linkActivated && !Self.hostAllowed(url.host) {
            openExternal(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        sawBoot = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let out = Self.smokeOut, !smokeStarted, webView.url?.host == MioShellTheme.host {
            smokeStarted = true
            runSmoke(out)
        }
        guard !coverDone else { return }
        if webView.url?.host != MioShellTheme.host {
            hideCover("external page")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self, !self.sawBoot else { return }
            self.hideCover("page without boot-loader")
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showError(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showError(error)
    }

    private func showError(_ error: Error) {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && (ns.code == 102 || ns.code == 101) { return }
        webView.loadHTMLString(MioShellTheme.errorHTML(ns), baseURL: MioShellTheme.home)
        hideCover("load error")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    // MARK: windows / dialogs

    /// target=_blank / window.open：站外 → 内置浏览器；站内（图片预览等）和登录弹窗 → 同一会话的弹窗
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "http" || scheme == "https" {
            if !Self.hostAllowed(url.host) {
                openExternal(url)
                return nil
            }
            let popup = MioPopupViewController(configuration: configuration)
            let nav = UINavigationController(rootViewController: popup)
            nav.modalPresentationStyle = .formSheet
            MioBrowserViewController.topPresenter(self)?.present(nav, animated: true)
            return popup.webView
        }
        if scheme == "about" || scheme.isEmpty {
            let popup = MioPopupViewController(configuration: configuration)
            let nav = UINavigationController(rootViewController: popup)
            MioBrowserViewController.topPresenter(self)?.present(nav, animated: true)
            return popup.webView
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
        presentAlert(a, fallback: completionHandler)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler(true) })
        presentAlert(a) { completionHandler(false) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let a = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        a.addTextField { $0.text = defaultText }
        a.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(nil) })
        a.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler(a.textFields?.first?.text) })
        presentAlert(a) { completionHandler(nil) }
    }

    private func presentAlert(_ alert: UIAlertController, fallback: @escaping () -> Void) {
        guard let presenter = MioBrowserViewController.topPresenter(self) else {
            fallback()
            return
        }
        presenter.present(alert, animated: true)
    }
}

/// WKUserContentController 强引用 handler：弱引用控制器，避免循环引用
final class MioWeakReplyHandler: NSObject, WKScriptMessageHandlerWithReply {
    weak var target: WKScriptMessageHandlerWithReply?
    init(_ target: WKScriptMessageHandlerWithReply) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        guard let target = target else {
            replyHandler(nil, "gone")
            return
        }
        target.userContentController(userContentController, didReceive: message, replyHandler: replyHandler)
    }
}

/// 主界面的弹窗（站内新窗口 / 登录弹窗）：与主界面同一会话，window.close() 时关闭
final class MioPopupViewController: UIViewController, WKUIDelegate, WKNavigationDelegate {
    let webView: WKWebView
    private var titleObservation: NSKeyValueObservation?

    init(configuration: WKWebViewConfiguration) {
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = MioShellTheme.background
        webView.frame = view.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.uiDelegate = self
        webView.navigationDelegate = self
        view.addSubview(webView)
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(close))
        titleObservation = webView.observe(\.title, options: [.initial, .new]) { [weak self] wv, _ in
            self?.title = wv.title
        }
    }

    @objc private func close() {
        dismiss(animated: true)
    }

    func webViewDidClose(_ webView: WKWebView) {
        close()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, navigationAction.navigationType == .linkActivated,
           let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
           !MioDesktopViewController.hostAllowed(url.host) {
            MioBrowserViewController.open(url, from: self)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}
