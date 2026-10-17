// MioHome.swift — 内置地址 mio://home（主页 + 新标签页）的模型。只依赖 Foundation；WKURLSchemeHandler 见 MioSchemeHandler.swift。
//
// 行为：
//   mio://home       → 本地小页面，立刻 location.replace 到 MioCore 首页（默认 https://mio.300031.xyz/mio/nav，不留历史记录）
//                      地址栏显示「Mio」：宿主对 mio://home 和 MioCore 首页地址都调用 addressBarText(for:)
//   mio://offline    → 打不开 MioCore 时的离线页（宿主在 didFailProvisionalNavigation 里 load offlineURL(failed:)）
//   mio://about      → 版本 / 许可（MPL-2.0 声明、源码地址）
// 为什么不用 iframe 嵌 MioCore：WebKit 会把 iframe 里的 MioCore 当第三方，登录 Cookie 被 ITP 拦掉。
// 迁移：v0.3.x 的 mio.tabs.newTabURL 若是用户自定义的非 MioCore 地址，新标签页继续用它；否则用 mio://home。

import Foundation

public struct MioHomeModel {
    public static let scheme = "mio"
    public static let homeURL = URL(string: "mio://home")!
    public static let offlineBase = URL(string: "mio://offline")!
    public static let aboutURL = URL(string: "mio://about")!
    public static let homePathKey = "mio.core.homePath"
    public static let defaultHomePath = "/mio/nav"
    /// v0.3.x key
    public static let legacyNewTabKey = "mio.tabs.newTabURL"
    public static let displayTitle = "Mio"

    public let prefs: MioPrefs
    public var appVersion: String
    public init(prefs: MioPrefs, appVersion: String = "0.4.0") { self.prefs = prefs; self.appVersion = appVersion }

    /// mio://home 跳转的目标（MioCore 首页）
    public var targetURL: URL {
        var path = prefs.string(Self.homePathKey, default: Self.defaultHomePath)
        if !path.hasPrefix("/") { path = "/" + path }
        if path.contains("//") || path.contains("..") { path = Self.defaultHomePath }
        return URL(string: MioCoreOrigin.configured(prefs).description + path) ?? URL(string: MioCoreOrigin.defaultOrigin + Self.defaultHomePath)!
    }

    /// 新标签页 / 主页地址：默认 mio://home；v0.3.x 用户自定义过别的网站则沿用
    public var newTabURL: URL {
        if let legacy = MioTabStore.normalizeNewTabURL(prefs.object(forKey: Self.legacyNewTabKey) as? String),
           legacy != MioTabStore.defaultNewTabURL, let u = URL(string: legacy), !MioCoreOrigin.isMioCore(u, prefs: prefs) {
            return u
        }
        return Self.homeURL
    }

    public static func isInternal(_ url: URL?) -> Bool { url?.scheme?.lowercased() == scheme }

    public func isHome(_ url: URL?) -> Bool {
        guard let u = url else { return false }
        if Self.isInternal(u) { return u.host?.lowercased() == "home" }
        return Self.sameIgnoringTrailingSlash(u, targetURL)
    }

    /// 地址栏显示：主页 → 「Mio」（编辑时宿主显示空 / 原地址都行）；其他 mio:// → mio://xxx；普通网页 → nil（宿主照常显示）
    public func addressBarText(for url: URL?) -> String? {
        guard let u = url else { return nil }
        if isHome(u) { return Self.displayTitle }
        if Self.isInternal(u) { return u.absoluteString }
        return nil
    }

    public func offlineURL(failed: URL?) -> URL {
        var c = URLComponents(url: Self.offlineBase, resolvingAgainstBaseURL: false)!
        if let f = failed?.absoluteString { c.queryItems = [URLQueryItem(name: "url", value: f)] }
        return c.url!
    }

    static func sameIgnoringTrailingSlash(_ a: URL, _ b: URL) -> Bool {
        func n(_ u: URL) -> String {
            var c = URLComponents(url: u, resolvingAgainstBaseURL: false)
            c?.fragment = nil
            c?.query = nil
            var s = c?.string?.lowercased() ?? u.absoluteString.lowercased()
            while s.hasSuffix("/") { s.removeLast() }
            return s
        }
        return n(a) == n(b)
    }

    // MARK: - 路由（scheme handler 用；纯函数，单测覆盖）

    public struct Response: Equatable {
        public let statusCode: Int
        public let mimeType: String
        public let body: Data
        public var headers: [String: String] {
            ["Content-Type": mimeType + "; charset=utf-8", "Cache-Control": "no-store",
             "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'"]
        }
    }

    public func response(for url: URL) -> Response {
        guard Self.isInternal(url) else { return page(404, "未找到", "<p>不是 Mio 内置地址。</p>") }
        switch url.host?.lowercased() ?? "" {
        case "home":
            let target = targetURL.absoluteString
            let js = Self.jsString(target)
            let body = """
            <!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
            <title>\(Self.displayTitle)</title><meta name="color-scheme" content="light dark">
            <style>html,body{margin:0;height:100%;font:15px -apple-system,system-ui,sans-serif;display:flex;align-items:center;justify-content:center;color:#888}</style>
            <script>location.replace(\(js));</script></head><body>正在打开 Mio…</body></html>
            """
            return Response(statusCode: 200, mimeType: "text/html", body: Data(body.utf8))
        case "offline":
            let failed = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "url" }?.value
            let retry = failed.flatMap { MioCoreBridge.openableURL($0) }?.absoluteString ?? Self.homeURL.absoluteString
            let html = """
            <h1>Mio 暂时打不开</h1><p>无法连接到 \(Self.htmlEscape(MioCoreOrigin.configured(prefs).description))。检查网络后重试。</p>
            <p><a id="retry" href="\(Self.htmlEscape(retry))">重试</a></p>
            """
            return page(200, "Mio · 离线", html)
        case "about":
            let html = """
            <h1>Mio \(Self.htmlEscape(appVersion))</h1>
            <p>基于 Mozilla Firefox for iOS 源码修改（iOS 版），以 Mozilla Public License 2.0 发布；源码：<a href="https://github.com/mio-co/MioApp">github.com/mio-co/MioApp</a>。</p>
            <p>Mio 与 Mozilla 无关，未获 Mozilla 认可。广告拦截规则转换使用 AdGuard SafariConverterLib（GPL-3.0）；SponsorBlock 数据来自 sponsor.ajay.app（CC BY-NC-SA 4.0）。</p>
            """
            return page(200, "关于 Mio", html)
        default:
            return page(404, "未找到", "<p>没有这个页面：\(Self.htmlEscape(url.absoluteString))</p>")
        }
    }

    func page(_ code: Int, _ title: String, _ inner: String) -> Response {
        let html = """
        <!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="color-scheme" content="light dark"><title>\(Self.htmlEscape(title))</title>
        <style>body{font:16px -apple-system,system-ui,sans-serif;max-width:40em;margin:12vh auto;padding:0 1.2em;line-height:1.6}h1{font-size:1.4em}</style>
        </head><body>\(inner)</body></html>
        """
        return Response(statusCode: code, mimeType: "text/html", body: Data(html.utf8))
    }

    static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }

    static func jsString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        var t = String(data: data, encoding: .utf8) ?? "[\"\"]"
        t = String(t.dropFirst().dropLast())
        return t.replacingOccurrences(of: "</", with: "<\\/")
    }
}
