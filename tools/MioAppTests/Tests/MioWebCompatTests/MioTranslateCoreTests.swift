import Foundation
import XCTest
@testable import MioWebCompat

/// 翻译原生侧纯逻辑（ios/App/App/MioTranslateCore.swift）：请求白名单 / Key 只在原生加 / 正则摘取 / 站点规范化 / 缓存 / 注入配置
final class MioTranslateCoreTests: XCTestCase {
    private let base = "https://api.example.com/v1/"

    private func check(_ req: [String: Any]) -> MioTranslateCore.CheckedRequest? {
        if case .success(let c) = MioTranslateCore.check(req, openaiBase: base) { return c }
        return nil
    }

    func testAllowsOnlyTranslationHostsAndConfiguredOpenAI() {
        XCTAssertNotNil(check(["url": "https://www.bing.com/ttranslatev3?isVertical=1", "method": "POST", "body": "a=b"]))
        XCTAssertNotNil(check(["url": "https://translate.googleapis.com/translate_a/t?client=gtx"]))
        XCTAssertNil(check(["url": "http://www.bing.com/x"]), "免费引擎只允许 https")
        XCTAssertNil(check(["url": "https://evil.example.org/steal"]))
        XCTAssertEqual(check(["url": "https://api.example.com/v1/chat/completions", "method": "POST", "auth": "openai"])?.openAIAuth, true)
        XCTAssertNil(check(["url": "https://api.example.com/v1/models", "auth": "openai"]), "Key 只给 chat/completions")
        XCTAssertNil(check(["url": "https://www.bing.com/x", "auth": "openai"]), "不能把 Key 发给别的域名")
        if case .success = MioTranslateCore.check(["url": "https://api.example.com/v1/chat/completions", "auth": "openai"], openaiBase: "") {
            XCTFail("未配置 OpenAI 地址时不放行")
        }
        XCTAssertNil(check(["url": "https://www.bing.com/x", "method": "PUT"]))
        XCTAssertNil(check(["url": "https://www.bing.com/x", "method": "GET", "body": "x"]))
        XCTAssertNil(check(["url": "https://www.bing.com/x", "method": "POST", "body": String(repeating: "x", count: 300_000)]))
        XCTAssertNil(check(["url": "not a url at all"]))
    }

    func testHeadersFilteredAndTimeoutClamped() {
        let c = check(["url": "https://www.bing.com/x", "method": "POST",
                       "headers": ["Content-Type": "a", "Cookie": "x", "Authorization": "Bearer t", "X-Evil": "1"], "timeoutMs": 999_999])
        XCTAssertEqual(c?.headers, ["content-type": "a"])
        XCTAssertEqual(c?.timeout, 90)
        let e = check(["url": "https://api-edge.cognitive.microsofttranslator.com/translate?to=zh-Hans", "method": "POST", "headers": ["Authorization": "Bearer t"]])
        XCTAssertEqual(e?.headers["authorization"], "Bearer t", "Edge API 的令牌头放行")
        XCTAssertEqual(check(["url": "https://www.bing.com/x", "timeoutMs": 12000.0])?.timeout, 12)
        XCTAssertEqual(check(["url": "https://www.bing.com/x", "pick": ["a(b)"]])?.picks, ["a(b)"])
    }

