// MioContentBlocker.swift — WKContentRuleList 的编译 / 缓存 / 查找（WebKit 端）。规则列表管理在 MioFilterManager（Foundation）。
//
//   let blocker = MioContentBlocker(manager: kit.filters)
//   kit.adblock.recompile = { await blocker.reload() }
//   Task { await blocker.prepare() }          // 启动：先查已编译的（秒开），需要时再编译；每天检查一次订阅
//   每个 WebView：MioWebViewModules(…, blocker: blocker)，导航时自动按白名单挂 / 卸
// 编译结果存在 WKContentRuleListStore（默认 store，或传入自定义目录），标识 mio.kit.<list>.<part>，内容没变就不重编。

#if canImport(WebKit)
import Foundation
import WebKit

public extension Notification.Name {
    /// 规则表变了（编译完成 / 列表开关）：宿主让每个 WebView 调 applyContentRules
    static let mioContentRulesDidChange = Notification.Name("mio.kit.contentRulesDidChange")
}

/// WKContentRuleListStore → MioRuleListCompiling（主线程调用 WebKit）
@MainActor
public final class MioWKRuleListStore: MioRuleListCompiling {
    public let store: WKContentRuleListStore
    public init(store: WKContentRuleListStore = .default()) { self.store = store }
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
    public private(set) var isBusy = false

    public init(manager: MioFilterManager, store: MioWKRuleListStore? = nil) {
        self.manager = manager
        self.store = store ?? MioWKRuleListStore()
    }

    /// 启动：先查已编译的规则（不编译，立即可用），然后补编译；订阅超过一天没检查就后台更新
    public func prepare(checkUpdates: Bool = true) async {
        await load(manager.activeIdentifiers())
        await reload()
        if checkUpdates && manager.needsUpdateCheck {
            await manager.refresh()
            await reload()
        }
    }

    /// 重新编译（内容没变的列表跳过）并加载
    public func reload() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let ids = await manager.compile(into: store)
        await load(ids)
    }

    private func load(_ ids: [String]) async {
        var out: [String: WKContentRuleList] = [:]
        for id in ids {
            if let l = ruleLists[id] ?? (await store.lookUp(id)) { out[id] = l }
        }
        let changed = Set(out.keys) != Set(ruleLists.keys)
        ruleLists = out
        if changed { NotificationCenter.default.post(name: .mioContentRulesDidChange, object: self) }
    }
}
#endif
