import Foundation
import XCTest
@testable import MioWebCompat

/// 内置浏览器容器（登录状态隔离）纯逻辑：元数据持久化（JSON 往返）、标签映射 / 锁定继承、站点规则、删除清理
final class ContainerCoreTests: XCTestCase {
    static let id1 = "11111111-1111-4111-8111-111111111111"
    static let id2 = "22222222-2222-4222-8222-222222222222"
    static let id3 = "33333333-3333-4333-8333-333333333333"

    private func state(ids: [String] = [id1, id2]) -> MioContainerState {
        var s = MioContainerState()
        var queue = ids
        s.newId = { queue.isEmpty ? UUID().uuidString.lowercased() : queue.removeFirst() }
        s.now = { 1000 }
        return s
    }

    func testDefaultContainerImmutable() {
        var s = MioContainerState()
        XCTAssertEqual(s.all.map { $0.id }, ["default"])
        XCTAssertTrue(s.all[0].isDefault)
        XCTAssertThrowsError(try s.remove("default")) { XCTAssertEqual($0 as? MioContainerError, .defaultImmutable) }
        XCTAssertThrowsError(try s.update("default", name: "x")) { XCTAssertEqual($0 as? MioContainerError, .defaultImmutable) }
        XCTAssertEqual(s.resolve("nope"), "default")
        XCTAssertEqual(s.resolve(nil), "default")
    }

    func testCreateRenameRecolor() throws {
        var s = state()
        let a = try s.create(name: "  工作  账号 ")
        XCTAssertEqual(a, MioContainer(id: Self.id1, name: "工作 账号", color: "blue", createdAt: 1000))
        let b = try s.create(name: "小号", color: "red")
        XCTAssertEqual(b.color, "red")
        XCTAssertEqual(s.nextColor(), "turquoise")
        XCTAssertThrowsError(try s.create(name: "   ")) { XCTAssertEqual($0 as? MioContainerError, .emptyName) }
        XCTAssertThrowsError(try s.update(Self.id1, color: "black")) { XCTAssertEqual($0 as? MioContainerError, .badColor) }
        XCTAssertEqual(try s.update(Self.id1, name: "公司", color: "green").name, "公司")
        XCTAssertEqual(s.get(Self.id1)?.color, "green")
        XCTAssertEqual(try s.create(name: String(repeating: "x", count: 50)).name.count, MioContainerCore.maxName)
    }

    func testMaxContainers() throws {
        var s = MioContainerState()
        for i in 0..<MioContainerCore.maxContainers { try s.create(name: "c\(i)") }
        XCTAssertFalse(s.canCreate)
        XCTAssertThrowsError(try s.create(name: "one more")) { XCTAssertEqual($0 as? MioContainerError, .tooMany) }
    }

    func testPersistenceRoundTrip() throws {
        var s = state()
        try s.create(name: "A", color: "pink")
        try s.create(name: "B")
        try s.setTab("tab-1", containerId: Self.id1, locked: true)
        try s.setTab("tab-2", containerId: Self.id2, locked: false)
        try s.setSiteRule("https://www.GitHub.com/login", containerId: Self.id2)
        let again = MioContainerState(json: s.jsonData())
        XCTAssertEqual(again, s)
        XCTAssertEqual(again.all.map { $0.name }, ["默认", "A", "B"])
        XCTAssertEqual(again.get(Self.id1)?.createdAt, 1000)
        XCTAssertEqual(again.tab("tab-1"), MioTabContainer(containerId: Self.id1, locked: true))
        XCTAssertEqual(again.tab("tab-2"), MioTabContainer(containerId: Self.id2, locked: false))
        XCTAssertEqual(again.tab("unknown"), .unassigned)
        XCTAssertEqual(again.containerFor(url: URL(string: "https://gist.github.com/x")), Self.id2)
    }

