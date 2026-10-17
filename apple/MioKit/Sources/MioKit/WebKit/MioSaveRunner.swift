// MioSaveRunner.swift — 「保存到 Mio」的执行端：在一个看不见的 WKWebView 里打开 MioCore 来源（用默认容器的数据存储 = 已登录的会话），
// 在独立 world 里执行 mio-save.js（同源 fetch 带上 Cookie / Cloudflare Access）。宿主收到 .host(.saveToMio) 时调用。
//
//   let runner = MioSaveRunner(kit: kit, dataStore: dataStores.dataStore(for: "default"))
//   let r = await runner.save(kind: "bookmark", payloadJSON: json)   // { ok, kind, id, … } | { ok: false, code: 'auth'|'network'|…, message }
//   let msg = MioSaveKind.message(for: r)                             // 给用户看的一句话（v0.3.x 同一份文案）

#if canImport(WebKit)
import Foundation
import WebKit

@MainActor
public final class MioSaveRunner: NSObject {
    public let kit: MioKitContainer
    let dataStore: WKWebsiteDataStore
    private var webView: WKWebView?
    private var loading: CheckedContinuation<Bool, Never>?
    private var navDelegate: MioSaveNavigationDelegate?
    /// 可选：MioCore API 令牌（设置里填了时加 Authorization: Bearer）
    public var apiToken: String?

    public init(kit: MioKitContainer, dataStore: WKWebsiteDataStore) {
        self.kit = kit
        self.dataStore = dataStore
    }

    public func save(kind: String, payloadJSON: String) async -> [String: Any] {
        guard let src = MioKitResources.script("mio-save") else { return ["ok": false, "code": "invalid", "message": "mio-save.js 未打包"] }
        let payload = (try? JSONSerialization.jsonObject(with: Data(payloadJSON.utf8))) as? [String: Any] ?? [:]
        guard await ensureLoaded(), let wv = webView else { return ["ok": false, "code": "network", "message": "打不开 MioCore"] }
        guard MioCoreOrigin.isMioCore(wv.url, prefs: kit.prefs) else { return ["ok": false, "code": "auth", "message": "需要先在 Mio 主页登录"] }
        var opts: [String: Any] = ["origin": MioCoreOrigin.configured(kit.prefs).description,
                                   "category": kit.prefs.string(MioPageToolsDefaults.saveCategoryKey, default: MioPageToolsDefaults.defaultCategory)]
        if let t = apiToken, !t.isEmpty { opts["token"] = t }
        let r = await MioWebViewModules.callAsync(wv, MioPageScripts.saveBody(source: src), arguments: ["kind": kind, "payload": payload, "opts": opts],
                                                  world: .world(name: "mio-save"))
        return r as? [String: Any] ?? ["ok": false, "code": "server", "message": "没有结果（脚本出错或超时）"]
    }

    private func ensureLoaded() async -> Bool {
        if let wv = webView, MioCoreOrigin.isMioCore(wv.url, prefs: kit.prefs) { return true }
        let c = WKWebViewConfiguration()
        c.websiteDataStore = dataStore
        let wv = WKWebView(frame: .zero, configuration: c)
        let d = MioSaveNavigationDelegate { [weak self] ok in self?.loaded(ok) }
        navDelegate = d
        wv.navigationDelegate = d
        webView = wv
        // robots.txt：同源、很轻（不跑 MioCore 前端）
        wv.load(URLRequest(url: MioCoreOrigin.originURL(kit.prefs).appendingPathComponent("robots.txt"), timeoutInterval: 20))
        return await withCheckedContinuation { self.loading = $0 }
    }

    func loaded(_ ok: Bool) { loading?.resume(returning: ok); loading = nil }
}

final class MioSaveNavigationDelegate: NSObject, WKNavigationDelegate {
    let done: @MainActor (Bool) -> Void
    init(_ done: @escaping @MainActor (Bool) -> Void) { self.done = done }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { let d = done; Task { @MainActor in d(true) } }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { let d = done; Task { @MainActor in d(false) } }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { let d = done; Task { @MainActor in d(false) } }
}
#endif
