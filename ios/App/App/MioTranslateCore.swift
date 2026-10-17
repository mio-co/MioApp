// MioTranslateCore.swift — 内置浏览器翻译的原生侧纯逻辑（只依赖 Foundation，tools/MioAppTests 在 Linux / macOS 上 swift test）。
// 页面脚本是 shared/translate/mio-translate.js（App 资源），这里负责：
// - 校验脚本发来的网络请求（只放行翻译引擎域名 + 用户配置的 OpenAI 地址；OpenAI Key 只在原生加）
// - 从 Bing 翻译页里按正则摘参数（避免把 600 KB 的页面传回网页）
// - 持久缓存（LRU，JSON 文件）
// - 设置项的规范化（自动翻译站点、API 地址）和注入配置

import Foundation

enum MioTranslateCore {
    /// 内部语言代码 → 显示名
    static let languages: [(code: String, name: String)] = [
        ("zh-CN", "简体中文"), ("zh-TW", "繁體中文"), ("en", "English"), ("ja", "日本語"), ("ko", "한국어"),
        ("fr", "Français"), ("de", "Deutsch"), ("es", "Español"), ("ru", "Русский"), ("pt", "Português"),
        ("it", "Italiano"), ("vi", "Tiếng Việt"), ("th", "ไทย"), ("id", "Bahasa Indonesia"), ("ar", "العربية"),
    ]

    static let engines: [(id: String, name: String)] = [
        ("microsoft", "微软翻译（免费）"), ("google", "谷歌翻译（免费）"), ("openai", "自定义 OpenAI 兼容 API"),
    ]

    static func languageName(_ code: String) -> String {
        languages.first(where: { $0.code == code })?.name ?? code
    }

    static let freeHosts: Set<String> = [
        "www.bing.com", "bing.com", "edge.microsoft.com",
        "api-edge.cognitive.microsofttranslator.com", "api.cognitive.microsofttranslator.com",
        "translate.googleapis.com", "translate.google.com",
    ]
    static let allowedHeaders: Set<String> = ["content-type", "accept", "authorization"]
    static let maxBody = 256 * 1024
    static let maxResponse = 3 * 1024 * 1024
    static let placeholder = "'__MIO_TRANSLATE_CONFIG__'"

    // MARK: - Hosts / URLs

