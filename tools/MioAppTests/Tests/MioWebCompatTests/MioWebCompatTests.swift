import Foundation
import XCTest
@testable import MioWebCompat

final class ProfileAndUserAgentTests: XCTestCase {
    func testProfile() {
        XCTAssertEqual(MioWebCompat.profile(isMacCatalyst: true, isPad: true), .desktop)   // Catalyst「按 iPad 缩放」
        XCTAssertEqual(MioWebCompat.profile(isMacCatalyst: true, isPad: false), .desktop)
        XCTAssertEqual(MioWebCompat.profile(isMacCatalyst: false, isPad: true), .desktop)
        XCTAssertEqual(MioWebCompat.profile(isMacCatalyst: false, isPad: false), .mobile)
    }

    func testSafariVersionMatchesSystemWebKit() {
        XCTAssertEqual(MioWebCompat.safariVersion(macOSMajor: 12, minor: 0), "15.1")
        XCTAssertEqual(MioWebCompat.safariVersion(macOSMajor: 12, minor: 7), "15.6")
        XCTAssertEqual(MioWebCompat.safariVersion(macOSMajor: 13, minor: 3), "16.4")
        XCTAssertEqual(MioWebCompat.safariVersion(macOSMajor: 13, minor: 6), "16.6")
        XCTAssertEqual(MioWebCompat.safariVersion(macOSMajor: 14, minor: 5), "17.5")
        XCTAssertEqual(MioWebCompat.safariVersion(macOSMajor: 15, minor: 0), "18.0")
        XCTAssertEqual(MioWebCompat.safariVersion(macOSMajor: 15, minor: 6), "18.6")
        XCTAssertEqual(MioWebCompat.safariVersion(macOSMajor: 26, minor: 1), "26.1")
        XCTAssertEqual(MioWebCompat.safariVersion(macOSMajor: 27, minor: 0), "27.0")
    }

    func testMacOSVersionPrefersSystemVersionPlist() {
        let v = MioWebCompat.macOSVersion(systemVersionPlist: ["ProductVersion": "15.4.1"], processVersion: (18, 4))
        XCTAssertEqual(v.major, 15); XCTAssertEqual(v.minor, 4)
        let t = MioWebCompat.macOSVersion(systemVersionPlist: ["ProductVersion": "26.0"], processVersion: (26, 0))
        XCTAssertEqual(t.major, 26)
    }

    func testMacOSVersionIgnoresCompatPlistAndMapsIOSEquivalent() {
        // SYSTEM_VERSION_COMPAT=1 下 plist 报 10.16 → 退回 ProcessInfo；Catalyst 给 iOS 对应版本 17.5 → macOS 14.5
        let v = MioWebCompat.macOSVersion(systemVersionPlist: ["ProductVersion": "10.16"], processVersion: (17, 5))
        XCTAssertEqual(v.major, 14); XCTAssertEqual(v.minor, 5)
        let w = MioWebCompat.macOSVersion(systemVersionPlist: nil, processVersion: (14, 6))
        XCTAssertEqual(w.major, 14); XCTAssertEqual(w.minor, 6)
        let x = MioWebCompat.macOSVersion(systemVersionPlist: nil, processVersion: (26, 1))
        XCTAssertEqual(x.major, 26)
    }

    func testDesktopUserAgentIsExactSafariFormat() {
        let ua = MioWebCompat.desktopUserAgent(safariVersion: "18.4")
        XCTAssertEqual(ua, "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Safari/605.1.15")
        XCTAssertFalse(ua.contains("Mobile"), "带 Mobile 时 YouTube 会给手机版 + 360p")
        XCTAssertFalse(ua.contains("iPad"))
        XCTAssertTrue(MioWebCompat.desktopApplicationName(safariVersion: "18.4").hasSuffix("Safari/605.1.15"))
    }

    func testMobileApplicationNameUnchanged() {
        // iPhone 保持 v0.3.x 行为（Google 登录要求带 Safari 标识）
        XCTAssertEqual(MioWebCompat.mobileApplicationName(iOSMajor: 18), "Version/18.0 Mobile/15E148 Safari/604.1")
    }
}

