import XCTest
@testable import MioWebCompat

/// 与 desktop/test/tabs-core.test.js、Android TabsCoreTest 同样的用例
final class MioTabsCoreTests: XCTestCase {
    private func hosts(_ s: MioTabStore) -> [String] { s.tabs.map { MioTabStore.displayHost($0.url) } }

    func testNewTabGoesRightOfActiveAndActivates() {
        let s = MioTabStore()
        let a = s.add("https://a.com/")!
        s.add("https://b.com/")
        s.select(a.id)
        let c = s.add("https://c.com/")!
        XCTAssertEqual(hosts(s), ["a.com", "c.com", "b.com"])
        XCTAssertEqual(s.activeID, c.id)
    }

    func testBackgroundTabsKeepOpeningOrder() {
        let s = MioTabStore()
        s.add("https://a.com/")
        s.add("https://z.com/", activate: false, index: 1)
        s.select(index: 0)
        for n in 1...3 { s.add("https://\(n).com/", activate: false, fromActive: true) }
        XCTAssertEqual(hosts(s), ["a.com", "1.com", "2.com", "3.com", "z.com"])
        s.select(index: 4)
        s.select(index: 0)
        s.add("https://4.com/", activate: false, fromActive: true)
        XCTAssertEqual(hosts(s), ["a.com", "4.com", "1.com", "2.com", "3.com", "z.com"])
    }

    func testForegroundChildKeepsOpener() {
        let s = MioTabStore()
        let a = s.add("https://a.com/")!
        let b = s.add("https://b.com/", fromActive: true)!
        XCTAssertEqual(s.activeID, b.id)
        XCTAssertEqual(s.tab(b.id)?.openerID, a.id)
    }

    func testCloseActivatesRightThenLeft() {
        let s = MioTabStore()
        let a = s.add("https://a.com/")!
        let b = s.add("https://b.com/")!
        let c = s.add("https://c.com/")!
        s.select(b.id)
        s.close(b.id)
        XCTAssertEqual(s.activeID, c.id)
        s.close(c.id)
        XCTAssertEqual(s.activeID, a.id)
        s.close(a.id)
        XCTAssertNil(s.activeID)
        XCTAssertTrue(s.isEmpty)
        XCTAssertNil(s.close(999))
    }

    func testReopenClosedRestoresPositionAndContainer() {
        let s = MioTabStore()
        s.add("https://a.com/")
        let b = s.add("https://b.com/", title: "B", containerID: "work", locked: true)!
        s.add("https://c.com/")
        s.close(b.id)
        s.close(s.tabs[0].id)
        XCTAssertEqual(s.reopenClosed()?.url, "https://a.com/")
        let r = s.reopenClosed()!
        XCTAssertEqual(r.title, "B")
        XCTAssertEqual(r.containerID, "work")
        XCTAssertTrue(r.locked)
        XCTAssertEqual(hosts(s), ["a.com", "b.com", "c.com"])
        XCTAssertNil(s.reopenClosed())
    }

    func testClosedStackLimitAndHTTPOnly() {
        let s = MioTabStore(maxClosed: 2)
        for u in ["https://1.com/", "about:blank", "https://2.com/", "https://3.com/"] { s.close(s.add(u)!.id) }
        XCTAssertEqual(s.closed.map(\.url), ["https://2.com/", "https://3.com/"])
    }

    func testMaxTabs() {
        let s = MioTabStore(maxTabs: 2)
        XCTAssertNotNil(s.add("https://a.com/"))
        XCTAssertNotNil(s.add("https://b.com/"))
        XCTAssertNil(s.add("https://c.com/"))
    }

    func testSelectRelativeAndNumber() {
        let s = MioTabStore()
        ["a", "b", "c"].forEach { s.add("https://\($0).com/") }
        s.select(index: 2)
        s.selectRelative(1)
        XCTAssertEqual(s.activeIndex, 0)
        s.selectRelative(-1)
        XCTAssertEqual(s.activeIndex, 2)
        s.selectNumber(1)
        XCTAssertEqual(s.activeIndex, 0)
        s.selectNumber(9)
        XCTAssertEqual(s.activeIndex, 2)
        XCTAssertFalse(s.selectNumber(5))
    }

    func testMove() {
        let s = MioTabStore()
        ["a", "b", "c"].forEach { s.add("https://\($0).com/") }
        XCTAssertTrue(s.move(from: 0, to: 2))
        XCTAssertEqual(hosts(s), ["b.com", "c.com", "a.com"])
        XCTAssertFalse(s.move(from: 1, to: 1))
        XCTAssertTrue(s.move(from: 0, to: 99))
        XCTAssertEqual(hosts(s), ["c.com", "a.com", "b.com"])
        XCTAssertFalse(s.move(from: 5, to: 0))
    }

    func testToUnloadLRU() {
        let s = MioTabStore()
        let ids = ["a", "b", "c", "d"].map { s.add("https://\($0).com/")!.id }
        s.select(ids[1]); s.select(ids[0]); s.select(ids[3])
        XCTAssertEqual(s.toUnload(maxLoaded: 2) { _ in true }, [ids[2], ids[1]])
        XCTAssertEqual(s.toUnload(maxLoaded: 10) { _ in true }, [])
        XCTAssertFalse(s.toUnload(maxLoaded: 1) { _ in true }.contains(ids[3]))
    }

