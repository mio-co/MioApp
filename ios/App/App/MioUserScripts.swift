// MioUserScripts.swift — 内置浏览器的用户脚本管理器（iOS / Mac Catalyst，UIKit + WebKit 部分）
//
// - 安装：粘贴代码、输入网址（.user.js；Greasy Fork 脚本页、GitHub blob 链接自动换成下载地址）、浏览器打开 *.user.js 时提示、
//   从文件导入（文件 App / Finder）。@require / @resource 安装时下载缓存，注入时 @require 内联在脚本同一作用域。
// - 注入：WKUserScript 不能按 URL 过滤，每个脚本包一层运行时（MioUserScriptCore.swift 的 userscriptRuntime），
//   在页面里按 @match / @include / @exclude 自己判定、按 @run-at 调度。有 @grant 的脚本各自跑在独立的
//   WKContentWorld（mio.userscript.<id>）：与页面 JS 和其他脚本隔离，原生消息通道也只注册在它自己的 world 里；
//   @grant none 的脚本跑在页面世界（与页面共享 window），不提供需要原生的 GM API。
// - GM API：GM_addStyle、GM_getValue / setValue / deleteValue / listValues（按脚本隔离持久化到原生）、
//   GM_xmlhttpRequest（原生 URLSession 代发：与页面同主机直接放行；在 @connect 里的域名首次询问用户；不在 @connect 里的拒绝）、
//   GM_openInTab、GM_setClipboard、GM_info、unsafeWindow、GM_registerMenuCommand、GM_notification、GM_getResourceText、GM.* Promise 版。
//   限制：隔离 world 里的 unsafeWindow 就是该 world 的 window（DOM 共享，页面自己的 JS 变量看不到——与 Safari 上的扩展一致）。

import UIKit
import WebKit
import CryptoKit
import UniformTypeIdentifiers

// MARK: - Manager

final class MioUserScriptManager {
    static let shared = MioUserScriptManager()

    let store: MioUserScriptStore
    /// GM 值的变化计数：内置浏览器在下一次主框架导航前重建注入代码（代码里带着值的快照，GM_getValue 才能同步返回）
    private(set) var valuesVersion = 0

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        store = MioUserScriptStore(directory: base.appendingPathComponent("MioUserScripts", isDirectory: true))
    }

    var scripts: [MioUserScript] { store.scripts }

    /// 内置浏览器注入的脚本（每个启用的脚本一个 WKUserScript）
    func webKitScripts() -> [WKUserScript] {
        let platform = MioWebKitCompat.isMac ? "mac" : "ios"
        return store.scripts.filter { $0.enabled }.map { s -> WKUserScript in
            let src = MioUserScriptRuntime.source(for: s, values: s.isolated ? store.values.all(s.id) : [:],
                                                  appVersion: MioBrowserSettings.appVersion, platform: platform)
            let time: WKUserScriptInjectionTime = s.meta.runAt == .documentStart ? .atDocumentStart : .atDocumentEnd
            let world: WKContentWorld = s.isolated ? .world(name: s.worldName) : .page
            return WKUserScript(source: src, injectionTime: time, forMainFrameOnly: s.meta.noframes, in: world)
        }
    }

    /// 需要原生消息通道的 world（启用、且有 @grant 的脚本）
    var isolatedWorldNames: Set<String> {
        Set(store.scripts.filter { $0.enabled && $0.isolated }.map { $0.worldName })
    }

    @discardableResult
    func install(_ pkg: MioUserScriptPackage) -> MioUserScript {
        let s = store.install(pkg)
        changed()
        return s
    }

    func setEnabled(_ id: String, _ on: Bool) { store.setEnabled(id, on); changed() }
    func delete(_ id: String) { store.delete(id); changed() }

    func setValue(_ id: String, _ key: String, _ json: String) -> Bool {
        let ok = store.values.set(id, key, json)
        if ok { valuesVersion += 1 }
        return ok
    }

    func deleteValue(_ id: String, _ key: String) {
        store.values.delete(id, key)
        valuesVersion += 1
    }

    /// 内置浏览器（MioBrowser.swift 已监听这个通知）重建用户脚本；设置页刷新
    func changed() {
        NotificationCenter.default.post(name: .mioBrowserSettingsDidChange, object: nil)
    }
}

// MARK: - Download / install / update

