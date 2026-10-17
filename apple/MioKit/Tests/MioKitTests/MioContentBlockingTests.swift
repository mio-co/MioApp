import XCTest
@testable import MioKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

func rules(_ json: String) -> [[String: Any]] {
    (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]] ?? []
}

final class MioBasicConverterTests: XCTestCase {
    let c = MioBasicFilterConverter()

    func testNetworkRules() {
        let r = c.convert(["! comment", "[Adblock Plus 2.0]", "||doubleclick.net^$third-party", "||ads.example.com/banner/*.gif$image,domain=news.com|~sub.news.com",
                           "|https://track.example/p|", "@@||doubleclick.net/ok^", "@@||good.example^$document"])
        let list = rules(r.json)
        XCTAssertEqual(r.sourceRules, 5)
        XCTAssertEqual(r.unsupported, 0)
        XCTAssertEqual(list.count, 5)
        let first = list[0]["trigger"] as! [String: Any]
        XCTAssertEqual(first["url-filter"] as? String, #"^[^:]+://+([^:/]+\.)?doubleclick\.net[/:]"#)
        XCTAssertEqual(first["load-type"] as? [String], ["third-party"])
        let second = list[1]["trigger"] as! [String: Any]
        XCTAssertEqual(second["resource-type"] as? [String], ["image"])
        XCTAssertEqual(second["if-domain"] as? [String], ["*news.com"], "if-domain 和 unless-domain 不能同时用：保留 if-domain")
        XCTAssertEqual((list[2]["trigger"] as! [String: Any])["url-filter"] as? String, #"^https://track\.example/p$"#)
        // 例外在最后（ignore-previous-rules 只作用于前面的规则）
        XCTAssertEqual((list[3]["action"] as! [String: Any])["type"] as? String, "ignore-previous-rules")
        let doc = list[4]["trigger"] as! [String: Any]
        XCTAssertEqual(doc["if-domain"] as? [String], ["*good.example"])
        XCTAssertEqual(doc["url-filter"] as? String, ".*")
    }

    func testCosmeticAndUnsupported() {
        var lines = ["example.com,~www.example.com##.ad", "example.org#%#//scriptlet('set-constant','a','1')", "example.org#$#body{}", "##.x:has(.y)",
                     "||x.com^$redirect=noopjs", "/banner\\d+/", "*$script", "example.com#@#.ad"]
        lines += (0..<120).map { "##.g\($0)" }
        let r = c.convert(lines)
        let list = rules(r.json)
        XCTAssertEqual(r.unsupported, 4, "redirect、正则、*$script（太宽）、#@#")
        XCTAssertEqual(r.advancedRules, 3, "#%# scriptlet、#$# CSS 注入、:has() 扩展 CSS 交给高级规则引擎")
        XCTAssertTrue(r.advancedText?.contains("set-constant") == true)
        let css = list.filter { ($0["action"] as! [String: Any])["type"] as? String == "css-display-none" }
        XCTAssertEqual(css.count, 1 + 3, "域名专属 1 条 + 120 个全局选择器按 50 合并成 3 条")
        XCTAssertEqual((css[0]["trigger"] as! [String: Any])["if-domain"] as? [String], ["*example.com"])
    }

    func testEmptyListStillValidJSON() {
        let r = c.convert(["! only comments"])
        XCTAssertEqual(rules(r.json).count, 1, "WebKit 不接受空数组：放占位规则")
    }

    func testCapAndDiscard() {
        let small = MioBasicFilterConverter(maxRules: 10)
        let r = small.convert((0..<30).map { "||ad\($0).example^" } + ["@@||ad1.example^"])
        XCTAssertEqual(r.ruleCount, 10)
        XCTAssertEqual(r.discarded, 21)
        XCTAssertEqual((rules(r.json).last!["action"] as! [String: Any])["type"] as? String, "ignore-previous-rules", "超限时先丢屏蔽规则，保留例外")
    }

    func testSplitterKeepsExceptionsInEveryPart() {
        let small = MioBasicFilterConverter(maxRules: 10)
        let lines = (0..<35).map { "||ad\($0).example^" } + ["@@||ad3.example^", "@@||ad30.example^"]
        let parts = MioRuleSplitter.convert(lines, converter: small, minSplit: 1)
        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertTrue(parts.allSatisfy { $0.discarded == 0 }, "每一片都在上限内")
        for p in parts {
            let exc = rules(p.json).filter { ($0["action"] as! [String: Any])["type"] as? String == "ignore-previous-rules" }
            XCTAssertEqual(exc.count, 2, "例外规则每片都带")
        }
        let blocks = parts.flatMap { rules($0.json) }.filter { ($0["action"] as! [String: Any])["type"] as? String == "block" }
        XCTAssertEqual(blocks.count, 35, "拆分不丢规则")
    }

    func testBundledListsConvert() {
        for list in MioFilterCatalog.bundled {
            let text = MioKitResources.filter(list.key == "mio-basic" ? "mio-basic" : "mio-youtube")
            XCTAssertNotNil(text, "\(list.key) 应打包在 Resources/filters")
            let r = c.convert(text!.components(separatedBy: "\n"))
            XCTAssertGreaterThan(r.ruleCount, 0)
        }
        let basic = c.convert(MioKitResources.filter("mio-basic")!.components(separatedBy: "\n"))
        XCTAssertEqual(basic.unsupported, 0, "内置精简列表只用内容规则能表达的语法")
        XCTAssertGreaterThan(basic.ruleCount, 30)
    }
}

final class FakeRuleStore: MioRuleListCompiling {
    var compiled: [String: String] = [:]
    var compileCount = 0
    var failIDs: Set<String> = []
    func availableIdentifiers() async -> Set<String> { Set(compiled.keys) }
    func compile(identifier: String, json: String) async throws {
        if failIDs.contains(identifier) { throw NSError(domain: "WKErrorDomain", code: 6, userInfo: [NSLocalizedDescriptionKey: "bad rule"]) }
        compiled[identifier] = json
        compileCount += 1
    }
    func remove(identifier: String) async { compiled[identifier] = nil }
}

final class MioFilterManagerTests: XCTestCase {
    var requests: [URLRequest] = []

    func makeManager(_ prefs: MioPrefs, responses: @escaping (URLRequest) -> (Int, String, [String: String])) -> MioFilterManager {
        MioFilterManager(directory: makeTempDir(), prefs: prefs, converter: MioBasicFilterConverter()) { req in
            self.requests.append(req)
            let (c, b, h) = responses(req)
            return (c, Data(b.utf8), h)
        }
    }

    func testDefaultsMatchV03() {
        let prefs = MioMemoryPrefs()
        XCTAssertEqual(MioFilterCatalog.enabledLists(prefs).map { $0.key }, ["mio-basic", "mio-youtube", "2", "11", "3", "101", "118", "224"])
        prefs.set(false, forKey: "mio.adblock.list.11")
        prefs.set(["https://easylist.to/easylist/easylist.txt", "http://insecure.example/list.txt", "https://easylist.to/easylist/easylist.txt"], forKey: MioFilterCatalog.customListsKey)
        let keys = MioFilterCatalog.enabledLists(prefs).map { $0.key }
        XCTAssertFalse(keys.contains("11"))
        XCTAssertEqual(keys.filter { $0.hasPrefix("custom-") }.count, 1, "只收 https、去重")
    }

    func testRefreshCompileCacheAndCleanup() async {
        let prefs = MioMemoryPrefs()
        for s in MioFilterCatalog.subscriptions where s.key != "2" { prefs.set(false, forKey: s.enabledKey) }
        var body = "! Title: AdGuard Base\n! Version: 2.1\n||ads.example^\n##.banner\n"
        let m = makeManager(prefs) { req in
            if req.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"" && body.contains("2.1") { return (304, "", [:]) }
            return (200, body, ["etag": "\"v1\""])
        }
        let store = FakeRuleStore()
        // 还没下载：只编译内置列表
        var ids = await m.compile(into: store)
        XCTAssertEqual(ids, ["mio.kit.mio-basic.0", "mio.kit.mio-youtube.0"])
        let msg = await m.refresh()
        XCTAssertEqual(msg, "1 个列表有更新")
        XCTAssertEqual(m.state.lists["2"]?.version, "2.1")
        ids = await m.compile(into: store)
        XCTAssertEqual(ids, ["mio.kit.mio-basic.0", "mio.kit.mio-youtube.0", "mio.kit.2.0"])
        XCTAssertEqual(store.compileCount, 3)
        // 再检查：带 If-None-Match，304，不重编
        _ = await m.refresh()
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "If-None-Match"), "\"v1\"")
        _ = await m.compile(into: store)
        XCTAssertEqual(store.compileCount, 3, "内容没变、规则表还在：跳过编译")
        XCTAssertEqual(m.activeIdentifiers(), ids)
        // 内容变了 → 重编
        body = "! Version: 2.2\n||ads.example^\n||more.example^\n"
        _ = await m.refresh()
        _ = await m.compile(into: store)
        XCTAssertEqual(store.compileCount, 4)
        // 关掉订阅 → 它的规则表被删
        prefs.set(false, forKey: "mio.adblock.list.2")
        ids = await m.compile(into: store)
        XCTAssertNil(store.compiled["mio.kit.2.0"])
        XCTAssertEqual(ids.count, 2)
        // 状态持久化
        let m2 = MioFilterManager(directory: m.directory, prefs: prefs, converter: MioBasicFilterConverter())
        XCTAssertEqual(m2.state.lists["2"]?.etag, "\"v1\"")
    }

