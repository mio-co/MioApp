// MioFilterManager.swift — 广告 / 跟踪拦截的规则列表：内置精简列表 + 可订阅 EasyList / AdGuard + 自定义订阅地址，
// 下载（ETag / Last-Modified 条件请求，失败重试 + 退避）、本地缓存、按列表编译成 WKContentRuleList（超 15 万条拆分），
// 编译结果按（内容 SHA-256 + 编译格式版本）缓存；内容规则表达不了的 scriptlet / 扩展 CSS 交给高级规则引擎（MioAdvancedRules）。
//
// 更新节奏：首次（订阅还没下载）/ 打开一个订阅 → 立即下载；之后每 24 小时检查一次（条件请求，没变就 304）；
// 失败按 1 分钟 → 5 分钟 → 15 分钟 → 1 小时退避重试（不再像 v0.4.0 那样失败也记成「已检查」、一天内不再试）。
// 何时检查由 MioContentBlocker 决定（启动、回到前台、运行中每 30 分钟看一次 needsUpdateCheck、设置变化）。
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
        // EasyList China 已包含在 AdGuard 中文里（列表头注明），默认不开，避免重复规则
        MioFilterList(key: "104", name: "EasyList China", source: .remote(adtidy(104)), defaultEnabled: false),
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
    /// 编译这份缓存时的编译格式（MioFilterManager.compileFormat）；不一致就重编（v0.4.0 的缓存是 0 条的空表，必须作废）
    public var compileFormat: Int?
    public var compiledAt: Date?
    public var parts: Int = 0
    /// 源规则条数（不含注释 / 空行）
    public var sourceRules: Int = 0
    /// WKContentRuleList 规则条数（网络拦截 + ## 元素隐藏 css-display-none + 例外）
    public var contentRules: Int = 0
    /// 交给高级规则引擎的条数（scriptlet / 扩展 CSS / JS）
    public var advancedRules: Int = 0
    /// 跳过的条数（两边都表达不了 + 超上限丢掉的）
    public var unsupported: Int = 0
    public var error: String?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case etag, lastModified, version, fetchedAt, checkedAt, sha256, compiledSha, compileFormat, compiledAt, parts, sourceRules, contentRules, advancedRules, unsupported, error
    }
    // v0.4.0 的 state.json 没有新字段：缺的按默认值读
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        etag = try c.decodeIfPresent(String.self, forKey: .etag)
        lastModified = try c.decodeIfPresent(String.self, forKey: .lastModified)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        fetchedAt = try c.decodeIfPresent(Date.self, forKey: .fetchedAt)
        checkedAt = try c.decodeIfPresent(Date.self, forKey: .checkedAt)
        sha256 = try c.decodeIfPresent(String.self, forKey: .sha256)
        compiledSha = try c.decodeIfPresent(String.self, forKey: .compiledSha)
        compileFormat = try c.decodeIfPresent(Int.self, forKey: .compileFormat)
        compiledAt = try c.decodeIfPresent(Date.self, forKey: .compiledAt)
        parts = try c.decodeIfPresent(Int.self, forKey: .parts) ?? 0
        sourceRules = try c.decodeIfPresent(Int.self, forKey: .sourceRules) ?? 0
        contentRules = try c.decodeIfPresent(Int.self, forKey: .contentRules) ?? 0
        advancedRules = try c.decodeIfPresent(Int.self, forKey: .advancedRules) ?? 0
        unsupported = try c.decodeIfPresent(Int.self, forKey: .unsupported) ?? 0
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }
}

public struct MioFilterState: Codable, Equatable {
    public var lists: [String: MioFilterListMeta] = [:]
    /// 最近一次检查（成功或失败）
    public var lastCheck: Date?
    /// 最近一次全部订阅都检查成功（200 / 304）
    public var lastSuccess: Date?
    /// 连续失败的检查轮数（退避用）
    public var consecutiveFailures: Int = 0
    public var lastMessage: String?
    /// 当前高级规则引擎对应的规则 SHA-256 / 构建错误
    public var engineSha: String?
    public var engineError: String?

    public init() {}