enum MioUserScriptInstaller {
    static func download(_ url: URL) async throws -> String {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let fragment = comps?.fragment
        comps?.fragment = nil
        guard let target = comps?.url else { throw MioUserScriptError.download("无效地址") }
        var req = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        req.setValue("text/javascript, application/javascript, text/plain, */*", forHTTPHeaderField: "Accept")
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw MioUserScriptError.download(error.localizedDescription)
        }
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw MioUserScriptError.download("HTTP \(http.statusCode)（\(target.absoluteString)）")
        }
        guard data.count <= MioUserScriptParser.maxScriptBytes else { throw MioUserScriptError.tooLarge(data.count) }
        try verifyIntegrity(data, fragment: fragment, url: target)
        guard let s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw MioUserScriptError.download("无法解码文本")
        }
        return s
    }

    /// @require https://…/x.js#sha256=<hex 或 base64>（也认 sha384 / sha512、md5 跳过）
    static func verifyIntegrity(_ data: Data, fragment: String?, url: URL) throws {
        guard let f = fragment, !f.isEmpty else { return }
        for part in f.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            let kv = part.split(maxSplits: 1, whereSeparator: { $0 == "=" || $0 == "-" }).map(String.init)
            guard kv.count == 2 else { continue }
            let algo = kv[0].lowercased()
            let digest: Data
            switch algo {
            case "sha256": digest = Data(SHA256.hash(data: data))
            case "sha384": digest = Data(SHA384.hash(data: data))
            case "sha512": digest = Data(SHA512.hash(data: data))
            default: continue
            }
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            let want = kv[1]
            if want.lowercased() == hex || want == digest.base64EncodedString() { return }
            throw MioUserScriptError.download("\(url.lastPathComponent) 校验失败（\(algo)）")
        }
    }

    static func resolve(_ s: String, base: String?) -> URL? {
        let b = base.flatMap(URL.init(string:))
        guard let u = URL(string: s, relativeTo: b)?.absoluteURL, let sc = u.scheme?.lowercased(), sc == "http" || sc == "https" else { return nil }
        return u
    }

    /// 解析元数据并下载 @require / @resource（任何一个失败都不安装，与 Tampermonkey 一致）
    static func prepare(code: String, sourceURL: String?) async throws -> MioUserScriptPackage {
        let meta = try MioUserScriptParser.parse(code)
        var requires: [String: String] = [:]
        for r in meta.requires where requires[r] == nil {
            guard let u = resolve(r, base: sourceURL) else { throw MioUserScriptError.download("无效的 @require：\(r)") }
            requires[r] = try await download(u)
        }
        var resources: [String: String] = [:]
        for (name, r) in meta.resources {
            guard let u = resolve(r, base: sourceURL) else { throw MioUserScriptError.download("无效的 @resource：\(r)") }
            resources[name] = try await download(u)
        }
        return MioUserScriptPackage(meta: meta, code: code, requireCache: requires, resourceCache: resources, sourceURL: sourceURL)
    }

    static func prepare(url: URL) async throws -> MioUserScriptPackage {
        let code = try await download(url)
        return try await prepare(code: code, sourceURL: url.absoluteString)
    }

    /// 有新版本时返回准备好的包（还没安装）；没有更新返回 nil
    static func checkUpdate(_ s: MioUserScript) async throws -> MioUserScriptPackage? {
        guard let checkURL = MioUserScriptSource.updateCheckURL(meta: s.meta, sourceURL: s.sourceURL) else {
            throw MioUserScriptError.download("脚本没有 @updateURL / @downloadURL，也不是从网址安装的")
        }
        let text = try await download(checkURL)
        let remote = try MioUserScriptParser.parse(text)
        guard MioUserScriptVersion.isNewer(remote.version, than: s.meta.version) else { return nil }
        let isMetaOnly = checkURL.path.lowercased().hasSuffix(".meta.js")
        let code: String
        let source: String?
        if isMetaOnly {
            guard let dl = MioUserScriptSource.downloadURL(meta: remote, sourceURL: s.sourceURL) else {
                throw MioUserScriptError.download("找不到新版本的下载地址")
            }
            code = try await download(dl)
            source = s.sourceURL ?? dl.absoluteString
        } else {
            code = text
            source = s.sourceURL ?? checkURL.absoluteString
        }
        return try await prepare(code: code, sourceURL: source)
    }
}

// MARK: - Bridge（GM API 的原生端）

private final class MioUserScriptWeakHandler: NSObject, WKScriptMessageHandlerWithReply {
    weak var target: MioUserScriptBridge?
    init(_ t: MioUserScriptBridge) { target = t }
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        guard let t = target else { replyHandler(nil, "browser closed"); return }
        t.userContentController(ucc, didReceive: message, replyHandler: replyHandler)
    }
}

final class MioUserScriptBridge: NSObject, WKScriptMessageHandlerWithReply {
    /// 当前内置浏览器的桥（脚本列表页用它列出 / 执行本页的菜单命令）
    static weak var current: MioUserScriptBridge?
    private static let worldPrefix = "mio.userscript."

    weak var webView: WKWebView?
    weak var presenter: UIViewController?
    private let controller: WKUserContentController
    private var registered: Set<String> = []
    private var tasks: [String: URLSessionDataTask] = [:]
    private var seenValuesVersion = MioUserScriptManager.shared.valuesVersion
    private var pendingAsks: [String: [(Bool) -> Void]] = [:]
    private var observer: NSObjectProtocol?
    /// 主框架里脚本注册的菜单命令：scriptID → [(id, name)]
    private(set) var menus: [String: [(id: String, name: String)]] = [:]

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    init(controller: WKUserContentController) {
        self.controller = controller
        super.init()
        sync()
        observer = NotificationCenter.default.addObserver(forName: .mioBrowserSettingsDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.sync()
        }
        Self.current = self
    }

    deinit {
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        tasks.values.forEach { $0.cancel() }
    }

    /// 只给启用的、有 @grant 的脚本各自的 world 注册消息通道（同名重复注册会抛 ObjC 异常，所以记账）
    func sync() {
        let want = MioUserScriptManager.shared.isolatedWorldNames
        for name in want.subtracting(registered) {
            controller.addScriptMessageHandler(MioUserScriptWeakHandler(self), contentWorld: .world(name: name), name: MioUserScriptRuntime.handlerName)
        }
        for name in registered.subtracting(want) {
            controller.removeScriptMessageHandler(forName: MioUserScriptRuntime.handlerName, contentWorld: .world(name: name))
        }
        registered = want
    }

    func detach() {
        for name in registered {
            controller.removeScriptMessageHandler(forName: MioUserScriptRuntime.handlerName, contentWorld: .world(name: name))
        }
        registered = []
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
    }

    /// 主框架即将导航：清掉上一页的菜单命令；GM 值变过时返回 true（调用方重建注入代码）
    func willNavigateMainFrame() -> Bool {
        menus = [:]
        let v = MioUserScriptManager.shared.valuesVersion
        guard v != seenValuesVersion else { return false }
        seenValuesVersion = v
        return true
    }

