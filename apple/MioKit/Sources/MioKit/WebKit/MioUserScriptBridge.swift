// MioUserScriptBridge.swift — 用户脚本 GM API 的原生端（v0.3.x MioUserScripts.swift 的 MioUserScriptBridge，去掉 UIKit，UI 走 MioUserScriptHost）。
// 只在启用、且有 @grant 的脚本自己的 WKContentWorld（mio.userscript.<id>）里注册 mioUserScript 通道：页面世界和别的脚本都拿不到。
// 脚本只能以自己的身份说话：world 名决定是哪个脚本，消息里的 id 必须一致。
// op：setValue / deleteValue / xhr（GM_xmlhttpRequest：同源直接发；@connect 声明过的问用户；没声明的拒绝）/ xhrAbort / openTab / setClipboard / menu / notification

#if canImport(WebKit)
import Foundation
import WebKit

@MainActor
public final class MioUserScriptBridge: NSObject {
    public let engine: MioUserScriptEngine
    public weak var host: MioUserScriptHost?
    public weak var webView: WKWebView?
    private let controller: WKUserContentController
    private var registered: Set<String> = []
    private var tasks: [String: URLSessionDataTask] = [:]
    private var pendingAsks: [String: [(Bool) -> Void]] = [:]
    /// 主框架里脚本注册的菜单命令：scriptID → [(id, name)]
    public private(set) var menus: [String: [(id: String, name: String)]] = [:]

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    public init(engine: MioUserScriptEngine, controller: WKUserContentController) {
        self.engine = engine
        self.controller = controller
    }

    /// 按当前启用脚本增删通道（同名重复注册会抛 ObjC 异常，所以记账）
    public func sync(enabled: Bool = true) {
        let want = enabled ? engine.isolatedWorldNames : []
        for name in want.subtracting(registered) {
            controller.addScriptMessageHandler(MioUserScriptWeakHandler(self), contentWorld: .world(name: name), name: MioUserScriptRuntime.handlerName)
        }
        for name in registered.subtracting(want) {
            controller.removeScriptMessageHandler(forName: MioUserScriptRuntime.handlerName, contentWorld: .world(name: name))
        }
        registered = want
    }

    public func detach() {
        for name in registered { controller.removeScriptMessageHandler(forName: MioUserScriptRuntime.handlerName, contentWorld: .world(name: name)) }
        registered = []
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
    }

    public func willNavigateMainFrame() { menus = [:] }

    public var menuItems: [(scriptID: String, scriptName: String, id: String, name: String)] {
        engine.scripts.flatMap { s in (menus[s.id] ?? []).map { (scriptID: s.id, scriptName: s.meta.displayName, id: $0.id, name: $0.name) } }
    }

    public func runMenuCommand(scriptID: String, id: String) {
        guard let wv = webView, let s = engine.store.script(id: scriptID) else { return }
        wv.evaluateJavaScript("window.__mioUserScriptMenu && window.__mioUserScriptMenu(\(MioJSString.literal(id))); void 0", in: nil, in: .world(name: s.worldName), completionHandler: nil)
    }

    // MARK: messages

    func handle(_ message: MioWKMessageInfo, replyHandler: @escaping (Any?, String?) -> Void) {
        guard let script = engine.script(forWorld: message.worldName), let body = message.body as? [String: Any], let op = body["op"] as? String else {
            replyHandler(nil, "bad message"); return
        }
        let id = script.id
        guard (body["id"] as? String) == id, script.enabled else { replyHandler(nil, "script not found"); return }
        switch op {
        case "setValue":
            guard let key = body["key"] as? String, let value = body["value"] as? String else { replyHandler(nil, "bad value"); return }
            if engine.setValue(id, key, value) { replyHandler(true, nil) } else { replyHandler(nil, "存储超出上限（每个脚本 5 MB）") }
        case "deleteValue":
            guard let key = body["key"] as? String else { replyHandler(nil, "bad key"); return }
            engine.deleteValue(id, key)
            replyHandler(true, nil)
        case "xhr":
            handleXHR(script: script, body: body, pageHost: message.origin?.host, reply: replyHandler)
        case "xhrAbort":
            if let r = body["reqId"] as? String, r.hasPrefix(id + ":") { tasks.removeValue(forKey: r)?.cancel() }
            replyHandler(true, nil)
        case "openTab":
            guard let s = body["url"] as? String, let url = URL(string: s), let sc = url.scheme?.lowercased(), sc == "http" || sc == "https" else {
                replyHandler(nil, "invalid url"); return
            }
            host?.userScriptOpenTab(url, background: (body["active"] as? Bool) == false)
            replyHandler(true, nil)
        case "setClipboard":
            host?.userScriptSetClipboard(body["data"] as? String ?? "", html: (body["type"] as? String ?? "text").lowercased().contains("html"))
            replyHandler(true, nil)
        case "notification":
            host?.userScriptNotification(title: body["title"] as? String ?? script.meta.displayName, text: body["text"] as? String ?? "")
            replyHandler(true, nil)
        case "menu":
            if message.isMainFrame {
                let list = (body["commands"] as? [[String: Any]] ?? []).compactMap { c -> (id: String, name: String)? in
                    guard let i = c["id"] as? String, let n = c["name"] as? String else { return nil }
                    return (id: i, name: n)
                }
                menus[id] = list.isEmpty ? nil : list
            }
            replyHandler(true, nil)
        default:
            replyHandler(nil, "unknown op \(op)")
        }
    }

