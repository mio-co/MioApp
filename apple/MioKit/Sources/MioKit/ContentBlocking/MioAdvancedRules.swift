// MioAdvancedRules.swift — 内容规则（WKContentRuleList）表达不了的「高级规则」：
//   - scriptlet：`example.com#%#//scriptlet('set-constant', 'ads', 'false')`（AdGuard Scriptlets：set-constant、abort-on-property-read、
//     json-prune、prevent-setTimeout、prevent-fetch …，uBO 的 `##+js(...)` 也认）
//   - 扩展 CSS：`#?#div:has(> .ad)`（AdGuard ExtendedCss）、CSS 注入 `#$#body { overflow: auto !important; }`
//   - JS 规则：`example.com#%#window.foo = 1;`
// 转换时 SafariConverterLib 把这些规则分出来（advancedRulesText），FilterEngine（同一个库，Apple 平台）按页面地址查出要用的规则，
// 这里再把查询结果拼成一段 JS，由 MioWebViewModules 在 document-start 注入页面（主框架：导航前预先准备；iframe：发消息后注入）。
// 与 v0.3.x 的 MioAdblockCore 同样的做法（同版本的 Scriptlets / ExtendedCss，见 Resources/adguard/README.md）。
//
// 只依赖 Foundation；FilterEngine 部分 #if canImport(FilterEngine)（Linux 上没有：高级规则只统计、不注入）。

import Foundation
#if canImport(FilterEngine)
import FilterEngine
#endif

/// 一个页面要注入的高级规则（FilterEngine 查询结果的纯值版本，方便测试）
public struct MioCosmeticConfig: Equatable {
    public struct Scriptlet: Equatable {
        public let name: String
        public let args: [String]
        public init(name: String, args: [String]) { self.name = name; self.args = args }
    }
    public var css: [String]
    public var extendedCss: [String]
    public var js: [String]
    public var scriptlets: [Scriptlet]
    public init(css: [String] = [], extendedCss: [String] = [], js: [String] = [], scriptlets: [Scriptlet] = []) {
        self.css = css; self.extendedCss = extendedCss; self.js = js; self.scriptlets = scriptlets
    }
    public var isEmpty: Bool { css.isEmpty && extendedCss.isEmpty && js.isEmpty && scriptlets.isEmpty }
}

// MARK: - Scriptlets 运行库（AdGuard Scriptlets corelibs）

public final class MioScriptletLibrary {
    public let version: String
    private let functions: [String: String]

    public init(data: Data) throws {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = obj["version"] as? String,
              let list = obj["scriptlets"] as? [[String: Any]] else { throw MioAdvancedError.invalid("scriptlets.corelibs.json 格式不对") }
        var map: [String: String] = [:]
        for item in list {
            guard let names = item["names"] as? [String], let fn = item["scriptlet"] as? String, fn.hasPrefix("function") else { continue }
            for n in names { map[n] = fn }
        }
        guard map.count > 50, map["json-prune"] != nil, map["set-constant"] != nil else {
            throw MioAdvancedError.invalid("scriptlets 内容不完整（\(map.count)）")
        }
        self.version = version
        self.functions = map
    }

    /// 包内 Resources/adguard/scriptlets.corelibs.json
    public static let bundled: MioScriptletLibrary? = {
        guard let s = MioKitResources.text("scriptlets.corelibs", ext: "json", dir: "adguard") else { return nil }
        return try? MioScriptletLibrary(data: Data(s.utf8))
    }()

    /// 包内 Resources/adguard/extended-css.min.js
    public static let bundledExtendedCss: String? = MioKitResources.text("extended-css.min", ext: "js", dir: "adguard")

    /// 不同名字的数量（含 uBO / ABP 别名）
    public var nameCount: Int { functions.count }
    public func function(named name: String) -> String? { functions[name] }
    public func supports(_ name: String) -> Bool { functions[name] != nil }

    /// 一次 scriptlet 调用（与 AdGuard Scriptlets passSourceAndProps 一致）；fnRef = 已定义的函数变量（同一函数只定义一次）
    func call(name: String, args: [String], fnRef: String) -> String? {
        let source: [String: Any] = ["name": name, "args": args, "engine": "safari-extension", "version": version, "verbose": false, "uniqueId": "mio"]
        guard let src = Self.json(source), let a = Self.json(args) else { return nil }
        return "try{\(fnRef)(\(src),\(a));}catch(e){}"
    }

    static func json(_ value: Any) -> String? {
        guard let d = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]) else { return nil }
        return String(data: d, encoding: .utf8)?.replacingOccurrences(of: "</", with: "<\\/")
    }
}

public enum MioAdvancedError: Error, CustomStringConvertible {
    case invalid(String)
    case engine(String)
    public var description: String {
        switch self { case .invalid(let s), .engine(let s): return s }
    }
}

// MARK: - 查询结果 → 注入代码

public enum MioAdvancedScript {
    /// CSS 规则：选择器 → `选择器 {display:none!important;}`；已经带样式的（`#$#`）原样
    public static func cssRules(_ css: [String]) -> [String] {
        css.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .map { $0.hasSuffix("}") ? $0 : "\($0) {display:none!important;}" }
    }

