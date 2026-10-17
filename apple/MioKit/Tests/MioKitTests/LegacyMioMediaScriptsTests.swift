import XCTest
@testable import MioKit

final class MioMediaScriptsTests: XCTestCase {
    func testDefaultCategories() {
        XCTAssertEqual(MioMediaScripts.defaultCategoryKeys, ["sponsor", "selfpromo", "interaction"])
        XCTAssertEqual(MioMediaScripts.categories.map { $0.key }, ["sponsor", "selfpromo", "interaction", "intro", "outro"])
    }

    func testConfigJSONIsStableAndFiltersCategories() throws {
        let c = MioMediaScripts.Config(platform: "ios", background: true, nowPlaying: false, pip: true, sponsorBlock: true,
                                       categories: ["outro", "bogus", "sponsor", "sponsor"])
        XCTAssertEqual(c.categories, ["sponsor", "outro"])
        XCTAssertEqual(c.json, #"{"platform":"ios","background":true,"nowPlaying":false,"pip":true,"sponsorBlock":true,"categories":["sponsor","outro"]}"#)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(c.json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["nowPlaying"] as? Bool, false)
        XCTAssertEqual(obj["categories"] as? [String], ["sponsor", "outro"])
    }

    func testConfigJSONEscapes() throws {
        let c = MioMediaScripts.Config(platform: "a\"b</script>\u{2028}")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(c.json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["platform"] as? String, "a\"b</script>\u{2028}")
        XCTAssertFalse(c.json.contains("</script>"))
        XCTAssertFalse(c.json.contains("\u{2028}"))
    }

    func testScriptReplacesPlaceholderOnce() {
        let s = MioMediaScripts.youtubeMediaScript(.init(platform: "mac"))
        XCTAssertFalse(s.contains(MioMediaScripts.configPlaceholder))
        XCTAssertTrue(s.contains(#"var CFG = {"platform":"mac""#))
        XCTAssertEqual(MioMediaScripts.youtubeMediaScriptTemplate.components(separatedBy: MioMediaScripts.configPlaceholder).count, 2)
        for js in [MioMediaScripts.youtubeMediaScriptTemplate, MioMediaScripts.visibilityScript, MioMediaScripts.emeProbeScript, MioMediaScripts.mediaSmokeScript] {
            XCTAssertFalse(js.contains("innerHTML"))
        }
    }

    func testSponsorBlockURLAllowlist() {
        XCTAssertTrue(MioMediaScripts.isAllowedSponsorBlockURL("https://sponsor.ajay.app/api/skipSegments/5f6b?categories=%5B%22sponsor%22%5D&actionTypes=%5B%22skip%22%5D"))
        XCTAssertTrue(MioMediaScripts.isAllowedSponsorBlockURL("https://sponsor.ajay.app/api/skipSegments/abcd"))
        XCTAssertFalse(MioMediaScripts.isAllowedSponsorBlockURL("http://sponsor.ajay.app/api/skipSegments/abcd"))
        XCTAssertFalse(MioMediaScripts.isAllowedSponsorBlockURL("https://sponsor.ajay.app.evil.com/api/skipSegments/abcd"))
        XCTAssertFalse(MioMediaScripts.isAllowedSponsorBlockURL("https://sponsor.ajay.app/api/skipSegments?videoID=dQw4w9WgXcQ"))
        XCTAssertFalse(MioMediaScripts.isAllowedSponsorBlockURL("https://sponsor.ajay.app/api/skipSegments/dQw4w9WgXcQ"))
        XCTAssertFalse(MioMediaScripts.isAllowedSponsorBlockURL("https://sponsor.ajay.app/api/skipSegments/ABCD"))
        XCTAssertFalse(MioMediaScripts.isAllowedSponsorBlockURL("https://sponsor.ajay.app/api/voteOnSponsorTime/abcd"))
        XCTAssertFalse(MioMediaScripts.isAllowedSponsorBlockURL("https://user:pw@sponsor.ajay.app/api/skipSegments/abcd"))
        XCTAssertFalse(MioMediaScripts.isAllowedSponsorBlockURL("https://sponsor.ajay.app:8443/api/skipSegments/abcd"))
        XCTAssertFalse(MioMediaScripts.isAllowedSponsorBlockURL("not a url"))
    }

    func testVideoIDMatchesJSRules() {
        let id = "dQw4w9WgXcQ"
        let ok = [
            "https://www.youtube.com/watch?v=\(id)", "https://m.youtube.com/watch?feature=share&v=\(id)&t=42s",
            "https://youtu.be/\(id)?si=x", "https://www.youtube.com/shorts/\(id)", "https://www.youtube.com/embed/\(id)",
            "https://www.youtube-nocookie.com/embed/\(id)", "https://www.youtube.com/live/\(id)", "https://music.youtube.com/watch?v=\(id)",
        ]
        for s in ok { XCTAssertEqual(MioMediaScripts.videoID(from: URL(string: s)!), id, s) }
        let bad = [
            "https://www.youtube.com/watch?v=short", "https://www.youtube.com/@chan", "https://evil.example/watch?v=\(id)",
            "https://notyoutube.com/watch?v=\(id)", "https://www.youtube.com/feed/subscriptions",
        ]
        for s in bad { XCTAssertNil(MioMediaScripts.videoID(from: URL(string: s)!), s) }
    }
}
