import XCTest
@testable import MioKit

/// Cloudflare Access 登录（MioCore 在 Access 后面）：地址分类、弹窗处理、UA、冒烟分类、Cookie 备份选择
final class MioAccessAuthTests: XCTestCase {
    let prefs = MioMemoryPrefs()
    let login = URL(string: "https://sakune.cloudflareaccess.com/cdn-cgi/access/login/mio.300031.xyz?kid=abc&redirect_url=%2Fmio%2Fnav")!

    func testAccessAndIdentityProviderURLs() {
        XCTAssertTrue(MioAccessAuth.isAccessURL(login))
        XCTAssertTrue(MioAccessAuth.isAccessLoginPage(login))
        XCTAssertTrue(MioAccessAuth.isAccessURL(URL(string: "https://mio.300031.xyz/cdn-cgi/access/authorized?token=x"), prefs: prefs))
        XCTAssertFalse(MioAccessAuth.isAccessURL(URL(string: "https://mio.300031.xyz/mio/nav"), prefs: prefs))
        XCTAssertFalse(MioAccessAuth.isAccessURL(URL(string: "https://cloudflareaccess.com/")), "不是团队域名")
        XCTAssertFalse(MioAccessAuth.isAccessURL(URL(string: "https://sakune.cloudflareaccess.com.evil.com/cdn-cgi/access/login")))
        XCTAssertFalse(MioAccessAuth.isAccessURL(URL(string: "http://sakune.cloudflareaccess.com/cdn-cgi/access/login")), "只认 https")

        XCTAssertTrue(MioAccessAuth.isIdentityProviderURL(URL(string: "https://accounts.google.com/o/oauth2/auth?client_id=1")))
        XCTAssertTrue(MioAccessAuth.isIdentityProviderURL(URL(string: "https://github.com/login/oauth/authorize?client_id=1")))
        XCTAssertTrue(MioAccessAuth.isIdentityProviderURL(URL(string: "https://github.com/sessions/two-factor")))
        XCTAssertFalse(MioAccessAuth.isIdentityProviderURL(URL(string: "https://github.com/mio-co/MioApp")), "普通 GitHub 页面不算")
        XCTAssertFalse(MioAccessAuth.isIdentityProviderURL(URL(string: "https://www.google.com/search?q=x")))
        XCTAssertTrue(MioAccessAuth.isAuthFlowURL(login))
    }

    func testPopupFromAccessLoginStaysInOpenerTab() {
        let google = URL(string: "https://accounts.google.com/o/oauth2/auth?client_id=1")
        XCTAssertEqual(MioAccessAuth.popupDisposition(opener: login, target: google, prefs: prefs), .openerTab)
        XCTAssertEqual(MioAccessAuth.popupDisposition(opener: URL(string: "https://mio.300031.xyz/mio/nav"), target: login, prefs: prefs), .openerTab)
        XCTAssertEqual(MioAccessAuth.popupDisposition(opener: URL(string: "mio://home"), target: login, prefs: prefs), .openerTab)
        // 第三方网站的「用 Google 登录」弹窗：保留新标签（window.opener / postMessage）
        XCTAssertEqual(MioAccessAuth.popupDisposition(opener: URL(string: "https://example.com/"), target: google, prefs: prefs), .newTab)
        // Access 登录页打开的普通链接（例如帮助）照常新标签
        XCTAssertEqual(MioAccessAuth.popupDisposition(opener: login, target: URL(string: "https://developers.cloudflare.com/"), prefs: prefs), .newTab)
        // MioCore 上的 /cdn-cgi/access/*（authorized / logout 页）也算 Access 页面
        XCTAssertEqual(MioAccessAuth.popupDisposition(opener: URL(string: "https://mio.300031.xyz/cdn-cgi/access/authorized?x=1"), target: google, prefs: prefs), .openerTab)
    }

    /// 回归（v0.4.0）：MioCore 导航页里的链接 / window.open 一律新标签，只有 Access 页面本身才在 MioCore 标签里继续
    func testMioCorePopupsOpenNewTabsUnlessAccess() {
        let nav = URL(string: "https://mio.300031.xyz/mio/nav")
        for t in ["https://example.org/", "https://www.youtube.com/watch?v=1", "https://mio.300031.xyz/mio/notes",
                  // 导航页里指向身份提供商的站点卡片：也是普通链接，开新标签
                  "https://accounts.google.com/", "https://github.com/login", "https://login.microsoftonline.com/",
                  "https://appleid.apple.com/"] {
            XCTAssertEqual(MioAccessAuth.popupDisposition(opener: nav, target: URL(string: t), prefs: prefs), .newTab, t)
            XCTAssertEqual(MioAccessAuth.popupDisposition(opener: URL(string: "mio://home"), target: URL(string: t), prefs: prefs), .newTab, t)
        }
        XCTAssertEqual(MioAccessAuth.popupDisposition(opener: nav, target: login, prefs: prefs), .openerTab)
        XCTAssertEqual(MioAccessAuth.popupDisposition(opener: nav, target: URL(string: "https://mio.300031.xyz/cdn-cgi/access/logout"), prefs: prefs), .openerTab)
        // 普通网站：什么都开新标签（含它自己的 Access / 登录弹窗）
        XCTAssertEqual(MioAccessAuth.popupDisposition(opener: URL(string: "https://example.com/"), target: URL(string: "https://example.org/"), prefs: prefs), .newTab)
        XCTAssertEqual(MioAccessAuth.popupDisposition(opener: URL(string: "https://example.com/"), target: login, prefs: prefs), .newTab)
        // 身份提供商页面自己弹的窗口：新标签（不在登录流程里吞标签）
        XCTAssertEqual(MioAccessAuth.popupDisposition(opener: URL(string: "https://accounts.google.com/signin"), target: URL(string: "https://support.google.com/"), prefs: prefs), .newTab)
        // 没有打开者 / 没有目标
        XCTAssertEqual(MioAccessAuth.popupDisposition(opener: nil, target: login, prefs: prefs), .newTab)
        XCTAssertEqual(MioAccessAuth.popupDisposition(opener: nav, target: nil, prefs: prefs), .newTab)
        // 改了 MioCore 地址：旧地址不再算 MioCore
        let custom = MioMemoryPrefs()
        custom.set("https://hub.example.net", forKey: MioCoreOrigin.originKey)
        XCTAssertEqual(MioAccessAuth.popupDisposition(opener: URL(string: "https://hub.example.net/mio/nav"), target: login, prefs: custom), .openerTab)
        XCTAssertEqual(MioAccessAuth.popupDisposition(opener: URL(string: "https://hub.example.net/mio/nav"), target: URL(string: "https://example.org/"), prefs: custom), .newTab)
    }

