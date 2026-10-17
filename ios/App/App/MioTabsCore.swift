// MioTabsCore.swift — 内置浏览器多标签页的纯逻辑（只依赖 Foundation；tools/MioAppTests 在 Linux 上单测）。
// 与 Windows 的 desktop/src/tabs-core.js、Android 的 TabsCore.java 同一套规则：
//   - 新标签插在当前标签右边；从当前标签打开的一串后台标签按打开顺序排在一起（openerID）
//   - 关闭当前标签 → 激活右边的，没有就左边的；最近关闭的最多记 20 个，可恢复（原位置、原容器）
//   - 标签数上限；超过「同时加载」上限时按最近使用卸载后台标签（只留 URL / 标题）
//   - 容器（登录隔离，feat/containers-core 接入）：每个标签一个 containerID（"default" = 现有浏览器数据）；
//     从标签里打开的子标签继承容器，锁定的标签连锁定一起继承且不能改容器
//   - 持久化只存 http(s) 的 URL + 标题 + 容器 + 锁定 + 当前标签序号（JSON，与 Windows 格式相同）

import Foundation

struct MioTab: Equatable {
    let id: Int
    var url: String
    var title: String
    var openerID: Int?
    var containerID: String
    var locked: Bool
    var lastActive: Int
}

struct MioClosedTab: Equatable {
    let url: String
    let title: String
    let index: Int
    let containerID: String
    let locked: Bool
}

final class MioTabStore {
    static let defaultContainer = "default"
    static let defaultMaxTabs = 50
    static let defaultMaxClosed = 20
    static let maxTitle = 300
    static let defaultNewTabURL = "https://mio.300031.xyz/mio/nav"

    let maxTabs: Int
    let maxClosed: Int
    private(set) var tabs: [MioTab] = []
    private(set) var activeID: Int?
    private(set) var closed: [MioClosedTab] = []
    private var nextID = 1
    private var clock = 0

    init(maxTabs: Int = MioTabStore.defaultMaxTabs, maxClosed: Int = MioTabStore.defaultMaxClosed) {
        self.maxTabs = maxTabs
        self.maxClosed = maxClosed
    }

    // MARK: helpers

    static func isHTTP(_ s: String) -> Bool {
        guard let u = URL(string: s), let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https", let h = u.host, !h.isEmpty else { return false }
        return true
    }

    /// 地址栏 / 标签条显示用的域名：小写、去掉 www.
    static func displayHost(_ s: String) -> String {
        guard isHTTP(s), var h = URL(string: s)?.host?.lowercased() else { return "" }
        if h.hasSuffix(".") { h.removeLast() }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    /// 设置里的新标签页地址：空 → 默认（MioCore 导航）；补 https://；不是 http(s) → nil
    static func normalizeNewTabURL(_ input: String?) -> String? {
        var s = (input ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return defaultNewTabURL }
        let hasScheme = s.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) != nil
        let hostPort = s.range(of: "^[^\\s/:]+:[0-9]+(/|$)", options: .regularExpression) != nil
        if !hasScheme || hostPort { s = "https://" + s }
        guard isHTTP(s), let u = URL(string: s), let host = u.host, host.contains(".") || host == "localhost" else { return nil }
        if u.path.isEmpty, var c = URLComponents(string: s) {
            c.path = "/"
            return c.string
        }
        return u.absoluteString
    }

    static func cleanTitle(_ t: String?) -> String {
        let collapsed = (t ?? "").components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return String(collapsed.prefix(maxTitle))
    }

