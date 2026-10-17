// MioUserScriptCore.swift — 用户脚本管理器的纯逻辑（只依赖 Foundation：Linux 上 swift test 也能跑）
//
// - ==UserScript== 元数据解析（@name @namespace @version @description @match @include @exclude @exclude-match
//   @run-at @grant @require @resource @connect @noframes @updateURL @downloadURL …）
// - @match（Chrome match pattern）/ @include / @exclude（glob，或 /正则/）→ 正则源码（Swift 与注入页面的 JS 用同一份）
// - 版本号比较、@connect 判定、安装来源 URL 规范化（GitHub blob → raw、Greasy Fork 脚本页 → 安装地址）
// - 脚本与 GM 存储（按脚本隔离）的文件持久化
// - 生成注入页面的代码：运行时（MIO_JS_BEGIN userscriptRuntime）+ 配置 + 脚本本体（@require 内联在同一作用域）
//
// UIKit / WebKit 部分（安装界面、WKContentWorld 注入、GM_xmlhttpRequest 代发）在 MioUserScripts.swift。

import Foundation

// MARK: - Metadata

public enum MioUserScriptRunAt: String, Codable, Equatable {
    case documentStart = "document-start"
    case documentEnd = "document-end"
    case documentIdle = "document-idle"

    public init(meta value: String?) {
        switch (value ?? "").trimmingCharacters(in: .whitespaces).lowercased() {
        case "document-start": self = .documentStart
        case "document-end", "document-body": self = .documentEnd
        default: self = .documentIdle   // 缺省与 Tampermonkey 一致：document-idle
        }
    }
}

public struct MioUserScriptMeta: Codable, Equatable {
    public var name: String
    public var localizedNames: [String: String] = [:]
    public var namespace: String = ""
    public var version: String = ""
    public var description: String = ""
    public var author: String = ""
    public var matches: [String] = []
    public var includes: [String] = []
    public var excludes: [String] = []
    public var excludeMatches: [String] = []
    public var runAt: MioUserScriptRunAt = .documentIdle
    public var grants: [String] = []
    public var requires: [String] = []
    /// @resource name url
    public var resources: [String: String] = [:]
    public var connects: [String] = []
    public var noframes: Bool = false
    public var updateURL: String?
    public var downloadURL: String?
    public var homepage: String?
    public var icon: String?
    /// 原始元数据块（GM_info.scriptMetaStr）
    public var header: String = ""

    /// 没有 @grant 或 @grant none：脚本跑在页面世界（与页面共享 window），不提供需要原生的 GM API
    public var grantsNone: Bool {
        let g = grants.filter { !$0.isEmpty }
        return g.isEmpty || g.contains("none")
    }

    /// 显示名：优先 @name:zh-CN / zh-Hans / zh
    public var displayName: String {
        for key in ["zh-CN", "zh-Hans", "zh-cn", "zh"] {
            if let n = localizedNames[key], !n.isEmpty { return n }
        }
        return name
    }

    /// 脚本身份：与 Tampermonkey 相同，用 @name + @namespace（同身份再安装 = 更新）
    public var identity: String { "\(namespace)\u{1F}\(name)" }
}

public enum MioUserScriptError: Error, Equatable, LocalizedError {
    case noMetadataBlock
    case missingName
    case tooLarge(Int)
    case download(String)
    case notUserScript

    public var errorDescription: String? {
        switch self {
        case .noMetadataBlock: return "没有找到 // ==UserScript== … // ==/UserScript== 元数据块"
        case .missingName: return "元数据缺少 @name"
        case .tooLarge(let n): return "文件太大（\(n / 1024) KB）"
        case .download(let s): return "下载失败：\(s)"
        case .notUserScript: return "不是用户脚本"
        }
    }
}

public enum MioUserScriptParser {
    public static let maxScriptBytes = 5 * 1024 * 1024

    /// 解析元数据块。键大小写不敏感（@RUN-AT 也认）；未知键忽略
    public static func parse(_ code: String) throws -> MioUserScriptMeta {
        guard code.utf8.count <= maxScriptBytes else { throw MioUserScriptError.tooLarge(code.utf8.count) }
        let lines = code.components(separatedBy: .newlines)
        var inBlock = false
        var found = false
        var headerLines: [String] = []
        var meta = MioUserScriptMeta(name: "")
        var sawName = false
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if !inBlock {
                if isMarker(line, "==UserScript==") { inBlock = true; headerLines.append(raw) }
                continue
            }
            headerLines.append(raw)
            if isMarker(line, "==/UserScript==") { found = true; break }
            guard line.hasPrefix("//") else { continue }
            let body = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            guard body.hasPrefix("@") else { continue }
            let rest = body.dropFirst()
            let keyEnd = rest.firstIndex(where: { $0 == " " || $0 == "\t" }) ?? rest.endIndex
            let key = String(rest[rest.startIndex..<keyEnd])
            let value = String(rest[keyEnd...]).trimmingCharacters(in: .whitespaces)
            apply(key: key, value: value, to: &meta, sawName: &sawName)
        }
        guard found else { throw MioUserScriptError.noMetadataBlock }
        guard sawName, !meta.name.isEmpty else { throw MioUserScriptError.missingName }
        meta.header = headerLines.joined(separator: "\n")
        return meta
    }

    private static func isMarker(_ line: String, _ marker: String) -> Bool {
        guard line.hasPrefix("//") else { return false }
        return line.dropFirst(2).trimmingCharacters(in: .whitespaces).hasPrefix(marker)
    }

    private static func apply(key rawKey: String, value: String, to m: inout MioUserScriptMeta, sawName: inout Bool) {
        // @name:zh-CN 之类的本地化键
        let parts = rawKey.split(separator: ":", maxSplits: 1).map(String.init)
        let key = parts[0].lowercased()
        let locale = parts.count > 1 ? parts[1] : nil
        switch key {
        case "name":
            if let l = locale { m.localizedNames[l] = value } else { m.name = value; sawName = true }
        case "description":
            if locale == nil { m.description = value }
        case "namespace": m.namespace = value
        case "version": m.version = value
        case "author": m.author = value
        case "match": if !value.isEmpty { m.matches.append(value) }
        case "include": if !value.isEmpty { m.includes.append(value) }
        case "exclude": if !value.isEmpty { m.excludes.append(value) }
        case "exclude-match": if !value.isEmpty { m.excludeMatches.append(value) }
        case "run-at": m.runAt = MioUserScriptRunAt(meta: value)
        case "grant": if !value.isEmpty { m.grants.append(value) }
        case "require": if !value.isEmpty { m.requires.append(value) }
        case "resource":
            let kv = value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if kv.count >= 2 { m.resources[kv[0]] = kv[kv.count - 1] }
        case "connect": if !value.isEmpty { m.connects.append(value) }
        case "noframes": m.noframes = true
        case "updateurl": m.updateURL = value.isEmpty ? nil : value
        case "downloadurl", "installurl": m.downloadURL = value.isEmpty ? nil : value
        case "homepage", "homepageurl", "website", "source": if m.homepage == nil, !value.isEmpty { m.homepage = value }
        case "icon", "iconurl", "defaulticon": if m.icon == nil, !value.isEmpty { m.icon = value }
        default: break
        }
    }
}

