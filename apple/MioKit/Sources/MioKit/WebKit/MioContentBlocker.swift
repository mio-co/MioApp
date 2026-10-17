// MioContentBlocker.swift — WKContentRuleList 的编译 / 缓存 / 查找（WebKit 端）。规则列表管理在 MioFilterManager（Foundation）。
//
//   let blocker = MioContentBlocker(manager: kit.filters)
//   kit.adblock.recompile = { await blocker.reload() }
//   Task { await blocker.prepare() }          // 启动：先查已编译的（秒开），需要时再编译；缺订阅立即下载，之后 24 小时检查一次（失败退避重试）
//   回到前台：blocker.appDidBecomeActive()
//   每个 WebView：MioWebViewModules(…, blocker: blocker)，导航时自动按白名单挂 / 卸
// 编译结果存在 WKContentRuleListStore（默认 store，或传入自定义目录），标识 mio.kit.<list>.<part>，内容没变就不重编。

#if canImport(WebKit)
import Foundation
import WebKit

public extension Notification.Name {
    /// 规则表变了（编译完成 / 列表开关）：宿主让每个 WebView 调 applyContentRules
    static let mioContentRulesDidChange = Notification.Name("mio.kit.contentRulesDidChange")
    /// 下载 / 编译结束（状态文字变了）：设置页可以刷新「已加载 N 条」
    static let mioContentRulesStatusDidChange = Notification.Name("mio.kit.contentRulesStatusDidChange")
}

/// WKContentRuleListStore → MioRuleListCompiling（主线程调用 WebKit）
@MainActor
public final class MioWKRuleListStore: MioRuleListCompiling {
    public let store: WKContentRuleListStore
    public init(store: WKContentRuleListStore? = nil) { self.store = store ?? .default() }
    /// 自定义目录（单测 / 与 v0.3.x 的规则分开）
    public convenience init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.init(store: WKContentRuleListStore(url: directory))
    }

    public func availableIdentifiers() async -> Set<String> {
        await withCheckedContinuation { c in store.getAvailableContentRuleListIdentifiers { ids in c.resume(returning: Set(ids ?? [])) } }
    }

    public func compile(identifier: String, json: String) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { _, err in
                if let e = err { c.resume(throwing: e) } else { c.resume() }
            }
        }
    }

    public func remove(identifier: String) async {
        await withCheckedContinuation { c in store.removeContentRuleList(forIdentifier: identifier) { _ in c.resume() } }
    }

    public func lookUp(_ identifier: String) async -> WKContentRuleList? {
        await withCheckedContinuation { c in store.lookUpContentRuleList(forIdentifier: identifier) { l, _ in c.resume(returning: l) } }
    }
}

@MainActor
public final class MioContentBlocker {
    public let manager: MioFilterManager
    public let store: MioWKRuleListStore
    /// 标识 → 已编译的规则表（按 manager.activeIdentifiers 顺序挂）
    public private(set) var ruleLists: [String: WKContentRuleList] = [:]
    /// 正在下载 / 编译（串行：同一时间只有一个任务，后来的请求合并到下一轮，不会像 v0.4.0 那样直接丢掉）
    public private(set) var isBusy = false
    /// 运行中多久看一次要不要检查订阅（真正检查的节奏由 manager.nextCheckDate 决定：24 小时 / 失败退避）
    public var autoUpdatePollInterval: TimeInterval = 30 * 60
    private var pendingReload = false
    private var pendingRefresh: (force: Bool, onlyMissing: Bool)?
    private var autoUpdateTask: Task<Void, Never>?
    private var settingsObserver: NSObjectProtocol?
    private var settingsDebounce: Task<Void, Never>?
    private var activeObservers: [NSObjectProtocol] = []

    public init(manager: MioFilterManager, store: MioWKRuleListStore? = nil) {
        self.manager = manager
        self.store = store ?? MioWKRuleListStore()
        manager.refreshHandler = { [weak self] force in (await self?.refreshAndReload(force: force)) ?? "" }
    }

    /// 启动：先查已编译的规则（不编译，立即可用），然后补编译；订阅缺了 / 到期 / 上次失败到了重试时间 → 下载并重编。
    /// checkUpdates = false 只用于单测（不联网）。之后运行中自动按间隔检查（startAutoUpdate），设置里打开订阅立即下载（observeSettings）
    public func prepare(checkUpdates: Bool = true) async {
        await load(manager.activeIdentifiers())
        await reload()
        if checkUpdates {
            observeSettings()
            await updateIfNeeded()
            startAutoUpdate()
        }
    }

    /// 到时间就检查订阅（启动、回到前台、定时器、设置变化时调用）。下载完重编
    public func updateIfNeeded() async {
        guard manager.needsUpdateCheck else { return }
        await refreshAndReload(force: false)
    }

