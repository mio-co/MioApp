import Foundation
import XCTest
@testable import MioWebCompat

/// v0.3.4 Mac 跟 Safari 对齐：缩放档位、按站点持久化、YouTube v0.3.0 UA、「在 Safari 中看高清」链接
final class DesktopParityTests: XCTestCase {
    func testSafariLevels() {
        XCTAssertEqual(MioZoomCore.levels, [0.5, 0.75, 0.85, 1.0, 1.15, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0])
    }

    func testZoomInOutSteps() {
        XCTAssertEqual(MioZoomCore.zoomIn(from: 1.0), 1.15)
        XCTAssertEqual(MioZoomCore.zoomIn(from: 1.15), 1.25)
        XCTAssertEqual(MioZoomCore.zoomOut(from: 1.0), 0.85)
        XCTAssertEqual(MioZoomCore.zoomOut(from: 0.85), 0.75)
        XCTAssertEqual(MioZoomCore.zoomIn(from: 3.0), 3.0)
        XCTAssertEqual(MioZoomCore.zoomOut(from: 0.5), 0.5)
        // 非档位值：往对应方向走到下一个档位
        XCTAssertEqual(MioZoomCore.zoomIn(from: 1.1), 1.15)
        XCTAssertEqual(MioZoomCore.zoomOut(from: 1.1), 1.0)
        var z = 1.0
        for _ in 0..<20 { z = MioZoomCore.zoomIn(from: z) }
        XCTAssertEqual(z, 3.0)
    }

    func testNearestAndLabel() {
        XCTAssertEqual(MioZoomCore.nearest(1.12), 1.15)
        XCTAssertEqual(MioZoomCore.nearest(.nan), 1.0)
        XCTAssertEqual(MioZoomCore.label(1.15), "115%")
        XCTAssertEqual(MioZoomCore.label(0.85), "85%")
    }

    func testSiteKey() {
        XCTAssertEqual(MioZoomCore.siteKey("WWW.Example.com"), "example.com")
        XCTAssertEqual(MioZoomCore.siteKey(url: URL(string: "https://news.example.com/a")), "news.example.com")
        XCTAssertNil(MioZoomCore.siteKey(url: URL(string: "about:blank")))
        XCTAssertNil(MioZoomCore.siteKey(""))
    }

    func testPerSitePersistenceRoundTrip() {
        var t = MioZoomCore.SiteTable()
        t.set(1.25, for: "example.com", default: 1.0)
        t.set(0.75, for: "news.example.com", default: 1.0)
        let back = MioZoomCore.SiteTable(json: t.json)
        XCTAssertEqual(back.zoom(for: "example.com", default: 1.0), 1.25)
        XCTAssertEqual(back.zoom(for: "news.example.com", default: 1.0), 0.75)
        XCTAssertEqual(back.zoom(for: "other.com", default: 1.0), 1.0)
        XCTAssertEqual(back.zoom(for: "other.com", default: 1.5), 1.5)
        XCTAssertEqual(back, t)
    }

    func testSettingDefaultRemovesEntry() {
        var t = MioZoomCore.SiteTable()
        t.set(1.5, for: "a.com", default: 1.0)
        XCTAssertEqual(t.count, 1)
        t.set(1.0, for: "a.com", default: 1.0)
        XCTAssertEqual(t.count, 0)
    }

    func testCorruptJSONAndOutOfRange() {
        XCTAssertEqual(MioZoomCore.SiteTable(json: "not json").count, 0)
        XCTAssertEqual(MioZoomCore.SiteTable(json: nil).count, 0)
        let t = MioZoomCore.SiteTable(json: #"{"sites":{"a.com":9,"b.com":1.24}}"#)
        XCTAssertEqual(t.zoom(for: "a.com", default: 1.0), 1.0)
        XCTAssertEqual(t.zoom(for: "b.com", default: 1.0), 1.25)
    }

    func testLimitDropsOldest() {
        var t = MioZoomCore.SiteTable()
        for i in 0...MioZoomCore.SiteTable.limit { t.set(1.5, for: "s\(i).com", default: 1.0) }
        XCTAssertEqual(t.count, MioZoomCore.SiteTable.limit)
        XCTAssertEqual(t.zoom(for: "s0.com", default: 1.0), 1.0)
    }

    func testYouTubeHosts() {
        for h in ["youtube.com", "www.youtube.com", "m.youtube.com", "www.youtube-nocookie.com", "youtu.be", "music.youtube.com"] {
            XCTAssertTrue(MioYouTubeCompat.isYouTubeHost(h), h)
        }
        for h in ["notyoutube.com", "youtube.com.evil.net", "example.com", ""] {
            XCTAssertFalse(MioYouTubeCompat.isYouTubeHost(h), h)
        }
    }

    func testLegacyUAMatchesV030() {
        // v0.3.0：Catalyst WKWebView 默认 UA + "Version/<major>.0 Mobile/15E148 Safari/604.1"
        let ua = MioYouTubeCompat.legacyMacUserAgent(osMajor: 18)
        XCTAssertEqual(ua, "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1")
        XCTAssertTrue(ua.hasSuffix(MioWebCompat.mobileApplicationName(iOSMajor: 18)))
    }

    func testVideoIDAndSafariURL() {
        XCTAssertEqual(MioYouTubeCompat.videoID(URL(string: "https://m.youtube.com/watch?v=abc123&t=5")), "abc123")
        XCTAssertEqual(MioYouTubeCompat.videoID(URL(string: "https://www.youtube-nocookie.com/embed/xyz")), "xyz")
        XCTAssertEqual(MioYouTubeCompat.videoID(URL(string: "https://youtu.be/q1")), "q1")
        XCTAssertEqual(MioYouTubeCompat.videoID(URL(string: "https://www.youtube.com/shorts/s9")), "s9")
        XCTAssertNil(MioYouTubeCompat.videoID(URL(string: "https://www.youtube.com/")))
        XCTAssertNil(MioYouTubeCompat.videoID(URL(string: "https://example.com/watch?v=1")))
        XCTAssertEqual(MioYouTubeCompat.safariHDURL(URL(string: "https://m.youtube.com/watch?v=abc&list=PL1"), seconds: 83.7)?.absoluteString,
                       "https://www.youtube.com/watch?v=abc&list=PL1&t=83s")
        XCTAssertEqual(MioYouTubeCompat.safariHDURL(URL(string: "https://youtu.be/q1"), seconds: 0)?.absoluteString,
                       "https://www.youtube.com/watch?v=q1")
        XCTAssertNil(MioYouTubeCompat.safariHDURL(URL(string: "https://www.youtube.com/feed"), seconds: 3))
    }
}
