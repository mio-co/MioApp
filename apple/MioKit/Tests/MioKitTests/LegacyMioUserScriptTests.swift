import XCTest
@testable import MioKit

final class MetadataTests: XCTestCase {
    let sample = """
    // some preamble
    // ==UserScript==
    // @name         Demo Script
    // @name:zh-CN   演示脚本
    // @namespace    https://example.com/ns
    // @version      1.2.3
    // @description  Does things
    // @description:zh-CN 做点事
    // @author       Mio
    // @match        https://*.example.com/*
    // @match        *://news.ycombinator.com/item?id=*
    // @include      /^https?://(www\\.)?google\\.[a-z.]+/search.*$/i
    // @include      http*://foo.tld/*
    // @exclude      *://*.example.com/admin/*
    // @exclude-match https://shop.example.com/*
    // @RUN-AT       document-start
    // @grant        GM_getValue
    // @grant        GM_setValue
    // @grant        GM_xmlhttpRequest
    // @require      https://cdn.example.com/lib.js#sha256=abc
    // @require      lib2.js
    // @resource     css https://cdn.example.com/style.css
    // @connect      api.example.com
    // @connect      self
    // @noframes
    // @updateURL    https://example.com/demo.meta.js
    // @downloadURL  https://example.com/demo.user.js
    // @homepageURL  https://example.com
    // @unknown      ignored
    // ==/UserScript==
    console.log('hi');
    """

    func testParsesAllKeys() throws {
        let m = try MioUserScriptParser.parse(sample)
        XCTAssertEqual(m.name, "Demo Script")
        XCTAssertEqual(m.displayName, "演示脚本")
        XCTAssertEqual(m.namespace, "https://example.com/ns")
        XCTAssertEqual(m.version, "1.2.3")
        XCTAssertEqual(m.description, "Does things")
        XCTAssertEqual(m.author, "Mio")
        XCTAssertEqual(m.matches, ["https://*.example.com/*", "*://news.ycombinator.com/item?id=*"])
        XCTAssertEqual(m.includes.count, 2)
        XCTAssertEqual(m.excludes, ["*://*.example.com/admin/*"])
        XCTAssertEqual(m.excludeMatches, ["https://shop.example.com/*"])
        XCTAssertEqual(m.runAt, .documentStart)
        XCTAssertEqual(m.grants, ["GM_getValue", "GM_setValue", "GM_xmlhttpRequest"])
        XCTAssertFalse(m.grantsNone)
        XCTAssertEqual(m.requires, ["https://cdn.example.com/lib.js#sha256=abc", "lib2.js"])
        XCTAssertEqual(m.resources, ["css": "https://cdn.example.com/style.css"])
        XCTAssertEqual(m.connects, ["api.example.com", "self"])
        XCTAssertTrue(m.noframes)
        XCTAssertEqual(m.updateURL, "https://example.com/demo.meta.js")
        XCTAssertEqual(m.downloadURL, "https://example.com/demo.user.js")
        XCTAssertEqual(m.homepage, "https://example.com")
        XCTAssertTrue(m.header.hasPrefix("// ==UserScript=="))
        XCTAssertTrue(m.header.hasSuffix("// ==/UserScript=="))
        XCTAssertFalse(m.header.contains("console.log"))
    }

    func testDefaults() throws {
        let m = try MioUserScriptParser.parse("// ==UserScript==\n// @name x\n// ==/UserScript==\n")
        XCTAssertEqual(m.runAt, .documentIdle)
        XCTAssertTrue(m.grantsNone)
        XCTAssertFalse(m.noframes)
        XCTAssertEqual(m.displayName, "x")
        let none = try MioUserScriptParser.parse("// ==UserScript==\n// @name x\n// @grant none\n// @run-at document-end\n// ==/UserScript==")
        XCTAssertTrue(none.grantsNone)
        XCTAssertEqual(none.runAt, .documentEnd)
        let body = try MioUserScriptParser.parse("// ==UserScript==\n// @name x\n// @run-at document-body\n// ==/UserScript==")
        XCTAssertEqual(body.runAt, .documentEnd)
    }

    func testWindowsLineEndingsAndIndent() throws {
        let m = try MioUserScriptParser.parse("  //  ==UserScript==\r\n  //   @name   CRLF  \r\n//@version 2\r\n// ==/UserScript==\r\nfoo()")
        XCTAssertEqual(m.name, "CRLF")
        XCTAssertEqual(m.version, "2")
    }

