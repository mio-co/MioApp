// macOS 上的 WebKit 测试（CI：macos runner 的 swift test）：真实 WKContentRuleListStore 编译、超 15 万条拆分后逐片编译、
// 真实 WKWebView 里的 MioCore 桥来源拒绝、mio:// 方案处理。Linux 上整个文件不编译。
#if canImport(WebKit) && os(macOS)
import XCTest
import WebKit
@testable import MioKit

@MainActor
final class MioWebKitTests: XCTestCase {
    func tempStore() -> MioWKRuleListStore { MioWKRuleListStore(directory: makeTempDir("rules")) }

    func testBasicConverterOutputCompiles() async throws {
        let store = tempStore()
        let lines = MioKitResources.filter("mio-basic")!.components(separatedBy: "\n") + [
            "||ads.example.com/banner/*.gif$image,domain=news.com", "|https://track.example/p|", "@@||ok.example^", "@@||good.example^$document",
            "example.com,~www.example.com##.ad", "##div[class^=\"sponsor\"]",
        ]
        let r = MioBasicFilterConverter().convert(lines)
        try await store.compile(identifier: "test.basic", json: r.json)
        let l = await store.lookUp("test.basic")
        XCTAssertNotNil(l)
        let empty = MioBasicFilterConverter().convert(["! nothing"])
        try await store.compile(identifier: "test.empty", json: empty.json)
    }

    func testBundledListsCompileWithBestConverter() async throws {
        let prefs = MioMemoryPrefs()
        for s in MioFilterCatalog.subscriptions { prefs.set(false, forKey: s.enabledKey) } // 不联网：只编内置列表
        let m = MioFilterManager(directory: makeTempDir("filters"), prefs: prefs)
        let blocker = MioContentBlocker(manager: m, store: tempStore())
        await blocker.prepare(checkUpdates: false)
        XCTAssertEqual(Set(blocker.ruleLists.keys), ["mio.kit.mio-basic.0", "mio.kit.mio-youtube.0"], "\(m.state.lists)")
        XCTAssertNil(m.state.lists["mio-basic"]?.error)
        // 第二次：内容没变，直接复用
        let before = m.state.lists["mio-basic"]?.compiledSha
        await blocker.reload()
        XCTAssertEqual(m.state.lists["mio-basic"]?.compiledSha, before)
    }

    /// 超过 15 万条：拆成多片，每片都能被 WebKit 编译（WebKit 硬上限 150000 条 / 表）
    func testOver150kSplitsAndEveryPartCompiles() async throws {
        let lines = (0..<160_000).map { "||ad\($0).example^" } + ["@@||ad5.example^"]
        let parts = MioRuleSplitter.convert(lines, converter: MioBasicFilterConverter())
        XCTAssertEqual(parts.count, 2)
        XCTAssertTrue(parts.allSatisfy { $0.ruleCount <= 150_000 && $0.discarded == 0 })
        let store = tempStore()
        for (i, p) in parts.enumerated() { try await store.compile(identifier: "test.big.\(i)", json: p.json) }
        let ids = await store.availableIdentifiers()
        XCTAssertTrue(ids.isSuperset(of: ["test.big.0", "test.big.1"]))
    }

    // MARK: 真实 WKWebView

    final class Nav: NSObject, WKNavigationDelegate {
        var cont: CheckedContinuation<Void, Never>?
        func webView(_ w: WKWebView, didFinish n: WKNavigation!) { cont?.resume(); cont = nil }
        func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { cont?.resume(); cont = nil }
        func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { cont?.resume(); cont = nil }
    }