// MARK: - URL patterns

/// 编译好的 URL 规则：source 是 JS / ICU 都认的正则源码（不含内联标志），ignoreCase 单独存
public struct MioURLRule: Codable, Equatable {
    public var source: String
    public var ignoreCase: Bool

    public func matches(_ url: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: source, options: ignoreCase ? [.caseInsensitive] : []) else { return false }
        return re.firstMatch(in: url, options: [], range: NSRange(url.startIndex..., in: url)) != nil
    }
}

public enum MioUserScriptPattern {
    /// `.tld`（@include 的 Greasemonkey 扩展）：任意顶级域，包括 co.uk 这类二级
    public static let tldRegex = #"\.(?:[a-z0-9-]{2,63}|(?:com?|net|org|gov|edu|ac|ne|or|go)\.[a-z]{2})"#

    /// 正则元字符转义（JS 与 ICU 通用的写法）
    public static func escape(_ s: String) -> String {
        var out = ""
        for ch in s {
            if "\\^$.|?*+()[]{}/".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// Chrome match pattern（@match / @exclude-match）。规则：
    /// - `<all_urls>`：http / https / file
    /// - scheme：`*` = http 或 https；也接受 http / https / file / ftp / ws / wss
    /// - host：`*` 任意；`*.example.com` = example.com 及其子域；其余为字面量（不允许别处出现 *）；可带端口，不带端口时任意端口
    /// - path：必须以 / 开头，`*` 匹配任意字符（含 /）；与 Chrome 一样对「路径 + 查询串」匹配，不含 #片段
    /// 无效模式返回 nil。
    public static func matchPattern(_ pattern: String) -> MioURLRule? {
        let p = pattern.trimmingCharacters(in: .whitespaces)
        if p == "<all_urls>" { return MioURLRule(source: #"^(?:https?|file):\/\/.*$"#, ignoreCase: false) }
        guard let sepRange = p.range(of: "://") else { return nil }
        let scheme = p[p.startIndex..<sepRange.lowerBound].lowercased()
        let schemeRe: String
        switch scheme {
        case "*": schemeRe = "https?"
        case "http", "https", "file", "ftp", "ws", "wss": schemeRe = scheme
        default: return nil
        }
        let rest = p[sepRange.upperBound...]
        let slash = rest.firstIndex(of: "/")
        let hostPart = String(slash.map { rest[rest.startIndex..<$0] } ?? rest[...]).lowercased()
        let pathPart = slash.map { String(rest[$0...]) } ?? "/*"   // 宽松：缺路径当作 /*
        var hostRe: String
        if scheme == "file" {
            hostRe = ""
            guard hostPart.isEmpty else { return nil }
        } else {
            guard !hostPart.isEmpty else { return nil }
            var host = hostPart
            var portRe = #"(?::\d+)?"#
            if let colon = host.lastIndex(of: ":"), !host.hasPrefix("[") || host.contains("]:") {
                let port = String(host[host.index(after: colon)...])
                if port == "*" || (!port.isEmpty && port.allSatisfy(\.isNumber)) {
                    portRe = port == "*" ? #"(?::\d+)?"# : ":" + port
                    host = String(host[host.startIndex..<colon])
                }
            }
            var tld = false
            if host.hasSuffix(".tld") { tld = true; host = String(host.dropLast(4)) }
            if host == "*" {
                hostRe = #"[^\/:?#]+"#
            } else if host.hasPrefix("*.") {
                let base = String(host.dropFirst(2))
                guard !base.isEmpty, !base.contains("*") else { return nil }
                hostRe = #"(?:[^\/:?#]+\.)?"# + escape(base)
            } else {
                guard !host.contains("*") else { return nil }
                hostRe = escape(host)
            }
            if tld { hostRe += tldRegex }
            hostRe += portRe
        }
        guard pathPart.hasPrefix("/") else { return nil }
        let pathRe = pathPart.split(separator: "*", omittingEmptySubsequences: false).map { escape(String($0)) }.joined(separator: ".*")
        return MioURLRule(source: "^" + schemeRe + #":\/\/"# + hostRe + pathRe + "$", ignoreCase: false)
    }

    /// @include / @exclude：`/正则/标志` 原样使用（只认 i 标志）；否则 glob：`*` 任意字符，`.tld` 任意顶级域，其余字面量，
    /// 整个 URL（含查询串和 #）匹配，大小写不敏感（Greasemonkey 行为）
    public static func glob(_ pattern: String) -> MioURLRule? {
        let p = pattern.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return nil }
        if p.count >= 2, p.hasPrefix("/"), let last = p.lastIndex(of: "/"), last != p.startIndex {
            let flags = p[p.index(after: last)...]
            if flags.allSatisfy({ "igmsuy".contains($0) }) {
                let src = String(p[p.index(after: p.startIndex)..<last])
                guard !src.isEmpty, (try? NSRegularExpression(pattern: src)) != nil else { return nil }
                return MioURLRule(source: src, ignoreCase: flags.contains("i"))
            }
        }
        if p == "*" { return MioURLRule(source: "^.*$", ignoreCase: true) }
        var re = ""
        var i = p.startIndex
        while i < p.endIndex {
            let ch = p[i]
            if ch == "*" {
                re += ".*"
            } else if ch == ".", p[i...].lowercased().hasPrefix(".tld"),
                      p.index(i, offsetBy: 4) == p.endIndex || "/:?#".contains(p[p.index(i, offsetBy: 4)]) {
                re += tldRegex
                i = p.index(i, offsetBy: 4)
                continue
            } else {
                re += escape(String(ch))
            }
            i = p.index(after: i)
        }
        return MioURLRule(source: "^" + re + "$", ignoreCase: true)
    }
}

/// 一个脚本的全部 URL 规则（注入时交给 JS 判定；Swift 侧用于单测、列表页预览）
public struct MioUserScriptRules: Codable, Equatable {
    public var matches: [MioURLRule]
    public var includes: [MioURLRule]
    public var excludes: [MioURLRule]
    public var excludeMatches: [MioURLRule]
    /// 没有任何 @match / @include：与 Greasemonkey 一致，视为所有网页（http / https）
    public var matchAll: Bool
    public var invalid: [String]

    public init(meta: MioUserScriptMeta) {
        var bad: [String] = []
        func compile(_ list: [String], _ f: (String) -> MioURLRule?) -> [MioURLRule] {
            list.compactMap { p in
                if let r = f(p) { return r }
                bad.append(p)
                return nil
            }
        }
        matches = compile(meta.matches, MioUserScriptPattern.matchPattern)
        includes = compile(meta.includes, MioUserScriptPattern.glob)
        excludes = compile(meta.excludes, MioUserScriptPattern.glob)
        excludeMatches = compile(meta.excludeMatches, MioUserScriptPattern.matchPattern)
        matchAll = meta.matches.isEmpty && meta.includes.isEmpty
        invalid = bad
    }

    /// 与注入运行时（JS）相同的判定：match 对去掉 # 的 URL，include / exclude 对完整 URL
    public func matches(_ url: String) -> Bool {
        let noHash = url.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? url
        let lower = url.lowercased()
        let included = matchAll
            ? (lower.hasPrefix("http://") || lower.hasPrefix("https://"))
            : (matches.contains { $0.matches(noHash) } || includes.contains { $0.matches(url) })
        guard included else { return false }
        if excludes.contains(where: { $0.matches(url) }) { return false }
        if excludeMatches.contains(where: { $0.matches(noHash) }) { return false }
        return true
    }
}

// MARK: - Versions / @connect / install URLs

public enum MioUserScriptVersion {
    /// Tampermonkey 风格：按 . 分段，每段先比数字再比后缀；后缀为空的大于有后缀的（1.0 > 1.0b）；缺的段当 0
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let pa = a.trimmingCharacters(in: .whitespaces).split(separator: ".").map(String.init)
        let pb = b.trimmingCharacters(in: .whitespaces).split(separator: ".").map(String.init)
        for i in 0..<max(pa.count, pb.count) {
            let (na, sa) = split(i < pa.count ? pa[i] : "0")
            let (nb, sb) = split(i < pb.count ? pb[i] : "0")
            if na != nb { return na < nb ? .orderedAscending : .orderedDescending }
            if sa != sb {
                if sa.isEmpty { return .orderedDescending }
                if sb.isEmpty { return .orderedAscending }
                return sa < sb ? .orderedAscending : .orderedDescending
            }
        }
        return .orderedSame
    }

    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }

    private static func split(_ s: String) -> (Int, String) {
        let digits = s.prefix(while: \.isNumber)
        return (Int(digits.prefix(18)) ?? 0, String(s.dropFirst(digits.count)))
    }
}

public enum MioUserScriptConnect {
    public enum Verdict: Equatable {
        /// 与发起请求的页面同主机：不询问
        case sameOrigin
        /// 在 @connect 里：首次询问用户
        case declared
        /// 不在 @connect 里：拒绝
        case undeclared
    }

    public static func normalizeHost(_ s: String) -> String {
        var h = s.trimmingCharacters(in: .whitespaces).lowercased()
        if let r = h.range(of: "://") { h = String(h[r.upperBound...]) }
        if let i = h.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { h = String(h[h.startIndex..<i]) }
        if h.hasPrefix("["), let close = h.firstIndex(of: "]") {
            h = String(h[h.index(after: h.startIndex)..<close])
        } else if let colon = h.lastIndex(of: ":"), h.filter({ $0 == ":" }).count == 1 {
            h = String(h[h.startIndex..<colon])
        }
        if h.hasPrefix("*.") { h = String(h.dropFirst(2)) }
        if h.hasPrefix(".") { h = String(h.dropFirst()) }
        if h.hasSuffix(".") { h = String(h.dropLast()) }
        return h
    }

    /// host 是否被某条 @connect 覆盖：`*` 任意；`self` = 页面主机；域名 = 自身及子域；IP / localhost 精确匹配
    public static func isDeclared(host: String, connects: [String], pageHost: String?) -> Bool {
        let h = normalizeHost(host)
        guard !h.isEmpty else { return false }
        for c in connects {
            let raw = c.trimmingCharacters(in: .whitespaces).lowercased()
            if raw == "*" { return true }
            let d = raw == "self" ? normalizeHost(pageHost ?? "") : normalizeHost(raw)
            guard !d.isEmpty else { continue }
            if h == d || h.hasSuffix("." + d) { return true }
        }
        return false
    }

    public static func verdict(target: String, pageHost: String?, connects: [String]) -> Verdict {
        let h = normalizeHost(target)
        if let p = pageHost, !p.isEmpty, normalizeHost(p) == h { return .sameOrigin }
        return isDeclared(host: h, connects: connects, pageHost: pageHost) ? .declared : .undeclared
    }
}

public enum MioUserScriptSource {
    /// 用户输入的安装地址 → 实际下载地址：
    /// - github.com/<u>/<r>/blob/<ref>/<path> → raw.githubusercontent.com/<u>/<r>/<ref>/<path>
    /// - greasyfork.org / sleazyfork.org 脚本页（/<locale>/scripts/<id>-slug）→ /scripts/<id>/code/script.user.js
    /// - 其余 http(s) 原样
    public static func installURL(from input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var comps = URLComponents(string: text), let scheme = comps.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = comps.host?.lowercased(), !host.isEmpty else { return nil }
        let segs = comps.path.split(separator: "/").map(String.init)
        if host == "github.com" || host == "www.github.com", segs.count >= 5, segs[2] == "blob" || segs[2] == "raw" {
            var raw = URLComponents()
            raw.scheme = "https"
            raw.host = "raw.githubusercontent.com"
            raw.path = "/" + ([segs[0], segs[1]] + segs[3...]).joined(separator: "/")
            return raw.url
        }
        if ["greasyfork.org", "www.greasyfork.org", "sleazyfork.org", "www.sleazyfork.org"].contains(host) {
            // [locale]/scripts/<id>[-slug][/...]
            var i = 0
            if segs.count > 0, segs[0] != "scripts" { i = 1 }
            if segs.count > i + 1, segs[i] == "scripts" {
                let idPart = segs[i + 1]
                let id = idPart.prefix(while: \.isNumber)
                let isCode = segs.count > i + 2 && segs[i + 2] == "code"
                if !id.isEmpty, !isCode || !(segs.last ?? "").hasSuffix(".user.js") {
                    var g = URLComponents()
                    g.scheme = "https"
                    g.host = host.replacingOccurrences(of: "www.", with: "")
                    g.path = "/scripts/\(id)/code/script.user.js"
                    return g.url
                }
            }
        }
        comps.fragment = nil
        return comps.url
    }

    /// 浏览器里打开的地址是否像用户脚本（*.user.js），用来弹出「安装」提示
    public static func looksLikeUserScript(_ url: URL) -> Bool {
        guard let s = url.scheme?.lowercased(), s == "http" || s == "https" else { return false }
        return url.path.lowercased().hasSuffix(".user.js")
    }

    /// 检查更新用的地址：@updateURL（通常是 .meta.js）> @downloadURL > 安装来源
    public static func updateCheckURL(meta: MioUserScriptMeta, sourceURL: String?) -> URL? {
        for s in [meta.updateURL, meta.downloadURL, sourceURL] {
            if let s = s, let u = URL(string: s), let sc = u.scheme?.lowercased(), sc == "http" || sc == "https" { return u }
        }
        return nil
    }

    /// 下载新版本用的地址：@downloadURL > 安装来源 > @updateURL（不是 .meta.js 时）
    public static func downloadURL(meta: MioUserScriptMeta, sourceURL: String?) -> URL? {
        var candidates = [meta.downloadURL, sourceURL]
        if let u = meta.updateURL, !u.lowercased().hasSuffix(".meta.js") { candidates.append(u) }
        for s in candidates {
            if let s = s, let u = URL(string: s), let sc = u.scheme?.lowercased(), sc == "http" || sc == "https" { return u }
        }
        return nil
    }
}

// MARK: - Model + persistence

public struct MioUserScript: Codable, Equatable, Identifiable {
    public var id: String
    public var meta: MioUserScriptMeta
    public var code: String
    /// @require URL → 代码（安装 / 更新时下载缓存，注入时内联）
    public var requireCache: [String: String] = [:]
    /// @resource name → 文本内容
    public var resourceCache: [String: String] = [:]
    public var enabled: Bool = true
    public var sourceURL: String?
    public var installedAt: Date
    public var updatedAt: Date
    public var lastUpdateCheck: Date?
    /// GM_xmlhttpRequest 跨域：host → 用户的「总是允许 / 拒绝」
    public var connectDecisions: [String: Bool] = [:]

    public var rules: MioUserScriptRules { MioUserScriptRules(meta: meta) }
    /// 跑在独立的 WKContentWorld 里（有 @grant）
    public var isolated: Bool { !meta.grantsNone }
    public var worldName: String { "mio.userscript.\(id)" }
}

/// 待安装（已解析、依赖已下载）
public struct MioUserScriptPackage: Equatable {
    public var meta: MioUserScriptMeta
    public var code: String
    public var requireCache: [String: String]
    public var resourceCache: [String: String]
    public var sourceURL: String?
}

/// 所有脚本存一个 JSON（scripts.json）；GM 值每个脚本一个文件（values/<id>.json）
public final class MioUserScriptStore {
    public let directory: URL
    public private(set) var scripts: [MioUserScript] = []
    public let values: MioUserScriptValueStore
    private let now: () -> Date

    public init(directory: URL, now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.now = now
        values = MioUserScriptValueStore(directory: directory.appendingPathComponent("values", isDirectory: true))
        load()
    }

    private var file: URL { directory.appendingPathComponent("scripts.json") }

    private func load() {
        guard let data = try? Data(contentsOf: file) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        scripts = (try? dec.decode([MioUserScript].self, from: data)) ?? []
    }

    private func save() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(scripts) else { return }
        try? data.write(to: file, options: .atomic)
    }

    public func script(id: String) -> MioUserScript? { scripts.first { $0.id == id } }

    public func existing(for meta: MioUserScriptMeta) -> MioUserScript? { scripts.first { $0.meta.identity == meta.identity } }

    /// 安装；同 @name + @namespace 已存在时就地更新（保留 id、启用状态、GM 值；@connect 里已不再声明的授权丢弃）
    @discardableResult
    public func install(_ pkg: MioUserScriptPackage) -> MioUserScript {
        let t = now()
        if let i = scripts.firstIndex(where: { $0.meta.identity == pkg.meta.identity }) {
            var s = scripts[i]
            s.meta = pkg.meta
            s.code = pkg.code
            s.requireCache = pkg.requireCache
            s.resourceCache = pkg.resourceCache
            if let src = pkg.sourceURL { s.sourceURL = src }
            s.updatedAt = t
            s.connectDecisions = s.connectDecisions.filter { MioUserScriptConnect.isDeclared(host: $0.key, connects: pkg.meta.connects, pageHost: nil) }
            scripts[i] = s
            save()
            return s
        }
        let s = MioUserScript(id: UUID().uuidString.lowercased(), meta: pkg.meta, code: pkg.code, requireCache: pkg.requireCache,
                              resourceCache: pkg.resourceCache, enabled: true, sourceURL: pkg.sourceURL, installedAt: t, updatedAt: t)
        scripts.append(s)
        save()
        return s
    }

    public func setEnabled(_ id: String, _ on: Bool) {
        guard let i = scripts.firstIndex(where: { $0.id == id }), scripts[i].enabled != on else { return }
        scripts[i].enabled = on
        save()
    }

    public func setConnectDecision(_ id: String, host: String, allow: Bool?) {
        guard let i = scripts.firstIndex(where: { $0.id == id }) else { return }
        let h = MioUserScriptConnect.normalizeHost(host)
        if let a = allow { scripts[i].connectDecisions[h] = a } else { scripts[i].connectDecisions.removeValue(forKey: h) }
        save()
    }

    public func markChecked(_ id: String) {
        guard let i = scripts.firstIndex(where: { $0.id == id }) else { return }
        scripts[i].lastUpdateCheck = now()
        save()
    }

    public func delete(_ id: String) {
        scripts.removeAll { $0.id == id }
        values.removeAll(id)
        save()
    }

    public func move(from: Int, to: Int) {
        guard scripts.indices.contains(from), to >= 0, to < scripts.count else { return }
        let s = scripts.remove(at: from)
        scripts.insert(s, at: to)
        save()
    }
}

/// GM_getValue / GM_setValue 的持久化：按脚本 id 分文件，值是 JS 端 JSON.stringify 后的字符串
public final class MioUserScriptValueStore {
    public static let maxBytesPerScript = 5 * 1024 * 1024

