import XCTest
@testable import MioWebCompat

/// 原生 macOS 版 Firefox 式外壳的纯逻辑（macos/Sources/MioMac/Chrome/MioMacChromeCore.swift）
final class MacChromeCoreTests: XCTestCase {
    // MARK: 标签条布局

    func testTabsShareWidthUpToMax() {
        let r = MioTabLayout.layout(pinned: [false, false], available: 1000)
        XCTAssertEqual(r.widths, [225, 225])
        XCTAssertEqual(r.xs, [0, 227])
        XCTAssertFalse(r.overflow)
        XCTAssertEqual(r.contentWidth, 452)
    }

    func testTabsShrinkThenOverflow() {
        let r = MioTabLayout.layout(pinned: Array(repeating: false, count: 6), available: 600)
        XCTAssertFalse(r.overflow)
        XCTAssertEqual(r.tabWidth, 98) // (600 - 10) / 6 = 98.33 → 半点对齐
        let o = MioTabLayout.layout(pinned: Array(repeating: false, count: 12), available: 600)
        XCTAssertTrue(o.overflow)
        XCTAssertEqual(o.tabWidth, 76)
        XCTAssertGreaterThan(o.contentWidth, 600)
    }

    func testPinnedTabsAreIconWidth() {
        let r = MioTabLayout.layout(pinned: [true, true, false], available: 500)
        XCTAssertEqual(Array(r.widths.prefix(2)), [36, 36])
        XCTAssertEqual(r.xs[1], 38)
        XCTAssertEqual(r.xs[2], 76)
        XCTAssertEqual(r.widths[2], 225)
    }

    func testLockedWidthDoesNotGrowButStillShrinks() {
        let r = MioTabLayout.layout(pinned: [false, false, false], available: 1000, lockedWidth: 120)
        XCTAssertEqual(r.tabWidth, 120)
        let s = MioTabLayout.layout(pinned: Array(repeating: false, count: 10), available: 900, lockedWidth: 120)
        XCTAssertEqual(s.tabWidth, 88) // (900 - 18) / 10 = 88.2
    }

    func testDropIndex() {
        let mids = [50.0, 150, 250, 350]
        XCTAssertEqual(MioTabLayout.dropIndex(center: 50, mids: mids, from: 0, allowed: 0...3), 0)
        XCTAssertEqual(MioTabLayout.dropIndex(center: 260, mids: mids, from: 0, allowed: 0...3), 2)
        XCTAssertEqual(MioTabLayout.dropIndex(center: 999, mids: mids, from: 0, allowed: 0...3), 3)
        XCTAssertEqual(MioTabLayout.dropIndex(center: -5, mids: mids, from: 3, allowed: 1...3), 1) // 不能越过固定区
        XCTAssertEqual(MioTabLayout.reordered([1, 2, 3, 4], from: 0, to: 2), [2, 3, 1, 4])
    }

    func testScrollReveal() {
        XCTAssertNil(MioTabLayout.scrollOffset(revealing: 100, width: 80, offset: 0, visible: 500, content: 1200))
        XCTAssertEqual(MioTabLayout.scrollOffset(revealing: 900, width: 80, offset: 0, visible: 500, content: 1200), 492)
        XCTAssertEqual(MioTabLayout.scrollOffset(revealing: 10, width: 80, offset: 400, visible: 500, content: 1200), 0)
        XCTAssertTrue(MioTabLayout.isDetach(verticalDistance: 60))
        XCTAssertFalse(MioTabLayout.isDetach(verticalDistance: 10))
    }

    // MARK: mio://home

    func testHomeAddressAliases() {
        // 首页模型（mio://home → MioCore 首页、地址栏「Mio」）与本机桥来源校验已移到 apple/MioKit（MioHomeModel / MioCoreOrigin，有各自的单测）
        XCTAssertTrue(MioMacHome.isHomeAddress("mio://home"))
        XCTAssertTrue(MioMacHome.isHomeAddress(" About:Home "))
        XCTAssertTrue(MioMacHome.isHomeAddress("about:newtab"))
        XCTAssertFalse(MioMacHome.isHomeAddress("mio://settings"))
        XCTAssertFalse(MioMacHome.isHomeAddress("https://mio.300031.xyz/"))
    }

