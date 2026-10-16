import UIKit
import Capacitor
import WebKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // 内置浏览器广告拦截：后台刷新任务必须在启动结束前注册；规则加载 / 首次编译在后台队列
        MioAdblockBackground.register()
        MioAdblock.shared.start()
        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {
        // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
        // Use this method to pause ongoing tasks, disable timers, and invalidate graphics rendering callbacks. Games should use this method to pause the game.
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
        // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        // Called as part of the transition from the background to the active state; here you can undo many of the changes made on entering the background.
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default Configuration",
                                          sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

// MARK: - Mio: theme

enum MioShellTheme {
    /// 与启动屏（LaunchScreen.storyboard）和站点首屏一致：浅色 #ffffff，深色 #0a0a0a（Assets 里的 MioLaunchBackground）
    static let background: UIColor = UIColor(named: "MioLaunchBackground") ?? UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 10 / 255, green: 10 / 255, blue: 10 / 255, alpha: 1) : .white
    }
    static let host = "mio.300031.xyz"
    /// App 直接打开后台导航页（Capacitor server.appStartPath = mio/nav），不经过首页 / 的 302
    static let home = URL(string: "https://mio.300031.xyz/mio/nav")!
}

// MARK: - Mio: launch cover

/// 原生启动遮罩：与 LaunchScreen.storyboard 同色、同 Logo、同位置，盖在 WKWebView 上，
/// 直到网页的首屏加载动画淡出（boot-loader.js 发 mioShell 'ready'）。避免冷启动时露出 WebView 首帧前的黑底。
final class MioLaunchCover: UIView {
    private let spinner = UIActivityIndicatorView(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = MioShellTheme.background
        isUserInteractionEnabled = true

        let logo = UIImageView(image: UIImage(named: "MioLaunchLogo"))
        logo.contentMode = .scaleAspectFit
        logo.translatesAutoresizingMaskIntoConstraints = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        addSubview(logo)
        addSubview(spinner)
        NSLayoutConstraint.activate([
            logo.centerXAnchor.constraint(equalTo: centerXAnchor),
            logo.centerYAnchor.constraint(equalTo: centerYAnchor),
            logo.widthAnchor.constraint(equalToConstant: 160),
            logo.heightAnchor.constraint(equalToConstant: 160),
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.topAnchor.constraint(equalTo: logo.bottomAnchor, constant: 16)
        ])
        // 超过 0.8 秒还没好才显示转圈，正常冷启动看到的只是一张静止的启动屏
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self = self, self.superview != nil else { return }
            self.spinner.startAnimating()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// WKUserContentController 会强引用 handler，这里弱引用控制器，避免循环引用
final class MioWeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

// MARK: - Mio: bridge view controller

final class MioBridgeViewController: CAPBridgeViewController, WKScriptMessageHandler {
    private var navProxy: MioNavigationProxy?
    private var cover: MioLaunchCover?
    private var coverDone = false
    /// 当前主文档是否运行了站点的 boot-loader.js（收到 'boot'）；每次 didCommit 重置
    private var sawBoot = false
    private let startedAt = CACurrentMediaTime()
    /// 网页一直没发 'ready'（旧版站点 / 脚本被拦截）时的兜底：最多盖这么久
    private static let coverTimeout: TimeInterval = 8

    override func capacitorDidLoad() {
        super.capacitorDidLoad()
        // App 内置浏览器（Capacitor.Plugins.MioBrowser）：MioCore 页面里点外链时调用
        bridge?.registerPluginInstance(MioBrowserPlugin())
        guard let webView = webView else { return }
        // WKWebView 首帧前（Capacitor 首次加载时还会把它设为不透明=false）露出的底色：跟站点主题一致，不是黑色
        let background = MioShellTheme.background
        webView.backgroundColor = background
        webView.scrollView.backgroundColor = background
        if #available(iOS 15.0, *) {
            webView.underPageBackgroundColor = background
        }
        webView.configuration.userContentController.add(MioWeakScriptHandler(self), name: "mioShell")

        if let original = webView.navigationDelegate {
            let proxy = MioNavigationProxy(original: original)
            proxy.owner = self
            navProxy = proxy
            webView.navigationDelegate = proxy
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let cover = MioLaunchCover(frame: view.bounds)
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(cover)
        self.cover = cover
        DispatchQueue.main.asyncAfter(deadline: .now() + MioBridgeViewController.coverTimeout) { [weak self] in
            self?.hideCover("timeout")
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let cover = cover, cover.superview === view {
            view.bringSubviewToFront(cover)
            cover.frame = view.bounds
        }
    }

    func hideCover(_ reason: String) {
        guard !coverDone, let cover = cover else { return }
        coverDone = true
        let ms = Int((CACurrentMediaTime() - startedAt) * 1000)
        print("⚡️ Mio launch cover hidden (\(reason)) at +\(ms) ms after bridge view load")
        UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: {
            cover.alpha = 0
        }, completion: { _ in
            cover.removeFromSuperview()
            self.cover = nil
        })
    }

    // 网页（public/boot-loader.js）→ App：boot / ready / failed
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "mioShell" else { return }
        let body = message.body as? [String: Any]
        let type = (body?["type"] as? String) ?? (message.body as? String) ?? ""
        let ms = Int((CACurrentMediaTime() - startedAt) * 1000)
        print("⚡️ Mio shell message \(type) \(body?["path"] as? String ?? "") at +\(ms) ms")
        switch type {
        case "boot": sawBoot = true
        case "ready", "failed": hideCover(type)
        default: break
        }
    }

    // 以下由 MioNavigationProxy 调用
    func navigationDidCommit() {
        sawBoot = false
    }

    func navigationDidFinish(_ url: URL?) {
        guard !coverDone else { return }
        // Cloudflare Access / Google / GitHub 登录页等站外页面：没有 boot-loader，加载完就露出来
        if url?.host != MioShellTheme.host {
            hideCover("external page \(url?.host ?? "?")")
            return
        }
        // 站内页面但没有运行 boot-loader.js（Worker 的错误页、旧版站点）：稍等一下 'boot' 消息，仍没有就露出来
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self, !self.sawBoot else { return }
            self.hideCover("page without boot-loader")
        }
    }

