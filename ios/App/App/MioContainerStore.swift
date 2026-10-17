// MioContainerStore.swift — 内置浏览器「容器」（登录状态隔离）：每个容器一个 WKWebsiteDataStore(forIdentifier: UUID)，
// Cookie / LocalStorage / IndexedDB / 缓存完全隔离；元数据、标签映射、锁定、站点规则持久化在 UserDefaults（mio.containers.state，JSON 见 MioContainerCore.swift）。
//
// 标签管理器接入（iOS / Mac Catalyst 共用）：
//   let store = MioContainerStore.shared
//   let config = store.makeConfiguration(for: containerId)        // 或 config.websiteDataStore = store.dataStore(for: containerId)
//   store.containerForNewTab(url:opener:requested:) / child(of:requested:)   // 锁定继承
//   store.setTab(tabKey, containerId:locked:) / tab(tabKey) / setTabLocked / removeTab / retainTabs   // restore 用
//   NotificationCenter: .mioContainerWillRemove（userInfo["containerId"], userInfo["tabKeys"]）→ 关闭这些标签（释放 WKWebView，数据才能删掉）
//                       .mioContainersDidChange → 刷新标签上的容器颜色 / 名称
// - 默认容器（"default"）= 原来内置浏览器的固定 UUID 数据（MioBrowserSettings.dataStoreID），不迁移、不丢登录
// - WKWebsiteDataStore(forIdentifier:) 需要 iOS 17 / macOS 14：更旧的系统 isSupported == false，只有默认容器（.default() 数据，与以前一致）
// - 删除容器：先发 .mioContainerWillRemove，下一轮 runloop 调 WKWebsiteDataStore.remove(forIdentifier:)；还被占用时重试，
//   最终失败则清空该 data store 的全部数据并留在 pendingRemovals，下次启动（没有 WebView 用它时）再删

import UIKit
import WebKit

extension Notification.Name {
    /// 容器列表 / 名称 / 颜色 / 站点规则变化
    static let mioContainersDidChange = Notification.Name("mio.containers.didChange")
    /// 容器即将被删除：userInfo["containerId"]: String，userInfo["tabKeys"]: [String]。收到后关闭该容器的所有标签
    static let mioContainerWillRemove = Notification.Name("mio.containers.willRemove")
}

final class MioContainerStore {
    static let shared = MioContainerStore()
    static let stateKey = "mio.containers.state"