    func testSafariUserAgentForGoogle() {
        XCTAssertTrue(MioAccessAuth.needsSafariUserAgent(URL(string: "https://accounts.google.com/v3/signin/identifier")))
        XCTAssertFalse(MioAccessAuth.needsSafariUserAgent(URL(string: "https://www.youtube.com/")))
        let ua = MioAccessAuth.mobileSafariUserAgent(iOSVersion: "18.6.2", iPad: false)
        XCTAssertEqual(ua, "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Mobile/15E148 Safari/604.1")
        XCTAssertFalse(ua.contains("FxiOS"))
        XCTAssertTrue(MioAccessAuth.mobileSafariUserAgent(iOSVersion: "26.1", iPad: true).contains("Macintosh"))
    }

    func testAdblockSkipsLoginPages() {
        let m = MioAdblockModule(manager: MioFilterManager(directory: FileManager.default.temporaryDirectory.appendingPathComponent("mio-access-\(UUID())"), prefs: prefs))
        XCTAssertFalse(m.shouldApplyContentRules(topURL: login, prefs: prefs))
        XCTAssertFalse(m.shouldApplyContentRules(topURL: URL(string: "https://accounts.google.com/o/oauth2/auth"), prefs: prefs))
        XCTAssertTrue(m.shouldApplyContentRules(topURL: URL(string: "https://example.com/"), prefs: prefs))
    }

    func testHomeStatus() {
        let home = MioHomeModel(prefs: prefs)
        XCTAssertEqual(MioAccessAuth.homeStatus(landedOn: URL(string: "https://mio.300031.xyz/mio/nav"), home: home), "ok")
        XCTAssertEqual(MioAccessAuth.homeStatus(landedOn: login, home: home), "access-login")
        XCTAssertEqual(MioAccessAuth.homeStatus(landedOn: URL(string: "https://accounts.google.com/o/oauth2/auth"), home: home), "access-login")
        XCTAssertEqual(MioAccessAuth.homeStatus(landedOn: URL(string: "https://example.com/"), home: home), "other")
        XCTAssertEqual(MioAccessAuth.homeStatus(landedOn: nil, home: home), "none")
        XCTAssertEqual(MioAccessAuth.homeStatus(landedOn: URL(string: "mio://home"), home: home), "internal", "跳转还没提交，不算到了 MioCore")
    }

    func testCookieBackupSelection() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let later = now.addingTimeInterval(86_400)
        let all = [
            MioAccessCookie(name: "CF_Authorization", value: "jwt-app", domain: "mio.300031.xyz", expires: later),
            MioAccessCookie(name: "CF_Authorization", value: "jwt-team", domain: "sakune.cloudflareaccess.com", expires: later),
            MioAccessCookie(name: "CF_AppSession", value: "csrf", domain: ".mio.300031.xyz", expires: later),
            MioAccessCookie(name: "CF_Authorization", value: "expired", domain: "old.cloudflareaccess.com", expires: now.addingTimeInterval(-5)),
            MioAccessCookie(name: "CF_Authorization", value: "session-only", domain: "x.cloudflareaccess.com", expires: nil),
            MioAccessCookie(name: "CF_Authorization", value: "other-site", domain: "example.com", expires: later),
            MioAccessCookie(name: "SID", value: "google", domain: ".google.com", expires: later),
        ]
        let picked = MioAccessCookieSet.select(all, prefs: prefs, now: now)
        XCTAssertEqual(Set(picked.map(\.value)), ["jwt-app", "jwt-team", "csrf"])

        let round = MioAccessCookieSet.decode(MioAccessCookieSet.encode(picked))
        XCTAssertEqual(round, picked)

        // 启动补回：数据存储里只剩团队域名那条 → 补另外两条
        let present = [all[1]]
        let missing = MioAccessCookieSet.missing(saved: picked, present: present, prefs: prefs, now: now)
        XCTAssertEqual(Set(missing.map(\.value)), ["jwt-app", "csrf"])
        // 备份过期了就不补
        XCTAssertTrue(MioAccessCookieSet.missing(saved: picked, present: [], prefs: prefs, now: later.addingTimeInterval(10)).isEmpty)
    }
}