    var menuItems: [(scriptID: String, scriptName: String, id: String, name: String)] {
        var out: [(String, String, String, String)] = []
        for s in MioUserScriptManager.shared.scripts {
            for c in menus[s.id] ?? [] { out.append((s.id, s.meta.displayName, c.id, c.name)) }
        }
        return out.map { (scriptID: $0.0, scriptName: $0.1, id: $0.2, name: $0.3) }
    }

    func runMenuCommand(scriptID: String, id: String) {
        guard let wv = webView, let s = MioUserScriptManager.shared.store.script(id: scriptID) else { return }
        let arg = MioJS.string(id)
        wv.evaluateJavaScript("window.__mioUserScriptMenu && window.__mioUserScriptMenu(\(arg)); void 0", in: nil, in: .world(name: s.worldName), completionHandler: nil)
    }

    // MARK: messages

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        let world = message.world.name ?? ""
        guard world.hasPrefix(Self.worldPrefix), let body = message.body as? [String: Any], let op = body["op"] as? String else {
            replyHandler(nil, "bad message")
            return
        }
        let id = String(world.dropFirst(Self.worldPrefix.count))
        // 脚本只能以自己的身份说话：world 名决定是哪个脚本，消息里的 id 必须一致
        guard (body["id"] as? String) == id, let script = MioUserScriptManager.shared.store.script(id: id), script.enabled else {
            replyHandler(nil, "script not found")
            return
        }
        switch op {
        case "setValue":
            guard let key = body["key"] as? String, let value = body["value"] as? String else { replyHandler(nil, "bad value"); return }
            if MioUserScriptManager.shared.setValue(id, key, value) { replyHandler(true, nil) } else { replyHandler(nil, "存储超出上限（每个脚本 5 MB）") }
        case "deleteValue":
            guard let key = body["key"] as? String else { replyHandler(nil, "bad key"); return }
            MioUserScriptManager.shared.deleteValue(id, key)
            replyHandler(true, nil)
        case "xhr":
            handleXHR(script: script, body: body, frame: message.frameInfo, reply: replyHandler)
        case "xhrAbort":
            if let r = body["reqId"] as? String, r.hasPrefix(id + ":") { tasks.removeValue(forKey: r)?.cancel() }
            replyHandler(true, nil)
        case "openTab":
            guard let s = body["url"] as? String, let url = URL(string: s), let sc = url.scheme?.lowercased(), sc == "http" || sc == "https" else {
                replyHandler(nil, "invalid url")
                return
            }
            // 内置浏览器是单页的：在当前浏览器里打开
            MioBrowserViewController.open(url, from: presenter)
            replyHandler(true, nil)
        case "setClipboard":
            let data = body["data"] as? String ?? ""
            let type = (body["type"] as? String ?? "text").lowercased()
            if type.contains("html") {
                UIPasteboard.general.items = [[UTType.html.identifier: data, UTType.utf8PlainText.identifier: data]]
            } else {
                UIPasteboard.general.string = data
            }
            replyHandler(true, nil)
        case "menu":
            if message.frameInfo.isMainFrame {
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

    private func handleXHR(script: MioUserScript, body: [String: Any], frame: WKFrameInfo, reply: @escaping (Any?, String?) -> Void) {
        guard let s = body["url"] as? String, let url = URL(string: s), let sc = url.scheme?.lowercased(), sc == "http" || sc == "https",
              let host = url.host, !host.isEmpty else {
            reply(["error": "不支持的地址"], nil)
            return
        }
        let pageHost = frame.securityOrigin.host
        let normalized = MioUserScriptConnect.normalizeHost(host)
        switch MioUserScriptConnect.verdict(target: host, pageHost: pageHost, connects: script.meta.connects) {
        case .sameOrigin:
            perform(url: url, body: body, reply: reply)
        case .undeclared:
            NSLog("⚡️ Mio userscript %@: %@ not in @connect, blocked", script.meta.name, host)
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
        if pendingAsks[key] != nil {
            pendingAsks[key]?.append(completion)
            return
        }
        pendingAsks[key] = [completion]
        let finish: (Bool) -> Void = { [weak self] allow in
            let cbs = self?.pendingAsks.removeValue(forKey: key) ?? []
            cbs.forEach { $0(allow) }
        }
        guard let top = MioBrowserViewController.topPresenter(presenter), top.view.window != nil else { finish(false); return }
        let a = UIAlertController(
            title: "允许脚本跨域访问？",
            message: "用户脚本「\(script.meta.displayName)」想向 \(host) 发送请求（脚本的 @connect 已声明该域名）。\n请求会带上你在该网站的 Cookie（登录状态）。",
            preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "拒绝", style: .cancel) { _ in
            MioUserScriptManager.shared.store.setConnectDecision(script.id, host: host, allow: false)
            finish(false)
        })
        a.addAction(UIAlertAction(title: "仅这一次", style: .default) { _ in finish(true) })
        a.addAction(UIAlertAction(title: "总是允许", style: .default) { _ in
            MioUserScriptManager.shared.store.setConnectDecision(script.id, host: host, allow: true)
            finish(true)
        })
        top.present(a, animated: true)
    }

    private func perform(url: URL, body: [String: Any], reply: @escaping (Any?, String?) -> Void) {
        guard let reqId = body["reqId"] as? String else { reply(["error": "bad request"], nil); return }
        var req = URLRequest(url: url)
        req.httpMethod = (body["method"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "GET"
        let timeoutMs = (body["timeout"] as? NSNumber)?.doubleValue ?? 0
        req.timeoutInterval = timeoutMs > 0 ? timeoutMs / 1000 : 120
        req.httpShouldHandleCookies = false
        var hasUA = false
        var hasAuth = false
        for (k, v) in body["headers"] as? [String: String] ?? [:] {
            let lk = k.lowercased()
            if lk == "user-agent" { hasUA = true }
            if lk == "authorization" { hasAuth = true }
            if lk == "host" || lk == "content-length" { continue }
            req.setValue(v, forHTTPHeaderField: k)
        }
        if !hasUA, let ua = body["userAgent"] as? String, !ua.isEmpty { req.setValue(ua, forHTTPHeaderField: "User-Agent") }
        if !hasAuth, let user = body["user"] as? String, !user.isEmpty {
            let pw = body["password"] as? String ?? ""
            req.setValue("Basic " + Data("\(user):\(pw)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
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
                DispatchQueue.main.async {
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
            if !matching.isEmpty {
                let fields = HTTPCookie.requestHeaderFields(with: matching)
                if let c = fields["Cookie"] {
                    let existing = r.value(forHTTPHeaderField: "Cookie")
                    r.setValue(existing.map { "\($0); \(c)" } ?? c, forHTTPHeaderField: "Cookie")
                }
            }
            start(r)
        }
    }

    static func cookie(_ c: HTTPCookie, matches url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if let exp = c.expiresDate, exp < Date() { return false }
        if c.isSecure, url.scheme?.lowercased() != "https" { return false }
        let domain = c.domain.lowercased()
        let domainOK: Bool
        if domain.hasPrefix(".") {
            domainOK = host == String(domain.dropFirst()) || host.hasSuffix(domain)
        } else {
            domainOK = host == domain
        }
        guard domainOK else { return false }
        let path = url.path.isEmpty ? "/" : url.path
        let cp = c.path.isEmpty ? "/" : c.path
        return path == cp || path.hasPrefix(cp.hasSuffix("/") ? cp : cp + "/")
    }

    private static func headerString(_ http: HTTPURLResponse?) -> String {
        guard let http = http else { return "" }
        return http.allHeaderFields.compactMap { k, v -> String? in
            guard let k = k as? String else { return nil }
            return "\(k.lowercased()): \(v)"
        }.sorted().joined(separator: "\r\n")
    }

    private static func decodeText(_ data: Data, response: HTTPURLResponse?, overrideMime: String) -> String {
        var charset: String?
        if let r = overrideMime.range(of: "charset=", options: .caseInsensitive) {
            charset = String(overrideMime[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " \"';"))
        }
        if charset == nil { charset = response?.textEncodingName }
        if let cs = charset {
            let cf = CFStringConvertIANACharSetNameToEncoding(cs as CFString)
            if cf != kCFStringEncodingInvalidId {
                let enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
                if let s = String(data: data, encoding: enc) { return s }
            }
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }
}

// MARK: - Install flow（列表页和浏览器共用）

final class MioFlag { var value = false }

enum MioUserScriptFlow {
    /// 用户在安装提示里选了「查看源码」：这一次放行，不再拦截
    private static var bypassOnce: URL?

    /// 浏览器主框架打开 *.user.js 时调用：true = 取消导航并弹出安装
    static func shouldIntercept(_ url: URL) -> Bool {
        guard MioUserScriptSource.looksLikeUserScript(url) else { return false }
        if let b = bypassOnce, b == url { bypassOnce = nil; return false }
        return true
    }

    /// 下载（显示进度）→ 安装确认页
    static func installFromURL(_ url: URL, from vc: UIViewController, viewSource: ((URL) -> Void)? = nil, completion: ((MioUserScript?) -> Void)? = nil) {
        let progress = UIAlertController(title: "正在下载脚本…", message: url.host, preferredStyle: .alert)
        let cancelled = MioFlag()
        progress.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in cancelled.value = true; completion?(nil) })
        vc.present(progress, animated: true)
        Task { @MainActor in
            do {
                let pkg = try await MioUserScriptInstaller.prepare(url: url)
                guard !cancelled.value else { return }
                progress.dismiss(animated: true) {
                    var onView: (() -> Void)?
                    if let cb = viewSource { onView = { MioUserScriptFlow.bypassOnce = url; cb(url) } }
                    MioUserScriptFlow.showConfirm(pkg, from: vc, viewSource: onView, completion: completion)
                }
            } catch {
                guard !cancelled.value else { return }
                progress.dismiss(animated: true) {
                    let a = UIAlertController(title: "无法安装脚本", message: error.localizedDescription, preferredStyle: .alert)
                    if let cb = viewSource {
                        a.addAction(UIAlertAction(title: "在浏览器中打开", style: .default) { _ in MioUserScriptFlow.bypassOnce = url; cb(url) })
                    }
                    a.addAction(UIAlertAction(title: "好", style: .cancel) { _ in completion?(nil) })
                    vc.present(a, animated: true)
                }
            }
        }
    }

    /// 粘贴 / 文件导入的代码：下载依赖 → 安装确认页
    static func installFromCode(_ code: String, sourceURL: String?, from vc: UIViewController, completion: ((MioUserScript?) -> Void)? = nil) {
        do {
            let meta = try MioUserScriptParser.parse(code)
            if meta.requires.isEmpty && meta.resources.isEmpty {
                showConfirm(MioUserScriptPackage(meta: meta, code: code, requireCache: [:], resourceCache: [:], sourceURL: sourceURL), from: vc, viewSource: nil, completion: completion)
                return
            }
        } catch {
            alert(vc, "无法安装脚本", error.localizedDescription)
            completion?(nil)
            return
        }
        let progress = UIAlertController(title: "正在下载 @require…", message: nil, preferredStyle: .alert)
        vc.present(progress, animated: true)
        Task { @MainActor in
            do {
                let pkg = try await MioUserScriptInstaller.prepare(code: code, sourceURL: sourceURL)
                progress.dismiss(animated: true) { MioUserScriptFlow.showConfirm(pkg, from: vc, viewSource: nil, completion: completion) }
            } catch {
                progress.dismiss(animated: true) { MioUserScriptFlow.alert(vc, "无法安装脚本", error.localizedDescription); completion?(nil) }
            }
        }
    }

    static func showConfirm(_ pkg: MioUserScriptPackage, from vc: UIViewController, viewSource: (() -> Void)?, completion: ((MioUserScript?) -> Void)?) {
        let confirm = MioUserScriptInstallViewController(package: pkg, viewSource: viewSource, completion: completion)
        let nav = UINavigationController(rootViewController: confirm)
        vc.present(nav, animated: true)
    }

    static func alert(_ vc: UIViewController, _ title: String, _ message: String?) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "好", style: .default))
        vc.present(a, animated: true)
    }
}

// MARK: - Script list

final class MioUserScriptsViewController: UITableViewController, UIDocumentPickerDelegate {
    private enum Row {
        case builtinYouTube, script(MioUserScript), empty, menu(scriptID: String, scriptName: String, id: String, name: String)
        case paste, fromURL, fromFile, checkAll
    }

    private var sections: [(title: String?, footer: String?, rows: [Row])] = []
    private var observer: NSObjectProtocol?
    private var checking = false

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let o = observer { NotificationCenter.default.removeObserver(o) } }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "用户脚本"
        observer = NotificationCenter.default.addObserver(forName: .mioBrowserSettingsDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.rebuild()
        }
        rebuild()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        rebuild()
    }

    private func rebuild() {
        var s: [(String?, String?, [Row])] = []
        let scripts = MioUserScriptManager.shared.scripts
        var installed: [Row] = scripts.map { .script($0) }
        if installed.isEmpty { installed = [.empty] }
        s.append(("已安装", "对之后打开的页面生效。点脚本可查看代码、检查更新或删除；左滑删除。", installed))
        if let items = MioUserScriptBridge.current?.menuItems, !items.isEmpty {
            s.append(("当前页面的脚本命令", nil, items.map { .menu(scriptID: $0.scriptID, scriptName: $0.scriptName, id: $0.id, name: $0.name) }))
        }
        s.append(("添加脚本", "支持 Greasy Fork、GitHub（blob / raw 链接）等任意 .user.js 地址；在内置浏览器里打开 .user.js 链接也会提示安装。", [.paste, .fromURL, .fromFile, .checkAll]))
        s.append(("内置", "YouTube 防沉迷已内置在 Mio 里，不需要导入脚本。", [.builtinYouTube]))
        sections = s.map { (title: $0.0, footer: $0.1, rows: $0.2) }
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].rows.count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { sections[section].title }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? { sections[section].footer }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.selectionStyle = .default
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.detailTextLabel?.numberOfLines = 2
        switch sections[indexPath.section].rows[indexPath.row] {
        case .builtinYouTube:
            cell.textLabel?.text = "YouTube 防沉迷（内置）"
            cell.detailTextLabel?.text = "隐藏 Shorts 推荐和入口，看 Shorts 时定时提醒"
            cell.selectionStyle = .none
            cell.accessoryView = makeSwitch(MioBrowserSettings.youtubeFocus) { MioBrowserSettings.youtubeFocus = $0 }
        case .script(let sc):
            cell.textLabel?.text = sc.meta.displayName + (sc.meta.version.isEmpty ? "" : "  v\(sc.meta.version)")
            var detail: [String] = []
            if !sc.meta.description.isEmpty { detail.append(sc.meta.description) }
            let targets = sc.meta.matches + sc.meta.includes
            detail.append(targets.isEmpty ? "所有网页" : targets.prefix(3).joined(separator: "  ") + (targets.count > 3 ? " …" : ""))
            cell.detailTextLabel?.text = detail.joined(separator: "\n")
            cell.accessoryView = makeSwitch(sc.enabled) { MioUserScriptManager.shared.setEnabled(sc.id, $0) }
        case .empty:
            cell.textLabel?.text = "还没有安装用户脚本"
            cell.textLabel?.textColor = .secondaryLabel
            cell.selectionStyle = .none
        case .menu(_, let scriptName, _, let name):
            cell.textLabel?.text = name
            cell.detailTextLabel?.text = scriptName
            cell.textLabel?.textColor = .systemBlue
        case .paste:
            cell.textLabel?.text = "粘贴代码…"
            cell.textLabel?.textColor = .systemBlue
        case .fromURL:
            cell.textLabel?.text = "从网址安装…"
            cell.textLabel?.textColor = .systemBlue
        case .fromFile:
            cell.textLabel?.text = "从文件导入…"
            cell.textLabel?.textColor = .systemBlue
        case .checkAll:
            cell.textLabel?.text = checking ? "正在检查更新…" : "检查全部更新"
            cell.textLabel?.textColor = .systemBlue
        }
        return cell
    }

