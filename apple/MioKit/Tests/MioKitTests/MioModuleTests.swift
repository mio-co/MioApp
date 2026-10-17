import XCTest
@testable import MioKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

func makeTempDir(_ name: String = #function) -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("miokit-\(name)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

func makeKit(_ prefs: MioMemoryPrefs = MioMemoryPrefs()) -> MioKitContainer {
    let d = makeTempDir()
    return MioKitContainer(prefs: prefs, filterDirectory: d.appendingPathComponent("filters"), userScriptDirectory: d.appendingPathComponent("us"),
                           secrets: MioMemorySecretStore(), translateCache: MioTranslateCache(file: nil))
}

final class Dummy: MioModule {
    let id: String
    let title = "Dummy"
    let summary = ""
    let section = MioSettingsSection.extensions
    init(_ id: String) { self.id = id }
    var settings: [MioModuleSetting] {
        [MioModuleSetting(key: "d.on", title: "on", kind: .toggle(default: false)),
         MioModuleSetting(key: "d.sub", title: "sub", kind: .choice(options: [MioChoiceOption(.int(1), "1"), MioChoiceOption(.int(2), "2")], default: .int(1)),
                          visibleWhen: .init(key: "d.on", equals: .bool(true)))]
    }
    func scripts(prefs: MioPrefs) -> [MioModuleScript] { [MioModuleScript(source: "/*\(id)*/")] }
}

final class MioModuleRegistryTests: XCTestCase {
    func testRegisterDedupAndDisabledInjectsNothing() {
        let prefs = MioMemoryPrefs()
        let r = MioModuleRegistry(prefs: prefs, modules: [Dummy("a"), Dummy("b")])
        var changed: [String] = []
        r.onChange = { changed.append($0) }
        XCTAssertFalse(r.register(Dummy("a")), "同 id 不覆盖")
        XCTAssertFalse(r.register(Dummy("")))
        XCTAssertEqual(r.scripts().map { $0.script.source }, ["/*a*/", "/*b*/"])
        r.setEnabled("a", false)
        XCTAssertEqual(r.scripts().map { $0.moduleID }, ["b"])
        XCTAssertEqual(prefs.object(forKey: "mio.kit.module.a.enabled") as? Bool, false)
        XCTAssertEqual(changed, ["mio.kit.module.a.enabled"])
    }

    func testSettingsModel() {
        let prefs = MioMemoryPrefs()
        let r = MioModuleRegistry(prefs: prefs, modules: [Dummy("a")])
        r.onChange = { _ in }
        let model = MioExtensionSettingsModel(registry: r)
        var g = model.group(for: r.modules[0])
        XCTAssertEqual(g.rows.map { $0.setting.key }, ["mio.kit.module.a.enabled", "d.on"], "visibleWhen 不满足时隐藏子设置")
        XCTAssertEqual(g.rows[0].role, .moduleToggle)
        XCTAssertTrue(model.apply(g.rows[1], .bool(true)))
        g = model.group(for: r.modules[0])
        XCTAssertEqual(g.rows.map { $0.setting.key }, ["mio.kit.module.a.enabled", "d.on", "d.sub"])
        XCTAssertFalse(model.apply(g.rows[2], .int(3)), "选项外的值拒绝")
        XCTAssertFalse(model.apply(g.rows[1], .string("x")), "类型不对拒绝")
        XCTAssertTrue(model.apply(g.rows[2], .int(2)))
        XCTAssertEqual(prefs.object(forKey: "d.sub") as? Int, 2)
        // 模块关掉：只剩总开关
        XCTAssertTrue(model.apply(g.rows[0], .bool(false)))
        XCTAssertEqual(model.group(for: r.modules[0]).rows.count, 1)
        XCTAssertEqual(r.scripts().count, 0)
    }

    func testBuiltinKitUsesLegacyKeys() {
        // v0.3.x 用户关掉了 YouTube 防沉迷 / 广告拦截 / WebRTC：升级后 MioKit 读到同样的状态
        let prefs = MioMemoryPrefs(["mio.browser.youtubeFocus": false, "mio.adblock.enabled": false, "mio.webrtc.enabled": true,
                                    "mio.browser.youtubeFocusInterval": 300, "mio.media.sponsorBlock": false])
        let kit = makeKit(prefs)
        XCTAssertFalse(kit.registry.isEnabled("youtubeFocus"))
        XCTAssertFalse(kit.registry.isEnabled("adblock"))
        XCTAssertTrue(kit.registry.isEnabled("webrtc"))
        XCTAssertFalse(kit.registry.isEnabled("sponsorBlock"))
        XCTAssertEqual(kit.registry.modules.map { $0.id },
                       ["miocore", "adblock", "webrtc", "youtubeFocus", "media", "sponsorBlock", "translate", "pageTools", "userScripts", "containers"])
        let ids = kit.registry.scripts().map { $0.moduleID }
        XCTAssertFalse(ids.contains("youtubeFocus"))
        XCTAssertTrue(ids.contains("webrtc"))
        XCTAssertTrue(ids.contains("media"))
        // 媒体脚本的 SponsorBlock 配置跟着 SponsorBlock 模块开关
        XCTAssertTrue(kit.media.scripts(prefs: prefs).last!.source.contains("\"sponsorBlock\":false"))
        prefs.set(true, forKey: "mio.browser.youtubeFocus")
        let yt = kit.youtubeFocus.scripts(prefs: prefs)
        XCTAssertEqual(yt.count, 1)
        XCTAssertTrue(yt[0].source.contains("300000"), "间隔沿用 v0.3.x 设置")
        // 设置页：每个模块一组；有总开关的第一行是总开关
        let groups = kit.settingsModel.groups()
        XCTAssertEqual(groups.count, kit.registry.modules.count)
        XCTAssertNil(groups.first { $0.moduleID == "miocore" }?.rows.first { $0.role == .moduleToggle }, "MioCore 常开，没有总开关")
        XCTAssertEqual(groups.first { $0.moduleID == "adblock" }?.rows.count, 1, "广告拦截关着：只显示总开关")
    }

    func testMenusAndActions() {
        let prefs = MioMemoryPrefs(["mio.webrtc.enabled": true])
        let kit = makeKit(prefs)
        var page = MioPageContext(url: URL(string: "https://meet.google.com/abc"), title: "Meet")
        let items = kit.registry.menuItems(page: page)
        let webrtc = items.first { $0.moduleID == "webrtc" }!
        XCTAssertEqual(webrtc.checked, false)
        XCTAssertEqual(kit.registry.perform(webrtc, page: page), .reload)
        XCTAssertEqual(prefs.object(forKey: "mio.webrtc.allowlist") as? [String], ["meet.google.com"])
        XCTAssertTrue(kit.webRTC.scripts(prefs: prefs)[0].source.contains("meet.google.com"))
        // 「保存到 Mio」：先在阅读世界提取正文，结果 → .host(.saveToMio)
        let save = items.first { $0.id == "miocore.save.bookmark" && $0.placement == .pageMenu }!
        guard case .runScript(let call) = kit.registry.perform(save, page: page) else { return XCTFail("应先提取正文") }
        XCTAssertEqual(call.world, .isolated("mio-reader"))
        let next = kit.registry.handleScriptResult(moduleID: "miocore", handler: call.resultHandler!, result: ["url": page.url!.absoluteString, "title": "Meet", "selection": ""], page: page)
        guard case .host(.saveToMio(let kind, let json)) = next else { return XCTFail("\(next)") }
        XCTAssertEqual(kind, "bookmark")
        XCTAssertTrue(json.contains("meet.google.com"))
        // MioCore 自己的页面 / mio:// 不出现「保存到 Mio」
        page.url = URL(string: "https://mio.300031.xyz/mio/nav")
        XCTAssertFalse(kit.registry.menuItems(page: page).contains { $0.itemID.hasPrefix("save.") })
        // 广告拦截白名单菜单
        prefs.set(true, forKey: "mio.adblock.enabled")
        page.url = URL(string: "https://www.example.com/x")
        let ab = kit.registry.menuItems(page: page).first { $0.moduleID == "adblock" }!
        _ = kit.registry.perform(ab, page: page)
        XCTAssertEqual(prefs.object(forKey: "mio.adblock.allowlist") as? [String], ["example.com"])
        XCTAssertFalse(kit.adblock.shouldApplyContentRules(topURL: URL(string: "https://sub.example.com"), prefs: prefs))
        XCTAssertTrue(kit.adblock.shouldApplyContentRules(topURL: URL(string: "https://example.org"), prefs: prefs))
        XCTAssertTrue(kit.registry.contentRuleModules(topURL: URL(string: "https://sub.example.com")).isEmpty)
    }

    func testForceDarkMenuAndScript() {
        let prefs = MioMemoryPrefs()
        let kit = makeKit(prefs)
        XCTAssertTrue(kit.pageTools.scripts(prefs: prefs).isEmpty, "没开任何深色：不注入")
        let page = MioPageContext(url: URL(string: "https://news.example.com/a"))
        let item = kit.registry.menuItems(page: page).first { $0.id == "pageTools.darkOn" }!
        XCTAssertEqual(kit.registry.perform(item, page: page), .reload)
        let s = kit.pageTools.scripts(prefs: prefs)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].world, .isolated("mio-dark"))
        XCTAssertTrue(s[0].source.contains("MioDark.install"))
    }
}

