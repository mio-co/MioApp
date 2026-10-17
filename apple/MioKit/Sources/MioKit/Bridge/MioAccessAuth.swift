// MioAccessAuth.swift — MioCore 站点挡在 Cloudflare Access 后面时，App 内登录要用到的纯逻辑（只依赖 Foundation，Linux 上单测）。
//
// 流程（与 Safari 相同，全部在当前标签里完成）：
//   mio://home → location.replace(https://mio.300031.xyz/mio/nav)
//     → 302 https://<team>.cloudflareaccess.com/cdn-cgi/access/login/mio.300031.xyz?…&redirect_url=%2Fmio%2Fnav
//     → 身份提供商（Google / GitHub OAuth，或一次性验证码邮件：在 Access 页面里填邮箱 → 收码 → 填码）
//     → https://<team>.cloudflareaccess.com/cdn-cgi/access/callback → https://mio.300031.xyz/cdn-cgi/access/authorized?…
//     → 302 回 redirect_url（/mio/nav），并在 MioCore 域名上设 CF_Authorization（团队域名上也有一份，做单点登录）
//
// 宿主要做的：
//   1. 这些地址一律在当前 WebView 里放行（不当外部 App / 通用链接打开，不弹「在 App 中打开」）：isAuthFlowURL
//   2. 登录页里 window.open / target=_blank 打开的登录地址 → 在打开者标签里继续（popupDisposition == .openerTab）
//   3. 登录页不挂广告拦截规则（MioAdblockModule.shouldApplyContentRules 已处理）
//   4. Google 登录页用 Safari 式 UA（needsSafariUserAgent）：Google 对内嵌 WebView 回 403 disallowed_useragent，
//      对版本号很怪的 UA（例如 FxiOS/0）报「此浏览器不安全」
//   5. Access 的 Cookie 定期备份到钥匙串、启动时补回（MioAccessCookieVault，WebKit 部分）
//   6. CI 冒烟：主页落在 Access 登录页 → homeOK = "access-login"（homeStatus）

import Foundation

public enum MioAccessAuth {
    /// Cloudflare Access 团队域名后缀（<team>.cloudflareaccess.com）
    public static let accessDomainSuffix = ".cloudflareaccess.com"
    /// Access 写在应用域名 / 团队域名上的 Cookie（CF_Authorization = JWT；CF_Binding 可选；CF_AppSession / CF_Session = CSRF）
    public static let cookieNames: Set<String> = ["CF_Authorization", "CF_Binding", "CF_AppSession", "CF_Session", "CF_Device"]
    /// 只有这两个决定「重启后还要不要再登」
    public static let sessionCookieNames: Set<String> = ["CF_Authorization", "CF_Binding"]

    // MARK: - 地址分类

    public static func isAccessHost(_ host: String?) -> Bool {
        guard let h = host?.lowercased(), h.hasSuffix(accessDomainSuffix), h.count > accessDomainSuffix.count else { return false }
        return true
    }

    /// Access 团队域名上的登录 / 回调页（以及应用域名上的 /cdn-cgi/access/*，例如 authorized、logout）
    public static func isAccessURL(_ url: URL?, prefs: MioPrefs? = nil) -> Bool {
        guard let u = url, let s = u.scheme?.lowercased(), s == "https" else { return false }
        if isAccessHost(u.host) { return true }
        if let prefs, MioCoreOrigin.isMioCore(u, prefs: prefs), u.path.hasPrefix("/cdn-cgi/access/") { return true }
        return false
    }

    /// Access 登录页（还没登录、正在让用户选身份提供商 / 填邮箱验证码）
    public static func isAccessLoginPage(_ url: URL?) -> Bool {
        guard let u = url, u.scheme?.lowercased() == "https", isAccessHost(u.host) else { return false }
        let p = u.path.lowercased()
        return p.hasPrefix("/cdn-cgi/access/")
    }

    /// 身份提供商的登录 / 授权页（Access 常用的几家）。只认主机 + 路径前缀，不认整站（github.com 的普通页面不算）
    public static func isIdentityProviderURL(_ url: URL?) -> Bool {
        guard let u = url, u.scheme?.lowercased() == "https", let h = u.host?.lowercased() else { return false }
        let p = u.path.lowercased()
        switch h {
        case "accounts.google.com", "accounts.youtube.com", "oauth2.googleapis.com":
            return true
        case "github.com":
            return p.hasPrefix("/login") || p.hasPrefix("/session") || p.hasPrefix("/sessions/") || p == "/sessions"
        case "login.microsoftonline.com", "login.live.com", "appleid.apple.com":
            return true
        case "gitlab.com":
            return p.hasPrefix("/users/sign_in") || p.hasPrefix("/oauth/")
        default:
            if h.hasSuffix(".okta.com") || h.hasSuffix(".auth0.com") { return true }
            return false
        }
    }

    /// 登录流程里的任何一页：Access + 身份提供商
    public static func isAuthFlowURL(_ url: URL?, prefs: MioPrefs? = nil) -> Bool {
        isAccessURL(url, prefs: prefs) || isIdentityProviderURL(url)
    }

    // MARK: - 弹窗

    public enum PopupDisposition: Equatable {
        /// 照常开新标签（保留 window.opener：第三方网站的「用 Google 登录」弹窗靠 postMessage 回传）
        case newTab
        /// 在打开者标签里继续（Access 登录页 / MioCore 打开的登录地址）
        case openerTab
    }

