// MioAdblockCore.swift — 内置浏览器的广告拦截核心（iOS / Mac Catalyst 共用，也被 tools/AdblockCheck 在 macOS 上直接编译）
//
// 组件（均为 AdGuard 开源项目，GPL-3.0，见仓库 NOTICE）：
// - SafariConverterLib（ContentBlockerConverter + FilterEngine）：AdGuard/EasyList 规则 → WKContentRuleList JSON + 高级规则引擎
// - AdGuard Scriptlets（scriptlets.corelibs.json）：脚本小片段（json-prune / set-constant ...）
// - AdGuard ExtendedCss：扩展 CSS 选择器（:has / :upward ...）
//
// 不依赖 UIKit。

import Foundation
import WebKit
import CryptoKit
import ContentBlockerConverter
import FilterEngine

extension Notification.Name {
    /// 规则编译完成 / 设置变化，已打开的浏览器据此重新挂载规则
    static let mioAdblockDidChange = Notification.Name("MioAdblockDidChange")
}

// MARK: - Filter catalog

struct MioFilterList: Equatable {
    let id: Int
    let name: String
    /// false = 仅 App 内置（Mio 补充规则），不远程更新
    let remote: Bool

    var url: URL? {
        remote ? URL(string: "https://filters.adtidy.org/ios/filters/\(id)_optimized.txt") : nil
    }
    var fileName: String { "filter-\(id).txt" }
    var key: String { String(id) }
}

enum MioFilterCatalog {
    /// 每个列表单独编译成一个（或多个，超过 15 万条时拆分）WKContentRuleList；
    /// 列表之间互不影响（例外规则只在同一列表内生效，所以按官方列表边界拆，不混合）
    static let lists: [MioFilterList] = [
        MioFilterList(id: 2, name: "AdGuard Base", remote: true),
        MioFilterList(id: 11, name: "AdGuard 移动广告", remote: true),
        MioFilterList(id: 3, name: "AdGuard 跟踪保护", remote: true),
        MioFilterList(id: 101, name: "EasyList", remote: true),
        MioFilterList(id: 118, name: "EasyPrivacy", remote: true),
        MioFilterList(id: 224, name: "AdGuard 中文", remote: true),
        MioFilterList(id: 0, name: "Mio YouTube 补充", remote: false),
    ]
}

// MARK: - Persistent state

struct MioListMeta: Codable {
    var source: String = "bundle"        // bundle | remote
    var etag: String?
    var lastModified: String?
    var version: String?                 // "! Version:"
    var timeUpdated: String?             // "! TimeUpdated:"
    var fetchedAt: Date?                 // 下载到新内容的时间
    var checkedAt: Date?                 // 最近一次检查（含 304）
    var sha256: String = ""
    var compiledSha: String?
    var parts: Int = 0
    var sourceRules: Int = 0
    var safariRules: Int = 0
    var advancedRules: Int = 0
    var discarded: Int = 0
    var error: String?
}

struct MioScriptletMeta: Codable {
    var version: String
    var sha256: String
    var source: String                   // bundle | remote
    var fetchedAt: Date?
}

struct MioAdblockState: Codable {
    var lists: [String: MioListMeta] = [:]
    var lastCheck: Date?
    var lastCheckOK: Bool?
    var lastCheckMessage: String?
    var compiledAt: Date?
    var engineDir: String?
    var engineSha: String?
    var scriptlets: MioScriptletMeta?
    var scriptletsCheckedAt: Date?
}

/// 读给 UI 的快照（主线程）
struct MioAdblockSnapshot {
    var state: MioAdblockState
    var busy: String?                    // 正在做什么（nil = 空闲）
    var ruleListCount: Int
    var ready: Bool
}

// MARK: - Settings (UserDefaults)

enum MioAdblockSettings {
    private static let defaults = UserDefaults.standard
    private static let enabledKey = "mio.adblock.enabled"
    private static let allowlistKey = "mio.adblock.allowlist"

    static var enabled: Bool {
        get { defaults.object(forKey: enabledKey) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: enabledKey)
            NotificationCenter.default.post(name: .mioAdblockDidChange, object: nil)
        }
    }

    /// 按站点白名单（主域名，匹配其所有子域名）
    static var allowlist: [String] {
        get { defaults.stringArray(forKey: allowlistKey) ?? [] }
        set {
            let cleaned = Array(Set(newValue.map { normalize($0) }.filter { !$0.isEmpty })).sorted()
            defaults.set(cleaned, forKey: allowlistKey)
            NotificationCenter.default.post(name: .mioAdblockDidChange, object: nil)
        }
    }

    static func normalize(_ host: String) -> String {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let u = URL(string: h), let uh = u.host { h = uh }
        if h.hasPrefix("www.") { h = String(h.dropFirst(4)) }
        return h
    }

    /// 白名单条目（若命中）
    static func allowlistEntry(for host: String?) -> String? {
        guard let host = host?.lowercased(), !host.isEmpty else { return nil }
        for entry in allowlist where host == entry || host.hasSuffix("." + entry) {
            return entry
        }
        return nil
    }

    static func isAllowlisted(_ host: String?) -> Bool { allowlistEntry(for: host) != nil }

    static func setAllowlisted(_ host: String, _ on: Bool) {
        let entry = normalize(host)
        var list = allowlist
        if on {
            list.append(entry)
        } else {
            list.removeAll { entry == $0 || entry.hasSuffix("." + $0) }
        }
        allowlist = list
    }
}

