// MioFilterManager.swift — 广告 / 跟踪拦截的规则列表：内置精简列表 + 可订阅 EasyList / AdGuard + 自定义订阅地址，
// 下载（ETag / Last-Modified 条件请求）、本地缓存、按列表编译成 WKContentRuleList（超 15 万条拆分），编译结果按 SHA-256 缓存。
// 只依赖 Foundation：WebKit 编译通过 MioRuleListCompiling 协议注入（WebKit 实现见 WebKit/MioContentBlocker.swift，单测用假实现）。
//
// 每个列表单独编译（例外规则只在同一列表内生效，按官方列表边界拆，不混合）；标识 mio.kit.<listKey>.<part>。
// 设置 key：mio.adblock.enabled / mio.adblock.allowlist（v0.3.x）；mio.adblock.list.<id>（每个订阅的开关，默认与 v0.3.x 相同全开）；
//          mio.adblock.customLists（自定义订阅地址，https，EasyList / AdGuard 语法）

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct MioFilterList: Hashable, Codable, Identifiable {
    public enum Source: Hashable, Codable {
        /// 包内 Resources/filters/<name>.txt（离线可用，不更新）
        case bundled(String)
        case remote(URL)
    }
    public let key: String
    public let name: String
    public let source: Source
    /// 默认开关（用户没动过时）
    public let defaultEnabled: Bool
    public var id: String { key }
    public var enabledKey: String { "mio.adblock.list.\(key)" }
    public var isBundled: Bool { if case .bundled = source { return true }; return false }

    public init(key: String, name: String, source: Source, defaultEnabled: Bool = true) {
        self.key = key; self.name = name; self.source = source; self.defaultEnabled = defaultEnabled
    }
}

public enum MioFilterCatalog {
    public static let enabledKey = "mio.adblock.enabled"
    public static let allowlistKey = "mio.adblock.allowlist"
    public static let customListsKey = "mio.adblock.customLists"

    /// 内置：始终编译（不可关，离线就有基础拦截）
    public static let bundled: [MioFilterList] = [
        MioFilterList(key: "mio-basic", name: "Mio 精简（内置）", source: .bundled("mio-basic")),
        MioFilterList(key: "mio-youtube", name: "Mio YouTube 补充（内置）", source: .bundled("mio-youtube")),
    ]

    static func adtidy(_ id: Int) -> URL { URL(string: "https://filters.adtidy.org/ios/filters/\(id)_optimized.txt")! }

    /// 可订阅（与 v0.3.x 同样的列表 / 地址：AdGuard 为 Safari 优化过的版本）
    public static let subscriptions: [MioFilterList] = [
        MioFilterList(key: "2", name: "AdGuard Base", source: .remote(adtidy(2))),
        MioFilterList(key: "11", name: "AdGuard 移动广告", source: .remote(adtidy(11))),
        MioFilterList(key: "3", name: "AdGuard 跟踪保护", source: .remote(adtidy(3))),
        MioFilterList(key: "101", name: "EasyList", source: .remote(adtidy(101))),
        MioFilterList(key: "118", name: "EasyPrivacy", source: .remote(adtidy(118))),
        MioFilterList(key: "224", name: "AdGuard 中文", source: .remote(adtidy(224))),
    ]

    /// 自定义订阅地址 → 列表（key = custom-<sha8>）；只接受 https
    public static func customList(_ s: String) -> MioFilterList? {
        guard let u = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)), u.scheme?.lowercased() == "https", u.host?.isEmpty == false else { return nil }
        let key = "custom-" + String(MioHash.sha256Hex(Data(u.absoluteString.utf8)).prefix(8))
        return MioFilterList(key: key, name: u.host.map { "\($0)\(u.path)" } ?? u.absoluteString, source: .remote(u))
    }

    /// 当前启用的全部列表（内置 + 打开的订阅 + 自定义）
    public static func enabledLists(_ prefs: MioPrefs) -> [MioFilterList] {
        let subs = subscriptions.filter { prefs.bool($0.enabledKey, default: $0.defaultEnabled) }
        let custom = prefs.strings(customListsKey).compactMap(customList)
        var seen = Set<String>()
        return (bundled + subs + custom).filter { seen.insert($0.key).inserted }
    }

    // 白名单（与 v0.3.x MioAdblockSettings 同样的规范化：去 www.，匹配子域名）
    public static func normalizeHost(_ host: String) -> String {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let u = URL(string: h), let uh = u.host { h = uh }
        if h.hasPrefix("www.") { h = String(h.dropFirst(4)) }
        return h
    }

    public static func allowlistEntry(for host: String?, prefs: MioPrefs) -> String? {
        guard let host = host?.lowercased(), !host.isEmpty else { return nil }
        for e in prefs.strings(allowlistKey).map(normalizeHost) where !e.isEmpty && (host == e || host.hasSuffix("." + e)) { return e }
        return nil
    }
}