    /// window.open / target=_blank：打开者是 Access 登录页或 MioCore（含 mio:// 内置页），目标又是登录流程 → 打开者标签里继续。
    /// Access 的流程全是整页跳转，最后回到 redirect_url；放进新标签反而会让原标签停在登录页。
    public static func popupDisposition(opener: URL?, target: URL?, prefs: MioPrefs) -> PopupDisposition {
        guard isAuthFlowURL(target, prefs: prefs) else { return .newTab }
        if isAccessURL(opener, prefs: prefs) { return .openerTab }
        if let o = opener, MioCoreOrigin.isMioCore(o, prefs: prefs) || MioHomeModel.isInternal(o) { return .openerTab }
        return .newTab
    }

    // MARK: - UA

    /// 这些页面要用 Safari 式 UA（宿主自己的 UA 带 FxiOS/x 或没有 Safari 标记时 Google 会拒绝登录）
    public static func needsSafariUserAgent(_ url: URL?) -> Bool {
        guard let u = url, let h = u.host?.lowercased() else { return false }
        return h == "accounts.google.com" || h == "accounts.youtube.com"
    }

    /// iOS / iPadOS 的 Safari UA（与系统版本一致，不带 FxiOS / Mio 标记）
    public static func mobileSafariUserAgent(iOSVersion: String, iPad: Bool, safariVersion: String? = nil) -> String {
        let v = iOSVersion.split(separator: ".").prefix(2).joined(separator: "_")
        let ver = safariVersion ?? iOSVersion.split(separator: ".").prefix(2).joined(separator: ".")
        if iPad {
            // iPadOS 默认请求桌面网站：Safari 也报 Macintosh
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(ver) Safari/605.1.15"
        }
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(v) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(ver) Mobile/15E148 Safari/604.1"
    }

    // MARK: - 冒烟

    /// 打开 mio://home 后落地页的分类：ok（MioCore 首页）/ access-login（Access 登录页，CI 上没登录，不算失败）/ other
    public static func homeStatus(landedOn url: URL?, home: MioHomeModel) -> String {
        guard let u = url else { return "none" }
        if home.isHome(u) || (MioCoreOrigin.isMioCore(u, prefs: home.prefs) && !u.path.hasPrefix("/cdn-cgi/")) { return "ok" }
        if isAccessURL(u, prefs: home.prefs) || isIdentityProviderURL(u) { return "access-login" }
        return "other"
    }

    // MARK: - Cookie 备份（纯数据；WebKit 读写见 MioAccessCookieVault）

    /// MioCore 主机或 Access 团队域名上的 Cookie（迁移旧数据存储时整站搬过来，MioCore 自己的会话 Cookie 也要）
    public static func isMioCoreOrAccessDomain(_ domain: String, prefs: MioPrefs) -> Bool {
        var d = domain.lowercased()
        if d.hasPrefix(".") { d.removeFirst() }
        return isAccessHost(d) || d == MioCoreOrigin.configured(prefs).host
    }

    /// 只备份 Access 的 Cookie：名字在 cookieNames 里，且域名是 MioCore 主机或 *.cloudflareaccess.com
    public static func shouldBackUp(name: String, domain: String, prefs: MioPrefs) -> Bool {
        guard cookieNames.contains(name) else { return false }
        var d = domain.lowercased()
        if d.hasPrefix(".") { d.removeFirst() }
        if isAccessHost(d) { return true }
        return d == MioCoreOrigin.configured(prefs).host
    }
}

/// 一条 Cookie 的可序列化快照（不依赖 HTTPCookie，Linux 上也能单测）
public struct MioAccessCookie: Codable, Equatable {
    public var name: String
    public var value: String
    public var domain: String
    public var path: String
    /// nil = 会话 Cookie（不备份：重启本来就该丢）
    public var expires: Date?
    public var secure: Bool
    public var httpOnly: Bool
    public var sameSite: String?

    public init(name: String, value: String, domain: String, path: String = "/", expires: Date?, secure: Bool = true,
                httpOnly: Bool = true, sameSite: String? = nil) {
        self.name = name; self.value = value; self.domain = domain; self.path = path; self.expires = expires
        self.secure = secure; self.httpOnly = httpOnly; self.sameSite = sameSite
    }

    var key: String { "\(domain.lowercased())|\(path)|\(name)" }

    public func isValid(at now: Date) -> Bool {
        guard let e = expires else { return false }
        return e > now.addingTimeInterval(60)
    }
}

public enum MioAccessCookieSet {
    /// 从数据存储里的全部 Cookie 里挑出要备份的（有过期时间、没过期）
    public static func select(_ all: [MioAccessCookie], prefs: MioPrefs, now: Date = Date()) -> [MioAccessCookie] {
        var out: [String: MioAccessCookie] = [:]
        for c in all where MioAccessAuth.shouldBackUp(name: c.name, domain: c.domain, prefs: prefs) && c.isValid(at: now) {
            out[c.key] = c
        }
        return out.values.sorted { $0.key < $1.key }
    }

    /// 启动时要补回的：备份里还有效、数据存储里没有（或数据存储里那条已经过期）的
    public static func missing(saved: [MioAccessCookie], present: [MioAccessCookie], prefs: MioPrefs, now: Date = Date()) -> [MioAccessCookie] {
        let have = Dictionary(present.filter { $0.expires == nil || $0.isValid(at: now) }.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        return select(saved, prefs: prefs, now: now).filter { have[$0.key] == nil }
    }

    public static func encode(_ cookies: [MioAccessCookie]) -> String? {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        guard let d = try? e.encode(cookies) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    public static func decode(_ s: String?) -> [MioAccessCookie] {
        guard let s, let d = s.data(using: .utf8) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return (try? dec.decode([MioAccessCookie].self, from: d)) ?? []
    }
}