    func testRunPicksMatchesBingPage() {
        let page = #"x;IG:"6F33281EA7124DA59F5AA885EEDCB22C",y data-iid="translator.5023" var params_AbusePreventionHelper = [1792195186283,"Y0RQ",3600000];"#
        let picks = MioTranslateCore.runPicks(page, [#"IG:"([0-9A-Fa-f]+)""#, #"data-iid="(translator\.\d+)""#, #"params_AbusePreventionHelper\s*=\s*\[(\d+),"([^"]+)",(\d+)"#, "nomatch(\\d)"])
        XCTAssertEqual(picks[0] as? [String], ["6F33281EA7124DA59F5AA885EEDCB22C"])
        XCTAssertEqual(picks[1] as? [String], ["translator.5023"])
        XCTAssertEqual(picks[2] as? [String], ["1792195186283", "Y0RQ", "3600000"])
        XCTAssertTrue(picks[3] is NSNull)
    }

    func testHostNormalizationAndMatching() {
        XCTAssertEqual(MioTranslateCore.normalizeHost("https://www.Example.com/path?q=1"), "example.com")
        XCTAssertEqual(MioTranslateCore.normalizeHost("*.news.example.com"), "news.example.com")
        XCTAssertEqual(MioTranslateCore.normalizeHost("example.com:8080/x"), "example.com")
        XCTAssertNil(MioTranslateCore.normalizeHost("not a host"))
        XCTAssertNil(MioTranslateCore.normalizeHost("nodot"))
        XCTAssertTrue(MioTranslateCore.hostMatches("docs.example.com", "example.com"))
        XCTAssertTrue(MioTranslateCore.hostMatches("example.com", "www.example.com"))
        XCTAssertFalse(MioTranslateCore.hostMatches("notexample.com", "example.com"))
        XCTAssertTrue(MioTranslateCore.isAuto(host: "news.ycombinator.com", sites: ["ycombinator.com"]))
        XCTAssertFalse(MioTranslateCore.isAuto(host: nil, sites: ["ycombinator.com"]))
    }

    func testOpenAIBase() {
        XCTAssertEqual(MioTranslateCore.normalizeBase("https://api.openai.com/v1/?x=1#f"), "https://api.openai.com/v1")
        XCTAssertEqual(MioTranslateCore.normalizeBase("ftp://x/v1"), "")
        XCTAssertEqual(MioTranslateCore.normalizeBase(""), "")
        XCTAssertEqual(MioTranslateCore.openaiEndpoint("https://api.openai.com/v1/"), "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(MioTranslateCore.openaiEndpoint("http://192.168.1.2:11434/v1/chat/completions"), "http://192.168.1.2:11434/v1/chat/completions")
    }

    func testLRUCache() {
        var l = MioTranslateLRU(limit: 3)
        l.put(["a": "1"])
        l.put("b", "2")
        l.put("c", "3")
        XCTAssertEqual(l.get("a"), "1") // a 变成最新
        l.put("d", "4")
        XCTAssertNil(l.get("b"))
        XCTAssertEqual(l.get(["a", "c", "d", "zz"]), ["a": "1", "c": "3", "d": "4"])
        l.put("big", String(repeating: "x", count: 30_000))
        XCTAssertNil(l.get("big"))
        let round = MioTranslateLRU.decode(l.encode(), limit: 3)
        XCTAssertEqual(round.count, 3)
        var r2 = round
        XCTAssertEqual(r2.get("d"), "4")
        XCTAssertEqual(MioTranslateLRU.decode(Data("garbage".utf8)).count, 0)
        l.clear()
        XCTAssertEqual(l.count, 0)
    }

    func testScriptConfigInjection() throws {
        let template = "(function(){ var CONFIG_B64 = '__MIO_TRANSLATE_CONFIG__'; })();"
        let cfg = MioTranslateCore.Config(token: "tok", platform: "ios", target: "zh-CN", engine: "openai", display: "bilingual",
                                          autoSites: ["example.com"], selection: true, youtube: true, ytSubs: false,
                                          openaiBase: "https://x/v1", openaiModel: "m", openaiPrompt: "p", openaiReady: true)
        let out = try XCTUnwrap(MioTranslateCore.script(template: template, config: cfg))
        XCTAssertFalse(out.contains("__MIO_TRANSLATE_CONFIG__"))
        let b64 = out.components(separatedBy: "'")[1]
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(Data(base64Encoded: b64))) as? [String: Any])
        XCTAssertEqual(json["token"] as? String, "tok")
        XCTAssertEqual(json["autoSites"] as? [String], ["example.com"])
        XCTAssertEqual(json["ytSubs"] as? Bool, false)
        XCTAssertEqual((json["openai"] as? [String: Any])?["ready"] as? Bool, true)
        XCTAssertNil(MioTranslateCore.script(template: "no placeholder", config: cfg))
        // 与真正的页面脚本模板对得上
        let real = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../shared/translate/mio-translate.js").standardized
        let text = try String(contentsOf: real, encoding: .utf8)
        XCTAssertNotNil(MioTranslateCore.script(template: text, config: cfg))
    }

    func testTokenAndLanguages() {
        let a = MioTranslateCore.makeToken(), b = MioTranslateCore.makeToken()
        XCTAssertEqual(a.count, 48)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(MioTranslateCore.languageName("zh-CN"), "简体中文")
        XCTAssertEqual(MioTranslateCore.languages.first?.code, "zh-CN")
        XCTAssertEqual(Set(MioTranslateCore.engines.map(\.id)), ["microsoft", "google", "openai"])
    }
}