final class MioModuleMessageTests: XCTestCase {
    let core = MioFrameOrigin(scheme: "https", host: "www.youtube.com")

    func msg(_ name: String, _ body: Any, main: Bool = true, world: MioScriptWorld = .page) -> MioScriptMessage {
        MioScriptMessage(endpoint: MioMessageEndpoint(name: name, world: world), body: body, isMainFrame: main, origin: core, pageURL: URL(string: "https://www.youtube.com/watch?v=x"))
    }

    func testSponsorBlockFetchAllowlist() async {
        let prefs = MioMemoryPrefs()
        let kit = makeKit(prefs)
        var fetched: [URL] = []
        kit.media.fetcher = { u in fetched.append(u); return (200, Data("[{\"segment\":[1,2]}]".utf8)) }
        let bad = await kit.registry.handle(msg("mioMedia", ["type": "sbFetch", "url": "https://evil.example/api/skipSegments/abcd"]))
        guard case .error = bad else { return XCTFail("非 SponsorBlock 地址应拒绝") }
        let ok = await kit.registry.handle(msg("mioMedia", ["type": "sbFetch", "url": "https://sponsor.ajay.app/api/skipSegments/abcd?categories=%5B%22sponsor%22%5D"]))
        guard case .value(let v) = ok else { return XCTFail("\(ok)") }
        XCTAssertEqual(v as? String, "[{\"segment\":[1,2]}]")
        XCTAssertEqual(fetched.count, 1)
        let sub = await kit.registry.handle(msg("mioMedia", ["type": "sbFetch", "url": "https://sponsor.ajay.app/api/skipSegments/abcd"], main: false))
        guard case .error = sub else { return XCTFail("iframe 不行") }
        prefs.set(false, forKey: "mio.media.sponsorBlock")
        let off = await kit.registry.handle(msg("mioMedia", ["type": "sbFetch", "url": "https://sponsor.ajay.app/api/skipSegments/abcd"]))
        guard case .error = off else { return XCTFail("SponsorBlock 关了就不代取") }
        // 模块关掉：通道不注册、消息被拒
        kit.registry.onChange = { _ in }
        kit.registry.setEnabled("media", false)
        XCTAssertFalse(kit.registry.messageEndpoints().contains { $0.endpoint.name == "mioMedia" })
        let gone = await kit.registry.handle(msg("mioMedia", ["type": "state"]))
        guard case .error = gone else { return XCTFail() }
    }

