// MioAdblockProbe.swift — 广告拦截的端到端自检（CI 冒烟用：Mac 原生壳、iOS 模拟器、MioKit macOS 单测）：
//   1. 规则数：订阅下载 + 编译完成，内容规则 > minContentRules（默认 1 万）
//   2. 网络拦截：页面里 fetch 广告地址（doubleclick / googlesyndication）被拦，同源对照请求正常
//   3. 元素隐藏（## → css-display-none）：测试页里放 AdGuard Base 的通用隐藏选择器（#ad_banner、.banner-ad-container …），至少一个被隐藏，对照元素可见
//   4. scriptlet：从已下载列表的高级规则里挑一条单域名 set-constant（例如 reporterpb.com.br#%#//scriptlet('set-constant','showModal','noopFunc')），
//      在该域名下载入测试页，检查 window 上的属性被改了
// 也给真实网站打分（adblock.turtlecute.org：页面里逐个请求广告 / 跟踪域名，统计被拦的比例）。

#if canImport(WebKit)
import Foundation
import WebKit
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@MainActor
public enum MioAdblockProbe {
    public static let probeBase = URL(string: "https://example.com/mio-adblock-probe")!
    /// AdGuard Base 里的通用元素隐藏选择器（任何网站都隐藏）；列表会变，所以只要求至少一个生效
    public static let genericHideIDs = ["ad_banner"]
    public static let genericHideClasses = ["banner-ad-container", "adsbox970x90", "banner-advert", "adsbygoogle-wrapper"]
    public static let adURLs = [
        "https://securepubads.g.doubleclick.net/tag/js/gpt.js",
        "https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js",
    ]