    // MARK: 地址栏显示

    func testURLDisplay() {
        let p = MioURLDisplay.parts(URL(string: "https://www.example.com/a/b?x=1"))
        XCTAssertEqual(p.prefix, "")
        XCTAssertEqual(p.host, "www.example.com")
        XCTAssertEqual(p.rest, "/a/b?x=1")
        XCTAssertEqual(MioURLDisplay.displayString(URL(string: "https://example.com/")), "example.com")
        XCTAssertEqual(MioURLDisplay.displayString(URL(string: "http://example.com:8080/x")), "http://example.com:8080/x")
        XCTAssertEqual(MioURLDisplay.displayString(URL(string: "about:blank")), "")
        XCTAssertEqual(MioURLDisplay.security(URL(string: "https://a.com"), isHome: false), .secure)
        XCTAssertEqual(MioURLDisplay.security(URL(string: "http://a.com"), isHome: false), .insecure)
        XCTAssertEqual(MioURLDisplay.security(URL(string: "http://localhost:3000"), isHome: false), .local)
        XCTAssertEqual(MioURLDisplay.security(URL(string: "https://mio.300031.xyz"), isHome: true), .home)
        XCTAssertEqual(MioURLDisplay.security(nil, isHome: false), .none)
        XCTAssertEqual(MioURLDisplay.editingText(URL(string: "https://example.com/")), "https://example.com/")
    }

    // MARK: 历史 / 书签 / 建议

    func testHistoryAndBookmarks() {
        var h = MioHistoryList()
        h.record(url: "https://a.com/", title: "A", at: 1)
        h.record(url: "https://b.com/", title: "B", at: 2)
        h.record(url: "https://a.com/", title: "", at: 3)
        h.record(url: "about:blank", title: "x", at: 4)
        XCTAssertEqual(h.entries.map(\.url), ["https://a.com/", "https://b.com/"])
        XCTAssertEqual(h.entries[0].visits, 2)
        XCTAssertEqual(h.entries[0].title, "A")
        XCTAssertEqual(MioHistoryList(json: h.json), h)

        var b = MioBookmarkList()
        XCTAssertTrue(b.toggle(url: "https://a.com/", title: "A"))
        XCTAssertTrue(b.contains("https://a.com/"))
        XCTAssertFalse(b.toggle(url: "https://a.com/", title: "A"))
        XCTAssertFalse(b.contains("https://a.com/"))
        XCTAssertFalse(b.toggle(url: "mio://home", title: "Mio"))
    }

    func testSuggestionsOrder() {
        let tabs = [MioSuggest.OpenTab(id: 1, title: "Example Domain", url: "https://example.com/"),
                    MioSuggest.OpenTab(id: 2, title: "Current", url: "https://example.org/")]
        let bm = [MioBookmark(url: "https://example.net/", title: "Example Net")]
        let hist = [MioHistoryEntry(url: "https://example.com/", title: "Example Domain", visits: 3, last: 1),
                    MioHistoryEntry(url: "https://www.example.edu/", title: "Edu", visits: 1, last: 2)]
        let s = MioSuggest.build(query: "example", resolved: URL(string: "https://www.google.com/search?q=example"), isSearch: true,
                                 tabs: tabs, bookmarks: bm, history: hist, activeTabID: 2)
        XCTAssertEqual(s.map(\.kind), [.search, .switchTab, .bookmark, .history])
        XCTAssertEqual(s[1].tabID, 1)
        XCTAssertEqual(s[3].url, "https://www.example.edu/")
        let v = MioSuggest.build(query: "example.com", resolved: URL(string: "https://example.com"), isSearch: false,
                                 tabs: [], bookmarks: [], history: [], limit: 8)
        XCTAssertEqual(v.map(\.kind), [.visit, .search])
        XCTAssertEqual(MioSuggest.build(query: "  ", resolved: nil, isSearch: true, tabs: tabs, bookmarks: bm, history: hist), [])
        XCTAssertEqual(MioSuggest.move(selection: -1, by: 1, count: 3), 0)
        XCTAssertEqual(MioSuggest.move(selection: 2, by: 1, count: 3), -1)
        XCTAssertEqual(MioSuggest.move(selection: -1, by: -1, count: 3), 2)
    }
}