    static func cleanContainer(_ c: String?) -> String {
        let s = (c ?? "").trimmingCharacters(in: .whitespaces)
        guard (1...64).contains(s.count), s.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return defaultContainer }
        return s
    }

    // MARK: queries

    var count: Int { tabs.count }
    var isEmpty: Bool { tabs.isEmpty }
    var canAdd: Bool { tabs.count < maxTabs }
    var hasClosed: Bool { !closed.isEmpty }
    var active: MioTab? { activeID.flatMap { tab($0) } }
    var activeIndex: Int? { activeID.flatMap { index(of: $0) } }

    func tab(_ id: Int) -> MioTab? { tabs.first { $0.id == id } }
    func index(of id: Int) -> Int? { tabs.firstIndex { $0.id == id } }

    // MARK: mutations

    /// 新建标签。fromActive：从当前标签打开（opener = 当前标签，继承容器；它锁定时强制继承容器 + 锁定）。满了返回 nil。
    @discardableResult
    func add(_ url: String, title: String? = nil, activate: Bool = true, fromActive: Bool = false,
             index requested: Int? = nil, containerID: String? = nil, locked: Bool = false, openerID explicitOpener: Int?? = nil) -> MioTab? {
        guard canAdd else { return nil }
        let openerID: Int? = explicitOpener ?? (fromActive ? activeID : nil)
        let opener = openerID.flatMap { tab($0) }
        var container = MioTabStore.cleanContainer(containerID)
        var isLocked = locked
        if let o = opener, fromActive {
            if o.locked {
                container = o.containerID
                isLocked = true
            } else if containerID == nil {
                container = o.containerID
            }
        }
        let t = MioTab(id: nextID, url: url, title: MioTabStore.cleanTitle(title), openerID: openerID, containerID: container, locked: isLocked, lastActive: 0)
        nextID += 1
        var at: Int
        if let r = requested {
            at = max(0, min(tabs.count, r))
        } else if let ai = activeIndex {
            at = ai + 1
            if let oid = t.openerID, oid == activeID {
                while at < tabs.count && tabs[at].openerID == activeID { at += 1 }
            }
        } else {
            at = tabs.count
        }
        tabs.insert(t, at: at)
        if activate || activeID == nil { select(t.id) }
        return tab(t.id)
    }

    @discardableResult
    func select(_ id: Int) -> Bool {
        guard let i = index(of: id) else { return false }
        if activeID != id, let prev = activeID {
            for k in tabs.indices where tabs[k].openerID == prev && tabs[k].id != id { tabs[k].openerID = nil }
        }
        activeID = id
        clock += 1
        tabs[i].lastActive = clock
        return true
    }

    @discardableResult
    func select(index i: Int) -> Bool {
        guard tabs.indices.contains(i) else { return false }
        return select(tabs[i].id)
    }

    /// ⌃Tab / ⌃⇧Tab：循环切换
    @discardableResult
    func selectRelative(_ delta: Int) -> Bool {
        guard !tabs.isEmpty else { return false }
        let n = tabs.count
        let i = activeIndex ?? 0
        return select(index: ((i + delta) % n + n) % n)
    }

    /// ⌘1…⌘8 选第 n 个，⌘9 选最后一个
    @discardableResult
    func selectNumber(_ n: Int) -> Bool {
        n == 9 ? select(index: tabs.count - 1) : select(index: n - 1)
    }

    @discardableResult
    func update(_ id: Int, url: String? = nil, title: String? = nil) -> Bool {
        guard let i = index(of: id) else { return false }
        var changed = false
        if let u = url, u != tabs[i].url { tabs[i].url = u; changed = true }
        if let t = title {
            let c = MioTabStore.cleanTitle(t)
            if c != tabs[i].title { tabs[i].title = c; changed = true }
        }
        return changed
    }

    @discardableResult
    func setContainer(_ id: Int, _ containerID: String) -> Bool {
        guard let i = index(of: id), !tabs[i].locked else { return false }
        let c = MioTabStore.cleanContainer(containerID)
        guard c != tabs[i].containerID else { return false }
        tabs[i].containerID = c
        return true
    }

    @discardableResult
    func setLocked(_ id: Int, _ locked: Bool) -> Bool {
        guard let i = index(of: id), tabs[i].locked != locked else { return false }
        tabs[i].locked = locked
        return true
    }

    /// 删除容器：关闭它的标签（返回 id），最近关闭里它的条目也删掉
    @discardableResult
    func removeContainer(_ containerID: String) -> [Int] {
        let c = MioTabStore.cleanContainer(containerID)
        guard c != MioTabStore.defaultContainer else { return [] }
        let ids = tabs.filter { $0.containerID == c }.map(\.id)
        ids.forEach { close($0) }
        closed.removeAll { $0.containerID == c }
        return ids
    }

    /// 关闭标签：返回被关闭的标签（不存在 → nil）；activeID 变成关闭后要显示的标签（没有标签 → nil）
    @discardableResult
    func close(_ id: Int) -> MioTab? {
        guard let i = index(of: id) else { return nil }
        let t = tabs.remove(at: i)
        if MioTabStore.isHTTP(t.url) {
            closed.append(MioClosedTab(url: t.url, title: t.title, index: i, containerID: t.containerID, locked: t.locked))
            if closed.count > maxClosed { closed.removeFirst(closed.count - maxClosed) }
        }
        for k in tabs.indices where tabs[k].openerID == id { tabs[k].openerID = nil }
        if activeID == id {
            activeID = nil
            if tabs.indices.contains(i) { select(tabs[i].id) } else if i > 0, tabs.indices.contains(i - 1) { select(tabs[i - 1].id) }
        }
        return t
    }

    /// ⌘⇧T：恢复最近关闭的标签并激活
    @discardableResult
    func reopenClosed() -> MioTab? {
        guard canAdd, let c = closed.popLast() else { return nil }
        return add(c.url, title: c.title, activate: true, index: c.index, containerID: c.containerID, locked: c.locked, openerID: .some(nil))
    }

    @discardableResult
    func move(from: Int, to: Int) -> Bool {
        guard tabs.indices.contains(from) else { return false }
        let dest = max(0, min(tabs.count - 1, to))
        guard dest != from else { return false }
        let t = tabs.remove(at: from)
        tabs.insert(t, at: dest)
        return true
    }

    /// 超过 maxLoaded 个已加载标签时该卸载哪些（不含当前标签，最久没用的先）
    func toUnload(maxLoaded: Int, isLoaded: (MioTab) -> Bool) -> [Int] {
        let loaded = tabs.filter(isLoaded)
        let extra = loaded.count - max(1, maxLoaded)
        guard extra > 0 else { return [] }
        return Array(loaded.filter { $0.id != activeID }.sorted { $0.lastActive < $1.lastActive }.prefix(extra).map(\.id))
    }

    // MARK: persistence（与 Windows browser-tabs.json 同格式）

    func serialize() -> Data {
        let keep = tabs.filter { MioTabStore.isHTTP($0.url) }
        let active = keep.firstIndex { $0.id == activeID } ?? 0
        let items: [[String: Any]] = keep.map { t in
            var o: [String: Any] = ["url": t.url, "title": t.title]
            if t.containerID != MioTabStore.defaultContainer { o["container"] = t.containerID }
            if t.locked { o["locked"] = true }
            return o
        }
        return (try? JSONSerialization.data(withJSONObject: ["v": 2, "active": active, "tabs": items], options: [.sortedKeys])) ?? Data()
    }

    /// 恢复（替换现有标签）；knownContainers 给出时，不认识的容器回到默认容器。返回恢复数
    @discardableResult
    func restore(_ data: Data?, knownContainers: [String]? = nil) -> Int {
        guard let data = data, let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let raw = obj["tabs"] as? [Any] else { return 0 }
        let items = raw.compactMap { $0 as? [String: Any] }.filter { MioTabStore.isHTTP($0["url"] as? String ?? "") }.prefix(maxTabs)
        guard !items.isEmpty else { return 0 }
        tabs = []
        activeID = nil
        for x in items {
            var c = MioTabStore.cleanContainer(x["container"] as? String)
            var locked = (x["locked"] as? Bool) ?? false
            if let known = knownContainers, c != MioTabStore.defaultContainer, !known.contains(c) {
                c = MioTabStore.defaultContainer // 容器已删除：回到默认容器，不再锁定
                locked = false
            }
            add(x["url"] as? String ?? "", title: x["title"] as? String, activate: false, index: tabs.count,
                containerID: c, locked: locked, openerID: .some(nil))
        }
        let a = (obj["active"] as? Int).map { max(0, min(items.count - 1, $0)) } ?? 0
        select(index: a)
        return items.count
    }
}