    public let directory: URL
    private var cache: [String: [String: String]] = [:]
    private let lock = NSLock()

    public init(directory: URL) { self.directory = directory }

    private func file(_ id: String) -> URL {
        // id 只允许安全字符，防止路径穿越
        let safe = String(id.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" }.map(Character.init))
        return directory.appendingPathComponent("\(safe.isEmpty ? "_" : safe).json")
    }

    private func loaded(_ id: String) -> [String: String] {
        if let c = cache[id] { return c }
        var v: [String: String] = [:]
        if let data = try? Data(contentsOf: file(id)), let obj = try? JSONDecoder().decode([String: String].self, from: data) { v = obj }
        cache[id] = v
        return v
    }

    private func persist(_ id: String, _ v: [String: String]) {
        cache[id] = v
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if v.isEmpty {
            try? FileManager.default.removeItem(at: file(id))
            return
        }
        if let data = try? JSONEncoder().encode(v) { try? data.write(to: file(id), options: .atomic) }
    }

    public func all(_ id: String) -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        return loaded(id)
    }

    public func get(_ id: String, _ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return loaded(id)[key]
    }

    /// 超出单脚本上限时拒绝（返回 false）
    @discardableResult
    public func set(_ id: String, _ key: String, _ json: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var v = loaded(id)
        v[key] = json
        let size = v.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
        guard size <= Self.maxBytesPerScript else { return false }
        persist(id, v)
        return true
    }