    func makeWebView(_ kit: MioKitContainer) -> (WKWebView, MioWebViewModules, Nav) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(MioSchemeHandler(kit: kit), forURLScheme: MioHomeModel.scheme)
        let mods = MioWebViewModules(kit: kit, controller: config.userContentController)
        mods.install()
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        mods.webView = wv
        let nav = Nav()
        wv.navigationDelegate = nav
        return (wv, mods, nav)
    }

    func load(_ wv: WKWebView, _ nav: Nav, html: String, base: String) async {
        await withCheckedContinuation { c in nav.cont = c; wv.loadHTMLString(html, baseURL: URL(string: base)) }
    }

    func js(_ wv: WKWebView, _ body: String) async -> Any? {
        await MioWebViewModules.callAsync(wv, body, arguments: [:], world: .page)
    }

    static let probe = """
    const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.mio;
    if (!h) return { noHandler: true };
    const r = await h.postMessage({ v: 1, id: 'x', method: 'openTab', params: { url: 'https://example.com/' } });
    const p = await h.postMessage({ v: 1, id: 'y', method: 'ping', params: {} });
    return { open: r, ping: p, shim: typeof window.Mio };
    """

    func testBridgeRejectsOtherOriginsInRealWebView() async throws {
        let kit = makeKit()
        let host = FakeBridgeHost()
        kit.bridge.delegate = host
        let (wv, mods, nav) = makeWebView(kit)
        await load(wv, nav, html: "<html><body>evil</body></html>", base: "https://evil.example/")
        let evil = await js(wv, Self.probe) as? [String: Any]
        XCTAssertNotNil(evil, "页面里的探测脚本没有返回（WebKit 环境问题？）")
        XCTAssertEqual(((evil?["open"] as? [String: Any])?["error"] as? [String: Any])?["code"] as? String, "forbidden")
        XCTAssertEqual(((evil?["ping"] as? [String: Any])?["error"] as? [String: Any])?["code"] as? String, "forbidden")
        XCTAssertEqual(evil?["shim"] as? String, "undefined", "其他网站不定义 window.Mio")
        XCTAssertTrue(host.opened.isEmpty)

        // 子域名 / http 降级也不行
        for base in ["https://evil.mio.300031.xyz/", "http://mio.300031.xyz/", "https://mio.300031.xyz.evil.com/"] {
            await load(wv, nav, html: "<p>x</p>", base: base)
            let r = await js(wv, Self.probe) as? [String: Any]
            XCTAssertEqual(((r?["ping"] as? [String: Any])?["error"] as? [String: Any])?["code"] as? String, "forbidden", base)
        }
        XCTAssertTrue(host.opened.isEmpty)

        // MioCore 来源：放行
        await load(wv, nav, html: "<html><body>mio</body></html>", base: "https://mio.300031.xyz/mio/nav")
        let ok = await js(wv, Self.probe) as? [String: Any]
        XCTAssertEqual((ok?["ping"] as? [String: Any])?["ok"] as? Bool, true)
        XCTAssertEqual((ok?["open"] as? [String: Any])?["ok"] as? Bool, true)
        XCTAssertEqual(ok?["shim"] as? String, "object")
        XCTAssertEqual(host.opened, [URL(string: "https://example.com/")!])
        let viaShim = await js(wv, "return (await window.Mio.call('ping')).api;")
        XCTAssertEqual(viaShim as? Int, 1)

        // MioCore 页面里的 iframe（沙箱 = 不透明来源；同源 srcdoc = 子框架）：都拒绝
        for sandbox in [true, false] {
            let r = await js(wv, """
            return await new Promise((res) => {
              window.addEventListener('message', e => res(e.data), { once: true });
              const f = document.createElement('iframe');
              if (\(sandbox)) f.setAttribute('sandbox', 'allow-scripts');
              f.srcdoc = "<script>try{webkit.messageHandlers.mio.postMessage({v:1,id:'f',method:'openTab',params:{url:'https://example.com/frame'}}).then(function(r){parent.postMessage(r,'*')},function(e){parent.postMessage({err:String(e)},'*')})}catch(e){parent.postMessage({nohandler:true},'*')}<\\/script>";
              document.body.appendChild(f);
              setTimeout(() => res('timeout'), 5000);
            });
            """) as? [String: Any]
            // 不透明来源的 iframe 可能根本拿不到 messageHandlers（nohandler）——同样算拒绝
            let rejected = (r?["error"] as? [String: Any])?["code"] as? String == "forbidden" || r?["nohandler"] as? Bool == true
            XCTAssertTrue(rejected, "iframe sandbox=\(sandbox): \(String(describing: r))")
        }
        XCTAssertEqual(host.opened.count, 1, "iframe 没能打开标签")
        withExtendedLifetime(mods) {}
    }

    /// 回归（v0.4.0 导航页链接点不开）：MioCore 调 window.MioDesktop.browser.open({ url }) 传的是对象，
    /// shim 曾把它 String() 成 "[object Object]" → 桥回 bad_request，而 MioCore 已经 preventDefault
    func testMioDesktopShimOpensTabsForMioCoreLinks() async throws {
        let kit = makeKit()
        let host = FakeBridgeHost()
        kit.bridge.delegate = host
        let (wv, mods, nav) = makeWebView(kit)
        defer { withExtendedLifetime(mods) {} }
        let page = """
        <html><body>
        <a id="ext" href="https://example.org/nav-tile" target="_blank" rel="noopener noreferrer">ext</a>
        <a id="same" href="/mio/notes" target="_blank">same-host</a>
        <script>\(MioNewTabFixture.mioCoreAppShellJS)</script>
        </body></html>
        """
        await load(wv, nav, html: page, base: "https://mio.300031.xyz/mio/nav")
        let shape = await js(wv, "return typeof window.MioDesktop + '/' + typeof (window.MioDesktop && window.MioDesktop.browser.open)")
        XCTAssertEqual(shape as? String, "object/function")

        // 1. 对象签名（MioCore / Capacitor / Electron 壳）
        let r1 = await js(wv, "const r = await window.MioDesktop.browser.open({ url: 'https://example.org/obj' }); return JSON.stringify(r);")
        XCTAssertEqual(r1 as? String, "{\"opened\":true}")
        // 2. 字符串 + { background }（v0.3.x 文档写法）
        _ = await js(wv, "await window.MioDesktop.browser.open('https://example.org/str', { background: true }); return 1;")
        // 3. 相对地址按页面解析
        _ = await js(wv, "await window.MioDesktop.browser.open({ url: '/mio/drop' }); return 1;")
        // 4. 站点卡片点击（MioCore 的 document click 接管）
        _ = await js(wv, "document.getElementById('ext').click(); await new Promise(r => setTimeout(r, 300)); return window.__opened.join(',');")
        // 5. 搜索框 / handleOpenLink 的 window.open（被 MioCore 包过）
        _ = await js(wv, "window.open('https://example.org/search?q=1', '_blank', 'noopener,noreferrer'); await new Promise(r => setTimeout(r, 300)); return 1;")
        XCTAssertEqual(host.opened.map(\.absoluteString), [
            "https://example.org/obj", "https://example.org/str", "https://mio.300031.xyz/mio/drop",
            "https://example.org/nav-tile", "https://example.org/search?q=1",
        ])
        XCTAssertEqual(host.backgrounds, [false, true, false, false, false])
        let log = await js(wv, "return window.__opened.join(',')") as? String ?? ""
        XCTAssertFalse(log.contains("rejected"), log)

        // 打不开的地址：同步抛错（MioCore 就不 preventDefault，交给浏览器），不调桥
        let bad = await js(wv, """
        const out = [];
        for (const u of [{ url: 'javascript:alert(1)' }, { url: '' }, {}, 'data:text/html,x', null]) {
          try { window.MioDesktop.browser.open(u); out.push('no-throw'); } catch (e) { out.push(e.name); }
        }
        return out.join(',');
        """)
        XCTAssertEqual(bad as? String, "TypeError,TypeError,TypeError,TypeError,TypeError")
        XCTAssertEqual(host.opened.count, 5)
    }

    func testSchemeHandlerServesInternalPages() async throws {
        let kit = makeKit()
        let (wv, mods, nav) = makeWebView(kit)
        defer { withExtendedLifetime(mods) {} }
        await withCheckedContinuation { c in nav.cont = c; wv.load(URLRequest(url: MioHomeModel.aboutURL)) }
        let title = await js(wv, "return document.title")
        XCTAssertEqual(title as? String, "关于 Mio")
        XCTAssertEqual(kit.home.addressBarText(for: wv.url), "mio://about")
        // mio:// 内置页能用 ping，不能 saveToMio
        let r = await js(wv, "const p = await window.Mio.call('ping'); try { await window.Mio.call('saveToMio', {kind:'note', payload:{url:'https://a.com'}}); return 'saved'; } catch (e) { return [p.api, e.code]; }") as? [Any]
        XCTAssertEqual(r?.first as? Int, 1)
        XCTAssertEqual(r?.last as? String, "forbidden")
    }

    func testContentRulesFollowAllowlist() async throws {
        let prefs = MioMemoryPrefs()
        for s in MioFilterCatalog.subscriptions { prefs.set(false, forKey: s.enabledKey) }
        let kit = makeKit(prefs)
        let blocker = MioContentBlocker(manager: MioFilterManager(directory: makeTempDir("f2"), prefs: prefs, converter: MioBasicFilterConverter()), store: tempStore())
        await blocker.prepare(checkUpdates: false)
        let config = WKWebViewConfiguration()
        let mods = MioWebViewModules(kit: kit, controller: config.userContentController, blocker: blocker)
        mods.willNavigateMainFrame(to: URL(string: "https://example.org/"))
        XCTAssertEqual(mods.appliedRuleListIdentifiers.count, 2)
        prefs.set(["example.org"], forKey: MioFilterCatalog.allowlistKey)
        mods.willNavigateMainFrame(to: URL(string: "https://www.example.org/"))
        XCTAssertEqual(mods.appliedRuleListIdentifiers, [], "白名单站点不挂规则")
        prefs.set(false, forKey: MioFilterCatalog.enabledKey)
        mods.willNavigateMainFrame(to: URL(string: "https://other.example/"))
        XCTAssertEqual(mods.appliedRuleListIdentifiers, [], "模块关掉不挂规则")
    }
}
#endif