/// 一个列表的持久状态
public struct MioFilterListMeta: Codable, Equatable {
    public var etag: String?
    public var lastModified: String?
    public var version: String?
    public var fetchedAt: Date?
    public var checkedAt: Date?
    public var sha256: String?
    public var compiledSha: String?
    public var parts: Int = 0
    public var sourceRules: Int = 0
    public var contentRules: Int = 0
    public var unsupported: Int = 0
    public var error: String?
}

public struct MioFilterState: Codable, Equatable {
    public var lists: [String: MioFilterListMeta] = [:]
    public var lastCheck: Date?
    public var lastMessage: String?
}

/// WKContentRuleListStore 的抽象（WebKit 实现：MioWKRuleListStore）
public protocol MioRuleListCompiling: AnyObject {
    func availableIdentifiers() async -> Set<String>
    func compile(identifier: String, json: String) async throws
    func remove(identifier: String) async
}

/// HTTP（可替换，单测用）：返回 (状态码, 数据, 响应头)
public typealias MioHTTPFetch = (URLRequest) async throws -> (Int, Data, [String: String])

public final class MioFilterManager {
    public static let identifierPrefix = "mio.kit."
    public static let updateInterval: TimeInterval = 24 * 3600

    public let directory: URL
    public let prefs: MioPrefs
    public var converter: MioFilterConverting
    public var http: MioHTTPFetch
    public private(set) var state: MioFilterState
    private let lock = NSLock()

    public init(directory: URL, prefs: MioPrefs, converter: MioFilterConverting = MioFilterConverters.best(), http: MioHTTPFetch? = nil) {
        self.directory = directory
        self.prefs = prefs
        self.converter = converter
        self.http = http ?? { req in
            let (d, r) = try await URLSession.shared.data(for: req)
            let h = r as? HTTPURLResponse
            var headers: [String: String] = [:]
            for (k, v) in h?.allHeaderFields ?? [:] { if let k = k as? String { headers[k.lowercased()] = "\(v)" } }
            return (h?.statusCode ?? 0, d, headers)
        }
        try? FileManager.default.createDirectory(at: directory.appendingPathComponent("lists"), withIntermediateDirectories: true)
        state = (try? Data(contentsOf: directory.appendingPathComponent("state.json"))).flatMap { try? JSONDecoder.mioKit.decode(MioFilterState.self, from: $0) } ?? MioFilterState()
    }