    private func makeSwitch(_ on: Bool, _ change: @escaping (Bool) -> Void) -> UISwitch {
        let sw = UISwitch()
        sw.isOn = on
        sw.addAction(UIAction { action in
            if let s = action.sender as? UISwitch { change(s.isOn) }
        }, for: .valueChanged)
        return sw
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let cell = tableView.cellForRow(at: indexPath)
        switch sections[indexPath.section].rows[indexPath.row] {
        case .script(let sc): showActions(sc, cell: cell)
        case .menu(let sid, _, let id, _):
            MioUserScriptBridge.current?.runMenuCommand(scriptID: sid, id: id)
            dismiss(animated: true)
        case .paste:
            navigationController?.pushViewController(MioUserScriptEditorViewController(), animated: true)
        case .fromURL: askURL()
        case .fromFile: pickFile()
        case .checkAll: checkAll()
        default: break
        }
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        if case .script = sections[indexPath.section].rows[indexPath.row] { return true }
        return false
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete, case .script(let sc) = sections[indexPath.section].rows[indexPath.row] else { return }
        confirmDelete(sc)
    }

    private func showActions(_ sc: MioUserScript, cell: UITableViewCell?) {
        let a = MioActionList(title: sc.meta.displayName, message: summary(sc))
        a.add("查看代码") { [weak self] in
            self?.navigationController?.pushViewController(MioUserScriptCodeViewController(title: sc.meta.displayName, code: sc.code), animated: true)
        }
        a.add("检查更新") { [weak self] in self?.checkUpdate(sc) }
        if let home = sc.meta.homepage, let u = URL(string: home), u.scheme?.hasPrefix("http") == true {
            a.add("打开主页") { MioBrowserViewController.open(u, from: self) }
        }
        if !sc.connectDecisions.isEmpty {
            a.add("重置跨域授权（\(sc.connectDecisions.count)）") {
                for h in sc.connectDecisions.keys { MioUserScriptManager.shared.store.setConnectDecision(sc.id, host: h, allow: nil) }
            }
        }
        a.add("删除", style: .destructive) { [weak self] in self?.confirmDelete(sc) }
        a.present(from: self, sourceView: cell)
    }