    /// 同一份 JSON 三端通用：Windows / Android 写出的文件 iOS 也能读
    func testParsesJsonWrittenByOtherPlatforms() {
        let json = """
        {"version":1,"containers":[{"id":"\(Self.id1)","name":"ok","color":"nope","createdAt":5},{"id":"\(Self.id1)","name":"dup"},
        {"id":"default","name":"hijack"},{"id":"../../etc","name":"path"},{"id":"\(Self.id2)","name":"   "}],
        "tabs":{"t1":{"containerId":"\(Self.id1)","locked":1},"t2":{"containerId":"\(Self.id3)","locked":true},"t3":null},
        "siteRules":[{"host":"a.com","containerId":"\(Self.id3)"},{"host":"b.com","containerId":"\(Self.id1)"},{"host":"B.com","containerId":"\(Self.id1)"}],
        "pendingRemovals":["\(Self.id3)","\(Self.id3)","x","\(Self.id1)"]}
        """
        let s = MioContainerState(json: Data(json.utf8))
        XCTAssertEqual(s.all.map { $0.id }, ["default", Self.id1])
        XCTAssertEqual(s.get(Self.id1)?.color, "blue")
        XCTAssertEqual(s.get(Self.id1)?.createdAt, 5)
        XCTAssertEqual(Array(s.tabs.keys), ["t1"])
        XCTAssertEqual(s.tab("t1"), MioTabContainer(containerId: Self.id1, locked: true))
        XCTAssertEqual(s.siteRules, [MioSiteRule(host: "b.com", containerId: Self.id1)])
        XCTAssertEqual(s.pendingRemovals, [Self.id3])
        XCTAssertEqual(MioContainerState(json: Data("{not json".utf8)).all.count, 1)
        XCTAssertEqual(MioContainerState(json: nil).all.count, 1)
    }

    func testTabMapping() throws {
        var s = state(ids: [Self.id1])
        try s.create(name: "A")
        try s.setTab("x", containerId: "default", locked: false)
        XCTAssertTrue(s.tabs.isEmpty)
        try s.setTab("x", containerId: "ghost", locked: true)
        XCTAssertEqual(s.tab("x"), MioTabContainer(containerId: "default", locked: true))
        try s.setTab("y", containerId: Self.id1, locked: false)
        XCTAssertEqual(try s.setTabLocked("y", true), MioTabContainer(containerId: Self.id1, locked: true))
        try s.setTab("z", containerId: Self.id1, locked: false)
        s.retainTabs(["y"])
        XCTAssertEqual(Array(s.tabs.keys), ["y"])
        XCTAssertThrowsError(try s.setTab("", containerId: Self.id1, locked: false))
    }

    func testLockInheritance() {
        let lockedA = MioTabContainer(containerId: Self.id1, locked: true)
        let openA = MioTabContainer(containerId: Self.id1, locked: false)
        XCTAssertEqual(MioContainerCore.inherit(parent: lockedA, requested: Self.id2), lockedA)
        XCTAssertEqual(MioContainerCore.inherit(parent: openA, requested: Self.id2), MioTabContainer(containerId: Self.id2, locked: false))
        XCTAssertEqual(MioContainerCore.inherit(parent: openA, requested: nil), openA)
        XCTAssertEqual(MioContainerCore.inherit(parent: nil, requested: Self.id2), MioTabContainer(containerId: Self.id2, locked: false))
        XCTAssertEqual(MioContainerCore.inherit(parent: nil, requested: nil), .unassigned)
        let child = MioContainerCore.inherit(parent: lockedA, requested: nil)
        XCTAssertEqual(MioContainerCore.inherit(parent: child, requested: Self.id2), lockedA)
    }

    func testContainerForNewTabPriority() throws {
        var s = state()
        try s.create(name: "A")
        try s.create(name: "B")
        try s.setSiteRule("github.com", containerId: Self.id2)
        let lockedA = MioTabContainer(containerId: Self.id1, locked: true)
        let openA = MioTabContainer(containerId: Self.id1, locked: false)
        let gh = URL(string: "https://github.com")
        XCTAssertEqual(s.child(of: lockedA, requested: Self.id2), lockedA)
        XCTAssertEqual(s.child(of: openA, requested: "ghost"), openA)
        XCTAssertEqual(s.child(of: MioTabContainer(containerId: "ghost", locked: true)), .unassigned)
        XCTAssertEqual(s.containerForNewTab(url: gh, opener: lockedA, requested: Self.id2), lockedA)
        XCTAssertEqual(s.containerForNewTab(url: gh, opener: openA, requested: "default"), .unassigned)
        XCTAssertEqual(s.containerForNewTab(url: URL(string: "https://api.github.com/x"), opener: openA), MioTabContainer(containerId: Self.id2, locked: false))
        XCTAssertEqual(s.containerForNewTab(url: URL(string: "https://example.com"), opener: openA), openA)
        XCTAssertEqual(s.containerForNewTab(url: URL(string: "https://example.com"), opener: nil), .unassigned)
    }