    func navigationDidShowError() {
        hideCover("load error")
    }
}

// MARK: - Mio: navigation error filtering

/// Capacitor 默认在任何加载失败时都跳 errorPath，包括 Cloudflare Access 跳转时
/// 常见的「已取消」(-999) 和「因策略中断」(WebKit 102)。这里只对真正的网络错误显示提示页。
/// 其余代理方法原样转发给 Capacitor 的 WebViewDelegationHandler。
final class MioNavigationProxy: NSObject, WKNavigationDelegate {
    private weak var original: WKNavigationDelegate?
    weak var owner: MioBridgeViewController?

    init(original: WKNavigationDelegate) {
        self.original = original
        super.init()
    }

    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return original?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let original = original, original.responds(to: aSelector) { return original }
        return super.forwardingTarget(for: aSelector)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        original?.webView?(webView, didCommit: navigation)
        owner?.navigationDidCommit()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        original?.webView?(webView, didFinish: navigation)
        owner?.navigationDidFinish(webView.url)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        // 转发给 Capacitor：恢复首次加载时改掉的 isOpaque（没有配置 errorPath，不会再跳错误页）
        original?.webView?(webView, didFail: navigation, withError: error)
        handle(webView, error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        original?.webView?(webView, didFailProvisionalNavigation: navigation, withError: error)
        handle(webView, error)
    }

    private func handle(_ webView: WKWebView, _ error: Error) {
        let ns = error as NSError
        print("⚡️ Mio navigation error: \(ns.domain) \(ns.code) \(ns.localizedDescription)")
        // 被取消 / 被策略中断：不是网络问题，忽略
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain" && (ns.code == 102 || ns.code == 101) { return }

        let failing = (ns.userInfo[NSURLErrorFailingURLStringErrorKey] as? String) ?? ""
        let esc = { (s: String) in
            s.replacingOccurrences(of: "&", with: "&amp;")
             .replacingOccurrences(of: "<", with: "&lt;")
             .replacingOccurrences(of: ">", with: "&gt;")
        }
        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <style>body{font-family:-apple-system;padding:48px 24px;color:#1f2937;background:#ffffff}
        @media (prefers-color-scheme: dark){body{color:#e5e7eb;background:#0a0a0a}}
        a{display:inline-block;margin-top:16px;padding:10px 20px;background:#f0a3bf;color:#fff;border-radius:10px;text-decoration:none}
        code{font-size:12px;color:#6b7280;word-break:break-all}</style></head>
        <body><h3>加载失败</h3><p>\(esc(ns.localizedDescription))</p>
        <p><code>\(esc(ns.domain)) \(ns.code)<br>\(esc(failing))</code></p>
        <a href="\(MioShellTheme.home.absoluteString)">重试</a></body></html>
        """
        webView.loadHTMLString(html, baseURL: MioShellTheme.home)
        owner?.navigationDidShowError()
    }
}