    private func summary(_ sc: MioUserScript) -> String {
        var lines: [String] = []
        if !sc.meta.version.isEmpty { lines.append("版本 \(sc.meta.version)") }
        lines.append("运行时机 \(sc.meta.runAt.rawValue)\(sc.meta.noframes ? "（仅顶层页面）" : "")")
        lines.append(sc.isolated ? "隔离环境（@grant \(sc.meta.grants.joined(separator: ", "))）" : "页面环境（@grant none）")
        if !sc.meta.connects.isEmpty { lines.append("@connect \(sc.meta.connects.joined(separator: ", "))") }
        if let src = sc.sourceURL { lines.append("来源 \(src)") }
        let invalid = sc.rules.invalid
        if !invalid.isEmpty { lines.append("⚠️ 无法识别的规则：\(invalid.joined(separator: " "))") }
        return lines.joined(separator: "\n")
    }

    private func confirmDelete(_ sc: MioUserScript) {
        let a = UIAlertController(title: "删除「\(sc.meta.displayName)」？", message: "脚本保存的数据（GM_setValue）也会一起删除。", preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        a.addAction(UIAlertAction(title: "删除", style: .destructive) { _ in MioUserScriptManager.shared.delete(sc.id) })
        present(a, animated: true)
    }

    private func askURL() {
        let a = UIAlertController(title: "从网址安装", message: "输入 .user.js 地址、Greasy Fork 脚本页或 GitHub 文件链接", preferredStyle: .alert)
        a.addTextField { tf in
            tf.keyboardType = .URL
            tf.autocapitalizationType = .none
            tf.autocorrectionType = .no
            tf.placeholder = "https://greasyfork.org/scripts/…"
            if let s = UIPasteboard.general.string, s.hasPrefix("http") { tf.text = s.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        a.addAction(UIAlertAction(title: "下载", style: .default) { [weak self] _ in
            guard let self = self, let t = a.textFields?.first?.text else { return }
            guard let url = MioUserScriptSource.installURL(from: t) else {
                MioUserScriptFlow.alert(self, "地址无效", "请输入 http(s) 开头的网址")
                return
            }
            MioUserScriptFlow.installFromURL(url, from: self)
        })
        present(a, animated: true)
    }

    private func pickFile() {
        var types: [UTType] = [.javaScript, .plainText, .text, .sourceCode]
        if let js = UTType(filenameExtension: "js") { types.insert(js, at: 0) }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), data.count <= MioUserScriptParser.maxScriptBytes,
              let code = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            MioUserScriptFlow.alert(self, "无法读取文件", url.lastPathComponent)
            return
        }
        MioUserScriptFlow.installFromCode(code, sourceURL: nil, from: self)
    }

    private func checkUpdate(_ sc: MioUserScript) {
        let progress = UIAlertController(title: "正在检查更新…", message: sc.meta.displayName, preferredStyle: .alert)
        present(progress, animated: true)
        Task { @MainActor in
            do {
                let pkg = try await MioUserScriptInstaller.checkUpdate(sc)
                MioUserScriptManager.shared.store.markChecked(sc.id)
                progress.dismiss(animated: true) {
                    if let pkg = pkg {
                        MioUserScriptFlow.showConfirm(pkg, from: self, viewSource: nil, completion: nil)
                    } else {
                        MioUserScriptFlow.alert(self, "已是最新版本", "\(sc.meta.displayName) v\(sc.meta.version)")
                    }
                }
            } catch {
                progress.dismiss(animated: true) { MioUserScriptFlow.alert(self, "检查更新失败", error.localizedDescription) }
            }
        }
    }

    private func checkAll() {
        guard !checking else { return }
        let list = MioUserScriptManager.shared.scripts.filter { MioUserScriptSource.updateCheckURL(meta: $0.meta, sourceURL: $0.sourceURL) != nil }
        guard !list.isEmpty else { MioUserScriptFlow.alert(self, "没有可检查更新的脚本", "只有从网址安装、或声明了 @updateURL / @downloadURL 的脚本能检查更新。"); return }
        checking = true
        rebuild()
        Task { @MainActor in
            var updated: [String] = []
            var failed: [String] = []
            for sc in list {
                do {
                    if let pkg = try await MioUserScriptInstaller.checkUpdate(sc) {
                        MioUserScriptManager.shared.install(pkg)
                        updated.append("\(pkg.meta.displayName) → v\(pkg.meta.version)")
                    }
                    MioUserScriptManager.shared.store.markChecked(sc.id)
                } catch {
                    failed.append("\(sc.meta.displayName)：\(error.localizedDescription)")
                }
            }
            checking = false
            rebuild()
            var msg = updated.isEmpty ? "全部已是最新版本。" : "已更新：\n" + updated.joined(separator: "\n")
            if !failed.isEmpty { msg += "\n\n失败：\n" + failed.joined(separator: "\n") }
            MioUserScriptFlow.alert(self, "检查完成", msg)
        }
    }
}

// MARK: - Install confirmation

final class MioUserScriptInstallViewController: UITableViewController {
    private let pkg: MioUserScriptPackage
    private let viewSource: (() -> Void)?
    private let completion: ((MioUserScript?) -> Void)?
    private var rows: [(String, String)] = []
    private var finished = false