final class DesktopURLTests: XCTestCase {
    func testRewritesMobileYouTube() {
        let u = MioWebCompat.desktopURL(for: URL(string: "https://m.youtube.com/watch?v=abc&t=10#x")!)
        XCTAssertEqual(u?.absoluteString, "https://www.youtube.com/watch?v=abc&t=10#x")
        XCTAssertEqual(MioWebCompat.desktopURL(for: URL(string: "http://M.YouTube.com/")!)?.absoluteString, "https://www.youtube.com/")
    }

    func testLeavesOtherURLsAlone() {
        XCTAssertNil(MioWebCompat.desktopURL(for: URL(string: "https://www.youtube.com/watch?v=abc")!))
        XCTAssertNil(MioWebCompat.desktopURL(for: URL(string: "https://music.youtube.com/")!))
        XCTAssertNil(MioWebCompat.desktopURL(for: URL(string: "https://m.example.com/")!))
        XCTAssertNil(MioWebCompat.desktopURL(for: URL(string: "about:blank")!))
        // 用户显式要求手机版
        XCTAssertNil(MioWebCompat.desktopURL(for: URL(string: "https://m.youtube.com/?app=m&persist_app=1")!))
    }
}

final class AdblockQualityAuditTests: XCTestCase {
    func testFlagsRulesThatRemoveStreamingData() {
        let text = """
        ! comment
        youtube.com#%#//scriptlet('json-prune', 'playerResponse.streamingData.adaptiveFormats')
        www.youtube.com#%#//scriptlet('set-constant', 'ytInitialPlayerResponse.streamingData', 'undefined')
        m.youtube.com#%#//scriptlet('json-prune-fetch-response', '$..streamingData', '', '/player/')
        youtube.com##+js(json-prune, playerResponse.streamingData.formats)
        youtube.com#%#//scriptlet('xml-prune', 'xpath(//*[name()="Period"])', '', '.mpd')
        youtube.com#%#(()=>{const r=JSON.parse;JSON.parse=function(t){const o=r(t);delete o.streamingData;return o}})();
        """
        let flagged = MioWebCompat.qualityRiskRules(text)
        XCTAssertEqual(flagged.count, 6, flagged.joined(separator: "\n"))
    }

    func testIgnoresAdOnlyRulesAndObligatoryProps() {
        let text = """
        youtube.com#%#//scriptlet('json-prune', 'playerResponse.adPlacements playerResponse.adSlots', 'playerResponse.streamingData.serverAbrStreamingUrl')
        youtube.com#%#//scriptlet('set-constant', 'ytInitialPlayerResponse.adPlacements', 'undefined')
        youtube.com##+js(json-prune, playerResponse.adPlacements playerResponse.playerAds adPlacements playerAds)
        example.com#%#//scriptlet('json-prune', 'streamingData')
        www.youtube.com#@%#(()=>{delete o.streamingData})();
        ||youtube.com/pagead/
        """
        XCTAssertEqual(MioWebCompat.qualityRiskRules(text), [])
    }

    func testQuotedArgs() {
        XCTAssertEqual(MioWebCompat.quotedArgs("'json-prune', 'a b', \"c\", 'd\\'e'"), ["json-prune", "a b", "c", "d'e"])
    }

    /// 实际打包的过滤列表（CI 里 fetch-adblock-assets 之后才有远程列表；本地没有时只查 filter-0）
    func testBundledListsDoNotDegradeYouTubeQuality() throws {
        let here = URL(fileURLWithPath: #filePath)
        let bundle = here.deletingLastPathComponent().appendingPathComponent("../../../../ios/App/App/AdblockBundle").standardized
        var checked = 0
        for dir in [bundle] {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            for f in files where f.hasSuffix(".txt") {
                let text = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
                let flagged = MioWebCompat.qualityRiskRules(text)
                XCTAssertEqual(flagged, [], "\(f): 这些规则可能让 YouTube 只剩低画质")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 0)
    }
}

final class InjectedScriptTests: XCTestCase {
    func testScriptsAreSelfContainedIIFEs() {
        for s in [MioWebCompat.returnKeyFixScript, MioWebCompat.passkeyHintScript, MioWebCompat.mediaProbeScript] {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertTrue(t.hasPrefix("(function"), String(t.prefix(40)))
            XCTAssertTrue(t.hasSuffix("})();"))
        }
        XCTAssertTrue(MioWebCompat.returnKeyFixScript.contains("'\\n'"), "raw string 里应是 JS 的 '\\n' 转义，而不是真的换行")
    }
}