    private let defaults: UserDefaults
    private(set) var state: MioContainerState
    private var stores: [String: WKWebsiteDataStore] = [:]
    private var purgedPending = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        state = MioContainerState(json: defaults.data(forKey: Self.stateKey))
    }

    /// 系统支持多个持久化数据存储（iOS 17 / macOS 14 起）
    static var isSupported: Bool {
        if #available(iOS 17.0, macCatalyst 17.0, *) { return true }
        return false
    }

    private func save() {
        defaults.set(state.jsonData(), forKey: Self.stateKey)
        NotificationCenter.default.post(name: .mioContainersDidChange, object: self)
    }

    // MARK: 查询

    /// 默认容器在前
    var containers: [MioContainer] { state.all }
    func container(_ id: String?) -> MioContainer? { state.get(id) }
    /// 未知 / 已删除 → "default"
    func resolve(_ id: String?) -> String { state.resolve(id) }

    static func color(_ name: String) -> UIColor {
        let v = MioContainerCore.colorHex[name] ?? MioContainerCore.colorHex[MioContainerCore.defaultColor]!
        return UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    static func dot(_ color: String, size: CGFloat = 14) -> UIImage {
        let ui = Self.color(color)
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { ctx in
            ui.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: size, height: size))
        }
    }

    // MARK: WebKit 数据

    /// 容器的数据存储（同一容器的所有标签共用一个实例）。旧系统 → .default()
    /// 无痕标签共用的不落盘数据存储（App 退出即清除）
    private lazy var privateStore = WKWebsiteDataStore.nonPersistent()

    func dataStore(for containerId: String?) -> WKWebsiteDataStore {
        if containerId == MioTabStore.privateContainer { return privateStore }
        purgePendingIfNeeded()
        let id = resolve(containerId)
        if let s = stores[id] { return s }
        let s: WKWebsiteDataStore
        if #available(iOS 17.0, macCatalyst 17.0, *) {
            if id == MioContainerCore.defaultId {
                s = WKWebsiteDataStore(forIdentifier: MioBrowserSettings.dataStoreID)
            } else if let uuid = UUID(uuidString: id) {
                s = WKWebsiteDataStore(forIdentifier: uuid)
            } else {
                s = WKWebsiteDataStore(forIdentifier: MioBrowserSettings.dataStoreID)
            }
        } else {
            s = .default()
        }
        stores[id] = s
        return s
    }

    /// 新标签 WebView 的配置：只设置 websiteDataStore，其余（UA、内容模式、脚本、拦截）由调用方照常设置
    func makeConfiguration(for containerId: String?) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore(for: containerId)
        return config
    }

    // MARK: 增删改

    @discardableResult
    func create(name: String, color: String? = nil) throws -> MioContainer {
        let c = try state.create(name: name, color: color)
        save()
        return c
    }

    @discardableResult
    func update(_ id: String, name: String? = nil, color: String? = nil) throws -> MioContainer {
        let c = try state.update(id, name: name, color: color)
        save()
        return c
    }

    /// 删除容器并清除其数据。completion(true) = 数据存储已删除；false = 仍被占用，已清空数据、下次启动再删
    func remove(_ id: String, completion: ((Bool) -> Void)? = nil) throws {
        let r = try state.remove(id)
        save()
        stores.removeValue(forKey: id)
        NotificationCenter.default.post(name: .mioContainerWillRemove, object: self, userInfo: ["containerId": id, "tabKeys": r.tabKeys])
        // 给标签管理器一轮 runloop 关闭 WebView
        DispatchQueue.main.async { self.purge(id, attempt: 0, completion: completion) }
    }

    private func purge(_ id: String, attempt: Int, completion: ((Bool) -> Void)?) {
        guard #available(iOS 17.0, macCatalyst 17.0, *), let uuid = UUID(uuidString: id) else {
            state.markRemoved(id)
            save()
            completion?(true)
            return
        }
        WKWebsiteDataStore.remove(forIdentifier: uuid) { [weak self] error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let error = error else {
                    self.state.markRemoved(id)
                    self.save()
                    completion?(true)
                    return
                }
                NSLog("⚡️ Mio containers: remove data store %@ failed (attempt %d): %@", id, attempt, error.localizedDescription)
                if attempt < 3 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.purge(id, attempt: attempt + 1, completion: completion) }
                    return
                }
                // 仍被占用：先把数据清空（不留登录状态），data store 本身留到下次启动删除
                let store = WKWebsiteDataStore(forIdentifier: uuid)
                store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
                    completion?(false)
                }
            }
        }
    }

    /// 启动后第一次取数据存储时：删掉上次没删干净的容器数据（此时没有 WebView 在用它们）
    private func purgePendingIfNeeded() {
        guard !purgedPending else { return }
        purgedPending = true
        guard #available(iOS 17.0, macCatalyst 17.0, *) else { return }
        for id in state.pendingRemovals {
            guard let uuid = UUID(uuidString: id) else { state.markRemoved(id); continue }
            WKWebsiteDataStore.remove(forIdentifier: uuid) { [weak self] error in
                DispatchQueue.main.async {
                    guard let self = self, error == nil else { return }
                    self.state.markRemoved(id)
                    self.save()
                }
            }
        }
    }

    // MARK: 标签 → 容器（restore 用）

    @discardableResult
    func setTab(_ key: String, containerId: String?, locked: Bool) -> MioTabContainer {
        let t = (try? state.setTab(key, containerId: containerId, locked: locked)) ?? .unassigned
        defaults.set(state.jsonData(), forKey: Self.stateKey) // 映射变化频繁，不发通知
        return t
    }

    func tab(_ key: String) -> MioTabContainer { state.tab(key) }

    @discardableResult
    func setTabLocked(_ key: String, _ locked: Bool) -> MioTabContainer {
        let t = state.tab(key)
        return setTab(key, containerId: t.containerId, locked: locked)
    }

    func removeTab(_ key: String) {
        state.removeTab(key)
        defaults.set(state.jsonData(), forKey: Self.stateKey)
    }

    /// 恢复标签后只保留仍存在的标签记录
    func retainTabs(_ keys: [String]) {
        state.retainTabs(keys)
        defaults.set(state.jsonData(), forKey: Self.stateKey)
    }

    func tabs(in containerId: String) -> [String] { state.tabs(in: containerId) }

    /// 锁定继承：子标签 / 弹窗
    func child(of parent: MioTabContainer?, requested: String? = nil) -> MioTabContainer { state.child(of: parent, requested: requested) }

    /// 新标签：锁定的打开者 > 显式指定 > 站点默认容器 > 未锁定的打开者 > 默认容器
    func containerForNewTab(url: URL?, opener: MioTabContainer?, requested: String? = nil) -> MioTabContainer {
        state.containerForNewTab(url: url, opener: opener, requested: requested)
    }

    // MARK: 站点默认容器

    @discardableResult
    func setSiteRule(_ host: String, containerId: String) throws -> String {
        let h = try state.setSiteRule(host, containerId: containerId)
        save()
        return h
    }

    func removeSiteRule(_ host: String) {
        state.removeSiteRule(host)
        save()
    }

    func containerFor(url: URL?) -> String? { state.containerFor(url: url) }
}

