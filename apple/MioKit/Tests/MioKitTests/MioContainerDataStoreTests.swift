// 容器数据存储（真实 WKWebsiteDataStore，macOS runner）：宿主指定默认容器的存储（iOS = .default()）、
// 每个容器独立的 WKWebsiteDataStore(forIdentifier:)、Cookie 互不可见、清除某个容器的数据。Linux 上不编译。
#if canImport(WebKit) && os(macOS)
import XCTest
import WebKit
@testable import MioKit

@MainActor
final class MioContainerDataStoreTests: XCTestCase {
    private func cookie(_ name: String, _ value: String, host: String) -> HTTPCookie {
        HTTPCookie(properties: [.name: name, .value: value, .domain: host, .path: "/",
                                .expires: Date().addingTimeInterval(3600)])!
    }

    func testDefaultStoreOverrideAndPerContainerStores() async throws {
        guard #available(macOS 14.0, *) else { throw XCTSkip("WKWebsiteDataStore(forIdentifier:) needs macOS 14") }
        let m = MioContainerManager(prefs: MioMemoryPrefs())
        m.postsNotifications = false
        let custom = WKWebsiteDataStore.nonPersistent()
        let stores = MioContainerDataStores(manager: m, defaultStore: { custom })
        XCTAssertTrue(stores.dataStore(for: nil) === custom, "默认容器用宿主给的存储（iOS：.default()）")
        XCTAssertTrue(stores.dataStore(for: "default") === custom)
        XCTAssertNil(MioContainerDataStores.identifier(of: custom))

        let a = try m.create(name: "A")
        let b = try m.create(name: "B")
        let sa = stores.dataStore(for: a.id)
        let sb = stores.dataStore(for: b.id)
        XCTAssertFalse(sa === sb)
        XCTAssertTrue(stores.dataStore(for: a.id) === sa, "同一个容器复用同一个存储")
        XCTAssertEqual(MioContainerDataStores.identifier(of: sa), a.id)
        XCTAssertEqual(MioContainerDataStores.identifier(of: sb), b.id)
        XCTAssertFalse(stores.dataStore(for: "private") === custom, "无痕不用默认存储")

        await sa.httpCookieStore.setCookie(cookie("mio_ct", "A", host: "127.0.0.1"))
        await sb.httpCookieStore.setCookie(cookie("mio_ct", "B", host: "127.0.0.1"))
        let ca = await sa.httpCookieStore.allCookies().filter { $0.name == "mio_ct" }.map { $0.value }
        let cb = await sb.httpCookieStore.allCookies().filter { $0.name == "mio_ct" }.map { $0.value }
        let cd = await custom.httpCookieStore.allCookies().filter { $0.name == "mio_ct" }
        XCTAssertEqual(ca, ["A"])
        XCTAssertEqual(cb, ["B"])
        XCTAssertTrue(cd.isEmpty)

        await stores.clearData(a.id)
        let afterA = await sa.httpCookieStore.allCookies().filter { $0.name == "mio_ct" }
        let afterB = await sb.httpCookieStore.allCookies().filter { $0.name == "mio_ct" }.map { $0.value }
        XCTAssertTrue(afterA.isEmpty, "清除 A 的数据")
        XCTAssertEqual(afterB, ["B"], "B 不受影响")

        // 删除：先删元数据，再删存储
        _ = try m.remove(a.id)
        _ = await stores.purge(a.id, attempts: 2)
        _ = try m.remove(b.id)
        _ = await stores.purge(b.id, attempts: 2)
    }

    func testNoOverrideKeepsFixedDefaultStore() {
        guard #available(macOS 14.0, *) else { return }
        let m = MioContainerManager(prefs: MioMemoryPrefs())
        let stores = MioContainerDataStores(manager: m)
        XCTAssertEqual(MioContainerDataStores.identifier(of: stores.dataStore(for: nil)),
                       MioContainerIDs.defaultDataStoreID.uuidString.lowercased(), "Mac：默认容器仍是 v0.3.x 的固定 UUID")
    }
}
#endif
