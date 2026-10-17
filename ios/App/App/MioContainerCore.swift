// MioContainerCore.swift — 内置浏览器「容器」（登录状态隔离）纯逻辑，只依赖 Foundation。
// tools/MioAppTests 在 Linux 上单测（Sources/MioWebCompat/MioContainerCore.swift 是指向这里的符号链接）。
//
// 与 Windows 的 desktop/src/containers-core.js、Android 的 xyz.mio.app.containers.ContainerState 同一套规则、同一份 JSON：
//   { "version": 1,
//     "containers": [{ "id": "<uuid 小写>", "name": "工作", "color": "blue", "createdAt": <ms> }],
//     "tabs": { "<tabKey>": { "containerId": "<id>", "locked": true } },
//     "siteRules": [{ "host": "github.com", "containerId": "<id>" }],
//     "pendingRemovals": ["<id>"] }
// - 默认容器 id = "default"：就是原来内置浏览器的那份数据（固定 UUID 的 WKWebsiteDataStore，不迁移、不丢登录），不存进 containers、不能删除
// - 未知 / 已删除的容器 id 一律按默认容器处理（resolve）
// - 锁定继承：锁定标签打开的子标签 / 弹窗继承容器且同样锁定；未锁定标签的子标签默认继承容器（可被显式指定覆盖）

import Foundation

struct MioContainer: Equatable {
    let id: String
    var name: String
    var color: String
    let createdAt: Int64 // 毫秒
    var isDefault: Bool { id == MioContainerCore.defaultId }
}

struct MioTabContainer: Equatable {
    var containerId: String
    var locked: Bool
    static let unassigned = MioTabContainer(containerId: MioContainerCore.defaultId, locked: false)
}

struct MioSiteRule: Equatable {
    let host: String
    let containerId: String
}

enum MioContainerError: Error, Equatable, CustomStringConvertible {
    case emptyName, tooMany, notFound, defaultImmutable, badColor, badHost, badRuleContainer, emptyTabKey
    var description: String {
        switch self {
        case .emptyName: return "容器名称不能为空"
        case .tooMany: return "最多 \(MioContainerCore.maxContainers) 个容器"
        case .notFound: return "容器不存在"
        case .defaultImmutable: return "默认容器不能修改或删除"
        case .badColor: return "无效的颜色"
        case .badHost: return "无效的域名"
        case .badRuleContainer: return "只能指定已有的非默认容器"
        case .emptyTabKey: return "tabKey 不能为空"
        }
    }
}

enum MioContainerCore {
    static let defaultId = "default"
    static let defaultName = "默认"
    static let defaultColor = "gray"
    static let maxContainers = 20
    static let maxName = 32
    /// 配色（Firefox Multi-Account Containers 色值）。顺序 = 新建容器自动分配的顺序：相邻两个对比强（v0.3.4 起；四端一致）
    static let colors = ["blue", "orange", "green", "pink", "purple", "yellow", "red", "turquoise", "gray"]
    static let colorHex: [String: UInt32] = [
        "blue": 0x37ADFF, "turquoise": 0x00C79A, "green": 0x51CD00, "yellow": 0xFFCB00,
        "orange": 0xFF9F00, "red": 0xFF613D, "pink": 0xFF4BDA, "purple": 0xAF51F5, "gray": 0x8E8E93,
    ]
    static let colorNames: [String: String] = [
        "blue": "蓝", "turquoise": "青", "green": "绿", "yellow": "黄", "orange": "橙", "red": "红", "pink": "粉", "purple": "紫", "gray": "灰",
    ]

    static var defaultContainer: MioContainer {
        MioContainer(id: defaultId, name: defaultName, color: defaultColor, createdAt: 0)
    }

    /// 小写 UUID（容器 id 同时是 WKWebsiteDataStore(forIdentifier:) 的 UUID）
    static func isContainerId(_ s: String?) -> Bool {
        guard let s = s, s.count == 36, s == s.lowercased(), UUID(uuidString: s) != nil else { return false }
        return true
    }