    func testTranslateTokenAndHostAllowlist() async {
        let prefs = MioMemoryPrefs()
        let kit = makeKit(prefs)
        var sent: [URLRequest] = []
        kit.translate.send = { r in sent.append(r); return (200, Data("{\"ok\":1}".utf8), nil) }
        let noToken = await kit.registry.handle(msg("mioTranslate", ["op": "fetch", "req": ["url": "https://api.cognitive.microsofttranslator.com/translate"]]))
        guard case .error(let e) = noToken else { return XCTFail() }
        XCTAssertEqual(e, "forbidden")
        let t = kit.translate.token
        let evil = await kit.registry.handle(msg("mioTranslate", ["t": t, "op": "fetch", "req": ["url": "https://evil.example/steal"]]))
        guard case .value(let ev) = evil else { return XCTFail() }
        XCTAssertNotNil((ev as? [String: Any])?["error"])
        XCTAssertTrue(sent.isEmpty)
        let put = await kit.registry.handle(msg("mioTranslate", ["t": t, "op": "cachePut", "entries": ["k": "v"]]))
        guard case .value = put else { return XCTFail() }
        let get = await kit.registry.handle(msg("mioTranslate", ["t": t, "op": "cacheGet", "keys": ["k", "x"]]))
        guard case .value(let g) = get else { return XCTFail() }
        XCTAssertEqual((g as? [String: Any])?["values"] as? [String: String], ["k": "v"])
        // 脚本：配置里带 token，模板占位符被替换
        let s = kit.translate.scripts(prefs: prefs)
        XCTAssertEqual(s.count, 1, "mio-translate.js 应打包在 Resources/js")
        XCTAssertFalse(s[0].source.contains(MioTranslateCore.placeholder))
        // 自动翻译菜单写 v0.3.x 的 key
        let page = MioPageContext(url: URL(string: "https://www.nytimes.com/x"))
        let auto = kit.registry.menuItems(page: page).first { $0.itemID == "autoOn" }!
        _ = kit.registry.perform(auto, page: page)
        XCTAssertEqual(prefs.object(forKey: "mio.translate.autoSites") as? [String], ["nytimes.com"])
    }