    enum CodingKeys: String, CodingKey { case lists, lastCheck, lastSuccess, consecutiveFailures, lastMessage, engineSha, engineError }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        lists = try c.decodeIfPresent([String: MioFilterListMeta].self, forKey: .lists) ?? [:]
        lastCheck = try c.decodeIfPresent(Date.self, forKey: .lastCheck)
        lastSuccess = try c.decodeIfPresent(Date.self, forKey: .lastSuccess)
        consecutiveFailures = try c.decodeIfPresent(Int.self, forKey: .consecutiveFailures) ?? 0
        lastMessage = try c.decodeIfPresent(String.self, forKey: .lastMessage)
        engineSha = try c.decodeIfPresent(String.self, forKey: .engineSha)
        engineError = try c.decodeIfPresent(String.self, forKey: .engineError)
    }
}

/// 设置页 / 冒烟测试看的汇总
public struct MioFilterSummary: Equatable {
    public var lists: Int
    /// 已下载 / 内置、并且编译好的列表数
    public var compiledLists: Int
    public var contentRules: Int
    public var advancedRules: Int
    public var skipped: Int
    public var lastSuccess: Date?
    /// 出错的列表：名字 → 错误
    public var errors: [String: String]
    /// 还没下载到的订阅
    public var missing: [String]
    public var loaded: Int { contentRules + advancedRules }
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
    /// 编译格式版本：转换逻辑变了就加一，旧缓存自动重编。1 = v0.4.0（CRLF 拆行 bug，订阅全是 0 条）；2 = 修复 + 高级规则
    public static let compileFormat = 2
    /// 连续失败 n 轮后，下次检查至少等多久
    public static func retryBackoff(_ failures: Int) -> TimeInterval {
        switch failures {
        case ..<1: return 0
        case 1: return 60
        case 2: return 5 * 60
        case 3: return 15 * 60
        default: return 3600
        }
    }

    public let directory: URL
    public let prefs: MioPrefs
    public var converter: MioFilterConverting
    public var http: MioHTTPFetch
    /// 单个列表下载失败（网络错误 / 5xx / 429）后的重试间隔（纳秒）；单测设成 [0, 0]
    public var retryDelays: [UInt64] = [2_000_000_000, 6_000_000_000]
    /// 高级规则引擎（Apple：FilterEngine；Linux / 单测可为 nil 或假实现）
    public var advanced: MioAdvancedEngine?
    public private(set) var state: MioFilterState
    /// 正在做什么（设置页显示「正在下载…」）；nil = 空闲
    public private(set) var activity: String?
    /// 宿主的串行更新入口（MioContentBlocker 设置：下载 + 重编 + 挂载，和启动 / 定时更新排队，不并发）。设置页「立即更新」走这里
    public var refreshHandler: (@MainActor (_ force: Bool) async -> String)?
    private let lock = NSLock()
    private var engineLoadTried = false