    /// 拼注入代码（page world，document-start）。nil = 没有要注入的
    /// 顺序：scriptlets（要赶在页面脚本之前）→ 普通 CSS → JS 规则 → ExtendedCss（DOMContentLoaded 后开始观察）
    public static func build(_ conf: MioCosmeticConfig, scriptlets: MioScriptletLibrary?, extendedCssLib: String?) -> String? {
        var parts: [String] = []
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
                if let existing = fnVars[fn] { v = existing } else {
                    v = "__mioS\(fnVars.count)"
                    fnVars[fn] = v
                    defs.append("var \(v)=\(fn);")
                }
                if let c = sl.call(name: s.name, args: s.args, fnRef: v) { calls.append(c) }
            }
            if !calls.isEmpty {
                parts.append("(function(){\n" + defs.joined(separator: "\n") + "\n" + calls.joined(separator: "\n") + "\n})();")
            }
        }
        let css = cssRules(conf.css)
        if !css.isEmpty, let lit = MioScriptletLibrary.json(css.joined(separator: "\n")) {
            parts.append("(function(){var css=\(lit);function add(){try{var s=document.createElement('style');s.setAttribute('data-mio-adblock','');s.textContent=css;(document.head||document.documentElement).appendChild(s);}catch(e){}}if(document.documentElement){add();}else{document.addEventListener('readystatechange',add,{once:true});}})();")
        }
        for js in conf.js { parts.append("try{\(js)\n}catch(e){}") }
        let ext = cssRules(conf.extendedCss)
        if !ext.isEmpty, let lib = extendedCssLib, let rules = MioScriptletLibrary.json(ext) {
            parts.append("(function(){\(lib)\n;var rules=\(rules);function go(){try{new ExtendedCss({cssRules:rules}).apply();}catch(e){}}if(document.readyState==='loading'){document.addEventListener('DOMContentLoaded',go,{once:true});}else{go();}})();")
        }
        return parts.isEmpty ? nil : "/* mio-adblock */\n" + parts.joined(separator: "\n")
    }
}

// MARK: - 引擎

/// 高级规则引擎（FilterEngine 的抽象：Linux 单测用假实现）。build 在后台线程调用，lookup 在主线程调用：实现要自己加锁
public protocol MioAdvancedEngine: AnyObject {
    /// 用全部高级规则（多个列表拼起来）重建引擎并持久化；下次启动 load() 直接读
    func build(rules: String) throws
    /// 启动时读上次构建的引擎（没有返回 false）
    @discardableResult func load() -> Bool
    var isReady: Bool { get }
    func lookup(pageURL: URL, topURL: URL?) -> MioCosmeticConfig?
}

public enum MioAdvancedEngines {
    /// 当前平台的引擎（Apple：FilterEngine；Linux：nil = 高级规则只统计不注入）
    public static func make(directory: URL) -> MioAdvancedEngine? {
        #if canImport(FilterEngine)
        return MioFilterEngineAdvanced(directory: directory)
        #else
        return nil
        #endif
    }
}

#if canImport(FilterEngine)
/// SafariConverterLib 的 FilterEngine（WebExtension）。每次构建写进新目录（engine-<时间>），成功后再换掉旧的
public final class MioFilterEngineAdvanced: MioAdvancedEngine {
    let directory: URL
    private let lock = NSLock()
    private var ext: WebExtension?
    private var currentDir: String? {
        get { try? String(contentsOf: directory.appendingPathComponent("current"), encoding: .utf8) }
        set {
            if let v = newValue { try? v.write(to: directory.appendingPathComponent("current"), atomically: true, encoding: .utf8) }
            else { try? FileManager.default.removeItem(at: directory.appendingPathComponent("current")) }
        }
    }

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public var isReady: Bool { lock.lock(); defer { lock.unlock() }; return ext != nil }

    @discardableResult
    public func load() -> Bool {
        guard let name = currentDir, !name.isEmpty else { return false }
        let dir = directory.appendingPathComponent(name, isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path), let e = try? WebExtension(containerURL: dir) else { return false }
        Self.prewarm(e)
        lock.lock(); ext = e; lock.unlock()
        return true
    }

    public func build(rules: String) throws {
        let name = "engine-\(Int(Date().timeIntervalSince1970 * 1000))"
        let dir = directory.appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let e = try WebExtension(containerURL: dir)
            _ = try e.buildFilterEngine(rules: rules)
            Self.prewarm(e)
            let old = currentDir
            lock.lock(); ext = e; lock.unlock()
            currentDir = name
            if let old, old != name { try? FileManager.default.removeItem(at: directory.appendingPathComponent(old)) }
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw MioAdvancedError.engine("高级规则引擎构建失败：\(error)")
        }
    }

    /// 第一次 lookup 要从磁盘反序列化引擎：在后台线程（build / load 里）先做掉，主线程查询就只是查表
    static func prewarm(_ e: WebExtension) {
        if let u = URL(string: "https://example.com/") { _ = e.lookup(pageUrl: u, topUrl: nil) }
    }

    public func lookup(pageURL: URL, topURL: URL?) -> MioCosmeticConfig? {
        lock.lock(); let e = ext; lock.unlock()
        guard let c = e?.lookup(pageUrl: pageURL, topUrl: topURL) else { return nil }
        return MioCosmeticConfig(css: c.css, extendedCss: c.extendedCss, js: c.js,
                                 scriptlets: c.scriptlets.map { .init(name: $0.name, args: $0.args) })
    }
}
#endif