    init(package: MioUserScriptPackage, viewSource: (() -> Void)?, completion: ((MioUserScript?) -> Void)?) {
        pkg = package
        self.viewSource = viewSource
        self.completion = completion
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        let existing = MioUserScriptManager.shared.store.existing(for: pkg.meta)
        title = existing == nil ? "安装用户脚本" : "更新用户脚本"
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: existing == nil ? "安装" : "更新", style: .done, target: self, action: #selector(installTapped))
        let m = pkg.meta
        rows.append(("名称", m.displayName))
        if !m.version.isEmpty {
            rows.append(("版本", existing.map { "\($0.meta.version) → \(m.version)" } ?? m.version))
        }
        if !m.description.isEmpty { rows.append(("说明", m.description)) }
        if !m.author.isEmpty { rows.append(("作者", m.author)) }
        let targets = m.matches + m.includes
        rows.append(("运行在", targets.isEmpty ? "所有网页" : targets.joined(separator: "\n")))
        if !(m.excludes + m.excludeMatches).isEmpty { rows.append(("排除", (m.excludes + m.excludeMatches).joined(separator: "\n"))) }
        rows.append(("运行时机", m.runAt.rawValue + (m.noframes ? "，仅顶层页面" : "，包括 iframe")))
        rows.append(("权限", m.grantsNone ? "无（@grant none，页面环境）" : m.grants.joined(separator: "\n")))
        if !m.connects.isEmpty { rows.append(("可跨域访问（首次询问）", m.connects.joined(separator: "\n"))) }
        if !m.requires.isEmpty { rows.append(("@require（已下载）", m.requires.joined(separator: "\n"))) }
        if !m.resources.isEmpty { rows.append(("@resource", m.resources.keys.sorted().joined(separator: "\n"))) }
        if let src = pkg.sourceURL { rows.append(("来源", src)) }
        let invalid = MioUserScriptRules(meta: m).invalid
        if !invalid.isEmpty { rows.append(("⚠️ 无法识别的规则（忽略）", invalid.joined(separator: "\n"))) }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if !finished, isBeingDismissed || navigationController?.isBeingDismissed == true {
            finished = true
            completion?(nil)
        }
    }

