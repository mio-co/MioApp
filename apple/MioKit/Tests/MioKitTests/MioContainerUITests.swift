import Foundation
import XCTest
@testable import MioKit

/// v0.4.1 iOS 容器 UI 用到的 MioKit 部分：图标字段（JSON 往返 / 旧 JSON 兼容）、预置 个人/工作/购物/银行、
/// 标签进哪个容器（MioContainerTabPolicy：恢复 / 显式指定 / 弹窗继承 / 父标签继承 / 站点规则 / 无痕）
final class MioContainerUITests: XCTestCase {
    static let id1 = "11111111-1111-4111-8111-111111111111"
    static let id2 = "22222222-2222-4222-8222-222222222222"

    private func manager(_ prefs: MioMemoryPrefs = MioMemoryPrefs()) -> MioContainerManager {
        let m = MioContainerManager(prefs: prefs)
        m.postsNotifications = false
        return m
    }

    // MARK: 图标

    func testIconsHaveSymbolsAndNames() {
        XCTAssertEqual(Set(MioContainerCore.icons), Set(MioContainerCore.iconSymbols.keys))
        XCTAssertEqual(Set(MioContainerCore.icons), Set(MioContainerCore.iconNames.keys))
        XCTAssertTrue(MioContainerCore.icons.contains(MioContainerCore.defaultIcon))
        XCTAssertEqual(MioContainerCore.iconSymbol("nope"), "circle.fill")
        XCTAssertEqual(MioContainerCore.iconSymbol(nil), "circle.fill")
        XCTAssertEqual(MioContainerCore.defaultContainer.icon, "circle")
    }

