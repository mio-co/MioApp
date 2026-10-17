// MioContainers.swift — 容器（登录状态隔离）。纯逻辑在 MioContainerCore.swift（v0.3.x 原样复制）；这里是：
//   - MioContainerManager：状态持久化（mio.containers.state，JSON 格式与 v0.3.x 相同）、增删改、站点规则、标签映射
//   - 数据存储 ID 映射：容器 id → WKWebsiteDataStore 的 UUID（默认容器 = v0.3.x 内置浏览器的固定 UUID，登录不丢）
//   - MioContainersModule：设置页（容器列表 / 站点规则由宿主画专门界面）+ 页面菜单「总在此容器打开此网站」
// WebKit 部分（WKWebsiteDataStore(forIdentifier:)、删除数据）在 WebKit/MioContainerDataStores.swift。

import Foundation

public extension Notification.Name {
    /// 容器列表 / 名称 / 颜色 / 站点规则变化
    static let mioContainersDidChange = Notification.Name("mio.containers.didChange")
    /// 容器即将被删除：userInfo["containerId"]: String，userInfo["tabKeys"]: [String] → 宿主关闭这些标签
    static let mioContainerWillRemove = Notification.Name("mio.containers.willRemove")
}

public enum MioContainerIDs {
    /// v0.3.x 内置浏览器的固定数据存储（MioBrowserSettings.dataStoreID）——默认容器继续用它
    public static let defaultDataStoreID = UUID(uuidString: "6D696F00-6272-6F77-7365-720000000001")!
    /// 无痕标签用的「容器」id（不落盘数据存储）
    public static let privateContainer = MioTabStore.privateContainer

    /// 容器 id → 数据存储 UUID。nil = 不落盘（无痕）
    public static func dataStoreUUID(for containerID: String?, state: MioContainerState) -> UUID? {
        if containerID == privateContainer { return nil }
        let id = state.resolve(containerID)
        if id == MioContainerCore.defaultId { return defaultDataStoreID }
        return UUID(uuidString: id) ?? defaultDataStoreID
    }
}

public final class MioContainerManager {
    public static let stateKey = "mio.containers.state"
    let prefs: MioPrefs
    public private(set) var state: MioContainerState
    public var postsNotifications = true

    public init(prefs: MioPrefs) {
        self.prefs = prefs
        state = MioContainerState(json: prefs.object(forKey: Self.stateKey) as? Data)
    }

    func save(notify: Bool = true) {
        prefs.set(state.jsonData(), forKey: Self.stateKey)
        if notify && postsNotifications { NotificationCenter.default.post(name: .mioContainersDidChange, object: self) }
    }

    /// 默认容器在前
    public var containers: [MioContainer] { state.all }
    public func container(_ id: String?) -> MioContainer? { state.get(id) }
    public func resolve(_ id: String?) -> String { state.resolve(id) }
    public func dataStoreUUID(for id: String?) -> UUID? { MioContainerIDs.dataStoreUUID(for: id, state: state) }

    @discardableResult
    public func create(name: String, color: String? = nil, icon: String? = nil) throws -> MioContainer {
        let c = try state.create(name: name, color: color, icon: icon)
        save()
        return c
    }

    @discardableResult
    public func update(_ id: String, name: String? = nil, color: String? = nil, icon: String? = nil) throws -> MioContainer {
        let c = try state.update(id, name: name, color: color, icon: icon)
        save()
        return c
    }

    /// 删除：返回要关闭的标签（宿主关掉后调用 MioContainerDataStores.purge 删数据，成功后 markRemoved）
    @discardableResult
    public func remove(_ id: String) throws -> [String] {
        let r = try state.remove(id)
        save()
        if postsNotifications {
            NotificationCenter.default.post(name: .mioContainerWillRemove, object: self, userInfo: ["containerId": id, "tabKeys": r.tabKeys])
        }
        return r.tabKeys
    }

    public var pendingRemovals: [String] { state.pendingRemovals }

    public static let presetsSeededKey = "mio.containers.presetsSeeded"

    /// 预置 个人 / 工作 / 购物 / 银行（MioContainerCore.presets）：只做一次（prefs 记一笔），而且只在还没有任何自建容器时建，
    /// 不碰升级用户自己建的容器。返回新建的容器
    @discardableResult
    public func seedPresetsIfNeeded() -> [MioContainer] {
        guard !prefs.bool(Self.presetsSeededKey, default: false) else { return [] }
        prefs.set(true, forKey: Self.presetsSeededKey)
        guard state.containers.isEmpty else { return [] }
        var out: [MioContainer] = []
        for p in MioContainerCore.presets {
            if let c = try? state.create(name: p.name, color: p.color, icon: p.icon) { out.append(c) }
        }
        if !out.isEmpty { save() }
        return out
    }
    public func markRemoved(_ id: String) { state.markRemoved(id); save(notify: false) }

