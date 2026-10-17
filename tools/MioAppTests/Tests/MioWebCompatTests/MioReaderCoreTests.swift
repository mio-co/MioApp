import Foundation
import XCTest
@testable import MioWebCompat

/// 阅读模式 / 强制深色 / 存到 Mio 的纯逻辑（ios/App/App/MioReaderCore.swift）
final class MioReaderCoreTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func freshStore() -> MioPageToolsStore {
        let name = "mio.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return MioPageToolsStore(defaults: d)
    }

    func testDarkPolicyPerSiteBeatsGlobalWithParentDomains() {
        let sites = ["example.com": true, "news.example.com": false]
        XCTAssertTrue(MioForceDarkPolicy.isEnabled(host: "example.com", global: false, sites: sites))
        XCTAssertTrue(MioForceDarkPolicy.isEnabled(host: "WWW.Example.com", global: false, sites: sites))
        XCTAssertTrue(MioForceDarkPolicy.isEnabled(host: "blog.example.com", global: false, sites: sites))
        XCTAssertFalse(MioForceDarkPolicy.isEnabled(host: "news.example.com", global: true, sites: sites))
        XCTAssertFalse(MioForceDarkPolicy.isEnabled(host: "a.news.example.com", global: true, sites: sites))
        XCTAssertFalse(MioForceDarkPolicy.isEnabled(host: "other.org", global: false, sites: sites))
        XCTAssertTrue(MioForceDarkPolicy.isEnabled(host: "other.org", global: true, sites: sites))
        XCTAssertTrue(MioForceDarkPolicy.isEnabled(host: nil, global: true, sites: [:]))
        XCTAssertTrue(MioForceDarkPolicy.isEnabled(host: "localhost", global: false, sites: ["localhost": true]))
        XCTAssertEqual(MioForceDarkPolicy.matchingSiteKey(host: "a.news.example.com", sites: sites), "news.example.com")
        XCTAssertEqual(MioForceDarkPolicy.matchingSiteKey(host: "x.example.com", sites: sites), "example.com")
        XCTAssertNil(MioForceDarkPolicy.matchingSiteKey(host: "x.org", sites: sites))
    }

    func testNeedsScriptAndConfigJSON() {
        XCTAssertFalse(MioForceDarkPolicy.needsScript(global: false, sites: [:]))
        XCTAssertFalse(MioForceDarkPolicy.needsScript(global: false, sites: ["a.com": false]))
        XCTAssertTrue(MioForceDarkPolicy.needsScript(global: false, sites: ["a.com": true]))
        XCTAssertTrue(MioForceDarkPolicy.needsScript(global: true, sites: [:]))
        let json = MioForceDarkPolicy.configJSON(global: true, sites: ["b.com": false], nativeHosts: ["www.GitHub.com", "github.com", "x.dev"])
        XCTAssertEqual(json, #"{"global":true,"nativeHosts":["github.com","x.dev"],"sites":{"b.com":false}}"#)
    }

    func testNativeHostsList() {
        var r = MioForceDarkPolicy.updateNativeHosts([], host: "www.github.com", native: true)
        XCTAssertEqual(r.list, ["github.com"]); XCTAssertTrue(r.changed)
        r = MioForceDarkPolicy.updateNativeHosts(r.list, host: "github.com", native: true)
        XCTAssertFalse(r.changed)
        r = MioForceDarkPolicy.updateNativeHosts(["a.com", "github.com"], host: "github.com", native: false)
        XCTAssertEqual(r.list, ["a.com"]); XCTAssertTrue(r.changed)
        r = MioForceDarkPolicy.updateNativeHosts(["a.com", "b.com"], host: "c.com", native: true, maxNative: 2)
        XCTAssertEqual(r.list, ["c.com", "a.com"])
        XCTAssertFalse(MioForceDarkPolicy.updateNativeHosts(["a.com"], host: "  ", native: true).changed)
    }

    func testStoreDarkSettings() {
        let s = freshStore()
        XCTAssertFalse(s.darkGlobal)
        XCTAssertFalse(s.isDarkEnabled(host: "example.com"))
        s.setDark(host: "www.example.com", enabled: true)
        XCTAssertEqual(s.darkSites, ["example.com": true])
        XCTAssertTrue(s.isDarkEnabled(host: "m.example.com"))
        // 在子域名上关闭：改的是实际生效的 example.com 那一项
        s.setDark(host: "m.example.com", enabled: false)
        XCTAssertEqual(s.darkSites, ["example.com": false])
        s.darkGlobal = true
        XCTAssertFalse(s.isDarkEnabled(host: "example.com"))
        XCTAssertTrue(s.isDarkEnabled(host: "other.com"))
        s.setDark(host: "example.com", enabled: nil)
        XCTAssertEqual(s.darkSites, [:])
        XCTAssertTrue(s.isDarkEnabled(host: "example.com"))
    }

    func testReaderPrefsStoreAndJS() {
        let s = freshStore()
        XCTAssertEqual(s.readerPrefs, MioReaderPrefs())
        var p = s.readerPrefs
        p.theme = .sepia; p.font = .serif; p.fontSize = 99
        s.readerPrefs = p
        XCTAssertEqual(s.readerPrefs.theme, .sepia)
        XCTAssertEqual(s.readerPrefs.font, .serif)
        XCTAssertEqual(s.readerPrefs.fontSize, 32)
        let auto = MioReaderPrefs(theme: .auto, font: .mono, fontSize: 5)
        XCTAssertEqual(auto.jsPrefs(systemDark: true)["theme"] as? String, "dark")
        XCTAssertEqual(auto.jsPrefs(systemDark: false)["theme"] as? String, "light")
        XCTAssertEqual(auto.jsPrefs(systemDark: false)["fontSize"] as? Int, 12)
        XCTAssertEqual(auto.jsPrefs(systemDark: false)["font"] as? String, "mono")
    }

    func testSaveCategoryDefault() {
        let s = freshStore()
        XCTAssertEqual(s.saveCategory, "稍后阅读")
        s.saveCategory = "  收藏  "
        XCTAssertEqual(s.saveCategory, "收藏")
        s.saveCategory = "   "
        XCTAssertEqual(s.saveCategory, "稍后阅读")
    }

    func testSaveResultMessages() {
        XCTAssertEqual(MioSaveKind.message(for: ["ok": true, "kind": "bookmark", "category": "稍后阅读"]).text, "已存到导航「稍后阅读」")
        XCTAssertEqual(MioSaveKind.message(for: ["ok": true, "kind": "bookmark", "duplicate": true, "category": "Tools"]).text, "导航里已有这个网页「Tools」")
        XCTAssertEqual(MioSaveKind.message(for: ["ok": true, "kind": "note"]).text, "已新建笔记")
        XCTAssertTrue(MioSaveKind.message(for: ["ok": true, "kind": "clip"]).ok)
        let f = MioSaveKind.message(for: ["ok": false, "code": "auth", "message": "未登录"])
        XCTAssertFalse(f.ok); XCTAssertEqual(f.text, "未登录")
        XCTAssertFalse(MioSaveKind.message(for: nil).ok)
    }

    func testScriptBodiesWrapSharedJS() throws {
        for name in ["reader", "dark", "mio-save"] {
            let url = repoRoot.appendingPathComponent("www/mio-browser/\(name).js")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "missing \(url.path)")
        }
        let dark = try String(contentsOf: repoRoot.appendingPathComponent("www/mio-browser/dark.js"), encoding: .utf8)
        let s = MioPageScripts.darkInstallScript(source: dark, configJSON: #"{"global":true}"#)
        XCTAssertTrue(s.hasPrefix(dark))
        XCTAssertTrue(s.hasSuffix(";try{MioDark.install(document,window,{\"global\":true});}catch(e){}\n"))
        let body = MioPageScripts.readerableBody(source: "/*src*/")
        XCTAssertEqual(body, "if (typeof globalThis.MioReader === 'undefined') {\n/*src*/\n}\nreturn MioReader.isProbablyReaderable(document);")
        XCTAssertTrue(MioPageScripts.extractBody(source: "").contains("MioReader.buildPage(a, prefs)"))
        XCTAssertTrue(MioPageScripts.saveBody(source: "").hasSuffix("return await MioSave.run(kind, payload, opts);"))
    }
}