    func testIconCreateUpdateAndRoundTrip() throws {
        var s = MioContainerState()
        var ids = [Self.id1, Self.id2]
        s.newId = { ids.removeFirst() }
        s.now = { 7 }
        let a = try s.create(name: "工作", color: "orange", icon: "briefcase")
        XCTAssertEqual(a.icon, "briefcase")
        XCTAssertEqual(a.symbol, "briefcase.fill")
        let b = try s.create(name: "无图标")
        XCTAssertEqual(b.icon, "circle", "没指定 → 圆点")
        XCTAssertThrowsError(try s.create(name: "坏", icon: "rocket")) { XCTAssertEqual($0 as? MioContainerError, .badIcon) }
        XCTAssertThrowsError(try s.update(Self.id1, icon: "rocket")) { XCTAssertEqual($0 as? MioContainerError, .badIcon) }
        XCTAssertEqual(try s.update(Self.id2, icon: "pet").icon, "pet")
        XCTAssertEqual(try s.update(Self.id1, name: "公司").icon, "briefcase", "改名不动图标")
        let again = MioContainerState(json: s.jsonData())
        XCTAssertEqual(again, s)
        XCTAssertEqual(again.get(Self.id2)?.icon, "pet")
        let json = String(data: s.jsonData(), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"icon\":\"briefcase\""), json)
    }

    /// v0.4.0 / Mac / v0.3.x 写的 JSON 没有 icon 字段；未知图标也按圆点
    func testLegacyJSONWithoutIcon() {
        let json = """
        {"version":1,"containers":[{"id":"\(Self.id1)","name":"老容器","color":"red","createdAt":5},
        {"id":"\(Self.id2)","name":"怪图标","color":"blue","icon":"rocket","createdAt":6}],"tabs":{},"siteRules":[]}
        """
        let s = MioContainerState(json: Data(json.utf8))
        XCTAssertEqual(s.containers.map { $0.icon }, ["circle", "circle"])
        XCTAssertEqual(s.get(Self.id1)?.color, "red")
    }

    // MARK: 预置

    func testPresetsSeededOnceInOrder() {
        let prefs = MioMemoryPrefs()
        let m = manager(prefs)
        let made = m.seedPresetsIfNeeded()
        XCTAssertEqual(made.map { $0.name }, ["个人", "工作", "购物", "银行"])
        XCTAssertEqual(m.containers.map { $0.name }, ["默认", "个人", "工作", "购物", "银行"])
        XCTAssertEqual(made.map { $0.color }, ["blue", "orange", "pink", "green"])
        XCTAssertEqual(made.map { $0.icon }, ["fingerprint", "briefcase", "cart", "dollar"])
        XCTAssertEqual(Set(made.map { $0.id }).count, 4)
        XCTAssertTrue(made.allSatisfy { MioContainerCore.isContainerId($0.id) })
        // 第二次 / 重启后不再建；用户删掉预置也不会回来
        XCTAssertEqual(m.seedPresetsIfNeeded(), [])
        _ = try? m.remove(made[3].id)
        let m2 = manager(prefs)
        XCTAssertEqual(m2.seedPresetsIfNeeded(), [])
        XCTAssertEqual(m2.containers.map { $0.name }, ["默认", "个人", "工作", "购物"])
    }

    func testPresetsSkippedWhenUserAlreadyHasContainers() throws {
        let prefs = MioMemoryPrefs()
        let m = manager(prefs)
        _ = try m.create(name: "我的")
        XCTAssertEqual(m.seedPresetsIfNeeded(), [])
        XCTAssertEqual(m.containers.map { $0.name }, ["默认", "我的"])
        XCTAssertEqual(prefs.object(forKey: MioContainerManager.presetsSeededKey) as? Bool, true)
    }

    // MARK: 标签进哪个容器

    private func policyState() throws -> (MioContainerState, work: String, bank: String) {
        var s = MioContainerState()
        var ids = [Self.id1, Self.id2]
        s.newId = { ids.removeFirst() }
        let w = try s.create(name: "工作")
        let b = try s.create(name: "银行")
        _ = try s.setSiteRule("bank.example", containerId: b.id)
        return (s, w.id, b.id)
    }

    private func decide(_ s: MioContainerState, record: MioTabContainer? = nil, pending: String? = nil,
                        parent: MioTabContainer? = nil, popup: Bool = false, priv: Bool = false,
                        url: String? = nil, rules: Bool = true) -> MioTabContainer? {
        MioContainerTabPolicy.decide(state: s, record: record, pending: pending, parent: parent, isPopup: popup,
                                     isPrivate: priv, url: url.flatMap { URL(string: $0) }, siteRulesEnabled: rules)
    }

    func testPolicyPrivateNeverInContainer() throws {
        let (s, w, _) = try policyState()
        XCTAssertNil(decide(s, pending: w, priv: true))
        XCTAssertNil(decide(s, parent: MioTabContainer(containerId: w, locked: true), popup: true, priv: true))
    }

    func testPolicyRestoredTabKeepsContainer() throws {
        let (s, w, _) = try policyState()
        XCTAssertEqual(decide(s, record: MioTabContainer(containerId: w, locked: false), url: "https://bank.example/")?.containerId, w,
                       "恢复的标签留在原容器，不被站点规则换走")
        // 记录里的容器已删除 → 默认
        XCTAssertEqual(decide(s, record: MioTabContainer(containerId: "33333333-3333-4333-8333-333333333333", locked: false))?.containerId, "default")
        // 没有记录、没有父标签（恢复回来的默认容器标签 / + 号新标签）→ 默认，不套站点规则
        XCTAssertEqual(decide(s, url: "https://bank.example/")?.containerId, "default")
    }

    func testPolicyExplicitChoiceWins() throws {
        let (s, w, b) = try policyState()
        XCTAssertEqual(decide(s, pending: w, url: "https://bank.example/"), MioTabContainer(containerId: w, locked: false))
        XCTAssertEqual(decide(s, pending: "default", parent: MioTabContainer(containerId: b, locked: false))?.containerId, "default",
                       "在默认容器中重新打开")
        XCTAssertEqual(decide(s, pending: "nope")?.containerId, "default")
    }

    func testPolicyPopupInheritsParent() throws {
        let (s, w, _) = try policyState()
        // target=_blank / window.open：WebKit 的配置带着父标签的存储，站点规则不生效
        XCTAssertEqual(decide(s, pending: nil, parent: MioTabContainer(containerId: w, locked: false), popup: true,
                              url: "https://bank.example/")?.containerId, w)
        XCTAssertEqual(decide(s, parent: nil, popup: true)?.containerId, "default")
    }

    func testPolicyLinkInNewTabInheritsOrFollowsRule() throws {
        let (s, w, b) = try policyState()
        let parent = MioTabContainer(containerId: w, locked: false)
        XCTAssertEqual(decide(s, parent: parent, url: "https://other.example/")?.containerId, w)
        XCTAssertEqual(decide(s, parent: parent, url: "https://bank.example/")?.containerId, b, "站点规则优先于未锁定的父容器")
        XCTAssertEqual(decide(s, parent: parent, url: "https://bank.example/", rules: false)?.containerId, w, "容器模块关掉 → 不套规则")
        XCTAssertEqual(decide(s, parent: MioTabContainer(containerId: w, locked: true), url: "https://bank.example/"),
                       MioTabContainer(containerId: w, locked: true), "锁定的父容器优先")
    }
}