    @objc private func cancelTapped() {
        finished = true
        dismiss(animated: true) { self.completion?(nil) }
    }

    @objc private func installTapped() {
        finished = true
        let s = MioUserScriptManager.shared.install(pkg)
        dismiss(animated: true) { self.completion?(s) }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 3 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return rows.count
        case 1: return viewSource == nil ? 1 : 2
        default: return 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 2 ? "只安装你信任的脚本：脚本可以读取和修改它运行的网页（包括登录后的内容）。" : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.detailTextLabel?.numberOfLines = 0
        cell.detailTextLabel?.textColor = .label
        cell.textLabel?.textColor = .secondaryLabel
        cell.textLabel?.font = .systemFont(ofSize: 13)
        cell.selectionStyle = .none
        switch indexPath.section {
        case 0:
            cell.textLabel?.text = rows[indexPath.row].0
            cell.detailTextLabel?.text = rows[indexPath.row].1
        case 1:
            cell.selectionStyle = .default
            cell.textLabel?.font = .systemFont(ofSize: 17)
            cell.textLabel?.textColor = .systemBlue
            cell.textLabel?.text = indexPath.row == 0 ? "查看代码（\(pkg.code.count) 字符）" : "在浏览器中查看源码（不安装）"
        default:
            cell.textLabel?.font = .systemFont(ofSize: 17)
            cell.textLabel?.textColor = .systemBlue
            cell.textLabel?.text = MioUserScriptManager.shared.store.existing(for: pkg.meta) == nil ? "安装" : "更新"
            cell.selectionStyle = .default
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch (indexPath.section, indexPath.row) {
        case (1, 0):
            navigationController?.pushViewController(MioUserScriptCodeViewController(title: pkg.meta.displayName, code: pkg.code), animated: true)
        case (1, 1):
            finished = true
            dismiss(animated: true) { self.completion?(nil); self.viewSource?() }
        case (2, _):
            installTapped()
        default:
            break
        }
    }
}

// MARK: - Code viewer / paste editor

final class MioUserScriptCodeViewController: UIViewController {
    private let code: String

    init(title: String, code: String) {
        self.code = code
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let tv = UITextView()
        tv.isEditable = false
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.text = code
        tv.alwaysBounceVertical = true
        tv.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tv)
        NSLayoutConstraint.activate([
            tv.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tv.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            tv.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            tv.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
        ])
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "拷贝", style: .plain, target: self, action: #selector(copyTapped))
    }

    @objc private func copyTapped() { UIPasteboard.general.string = code }
}

final class MioUserScriptEditorViewController: UIViewController {
    private let textView = UITextView()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "粘贴脚本代码"
        view.backgroundColor = .systemBackground
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.spellCheckingType = .no
        textView.translatesAutoresizingMaskIntoConstraints = false
        if let s = UIPasteboard.general.string, s.contains("==UserScript==") { textView.text = s }
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
            textView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
        ])
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: "安装", style: .done, target: self, action: #selector(installTapped)),
            UIBarButtonItem(title: "粘贴", style: .plain, target: self, action: #selector(pasteTapped)),
        ]
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if textView.text.isEmpty { textView.becomeFirstResponder() }
    }

    @objc private func pasteTapped() {
        if let s = UIPasteboard.general.string { textView.text = s }
    }

    @objc private func installTapped() {
        let code = textView.text ?? ""
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        textView.resignFirstResponder()
        MioUserScriptFlow.installFromCode(code, sourceURL: nil, from: self) { [weak self] s in
            if s != nil { self?.navigationController?.popViewController(animated: true) }
        }
    }
}