    // MARK: GM_xmlhttpRequest

    private func handleXHR(script: MioUserScript, body: [String: Any], pageHost: String?, reply: @escaping (Any?, String?) -> Void) {
        guard let s = body["url"] as? String, let url = URL(string: s), let sc = url.scheme?.lowercased(), sc == "http" || sc == "https",
              let host = url.host, !host.isEmpty else { reply(["error": "不支持的地址"], nil); return }
        let normalized = MioUserScriptConnect.normalizeHost(host)
        switch MioUserScriptConnect.verdict(target: host, pageHost: pageHost, connects: script.meta.connects) {
        case .sameOrigin:
            perform(url: url, body: body, reply: reply)
        case .undeclared:
            reply(["error": "\(host) 不在脚本的 @connect 列表中，已拒绝"], nil)
        case .declared:
            if let d = script.connectDecisions[normalized] {
                if d { perform(url: url, body: body, reply: reply) } else { reply(["error": "已拒绝脚本访问 \(host)"], nil) }
                return
            }
            ask(script: script, host: normalized) { [weak self] allow in
                if allow { self?.perform(url: url, body: body, reply: reply) } else { reply(["error": "已拒绝脚本访问 \(host)"], nil) }
            }
        }
    }

    private func ask(script: MioUserScript, host: String, completion: @escaping (Bool) -> Void) {
        let key = script.id + "|" + host
        if pendingAsks[key] != nil { pendingAsks[key]?.append(completion); return }
        pendingAsks[key] = [completion]
        guard let h = self.host else { finish(key, false); return }
        let name = script.meta.displayName, sid = script.id
        Task { @MainActor in
            let r = await h.userScriptAskConnect(scriptName: name, host: host)
            if r.remember { self.engine.setConnectDecision(sid, host: host, allow: r.allow) }
            self.finish(key, r.allow)
        }
    }

    private func finish(_ key: String, _ allow: Bool) {
        let cbs = pendingAsks.removeValue(forKey: key) ?? []
        cbs.forEach { $0(allow) }
    }