    static func cleanName(_ s: String?) -> String {
        let collapsed = (s ?? "").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return String(collapsed.prefix(maxName))
    }

    /// 站点规则主机名：小写、去掉端口 / 路径 / 末尾点 / www.；接受网址
    static func normalizeHost(_ input: String?) -> String? {
        var s = (input ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }
        if s.contains("://") {
            guard let host = URL(string: s)?.host else { return nil }
            s = host.lowercased()
        } else {
            s = String(s.split(whereSeparator: { $0 == "/" || $0 == "?" || $0 == "#" }).first ?? "")
            if let colon = s.lastIndex(of: ":"), s[s.index(after: colon)...].allSatisfy({ $0.isNumber }) { s = String(s[..<colon]) }
        }
        if s.hasSuffix(".") { s.removeLast() }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard !s.isEmpty, s.allSatisfy({ allowed.contains($0) }), s.contains("."), !s.hasPrefix("."), !s.contains("..") else { return nil }
        return s
    }

    static func hostOf(url: URL?) -> String? {
        guard let u = url, let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https", var h = u.host?.lowercased() else { return nil }
        if h.hasSuffix(".") { h.removeLast() }
        return h
    }

    /// 锁定继承（纯函数）：父标签锁定 → 父容器 + 锁定（忽略 requested）；有 requested → requested；有父标签 → 父容器；否则默认容器
    static func inherit(parent: MioTabContainer?, requested: String?) -> MioTabContainer {
        if let p = parent, p.locked { return MioTabContainer(containerId: p.containerId, locked: true) }
        if let r = requested, !r.isEmpty { return MioTabContainer(containerId: r, locked: false) }
        if let p = parent { return MioTabContainer(containerId: p.containerId, locked: false) }
        return .unassigned
    }

    /// 站点默认容器规则匹配：主机名本身或其子域名命中；多条命中取最长（最具体）的
    static func matchSiteRule(url: URL?, rules: [MioSiteRule]) -> String? {
        guard let host = hostOf(url: url) else { return nil }
        var best: MioSiteRule?
        for r in rules where host == r.host || host.hasSuffix("." + r.host) {
            if best == nil || r.host.count > best!.host.count { best = r }
        }
        return best?.containerId
    }
}

/// 容器元数据 + 标签映射 + 站点规则 + 待清理列表。值类型；MioContainerStore 负责持久化（UserDefaults）和 WebKit 数据。
struct MioContainerState: Equatable {
    private(set) var containers: [MioContainer] = []
    private(set) var tabs: [String: MioTabContainer] = [:]
    private(set) var siteRules: [MioSiteRule] = []
    private(set) var pendingRemovals: [String] = []

    var now: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    var newId: () -> String = { UUID().uuidString.lowercased() }

    static func == (a: MioContainerState, b: MioContainerState) -> Bool {
        a.containers == b.containers && a.tabs == b.tabs && a.siteRules == b.siteRules && a.pendingRemovals == b.pendingRemovals
    }

    init() {}

    /// 容错解析：坏 JSON / 坏条目丢掉
    init(json: Data?) {
        guard let data = json, let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        var seen = Set<String>()
        for case let c as [String: Any] in (root["containers"] as? [Any]) ?? [] {
            guard containers.count < MioContainerCore.maxContainers, let id = c["id"] as? String, MioContainerCore.isContainerId(id), !seen.contains(id) else { continue }
            let name = MioContainerCore.cleanName(c["name"] as? String)
            guard !name.isEmpty else { continue }
            let color = (c["color"] as? String).flatMap { MioContainerCore.colors.contains($0) ? $0 : nil } ?? MioContainerCore.colors[0]
            let created = (c["createdAt"] as? NSNumber)?.int64Value ?? 0
            seen.insert(id)
            containers.append(MioContainer(id: id, name: name, color: color, createdAt: created))
        }
        for (k, v) in (root["tabs"] as? [String: Any]) ?? [:] {
            guard !k.isEmpty, let t = v as? [String: Any], let cid = t["containerId"] as? String, exists(cid) else { continue }
            let locked = (t["locked"] as? Bool) ?? ((t["locked"] as? NSNumber)?.boolValue ?? false)
            tabs[k] = MioTabContainer(containerId: cid, locked: locked)
        }
        var hosts = Set<String>()
        for case let r as [String: Any] in (root["siteRules"] as? [Any]) ?? [] {
            guard let host = MioContainerCore.normalizeHost(r["host"] as? String), !hosts.contains(host),
                  let cid = r["containerId"] as? String, exists(cid) else { continue }
            hosts.insert(host)
            siteRules.append(MioSiteRule(host: host, containerId: cid))
        }
        for case let id as String in (root["pendingRemovals"] as? [Any]) ?? [] where MioContainerCore.isContainerId(id) && !seen.contains(id) && !pendingRemovals.contains(id) {
            pendingRemovals.append(id)
        }
    }