// MARK: - CI 冒烟（Mac：MioDesktop.runSmoke 在 YouTube 检查之后调用）

enum MioUserScriptSmoke {
    static let code = """
    // ==UserScript==
    // @name         Mio Smoke (isolated)
    // @namespace    mio.smoke
    // @version      1
    // @match        https://example.com/*
    // @run-at       document-end
    // @grant        GM_getValue
    // @grant        GM_setValue
    // @grant        GM_addStyle
    // ==/UserScript==
    GM_addStyle('html{--mio-smoke:1}');
    var n = GM_getValue('n', 0);
    GM_setValue('n', n + 1);
    document.documentElement.setAttribute('data-mio-smoke', 'isolated:' + typeof GM_info + ':' + typeof GM_setValue + ':' + (typeof window.__mioSmokePage));
    """

    static let pageCode = """
    // ==UserScript==
    // @name         Mio Smoke (page)
    // @namespace    mio.smoke
    // @match        https://example.com/*
    // @run-at       document-start
    // @grant        none
    // ==/UserScript==
    window.__mioSmokePage = 1;
    """

    /// 1) 当前页（YouTube，WebRTC 默认屏蔽）：RTCPeerConnection 应为 undefined
    /// 2) 装两个测试脚本（隔离 world + 页面世界）、把 example.com 加入 WebRTC 放行列表，打开 https://example.com/：
    ///    RTCPeerConnection 可用、两个脚本都运行、隔离脚本看不到页面世界的变量、GM_setValue 写到原生
    /// 结束后删除测试脚本、恢复放行列表
    static func run(completion: @escaping ([String: Any], Bool) -> Void) {
        var report: [String: Any] = [:]
        MioBrowserViewController.smokeEvaluate(MioWebRTCGuard.probeScript) { result, error in
            let blocked = parse(result)
            report["webrtcBlockedPage"] = blocked.map { $0 as Any } ?? "error: \(String(describing: error))"
            // 屏蔽：脚本已处理（guard = true）且 RTCPeerConnection 不存在
            let blockedOK = !MioWebRTCSettings.enabled || ((blocked?["pc"] as? String) == "undefined" && (blocked?["guard"] as? Bool) == true)
            let allowBefore = MioWebRTCSettings.allowlist
            let iso: MioUserScript
            let page: MioUserScript
            do {
                iso = MioUserScriptManager.shared.install(MioUserScriptPackage(meta: try MioUserScriptParser.parse(code), code: code, requireCache: [:], resourceCache: [:], sourceURL: nil))
                page = MioUserScriptManager.shared.install(MioUserScriptPackage(meta: try MioUserScriptParser.parse(pageCode), code: pageCode, requireCache: [:], resourceCache: [:], sourceURL: nil))
            } catch {
                report["error"] = "\(error)"
                completion(report, false)
                return
            }
            MioWebRTCSettings.setAllowed("example.com", true)
            MioBrowserViewController.open(URL(string: "https://example.com/")!, from: nil)
            let deadline = Date().addingTimeInterval(25)
            func cleanup() {
                MioUserScriptManager.shared.delete(iso.id)
                MioUserScriptManager.shared.delete(page.id)
                MioWebRTCSettings.allowlist = allowBefore
            }
            func poll() {
                let js = "JSON.stringify({host: location.hostname, ready: document.readyState, smoke: document.documentElement.getAttribute('data-mio-smoke'), page: typeof window.__mioSmokePage, rtc: \(MioWebRTCGuard.probeScript)})"
                MioBrowserViewController.smokeEvaluate(js) { result, _ in
                    let obj = parse(result)
                    let ready = (obj?["host"] as? String) == "example.com" && (obj?["ready"] as? String) == "complete" && obj?["smoke"] is String
                    if !ready && Date() < deadline {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { poll() }
                        return
                    }
                    // GM_setValue 经原生持久化（给消息一点时间）
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        report["example"] = obj.map { $0 as Any } ?? "none"
                        let rtc = (obj?["rtc"] as? String).flatMap { parse($0) }
                        report["webrtcAllowedPage"] = rtc.map { $0 as Any } ?? "none"
                        let stored = MioUserScriptManager.shared.store.values.get(iso.id, "n")
                        report["gmValueStored"] = stored ?? "nil"
                        // 放行：脚本明确跳过（guard = false），页面拿到的是 WKWebView 原生的接口。
                        // CI 的 macOS VM 上 WKWebView 原生没有 RTCPeerConnection，所以「原生是否可用」只记录不作门槛；
                        // 真正的可用性由 Windows 冒烟（Chromium）和真机确认
                        let allowedOK = (rtc?["guard"] as? Bool) == false
                        report["nativeWebRTCOnAllowedPage"] = (rtc?["pc"] as? String) == "function"
                        report["nativeWebRTCPrefs"] = MioWebRTCGuard.nativePrefs
                        let scriptOK = (obj?["smoke"] as? String) == "isolated:object:function:undefined" && (obj?["page"] as? String) == "number" && stored == "1"
                        report["webrtcOK"] = blockedOK && allowedOK
                        report["userscriptsOK"] = scriptOK
                        cleanup()
                        completion(report, blockedOK && allowedOK && scriptOK)
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { poll() }
        }
    }

    private static func parse(_ v: Any?) -> [String: Any]? {
        guard let s = v as? String else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]
    }
}