    func testOpenAIReadyNeedsKeyInSecretStore() {
        let prefs = MioMemoryPrefs(["mio.translate.engine": "openai", "mio.translate.openaiBase": "https://api.example.com/v1", "mio.translate.openaiModel": "m"])
        let kit = makeKit(prefs)
        XCTAssertFalse(kit.translate.config(prefs).openaiReady)
        kit.translate.setAPIKey("sk-test")
        XCTAssertTrue(kit.translate.config(prefs).openaiReady)
        XCTAssertNil(prefs.object(forKey: "mio.translate.openaiKeyFallback"), "API Key 不写进普通设置")
    }
}

final class MioContainerManagerTests: XCTestCase {
    func testDataStoreMappingAndPersistence() throws {
        let prefs = MioMemoryPrefs()
        let m = MioContainerManager(prefs: prefs)
        m.postsNotifications = false
        XCTAssertEqual(m.dataStoreUUID(for: nil), MioContainerIDs.defaultDataStoreID)
        XCTAssertEqual(m.dataStoreUUID(for: "default"), UUID(uuidString: "6D696F00-6272-6F77-7365-720000000001"))
        XCTAssertNil(m.dataStoreUUID(for: "private"), "无痕 = 不落盘")
        let work = try m.create(name: "工作", color: "blue")
        XCTAssertEqual(m.dataStoreUUID(for: work.id), UUID(uuidString: work.id))
        XCTAssertEqual(m.dataStoreUUID(for: "deleted-or-unknown"), MioContainerIDs.defaultDataStoreID)
        _ = try m.setSiteRule("https://mail.google.com/x", containerId: work.id)
        // 同一个 key（mio.containers.state）重新读出来一样
        let m2 = MioContainerManager(prefs: prefs)
        XCTAssertEqual(m2.containers.map { $0.name }, ["默认", "工作"])
        XCTAssertEqual(m2.containerFor(url: URL(string: "https://mail.google.com/inbox")), work.id)
        XCTAssertEqual(m2.containerForNewTab(url: URL(string: "https://mail.google.com/"), opener: nil).containerId, work.id)
        let tabs = try m2.remove(work.id)
        XCTAssertEqual(tabs, [])
        XCTAssertEqual(m2.pendingRemovals, [work.id])
        m2.markRemoved(work.id)
        XCTAssertEqual(m2.pendingRemovals, [])
    }

    func testContainerMenu() throws {
        let kit = makeKit()
        kit.containers.postsNotifications = false
        let w = try kit.containers.create(name: "工作")
        let page = MioPageContext(url: URL(string: "https://github.com/x"), containerID: "default")
        let items = kit.registry.menuItems(page: page).filter { $0.moduleID == "containers" }
        XCTAssertTrue(items.contains { $0.itemID == "reopen:" + w.id })
        XCTAssertFalse(items.contains { $0.itemID == "rule" }, "默认容器不能做站点规则（不设规则就是默认）")
        let inWork = MioPageContext(url: URL(string: "https://github.com/x"), containerID: w.id)
        let rule = kit.registry.menuItems(page: inWork).first { $0.moduleID == "containers" && $0.itemID == "rule" }!
        _ = kit.registry.perform(rule, page: inWork)
        XCTAssertEqual(kit.containers.containerFor(url: URL(string: "https://github.com/y")), w.id)
        let reopen = items.first { $0.itemID == "reopen:" + w.id }!
        XCTAssertEqual(kit.registry.perform(reopen, page: page), .host(.reopenInContainer(containerID: w.id)))
    }
}