    func testRejectsHTMLAndRecordsErrors() async {
        let prefs = MioMemoryPrefs()
        for s in MioFilterCatalog.subscriptions where s.key != "101" { prefs.set(false, forKey: s.enabledKey) }
        let m = makeManager(prefs) { _ in (200, "<!doctype html><html>captive portal</html>", [:]) }
        let msg = await m.refresh()
        XCTAssertTrue(msg.contains("EasyList"))
        XCTAssertEqual(m.state.lists["101"]?.error, "不是规则列表")
        let store = FakeRuleStore()
        store.failIDs = ["mio.kit.mio-youtube.0"]
        let ids = await m.compile(into: store)
        XCTAssertEqual(ids, ["mio.kit.mio-basic.0"])
        XCTAssertNotNil(m.state.lists["mio-youtube"]?.error)
        XCTAssertNil(m.state.lists["mio-youtube"]?.compiledSha, "编译失败不记缓存，下次重试")
    }

    func testSplitsLargeListIntoParts() async {
        let prefs = MioMemoryPrefs()
        for s in MioFilterCatalog.subscriptions where s.key != "224" { prefs.set(false, forKey: s.enabledKey) }
        let big = (0..<5000).map { "||ad\($0).example^" }.joined(separator: "\n") + "\n@@||ad7.example^\n"
        let m = MioFilterManager(directory: makeTempDir(), prefs: prefs, converter: MioBasicFilterConverter(maxRules: 2000)) { _ in (200, Data(("! big\n" + big).utf8), [:]) }
        _ = await m.refresh()
        let store = FakeRuleStore()
        let ids = await m.compile(into: store)
        let parts = ids.filter { $0.hasPrefix("mio.kit.224.") }
        XCTAssertEqual(parts.count, 4, "5000 条 / 上限 2000 → 对半拆两次 = 4 片")
        XCTAssertEqual(m.state.lists["224"]?.parts, 4)
    }
}

