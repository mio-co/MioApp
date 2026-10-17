// MioContainerDataStores.swift — 容器 → WKWebsiteDataStore（WebKit 端）。
// - 每个容器一个 WKWebsiteDataStore(forIdentifier: UUID)：Cookie / LocalStorage / IndexedDB / 缓存完全隔离（iOS 17 / macOS 14 起）
// - 默认容器 = v0.3.x 内置浏览器的固定 UUID（MioContainerIDs.defaultDataStoreID），升级不丢登录
// - 更旧的系统：只有默认容器，用 .default()（与 v0.3.x 一致）
// - 无痕：共用一个 nonPersistent()
// - 删除容器：宿主先关掉该容器的标签（.mioContainerWillRemove），再 await purge(id)；还被占用时重试，最终清空数据、下次启动再删

#if canImport(WebKit)
import Foundation
import WebKit

@MainActor
public final class MioContainerDataStores {
    public let manager: MioContainerManager
    private var stores: [String: WKWebsiteDataStore] = [:]
    private lazy var privateStore = WKWebsiteDataStore.nonPersistent()
    private var purgedPending = false

    public init(manager: MioContainerManager) { self.manager = manager }

    public static var isSupported: Bool {
        if #available(iOS 17.0, macOS 14.0, *) { return true }
        return false
    }

    public func dataStore(for containerID: String?) -> WKWebsiteDataStore {
        guard let uuid = manager.dataStoreUUID(for: containerID) else { return privateStore }
        let id = manager.resolve(containerID)
        if let s = stores[id] { return s }
        let s: WKWebsiteDataStore
        if #available(iOS 17.0, macOS 14.0, *) {
            s = WKWebsiteDataStore(forIdentifier: uuid)
        } else {
            s = .default()
        }
        stores[id] = s
        if !purgedPending { purgedPending = true; Task { await purgePending() } }
        return s
    }

    public func makeConfiguration(for containerID: String?) -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = dataStore(for: containerID)
        return c
    }

    /// 删除容器的数据存储。true = 已删除；false = 仍被占用（已清空数据，留到下次启动删）
    @discardableResult
    public func purge(_ id: String, attempts: Int = 4) async -> Bool {
        stores[id] = nil
        guard #available(iOS 17.0, macOS 14.0, *), let uuid = UUID(uuidString: id) else { manager.markRemoved(id); return true }
        for i in 0..<attempts {
            let err: Error? = await withCheckedContinuation { c in WKWebsiteDataStore.remove(forIdentifier: uuid) { c.resume(returning: $0) } }
            if err == nil { manager.markRemoved(id); return true }
            if i < attempts - 1 { try? await Task.sleep(nanoseconds: 1_500_000_000) }
        }
        let store = WKWebsiteDataStore(forIdentifier: uuid)
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        return false
    }

    /// 启动后第一次取数据存储时：删掉上次没删干净的
    public func purgePending() async {
        guard #available(iOS 17.0, macOS 14.0, *) else { return }
        for id in manager.pendingRemovals {
            guard let uuid = UUID(uuidString: id) else { manager.markRemoved(id); continue }
            let err: Error? = await withCheckedContinuation { c in WKWebsiteDataStore.remove(forIdentifier: uuid) { c.resume(returning: $0) } }
            if err == nil { manager.markRemoved(id) }
        }
    }
}
#endif