    public func delete(_ id: String, _ key: String) {
        lock.lock(); defer { lock.unlock() }
        var v = loaded(id)
        guard v.removeValue(forKey: key) != nil else { return }
        persist(id, v)
    }

    public func keys(_ id: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return loaded(id).keys.sorted()
    }

    public func removeAll(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        cache[id] = [:]
        try? FileManager.default.removeItem(at: file(id))
    }
}

// MARK: - Injection source

public enum MioUserScriptRuntime {
    /// 原生消息通道名（只注册在各脚本自己的 WKContentWorld 里，页面世界拿不到）
    public static let handlerName = "mioUserScript"

    /// 注入页面的完整代码：运行时(配置, function(GM API…){ @require…; 脚本 })
    public static func source(for s: MioUserScript, values: [String: String], appVersion: String, platform: String = "ios") -> String {
        let rules = s.rules
        func ruleList(_ r: [MioURLRule]) -> [[String: Any]] { r.map { ["s": $0.source, "i": $0.ignoreCase] } }
        var resources: [String: String] = [:]
        for (k, _) in s.meta.resources { resources[k] = s.resourceCache[k] ?? "" }
        let info: [String: Any] = [
            "script": [
                "name": s.meta.name,
                "namespace": s.meta.namespace,
                "version": s.meta.version,
                "description": s.meta.description,
                "author": s.meta.author,
                "matches": s.meta.matches,
                "includes": s.meta.includes,
                "excludes": s.meta.excludes,
                "grant": s.meta.grants,
                "requires": s.meta.requires,
                "resources": s.meta.resources.map { ["name": $0.key, "url": $0.value] },
                "run-at": s.meta.runAt.rawValue,
                "noframes": s.meta.noframes,
                "connects": s.meta.connects,
                "uuid": s.id,
            ] as [String: Any],
            "scriptMetaStr": s.meta.header,
            "scriptHandler": "Mio",
            "version": appVersion,
            "platform": platform,
        ]
        let config: [String: Any] = [
            "id": s.id,
            "name": s.meta.displayName,
            "isolated": s.isolated,
            "handler": handlerName,
            "runAt": s.meta.runAt.rawValue,
            "noframes": s.meta.noframes,
            "grants": s.meta.grants,
            "match": ruleList(rules.matches),
            "include": ruleList(rules.includes),
            "exclude": ruleList(rules.excludes),
            "excludeMatch": ruleList(rules.excludeMatches),
            "matchAll": rules.matchAll,
            "values": s.isolated ? values : [:],
            "resources": resources,
            "info": info,
        ]
        let json = (try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        var body = ""
        for url in s.meta.requires {
            if let code = s.requireCache[url] {
                body += "// @require \(url.replacingOccurrences(of: "\n", with: ""))\n\(code)\n;\n"
            }
        }
        body += s.code
        return "\(runtimeScript)(\(json), function(\(apiParams)){\n\(body)\n});\n"
    }

    /// 运行时传给脚本包装函数的参数（顺序与 runtimeScript 里 main.call 一致）
    public static let apiParams = "GM, GM_info, unsafeWindow, GM_addStyle, GM_getValue, GM_setValue, GM_deleteValue, GM_listValues, GM_xmlhttpRequest, GM_openInTab, GM_setClipboard, GM_registerMenuCommand, GM_unregisterMenuCommand, GM_notification, GM_getResourceText, GM_getResourceURL, GM_addValueChangeListener, GM_removeValueChangeListener, GM_log, GM_addElement"

    // MIO_JS_BEGIN userscriptRuntime
    public static let runtimeScript = #"""
    (function (C, main) {
      'use strict';
      var w = window;
      var d = document;
      var isTop;
      try { isTop = w.top === w; } catch (e) { isTop = false; }
      if (C.noframes && !isTop) return;
      if (!/^(https?|file):$/.test(location.protocol)) return;
      var href = String(location.href);
      var noHash = href.split('#')[0];
      function test(rules, url) {
        for (var i = 0; i < (rules || []).length; i++) {
          try { if (new RegExp(rules[i].s, rules[i].i ? 'i' : '').test(url)) return true; } catch (e) {}
        }
        return false;
      }
      var hit = C.matchAll ? /^https?:/i.test(href) : (test(C.match, noHash) || test(C.include, href));
      if (!hit || test(C.exclude, href) || test(C.excludeMatch, noHash)) return;
      var ranKey = '__mioUserScriptRan';
      try {
        var ran = w[ranKey] || (Object.defineProperty(w, ranKey, { value: {}, configurable: false }), w[ranKey]);
        if (ran[C.id]) return;
        ran[C.id] = 1;
      } catch (e) {}

      var label = '[Mio 用户脚本] ' + C.name;
      var handler = null;
      try { handler = C.isolated && w.webkit && w.webkit.messageHandlers && w.webkit.messageHandlers[C.handler] || null; } catch (e) { handler = null; }
      // Android（WebMessageListener，页面世界 + 每脚本 token）/ Windows（Electron 隔离 world 里 contextBridge 暴露的 invoke）
      if (!handler && C.isolated && C.bridge) handler = nativeBridge(C.bridge);
      function nativeBridge(name) {
        var b = null;
        try { b = w[name]; } catch (e) { b = null; }
        if (!b) return null;
        var def = Object.defineProperty, str = JSON.stringify, parse = JSON.parse;
        if (typeof b.invoke === 'function') {
          var inv = b.invoke;
          return { postMessage: function (m) { return inv(m); } };
        }
        if (typeof b.postMessage !== 'function') return null;
        var send = b.postMessage.bind(b);
        var pending = {};
        var n = 0;
        var onMsg = function (ev) {
          var r;
          try { r = parse(ev && ev.data); } catch (e) { return; }
          if (!r || r.sid !== C.id || !pending[r.seq]) return;
          var p = pending[r.seq];
          delete pending[r.seq];
          clearTimeout(p[2]);
          if (r.error) p[1](new Error(String(r.error))); else p[0](r.result);
        };
        if (typeof b.addEventListener === 'function') b.addEventListener('message', onMsg); else b.onmessage = onMsg;
        return {
          postMessage: function (m) {
            return new Promise(function (resolve, reject) {
              var seq = ++n;
              var timer = setTimeout(function () { if (pending[seq]) { delete pending[seq]; reject(new Error('timeout')); } }, 120000);
              pending[seq] = [resolve, reject, timer];
              def(m, 'seq', { value: seq, enumerable: true });
              def(m, 'token', { value: String(C.token || ''), enumerable: true });
              try { send(str(m)); } catch (e) { delete pending[seq]; clearTimeout(timer); reject(e); }
            });
          }
        };
      }
      function post(op, payload) {
        var msg = payload || {};
        msg.op = op;
        msg.id = C.id;
        if (!handler) return Promise.reject(new Error('GM API 不可用（脚本未 @grant 或运行在页面世界）'));
        try { return Promise.resolve(handler.postMessage(msg)); } catch (e) { return Promise.reject(e); }
      }

      // ---- GM_addStyle / GM_addElement（DOM API，不用 innerHTML：兼容 Trusted Types）
      function whenRoot(fn) {
        var r = d.head || d.documentElement;
        if (r) { fn(r); return; }
        var mo = new MutationObserver(function () {
          var x = d.head || d.documentElement;
          if (x) { mo.disconnect(); fn(x); }
        });
        mo.observe(d, { childList: true, subtree: true });
      }
      function addStyle(css) {
        var s = d.createElement('style');
        s.setAttribute('data-mio-userscript', C.id);
        s.textContent = String(css);
        whenRoot(function (r) { r.appendChild(s); });
        return s;
      }
      function addElement(parent, tag, attrs) {
        if (typeof parent === 'string') { attrs = tag; tag = parent; parent = null; }
        var el = d.createElement(String(tag));
        var a = attrs || {};
        Object.keys(a).forEach(function (k) {
          if (k === 'textContent') el.textContent = a[k];
          else el.setAttribute(k, a[k]);
        });
        if (parent) parent.appendChild(el); else whenRoot(function (r) { r.appendChild(el); });
        return el;
      }

      // ---- 存储（原生按脚本隔离持久化；这里是本页的同步缓存）
      var V = C.values || {};
      var listeners = {};
      var nextListener = 1;
      function notify(key, oldV, newV) {
        Object.keys(listeners).forEach(function (k) {
          var l = listeners[k];
          if (l.key === key) { try { l.fn(key, oldV, newV, false); } catch (e) {} }
        });
      }
      function getValue(key, def) {
        key = String(key);
        if (!Object.prototype.hasOwnProperty.call(V, key)) return def;
        try { return JSON.parse(V[key]); } catch (e) { return def; }
      }
      function setValue(key, value) {
        key = String(key);
        if (value === undefined) { deleteValue(key); return; }
        var old = getValue(key);
        var json = JSON.stringify(value);
        if (json === undefined) return;
        V[key] = json;
        post('setValue', { key: key, value: json }).catch(function (e) { console.warn(label, 'GM_setValue', e); });
        notify(key, old, value);
      }
      function deleteValue(key) {
        key = String(key);
        if (!Object.prototype.hasOwnProperty.call(V, key)) return;
        var old = getValue(key);
        delete V[key];
        post('deleteValue', { key: key }).catch(function () {});
        notify(key, old, undefined);
      }
      function listValues() { return Object.keys(V); }
      function addValueChangeListener(key, fn) {
        var id = nextListener++;
        listeners[id] = { key: String(key), fn: fn };
        return id;
      }
      function removeValueChangeListener(id) { delete listeners[id]; }

      // ---- GM_xmlhttpRequest（原生 URLSession 代发）
      var seq = 0;
      function b64encode(u8) {
        var s = '';
        for (var i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000));
        return btoa(s);
      }
      function b64decode(b64) {
        var s = atob(b64 || '');
        var u8 = new Uint8Array(s.length);
        for (var i = 0; i < s.length; i++) u8[i] = s.charCodeAt(i);
        return u8;
      }
      function encodeBody(data, headers) {
        if (data === undefined || data === null) return Promise.resolve(null);
        if (typeof data === 'string') return Promise.resolve({ text: data });
        if (typeof URLSearchParams !== 'undefined' && data instanceof URLSearchParams) {
          if (!hasHeader(headers, 'content-type')) headers['Content-Type'] = 'application/x-www-form-urlencoded;charset=UTF-8';
          return Promise.resolve({ text: data.toString() });
        }
        if (data instanceof ArrayBuffer) return Promise.resolve({ base64: b64encode(new Uint8Array(data)) });
        if (ArrayBuffer.isView(data)) return Promise.resolve({ base64: b64encode(new Uint8Array(data.buffer, data.byteOffset, data.byteLength)) });
        if ((typeof Blob !== 'undefined' && data instanceof Blob) || (typeof FormData !== 'undefined' && data instanceof FormData)) {
          var r = new Response(data);
          var ct = r.headers.get('content-type') || (data.type || '');
          if (ct && !hasHeader(headers, 'content-type')) headers['Content-Type'] = ct;
          return r.arrayBuffer().then(function (ab) { return { base64: b64encode(new Uint8Array(ab)) }; });
        }
        return Promise.resolve({ text: String(data) });
      }
      function hasHeader(h, name) {
        return Object.keys(h).some(function (k) { return k.toLowerCase() === name; });
      }
      function parseHeaders(raw) {
        var out = {};
        String(raw || '').split(/\r?\n/).forEach(function (line) {
          var i = line.indexOf(':');
          if (i > 0) out[line.slice(0, i).trim().toLowerCase()] = line.slice(i + 1).trim();
        });
        return out;
      }
      function xhr(details) {
        details = details || {};
        var reqId = C.id + ':' + (++seq);
        var state = { done: false, aborted: false };
        var headers = {};
        Object.keys(details.headers || {}).forEach(function (k) { headers[k] = String(details.headers[k]); });
        function fire(name, resp) {
          var fn = details[name];
          if (typeof fn === 'function') { try { fn.call(details, resp); } catch (e) { console.error(label, name, e); } }
        }
        function base(extra) {
          var r = { readyState: 4, status: 0, statusText: '', responseHeaders: '', response: null, responseText: '', responseXML: null, finalUrl: url, context: details.context };
          Object.keys(extra || {}).forEach(function (k) { r[k] = extra[k]; });
          return r;
        }
        var url;
        try { url = new URL(String(details.url), location.href).href; } catch (e) { url = String(details.url); }
        var handle = {
          abort: function () {
            if (state.done || state.aborted) return;
            state.aborted = true;
            post('xhrAbort', { reqId: reqId }).catch(function () {});
            var r = base({ error: 'aborted' });
            fire('onabort', r);
            fire('onloadend', r);
          }
        };
        fire('onloadstart', base({ readyState: 1 }));
        encodeBody(details.data, headers).then(function (body) {
          if (state.aborted) return null;
          return post('xhr', {
            reqId: reqId,
            method: String(details.method || 'GET').toUpperCase(),
            url: url,
            headers: headers,
            body: body,
            timeout: Number(details.timeout) || 0,
            anonymous: !!details.anonymous,
            responseType: String(details.responseType || ''),
            overrideMimeType: details.overrideMimeType ? String(details.overrideMimeType) : '',
            user: details.user ? String(details.user) : '',
            password: details.password ? String(details.password) : '',
            userAgent: navigator.userAgent
          });
        }).then(function (res) {
          if (state.aborted || !res) return;
          state.done = true;
          if (res.error) {
            var er = base({ error: res.error, status: 0, statusText: res.error });
            fire(res.timeout ? 'ontimeout' : 'onerror', er);
            fire('onloadend', er);
            return;
          }
          var type = String(details.responseType || '').toLowerCase();
          var text = typeof res.text === 'string' ? res.text : '';
          var hdrs = parseHeaders(res.headers);
          var mime = details.overrideMimeType || hdrs['content-type'] || '';
          var response = text;
          if (type === 'arraybuffer' || type === 'blob') {
            var u8 = b64decode(res.base64);
            response = type === 'blob' ? new Blob([u8], { type: mime }) : u8.buffer;
          } else if (type === 'json') {
            try { response = JSON.parse(text); } catch (e) { response = null; }
          }
          var r = base({ status: res.status, statusText: res.statusText || '', responseHeaders: res.headers || '', finalUrl: res.finalUrl || url, responseText: text, response: response });
          var xml = null;
          var xmlDone = false;
          Object.defineProperty(r, 'responseXML', {
            enumerable: true,
            get: function () {
              if (!xmlDone) {
                xmlDone = true;
                try {
                  var t = type === 'document' || /html/i.test(mime) ? 'text/html' : 'text/xml';
                  xml = new DOMParser().parseFromString(text, t);
                } catch (e) { xml = null; }
              }
              return xml;
            }
          });
          if (type === 'document') r.response = r.responseXML;
          fire('onreadystatechange', r);
          fire('onprogress', r);
          fire('onload', r);
          fire('onloadend', r);
        }, function (err) {
          if (state.aborted) return;
          state.done = true;
          var r = base({ error: String((err && err.message) || err), statusText: String((err && err.message) || err) });
          fire('onerror', r);
          fire('onloadend', r);
        });
        return handle;
      }
      function xhrPromise(details) {
        var h;
        var p = new Promise(function (resolve, reject) {
          var dd = {};
          Object.keys(details || {}).forEach(function (k) { dd[k] = details[k]; });
          var ol = dd.onload, oe = dd.onerror, ot = dd.ontimeout, oa = dd.onabort;
          dd.onload = function (r) { if (ol) ol(r); resolve(r); };
          dd.onerror = function (r) { if (oe) oe(r); reject(r); };
          dd.ontimeout = function (r) { if (ot) ot(r); reject(r); };
          dd.onabort = function (r) { if (oa) oa(r); reject(r); };
          h = xhr(dd);
        });
        p.abort = function () { if (h) h.abort(); };
        return p;
      }

      // ---- 其他 GM API
      function openInTab(url, opts) {
        var u;
        try { u = new URL(String(url), location.href).href; } catch (e) { u = String(url); }
        var active = true;
        if (typeof opts === 'boolean') active = !opts;
        else if (opts && (opts.active === false || opts.loadInBackground === true)) active = false;
        var tab = { closed: false, onclose: null, close: function () { tab.closed = true; } };
        post('openTab', { url: u, active: active }).catch(function (e) { console.warn(label, 'GM_openInTab', e); });
        return tab;
      }
      function setClipboard(data, info) {
        var type = typeof info === 'string' ? info : (info && (info.type || info.mimetype)) || 'text';
        return post('setClipboard', { data: String(data), type: String(type) }).catch(function (e) { console.warn(label, 'GM_setClipboard', e); });
      }
      var menu = {};
      var nextMenu = 1;
      function syncMenu() {
        if (!isTop) return;
        post('menu', { commands: Object.keys(menu).map(function (k) { return { id: String(k), name: menu[k].name }; }) }).catch(function () {});
      }
      function registerMenuCommand(name, fn) {
        var id = nextMenu++;
        menu[id] = { name: String(name), fn: fn };
        syncMenu();
        return id;
      }
      function unregisterMenuCommand(id) { delete menu[id]; syncMenu(); }
      if (C.isolated && isTop) {
        var runMenu = function (id) { var m = menu[id]; if (m && typeof m.fn === 'function') { try { m.fn(); } catch (e) { console.error(label, e); } } };
        try {
          Object.defineProperty(w, '__mioUserScriptMenu', { configurable: true, value: runMenu });
        } catch (e) {}
        // Android 所有脚本共用页面世界：按脚本 id 分开（原生执行 __mioUserScriptMenus[id](命令)）
        if (C.bridge) {
          try {
            if (!w.__mioUserScriptMenus) Object.defineProperty(w, '__mioUserScriptMenus', { configurable: true, value: {} });
            w.__mioUserScriptMenus[C.id] = runMenu;
          } catch (e) {}
        }
      }
      function notification(details, title, image, onclick) {
        var o = typeof details === 'string' ? { text: details, title: title, image: image, onclick: onclick } : (details || {});
        var box = d.createElement('div');
        box.setAttribute('data-mio-userscript-toast', C.id);
        box.style.cssText = 'position:fixed;z-index:2147483647;left:50%;bottom:24px;transform:translateX(-50%);max-width:86vw;padding:10px 16px;border-radius:12px;background:rgba(30,30,30,.92);color:#fff;font:14px -apple-system,system-ui,sans-serif;box-shadow:0 4px 18px rgba(0,0,0,.3);cursor:pointer';
        var t = d.createElement('b');
        t.textContent = String(o.title || C.name);
        var p = d.createElement('div');
        p.textContent = String(o.text || '');
        box.appendChild(t);
        box.appendChild(p);
        box.addEventListener('click', function () { box.remove(); if (typeof o.onclick === 'function') o.onclick(); });
        whenRoot(function () { (d.body || d.documentElement).appendChild(box); });
        setTimeout(function () { if (box.parentNode) { box.remove(); if (typeof o.ondone === 'function') o.ondone(); } }, Number(o.timeout) || 5000);
      }
      var R = C.resources || {};
      function getResourceText(name) { return Object.prototype.hasOwnProperty.call(R, name) ? R[name] : null; }
      function getResourceURL(name) {
        var t = getResourceText(name);
        if (t === null) return null;
        return 'data:text/plain;charset=utf-8;base64,' + b64encode(new TextEncoder().encode(t));
      }
      function log() { try { console.log.apply(console, [label].concat([].slice.call(arguments))); } catch (e) {} }

      var info = C.info || {};
      var iso = !!C.isolated;
      var gm = {
        info: info,
        addStyle: function (css) { return Promise.resolve(addStyle(css)); },
        addElement: function (a, b, c) { return Promise.resolve(addElement(a, b, c)); },
        getValue: function (k, def) { return Promise.resolve(getValue(k, def)); },
        setValue: function (k, v) { setValue(k, v); return Promise.resolve(); },
        deleteValue: function (k) { deleteValue(k); return Promise.resolve(); },
        listValues: function () { return Promise.resolve(listValues()); },
        xmlHttpRequest: xhrPromise,
        openInTab: function (u, o) { return Promise.resolve(openInTab(u, o)); },
        setClipboard: function (data, i) { return setClipboard(data, i).then(function () {}); },
        registerMenuCommand: function (n, f) { return Promise.resolve(registerMenuCommand(n, f)); },
        unregisterMenuCommand: function (id) { unregisterMenuCommand(id); return Promise.resolve(); },
        notification: function (a, b, c, e) { notification(a, b, c, e); return Promise.resolve(); },
        getResourceText: function (n) { return Promise.resolve(getResourceText(n)); },
        getResourceUrl: function (n) { return Promise.resolve(getResourceURL(n)); },
        log: function () { log.apply(null, arguments); return Promise.resolve(); }
      };
      if (!iso) {
        // @grant none：页面世界，只有 GM_info 和不需要原生的 API
        ['getValue', 'setValue', 'deleteValue', 'listValues', 'xmlHttpRequest', 'openInTab', 'setClipboard'].forEach(function (k) { delete gm[k]; });
      }

      function start() {
        try {
          main.call(w,
            gm, info, w,
            addStyle,
            iso ? getValue : undefined,
            iso ? setValue : undefined,
            iso ? deleteValue : undefined,
            iso ? listValues : undefined,
            iso ? xhr : undefined,
            iso ? openInTab : undefined,
            iso ? setClipboard : undefined,
            registerMenuCommand, unregisterMenuCommand,
            notification, getResourceText, getResourceURL,
            addValueChangeListener, removeValueChangeListener,
            log, addElement);
        } catch (e) {
          console.error(label, e);
        }
      }
      if (C.runAt === 'document-start') {
        start();
      } else if (C.runAt === 'document-end') {
        if (d.readyState === 'loading') d.addEventListener('DOMContentLoaded', start, { once: true }); else start();
      } else {
        var idle = function () { setTimeout(start, 0); };
        if (d.readyState === 'loading') d.addEventListener('DOMContentLoaded', idle, { once: true }); else idle();
      }
    })
    """#
    // MIO_JS_END userscriptRuntime
}