    public init(directory: URL, prefs: MioPrefs, converter: MioFilterConverting = MioFilterConverters.best(), http: MioHTTPFetch? = nil,
                advanced: MioAdvancedEngine?? = nil) {
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
        self.advanced = advanced ?? MioAdvancedEngines.make(directory: directory.appendingPathComponent("engine", isDirectory: true))
        try? FileManager.default.createDirectory(at: directory.appendingPathComponent("lists"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: directory.appendingPathComponent("adv"), withIntermediateDirectories: true)
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
    func setActivity(_ a: String?) { lock.lock(); activity = a; lock.unlock() }

    func fileURL(_ list: MioFilterList) -> URL { directory.appendingPathComponent("lists/\(list.key).txt") }
    func advancedURL(_ list: MioFilterList) -> URL { directory.appendingPathComponent("adv/\(list.key).txt") }

    public static func identifier(_ list: MioFilterList, part: Int) -> String { "\(identifierPrefix)\(list.key).\(part)" }

    /// 列表文本：内置读包内资源；订阅读已下载的文件（还没下载 → nil）
    public func text(of list: MioFilterList) -> String? {
        switch list.source {
        case .bundled(let name): return MioKitResources.filter(name)
        case .remote: return try? String(contentsOf: fileURL(list), encoding: .utf8)
        }
    }

    /// 打开了、但还没下载到的订阅（首次启动 / 刚打开开关 / 上次下载失败）
    public func missingLists() -> [MioFilterList] {
        MioFilterCatalog.enabledLists(prefs).filter { !$0.isBundled && !FileManager.default.fileExists(atPath: fileURL($0).path) }
    }

    /// 下次该检查订阅的时间：缺订阅且没失败过 → 现在；失败过 → 按退避；都下载过 → 上次成功 + 24 小时
    public func nextCheckDate() -> Date {
        lock.lock(); let s = state; lock.unlock()
        let earliest = (s.lastCheck ?? .distantPast).addingTimeInterval(Self.retryBackoff(s.consecutiveFailures))
        let hasRemote = MioFilterCatalog.enabledLists(prefs).contains { !$0.isBundled }
        guard hasRemote else { return .distantFuture }
        if !missingLists().isEmpty || s.lastSuccess == nil { return earliest }
        return max(s.lastSuccess!.addingTimeInterval(Self.updateInterval), earliest)
    }

    public var needsUpdateCheck: Bool { Date() >= nextCheckDate() }

    // MARK: 下载

    /// 检查订阅更新（条件请求，每个列表失败会重试）。onlyMissing = 只下载还没有的（刚打开某个订阅）。返回给用户看的一句话
    @discardableResult
    public func refresh(force: Bool = false, onlyMissing: Bool = false) async -> String {
        var changed = 0
        var failed: [String] = []
        let lists = MioFilterCatalog.enabledLists(prefs).filter { !$0.isBundled }
        let targets = onlyMissing ? lists.filter { !FileManager.default.fileExists(atPath: fileURL($0).path) } : lists
        guard !targets.isEmpty else { return state.lastMessage ?? "没有需要下载的订阅" }
        for (i, list) in targets.enumerated() {
            guard case .remote(let url) = list.source else { continue }
            setActivity("正在下载 \(list.name)（\(i + 1)/\(targets.count)）")
            var meta = state.lists[list.key] ?? MioFilterListMeta()
            let haveFile = FileManager.default.fileExists(atPath: fileURL(list).path)
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
            if !force && haveFile {
                if let e = meta.etag { req.setValue(e, forHTTPHeaderField: "If-None-Match") }
                if let lm = meta.lastModified { req.setValue(lm, forHTTPHeaderField: "If-Modified-Since") }
            }
            var attempt = 0
            while true {
                var retry = false
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
                        retry = code == 0 || code == 429 || code >= 500
                    }
                } catch {
                    meta.error = (error as NSError).localizedDescription
                    retry = true
                }
                if meta.error == nil || !retry || attempt >= retryDelays.count { break }
                let delay = retryDelays[attempt]
                attempt += 1
                if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            }
            if meta.error != nil { failed.append(list.name) }
            let m = meta
            mutate { $0.lists[list.key] = m }
            saveState()
        }
        setActivity(nil)
        let msg = failed.isEmpty ? (changed > 0 ? "\(changed) 个列表有更新" : "规则已是最新") : "部分失败：\(failed.joined(separator: "、"))（稍后自动重试）"
        let allOK = failed.isEmpty
        let wasFull = !onlyMissing || targets.count == lists.count
        mutate {
            $0.lastCheck = Date()
            $0.lastMessage = msg
            if allOK {
                $0.consecutiveFailures = 0
                if wasFull { $0.lastSuccess = Date() }
            } else {
                $0.consecutiveFailures += 1
            }
        }
        saveState()
        return msg
    }

    // MARK: 编译

