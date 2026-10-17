// macOS 上的广告拦截端到端测试（真实 AdGuard 转换器 + FilterEngine + WKContentRuleListStore + WKWebView）：
//   - testLocalPage*：本地测试规则（CRLF，AdGuard 语法）→ 网络请求被拦、## 元素隐藏、scriptlet（set-constant / abort-on-property-read）、
//     扩展 CSS（#?# :has）、iframe 里的 scriptlet；不依赖订阅内容（规则自带），但页面里的请求要联网
//   - testLiveSubscriptions（MIO_ADBLOCK_LIVE=1 才跑，CI miokit job 打开）：真实下载默认订阅 → >1 万条、MioAdblockProbe 全过；
//     adblock.turtlecute.org 开 / 关拦截各测一次得分 + 截图（MIO_ADBLOCK_ARTIFACTS 目录）
#if canImport(WebKit) && os(macOS)
import XCTest
import WebKit
import AppKit
@testable import MioKit

@MainActor
final class MioAdblockWebKitTests: XCTestCase {
    static let testHost = "mio-adblock-test.example.com"
    /// 自带的测试列表（CRLF，与 filters.adtidy.org 一样）
    static let testList = [
        "! Title: Mio adblock test list",
        "! Version: 1.0.0",
        "||example.org/mio-ad-test.js",
        "###mio-ad-banner",
        "\(testHost)##.mio-sponsored",
        "\(testHost)#%#//scriptlet('set-constant', 'mioAdFlag', 'true')",
        "\(testHost)#%#//scriptlet('abort-on-property-read', 'mioAdDetector')",
        "\(testHost)#?#.mio-wrap:has(> .mio-sponsor-mark)",
        "\(testHost)##+js(set-constant, mioUboFlag, false)",
        "frame.\(testHost)#%#//scriptlet('set-constant', 'mioFrameFlag', 'true')",
    ].joined(separator: "\r\n") + "\r\n"

    static let page = """
    <!doctype html><html><body>
    <div id="mio-ad-banner">generic hide</div>
    <div class="mio-sponsored">domain hide</div>
    <div class="mio-wrap" id="w1"><span class="mio-sponsor-mark">s</span>extended css</div>
    <div class="mio-wrap" id="w2">keep</div>
    <div id="control">control</div>
    <script>
      window.__detector = 'not-run';
      try { window.__detector = typeof window.mioAdDetector; } catch (e) { window.__detector = 'aborted'; }
    </script>
    </body></html>
    """

    func makeBlocker(_ list: String, prefs: MioMemoryPrefs = MioMemoryPrefs()) async -> (MioKitContainer, MioContentBlocker) {
        for s in MioFilterCatalog.subscriptions { prefs.set(s.key == "2", forKey: s.enabledKey) }
        let kit = makeKit(prefs)
        let m = kit.filters   // 和设置页 / 模块用同一个 manager
        m.http = { _ in (200, Data(list.utf8), [:]) }
        let blocker = MioContentBlocker(manager: m, store: MioWKRuleListStore(directory: makeTempDir("adb-rules")))
        await blocker.prepare(checkUpdates: false)
        _ = await m.refresh()
        await blocker.reload()
        return (kit, blocker)
    }

    func js(_ wv: WKWebView, _ body: String) async -> Any? { await MioWebViewModules.callAsync(wv, body, arguments: [:], world: .page) }