    func testErrors() {
        XCTAssertThrowsError(try MioUserScriptParser.parse("console.log(1)")) { XCTAssertEqual($0 as? MioUserScriptError, .noMetadataBlock) }
        XCTAssertThrowsError(try MioUserScriptParser.parse("// ==UserScript==\n// @name x\n")) { XCTAssertEqual($0 as? MioUserScriptError, .noMetadataBlock) }
        XCTAssertThrowsError(try MioUserScriptParser.parse("// ==UserScript==\n// @version 1\n// ==/UserScript==")) { XCTAssertEqual($0 as? MioUserScriptError, .missingName) }
    }
}

final class MatchPatternTests: XCTestCase {
    func rule(_ p: String, file: StaticString = #file, line: UInt = #line) -> MioURLRule {
        guard let r = MioUserScriptPattern.matchPattern(p) else {
            XCTFail("pattern \(p) should be valid", file: file, line: line)
            return MioURLRule(source: "(?!)", ignoreCase: false)
        }
        return r
    }

    func testChromeMatchPatterns() {
        // Chrome 文档里的例子
        let all = rule("<all_urls>")
        XCTAssertTrue(all.matches("https://a.com/"))
        XCTAssertTrue(all.matches("file:///tmp/x.html"))
        XCTAssertFalse(all.matches("chrome://settings/"))

        let anyHttp = rule("*://*/*")
        XCTAssertTrue(anyHttp.matches("http://example.org/"))
        XCTAssertTrue(anyHttp.matches("https://a.b.c/d?e=f"))
        XCTAssertFalse(anyHttp.matches("ftp://example.org/"))
        XCTAssertFalse(anyHttp.matches("file:///a"))

        let sub = rule("https://*.google.com/foo*bar")
        XCTAssertTrue(sub.matches("https://www.google.com/foo/baz/bar"))
        XCTAssertTrue(sub.matches("https://docs.google.com/foobar"))
        XCTAssertTrue(sub.matches("https://google.com/foobar"))       // *. 也匹配裸域
        XCTAssertFalse(sub.matches("http://www.google.com/foobar"))   // scheme 不同
        XCTAssertFalse(sub.matches("https://www.google.com.evil.com/foobar"))
        XCTAssertFalse(sub.matches("https://evilgoogle.com/foobar"))

        let exact = rule("http://example.org/foo/bar.html")
        XCTAssertTrue(exact.matches("http://example.org/foo/bar.html"))
        XCTAssertFalse(exact.matches("http://example.org/foo/bar.html?x=1"))
        XCTAssertFalse(exact.matches("http://example.org/foo/bar.htmlx"))

        let root = rule("https://example.com/")
        XCTAssertTrue(root.matches("https://example.com/"))
        XCTAssertFalse(root.matches("https://example.com/a"))

        let local = rule("http://127.0.0.1/*")
        XCTAssertTrue(local.matches("http://127.0.0.1/"))
        XCTAssertTrue(local.matches("http://127.0.0.1:8080/x"))   // 不写端口 = 任意端口

        let port = rule("http://localhost:3000/*")
        XCTAssertTrue(port.matches("http://localhost:3000/app"))
        XCTAssertFalse(port.matches("http://localhost:4000/app"))

        let query = rule("*://news.ycombinator.com/item?id=*")
        XCTAssertTrue(query.matches("https://news.ycombinator.com/item?id=123"))
        XCTAssertFalse(query.matches("https://news.ycombinator.com/itemXid=123"))   // ? 是字面量

        let dot = rule("https://a.com/x.y")
        XCTAssertFalse(dot.matches("https://a.com/xzy"))   // . 是字面量

        let file = rule("file:///foo*")
        XCTAssertTrue(file.matches("file:///foo/bar.html"))
        XCTAssertFalse(file.matches("file:///bar"))

        XCTAssertTrue(rule("https://example.com").matches("https://example.com/anything"))   // 宽松：缺路径 = /*
    }

    func testInvalidMatchPatterns() {
        for p in ["https://*foo/bar", "https://foo.*.bar/baz", "http:/bar", "foo://*", "https:///x", "*://", "https://a*b.com/", "file://host/x"] {
            XCTAssertNil(MioUserScriptPattern.matchPattern(p), p)
        }
    }