// MARK: - Scriptlets (AdGuard Scriptlets corelibs bundle)

final class MioScriptlets {
    let version: String
    let sha256: String
    private let functions: [String: String]

    init(data: Data) throws {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = obj["version"] as? String,
              let list = obj["scriptlets"] as? [[String: Any]] else {
            throw MioAdblockError.invalid("scriptlets.corelibs.json 格式不对")
        }
        var map: [String: String] = [:]
        for item in list {
            guard let names = item["names"] as? [String], let fn = item["scriptlet"] as? String,
                  fn.hasPrefix("function") else { continue }
            for n in names { map[n] = fn }
        }
        guard map.count > 50, map["json-prune"] != nil, map["set-constant"] != nil else {
            throw MioAdblockError.invalid("scriptlets 内容不完整（\(map.count)）")
        }
        self.version = version
        self.sha256 = Data(SHA256.hash(data: data)).base64EncodedString()
        self.functions = map
    }

    var count: Int { Set(functions.values).count }

    func function(named name: String) -> String? { functions[name] }

    /// 生成一个 scriptlet 调用（与 AdGuard Scriptlets passSourceAndProps 一致）；fnRef 给定时调用已定义的函数变量（同一函数只定义一次）
    func code(name: String, args: [String], fnRef: String? = nil) -> String? {
        guard let fn = functions[name] else { return nil }
        let source: [String: Any] = [
            "name": name,
            "args": args,
            "engine": "safari-extension",
            "version": version,
            "verbose": false,
            "uniqueId": "mio",
        ]
        guard let src = MioJS.json(source), let a = MioJS.json(args) else { return nil }
        return "try{(\(fnRef ?? fn))(\(src),\(a));}catch(e){}"
    }
}

enum MioAdblockError: Error, CustomStringConvertible {
    case invalid(String)
    case network(String)
    case compile(String)

    var description: String {
        switch self {
        case .invalid(let s), .network(let s), .compile(let s): return s
        }
    }
}

enum MioJS {
    static func json(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value) || value is String,
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func string(_ s: String) -> String {
        json(s) ?? "\"\""
    }
}

// MARK: - Engine

/// 规则下载 / 转换 / 编译 / 查询。重活都在 `work` 串行队列；对外状态在主线程发布。
final class MioAdblock {
    static let shared = MioAdblock()

    /// App 内置资源目录（AdblockBundle/：filter-*.txt、manifest.json、scriptlets.corelibs.json、extended-css.min.js）
    var bundleDir: URL
    /// 本机缓存目录（Application Support/MioAdblock）
    let storeDir: URL
    let updateInterval: TimeInterval = 24 * 3600

    private let work = DispatchQueue(label: "mio.adblock.work", qos: .utility)
    private var state = MioAdblockState()          // work 队列
    private var started = false

    // 主线程
    private(set) var ruleLists: [WKContentRuleList] = []
    private(set) var snapshot = MioAdblockSnapshot(state: MioAdblockState(), busy: "启动中", ruleListCount: 0, ready: false)

    // 查询（任意线程，lock 保护）
    private let lookupLock = NSLock()
    private var webExtension: WebExtension?
    private var scriptlets: MioScriptlets?
    private(set) lazy var extendedCssLib: String? = {
        guard let data = try? Data(contentsOf: bundleDir.appendingPathComponent("extended-css.min.js")) else { return nil }
        return String(data: data, encoding: .utf8)
    }()

    /// BGAppRefreshTask 超时时设为 true，转换中途放弃
    private var cancelFlag = false
    private var currentProgress: Progress?

    init(bundleDir: URL? = nil, storeDir: URL? = nil) {
        self.bundleDir = bundleDir ?? (Bundle.main.resourceURL ?? URL(fileURLWithPath: ".")).appendingPathComponent("AdblockBundle", isDirectory: true)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.storeDir = storeDir ?? support.appendingPathComponent("MioAdblock", isDirectory: true)
    }

    private var listsDir: URL { storeDir.appendingPathComponent("lists", isDirectory: true) }
    private var advDir: URL { storeDir.appendingPathComponent("adv", isDirectory: true) }
    private var stateURL: URL { storeDir.appendingPathComponent("state.json") }
    private var scriptletsURL: URL { storeDir.appendingPathComponent("scriptlets.corelibs.json") }