    func jsonData() -> Data {
        let obj: [String: Any] = [
            "version": 1,
            "containers": containers.map { ["id": $0.id, "name": $0.name, "color": $0.color, "createdAt": NSNumber(value: $0.createdAt)] as [String: Any] },
            "tabs": tabs.mapValues { ["containerId": $0.containerId, "locked": $0.locked] as [String: Any] },
            "siteRules": siteRules.map { ["host": $0.host, "containerId": $0.containerId] },
            "pendingRemovals": pendingRemovals,
        ]
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    // MARK: containers

    /// 默认容器在前
    var all: [MioContainer] { [MioContainerCore.defaultContainer] + containers }

    func get(_ id: String?) -> MioContainer? {
        if id == MioContainerCore.defaultId { return MioContainerCore.defaultContainer }
        return containers.first { $0.id == id }
    }

    func exists(_ id: String?) -> Bool {
        id == MioContainerCore.defaultId || containers.contains { $0.id == id }
    }

    /// 有效 id 原样返回，其他（空、未知、已删除）→ "default"
    func resolve(_ id: String?) -> String {
        exists(id) ? id! : MioContainerCore.defaultId
    }

    var canCreate: Bool { containers.count < MioContainerCore.maxContainers }

    /// 自动分配：按 colors 顺序取第一个没有被已有容器（不含默认容器）用的颜色；全被用过才循环。已建容器的颜色不变
    func nextColor() -> String {
        let used = Set(containers.map { $0.color })
        return MioContainerCore.colors.first { !used.contains($0) } ?? MioContainerCore.colors[containers.count % MioContainerCore.colors.count]
    }

    @discardableResult
    mutating func create(name: String, color: String? = nil) throws -> MioContainer {
        guard canCreate else { throw MioContainerError.tooMany }
        let n = MioContainerCore.cleanName(name)
        guard !n.isEmpty else { throw MioContainerError.emptyName }
        var id = newId().lowercased()
        while !MioContainerCore.isContainerId(id) || exists(id) || pendingRemovals.contains(id) { id = UUID().uuidString.lowercased() }
        let col = color.flatMap { MioContainerCore.colors.contains($0) ? $0 : nil } ?? nextColor()
        let c = MioContainer(id: id, name: n, color: col, createdAt: now())
        containers.append(c)
        return c
    }

    @discardableResult
    mutating func update(_ id: String, name: String? = nil, color: String? = nil) throws -> MioContainer {
        guard let i = containers.firstIndex(where: { $0.id == id }) else {
            throw id == MioContainerCore.defaultId ? MioContainerError.defaultImmutable : MioContainerError.notFound
        }
        if let name = name {
            let n = MioContainerCore.cleanName(name)
            guard !n.isEmpty else { throw MioContainerError.emptyName }
            containers[i].name = n
        }
        if let color = color {
            guard MioContainerCore.colors.contains(color) else { throw MioContainerError.badColor }
            containers[i].color = color
        }
        return containers[i]
    }

    /// 删除：去掉元数据、它的标签映射（这些标签应被标签管理器关闭）和站点规则，记入 pendingRemovals。返回被删除的容器和受影响的 tabKey
    @discardableResult
    mutating func remove(_ id: String) throws -> (container: MioContainer, tabKeys: [String]) {
        guard id != MioContainerCore.defaultId else { throw MioContainerError.defaultImmutable }
        guard let i = containers.firstIndex(where: { $0.id == id }) else { throw MioContainerError.notFound }
        let c = containers.remove(at: i)
        let keys = tabs(in: id)
        for k in keys { tabs.removeValue(forKey: k) }
        siteRules.removeAll { $0.containerId == id }
        if !pendingRemovals.contains(id) { pendingRemovals.append(id) }
        return (c, keys)
    }

    mutating func markRemoved(_ id: String) {
        pendingRemovals.removeAll { $0 == id }
    }

    // MARK: tab → container（restore 用）

    /// 默认容器且不锁定 = 删除记录（读出来一样）
    @discardableResult
    mutating func setTab(_ key: String, containerId: String?, locked: Bool) throws -> MioTabContainer {
        guard !key.isEmpty else { throw MioContainerError.emptyTabKey }
        let cid = resolve(containerId)
        if cid == MioContainerCore.defaultId && !locked { tabs.removeValue(forKey: key) } else { tabs[key] = MioTabContainer(containerId: cid, locked: locked) }
        return tab(key)
    }

    /// 没记录 → 默认容器、不锁定
    func tab(_ key: String) -> MioTabContainer {
        guard let t = tabs[key] else { return .unassigned }
        return MioTabContainer(containerId: resolve(t.containerId), locked: t.locked)
    }

    @discardableResult
    mutating func setTabLocked(_ key: String, _ locked: Bool) throws -> MioTabContainer {
        try setTab(key, containerId: tab(key).containerId, locked: locked)
    }

    mutating func removeTab(_ key: String) { tabs.removeValue(forKey: key) }

    /// 只保留这些标签的记录
    mutating func retainTabs(_ keys: [String]) {
        let keep = Set(keys)
        tabs = tabs.filter { keep.contains($0.key) }
    }

    func tabs(in containerId: String) -> [String] {
        tabs.filter { $0.value.containerId == containerId }.map { $0.key }.sorted()
    }

    /// 锁定继承 + resolve
    func child(of parent: MioTabContainer?, requested: String? = nil) -> MioTabContainer {
        let r = MioContainerCore.inherit(parent: parent, requested: exists(requested) ? requested : nil)
        return MioTabContainer(containerId: resolve(r.containerId), locked: r.locked && exists(r.containerId))
    }

    /// 新标签用哪个容器：锁定的打开者 > 显式指定 > 站点默认容器规则 > 未锁定的打开者 > 默认容器
    func containerForNewTab(url: URL?, opener: MioTabContainer?, requested: String? = nil) -> MioTabContainer {
        if let o = opener, o.locked { return child(of: o) }
        if let r = requested, exists(r) { return MioTabContainer(containerId: r, locked: false) }
        if let rule = containerFor(url: url) { return MioTabContainer(containerId: rule, locked: false) }
        return child(of: opener)
    }

    // MARK: site rules（可选）

    @discardableResult
    mutating func setSiteRule(_ input: String, containerId: String) throws -> String {
        guard let host = MioContainerCore.normalizeHost(input) else { throw MioContainerError.badHost }
        guard containerId != MioContainerCore.defaultId, exists(containerId) else { throw MioContainerError.badRuleContainer }
        siteRules.removeAll { $0.host == host }
        siteRules.append(MioSiteRule(host: host, containerId: containerId))
        siteRules.sort { $0.host < $1.host }
        return host
    }

    mutating func removeSiteRule(_ input: String) {
        let host = MioContainerCore.normalizeHost(input) ?? input
        siteRules.removeAll { $0.host == host }
    }

    func containerFor(url: URL?) -> String? {
        guard let id = MioContainerCore.matchSiteRule(url: url, rules: siteRules), exists(id) else { return nil }
        return id
    }
}