    func testSiteRules() throws {
        XCTAssertEqual(MioContainerCore.normalizeHost("https://WWW.Example.com:8443/a?b"), "example.com")
        XCTAssertEqual(MioContainerCore.normalizeHost("sub.example.com/path"), "sub.example.com")
        XCTAssertEqual(MioContainerCore.normalizeHost("example.com:8080"), "example.com")
        XCTAssertNil(MioContainerCore.normalizeHost("localhost"))
        XCTAssertNil(MioContainerCore.normalizeHost("javascript:alert(1)"))
        XCTAssertNil(MioContainerCore.normalizeHost(""))
        let rules = [MioSiteRule(host: "example.com", containerId: "a"), MioSiteRule(host: "mail.example.com", containerId: "b")]
        XCTAssertEqual(MioContainerCore.matchSiteRule(url: URL(string: "https://x.mail.example.com/"), rules: rules), "b")
        XCTAssertEqual(MioContainerCore.matchSiteRule(url: URL(string: "https://www.example.com/"), rules: rules), "a")
        XCTAssertNil(MioContainerCore.matchSiteRule(url: URL(string: "https://notexample.com/"), rules: rules))
        XCTAssertNil(MioContainerCore.matchSiteRule(url: URL(string: "file:///etc/passwd"), rules: rules))
        var s = state(ids: [Self.id1])
        try s.create(name: "A")
        XCTAssertThrowsError(try s.setSiteRule("a.com", containerId: "default"))
        XCTAssertThrowsError(try s.setSiteRule("a.com", containerId: Self.id2))
        XCTAssertThrowsError(try s.setSiteRule("nope", containerId: Self.id1)) { XCTAssertEqual($0 as? MioContainerError, .badHost) }
        try s.setSiteRule("a.com", containerId: Self.id1)
        try s.setSiteRule("A.com", containerId: Self.id1)
        XCTAssertEqual(s.siteRules.count, 1)
        s.removeSiteRule("https://a.com/")
        XCTAssertTrue(s.siteRules.isEmpty)
    }

    func testRemoveCleansMappingsAndRules() throws {
        var s = state()
        try s.create(name: "A")
        try s.create(name: "B")
        try s.setTab("t1", containerId: Self.id1, locked: true)
        try s.setTab("t2", containerId: Self.id1, locked: false)
        try s.setTab("t3", containerId: Self.id2, locked: true)
        try s.setSiteRule("a.com", containerId: Self.id1)
        let r = try s.remove(Self.id1)
        XCTAssertEqual(r.container.id, Self.id1)
        XCTAssertEqual(r.tabKeys, ["t1", "t2"])
        XCTAssertEqual(s.tab("t1"), .unassigned)
        XCTAssertEqual(s.tab("t3"), MioTabContainer(containerId: Self.id2, locked: true))
        XCTAssertNil(s.containerFor(url: URL(string: "https://a.com")))
        XCTAssertEqual(s.pendingRemovals, [Self.id1])
        XCTAssertEqual(MioContainerState(json: s.jsonData()).pendingRemovals, [Self.id1])
        s.markRemoved(Self.id1)
        XCTAssertTrue(s.pendingRemovals.isEmpty)
        XCTAssertThrowsError(try s.remove(Self.id1)) { XCTAssertEqual($0 as? MioContainerError, .notFound) }
    }

    func testIsContainerId() {
        XCTAssertTrue(MioContainerCore.isContainerId(Self.id1))
        XCTAssertFalse(MioContainerCore.isContainerId("AAAAAAAA-1111-4111-8111-111111111111"))
        XCTAssertFalse(MioContainerCore.isContainerId("default"))
        XCTAssertFalse(MioContainerCore.isContainerId(nil))
    }
}