    // MARK: lifecycle

    /// App 启动时调用：加载缓存 → 缺什么编译什么 → 超过 24h 检查更新
    func start(checkUpdates: Bool = true, completion: (() -> Void)? = nil) {
        work.async {
            if !self.started {
                self.started = true
                self.prepareStore()
                self.loadScriptlets()
                self.loadEngine()
            }
            self.publish(busy: "加载规则")
            self.compileIfNeeded()
            if checkUpdates {
                self.checkForUpdatesLocked(force: false)
            }
            self.publish(busy: nil)
            if let completion = completion { DispatchQueue.main.async(execute: completion) }
        }
    }

    /// 手动「立即更新」或后台刷新。completion(ok, message) 在主线程。
    func checkForUpdates(force: Bool, completion: ((Bool, String) -> Void)? = nil) {
        work.async {
            if !self.started {
                self.started = true
                self.prepareStore()
                self.loadScriptlets()
                self.loadEngine()
                self.compileIfNeeded()
            }
            self.cancelFlag = false
            let (ok, msg) = self.checkForUpdatesLocked(force: force)
            self.publish(busy: nil)
            if let completion = completion { DispatchQueue.main.async { completion(ok, msg) } }
        }
    }

    /// 后台任务即将超时
    func cancelWork() {
        cancelFlag = true
        currentProgress?.cancel()
    }

    var needsUpdateCheck: Bool {
        guard let last = snapshot.state.lastCheck else { return true }
        return Date().timeIntervalSince(last) >= updateInterval
    }

    // MARK: store