/// 高级规则引擎的假实现：记下 build 的规则，lookup 按「域名#%#//scriptlet(...)」原样解析
final class FakeAdvancedEngine: MioAdvancedEngine {
    var built: [String] = []
    var ready = false
    func build(rules: String) throws { built.append(rules); ready = true }
    func load() -> Bool { false }
    var isReady: Bool { ready }
    func lookup(pageURL: URL, topURL: URL?) -> MioCosmeticConfig? {
        guard let host = pageURL.host, let rules = built.last else { return nil }
        var conf = MioCosmeticConfig()
        for line in MioFilterText.lines(rules) {
            guard let r = line.range(of: "#%#//scriptlet("), line[..<r.lowerBound].split(separator: ",").contains(where: { host.hasSuffix($0) }) else { continue }
            let args = line[r.upperBound...].dropLast().split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " '")) }
            conf.scriptlets.append(.init(name: args[0], args: Array(args.dropFirst())))
        }
        return conf
    }
}

/// v0.4.0「广告拦截基本不生效」的回归测试：CRLF 列表、编译缓存作废、下载失败重试 / 退避、首次 / 打开订阅立即下载、状态文字、高级规则
final class MioAdblockFixTests: XCTestCase {
    func onlyList(_ key: String, _ prefs: MioPrefs) {
        for s in MioFilterCatalog.subscriptions { prefs.set(s.key == key, forKey: s.enabledKey) }
    }