#if canImport(WebKit) && os(macOS)
/// Cloudflare Access Cookie 备份 / 补回（真实 WKHTTPCookieStore，非持久存储）
@MainActor
final class MioAccessCookieVaultTests: XCTestCase {
    func testBackUpAndRestoreAccessCookies() async throws {
        let prefs = MioMemoryPrefs()
        let secrets = MioMemorySecretStore()
        let store = WKWebsiteDataStore.nonPersistent()
        let vault = MioAccessCookieVault(prefs: prefs, secrets: secrets, store: { store })
        let later = Date().addingTimeInterval(86_400)
        func cookie(_ name: String, _ value: String, _ domain: String) -> HTTPCookie {
            HTTPCookie(properties: [.name: name, .value: value, .domain: domain, .path: "/", .expires: later, .secure: "TRUE"])!
        }
        await store.httpCookieStore.setCookie(cookie("CF_Authorization", "jwt-app", "mio.300031.xyz"))
        await store.httpCookieStore.setCookie(cookie("CF_Authorization", "jwt-team", "sakune.cloudflareaccess.com"))
        await store.httpCookieStore.setCookie(cookie("other", "x", "mio.300031.xyz"))
        let saved = await vault.backUp()
        XCTAssertEqual(saved, 2)
        XCTAssertEqual(vault.savedCount, 2)

        // 模拟「Cookie 没落盘就被杀掉」：清掉数据存储里的 Access Cookie → 启动时补回
        for c in await store.httpCookieStore.allCookies() where c.name == "CF_Authorization" {
            await store.httpCookieStore.deleteCookie(c)
        }
        let restored = await vault.restore()
        XCTAssertEqual(restored, 2)
        let names = await store.httpCookieStore.allCookies().filter { $0.name == "CF_Authorization" }.map(\.value)
        XCTAssertEqual(Set(names), ["jwt-app", "jwt-team"])
        // 再补一次：都在，不重复
        let again = await vault.restore()
        XCTAssertEqual(again, 0)

        // 退出登录 → 清空备份
        vault.didFinishMainFrame(URL(string: "https://sakune.cloudflareaccess.com/cdn-cgi/access/logout"))
        XCTAssertEqual(vault.savedCount, 0)
    }
}
#endif