    private func prepareStore() {
        let fm = FileManager.default
        for d in [storeDir, listsDir, advDir] {
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        if let data = try? Data(contentsOf: stateURL),
           let s = try? JSONDecoder.mio.decode(MioAdblockState.self, from: data) {
            state = s
        }
        let manifest = bundleManifest()
        // 首次安装或 App 带了更新的内置规则：用内置版本
        for list in MioFilterCatalog.lists {
            let bundled = bundleDir.appendingPathComponent(list.fileName)
            let local = listsDir.appendingPathComponent(list.fileName)
            guard let bdata = try? Data(contentsOf: bundled) else { continue }
            let bsha = Self.sha(bdata)
            var meta = state.lists[list.key] ?? MioListMeta()
            let localExists = fm.fileExists(atPath: local.path)
            var useBundle = !localExists || meta.sha256.isEmpty
            if !useBundle, meta.source == "bundle", meta.sha256 != bsha { useBundle = true }
            if !useBundle, !list.remote, meta.sha256 != bsha { useBundle = true }
            if !useBundle, meta.source == "remote",
               let bm = manifest?[list.key] as? [String: Any],
               let bTime = (bm["lastModified"] as? String).flatMap(Self.httpDate),
               let lTime = meta.lastModified.flatMap(Self.httpDate), bTime > lTime {
                useBundle = true   // App 内置的比上次下载的还新
            }
            if useBundle {
                try? bdata.write(to: local, options: .atomic)
                let header = Self.header(of: bdata)
                meta.source = "bundle"
                meta.sha256 = bsha
                meta.version = header.version
                meta.timeUpdated = header.timeUpdated
                if let bm = manifest?[list.key] as? [String: Any] {
                    meta.etag = bm["etag"] as? String
                    meta.lastModified = bm["lastModified"] as? String
                } else {
                    meta.etag = nil
                    meta.lastModified = nil
                }
                meta.fetchedAt = nil
                state.lists[list.key] = meta
            }
        }
        saveState()
    }

    private func bundleManifest() -> [String: Any]? {
        guard let data = try? Data(contentsOf: bundleDir.appendingPathComponent("manifest.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["lists"] as? [String: Any]
    }

    private func saveState() {
        if let data = try? JSONEncoder.mio.encode(state) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }

    private func publish(busy: String?) {
        let s = state
        DispatchQueue.main.async {
            self.snapshot = MioAdblockSnapshot(state: s, busy: busy, ruleListCount: self.ruleLists.count,
                                               ready: !self.ruleLists.isEmpty)
            NotificationCenter.default.post(name: .mioAdblockDidChange, object: self)
        }
    }

    // MARK: scriptlets

    private func loadScriptlets() {
        let bundledURL = bundleDir.appendingPathComponent("scriptlets.corelibs.json")
        var chosen: MioScriptlets?
        var source = "bundle"
        if let data = try? Data(contentsOf: scriptletsURL), let s = try? MioScriptlets(data: data),
           s.sha256 == state.scriptlets?.sha256 {
            chosen = s
            source = "remote"
        }
        if let data = try? Data(contentsOf: bundledURL), let b = try? MioScriptlets(data: data) {
            // 远程版本不比内置新（App 升级带来更新的内置版）→ 用内置
            if let c = chosen, Self.compareVersions(c.version, b.version) < 0 { chosen = nil }
            if chosen == nil { chosen = b; source = "bundle" }
        }
        if let c = chosen {
            lookupLock.lock(); scriptlets = c; lookupLock.unlock()
            var meta = state.scriptlets ?? MioScriptletMeta(version: c.version, sha256: c.sha256, source: source, fetchedAt: nil)
            meta.version = c.version
            meta.sha256 = c.sha256
            meta.source = source
            if source == "bundle" { meta.fetchedAt = nil }
            state.scriptlets = meta
            saveState()
        }
    }

    /// 远程更新 Scriptlets：npm registry 取同一主版本的 latest → jsDelivr 下载 dist/scriptlets.corelibs.json →
    /// 用 jsDelivr data API 给出的 SHA-256 校验 → 解析校验 → 缓存。任何一步失败保持当前版本（内置兜底）。
    private func updateScriptlets() -> String {
        guard let current = scriptlets else { return "Scriptlets 未加载" }
        let major = current.version.split(separator: ".").first.map(String.init) ?? "2"
        do {
            var req = URLRequest(url: URL(string: "https://registry.npmjs.org/@adguard/scriptlets")!, timeoutInterval: 30)
            req.setValue("application/vnd.npm.install-v1+json", forHTTPHeaderField: "Accept")
            let (meta, _) = try Self.fetch(req)
            guard let obj = try JSONSerialization.jsonObject(with: meta) as? [String: Any],
                  let tags = obj["dist-tags"] as? [String: Any], let latest = tags["latest"] as? String else {
                throw MioAdblockError.invalid("npm registry 响应异常")
            }
            state.scriptletsCheckedAt = Date()
            guard latest.split(separator: ".").first.map(String.init) == major else { return "Scriptlets \(current.version)（新主版本 \(latest) 未自动采用）" }
            guard Self.compareVersions(latest, current.version) > 0 else { return "Scriptlets \(current.version) 已是最新" }
            let path = "/dist/scriptlets.corelibs.json"
            let (flat, _) = try Self.fetch(URLRequest(url: URL(string: "https://data.jsdelivr.com/v1/packages/npm/@adguard/scriptlets@\(latest)?structure=flat")!, timeoutInterval: 30))
            guard let fobj = try JSONSerialization.jsonObject(with: flat) as? [String: Any],
                  let files = fobj["files"] as? [[String: Any]],
                  let expected = files.first(where: { ($0["name"] as? String) == path })?["hash"] as? String else {
                throw MioAdblockError.invalid("jsDelivr 没有 \(path) 的哈希")
            }
            let (data, _) = try Self.fetch(URLRequest(url: URL(string: "https://cdn.jsdelivr.net/npm/@adguard/scriptlets@\(latest)\(path)")!, timeoutInterval: 60))
            let got = Data(SHA256.hash(data: data)).base64EncodedString()
            guard got == expected else { throw MioAdblockError.invalid("Scriptlets \(latest) 哈希不匹配") }
            let s = try MioScriptlets(data: data)
            guard s.version == latest else { throw MioAdblockError.invalid("Scriptlets 版本号不一致") }
            try data.write(to: scriptletsURL, options: .atomic)
            lookupLock.lock(); scriptlets = s; lookupLock.unlock()
            state.scriptlets = MioScriptletMeta(version: s.version, sha256: s.sha256, source: "remote", fetchedAt: Date())
            saveState()
            return "Scriptlets 更新到 \(s.version)"
        } catch {
            return "Scriptlets 更新失败：\(error)"
        }
    }

    // MARK: update

    @discardableResult
    private func checkForUpdatesLocked(force: Bool) -> (Bool, String) {
        if !force, let last = state.lastCheck, Date().timeIntervalSince(last) < updateInterval {
            return (true, "24 小时内已检查过")
        }
        publish(busy: "检查更新")
        var changed = 0
        var failed: [String] = []
        var okCount = 0
        for list in MioFilterCatalog.lists where list.remote {
            if cancelFlag { break }
            guard let url = list.url else { continue }
            var meta = state.lists[list.key] ?? MioListMeta()
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
            if let etag = meta.etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
            if let lm = meta.lastModified { req.setValue(lm, forHTTPHeaderField: "If-Modified-Since") }
            do {
                let (data, resp) = try Self.fetch(req, allow304: true)
                meta.checkedAt = Date()
                if resp.statusCode == 304 {
                    okCount += 1
                } else {
                    guard Self.looksLikeFilter(data) else { throw MioAdblockError.invalid("内容不像过滤列表") }
                    let sha = Self.sha(data)
                    if sha != meta.sha256 {
                        try data.write(to: listsDir.appendingPathComponent(list.fileName), options: .atomic)
                        let header = Self.header(of: data)
                        meta.sha256 = sha
                        meta.version = header.version
                        meta.timeUpdated = header.timeUpdated
                        meta.fetchedAt = Date()
                        meta.source = "remote"
                        changed += 1
                    }
                    meta.etag = resp.value(forHTTPHeaderField: "ETag")
                    meta.lastModified = resp.value(forHTTPHeaderField: "Last-Modified")
                    okCount += 1
                }
                meta.error = nil
            } catch {
                meta.error = "\(error)"
                failed.append(list.name)
            }
            state.lists[list.key] = meta
            saveState()
        }
        var parts: [String] = []
        if !cancelFlag {
            parts.append(updateScriptlets())
        }
        if okCount > 0 { state.lastCheck = Date() }
        state.lastCheckOK = failed.isEmpty && !cancelFlag
        if changed > 0 && !cancelFlag {
            compileIfNeeded()
        }
        let msg: String
        if cancelFlag {
            msg = "已中断（下次启动继续）"
        } else if failed.isEmpty {
            msg = (changed > 0 ? "\(changed) 个列表有更新，已重新编译" : "规则已是最新") + "；" + parts.joined(separator: "；")
        } else {
            msg = "部分失败：\(failed.joined(separator: "、"))；" + parts.joined(separator: "；")
        }
        state.lastCheckMessage = msg
        saveState()
        return (failed.isEmpty && !cancelFlag, msg)
    }

    // MARK: compile

    private func compileIfNeeded() {
        let available = Set(availableRuleListIdentifiers())
        var advChanged = false
        var compiledAny = false
        for list in MioFilterCatalog.lists {
            if cancelFlag { return }
            guard var meta = state.lists[list.key] else { continue }
            let ids = (0..<max(meta.parts, 1)).map { Self.identifier(list, $0) }
            let present = meta.parts > 0 && ids.allSatisfy { available.contains($0) }
            if meta.compiledSha == meta.sha256 && present && fileExists(advDir.appendingPathComponent("adv-\(list.id).txt")) { continue }
            guard let data = try? Data(contentsOf: listsDir.appendingPathComponent(list.fileName)),
                  var text = String(data: data, encoding: .utf8) else { continue }
            publish(busy: "编译 \(list.name)")
            text.makeContiguousUTF8()
            let lines = Self.lines(text)
            let started = Date()
            let results = convert(lines)
            if cancelFlag { return }
            var safari = 0, discarded = 0, advanced = 0
            var advText: [String] = []
            var compileError: String?
            for (i, r) in results.enumerated() {
                safari += r.safariRulesCount
                discarded += r.discardedSafariRules
                advanced += r.advancedRulesCount
                if let a = r.advancedRulesText, !a.isEmpty { advText.append(a) }
                if let err = compileRuleList(identifier: Self.identifier(list, i), json: r.safariRulesJSON) {
                    compileError = err
                }
            }
            // 删除旧的多余分片
            for i in results.count..<max(meta.parts, results.count) {
                removeRuleList(identifier: Self.identifier(list, i))
            }
            try? advText.joined(separator: "\n").write(to: advDir.appendingPathComponent("adv-\(list.id).txt"), atomically: true, encoding: .utf8)
            meta.parts = results.count
            meta.sourceRules = lines.count
            meta.safariRules = safari
            meta.discarded = discarded
            meta.advancedRules = advanced
            meta.compiledSha = compileError == nil ? meta.sha256 : nil
            meta.error = compileError
            state.lists[list.key] = meta
            advChanged = true
            compiledAny = true
            let took = String(format: "%.1f", Date().timeIntervalSince(started))
            NSLog("%@", "⚡️ Mio adblock compiled \(list.name): \(lines.count) source → \(safari) safari (\(results.count) parts, \(discarded) discarded), \(advanced) advanced in \(took)s")
            saveState()
        }
        if compiledAny { state.compiledAt = Date() }
        if advChanged || webExtension == nil {
            buildEngine()
        }
        saveState()
        reloadRuleLists()
    }

    /// 一个 WKContentRuleList 最多 15 万条：超了就对半拆分（递归），每片单独编译
    private func convert(_ lines: [String]) -> [ConversionResult] {
        let progress = Progress(totalUnitCount: 1)
        currentProgress = progress
        let r = ContentBlockerConverter().convertArray(
            rules: lines,
            safariVersion: SafariVersion.autodetect(),
            advancedBlocking: true,
            maxJsonSizeBytes: nil,
            progress: progress
        )
        currentProgress = nil
        if r.discardedSafariRules > 0 && lines.count > 2000 && !cancelFlag {
            let mid = lines.count / 2
            return convert(Array(lines[..<mid])) + convert(Array(lines[mid...]))
        }
        return [r]
    }

    private func buildEngine() {
        var all: [String] = []
        for list in MioFilterCatalog.lists {
            if let s = try? String(contentsOf: advDir.appendingPathComponent("adv-\(list.id).txt"), encoding: .utf8), !s.isEmpty {
                all.append(s)
            }
        }
        let combined = all.joined(separator: "\n")
        let sha = Self.sha(Data(combined.utf8))
        if sha == state.engineSha, webExtension != nil { return }
        publish(busy: "构建高级规则引擎")
        let dirName = "engine-\(Int(Date().timeIntervalSince1970))"
        let dir = storeDir.appendingPathComponent(dirName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let ext = try WebExtension(containerURL: dir)
            _ = try ext.buildFilterEngine(rules: combined)
            lookupLock.lock(); webExtension = ext; lookupLock.unlock()
            let old = state.engineDir
            state.engineDir = dirName
            state.engineSha = sha
            saveState()
            if let old = old, old != dirName {
                try? FileManager.default.removeItem(at: storeDir.appendingPathComponent(old))
            }
        } catch {
            NSLog("%@", "⚡️ Mio adblock engine build failed: \(error)")
        }
    }

    private func loadEngine() {
        guard let name = state.engineDir else { return }
        let dir = storeDir.appendingPathComponent(name, isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path), let ext = try? WebExtension(containerURL: dir) else {
            state.engineDir = nil
            state.engineSha = nil
            return
        }
        lookupLock.lock(); webExtension = ext; lookupLock.unlock()
    }

    // MARK: WKContentRuleListStore（主线程调用，work 队列等待）

    private static func identifier(_ list: MioFilterList, _ part: Int) -> String { "mio-\(list.id)-\(part)" }

    private func availableRuleListIdentifiers() -> [String] {
        let sem = DispatchSemaphore(value: 0)
        let ids = MioBox<[String]>([])
        DispatchQueue.main.async {
            WKContentRuleListStore.default().getAvailableContentRuleListIdentifiers { list in
                ids.value = list ?? []
                sem.signal()
            }
        }
        sem.wait()
        return ids.value
    }

    private func compileRuleList(identifier: String, json: String) -> String? {
        let sem = DispatchSemaphore(value: 0)
        let box = MioBox<String?>(nil)
        DispatchQueue.main.async {
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { _, error in
                if let error = error { box.value = "\(identifier): \(error.localizedDescription)" }
                sem.signal()
            }
        }
        sem.wait()
        let err = box.value
        if let err = err { NSLog("%@", "⚡️ Mio adblock compile error \(err)") }
        return err
    }

    private func removeRuleList(identifier: String) {
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            WKContentRuleListStore.default().removeContentRuleList(forIdentifier: identifier) { _ in sem.signal() }
        }
        sem.wait()
    }

    private func reloadRuleLists() {
        var ids: [String] = []
        for list in MioFilterCatalog.lists {
            guard let meta = state.lists[list.key], meta.parts > 0 else { continue }
            ids += (0..<meta.parts).map { Self.identifier(list, $0) }
        }
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            let group = DispatchGroup()
            let results = MioBox<[String: WKContentRuleList]>([:])
            for id in ids {
                group.enter()
                WKContentRuleListStore.default().lookUpContentRuleList(forIdentifier: id) { list, _ in
                    if let list = list { results.value[id] = list }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                self.ruleLists = ids.compactMap { results.value[$0] }
                sem.signal()
            }
        }
        sem.wait()
        publish(busy: nil)
    }

    // MARK: lookup（主线程）

    /// 某个页面（frame）要注入的 JS；nil = 没有需要注入的内容
    func pageScript(for url: URL, topURL: URL?) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        lookupLock.lock()
        let ext = webExtension
        let sl = scriptlets
        lookupLock.unlock()
        guard let conf = ext?.lookup(pageUrl: url, topUrl: topURL) else { return nil }
        return Self.script(for: conf, scriptlets: sl, extendedCssLib: conf.extendedCss.isEmpty ? nil : extendedCssLib)
    }

    /// 只给检查工具 / 设置页用
    func configuration(for url: URL, topURL: URL? = nil) -> WebExtension.Configuration? {
        lookupLock.lock()
        let ext = webExtension
        lookupLock.unlock()
        return ext?.lookup(pageUrl: url, topUrl: topURL)
    }

    var scriptletsVersion: String? {
        lookupLock.lock(); defer { lookupLock.unlock() }
        return scriptlets?.version
    }

    static func cssRules(_ css: [String]) -> [String] {
        css.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0.hasSuffix("}") ? $0 : "\($0) {display:none!important;}" }
    }