    /// 把启用的列表编译进 store（内容 + 编译格式没变、规则表还在就跳过）；删掉不再需要的旧规则表；最后按需重建高级规则引擎。
    /// onListReady：每编好（或复用）一个列表就回调一次当前全部可用标识，宿主可以边编边挂（首次启动不用等全部编完）。
    /// 返回当前生效的标识（按列表顺序）
    @discardableResult
    public func compile(into store: MioRuleListCompiling, onListReady: (([String]) async -> Void)? = nil) async -> [String] {
        await loadEngineIfNeeded()
        let available = await store.availableIdentifiers()
        var active: [String] = []
        let lists = MioFilterCatalog.enabledLists(prefs)
        for list in lists {
            guard let text = text(of: list) else { continue }
            let sha = MioHash.sha256Hex(Data(text.utf8))
            var meta = state.lists[list.key] ?? MioFilterListMeta()
            let ids = (0..<max(meta.parts, 1)).map { Self.identifier(list, part: $0) }
            let advOK = meta.advancedRules == 0 || FileManager.default.fileExists(atPath: advancedURL(list).path)
            if meta.compiledSha == sha, meta.compileFormat == Self.compileFormat, meta.parts > 0, advOK, ids.allSatisfy(available.contains) {
                active += ids
                await onListReady?(active)
                continue
            }
            setActivity("正在编译 \(list.name)")
            let conv = converter
            let (parts, source) = await Task.detached(priority: .utility) { () -> ([MioConversionResult], Int) in
                let lines = MioFilterText.lines(text)
                let source = lines.reduce(0) { n, l in (l.hasPrefix("!") || l.hasPrefix("[")) ? n : n + 1 }
                return (MioRuleSplitter.convert(lines, converter: conv), source)
            }.value
            var err: String?
            var newIDs: [String] = []
            for (i, p) in parts.enumerated() {
                let id = Self.identifier(list, part: i)
                do { try await store.compile(identifier: id, json: p.json); newIDs.append(id) } catch { err = "\(id): \(error.localizedDescription)" }
            }
            for i in parts.count..<max(meta.parts, parts.count) { await store.remove(identifier: Self.identifier(list, part: i)) }
            let advText = parts.compactMap { $0.advancedText }.filter { !$0.isEmpty }.joined(separator: "\n")
            if advText.isEmpty { try? FileManager.default.removeItem(at: advancedURL(list)) }
            else { try? advText.write(to: advancedURL(list), atomically: true, encoding: .utf8) }
            meta.sha256 = meta.sha256 ?? sha
            meta.compiledSha = err == nil ? sha : nil
            meta.compileFormat = Self.compileFormat
            meta.compiledAt = Date()
            meta.parts = parts.count
            meta.sourceRules = source
            meta.contentRules = parts.reduce(0) { $0 + $1.ruleCount }
            meta.advancedRules = parts.reduce(0) { $0 + $1.advancedRules }
            meta.unsupported = parts.reduce(0) { $0 + $1.unsupported + $1.discarded }
            meta.error = err
            let m = meta
            mutate { $0.lists[list.key] = m }
            saveState()
            active += newIDs
            await onListReady?(active)
        }
        // 关掉的列表 / 旧分片：删
        for id in available where id.hasPrefix(Self.identifierPrefix) && !active.contains(id) { await store.remove(identifier: id) }
        await rebuildEngineIfNeeded(lists: lists)
        setActivity(nil)
        saveState()
        return active
    }

    /// 启动后第一次编译前：读上次构建的高级规则引擎（后台线程反序列化）
    func loadEngineIfNeeded() async {
        guard !engineLoadTried, let engine = advanced, !engine.isReady, state.engineSha != nil else { return }
        engineLoadTried = true
        let ok = await Task.detached(priority: .utility) { engine.load() }.value
        if !ok { mutate { $0.engineSha = nil } }
    }

    /// 全部启用列表的高级规则拼起来，变了就重建引擎
    func rebuildEngineIfNeeded(lists: [MioFilterList]) async {
        guard let engine = advanced else { return }
        let texts = lists.compactMap { try? String(contentsOf: advancedURL($0), encoding: .utf8) }.filter { !$0.isEmpty }
        let combined = texts.joined(separator: "\n")
        let sha = MioHash.sha256Hex(Data(combined.utf8))
        if sha == state.engineSha && (engine.isReady || combined.isEmpty) { return }
        if combined.isEmpty {
            // 没有高级规则：清空引擎（空规则也能构建，查询结果为空）
            _ = try? engine.build(rules: "")
            mutate { $0.engineSha = sha; $0.engineError = nil }
            return
        }
        setActivity("正在构建高级规则（scriptlet / 扩展 CSS）")
        let result: String? = await Task.detached(priority: .utility) { () -> String? in
            do { try engine.build(rules: combined); return nil } catch { return "\(error)" }
        }.value
        mutate { $0.engineSha = result == nil ? sha : nil; $0.engineError = result }
    }