    func testIncludeGlobs() {
        func g(_ p: String) -> MioURLRule { MioUserScriptPattern.glob(p)! }
        XCTAssertTrue(g("*").matches("https://anything/"))
        XCTAssertTrue(g("http*://example.com/*").matches("https://example.com/a?b#c"))
        XCTAssertTrue(g("http*://example.com/*").matches("http://example.com/"))
        XCTAssertFalse(g("http://example.com/*").matches("https://example.com/"))
        XCTAssertTrue(g("*example.com*").matches("https://sub.example.com/x"))
        XCTAssertTrue(g("HTTPS://EXAMPLE.COM/*").matches("https://example.com/x"))   // 大小写不敏感
        XCTAssertFalse(g("https://example.com/a.b").matches("https://example.com/aXb"))
        XCTAssertTrue(g("https://example.com/a?b").matches("https://example.com/a?b"))
        XCTAssertFalse(g("https://example.com/a?b").matches("https://example.com/ab"))
        // .tld
        let tld = g("https://www.google.tld/search*")
        XCTAssertTrue(tld.matches("https://www.google.com/search?q=1"))
        XCTAssertTrue(tld.matches("https://www.google.co.uk/search?q=1"))
        XCTAssertTrue(tld.matches("https://www.google.de/search"))
        XCTAssertFalse(tld.matches("https://www.google.evil.example/search"))
        XCTAssertTrue(g("*://*.example.tld").matches("https://a.example.org"))
        // 正则
        let re = g("/^https?://(www\\.)?google\\.[a-z.]+/search.*$/i")
        XCTAssertTrue(re.ignoreCase)
        XCTAssertTrue(re.matches("https://WWW.google.com/search?q=x"))
        XCTAssertFalse(re.matches("https://google.com/maps"))
        XCTAssertNil(MioUserScriptPattern.glob("/(unclosed/"))
        XCTAssertNil(MioUserScriptPattern.glob(""))
    }

    func testRulesCombination() throws {
        let m = try MioUserScriptParser.parse("""
        // ==UserScript==
        // @name r
        // @match https://*.example.com/*
        // @include http*://other.org/*
        // @exclude *://*.example.com/admin/*
        // @exclude-match https://shop.example.com/*
        // @match not a pattern
        // ==/UserScript==
        """)
        let r = MioUserScriptRules(meta: m)
        XCTAssertEqual(r.invalid, ["not a pattern"])
        XCTAssertFalse(r.matchAll)
        XCTAssertTrue(r.matches("https://www.example.com/page"))
        XCTAssertTrue(r.matches("https://www.example.com/page#frag"))
        XCTAssertTrue(r.matches("http://other.org/x"))
        XCTAssertFalse(r.matches("https://www.example.com/admin/users"))
        XCTAssertFalse(r.matches("https://shop.example.com/cart"))
        XCTAssertFalse(r.matches("https://unrelated.net/"))
        XCTAssertFalse(r.matches("http://www.example.com/"))   // @match 限定 https

        let none = MioUserScriptRules(meta: try MioUserScriptParser.parse("// ==UserScript==\n// @name n\n// @exclude *://bad.com/*\n// ==/UserScript=="))
        XCTAssertTrue(none.matchAll)
        XCTAssertTrue(none.matches("https://any.site/"))
        XCTAssertFalse(none.matches("https://bad.com/x"))
        XCTAssertFalse(none.matches("about:blank"))
    }
}

final class VersionConnectSourceTests: XCTestCase {
    func testVersionCompare() {
        XCTAssertTrue(MioUserScriptVersion.isNewer("1.2.4", than: "1.2.3"))
        XCTAssertTrue(MioUserScriptVersion.isNewer("1.10", than: "1.9"))
        XCTAssertTrue(MioUserScriptVersion.isNewer("2", than: "1.99.99"))
        XCTAssertTrue(MioUserScriptVersion.isNewer("1.0", than: "1.0b"))
        XCTAssertTrue(MioUserScriptVersion.isNewer("1.0b2", than: "1.0b1"))
        XCTAssertTrue(MioUserScriptVersion.isNewer("2024.10.17", than: "2024.9.30"))
        XCTAssertFalse(MioUserScriptVersion.isNewer("1.0", than: "1.0.0"))
        XCTAssertFalse(MioUserScriptVersion.isNewer("1.2.3", than: "1.2.3"))
        XCTAssertFalse(MioUserScriptVersion.isNewer("0.9", than: "1.0"))
        XCTAssertEqual(MioUserScriptVersion.compare("1.0.0", "1"), .orderedSame)
    }