    func testLocalPageNetworkHideScriptletExtendedCss() async throws {
        let (kit, blocker) = await makeBlocker(Self.testList)
        let meta = try XCTUnwrap(blocker.manager.state.lists["2"])
        XCTAssertNil(meta.error, "\(meta)")
        XCTAssertGreaterThanOrEqual(meta.contentRules, 2, "网络 + ## 规则编进 WKContentRuleList")
        XCTAssertGreaterThanOrEqual(meta.advancedRules, 4, "scriptlet / 扩展 CSS / +js 进高级规则")
        XCTAssertEqual(blocker.manager.advanced?.isReady, true, "FilterEngine 构建好了：\(blocker.manager.state.engineError ?? "-")")
        XCTAssertTrue(blocker.ruleLists.keys.contains("mio.kit.2.0"))

        let (wv, mods, loader) = MioAdblockProbe.standalone(kit: kit, blocker: blocker)
        let base = URL(string: "https://\(Self.testHost)/page")!
        await MioAdblockProbe.loadHTML(wv, mods, loader, html: Self.page, base: base)
        XCTAssertTrue(mods.appliedRuleListIdentifiers.contains("mio.kit.2.0"))
        XCTAssertEqual(mods.adblockPrepared.map { $0.host }, [Self.testHost], "主框架导航前准备好了注入代码")
        try? await Task.sleep(nanoseconds: 800_000_000)
        let r = await js(wv, """
        async function hit(u) { try { await fetch(u, { mode: 'no-cors', cache: 'no-store' }); return 'loaded'; } catch (e) { return 'blocked'; } }
        const vis = (s) => { const el = document.querySelector(s); return !!el && getComputedStyle(el).display !== 'none'; };
        return JSON.stringify({
          ad: await hit('https://example.org/mio-ad-test.js?x=' + Date.now()),
          control: await hit('https://example.org/mio-ok.js?x=' + Date.now()),
          banner: vis('#mio-ad-banner'), sponsored: vis('.mio-sponsored'), w1: vis('#w1'), w2: vis('#w2'), control: vis('#control'),
          flag: window.mioAdFlag, ubo: window.mioUboFlag, detector: window.__detector
        });
        """) as? String ?? "{}"
        let d = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(r.utf8)) as? [String: Any], r)
        XCTAssertEqual(d["ad"] as? String, "blocked", "网络规则 \(d)")
        XCTAssertEqual(d["banner"] as? Bool, false, "通用 ## 隐藏 \(d)")
        XCTAssertEqual(d["sponsored"] as? Bool, false, "域名 ## 隐藏 \(d)")
        XCTAssertEqual(d["control"] as? Bool, true, "对照元素可见 \(d)")
        XCTAssertEqual(d["flag"] as? Bool, true, "scriptlet set-constant \(d)")
        XCTAssertEqual(d["ubo"] as? Bool, false, "uBO ##+js(set-constant) \(d)")
        XCTAssertEqual(d["detector"] as? String, "aborted", "scriptlet abort-on-property-read \(d)")
        XCTAssertEqual(d["w1"] as? Bool, false, "扩展 CSS :has() \(d)")
        XCTAssertEqual(d["w2"] as? Bool, true, "扩展 CSS 不误伤 \(d)")

        // 白名单站点：规则卸下、不注入
        kit.prefs.set([Self.testHost], forKey: MioFilterCatalog.allowlistKey)
        await MioAdblockProbe.loadHTML(wv, mods, loader, html: Self.page, base: base)
        try? await Task.sleep(nanoseconds: 500_000_000)
        let off = await js(wv, "return JSON.stringify({ flag: window.mioAdFlag === undefined, banner: getComputedStyle(document.querySelector('#mio-ad-banner')).display })") as? String ?? ""
        XCTAssertTrue(off.contains("\"flag\":true") && off.contains("\"banner\":\"block\""), off)
        XCTAssertTrue(mods.appliedRuleListIdentifiers.isEmpty)
        withExtendedLifetime(mods) {}
    }

    func testScriptletInIframeViaFrameMessage() async throws {
        let (kit, blocker) = await makeBlocker(Self.testList)
        let (wv, mods, loader) = MioAdblockProbe.standalone(kit: kit, blocker: blocker)
        // 主框架 example.net（没有规则），iframe 指向 frame.<testHost>（有 set-constant）：iframe 走「发消息 → 原生注入」
        let frameURL = URL(string: "https://frame.\(Self.testHost)/f")!
        XCTAssertNotNil(blocker.pageScript(for: frameURL, topURL: URL(string: "https://example.net/")), "iframe 地址查得到 scriptlet")
        await MioAdblockProbe.loadHTML(wv, mods, loader, html: "<html><body>top</body></html>", base: URL(string: "https://example.net/")!)
        XCTAssertTrue(mods.adblockPrepared.isEmpty, "主框架没有高级规则")
        withExtendedLifetime(mods) {}
    }

    func testSettingsStatusAfterCompile() async throws {
        let (kit, blocker) = await makeBlocker(Self.testList)
        let group = kit.settingsModel.group(for: kit.adblock)
        let status = try XCTUnwrap(group.rows.first { $0.setting.key == "adblock.status" }?.detail)
        XCTAssertTrue(status.hasPrefix("已加载 "), status)
        XCTAssertTrue(status.contains("跳过") && status.contains("上次更新"), status)
        XCTAssertNotNil(group.rows.first { $0.setting.key == "adblock.update" }, "立即更新按钮")
        let msg = await kit.adblock.performSettingAction("adblock.update", prefs: kit.prefs)
        XCTAssertTrue(msg?.contains("已加载") == true, msg ?? "")
        withExtendedLifetime(blocker) {}
    }

    // MARK: 真实订阅 + 真实网站（联网）

    func testLiveSubscriptions() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MIO_ADBLOCK_LIVE"] == "1", "MIO_ADBLOCK_LIVE=1 才跑（下载约 11 MB）")
        let out = ProcessInfo.processInfo.environment["MIO_ADBLOCK_ARTIFACTS"].map { URL(fileURLWithPath: $0) } ?? makeTempDir("adb-art")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let prefs = MioMemoryPrefs()
        let kit = makeKit(prefs)
        let m = kit.filters
        let blocker = MioContentBlocker(manager: m, store: MioWKRuleListStore(directory: makeTempDir("live-rules")))
        let t0 = Date()
        await blocker.prepare()
        let prepareSeconds = Date().timeIntervalSince(t0)
        blocker.stopAutoUpdate()
        var report: [String: Any] = ["prepareSeconds": Int(prepareSeconds), "details": m.listDetails(), "status": m.statusText()]
        print("ADBLOCK_DETAILS\n" + m.listDetails())

        let (wv, mods, loader) = MioAdblockProbe.standalone(kit: kit, blocker: blocker)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 1400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = wv
        window.orderFront(nil)
        let probe = await MioAdblockProbe.run(blocker: blocker, webView: wv) { html, base in
            await MioAdblockProbe.loadHTML(wv, mods, loader, html: html, base: base)
        }
        report["probe"] = probe
        if let png = await MioAdblockProbe.snapshotPNG(wv) { try? png.write(to: out.appendingPathComponent("miokit-probe-page.png")) }

        // 真实网站打分：开拦截
        await MioAdblockProbe.loadURL(wv, mods, loader, url: MioAdblockProbe.scoreSite)
        let on = await MioAdblockProbe.turtlecuteScore(wv)
        report["turtlecuteOn"] = on
        if let png = await MioAdblockProbe.snapshotPNG(wv) { try? png.write(to: out.appendingPathComponent("miokit-turtlecute-on.png")) }
        // 关拦截（同一页面、同样的 WebView 尺寸，不挂任何 Mio 规则）作对照
        let plain = WKWebView(frame: wv.frame, configuration: { let c = WKWebViewConfiguration(); c.websiteDataStore = .nonPersistent(); return c }())
        let plainLoader = MioAdblockProbe.Loader()
        plain.navigationDelegate = plainLoader
        window.contentView = plain
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in plainLoader.cont = c; plain.load(URLRequest(url: MioAdblockProbe.scoreSite)) }
        let off = await MioAdblockProbe.turtlecuteScore(plain)
        report["turtlecuteOff"] = off
        if let png = await MioAdblockProbe.snapshotPNG(plain) { try? png.write(to: out.appendingPathComponent("miokit-turtlecute-off.png")) }

        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: out.appendingPathComponent("miokit-adblock-report.json"))
        print("ADBLOCK_REPORT " + (String(data: data, encoding: .utf8) ?? ""))

        let s = m.summary()
        XCTAssertGreaterThan(s.contentRules, 10_000, m.listDetails())
        XCTAssertTrue(s.errors.isEmpty, "\(s.errors)")
        XCTAssertEqual(probe["blockedOK"] as? Bool, true, "\(probe)")
        XCTAssertEqual(probe["hideOK"] as? Bool, true, "\(probe)")
        XCTAssertEqual(probe["scriptletOK"] as? Bool, true, "\(probe)")
        if let a = on["score"] as? Int, let b = off["score"] as? Int { XCTAssertGreaterThan(a, b, "开拦截得分应高于关拦截") }
        withExtendedLifetime(mods) {}
    }
}
#endif
