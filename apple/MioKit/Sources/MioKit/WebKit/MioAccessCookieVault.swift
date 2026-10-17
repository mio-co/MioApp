// MioAccessCookieVault.swift — Cloudflare Access 登录 Cookie 的钥匙串备份（重启后不用再登）。
//
// WKWebView 的持久数据存储会把带过期时间的 Cookie 写盘，但写盘是异步、延迟的：登录后几秒内 App 被划掉 / 崩溃，
// 新 Cookie 可能还没落盘，下次启动又被 Access 拦到登录页。这里在「登录完成回到 MioCore」和「进入后台」时
// 把 Access 的 Cookie（CF_Authorization / CF_Binding / CF_AppSession…，只限 MioCore 主机和 *.cloudflareaccess.com）
// 存进钥匙串（MioKeychainSecretStore，名字 access.cookies），App 启动时先补回数据存储里缺的、还没过期的。
// 会话 Cookie（没有过期时间）不备份；过期的自动丢掉；退出登录（/cdn-cgi/access/logout）后清空备份。
// 只用默认容器的数据存储（MioCore 永远在默认容器里打开；无痕 / 其他容器不备份）。

#if canImport(WebKit)
import Foundation
import WebKit

@MainActor
public final class MioAccessCookieVault {
    public static let secretName = "access.cookies"

    let prefs: MioPrefs
    let secrets: MioSecretStore
    let store: @MainActor () -> WKWebsiteDataStore

    public init(prefs: MioPrefs, secrets: MioSecretStore = MioKeychainSecretStore.shared, store: @escaping @MainActor () -> WKWebsiteDataStore) {
        self.prefs = prefs
        self.secrets = secrets
        self.store = store
    }

    public var savedCount: Int { MioAccessCookieSet.decode(secrets.secret(Self.secretName)).count }

    /// 启动时调用（第一个标签载入之前越早越好）：补回数据存储里缺的 Access Cookie。返回补回的条数
    @discardableResult
    public func restore() async -> Int {
        let saved = MioAccessCookieSet.decode(secrets.secret(Self.secretName))
        guard !saved.isEmpty else { return 0 }
        let cookieStore = store().httpCookieStore
        let present = await cookieStore.allCookies().map(Self.snapshot)
        let missing = MioAccessCookieSet.missing(saved: saved, present: present, prefs: prefs)
        for c in missing {
            if let hc = Self.cookie(c) { await cookieStore.setCookie(hc) }
        }
        return missing.count
    }

    /// 备份当前有效的 Access Cookie（登录完成、进入后台时调用）。返回备份条数
    @discardableResult
    public func backUp() async -> Int {
        let all = await store().httpCookieStore.allCookies().map(Self.snapshot)
        let keep = MioAccessCookieSet.select(all, prefs: prefs)
        let hasSession = keep.contains { MioAccessAuth.sessionCookieNames.contains($0.name) }
        // 没有登录态（已退出 / 过期）→ 清空备份，避免把旧 Cookie 补回去
        secrets.setSecret(Self.secretName, hasSession ? MioAccessCookieSet.encode(keep) : nil)
        return hasSession ? keep.count : 0
    }

    /// 一次性迁移：把另一个数据存储（例如 v0.3.x Mac Catalyst 主界面用的 .default()）里 MioCore / Access 域名上的 Cookie
    /// 复制到当前存储（只补当前没有的、没过期的、带过期时间的）。prefs 里记一次，之后不再做。返回复制条数
    @discardableResult
    public func migrateOnce(from other: WKWebsiteDataStore, key: String = "mio.access.migratedFromDefaultStore") async -> Int {
        guard !prefs.bool(key, default: false) else { return 0 }
        prefs.set(true, forKey: key)
        let target = store()
        guard other !== target else { return 0 }
        let now = Date()
        let have = Set(await target.httpCookieStore.allCookies().map { Self.snapshot($0).key })
        var n = 0
        for c in await other.httpCookieStore.allCookies() {
            let snap = Self.snapshot(c)
            guard MioAccessAuth.isMioCoreOrAccessDomain(snap.domain, prefs: prefs), snap.isValid(at: now), !have.contains(snap.key) else { continue }
            await target.httpCookieStore.setCookie(c)
            n += 1
        }
        if n > 0 { _ = await backUp() }
        return n
    }

    public func clear() { secrets.setSecret(Self.secretName, nil) }

    /// 主框架导航完成时调用：回到 MioCore（登录完成）→ 备份；Access 退出页 → 清空
    public func didFinishMainFrame(_ url: URL?) {
        guard let u = url else { return }
        if MioAccessAuth.isAccessURL(u, prefs: prefs), u.path.lowercased().hasPrefix("/cdn-cgi/access/logout") {
            clear()
            return
        }
        if MioCoreOrigin.isMioCore(u, prefs: prefs) {
            Task { await self.backUp() }
        }
    }

    nonisolated static func snapshot(_ c: HTTPCookie) -> MioAccessCookie {
        let same = c.sameSitePolicy?.rawValue
        return MioAccessCookie(name: c.name, value: c.value, domain: c.domain, path: c.path, expires: c.expiresDate,
                               secure: c.isSecure, httpOnly: c.isHTTPOnly, sameSite: same)
    }

    nonisolated static func cookie(_ c: MioAccessCookie) -> HTTPCookie? {
        var p: [HTTPCookiePropertyKey: Any] = [
            .name: c.name, .value: c.value, .domain: c.domain, .path: c.path.isEmpty ? "/" : c.path,
        ]
        if let e = c.expires { p[.expires] = e }
        if c.secure { p[.secure] = "TRUE" }
        if c.httpOnly { p[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if let s = c.sameSite { p[.sameSitePolicy] = s }
        return HTTPCookie(properties: p)
    }
}
#endif