    func testConnect() {
        let c = ["api.example.com", "self", "192.168.1.2", "localhost"]
        XCTAssertEqual(MioUserScriptConnect.verdict(target: "page.org", pageHost: "page.org", connects: []), .sameOrigin)
        XCTAssertEqual(MioUserScriptConnect.verdict(target: "api.example.com", pageHost: "page.org", connects: c), .declared)
        XCTAssertEqual(MioUserScriptConnect.verdict(target: "v2.api.example.com", pageHost: "page.org", connects: c), .declared)
        XCTAssertEqual(MioUserScriptConnect.verdict(target: "example.com", pageHost: "page.org", connects: c), .undeclared)
        XCTAssertEqual(MioUserScriptConnect.verdict(target: "evilapi.example.com", pageHost: "page.org", connects: ["api.example.com"]), .undeclared)
        XCTAssertEqual(MioUserScriptConnect.verdict(target: "192.168.1.2", pageHost: "page.org", connects: c), .declared)
        XCTAssertEqual(MioUserScriptConnect.verdict(target: "localhost", pageHost: "page.org", connects: c), .declared)
        XCTAssertEqual(MioUserScriptConnect.verdict(target: "anything.net", pageHost: "page.org", connects: ["*"]), .declared)
        XCTAssertTrue(MioUserScriptConnect.isDeclared(host: "cdn.page.org", connects: ["self"], pageHost: "page.org"))
        XCTAssertFalse(MioUserScriptConnect.isDeclared(host: "x.com", connects: [], pageHost: nil))
        XCTAssertTrue(MioUserScriptConnect.isDeclared(host: "API.Example.com", connects: ["https://api.example.com/v1"], pageHost: nil))
        XCTAssertEqual(MioUserScriptConnect.normalizeHost("https://Foo.com:8443/x"), "foo.com")
        XCTAssertEqual(MioUserScriptConnect.normalizeHost("*.foo.com"), "foo.com")
        XCTAssertEqual(MioUserScriptConnect.normalizeHost("[::1]:80"), "::1")
    }

    func testInstallURLs() {
        XCTAssertEqual(MioUserScriptSource.installURL(from: "https://github.com/u/r/blob/main/dir/x.user.js")?.absoluteString,
                       "https://raw.githubusercontent.com/u/r/main/dir/x.user.js")
        XCTAssertEqual(MioUserScriptSource.installURL(from: "https://greasyfork.org/zh-CN/scripts/1682-google-hit-hider")?.absoluteString,
                       "https://greasyfork.org/scripts/1682/code/script.user.js")
        XCTAssertEqual(MioUserScriptSource.installURL(from: "https://greasyfork.org/scripts/1682")?.absoluteString,
                       "https://greasyfork.org/scripts/1682/code/script.user.js")
        XCTAssertEqual(MioUserScriptSource.installURL(from: " https://update.greasyfork.org/scripts/1682/x.user.js ")?.absoluteString,
                       "https://update.greasyfork.org/scripts/1682/x.user.js")
        XCTAssertEqual(MioUserScriptSource.installURL(from: "https://greasyfork.org/scripts/1682/code/x.user.js")?.absoluteString,
                       "https://greasyfork.org/scripts/1682/code/x.user.js")
        XCTAssertEqual(MioUserScriptSource.installURL(from: "https://raw.githubusercontent.com/u/r/main/x.user.js#frag")?.absoluteString,
                       "https://raw.githubusercontent.com/u/r/main/x.user.js")
        XCTAssertNil(MioUserScriptSource.installURL(from: "javascript:alert(1)"))
        XCTAssertNil(MioUserScriptSource.installURL(from: "not a url"))
        XCTAssertTrue(MioUserScriptSource.looksLikeUserScript(URL(string: "https://x.com/a/B.USER.JS?x=1")!))
        XCTAssertFalse(MioUserScriptSource.looksLikeUserScript(URL(string: "https://x.com/a/b.js")!))
        XCTAssertFalse(MioUserScriptSource.looksLikeUserScript(URL(string: "file:///a.user.js")!))
    }