// MARK: - 设置页「容器管理」

final class MioContainersViewController: UITableViewController {
    private enum Row {
        case container(MioContainer), add, rule(MioSiteRule), addRule
    }

    private var sections: [(title: String?, footer: String?, rows: [Row])] = []
    private var observer: NSObjectProtocol?
    private let store = MioContainerStore.shared

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let o = observer { NotificationCenter.default.removeObserver(o) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "容器"
        MioContainerUX.installTip()
        observer = NotificationCenter.default.addObserver(forName: .mioContainersDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.rebuild()
        }
        rebuild()
    }

    private func rebuild() {
        var s: [(String?, String?, [Row])] = []
        var list: [Row] = store.containers.map { .container($0) }
        if MioContainerStore.isSupported && store.state.canCreate { list.append(.add) }
        let footer: String
        if MioContainerStore.isSupported {
            footer = "每个容器有独立的 Cookie、LocalStorage、IndexedDB 和缓存，同一网站可以在不同容器里登录不同账号。「默认」就是原来的浏览数据。点容器可改名、换颜色或删除；删除会关闭它的标签并清除其中全部数据。最多 \(MioContainerCore.maxContainers) 个。"
        } else {
            footer = "容器需要 iOS 17 / macOS 14 或更新的系统（WebKit 多数据存储）。当前系统只有默认容器。"
        }
        s.append(("容器（登录状态隔离）", footer, list))
        if MioContainerStore.isSupported && store.containers.count > 1 {
            var rules: [Row] = store.state.siteRules.map { .rule($0) }
            rules.append(.addRule)
            s.append(("站点默认容器", "从外部打开这些网站（含子域名）时自动使用指定容器；锁定的标签里打开的链接仍留在原容器。左滑删除。", rules))
        }
        sections = s.map { (title: $0.0, footer: $0.1, rows: $0.2) }
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].rows.count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { sections[section].title }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? { sections[section].footer }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.detailTextLabel?.textColor = .secondaryLabel
        switch sections[indexPath.section].rows[indexPath.row] {
        case .container(let c):
            cell.imageView?.image = MioContainerStore.dot(c.color)
            cell.textLabel?.text = c.name
            if c.isDefault {
                cell.detailTextLabel?.text = "原来的浏览数据，不能删除"
            } else {
                let n = store.tabs(in: c.id).count
                cell.detailTextLabel?.text = (MioContainerCore.colorNames[c.color] ?? c.color) + (n > 0 ? " · \(n) 个标签" : "")
                cell.accessoryType = .disclosureIndicator
            }
        case .add:
            cell.textLabel?.text = "新建容器…"
            cell.textLabel?.textColor = .systemBlue
        case .rule(let r):
            cell.textLabel?.text = r.host
            let c = store.container(r.containerId)
            cell.detailTextLabel?.text = "总是在「\(c?.name ?? "?")」容器打开"
            if let c = c { cell.imageView?.image = MioContainerStore.dot(c.color, size: 10) }
            cell.selectionStyle = .none
        case .addRule:
            cell.textLabel?.text = "添加站点规则…"
            cell.textLabel?.textColor = .systemBlue
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let cell = tableView.cellForRow(at: indexPath)
        switch sections[indexPath.section].rows[indexPath.row] {
        case .container(let c) where c.isDefault:
            let a = MioActionList(title: c.name)
            a.add("打开此容器（新标签页）") { [weak self] in
                guard let self = self else { return }
                MioContainerUX.openContainer(c.id, from: self)
            }
            a.present(from: self, sourceView: cell)
        case .container(let c) where !c.isDefault:
            let a = MioActionList(title: c.name)
            a.add("打开此容器（新标签页）") { [weak self] in
                guard let self = self else { return }
                MioContainerUX.openContainer(c.id, from: self)
            }
            a.add("重命名") { [weak self] in self?.askName(title: "重命名容器", initial: c.name) { _ = try self?.store.update(c.id, name: $0) } }
            a.add("更改颜色") { [weak self] in self?.pickColor(current: c.color, from: cell) { _ = try self?.store.update(c.id, color: $0) } }
            a.add("删除容器…", style: .destructive) { [weak self] in self?.confirmDelete(c) }
            a.present(from: self, sourceView: cell)
        case .add:
            askName(title: "新建容器", initial: "") { [weak self] name in
                guard let self = self else { return }
                let color = self.store.state.nextColor()
                _ = try self.store.create(name: name, color: color)
            }
        case .addRule:
            addRule(from: cell)
        default:
            break
        }
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        switch sections[indexPath.section].rows[indexPath.row] {
        case .rule: return true
        case .container(let c): return !c.isDefault
        default: return false
        }
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        switch sections[indexPath.section].rows[indexPath.row] {
        case .rule(let r): store.removeSiteRule(r.host)
        case .container(let c): confirmDelete(c)
        default: break
        }
    }