    /// 用户输入的站点 → 规范化域名（去掉协议 / www. / 路径 / 端口）；无效返回 nil
    static func normalizeHost(_ input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.isEmpty { return nil }
        if s.contains("://") {
            guard let h = URLComponents(string: s)?.host, !h.isEmpty else { return nil }
            s = h
        }
        if s.hasPrefix("*.") { s.removeFirst(2) }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        if let colon = s.firstIndex(of: ":") { s = String(s[..<colon]) }
        while s.hasSuffix(".") { s.removeLast() }
        if s == "localhost" { return s }
        let labels = s.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return nil }
        let ok = labels.allSatisfy { l in !l.isEmpty && l.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }
        return ok ? s : nil
    }

    static func hostMatches(_ host: String?, _ entry: String) -> Bool {
        guard var h = host?.lowercased(), !h.isEmpty, let e = normalizeHost(entry) else { return false }
        while h.hasSuffix(".") { h.removeLast() }
        return h == e || h.hasSuffix("." + e)
    }

    static func isAuto(host: String?, sites: [String]) -> Bool {
        sites.contains { hostMatches(host, $0) }
    }

    /// OpenAI 兼容地址：http(s)，去掉查询 / 片段 / 末尾斜杠；无效 = ""
    static func normalizeBase(_ input: String) -> String {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, var c = URLComponents(string: s), let scheme = c.scheme?.lowercased(),
              scheme == "https" || scheme == "http", let host = c.host, !host.isEmpty else { return "" }
        c.query = nil
        c.fragment = nil
        var out = c.string ?? ""
        while out.hasSuffix("/") { out.removeLast() }
        return out
    }

    static func openaiEndpoint(_ base: String) -> String {
        let b = normalizeBase(base)
        if b.isEmpty { return "" }
        return b.hasSuffix("/chat/completions") ? b : b + "/chat/completions"
    }

    // MARK: - Request checking

    struct CheckedRequest: Equatable {
        var url: URL
        var method: String
        var headers: [String: String]
        var body: String?
        var timeout: TimeInterval
        var openAIAuth: Bool
        var picks: [String]?
    }

    enum CheckError: Error, Equatable, CustomStringConvertible {
        case bad(String)
        var description: String { if case .bad(let s) = self { return s }; return "bad" }
    }

    /// 校验页面脚本发来的 req（{url, method, headers, body, timeoutMs, auth, pick}）
    static func check(_ req: [String: Any], openaiBase: String) -> Result<CheckedRequest, CheckError> {
        guard let raw = req["url"] as? String, let url = URL(string: raw), let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = comps.host?.lowercased(), let scheme = comps.scheme?.lowercased() else { return .failure(.bad("bad url")) }
        let method = ((req["method"] as? String) ?? "GET").uppercased()
        guard method == "GET" || method == "POST" else { return .failure(.bad("method")) }
        let endpoint = openaiEndpoint(openaiBase)
        let noQuery = raw.split(separator: "?", maxSplits: 1).first.map(String.init) ?? raw
        let isOpenAI = !endpoint.isEmpty && (raw == endpoint || noQuery == endpoint)
        if !isOpenAI && !(scheme == "https" && freeHosts.contains(host)) { return .failure(.bad("host not allowed")) }
        let auth = req["auth"] as? String
        if let a = auth, !(a == "openai" && isOpenAI) { return .failure(.bad("auth not allowed")) }
        var headers: [String: String] = [:]
        for (k, v) in (req["headers"] as? [String: Any]) ?? [:] {
            let lk = k.lowercased()
            guard allowedHeaders.contains(lk) else { continue }
            if lk == "authorization" && !host.hasSuffix("cognitive.microsofttranslator.com") { continue }
            headers[lk] = String(String(describing: v).prefix(4096))
        }
        let body = req["body"] as? String
        if let b = body, b.utf8.count > maxBody { return .failure(.bad("body too large")) }
        if body != nil && method == "GET" { return .failure(.bad("GET with body")) }
        let rawMs = req["timeoutMs"]
        let ms: Double = (rawMs as? Double) ?? (rawMs as? Int).map(Double.init) ?? (rawMs as? NSNumber)?.doubleValue ?? 15000
        let timeout = max(1, min(ms / 1000, 90))
        let picks = (req["pick"] as? [Any]).map { Array($0.prefix(8)).map { String(describing: $0) } }
        return .success(CheckedRequest(url: url, method: method, headers: headers, body: body, timeout: timeout,
                                       openAIAuth: isOpenAI && auth == "openai", picks: picks))
    }

    /// 对响应文本跑正则，返回每个正则的捕获组（没匹配 → NSNull）
    static func runPicks(_ text: String, _ patterns: [String]) -> [Any] {
        let ns = text as NSString
        return patterns.map { p -> Any in
            guard let re = try? NSRegularExpression(pattern: p),
                  let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return NSNull() }
            var groups: [String] = []
            if m.numberOfRanges > 1 {
                for i in 1..<m.numberOfRanges {
                    let r = m.range(at: i)
                    groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
                }
            }
            return groups
        }
    }

    // MARK: - Injected config

    struct Config: Equatable {
        var token: String
        var platform: String
        var target: String
        var engine: String
        var display: String
        var autoSites: [String]
        var selection: Bool
        var youtube: Bool
        var ytSubs: Bool
        var openaiBase: String
        var openaiModel: String
        var openaiPrompt: String
        var openaiReady: Bool
    }

    static func configJSON(_ c: Config) -> [String: Any] {
        [
            "v": 1, "token": c.token, "platform": c.platform, "target": c.target, "engine": c.engine, "display": c.display,
            "autoSites": c.autoSites, "selection": c.selection, "youtube": c.youtube, "ytSubs": c.ytSubs,
            "openai": ["base": c.openaiBase, "model": c.openaiModel, "prompt": c.openaiPrompt, "ready": c.openaiReady] as [String: Any],
        ]
    }

    /// 把配置（base64 JSON）填进脚本模板；模板没有占位符返回 nil
    static func script(template: String, config: Config) -> String? {
        guard template.contains(placeholder),
              let data = try? JSONSerialization.data(withJSONObject: configJSON(config), options: [.sortedKeys]) else { return nil }
        let b64 = data.base64EncodedString()
        guard let r = template.range(of: placeholder) else { return nil }
        return template.replacingCharacters(in: r, with: "'\(b64)'")
    }

    /// 每次启动随机的桥 token（页面拿不到：只在注入脚本的闭包里）
    static func makeToken() -> String {
        var g = SystemRandomNumberGenerator()
        return (0..<24).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &g)) }.joined()
    }
}

// MARK: - 持久缓存（LRU）

/// 有序字典 LRU：get 会把条目挪到最新；超过 limit 淘汰最旧。encode/decode 成 JSON（[[key, value], …]，旧 → 新）
struct MioTranslateLRU: Equatable {
    private(set) var keys: [String] = []
    private(set) var values: [String: String] = [:]
    let limit: Int

    init(limit: Int = 20000) { self.limit = max(1, limit) }

    var count: Int { values.count }

    mutating func get(_ key: String) -> String? {
        guard let v = values[key] else { return nil }
        touch(key)
        return v
    }

    mutating func get(_ many: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for k in many.prefix(500) { if let v = get(k) { out[k] = v } }
        return out
    }

    mutating func put(_ key: String, _ value: String) {
        guard key.count <= 200, value.count <= 20000 else { return }
        if values[key] != nil { touch(key) } else { keys.append(key) }
        values[key] = value
        trim()
    }

    mutating func put(_ entries: [String: String]) {
        for (k, v) in entries.prefix(500) { put(k, v) }
    }

    mutating func clear() {
        keys = []
        values = [:]
    }

    private mutating func touch(_ key: String) {
        if let i = keys.lastIndex(of: key) { keys.remove(at: i) }
        keys.append(key)
    }

    private mutating func trim() {
        let over = keys.count - limit
        guard over > 0 else { return }
        for k in keys.prefix(over) { values[k] = nil }
        keys.removeFirst(over)
    }

    func encode() -> Data {
        let arr = keys.compactMap { k in values[k].map { [k, $0] } }
        return (try? JSONSerialization.data(withJSONObject: arr)) ?? Data("[]".utf8)
    }

    static func decode(_ data: Data, limit: Int = 20000) -> MioTranslateLRU {
        var lru = MioTranslateLRU(limit: limit)
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String]] else { return lru }
        for pair in arr where pair.count == 2 { lru.put(pair[0], pair[1]) }
        return lru
    }
}