    static func script(for conf: WebExtension.Configuration, scriptlets: MioScriptlets?, extendedCssLib: String?) -> String? {
        var parts: [String] = []
        // 1) scriptlets 最先（要赶在页面脚本之前）；去重，同一个函数只定义一次
        if let sl = scriptlets {
            var seen = Set<String>()
            var fnVars: [String: String] = [:]
            var defs: [String] = []
            var calls: [String] = []
            for s in conf.scriptlets {
                let key = s.name + "\u{1}" + s.args.joined(separator: "\u{1}")
                guard !seen.contains(key), let fn = sl.function(named: s.name) else { continue }
                seen.insert(key)
                let v: String
                if let existing = fnVars[fn] {
                    v = existing
                } else {
                    v = "__mioS\(fnVars.count)"
                    fnVars[fn] = v
                    defs.append("var \(v)=\(fn);")
                }
                if let code = sl.code(name: s.name, args: s.args, fnRef: v) { calls.append(code) }
            }
            if !calls.isEmpty {
                parts.append("(function(){\n" + defs.joined(separator: "\n") + "\n" + calls.joined(separator: "\n") + "\n})();")
            }
        }
        // 2) 普通 CSS
        let css = cssRules(conf.css)
        if !css.isEmpty {
            parts.append("""
            (function(){var css=\(MioJS.string(css.joined(separator: "\n")));function add(){try{var s=document.createElement('style');s.setAttribute('data-mio-adblock','');s.textContent=css;(document.head||document.documentElement).appendChild(s);}catch(e){}}if(document.documentElement){add();}else{document.addEventListener('readystatechange',add,{once:true});}})();
            """)
        }
        // 3) JS 规则
        for js in conf.js {
            parts.append("try{\(js)\n}catch(e){}")
        }
        // 4) ExtendedCss
        let ext = cssRules(conf.extendedCss)
        if !ext.isEmpty, let lib = extendedCssLib, let rules = MioJS.json(ext) {
            parts.append("""
            (function(){\(lib)
            ;var rules=\(rules);function go(){try{new ExtendedCss({cssRules:rules}).apply();}catch(e){}}if(document.readyState==='loading'){document.addEventListener('DOMContentLoaded',go,{once:true});}else{go();}})();
            """)
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n")
    }

    // MARK: helpers

    private func fileExists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }).map(String.init)
    }

    static func header(of data: Data) -> (version: String?, timeUpdated: String?) {
        let head = String(decoding: data.prefix(4096), as: UTF8.self)
        var version: String?
        var time: String?
        for line in head.split(separator: "\n").prefix(40) {
            let l = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if l.hasPrefix("! Version:") { version = l.dropFirst(10).trimmingCharacters(in: .whitespaces) }
            if l.hasPrefix("! TimeUpdated:") { time = l.dropFirst(14).trimmingCharacters(in: .whitespaces) }
        }
        return (version, time)
    }

    static func looksLikeFilter(_ data: Data) -> Bool {
        guard data.count > 1000 else { return false }
        let head = String(decoding: data.prefix(2048), as: UTF8.self).lowercased()
        if head.contains("<html") || head.contains("<!doctype") { return false }
        return head.contains("! title") || head.contains("[adblock") || head.contains("! version")
    }

    static func httpDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: s)
    }

    /// -1 / 0 / 1（只比较数字段；预发布版本当作更旧）
    static func compareVersions(_ a: String, _ b: String) -> Int {
        func parts(_ v: String) -> [Int] {
            let core = v.split(separator: "-").first.map(String.init) ?? v
            return core.split(separator: ".").map { Int($0) ?? 0 }
        }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        let preA = a.contains("-"), preB = b.contains("-")
        if preA != preB { return preA ? -1 : 1 }
        return 0
    }

    /// 同步请求（只在 work 队列调用）
    static func fetch(_ request: URLRequest, allow304: Bool = false) throws -> (Data, HTTPURLResponse) {
        let sem = DispatchSemaphore(value: 0)
        let result = MioBox<(Data, HTTPURLResponse)?>(nil)
        let failure = MioBox<Error?>(nil)
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        session.dataTask(with: request) { data, resp, error in
            if let error = error {
                failure.value = MioAdblockError.network(error.localizedDescription)
            } else if let http = resp as? HTTPURLResponse {
                if http.statusCode == 200 || (allow304 && http.statusCode == 304) {
                    result.value = (data ?? Data(), http)
                } else {
                    failure.value = MioAdblockError.network("HTTP \(http.statusCode)")
                }
            } else {
                failure.value = MioAdblockError.network("无响应")
            }
            sem.signal()
        }.resume()
        sem.wait()
        session.finishTasksAndInvalidate()
        if let r = result.value { return r }
        throw failure.value ?? MioAdblockError.network("未知错误")
    }
}