    func testContainerInheritanceAndLock() {
        let s = MioTabStore()
        let a = s.add("https://a.com/", containerID: "shop")!
        XCTAssertEqual(s.add("https://a.com/x", fromActive: true)?.containerID, "shop")
        s.select(a.id)
        XCTAssertEqual(s.add("https://a.com/y", fromActive: true, containerID: "work")?.containerID, "work")
        s.setLocked(a.id, true)
        s.select(a.id)
        let forced = s.add("https://a.com/z", fromActive: true, containerID: "work")!
        XCTAssertEqual(forced.containerID, "shop")
        XCTAssertTrue(forced.locked)
        XCTAssertFalse(s.setContainer(forced.id, "work"))
        s.setLocked(forced.id, false)
        XCTAssertTrue(s.setContainer(forced.id, "work"))
        XCTAssertEqual(s.add("https://b.com/", containerID: "../evil")?.containerID, "default")
    }

    func testRemoveContainer() {
        let s = MioTabStore()
        s.add("https://a.com/")
        s.add("https://b.com/", containerID: "p2")
        s.add("https://c.com/", containerID: "p2")
        let d = s.add("https://d.com/", containerID: "p2")!
        s.close(d.id)
        XCTAssertEqual(s.removeContainer("p2").count, 2)
        XCTAssertEqual(hosts(s), ["a.com"])
        XCTAssertFalse(s.closed.contains { $0.containerID == "p2" })
        XCTAssertEqual(s.removeContainer("default"), [])
    }

    func testSerializeRestoreRoundTrip() throws {
        let s = MioTabStore()
        s.add("https://a.com/", title: "  A \n title ")
        s.add("about:blank")
        let c = s.add("https://c.com/x?y=1", title: "C", containerID: "acc2", locked: true)!
        s.add("https://d.com/", containerID: "gone")
        s.select(c.id)
        let data = s.serialize()
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["v"] as? Int, 2)
        XCTAssertEqual(obj["active"] as? Int, 1)
        let items = try XCTUnwrap(obj["tabs"] as? [[String: Any]])
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0]["title"] as? String, "A title")
        XCTAssertNil(items[0]["container"])
        XCTAssertEqual(items[1]["container"] as? String, "acc2")
        XCTAssertEqual(items[1]["locked"] as? Bool, true)

        let r = MioTabStore()
        XCTAssertEqual(r.restore(data, knownContainers: ["acc2"]), 3)
        XCTAssertEqual(r.active?.url, "https://c.com/x?y=1")
        XCTAssertEqual(r.active?.containerID, "acc2")
        XCTAssertEqual(r.active?.locked, true)
        XCTAssertEqual(r.tabs[2].containerID, "default")
        // 已删除容器里锁定的标签：回到默认容器并解锁
        let g = MioTabStore()
        XCTAssertEqual(g.restore(Data(#"{"tabs":[{"url":"https://e.com/","container":"gone","locked":true}]}"#.utf8), knownContainers: ["acc2"]), 1)
        XCTAssertEqual(g.tabs[0].containerID, "default")
        XCTAssertEqual(g.tabs[0].locked, false)
        XCTAssertEqual(MioTabStore().restore(Data(#"{"tabs":[{"url":"javascript:alert(1)"}]}"#.utf8)), 0)
        XCTAssertEqual(MioTabStore().restore(nil), 0)
        // Windows 写的 v1 文件也能读
        XCTAssertEqual(MioTabStore().restore(Data(#"{"v":1,"active":0,"tabs":[{"url":"https://a.com/","title":"A"}]}"#.utf8)), 1)
        let big = MioTabStore(maxTabs: 3)
        let many = (0..<10).map { #"{"url":"https://\#($0).com/"}"# }.joined(separator: ",")
        XCTAssertEqual(big.restore(Data(#"{"active":99,"tabs":[\#(many)]}"#.utf8)), 3)
        XCTAssertEqual(big.activeIndex, 2)
    }

    func testUpdate() {
        let s = MioTabStore()
        let a = s.add("https://a.com/")!
        XCTAssertTrue(s.update(a.id, title: "x"))
        XCTAssertFalse(s.update(a.id, title: "x"))
        XCTAssertTrue(s.update(a.id, url: "https://b.com/"))
        XCTAssertFalse(s.update(999, url: "https://b.com/"))
    }

    func testDisplayHostAndNewTabURL() {
        XCTAssertEqual(MioTabStore.displayHost("https://www.YouTube.com/watch?v=1"), "youtube.com")
        XCTAssertEqual(MioTabStore.displayHost("about:blank"), "")
        XCTAssertEqual(MioTabStore.normalizeNewTabURL(""), MioTabStore.defaultNewTabURL)
        XCTAssertEqual(MioTabStore.normalizeNewTabURL("example.com"), "https://example.com/")
        XCTAssertEqual(MioTabStore.normalizeNewTabURL("localhost:8080"), "https://localhost:8080/")
        XCTAssertEqual(MioTabStore.normalizeNewTabURL("http://example.com/a"), "http://example.com/a")
        XCTAssertNil(MioTabStore.normalizeNewTabURL("javascript:alert(1)"))
        XCTAssertNil(MioTabStore.normalizeNewTabURL("file:///etc/passwd"))
        XCTAssertNil(MioTabStore.normalizeNewTabURL("nodot"))
    }
}