    private func perform(url: URL, body: [String: Any], reply: @escaping (Any?, String?) -> Void) {
        guard let reqId = body["reqId"] as? String else { reply(["error": "bad request"], nil); return }
        var req = URLRequest(url: url)
        req.httpMethod = (body["method"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "GET"
        let timeoutMs = (body["timeout"] as? NSNumber)?.doubleValue ?? 0
        req.timeoutInterval = timeoutMs > 0 ? timeoutMs / 1000 : 120
        req.httpShouldHandleCookies = false
        var hasUA = false, hasAuth = false
        for (k, v) in body["headers"] as? [String: String] ?? [:] {
            let lk = k.lowercased()
            if lk == "user-agent" { hasUA = true }
            if lk == "authorization" { hasAuth = true }
            if lk == "host" || lk == "content-length" { continue }
            req.setValue(v, forHTTPHeaderField: k)
        }
        if !hasUA, let ua = body["userAgent"] as? String, !ua.isEmpty { req.setValue(ua, forHTTPHeaderField: "User-Agent") }
        if !hasAuth, let user = body["user"] as? String, !user.isEmpty {
            req.setValue("Basic " + Data("\(user):\(body["password"] as? String ?? "")".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        }
        if let b = body["body"] as? [String: Any] {
            if let t = b["text"] as? String { req.httpBody = Data(t.utf8) } else if let b64 = b["base64"] as? String { req.httpBody = Data(base64Encoded: b64) }
        }
        let anonymous = (body["anonymous"] as? Bool) ?? false
        let responseType = (body["responseType"] as? String ?? "").lowercased()
        let overrideMime = body["overrideMimeType"] as? String ?? ""
        let cookieStore = webView?.configuration.websiteDataStore.httpCookieStore

        let start: (URLRequest) -> Void = { [weak self] request in
            guard let self = self else { reply(["error": "browser closed"], nil); return }
            let task = self.session.dataTask(with: request) { data, resp, err in
                Task { @MainActor in
                    self.tasks.removeValue(forKey: reqId)
                    if let err = err as NSError? {
                        if err.code == NSURLErrorCancelled { reply(["error": "aborted"], nil); return }
                        reply(["error": err.localizedDescription, "timeout": err.code == NSURLErrorTimedOut], nil)
                        return
                    }
                    let http = resp as? HTTPURLResponse
                    let data = data ?? Data()
                    if !anonymous, let http = http, let store = cookieStore, let final = http.url {
                        var fields: [String: String] = [:]
                        for (k, v) in http.allHeaderFields { if let k = k as? String, let v = v as? String { fields[k] = v } }
                        for c in HTTPCookie.cookies(withResponseHeaderFields: fields, for: final) { store.setCookie(c) }
                    }
                    var result: [String: Any] = [
                        "status": http?.statusCode ?? 0,
                        "statusText": http.map { HTTPURLResponse.localizedString(forStatusCode: $0.statusCode) } ?? "",
                        "finalUrl": resp?.url?.absoluteString ?? url.absoluteString,
                        "headers": Self.headerString(http),
                    ]
                    if responseType == "arraybuffer" || responseType == "blob" {
                        result["base64"] = data.base64EncodedString()
                    } else {
                        result["text"] = Self.decodeText(data, response: http, overrideMime: overrideMime)
                    }
                    reply(result, nil)
                }
            }
            self.tasks[reqId] = task
            task.resume()
        }

        guard !anonymous, let store = cookieStore else { start(req); return }
        store.getAllCookies { cookies in
            let matching = cookies.filter { Self.cookie($0, matches: url) }
            var r = req
            if !matching.isEmpty, let c = HTTPCookie.requestHeaderFields(with: matching)["Cookie"] {
                r.setValue(r.value(forHTTPHeaderField: "Cookie").map { "\($0); \(c)" } ?? c, forHTTPHeaderField: "Cookie")
            }
            start(r)
        }
    }

    nonisolated static func cookie(_ c: HTTPCookie, matches url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if let exp = c.expiresDate, exp < Date() { return false }
        if c.isSecure, url.scheme?.lowercased() != "https" { return false }
        let domain = c.domain.lowercased()
        let domainOK = domain.hasPrefix(".") ? (host == String(domain.dropFirst()) || host.hasSuffix(domain)) : host == domain
        guard domainOK else { return false }
        let path = url.path.isEmpty ? "/" : url.path
        let cp = c.path.isEmpty ? "/" : c.path
        return path == cp || path.hasPrefix(cp.hasSuffix("/") ? cp : cp + "/")
    }

    nonisolated static func headerString(_ http: HTTPURLResponse?) -> String {
        guard let http = http else { return "" }
        return http.allHeaderFields.compactMap { k, v -> String? in (k as? String).map { "\($0.lowercased()): \(v)" } }.sorted().joined(separator: "\r\n")
    }

    nonisolated static func decodeText(_ data: Data, response: HTTPURLResponse?, overrideMime: String) -> String {
        var charset: String?
        if let r = overrideMime.range(of: "charset=", options: .caseInsensitive) {
            charset = String(overrideMime[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " \"';"))
        }
        if charset == nil { charset = response?.textEncodingName }
        if let cs = charset {
            let cf = CFStringConvertIANACharSetNameToEncoding(cs as CFString)
            if cf != kCFStringEncodingInvalidId, let s = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))) { return s }
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }
}

final class MioUserScriptWeakHandler: NSObject, WKScriptMessageHandlerWithReply {
    weak var target: MioUserScriptBridge?
    init(_ t: MioUserScriptBridge) { target = t }
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        let info = MioWKMessageInfo(message)
        Task { @MainActor [weak t = self.target] in
            guard let t = t else { replyHandler(nil, "browser closed"); return }
            t.handle(info, replyHandler: replyHandler)
        }
    }
}
#endif