    /// 已编译、当前应挂载的标识（不触发编译；启动时先用它 lookUp，后台再 compile）
    public func activeIdentifiers() -> [String] {
        MioFilterCatalog.enabledLists(prefs).flatMap { list -> [String] in
            guard let m = state.lists[list.key], m.compiledSha != nil, m.compileFormat == Self.compileFormat, m.parts > 0 else { return [] }
            return (0..<m.parts).map { Self.identifier(list, part: $0) }
        }
    }

    // MARK: 高级规则查询

    /// 某个页面（frame）要注入的高级规则 JS（scriptlet / 扩展 CSS / JS 规则）；nil = 没有。主线程调用（FilterEngine 查表，毫秒级）
    public func pageScript(for url: URL, topURL: URL?) -> String? {
        guard let sc = url.scheme?.lowercased(), sc == "http" || sc == "https", let engine = advanced, engine.isReady,
              let conf = engine.lookup(pageURL: url, topURL: topURL), !conf.isEmpty else { return nil }
        return MioAdvancedScript.build(conf, scriptlets: MioScriptletLibrary.bundled,
                                       extendedCssLib: conf.extendedCss.isEmpty ? nil : MioScriptletLibrary.bundledExtendedCss)
    }

    // MARK: 状态

    public func summary() -> MioFilterSummary {
        lock.lock(); let s = state; lock.unlock()
        let lists = MioFilterCatalog.enabledLists(prefs)
        var r = MioFilterSummary(lists: lists.count, compiledLists: 0, contentRules: 0, advancedRules: 0, skipped: 0,
                                 lastSuccess: s.lastSuccess, errors: [:], missing: missingLists().map(\.name))
        for l in lists {
            guard let m = s.lists[l.key] else { continue }
            if m.compiledSha != nil && m.compileFormat == Self.compileFormat {
                r.compiledLists += 1
                r.contentRules += m.contentRules
                r.advancedRules += m.advancedRules
                r.skipped += m.unsupported
            }
            if let e = m.error { r.errors[l.name] = e }
        }
        if let e = s.engineError { r.errors["高级规则"] = e }
        return r
    }

    /// 设置页「状态」：已加载 N 条（内容规则 X · 高级 Y）· 跳过 M 条 · 上次更新 …
    public func statusText(now: Date = Date()) -> String {
        let s = summary()
        var out = "已加载 \(s.loaded) 条（内容规则 \(s.contentRules) · 高级 \(s.advancedRules)）· 跳过 \(s.skipped) 条"
        if let t = s.lastSuccess { out += " · 上次更新 " + Self.shortDate(t, now: now) } else { out += " · 订阅尚未下载" }
        if let a = activity { out += "；" + a }
        if !s.missing.isEmpty && activity == nil { out += "；待下载：" + s.missing.joined(separator: "、") }
        if !s.errors.isEmpty { out += "；出错：" + s.errors.keys.sorted().joined(separator: "、") }
        return out
    }

    /// 每个列表一行：名字 版本 条数 / 跳过 / 错误
    public func listDetails() -> String {
        lock.lock(); let s = state; lock.unlock()
        return MioFilterCatalog.enabledLists(prefs).map { l in
            guard let m = s.lists[l.key] else { return "\(l.name)：未下载" }
            var line = "\(l.name)"
            if let v = m.version { line += " \(v)" }
            if m.compiledSha != nil && m.compileFormat == Self.compileFormat {
                line += "：\(m.contentRules + m.advancedRules) 条，跳过 \(m.unsupported)"
            } else if m.fetchedAt != nil || l.isBundled {
                line += "：待编译"
            } else {
                line += "：未下载"
            }
            if let e = m.error { line += "（\(e)）" }
            return line
        }.joined(separator: "\n")
    }

    static func shortDate(_ d: Date, now: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = .current
        f.dateFormat = Calendar.current.isDate(d, inSameDayAs: now) ? "今天 HH:mm" : "M月d日 HH:mm"
        return f.string(from: d)
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
        for line in MioFilterText.lines(head).prefix(40) where line.hasPrefix("! Version:") {
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