    func testUpdateURLs() throws {
        var m = try MioUserScriptParser.parse("// ==UserScript==\n// @name u\n// ==/UserScript==")
        XCTAssertNil(MioUserScriptSource.updateCheckURL(meta: m, sourceURL: nil))
        XCTAssertEqual(MioUserScriptSource.updateCheckURL(meta: m, sourceURL: "https://s/x.user.js")?.absoluteString, "https://s/x.user.js")
        m.updateURL = "https://s/x.meta.js"
        m.downloadURL = "https://s/dl.user.js"
        XCTAssertEqual(MioUserScriptSource.updateCheckURL(meta: m, sourceURL: "https://s/x.user.js")?.absoluteString, "https://s/x.meta.js")
        XCTAssertEqual(MioUserScriptSource.downloadURL(meta: m, sourceURL: "https://s/x.user.js")?.absoluteString, "https://s/dl.user.js")
        m.downloadURL = nil
        XCTAssertEqual(MioUserScriptSource.downloadURL(meta: m, sourceURL: nil), nil)   // .meta.js 不能当下载地址
    }
}

final class StoreTests: XCTestCase {
    var dir: URL!

    override func setUp() {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mio-us-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    func pkg(_ name: String, ns: String = "ns", version: String = "1", connects: [String] = []) throws -> MioUserScriptPackage {
        let connectLines = connects.map { "// @connect \($0)\n" }.joined()
        let code = "// ==UserScript==\n// @name \(name)\n// @namespace \(ns)\n// @version \(version)\n// @grant GM_setValue\n\(connectLines)// ==/UserScript==\nvoid 0;"
        return MioUserScriptPackage(meta: try MioUserScriptParser.parse(code), code: code, requireCache: [:], resourceCache: [:], sourceURL: "https://s/\(name).user.js")
    }

    func testGMStorageIsolatedPerScript() throws {
        let store = MioUserScriptStore(directory: dir)
        let a = store.install(try pkg("A"))
        let b = store.install(try pkg("B"))
        XCTAssertNotEqual(a.id, b.id)
        store.values.set(a.id, "k", "\"from A\"")
        store.values.set(b.id, "k", "42")
        store.values.set(a.id, "only-a", "true")
        XCTAssertEqual(store.values.get(a.id, "k"), "\"from A\"")
        XCTAssertEqual(store.values.get(b.id, "k"), "42")
        XCTAssertNil(store.values.get(b.id, "only-a"))
        XCTAssertEqual(store.values.keys(a.id), ["k", "only-a"])
        XCTAssertEqual(store.values.keys(b.id), ["k"])

        // 持久化：新实例读回来，仍然隔离
        let reopened = MioUserScriptStore(directory: dir)
        XCTAssertEqual(reopened.scripts.map(\.meta.name), ["A", "B"])
        XCTAssertEqual(reopened.values.all(a.id), ["k": "\"from A\"", "only-a": "true"])
        XCTAssertEqual(reopened.values.all(b.id), ["k": "42"])

        // 注入代码只带自己的值
        let srcA = MioUserScriptRuntime.source(for: reopened.script(id: a.id)!, values: reopened.values.all(a.id), appVersion: "t")
        XCTAssertTrue(srcA.contains("from A"))
        XCTAssertFalse(srcA.contains("\"42\""))

        // 删除脚本连同它的值；另一个不受影响
        reopened.values.delete(b.id, "k")
        XCTAssertEqual(reopened.values.keys(b.id), [])
        reopened.delete(a.id)
        XCTAssertNil(reopened.script(id: a.id))
        XCTAssertEqual(reopened.values.all(a.id), [:])
        XCTAssertEqual(MioUserScriptStore(directory: dir).values.all(a.id), [:])
    }

    func testValueStoreRejectsPathTraversalAndOversize() {
        let v = MioUserScriptValueStore(directory: dir)
        v.set("../../etc/passwd", "k", "1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.deletingLastPathComponent().appendingPathComponent("etc").path))
        XCTAssertEqual(v.get("../../etc/passwd", "k"), "1")
        let big = String(repeating: "x", count: MioUserScriptValueStore.maxBytesPerScript + 1)
        XCTAssertFalse(v.set("id", "big", big))
        XCTAssertNil(v.get("id", "big"))
    }

    func testReinstallSameIdentityUpdatesInPlace() throws {
        let store = MioUserScriptStore(directory: dir)
        let a = store.install(try pkg("A", version: "1", connects: ["api.a.com", "old.a.com"]))
        store.setEnabled(a.id, false)
        store.values.set(a.id, "k", "1")
        store.setConnectDecision(a.id, host: "api.a.com", allow: true)
        store.setConnectDecision(a.id, host: "old.a.com", allow: true)
        let a2 = store.install(try pkg("A", version: "2", connects: ["api.a.com"]))
        XCTAssertEqual(a2.id, a.id)
        XCTAssertEqual(store.scripts.count, 1)
        XCTAssertEqual(a2.meta.version, "2")
        XCTAssertFalse(a2.enabled)                       // 保留启用状态
        XCTAssertEqual(store.values.get(a.id, "k"), "1") // 保留数据
        XCTAssertEqual(a2.connectDecisions, ["api.a.com": true])   // 不再声明的域名授权被丢弃
        // 不同 namespace = 不同脚本
        let other = store.install(try pkg("A", ns: "other"))
        XCTAssertNotEqual(other.id, a.id)
        XCTAssertEqual(store.scripts.count, 2)
    }

    func testRuntimeSourceEmbedsRulesAndRequires() throws {
        let code = "// ==UserScript==\n// @name R\n// @match https://*.example.com/*\n// @require https://cdn/lib.js\n// @run-at document-end\n// @grant none\n// ==/UserScript==\nwindow.x = libValue;"
        let meta = try MioUserScriptParser.parse(code)
        let s = MioUserScript(id: "abc", meta: meta, code: code, requireCache: ["https://cdn/lib.js": "var libValue = 7;"], installedAt: Date(), updatedAt: Date())
        XCTAssertFalse(s.isolated)
        let src = MioUserScriptRuntime.source(for: s, values: ["leak": "1"], appVersion: "0.3.3")
        XCTAssertTrue(src.hasPrefix("(function (C, main) {"))
        XCTAssertTrue(src.contains("var libValue = 7;"))
        XCTAssertLessThan(src.range(of: "var libValue = 7;")!.lowerBound, src.range(of: "window.x = libValue;")!.lowerBound)
        XCTAssertTrue(src.contains("\"runAt\":\"document-end\""))
        XCTAssertTrue(src.contains("\"isolated\":false"))
        XCTAssertFalse(src.contains("leak"))   // 页面世界的脚本不带存储
    }
}

final class WebRTCSettingsTests: XCTestCase {
    var suite: String!

    override func setUp() {
        suite = "mio-webrtc-test-\(UUID().uuidString)"
        MioWebRTCSettings.defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        MioWebRTCSettings.defaults.removePersistentDomain(forName: suite)
        MioWebRTCSettings.defaults = .standard
    }

    func testDefaultsAndAllowlist() {
        XCTAssertTrue(MioWebRTCSettings.enabled)
        XCTAssertEqual(MioWebRTCSettings.allowlist, [])
        XCTAssertNotNil(MioWebRTCSettings.script())
        MioWebRTCSettings.setAllowed("https://www.Meet.Google.com/abc-defg", true)
        XCTAssertEqual(MioWebRTCSettings.allowlist, ["meet.google.com"])
        XCTAssertTrue(MioWebRTCSettings.isAllowed("meet.google.com"))
        XCTAssertTrue(MioWebRTCSettings.isAllowed("a.meet.google.com"))
        XCTAssertFalse(MioWebRTCSettings.isAllowed("google.com"))
        XCTAssertFalse(MioWebRTCSettings.isAllowed("evilmeet.google.com"))
        XCTAssertTrue(MioWebRTCSettings.script()!.contains("\"allow\":[\"meet.google.com\"]"))
        MioWebRTCSettings.setAllowed("a.meet.google.com", false)
        XCTAssertEqual(MioWebRTCSettings.allowlist, [])
        MioWebRTCSettings.enabled = false
        XCTAssertNil(MioWebRTCSettings.script())
    }

    func testNormalize() {
        XCTAssertEqual(MioWebRTCSettings.normalize(" HTTPS://user@www.Zoom.us:443/j/1 "), "zoom.us")
        XCTAssertEqual(MioWebRTCSettings.normalize("*.discord.com"), "discord.com")
        XCTAssertEqual(MioWebRTCSettings.normalize("teams.microsoft.com."), "teams.microsoft.com")
    }

    func testTemplateHasPlaceholderOnce() {
        XCTAssertEqual(MioWebRTCGuard.template.components(separatedBy: MioWebRTCGuard.configPlaceholder).count, 2)
        XCTAssertFalse(MioWebRTCGuard.script(allow: []).contains(MioWebRTCGuard.configPlaceholder))
    }
}

/// Swift 编译出的正则交给注入页面的 JS（new RegExp）用：把规则和期望写进 js/fixtures/userscript-rules.json，
/// 这里校验 fixture 与当前编译结果一致（ICU 判定），js/userscripts.test.mjs 用 JS 正则引擎跑同一批用例。
/// 更新 fixture：MIO_WRITE_FIXTURES=1 swift test --filter RuleFixtureTests
final class RuleFixtureTests: XCTestCase {
    struct Case: Codable, Equatable {
        var kind: String
        var pattern: String
        var rule: MioURLRule
        var urls: [String: Bool]
    }

    static let inputs: [(String, String, [String: Bool])] = [
        ("match", "https://*.example.com/*", ["https://www.example.com/a?b": true, "https://example.com/": true, "http://www.example.com/": false, "https://example.com.evil.org/": false, "https://xexample.com/": false]),
        ("match", "*://*/*", ["http://a.b/": true, "https://a.b:8080/x": true, "file:///x": false, "ftp://a.b/": false]),
        ("match", "<all_urls>", ["https://a/": true, "file:///etc/hosts": true, "about:blank": false]),
        ("match", "http://example.org/foo/bar.html", ["http://example.org/foo/bar.html": true, "http://example.org/foo/bar.html?q": false, "http://example.org/foo/barXhtml": false]),
        ("match", "*://news.ycombinator.com/item?id=*", ["https://news.ycombinator.com/item?id=1": true, "https://news.ycombinator.com/itemid=1": false]),
        ("match", "http://localhost:3000/*", ["http://localhost:3000/": true, "http://localhost:3001/": false]),
        ("match", "https://www.google.tld/search*", ["https://www.google.co.jp/search?q=1": true, "https://www.google.com/maps": false]),
        ("glob", "http*://example.com/*", ["https://example.com/x#y": true, "http://example.com/": true, "https://sub.example.com/": false]),
        ("glob", "*example.com*", ["https://sub.example.com/": true, "https://example.org/": false]),
        ("glob", "HTTPS://EXAMPLE.COM/A?B", ["https://example.com/a?b": true, "https://example.com/ab": false]),
        ("glob", "*://*.google.tld/*", ["https://www.google.co.uk/x": true, "https://www.google.de/": true, "https://google.de/": false]),
        ("glob", "/^https?://(www\\.)?github\\.com/[^/]+/[^/]+/?$/i", ["https://GitHub.com/a/b": true, "https://github.com/a/b/issues": false]),
        ("glob", "*", ["https://anything/": true]),
    ]

    static var fixtureURL: URL {
        // MioKit 里复用 tools/MioAppTests 的同一份 fixture（只读；更新仍在 tools/MioAppTests 里做）
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("tools/MioAppTests/js/fixtures/userscript-rules.json")
    }

    func compiled() throws -> [Case] {
        try Self.inputs.map { kind, pattern, urls in
            let rule = try XCTUnwrap(kind == "match" ? MioUserScriptPattern.matchPattern(pattern) : MioUserScriptPattern.glob(pattern), pattern)
            for (u, want) in urls { XCTAssertEqual(rule.matches(u), want, "\(pattern) vs \(u)") }
            return Case(kind: kind, pattern: pattern, rule: rule, urls: urls)
        }
    }

    func testFixtureMatchesCompiledRules() throws {
        let cases = try compiled()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(cases)
        _ = data
        guard FileManager.default.fileExists(atPath: Self.fixtureURL.path) else { throw XCTSkip("不在仓库里运行：没有 tools/MioAppTests fixture") }
        let onDisk = try JSONDecoder().decode([Case].self, from: Data(contentsOf: Self.fixtureURL))
        XCTAssertEqual(onDisk, cases, "fixture 过期：MIO_WRITE_FIXTURES=1 swift test --filter RuleFixtureTests")
    }
}