    /// 「立即更新」：强制重新下载全部订阅（不带条件请求）并重编。返回给用户看的一句话
    @discardableResult
    public func refreshAndReload(force: Bool, onlyMissing: Bool = false) async -> String {
        if isBusy {
            // 合并：当前任务结束后再跑一轮（force 取或）
            let f = (pendingRefresh?.force ?? false) || force
            let m = (pendingRefresh?.onlyMissing ?? true) && onlyMissing
            pendingRefresh = (f, m)
            while isBusy { try? await Task.sleep(nanoseconds: 100_000_000) }
            return manager.state.lastMessage ?? ""
        }
        isBusy = true
        let msg = await manager.refresh(force: force, onlyMissing: onlyMissing)
        await compileAndLoad()
        await drainPending()
        isBusy = false
        NotificationCenter.default.post(name: .mioContentRulesStatusDidChange, object: self)
        return msg
    }

    /// 重新编译（内容没变的列表跳过）并加载；忙的时候合并到当前任务之后
    public func reload() async {
        if isBusy {
            pendingReload = true
            while isBusy { try? await Task.sleep(nanoseconds: 100_000_000) }
            return
        }
        isBusy = true
        await compileAndLoad()
        await drainPending()
        isBusy = false
        NotificationCenter.default.post(name: .mioContentRulesStatusDidChange, object: self)
    }

    private func compileAndLoad() async {
        let ids = await manager.compile(into: store) { [weak self] ids in await self?.load(ids) }
        await load(ids)
    }

    private func drainPending() async {
        while pendingReload || pendingRefresh != nil {
            if let r = pendingRefresh {
                pendingRefresh = nil
                pendingReload = false
                _ = await manager.refresh(force: r.force, onlyMissing: r.onlyMissing)
                await compileAndLoad()
            } else {
                pendingReload = false
                await compileAndLoad()
            }
        }
    }

    /// 运行中定时看一次（Mac 常开不重启；iOS 在前台时），App 回到前台也看一次。重复调用无副作用
    public func startAutoUpdate() {
        guard autoUpdateTask == nil else { return }
        // 回到前台：UIApplication / NSApplication 的 didBecomeActive（只用通知名，MioKit 不依赖 UIKit / AppKit）
        for name in ["UIApplicationDidBecomeActiveNotification", "NSApplicationDidBecomeActiveNotification"] {
            activeObservers.append(NotificationCenter.default.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appDidBecomeActive() }
            })
        }
        let interval = autoUpdatePollInterval
        autoUpdateTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(max(interval, 1) * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                await self.updateIfNeeded()
            }
        }
    }

    public func stopAutoUpdate() {
        autoUpdateTask?.cancel(); autoUpdateTask = nil
        for o in activeObservers { NotificationCenter.default.removeObserver(o) }
        activeObservers = []
    }

    /// App 回到前台（iOS：UIApplication.didBecomeActive；Mac：NSApplication.didBecomeActive）
    public func appDidBecomeActive() {
        Task { await self.updateIfNeeded() }
    }

    /// 设置变化：打开订阅 / 加自定义订阅 / 打开拦截总开关 → 立即下载缺的并编译；关掉订阅 → 重编（删掉它的规则表）
    private func observeSettings() {
        guard settingsObserver == nil else { return }
        settingsObserver = NotificationCenter.default.addObserver(forName: .mioSettingsDidChange, object: nil, queue: .main) { [weak self] n in
            guard let key = n.userInfo?["key"] as? String, key.hasPrefix("mio.adblock."), key != MioFilterCatalog.allowlistKey else { return }
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
    }

    private func settingsChanged() {
        settingsDebounce?.cancel()
        settingsDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !Task.isCancelled else { return }
            if !self.manager.missingLists().isEmpty {
                await self.refreshAndReload(force: false, onlyMissing: true)
            } else {
                await self.reload()
            }
        }
    }

    /// 页面（frame）要注入的高级规则 JS；nil = 没有
    public func pageScript(for url: URL, topURL: URL?) -> String? {
        manager.pageScript(for: url, topURL: topURL)
    }

    /// 已挂载的规则总数（内容规则，不含高级规则）
    public var loadedContentRuleCount: Int { manager.summary().contentRules }

    /// 标识 → 加载时该列表的编译时间（列表重编过、标识没变时换成新编译的对象）
    private var loadedVersion: [String: Date] = [:]

    private func load(_ ids: [String]) async {
        var out: [String: WKContentRuleList] = [:]
        var versions: [String: Date] = [:]
        for id in ids {
            let v = compiledAt(of: id)
            if let cached = ruleLists[id], loadedVersion[id] == v { out[id] = cached } else if let l = await store.lookUp(id) { out[id] = l }
            versions[id] = v
        }
        let changed = Set(out.keys) != Set(ruleLists.keys) || out.contains { ruleLists[$0.key] !== $0.value }
        ruleLists = out
        loadedVersion = versions
        if changed { NotificationCenter.default.post(name: .mioContentRulesDidChange, object: self) }
    }

    /// mio.kit.<listKey>.<part> → 该列表的编译时间
    private func compiledAt(of id: String) -> Date? {
        guard id.hasPrefix(MioFilterManager.identifierPrefix), let dot = id.lastIndex(of: ".") else { return nil }
        let key = String(id[id.index(id.startIndex, offsetBy: MioFilterManager.identifierPrefix.count)..<dot])
        return manager.state.lists[key]?.compiledAt
    }
}
#endif
