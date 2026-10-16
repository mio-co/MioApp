import UIKit
import Capacitor
import WebKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Override point for customization after application launch.
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

// MARK: - Mio: navigation error filtering

/// Capacitor 默认在任何加载失败时都跳 errorPath，包括 Cloudflare Access 跳转时
/// 常见的「已取消」(-999) 和「因策略中断」(WebKit 102)。这里只对真正的网络错误显示提示页。
final class MioBridgeViewController: CAPBridgeViewController {
    private var navProxy: MioNavigationProxy?

    override func capacitorDidLoad() {
        super.capacitorDidLoad()
        guard let webView = webView, let original = webView.navigationDelegate else { return }
        let proxy = MioNavigationProxy(original: original)
        navProxy = proxy
        webView.navigationDelegate = proxy
    }
}

final class MioNavigationProxy: NSObject, WKNavigationDelegate {
    private weak var original: WKNavigationDelegate?
    static let home = URL(string: "https://mio.300031.xyz/")!

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

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handle(webView, error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
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
        <style>body{font-family:-apple-system;padding:48px 24px;color:#1f2937}
        a{display:inline-block;margin-top:16px;padding:10px 20px;background:#f0a3bf;color:#fff;border-radius:10px;text-decoration:none}
        code{font-size:12px;color:#6b7280;word-break:break-all}</style></head>
        <body><h3>加载失败</h3><p>\(esc(ns.localizedDescription))</p>
        <p><code>\(esc(ns.domain)) \(ns.code)<br>\(esc(failing))</code></p>
        <a href="\(MioNavigationProxy.home.absoluteString)">重试</a></body></html>
        """
        webView.loadHTMLString(html, baseURL: MioNavigationProxy.home)
    }
}