    public static var probeHTML: String {
        let ids = genericHideIDs.map { "<div id=\"\($0)\" class=\"probe\">ad #\($0)</div>" }.joined()
        let classes = genericHideClasses.map { "<div class=\"\($0) probe\">ad .\($0)</div>" }.joined()
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width"><title>Mio adblock probe</title>
        <style>body{font:14px -apple-system,sans-serif;padding:12px}.probe{padding:8px;margin:4px 0;background:#fdd}#mio-control{background:#dfd;padding:8px}</style></head>
        <body><h3>Mio adblock probe</h3>\(ids)\(classes)<div id="mio-control">control (must stay visible)</div></body></html>
        """
    }

    static let probeJS = """
    async function hit(u) {
      try { await fetch(u, { mode: 'no-cors', cache: 'no-store' }); return 'loaded'; }
      catch (e) { return 'blocked:' + (e && e.message ? e.message : String(e)); }
    }
    const vis = (el) => !!el && getComputedStyle(el).display !== 'none' && el.getBoundingClientRect().height > 0;
    const ads = {};
    for (const u of AD_URLS) ads[u] = await hit(u + '?mio=' + Date.now());
    const control = await hit(location.origin + '/?mio-control=' + Date.now());
    const hidden = {};
    for (const el of document.querySelectorAll('.probe')) hidden[el.id ? '#' + el.id : '.' + el.classList[0]] = !vis(el);
    return JSON.stringify({ ads, control, hidden, controlVisible: vis(document.getElementById('mio-control')) });
    """

    /// 等订阅下载 + 编译完（内容规则数达到 minContentRules，或没有在忙且所有订阅都试过）
    public static func waitForRules(_ blocker: MioContentBlocker, minContentRules: Int, timeout: TimeInterval) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            let s = blocker.manager.summary()
            if s.contentRules >= minContentRules && !blocker.isBusy { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return blocker.manager.summary().contentRules >= minContentRules
    }

    /// 已下载列表的高级规则里挑一条可在测试页验证的 set-constant（单个具体域名、简单属性名、值有明确类型）
    public static func pickSetConstant(_ advancedText: String) -> (domain: String, property: String, value: String, jsType: String)? {
        let types = ["true": "boolean", "false": "boolean", "noopFunc": "function", "trueFunc": "function", "falseFunc": "function",
                     "null": "object", "0": "number", "1": "number", "emptyArr": "object", "emptyObj": "object"]
        let re = try? NSRegularExpression(pattern: #"^([a-z0-9-]+(?:\.[a-z0-9-]+)+)#%#//scriptlet\('set-constant', '([A-Za-z_$][A-Za-z0-9_$]*)', '([A-Za-z0-9]+)'\)$"#)
        for line in MioFilterText.lines(advancedText) {
            let ns = line as NSString
            guard let m = re?.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges == 4 else { continue }
            let value = ns.substring(with: m.range(at: 3))
            guard let t = types[value] else { continue }
            return (ns.substring(with: m.range(at: 1)), ns.substring(with: m.range(at: 2)), value, t)
        }
        return nil
    }

    /// 端到端自检。load(html, baseURL) 由调用方提供：独立 WebView（standaloneLoader）或 App 里真实标签（iOS：tab.webView.loadHTMLString，
    /// 宿主自己的导航回调会调 willNavigateMainFrame，走的是真实路径）
    public static func run(blocker: MioContentBlocker, webView wv: WKWebView, minContentRules: Int = 10_000,
                           load: (String, URL) async -> Void) async -> [String: Any] {
        var r: [String: Any] = [:]
        let s = blocker.manager.summary()
        r["contentRules"] = s.contentRules
        r["advancedRules"] = s.advancedRules
        r["skipped"] = s.skipped
        r["compiledLists"] = s.compiledLists
        r["lists"] = s.lists
        r["missing"] = s.missing
        r["errors"] = s.errors
        r["ruleListIdentifiers"] = blocker.ruleLists.keys.sorted()
        r["status"] = blocker.manager.statusText()
        r["details"] = blocker.manager.listDetails()
        let rulesOK = s.contentRules >= minContentRules
        r["rulesOK"] = rulesOK

        // 网络拦截 + 元素隐藏
        await load(probeHTML, probeBase)
        try? await Task.sleep(nanoseconds: 700_000_000)
        let js = probeJS.replacingOccurrences(of: "AD_URLS", with: MioJSString.json(adURLs))
        let raw = await MioWebViewModules.callAsync(wv, js, arguments: [:], world: .page) as? String ?? "{}"
        let probe = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? ["raw": raw]
        r["probe"] = probe
        let ads = probe["ads"] as? [String: String] ?? [:]
        let blockedOK = !ads.isEmpty && ads.values.allSatisfy { $0.hasPrefix("blocked") } && (probe["control"] as? String) == "loaded"
        let hidden = probe["hidden"] as? [String: Bool] ?? [:]
        let hideOK = hidden.values.contains(true) && (probe["controlVisible"] as? Bool) == true
        r["blockedOK"] = blockedOK
        r["hideOK"] = hideOK

        // scriptlet（真实列表里的 set-constant）
        let advText = MioFilterCatalog.enabledLists(blocker.manager.prefs)
            .compactMap { try? String(contentsOf: blocker.manager.advancedURL($0), encoding: .utf8) }.joined(separator: "\n")
        var scriptletOK = false
        if let pick = pickSetConstant(advText), let base = URL(string: "https://\(pick.domain)/mio-adblock-probe") {
            r["scriptletRule"] = "\(pick.domain)#%#//scriptlet('set-constant', '\(pick.property)', '\(pick.value)')"
            r["scriptletInjectable"] = blocker.pageScript(for: base, topURL: nil) != nil
            await load("<!doctype html><html><body><p id=s>scriptlet probe</p></body></html>", base)
            try? await Task.sleep(nanoseconds: 500_000_000)
            let t = await MioWebViewModules.callAsync(wv, "return typeof window[\(MioJSString.literal(pick.property))];", arguments: [:], world: .page) as? String
            r["scriptletType"] = t.map { $0 as Any } ?? NSNull()
            scriptletOK = t == pick.jsType
        } else {
            r["scriptletRule"] = NSNull()
        }
        r["scriptletOK"] = scriptletOK
        r["ok"] = rulesOK && blockedOK && hideOK && scriptletOK
        return r
    }

    // MARK: 独立 WebView（Mac 冒烟 / 单测）

    public final class Loader: NSObject, WKNavigationDelegate {
        var cont: CheckedContinuation<Void, Never>?
        public func webView(_ w: WKWebView, didFinish n: WKNavigation!) { cont?.resume(); cont = nil }
        public func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { cont?.resume(); cont = nil }
        public func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { cont?.resume(); cont = nil }
    }

    /// 一个装好 MioKit 模块 + 广告拦截规则的独立 WebView，以及载入函数（导航前调 willNavigateMainFrame，与宿主相同）
    public static func standalone(kit: MioKitContainer, blocker: MioContentBlocker,
                                  frame: CGRect = CGRect(x: 0, y: 0, width: 1100, height: 1400)) -> (WKWebView, MioWebViewModules, Loader) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let mods = MioWebViewModules(kit: kit, controller: config.userContentController, blocker: blocker)
        mods.install()
        let wv = WKWebView(frame: frame, configuration: config)
        mods.webView = wv
        let loader = Loader()
        wv.navigationDelegate = loader
        return (wv, mods, loader)
    }

    public static func loadHTML(_ wv: WKWebView, _ mods: MioWebViewModules, _ loader: Loader, html: String, base: URL) async {
        mods.willNavigateMainFrame(to: base)
        await withCheckedContinuation { c in loader.cont = c; wv.loadHTMLString(html, baseURL: base) }
    }

    public static func loadURL(_ wv: WKWebView, _ mods: MioWebViewModules, _ loader: Loader, url: URL, timeout: TimeInterval = 60) async {
        mods.willNavigateMainFrame(to: url)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            loader.cont = c
            wv.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout))
        }
    }

    // MARK: 真实网站打分

    public static let scoreSite = URL(string: "https://adblock.turtlecute.org/")!

    /// adblock.turtlecute.org：页面载入后自动逐个请求广告 / 跟踪域名（.test 方块绿 = 被拦，红 = 没拦）。等测完后数一下
    public static func turtlecuteScore(_ wv: WKWebView, settle: TimeInterval = 45) async -> [String: Any] {
        let end = Date().addingTimeInterval(settle)
        var last: [String: Any] = [:]
        var stable = 0
        while Date() < end {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let raw = await MioWebViewModules.callAsync(wv, """
            const tests = Array.from(document.querySelectorAll('#test .test'));
            const failed = tests.filter(t => t.dataset.hasFailure === 'true').length;
            const pending = tests.filter(t => t.querySelector('div') && t.querySelector('div').childNodes.length === 0).length;
            const v = document.querySelector('.lt_value');
            return JSON.stringify({ total: tests.length, notBlocked: failed, pending, value: v ? v.textContent.trim() : null, title: document.title });
            """, arguments: [:], world: .page) as? String ?? "{}"
            let d = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? ["raw": raw]
            if let a = d["total"] as? Int, a > 0, (d["total"] as? Int) == (last["total"] as? Int), (d["notBlocked"] as? Int) == (last["notBlocked"] as? Int) {
                stable += 1
            } else { stable = 0 }
            last = d
            if stable >= 3 { break }
        }
        if let total = last["total"] as? Int, total > 0, let nb = last["notBlocked"] as? Int {
            last["blocked"] = total - nb
            last["score"] = Int((Double(total - nb) / Double(total) * 100).rounded())
        }
        return last
    }

    /// WebView 截图 → PNG
    public static func snapshotPNG(_ wv: WKWebView) async -> Data? {
        await withCheckedContinuation { (c: CheckedContinuation<Data?, Never>) in
            wv.takeSnapshot(with: nil) { image, _ in
                #if os(macOS)
                guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { c.resume(returning: nil); return }
                c.resume(returning: rep.representation(using: .png, properties: [:]))
                #else
                c.resume(returning: image?.pngData())
                #endif
            }
        }
    }
}
#endif
