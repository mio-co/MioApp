// MioFilterConverter.swift — AdGuard / EasyList 规则 → WKContentRuleList JSON。
//   - MioAdGuardFilterConverter：Apple 平台用 AdGuard SafariConverterLib（与 v0.3.x 同版本、同参数），覆盖完整语法
//   - MioBasicFilterConverter：纯 Swift 子集（||domain^、|、*、$third-party / domain= / 资源类型 / match-case、@@ 例外、## 元素隐藏），
//     Linux 单测用，也是没有 SafariConverterLib 时的退路
//   - MioRuleSplitter：一个 WKContentRuleList 最多 15 万条，超了把源规则对半拆（递归），例外规则（@@ / #@#）每一片都保留
// 只依赖 Foundation（AdGuard 部分 #if canImport）。

import Foundation
#if canImport(ContentBlockerConverter)
import ContentBlockerConverter
#endif

public struct MioConversionResult: Equatable {
    /// WKContentRuleList 的 JSON（数组）
    public var json: String
    public var ruleCount: Int
    public var sourceRules: Int
    /// 因超过上限被丢掉的条数（> 0 时拆分器会对半拆）
    public var discarded: Int
    /// 跳过的：内容规则和高级规则引擎都表达不了（转换出错 / 不支持的修饰符），计入设置页的「跳过 M 条」
    public var unsupported: Int
    /// 高级规则（scriptlet `#%#//scriptlet`、扩展 CSS `#?#` / `#$#`、`+js`、JS 规则 `#%#`）：由 FilterEngine 在页面里注入
    public var advancedRules: Int
    /// 高级规则原文（AdGuard 语法，一行一条），交给 MioAdvancedEngine
    public var advancedText: String?
    public init(json: String, ruleCount: Int, sourceRules: Int, discarded: Int, unsupported: Int, advancedRules: Int = 0, advancedText: String? = nil) {
        self.json = json; self.ruleCount = ruleCount; self.sourceRules = sourceRules; self.discarded = discarded; self.unsupported = unsupported
        self.advancedRules = advancedRules; self.advancedText = advancedText
    }
}

/// 过滤列表文本 → 行。注意 Swift 把 "\r\n" 当成一个 Character（字素簇），`$0 == "\n"` 不会命中它：
/// filters.adtidy.org 的列表全是 CRLF，v0.4.0 用 Character 比较拆行，整份列表变成一行注释 → 0 条规则（广告拦截基本不生效的根因）。
/// 这里按 UTF-8 字节拆，\r\n、\n、\r 都认。
public enum MioFilterText {
    public static func lines(_ text: String) -> [String] {
        // 按 UTF-8 字节拆（\n = 10，\r = 13）：快，也不受字素簇影响；空行丢掉
        text.utf8.split(omittingEmptySubsequences: true, whereSeparator: { $0 == 10 || $0 == 13 })
            .map { String(decoding: $0, as: UTF8.self) }
    }
}

public protocol MioFilterConverting {
    /// WebKit 单个规则表上限
    var maxRules: Int { get }
    func convert(_ lines: [String]) -> MioConversionResult
}

public enum MioFilterConverters {
    /// 当前平台最好的转换器
    public static func best() -> MioFilterConverting {
        #if canImport(ContentBlockerConverter)
        return MioAdGuardFilterConverter()
        #else
        return MioBasicFilterConverter()
        #endif
    }
}

#if canImport(ContentBlockerConverter)
/// AdGuard SafariConverterLib（GPL-3.0）。上限由库内部控制（15 万），超出部分记为 discarded
public struct MioAdGuardFilterConverter: MioFilterConverting {
    public let maxRules = 150_000
    public init() {}
    public func convert(_ lines: [String]) -> MioConversionResult {
        let r = ContentBlockerConverter().convertArray(rules: lines, safariVersion: SafariVersion.autodetect(), advancedBlocking: true,
                                                      maxJsonSizeBytes: nil, progress: nil)
        return MioConversionResult(json: r.safariRulesJSON, ruleCount: r.safariRulesCount, sourceRules: r.sourceRulesCount,
                                   discarded: r.discardedSafariRules, unsupported: r.errorsCount,
                                   advancedRules: r.advancedRulesCount, advancedText: r.advancedRulesText)
    }
}
#endif

// MARK: - 内置子集转换器

public struct MioBasicFilterConverter: MioFilterConverting {
    public var maxRules: Int
    /// 全局元素隐藏选择器每多少个合并成一条 css-display-none
    public var cssBatch = 50
    public init(maxRules: Int = 150_000) { self.maxRules = maxRules }

    static let typeMap: [String: String] = [
        "script": "script", "image": "image", "stylesheet": "style-sheet", "font": "font", "media": "media",
        "xmlhttprequest": "raw", "xhr": "raw", "other": "raw", "subdocument": "document", "document": "document",
        "popup": "popup", "ping": "ping", "websocket": "websocket", "object": "raw",
    ]
    /// 认识但不需要处理的修饰符
    static let ignorableOptions: Set<String> = ["important", "~important", "all", "1p", "3p", "first-party", "~first-party", "third-party", "~third-party"]

