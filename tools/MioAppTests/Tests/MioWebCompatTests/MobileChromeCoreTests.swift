import XCTest
@testable import MioWebCompat

/// 手机端 Safari 式布局的纯逻辑（MioMobileChromeCore）；Android MobileChromeCoreTest 是同样的用例
final class MobileChromeCoreTests: XCTestCase {
    func testLayoutParseDefaultsToCompact() {
        XCTAssertEqual(MioBrowserLayout.parse(nil), .compact)
        XCTAssertEqual(MioBrowserLayout.parse(""), .compact)
        XCTAssertEqual(MioBrowserLayout.parse("weird"), .compact)
        XCTAssertEqual(MioBrowserLayout.parse("Bottom"), .bottom)
        XCTAssertEqual(MioBrowserLayout.parse(" top "), .top)
        XCTAssertEqual(MioBrowserLayout.allCases.map(\.rawValue), ["compact", "bottom", "top"])
        XCTAssertEqual(MioBrowserLayout.allCases.map(\.title), ["紧凑", "底部", "顶部"])
        XCTAssertFalse(MioBrowserLayout.compact.hasToolbarRow)
        XCTAssertTrue(MioBrowserLayout.bottom.hasToolbarRow)
        XCTAssertTrue(MioBrowserLayout.top.addressOnTop)
        XCTAssertFalse(MioBrowserLayout.compact.menuInAddressBar)
    }

    func testDisplayHost() {
        XCTAssertEqual(MioMobileChromeCore.displayHost("https://www.Example.com/a?b#c"), "example.com")
        XCTAssertEqual(MioMobileChromeCore.displayHost("https://m.youtube.com/watch?v=1"), "m.youtube.com")
        XCTAssertEqual(MioMobileChromeCore.displayHost("http://user:pw@host.dev:8080/x"), "host.dev")
        XCTAssertEqual(MioMobileChromeCore.displayHost("https://www.com/"), "www.com")
        XCTAssertEqual(MioMobileChromeCore.displayHost("https://[::1]:8080/"), "::1")
        XCTAssertEqual(MioMobileChromeCore.displayHost("example.org/path"), "example.org")
        XCTAssertEqual(MioMobileChromeCore.displayHost(nil), "")
        XCTAssertEqual(MioMobileChromeCore.displayHost("  "), "")
    }

    func testSwipeClassification() {
        XCTAssertEqual(MioMobileChromeCore.classifySwipe(dx: -80, dy: 5), .nextTab)
        XCTAssertEqual(MioMobileChromeCore.classifySwipe(dx: 80, dy: -10), .previousTab)
        XCTAssertEqual(MioMobileChromeCore.classifySwipe(dx: -25, dy: 0, vx: -900), .nextTab)
        XCTAssertEqual(MioMobileChromeCore.classifySwipe(dx: -25, dy: 0, vx: -100), .none)
        XCTAssertEqual(MioMobileChromeCore.classifySwipe(dx: 5, dy: -60), .overview)
        XCTAssertEqual(MioMobileChromeCore.classifySwipe(dx: 0, dy: -20, vy: -900), .overview)
        XCTAssertEqual(MioMobileChromeCore.classifySwipe(dx: 0, dy: 80), .none, "下滑不做事")
        XCTAssertEqual(MioMobileChromeCore.classifySwipe(dx: 60, dy: 50), .none, "斜着滑不算")
        XCTAssertEqual(MioMobileChromeCore.classifySwipe(dx: 3, dy: 2), .none)
    }

    func testTabSwitch() {
        let ids = [1, 2, 3]
        XCTAssertEqual(MioMobileChromeCore.tabSwitch(ids: ids, active: 1, swipe: .nextTab), .select(2))
        XCTAssertEqual(MioMobileChromeCore.tabSwitch(ids: ids, active: 3, swipe: .nextTab), .newTab, "最后一个再往左滑 = 新标签")
        XCTAssertEqual(MioMobileChromeCore.tabSwitch(ids: ids, active: 2, swipe: .previousTab), .select(1))
        XCTAssertEqual(MioMobileChromeCore.tabSwitch(ids: ids, active: 1, swipe: .previousTab), .none)
        XCTAssertEqual(MioMobileChromeCore.tabSwitch(ids: ids, active: 2, swipe: .overview), .none)
        XCTAssertEqual(MioMobileChromeCore.tabSwitch(ids: [], active: nil, swipe: .nextTab), .newTab)
    }