/// 回调里写结果用（避免 @Sendable 闭包里修改捕获的 var）
final class MioBox<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

extension JSONDecoder {
    static var mio: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

extension JSONEncoder {
    static var mio: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

// MARK: - Per-WebView session

/// WKUserContentController 会强引用 handler：弱引用转发
final class MioAdblockWeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// 一个内置浏览器 WebView 的拦截状态：
/// - 内容拦截：把 MioAdblock.ruleLists 挂到 userContentController（白名单站点 / 关闭拦截时全部摘掉）
/// - 主框架：在 decidePolicyFor(navigationAction) 里提前查好目标页面的 scriptlets/CSS，
///   生成 document-start 用户脚本（按 hostname 分发），保证比页面脚本先跑
/// - 子框架（iframe）：document-start 发消息给原生，原生查询后 evaluateJavaScript(in: frame, in: .page) 注入
final class MioAdblockSession: NSObject, WKScriptMessageHandler {
    static let messageName = "mioAdblock"

    weak var webView: WKWebView?
    private let controller: WKUserContentController
    /// 外部附加的用户脚本（例如后台播放用的 visibility 覆盖）
    var extraScripts: [WKUserScript] = [] { didSet { rebuildScripts() } }
    /// 最近准备过的主框架页面：host → 注入代码（保留 2 个，处理跨主机重定向 youtube.com → m.youtube.com）
    private var prepared: [(host: String, code: String)] = []
    private var attachedKey = ""
    private var observer: NSObjectProtocol?
    private(set) var topHost: String?