    // 标签映射（会话恢复用；变化频繁，不发通知）
    @discardableResult
    public func setTab(_ key: String, containerId: String?, locked: Bool) -> MioTabContainer {
        let t = (try? state.setTab(key, containerId: containerId, locked: locked)) ?? .unassigned
        save(notify: false)
        return t
    }
    public func tab(_ key: String) -> MioTabContainer { state.tab(key) }
    public func removeTab(_ key: String) { state.removeTab(key); save(notify: false) }
    public func retainTabs(_ keys: [String]) { state.retainTabs(keys); save(notify: false) }
    public func child(of parent: MioTabContainer?, requested: String? = nil) -> MioTabContainer { state.child(of: parent, requested: requested) }
    /// 新标签：锁定的打开者 > 显式指定 > 站点默认容器 > 未锁定的打开者 > 默认容器
    public func containerForNewTab(url: URL?, opener: MioTabContainer?, requested: String? = nil) -> MioTabContainer {
        state.containerForNewTab(url: url, opener: opener, requested: requested)
    }

    // 站点规则
    public var siteRules: [MioSiteRule] { state.siteRules }
    @discardableResult
    public func setSiteRule(_ host: String, containerId: String) throws -> String {
        let h = try state.setSiteRule(host, containerId: containerId)
        save()
        return h
    }
    public func removeSiteRule(_ host: String) { state.removeSiteRule(host); save() }
    public func containerFor(url: URL?) -> String? { state.containerFor(url: url) }
}

/// 容器模块：开关只控制「站点规则自动分配」和菜单项；容器本身（数据隔离）一直可用
public final class MioContainersModule: MioModule {
    public let id = "containers"
    public let title = "容器"
    public let summary = "不同容器的登录状态、Cookie、缓存完全隔离；可让指定网站总在某个容器打开。"
    public let symbol = "square.stack.3d.up"
    public let section = MioSettingsSection.containers
    public var enabledKey: String? { "mio.kit.module.containers.enabled" }
    public let manager: MioContainerManager
    public init(manager: MioContainerManager) { self.manager = manager }

    public var settings: [MioModuleSetting] {
        [MioModuleSetting(key: "containers.summary", title: "容器", kind: .info, footer: "容器列表、颜色、站点规则在「容器」设置页管理。")]
    }

    public func settingStatus(_ key: String, prefs: MioPrefs) -> String? {
        key == "containers.summary" ? "\(manager.containers.count) 个容器，\(manager.siteRules.count) 条站点规则" : nil
    }

    public func menuItems(page: MioPageContext, prefs: MioPrefs) -> [MioModuleMenuItem] {
        guard page.host != nil, page.url?.scheme?.hasPrefix("http") == true else { return [] }
        var out: [MioModuleMenuItem] = []
        let current = manager.resolve(page.containerID)
        let ruled = manager.containerFor(url: page.url)
        for c in manager.containers where c.id != current {
            out.append(MioModuleMenuItem(moduleID: id, itemID: "reopen:" + c.id, title: "在「\(c.name)」中重新打开", symbol: "arrow.uturn.right.square"))
        }
        if let cur = manager.container(current), !cur.isDefault {
            let on = ruled == cur.id
            out.append(MioModuleMenuItem(moduleID: id, itemID: on ? "unrule" : "rule", title: "总在「\(cur.name)」打开此网站", symbol: "pin", checked: on))
        }
        return out
    }

    public func perform(_ itemID: String, page: MioPageContext, prefs: MioPrefs) -> MioModuleAction {
        if itemID.hasPrefix("reopen:") { return .host(.reopenInContainer(containerID: String(itemID.dropFirst(7)))) }
        guard let h = page.host else { return .none }
        switch itemID {
        case "rule":
            do { _ = try manager.setSiteRule(h, containerId: manager.resolve(page.containerID)) } catch { return .host(.toast("\(error)")) }
            return .host(.toast("以后 \(h) 会在这个容器打开"))
        case "unrule":
            if let n = MioContainerCore.normalizeHost(h) { manager.removeSiteRule(n) }
            return .host(.toast("已取消 \(h) 的容器规则"))
        default: return .none
        }
    }
}