    private let g = MioMobileChromeCore.Geometry(viewHeight: 844, safeTop: 47, safeBottom: 34, bottomChromeMinY: 760,
                                                 collapsedPillMinY: 812, topChromeMaxY: 99, collapsedTopMaxY: 71)

    func testCompactInsetsHaveNoTopBar() {
        let e = MioMobileChromeCore.contentInsets(layout: .compact, collapsed: false, g: g)
        XCTAssertEqual(e.top, 47, "紧凑：顶部只让出状态栏，没有栏")
        XCTAssertEqual(e.bottom, 844 - 760 + 6)
        let c = MioMobileChromeCore.contentInsets(layout: .compact, collapsed: true, g: g)
        XCTAssertEqual(c.top, 47, "收缩时顶部也不变：不存在露一截的顶栏")
        XCTAssertEqual(c.bottom, 34, "收缩胶囊在安全区里：至少让出安全区")
        XCTAssertEqual(MioMobileChromeCore.hiddenTopInset(layout: .compact, g: g), 47)
    }

    func testTopLayoutInsets() {
        let e = MioMobileChromeCore.contentInsets(layout: .top, collapsed: false, g: g)
        XCTAssertEqual(e.top, 99)
        XCTAssertEqual(e.bottom, 84)
        let c = MioMobileChromeCore.contentInsets(layout: .top, collapsed: true, g: g)
        XCTAssertEqual(c.top, 71)
        XCTAssertEqual(c.bottom, 34)
        XCTAssertEqual(MioMobileChromeCore.hiddenTopInset(layout: .top, g: g), 71)
    }

    func testMenuContainsEveryLegacyEntry() {
        let all = MioMobileChromeCore.menuSections(.init(host: "example.com", translateMode: "bilingual")).flatMap(\.items)
        XCTAssertEqual(Set(all).count, all.count, "没有重复条目")
        XCTAssertEqual(Set(all), Set(MioMobileChromeCore.MenuItem.allCases), "网页 + 有域名 + 正在翻译：全部条目都出现")
        for (legacy, target) in MioMobileChromeCore.legacyToolbarEntries {
            let parts = target.split(separator: ".")
            XCTAssertEqual(parts.count, 2, legacy)
            if parts[0] == "menu" {
                XCTAssertNotNil(MioMobileChromeCore.MenuItem(rawValue: String(parts[1])), "\(legacy) → \(target)")
            } else {
                XCTAssertTrue(["capsule", "tabsMenu"].contains(String(parts[0])), legacy)
            }
        }
        for key in ["back", "forward", "reload", "share", "translate", "safari", "pageTools", "settings", "shield", "tabs", "close", "reader"] {
            XCTAssertNotNil(MioMobileChromeCore.legacyToolbarEntries[key], key)
        }
    }

    func testMenuHidesInapplicableItems() {
        let s = MioMobileChromeCore.menuSections(.init(isWebPage: false, host: nil, translateMode: "off", adblockEnabled: false,
                                                       webrtcGuardEnabled: false, findSupported: false))
        let items = s.flatMap(\.items)
        XCTAssertFalse(items.contains(.share))
        XCTAssertFalse(items.contains(.findInPage))
        XCTAssertFalse(items.contains(.translateOff))
        XCTAssertFalse(items.contains(.darkSite))
        XCTAssertFalse(items.contains(.adblockSite))
        XCTAssertFalse(items.contains(.webrtcSite))
        XCTAssertFalse(s.map(\.title).contains("存到 Mio"))
        XCTAssertTrue(items.contains(.settings))
        XCTAssertTrue(items.contains(.backToMio))
        XCTAssertTrue(items.contains(.adblock))
        XCTAssertEqual(s.first?.items.first, .forward)
        XCTAssertEqual(s.last?.items, [.settings, .backToMio])
    }

    func testTitles() {
        XCTAssertEqual(MioMobileChromeCore.title(.requestDesktop), "请求桌面网站")
        XCTAssertEqual(MioMobileChromeCore.title(.requestDesktop, desktop: true), "请求移动网站")
        XCTAssertEqual(MioMobileChromeCore.title(.openExternal), "用 Safari 打开")
        XCTAssertEqual(MioMobileChromeCore.title(.openExternal, systemBrowser: "系统浏览器"), "用 系统浏览器 打开")
        XCTAssertEqual(MioMobileChromeCore.title(.translateTarget, targetLanguage: "简体中文"), "译为 简体中文")
        for item in MioMobileChromeCore.MenuItem.allCases { XCTAssertFalse(MioMobileChromeCore.title(item).isEmpty) }
    }
}