    init(configuration: WKWebViewConfiguration) {
        controller = configuration.userContentController
        super.init()
        controller.add(MioAdblockWeakHandler(self), name: Self.messageName)
        rebuildScripts()
        observer = NotificationCenter.default.addObserver(forName: .mioAdblockDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.refreshAfterChange()
        }
    }

    deinit {
        if let observer = observer { NotificationCenter.default.removeObserver(observer) }
    }

    func detach() {
        controller.removeScriptMessageHandler(forName: Self.messageName)
    }

    var isActiveForCurrentPage: Bool {
        MioAdblockSettings.enabled && !MioAdblockSettings.isAllowlisted(topHost)
    }

    /// 主框架即将导航到 url（包括服务端重定向）：挂规则、准备脚本
    func prepareMainFrame(_ url: URL) {
        let host = url.host?.lowercased()
        topHost = host
        attachRuleLists()
        guard let host = host else { return }
        prepared.removeAll { $0.host == host }
        if isActiveForCurrentPage, let code = MioAdblock.shared.pageScript(for: url, topURL: nil) {
            prepared.append((host, code))
            if prepared.count > 2 { prepared.removeFirst(prepared.count - 2) }
        }
        rebuildScripts()
    }

    private func refreshAfterChange() {
        attachedKey = ""
        attachRuleLists()
        if !isActiveForCurrentPage { prepared.removeAll() }
        rebuildScripts()
    }