    public func convert(_ lines: [String]) -> MioConversionResult {
        var blocks: [[String: Any]] = []
        var exceptions: [[String: Any]] = []
        var globalCSS: [String] = []
        var unsupported = 0
        var source = 0
        var advanced: [String] = []
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[") { continue }
            source += 1
            if let r = cosmetic(line) {
                switch r {
                case .global(let sel): globalCSS.append(sel)
                case .rule(let rule): blocks.append(rule)
                case .advanced: advanced.append(line)
                case .unsupported: unsupported += 1
                }
                continue
            }
            guard let (rule, isException) = network(line) else { unsupported += 1; continue }
            if isException { exceptions.append(rule) } else { blocks.append(rule) }
        }
        var cssRules: [[String: Any]] = []
        var i = 0
        while i < globalCSS.count {
            let chunk = globalCSS[i..<min(i + cssBatch, globalCSS.count)]
            cssRules.append(["trigger": ["url-filter": ".*"], "action": ["type": "css-display-none", "selector": chunk.joined(separator: ", ")]])
            i += cssBatch
        }
        // 顺序：屏蔽 → 元素隐藏 → 例外（ignore-previous-rules 只作用于它前面的规则）
        var main = blocks + cssRules
        let room = max(0, maxRules - exceptions.count)
        var discarded = 0
        if main.count > room { discarded = main.count - room; main = Array(main.prefix(room)) }
        var all = main + exceptions
        if all.isEmpty {
            // WebKit 不接受空数组：放一条永远不命中的占位规则
            all = [["trigger": ["url-filter": "^mio-kit-empty-list:"], "action": ["type": "block"]]]
        }
        let data = (try? JSONSerialization.data(withJSONObject: all, options: [.sortedKeys])) ?? Data("[]".utf8)
        return MioConversionResult(json: String(data: data, encoding: .utf8) ?? "[]", ruleCount: all.count, sourceRules: source,
                                   discarded: discarded, unsupported: unsupported,
                                   advancedRules: advanced.count, advancedText: advanced.isEmpty ? nil : advanced.joined(separator: "\n"))
    }

    enum Cosmetic { case global(String), rule([String: Any]), advanced, unsupported }

    func cosmetic(_ line: String) -> Cosmetic? {
        // HTML 过滤（$$ / ##^）WebKit 做不到；#@# 例外隐藏内容规则里没有对应写法（AdGuard 转换器能处理）
        for marker in ["$$", "##^", "#@#"] where line.contains(marker) { return .unsupported }
        // 高级规则：scriptlet / JS（#%#）、CSS 注入（#$#）、扩展 CSS（#?#）、+js，以及它们的例外 → 交给高级规则引擎（页面里注入）
        for marker in ["#%#", "#$#", "#?#", "#@%#", "#@$#", "#@?#", "##+js"] where line.contains(marker) { return .advanced }
        guard let r = line.range(of: "##") else { return nil }
        let domains = String(line[..<r.lowerBound])
        let selector = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !selector.isEmpty else { return .unsupported }
        // 扩展 CSS 伪类（:has / :-abp- / :contains …）WebKit 选择器做不到 → 高级规则引擎（ExtendedCss）
        if selector.contains(":has(") || selector.contains(":-abp-") || selector.contains(":contains(") || selector.contains(":upward(")
            || selector.contains(":xpath(") || selector.contains(":matches-css") { return .advanced }
        if domains.isEmpty { return .global(selector) }
        let (ifd, unless) = domainLists(domains.split(separator: ",").map(String.init))
        var trigger: [String: Any] = ["url-filter": ".*"]
        if !ifd.isEmpty { trigger["if-domain"] = ifd } else if !unless.isEmpty { trigger["unless-domain"] = unless } else { return .unsupported }
        return .rule(["trigger": trigger, "action": ["type": "css-display-none", "selector": selector]])
    }