    func testFilterTextLinesHandlesCRLF() {
        XCTAssertEqual(MioFilterText.lines("! a\r\n||x.com^\r\n\r\n##.ad\n||y.com^\r||z.com^"), ["! a", "||x.com^", "##.ad", "||y.com^", "||z.com^"])
        // 回归：Swift 里 "\r\n" 是一个 Character，旧代码按 Character 比较拆不开
        let crlf = "a\r\nb"
        XCTAssertEqual(crlf.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).count, 1, "旧写法拆不开 CRLF（说明根因）")
        XCTAssertEqual(MioFilterText.lines(crlf).count, 2)
    }

    func testCRLFSubscriptionCompilesAllRules() async {
        let prefs = MioMemoryPrefs()
        onlyList("2", prefs)
        let lines = ["! Title: AdGuard Base filter (Optimized)", "! Version: 2.4.97.99"] + (0..<3000).map { "||ad\($0).example^" }
            + ["###ad_banner", "##.banner-ad-container", "example.org#%#//scriptlet('set-constant', 'ads', 'false')"]
        let body = lines.joined(separator: "\r\n") + "\r\n"
        let m = MioFilterManager(directory: makeTempDir(), prefs: prefs, converter: MioBasicFilterConverter(), http: { _ in (200, Data(body.utf8), [:]) },
                                 advanced: .some(nil))
        _ = await m.refresh()
        XCTAssertEqual(m.state.lists["2"]?.version, "2.4.97.99", "CRLF 列表也能读出版本")
        let store = FakeRuleStore()
        _ = await m.compile(into: store)
        let meta = m.state.lists["2"]!
        XCTAssertEqual(meta.sourceRules, 3003)
        XCTAssertGreaterThanOrEqual(meta.contentRules, 3001, "3000 条网络规则 + 元素隐藏")
        XCTAssertEqual(meta.advancedRules, 1)
        XCTAssertEqual(meta.compileFormat, MioFilterManager.compileFormat)
        let json = store.compiled["mio.kit.2.0"] ?? ""
        XCTAssertTrue(json.contains("css-display-none") && json.contains("#ad_banner"), "## 元素隐藏 → css-display-none")
        XCTAssertGreaterThan(m.summary().contentRules, 3000)
    }

    func testStaleV040CacheIsRecompiled() async throws {
        let prefs = MioMemoryPrefs()
        onlyList("2", prefs)
        let dir = makeTempDir()
        let body = "! Version: 1\r\n||ads.example^\r\n||more.example^\r\n"
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("lists"), withIntermediateDirectories: true)
        try Data(body.utf8).write(to: dir.appendingPathComponent("lists/2.txt"))
        let sha = MioHash.sha256Hex(Data(body.utf8))
        // v0.4.0 留下的 state.json：没有 compileFormat，0 条但「编译成功」
        let old = """
        {"lastCheck":"2026-10-17T16:00:00Z","lastMessage":"6 个列表有更新","lists":{"2":{"compiledSha":"\(sha)","contentRules":0,"parts":1,"sha256":"\(sha)","sourceRules":0,"unsupported":0}}}
        """
        try Data(old.utf8).write(to: dir.appendingPathComponent("state.json"))
        let m = MioFilterManager(directory: dir, prefs: prefs, converter: MioBasicFilterConverter(), http: { _ in (304, Data(), [:]) }, advanced: .some(nil))
        XCTAssertEqual(m.state.lists["2"]?.parts, 1, "旧 state.json 能读")
        XCTAssertNil(m.state.lastSuccess)
        XCTAssertTrue(m.needsUpdateCheck, "旧版没有 lastSuccess：立即检查一次")
        XCTAssertFalse(m.activeIdentifiers().contains("mio.kit.2.0"), "旧格式的编译结果不算数")
        let store = FakeRuleStore()
        store.compiled["mio.kit.2.0"] = "[]" // 旧的空规则表还在 store 里
        _ = await m.compile(into: store)
        XCTAssertEqual(m.state.lists["2"]?.contentRules, 2, "编译格式变了：重编，不再命中旧的空表")
        XCTAssertNotEqual(store.compiled["mio.kit.2.0"], "[]")
    }

    func testRetriesThenSucceeds() async {
        let prefs = MioMemoryPrefs()
        onlyList("224", prefs)
        var calls = 0
        let m = MioFilterManager(directory: makeTempDir(), prefs: prefs, converter: MioBasicFilterConverter(), http: { _ in
            calls += 1
            if calls == 1 { throw URLError(.timedOut) }
            if calls == 2 { return (503, Data(), [:]) }
            return (200, Data("! x\n||a.example^\n".utf8), [:])
        }, advanced: .some(nil))
        m.retryDelays = [0, 0]
        let msg = await m.refresh()
        XCTAssertEqual(calls, 3, "超时、503 都重试")
        XCTAssertEqual(msg, "1 个列表有更新")
        XCTAssertNil(m.state.lists["224"]?.error)
        XCTAssertNotNil(m.state.lastSuccess)
        XCTAssertEqual(m.state.consecutiveFailures, 0)
        XCTAssertFalse(m.needsUpdateCheck, "成功后 24 小时内不再检查")
    }

    func testFailureBacksOffInsteadOfWaitingADay() async {
        let prefs = MioMemoryPrefs()
        onlyList("224", prefs)
        var calls = 0
        let m = MioFilterManager(directory: makeTempDir(), prefs: prefs, converter: MioBasicFilterConverter(), http: { _ in
            calls += 1; throw URLError(.notConnectedToInternet)
        }, advanced: .some(nil))
        m.retryDelays = [0, 0]
        XCTAssertTrue(m.needsUpdateCheck, "首次：订阅还没下载 → 立即检查")
        let msg = await m.refresh()
        XCTAssertTrue(msg.hasPrefix("部分失败"), msg)
        XCTAssertEqual(calls, 3)
        XCTAssertNil(m.state.lastSuccess)
        XCTAssertEqual(m.state.consecutiveFailures, 1)
        XCTAssertFalse(m.needsUpdateCheck, "刚失败：先退避 1 分钟")
        XCTAssertLessThanOrEqual(m.nextCheckDate().timeIntervalSinceNow, 61, "不是 24 小时后")
        m.mutate { $0.lastCheck = Date().addingTimeInterval(-61) }
        XCTAssertTrue(m.needsUpdateCheck, "退避时间到了就重试")
        XCTAssertEqual(MioFilterManager.retryBackoff(2), 300)
        XCTAssertEqual(MioFilterManager.retryBackoff(9), 3600)
        XCTAssertFalse(m.statusText().isEmpty)
    }

    func testEnablingASubscriptionNeedsImmediateDownload() async {
        let prefs = MioMemoryPrefs()
        onlyList("224", prefs)
        let m = MioFilterManager(directory: makeTempDir(), prefs: prefs, converter: MioBasicFilterConverter(), http: { req in
            (200, Data("! \(req.url!.lastPathComponent)\n||a.example^\n".utf8), [:])
        }, advanced: .some(nil))
        _ = await m.refresh()
        XCTAssertFalse(m.needsUpdateCheck)
        prefs.set(true, forKey: "mio.adblock.list.104") // 打开 EasyList China
        XCTAssertEqual(m.missingLists().map(\.key), ["104"])
        XCTAssertTrue(m.needsUpdateCheck, "打开新订阅：立即下载")
        _ = await m.refresh(onlyMissing: true)
        XCTAssertTrue(m.missingLists().isEmpty)
        XCTAssertFalse(m.needsUpdateCheck)
    }

    func testStatusTextShowsLoadedSkippedAndLastUpdate() async {
        let prefs = MioMemoryPrefs()
        onlyList("2", prefs)
        let body = "! Version: 9\n||a.example^\n||b.example^\n##.ad\n||c.example^$redirect=noopjs\nexample.org#%#//scriptlet('set-constant', 'x', 'true')\n"
        let m = MioFilterManager(directory: makeTempDir(), prefs: prefs, converter: MioBasicFilterConverter(), http: { _ in (200, Data(body.utf8), [:]) },
                                 advanced: .some(nil))
        XCTAssertTrue(m.statusText().contains("订阅尚未下载"))
        _ = await m.refresh()
        _ = await m.compile(into: FakeRuleStore())
        let s = m.summary()
        XCTAssertEqual(m.state.lists["2"]?.unsupported, 1, "redirect 修饰符跳过")
        XCTAssertEqual(m.state.lists["2"]?.advancedRules, 1)
        XCTAssertGreaterThanOrEqual(s.advancedRules, 1)
        let t = m.statusText()
        XCTAssertTrue(t.hasPrefix("已加载 \(s.loaded) 条"), t)
        XCTAssertTrue(t.contains("跳过 \(s.skipped) 条"), t)
        XCTAssertTrue(t.contains("上次更新 今天"), t)
        XCTAssertTrue(m.listDetails().contains("AdGuard Base 9："), m.listDetails())
    }

    func testAdvancedRulesReachEngineAndBecomeScript() async throws {
        let prefs = MioMemoryPrefs()
        onlyList("2", prefs)
        let body = "! x\n||a.example^\nexample.org#%#//scriptlet('set-constant', 'adsEnabled', 'false')\nexample.org#%#//scriptlet('abort-on-property-read', 'adblockDetector')\n"
        let engine = FakeAdvancedEngine()
        let m = MioFilterManager(directory: makeTempDir(), prefs: prefs, converter: MioBasicFilterConverter(), http: { _ in (200, Data(body.utf8), [:]) },
                                 advanced: engine)
        _ = await m.refresh()
        _ = await m.compile(into: FakeRuleStore())
        XCTAssertEqual(engine.built.count, 1)
        XCTAssertTrue(engine.built[0].contains("set-constant"))
        // 内容没变：不重建
        _ = await m.compile(into: FakeRuleStore())
        XCTAssertEqual(engine.built.count, 1)
        let js = try XCTUnwrap(m.pageScript(for: URL(string: "https://www.example.org/a")!, topURL: nil))
        XCTAssertTrue(js.contains("\"adsEnabled\"") && js.contains("\"adblockDetector\""), "两个 scriptlet 的参数")
        XCTAssertTrue(js.contains("var __mioS0=function"), "scriptlet 函数来自包内 AdGuard Scriptlets")
        XCTAssertNil(m.pageScript(for: URL(string: "https://other.example/")!, topURL: nil))
        XCTAssertNil(m.pageScript(for: URL(string: "mio://home")!, topURL: nil))
    }

    func testBundledScriptletLibrary() throws {
        let lib = try XCTUnwrap(MioScriptletLibrary.bundled, "Resources/adguard/scriptlets.corelibs.json")
        XCTAssertEqual(lib.version, "2.5.1")
        for n in ["set-constant", "abort-on-property-read", "abort-on-property-write", "abort-current-inline-script", "json-prune",
                  "prevent-setTimeout", "prevent-setInterval", "prevent-fetch", "prevent-xhr", "remove-attr", "remove-class",
                  "ubo-set-constant.js", "ubo-json-prune.js", "set-cookie", "no-topics"] {
            XCTAssertTrue(lib.supports(n), n)
        }
        XCTAssertNotNil(MioScriptletLibrary.bundledExtendedCss)
        let conf = MioCosmeticConfig(css: [".ad", "body { overflow: auto !important; }"], extendedCss: ["div:has(> .sponsor)"], js: ["window.x=1;"],
                                     scriptlets: [.init(name: "set-constant", args: ["a", "1"]), .init(name: "set-constant", args: ["b", "true"]),
                                                  .init(name: "set-constant", args: ["a", "1"]), .init(name: "no-such-scriptlet", args: [])])
        let js = try XCTUnwrap(MioAdvancedScript.build(conf, scriptlets: lib, extendedCssLib: MioScriptletLibrary.bundledExtendedCss))
        XCTAssertEqual(js.components(separatedBy: "var __mioS").count - 1, 1, "同一函数只定义一次")
        XCTAssertEqual(js.components(separatedBy: "try{__mioS0(").count - 1, 2, "重复的调用去重，不认识的跳过")
        XCTAssertTrue(js.contains(".ad {display:none!important;}") && js.contains("body { overflow: auto !important; }"))
        XCTAssertTrue(js.contains("new ExtendedCss"))
        XCTAssertNil(MioAdvancedScript.build(MioCosmeticConfig(), scriptlets: lib, extendedCssLib: nil))
    }

    func testDefaultSubscriptions() {
        let prefs = MioMemoryPrefs()
        let on = MioFilterCatalog.enabledLists(prefs).map(\.name)
        for n in ["AdGuard Base", "AdGuard 中文", "EasyList"] { XCTAssertTrue(on.contains(n), n) }
        XCTAssertFalse(on.contains("EasyList China"), "已包含在 AdGuard 中文里，默认不开")
        XCTAssertNotNil(MioFilterCatalog.subscriptions.first { $0.key == "104" })
    }
}