    private func attachRuleLists() {
        let lists = isActiveForCurrentPage ? MioAdblock.shared.ruleLists : []
        let key = lists.map { $0.identifier }.joined(separator: ",")
        guard key != attachedKey else { return }
        controller.removeAllContentRuleLists()
        for l in lists { controller.add(l) }
        attachedKey = key
    }

    private func rebuildScripts() {
        controller.removeAllUserScripts()
        // 主框架：按 hostname 分发预先生成好的代码；没准备到（异常路径）就向原生要
        var map: [String] = []
        for p in prepared {
            map.append("\(MioJS.string(p.host)):function(){\n\(p.code)\n}")
        }
        let main = """
        (function(){if(window.top!==window)return;var M={\(map.joined(separator: ",\n"))};var h=location.hostname.toLowerCase();var f=M[h];if(f){try{f();}catch(e){}}else if(/^https?:$/.test(location.protocol)){try{window.webkit.messageHandlers.\(Self.messageName).postMessage({type:'main',url:location.href});}catch(e){}}})();
        """
        controller.addUserScript(WKUserScript(source: main, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let frames = """
        (function(){if(window.top===window)return;if(!/^https?:$/.test(location.protocol))return;try{window.webkit.messageHandlers.\(Self.messageName).postMessage({type:'frame',url:location.href});}catch(e){}})();
        """
        controller.addUserScript(WKUserScript(source: frames, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        for s in extraScripts { controller.addUserScript(s) }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.messageName, let webView = webView, isActiveForCurrentPage,
              let body = message.body as? [String: Any], let s = body["url"] as? String, let url = URL(string: s) else { return }
        let top = (body["type"] as? String) == "main" ? nil : webView.url
        guard let code = MioAdblock.shared.pageScript(for: url, topURL: top) else { return }
        webView.evaluateJavaScript(code, in: message.frameInfo, in: .page, completionHandler: nil)
    }
}

extension MioAdblock {
    /// 检查工具用：与内置浏览器主框架注入完全相同的代码
    static func pageScriptForCheck(_ url: URL) -> String? { shared.pageScript(for: url, topURL: nil) }
}