    /// 默认位置：Application Support/MioKit/ContentBlocking
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("MioKit/ContentBlocking", isDirectory: true)
    }

    func saveState() {
        lock.lock(); let s = state; lock.unlock()
        if let d = try? JSONEncoder.mioKit.encode(s) { try? d.write(to: directory.appendingPathComponent("state.json"), options: .atomic) }
    }

    func mutate(_ f: (inout MioFilterState) -> Void) { lock.lock(); f(&state); lock.unlock() }

    func fileURL(_ list: MioFilterList) -> URL { directory.appendingPathComponent("lists/\(list.key).txt") }

    public static func identifier(_ list: MioFilterList, part: Int) -> String { "\(identifierPrefix)\(list.key).\(part)" }

    /// 列表文本：内置读包内资源；订阅读已下载的文件（还没下载 → nil）
    public func text(of list: MioFilterList) -> String? {
        switch list.source {
        case .bundled(let name): return MioKitResources.filter(name)
        case .remote: return try? String(contentsOf: fileURL(list), encoding: .utf8)
        }
    }

    public var needsUpdateCheck: Bool {
        guard let last = state.lastCheck else { return true }
        return Date().timeIntervalSince(last) > Self.updateInterval
    }

    // MARK: 下载

    /// 检查订阅更新（条件请求）。返回给用户看的一句话
    @discardableResult
    public func refresh(force: Bool = false) async -> String {
        var changed = 0
        var failed: [String] = []
        for list in MioFilterCatalog.enabledLists(prefs) {
            guard case .remote(let url) = list.source else { continue }
            var meta = state.lists[list.key] ?? MioFilterListMeta()
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
            let haveFile = FileManager.default.fileExists(atPath: fileURL(list).path)
            if !force && haveFile {
                if let e = meta.etag { req.setValue(e, forHTTPHeaderField: "If-None-Match") }
                if let lm = meta.lastModified { req.setValue(lm, forHTTPHeaderField: "If-Modified-Since") }
            }
            do {
                let (code, data, headers) = try await http(req)
                meta.checkedAt = Date()
                if code == 304 && haveFile {
                    meta.error = nil
                } else if code == 200, Self.looksLikeFilter(data) {
                    let sha = MioHash.sha256Hex(data)
                    if sha != meta.sha256 || !haveFile {
                        try data.write(to: fileURL(list), options: .atomic)
                        meta.sha256 = sha
                        meta.fetchedAt = Date()
                        meta.version = Self.header(of: data)
                        changed += 1
                    }
                    meta.etag = headers["etag"]
                    meta.lastModified = headers["last-modified"]
                    meta.error = nil
                } else {
                    meta.error = code == 200 ? "不是规则列表" : "HTTP \(code)"
                    failed.append(list.name)
                }
            } catch {
                meta.error = (error as NSError).localizedDescription
                failed.append(list.name)
            }
            let m = meta
            mutate { $0.lists[list.key] = m }
        }
        let msg = failed.isEmpty ? (changed > 0 ? "\(changed) 个列表有更新" : "规则已是最新") : "部分失败：\(failed.joined(separator: "、"))"
        mutate { $0.lastCheck = Date(); $0.lastMessage = msg }
        saveState()
        return msg
    }

    // MARK: 编译

    /// 把启用的列表编译进 store（内容没变、编译结果还在就跳过）；删掉不再需要的旧规则表。返回当前生效的标识（按列表顺序）
    @discardableResult
    public func compile(into store: MioRuleListCompiling) async -> [String] {
        let available = await store.availableIdentifiers()
        var active: [String] = []
        for list in MioFilterCatalog.enabledLists(prefs) {
            guard let text = text(of: list) else { continue }
            let sha = MioHash.sha256Hex(Data(text.utf8))
            var meta = state.lists[list.key] ?? MioFilterListMeta()
            let ids = (0..<max(meta.parts, 1)).map { Self.identifier(list, part: $0) }
            if meta.compiledSha == sha, meta.parts > 0, ids.allSatisfy(available.contains) {
                active += ids
                continue
            }
            let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init)
            let parts = MioRuleSplitter.convert(lines, converter: converter)
            var err: String?
            var newIDs: [String] = []
            for (i, p) in parts.enumerated() {
                let id = Self.identifier(list, part: i)
                do { try await store.compile(identifier: id, json: p.json); newIDs.append(id) } catch { err = "\(id): \(error.localizedDescription)" }
            }
            for i in parts.count..<max(meta.parts, parts.count) { await store.remove(identifier: Self.identifier(list, part: i)) }
            meta.sha256 = meta.sha256 ?? sha
            meta.compiledSha = err == nil ? sha : nil
            meta.parts = parts.count
            meta.sourceRules = parts.first?.sourceRules ?? 0
            meta.contentRules = parts.reduce(0) { $0 + $1.ruleCount }
            meta.unsupported = parts.reduce(0) { $0 + $1.unsupported }
            meta.error = err
            let m = meta
            mutate { $0.lists[list.key] = m }
            active += newIDs
        }
        // 关掉的列表 / 旧分片：删
        for id in available where id.hasPrefix(Self.identifierPrefix) && !active.contains(id) { await store.remove(identifier: id) }
        saveState()
        return active
    }

    /// 已编译、当前应挂载的标识（不触发编译；启动时先用它 lookUp，后台再 compile）
    public func activeIdentifiers() -> [String] {
        MioFilterCatalog.enabledLists(prefs).flatMap { list -> [String] in
            guard let m = state.lists[list.key], m.compiledSha != nil, m.parts > 0 else { return [] }
            return (0..<m.parts).map { Self.identifier(list, part: $0) }
        }
    }

    public func statusText() -> String {
        let lists = MioFilterCatalog.enabledLists(prefs)
        let rules = lists.compactMap { state.lists[$0.key]?.contentRules }.reduce(0, +)
        var s = "\(lists.count) 个列表，\(rules) 条内容规则"
        if let m = state.lastMessage { s += "；" + m }
        return s
    }

    // MARK: 工具

    static func looksLikeFilter(_ data: Data) -> Bool {
        guard data.count > 16 else { return false }
        let head = String(decoding: data.prefix(2048), as: UTF8.self).lowercased()
        if head.contains("<html") || head.contains("<!doctype") { return false }
        return head.contains("!") || head.contains("##") || head.contains("||")
    }

    static func header(of data: Data) -> String? {
        let head = String(decoding: data.prefix(4096), as: UTF8.self)
        for line in head.split(separator: "\n").prefix(40) where line.hasPrefix("! Version:") {
            return line.dropFirst("! Version:".count).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}

extension JSONDecoder {
    static var mioKit: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}

extension JSONEncoder {
    static var mioKit: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }
}
