import XCTest
@testable import MioKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class MioUserScriptEngineTests: XCTestCase {
    static let script = """
    // ==UserScript==
    // @name         Demo
    // @namespace    mio.test
    // @version      1.0
    // @match        https://example.com/*
    // @exclude      https://example.com/private/*
    // @run-at       document-start
    // @grant        GM_getValue
    // @grant        GM_setValue
    // @grant        GM_xmlhttpRequest
    // @grant        GM_addStyle
    // @connect      api.example.com
    // @require      https://cdn.example.com/lib.js#sha256=REPLACE
    // @updateURL    https://example.com/demo.meta.js
    // ==/UserScript==
    GM_addStyle('body{color:red}');
    """

    override func tearDown() { MioUserScriptInstaller.fetch = { _ in throw URLError(.notConnectedToInternet) } }

    func testInstallWithRequireIntegrityAndInjection() async throws {
        let lib = Data("window.lib = 1;".utf8)
        let code = Self.script.replacingOccurrences(of: "REPLACE", with: MioHash.sha256Hex(lib))
        MioUserScriptInstaller.fetch = { req in
            XCTAssertNil(req.url?.fragment, "完整性片段不发给服务器")
            return (lib, 200)
        }
        let engine = MioUserScriptEngine(directory: makeTempDir())
        var changes = 0
        engine.onChange = { changes += 1 }
        let pkg = try await MioUserScriptInstaller.prepare(code: code, sourceURL: "https://example.com/demo.user.js")
        let s = engine.install(pkg)
        XCTAssertEqual(changes, 1)
        XCTAssertTrue(s.isolated)
        XCTAssertEqual(s.meta.connects, ["api.example.com"])
        let scripts = engine.moduleScripts()
        XCTAssertEqual(scripts.count, 1)
        XCTAssertEqual(scripts[0].world, .isolated("mio.userscript.\(s.id)"))
        XCTAssertEqual(scripts[0].injection, .documentStart)
        XCTAssertTrue(scripts[0].source.contains("window.lib = 1;"), "@require 内联")
        XCTAssertTrue(s.rules.matches("https://example.com/a"))
        XCTAssertFalse(s.rules.matches("https://example.com/private/x"))
        XCTAssertEqual(engine.isolatedWorldNames, ["mio.userscript.\(s.id)"])
        // GM 值：变化计数（宿主据此重装注入代码）
        XCTAssertTrue(engine.setValue(s.id, "k", "\"v\""))
        XCTAssertEqual(engine.valuesVersion, 1)
        XCTAssertTrue(engine.moduleScripts()[0].source.contains("\\\"v\\\""), "值快照烘焙进注入代码")
        // 停用 → 不注入、没有通道
        engine.setEnabled(s.id, false)
        XCTAssertTrue(engine.moduleScripts().isEmpty)
        XCTAssertTrue(engine.isolatedWorldNames.isEmpty)
        // 持久化（与 v0.3.x 同格式同目录结构）
        let again = MioUserScriptEngine(directory: engine.store.directory)
        XCTAssertEqual(again.scripts.map { $0.meta.name }, ["Demo"])
        XCTAssertEqual(again.store.values.get(s.id, "k"), "\"v\"")
    }

    func testIntegrityMismatchBlocksInstall() async {
        let code = Self.script.replacingOccurrences(of: "REPLACE", with: String(repeating: "0", count: 64))
        MioUserScriptInstaller.fetch = { _ in (Data("evil()".utf8), 200) }
        do {
            _ = try await MioUserScriptInstaller.prepare(code: code, sourceURL: nil)
            XCTFail("校验失败应拒绝安装")
        } catch {
            XCTAssertTrue("\(error)".contains("校验失败") || (error as? LocalizedError)?.errorDescription?.contains("校验失败") == true, "\(error)")
        }
    }

    func testGrantNoneRunsInPageWorldAndDocumentEnd() throws {
        let engine = MioUserScriptEngine(directory: makeTempDir())
        let meta = try MioUserScriptParser.parse("// ==UserScript==\n// @name P\n// @include *\n// @grant none\n// ==/UserScript==\nconsole.log(1)")
        let s = engine.install(MioUserScriptPackage(meta: meta, code: "console.log(1)", requireCache: [:], resourceCache: [:], sourceURL: nil))
        XCTAssertFalse(s.isolated)
        let m = engine.moduleScripts()[0]
        XCTAssertEqual(m.world, .page)
        XCTAssertEqual(m.injection, .documentEnd, "默认 document-idle → documentEnd")
        XCTAssertTrue(engine.isolatedWorldNames.isEmpty, "@grant none 不开原生通道")
        XCTAssertNil(engine.script(forWorld: "mio.userscript.nope"))
        XCTAssertEqual(engine.script(forWorld: s.worldName)?.id, s.id)
    }

    func testUpdateCheck() async throws {
        let engine = MioUserScriptEngine(directory: makeTempDir())
        let v1 = "// ==UserScript==\n// @name U\n// @namespace n\n// @version 1.0\n// @match https://a.com/*\n// @downloadURL https://a.com/u.user.js\n// ==/UserScript==\n1"
        let v2 = v1.replacingOccurrences(of: "1.0", with: "1.1").replacingOccurrences(of: "\n1", with: "\n2")
        engine.install(try await MioUserScriptInstaller.prepare(code: v1, sourceURL: "https://a.com/u.user.js"))
        MioUserScriptInstaller.fetch = { _ in (Data(v2.utf8), 200) }
        let r = await MioUserScriptInstaller.updateAll(engine)
        XCTAssertEqual(r.updated, ["U"])
        XCTAssertEqual(engine.scripts.count, 1, "同 @name + @namespace 就地更新")
        XCTAssertEqual(engine.scripts[0].meta.version, "1.1")
        let none = await MioUserScriptInstaller.updateAll(engine)
        XCTAssertTrue(none.updated.isEmpty)
    }

    func testModuleMenuForUserJS() {
        let kit = makeKit()
        let page = MioPageContext(url: URL(string: "https://greasyfork.org/scripts/1-x/code/x.user.js"))
        let item = kit.registry.menuItems(page: page).first { $0.moduleID == "userScripts" }
        XCTAssertNotNil(item)
        XCTAssertEqual(kit.registry.perform(item!, page: page), .host(.installUserScript(page.url!)))
    }
}

final class MioHashTests: XCTestCase {
    func testSHA256Vectors() {
        XCTAssertEqual(MioSHA256.hash(Data()).map { String(format: "%02x", $0) }.joined(), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(MioSHA256.hash(Data("abc".utf8)).map { String(format: "%02x", $0) }.joined(), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let long = Data(String(repeating: "a", count: 1000).utf8)
        XCTAssertEqual(MioSHA256.hash(long).map { String(format: "%02x", $0) }.joined(), MioHash.sha256Hex(long))
    }
}