    /// 域名列表 → (if-domain, unless-domain)，WebKit 写法 *example.com = 含子域名
    func domainLists(_ items: [String]) -> ([String], [String]) {
        var ifd: [String] = [], unless: [String] = []
        for d in items.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) where !d.isEmpty {
            if d.hasPrefix("~") { let h = String(d.dropFirst()); if Self.validDomain(h) { unless.append("*" + h) } } else if Self.validDomain(d) { ifd.append("*" + d) }
        }
        return (ifd, unless)
    }

    static func validDomain(_ s: String) -> Bool {
        !s.isEmpty && s.range(of: #"^[a-z0-9.\-]+$"#, options: .regularExpression) != nil && !s.hasPrefix(".") && s.contains(".")
    }

    func network(_ input: String) -> ([String: Any], Bool)? {
        var line = input
        var exception = false
        if line.hasPrefix("@@") { exception = true; line = String(line.dropFirst(2)) }
        var pattern = line
        var options: [String] = []
        if let dollar = line.lastIndex(of: "$"), dollar > line.startIndex, !line.hasPrefix("/") || line[line.index(before: dollar)] == "/" {
            pattern = String(line[..<dollar])
            options = line[line.index(after: dollar)...].split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces).lowercased() }
        }
        // 正则规则 /…/：WebKit 正则子集太窄，交给 AdGuard 转换器
        if pattern.hasPrefix("/") && pattern.hasSuffix("/") && pattern.count > 1 { return nil }
        var trigger: [String: Any] = [:]
        var types: [String] = []
        var wholeDocument = false
        for o in options {
            if o == "third-party" || o == "3p" || o == "~first-party" { trigger["load-type"] = ["third-party"]; continue }
            if o == "~third-party" || o == "1p" || o == "first-party" { trigger["load-type"] = ["first-party"]; continue }
            if o == "match-case" { trigger["url-filter-is-case-sensitive"] = true; continue }
            if o.hasPrefix("domain=") {
                let (ifd, unless) = domainLists(o.dropFirst(7).split(separator: "|").map(String.init))
                if !ifd.isEmpty { trigger["if-domain"] = ifd } else if !unless.isEmpty { trigger["unless-domain"] = unless }
                continue
            }
            if exception && (o == "document" || o == "content" || o == "urlblock") { wholeDocument = true; continue }
            // elemhide / generichide 只放行元素隐藏，内容规则表达不了（不能近似成整页放行）→ 不支持
            if let t = Self.typeMap[o] { if !types.contains(t) { types.append(t) }; continue }
            if Self.ignorableOptions.contains(o) { continue }
            return nil // ~script、redirect、removeparam、csp、badfilter… 内容规则表达不了
        }
        if exception && wholeDocument {
            // @@||example.com^$document → 在 example.com 上整页放行
            let host = pattern.replacingOccurrences(of: "||", with: "").replacingOccurrences(of: "^", with: "").replacingOccurrences(of: "|", with: "")
            guard Self.validDomain(host.lowercased()) else { return nil }
            return (["trigger": ["url-filter": ".*", "if-domain": ["*" + host.lowercased()]], "action": ["type": "ignore-previous-rules"]], true)
        }
        guard let filter = Self.urlFilter(pattern) else { return nil }
        trigger["url-filter"] = filter
        if !types.isEmpty { trigger["resource-type"] = types }
        return (["trigger": trigger, "action": ["type": exception ? "ignore-previous-rules" : "block"]], exception)
    }

    /// AdBlock 模式 → WebKit 正则子集（不支持 | 选择、{}、\d 等）
    static func urlFilter(_ p: String) -> String? {
        var s = Substring(p)
        var out = ""
        if s.hasPrefix("||") {
            s = s.dropFirst(2)
            out = "^[^:]+://+([^:/]+\\.)?"
            // 域名部分到第一个 / ^ * 为止
            var host = ""
            while let c = s.first, c != "/" && c != "^" && c != "*" && c != "|" && c != ":" { host.append(c); s = s.dropFirst() }
            guard !host.isEmpty, host.range(of: #"^[A-Za-z0-9.\-_]+$"#, options: .regularExpression) != nil else { return nil }
            out += escape(host.lowercased())
            if s.first == "^" { out += "[/:]"; s = s.dropFirst() }
        } else if s.hasPrefix("|") {
            s = s.dropFirst()
            out = "^"
        }
        var endAnchor = false
        if s.hasSuffix("|") { endAnchor = true; s = s.dropLast() }
        for c in s {
            switch c {
            case "*": out += ".*"
            case "^": out += "[/:?&=]"
            default: out += escape(String(c))
            }
        }
        if endAnchor { out += "$" }
        if out.isEmpty || out == "^" { return p.isEmpty ? nil : ".*" }
        // 太宽泛的规则（只有通配）丢掉，免得把整个网页拦了
        if out.replacingOccurrences(of: ".*", with: "").isEmpty { return nil }
        guard out.unicodeScalars.allSatisfy({ $0.isASCII }) else { return nil }
        return out
    }

    static func escape(_ s: String) -> String {
        var o = ""
        for c in s { if ".+?{}()[]\\$|".contains(c) { o += "\\" + String(c) } else { o.append(c) } }
        return o
    }
}

// MARK: - 拆分

public enum MioRuleSplitter {
    /// 例外规则：拆分时每一片都要带上，否则例外只在某一片里生效
    public static func isException(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("@@") || t.contains("#@#") || t.contains("#@%#") || t.contains("#@$#") || t.contains("#@?#")
    }

    /// 转换；超过单表上限（converter.discarded > 0）就把非例外规则对半拆，递归。返回每一片的结果（每片单独编译成一个 WKContentRuleList）
    public static func convert(_ lines: [String], converter: MioFilterConverting, minSplit: Int = 2000) -> [MioConversionResult] {
        let r = converter.convert(lines)
        guard r.discarded > 0 else { return [r] }
        let exceptions = lines.filter(isException)
        let normal = lines.filter { !isException($0) }
        guard normal.count > max(minSplit, 1) else { return [r] }
        let mid = normal.count / 2
        return convert(Array(normal[..<mid]) + exceptions, converter: converter, minSplit: minSplit)
            + convert(Array(normal[mid...]) + exceptions, converter: converter, minSplit: minSplit)
    }
}