    private func showError(_ error: Error) {
        let a = UIAlertController(title: "操作失败", message: (error as? MioContainerError)?.description ?? error.localizedDescription, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "好", style: .default))
        present(a, animated: true)
    }

    private func askName(title: String, initial: String, apply: @escaping (String) throws -> Void) {
        let a = UIAlertController(title: title, message: "例如：工作、小号 2", preferredStyle: .alert)
        a.addTextField { $0.text = initial; $0.clearButtonMode = .whileEditing }
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        a.addAction(UIAlertAction(title: "好", style: .default) { [weak self] _ in
            do { try apply(a.textFields?.first?.text ?? "") } catch { self?.showError(error) }
        })
        present(a, animated: true)
    }

    private func pickColor(current: String, from view: UIView?, apply: @escaping (String) throws -> Void) {
        let a = MioActionList(title: "容器颜色")
        for col in MioContainerCore.colors {
            a.add(MioContainerCore.colorNames[col] ?? col, checked: col == current, image: MioContainerStore.dot(col).withRenderingMode(.alwaysOriginal)) { [weak self] in
                do { try apply(col) } catch { self?.showError(error) }
            }
        }
        a.present(from: self, sourceView: view)
    }

    private func confirmDelete(_ c: MioContainer) {
        let a = UIAlertController(title: "删除容器「\(c.name)」？", message: "会关闭它的标签，并清除其中的 Cookie、登录状态、网站存储和缓存，无法恢复。", preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in self?.rebuild() })
        a.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            do { try self?.store.remove(c.id) } catch { self?.showError(error) }
        })
        present(a, animated: true)
    }

    private func addRule(from view: UIView?) {
        let a = UIAlertController(title: "站点默认容器", message: "输入域名，例如 github.com（含子域名）", preferredStyle: .alert)
        a.addTextField {
            $0.keyboardType = .URL
            $0.autocapitalizationType = .none
            $0.autocorrectionType = .no
        }
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        a.addAction(UIAlertAction(title: "下一步", style: .default) { [weak self] _ in
            guard let self = self else { return }
            let text = a.textFields?.first?.text ?? ""
            guard MioContainerCore.normalizeHost(text) != nil else { self.showError(MioContainerError.badHost); return }
            let pick = MioActionList(title: "在哪个容器打开？", message: MioContainerCore.normalizeHost(text))
            for c in self.store.containers where !c.isDefault {
                pick.add(c.name, image: MioContainerStore.dot(c.color).withRenderingMode(.alwaysOriginal)) { [weak self] in
                    do { _ = try self?.store.setSiteRule(text, containerId: c.id) } catch { self?.showError(error) }
                }
            }
            pick.present(from: self, sourceView: view)
        })
        present(a, animated: true)
    }
}
