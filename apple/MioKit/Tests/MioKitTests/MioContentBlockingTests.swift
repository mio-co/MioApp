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
        XCTAssertEqual(r.unsupported, 7)
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
