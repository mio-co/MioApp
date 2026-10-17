// MioTranslateModule.swift — 网页翻译（mio-translate.js + 原生网络代发 / 缓存）。key 沿用 v0.3.x 的 mio.translate.*。
// 原生消息 mioTranslate（页面世界，只认主框架 + 本进程随机 token）：fetch（MioTranslateCore.check 白名单校验后代发）、cacheGet / cachePut、setPref(ytSubs)。
// OpenAI 兼容 API Key 存钥匙串（MioSecretStore，name = translate.openai，与 v0.3.x 同一个钥匙串条目）。

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public final class MioTranslateModule: MioModuleMessageHandling {
    public static func key(_ k: String) -> String { "mio.translate." + k }
    public static let messageName = "mioTranslate"
    public static let secretName = "translate.openai"

    public let id = "translate"
    public let title = "翻译"
    public let summary = "整页双语对照 / 仅译文、划词翻译、YouTube 双语字幕；可指定网站自动翻译。"
    public let symbol = "character.bubble"
    public let section = MioSettingsSection.extensions
    /// 新 key（v0.3.x 翻译没有总开关，默认开 = 行为不变）
    public var enabledKey: String? { "mio.kit.module.translate.enabled" }

    /// 每次启动换一个；页面脚本发消息必须带上（防其他脚本冒用代发通道）
    public let token = MioTranslateCore.makeToken()
    public let secrets: MioSecretStore
    public let cache: MioTranslateCache
    public var template: String? = MioKitResources.script("mio-translate")
    /// 网络（可替换，单测用）
    public var send: (URLRequest) async -> (Int, Data?, String?) = { req in
        do {
            let (d, r) = try await MioTranslateModule.session.data(for: req)
            return ((r as? HTTPURLResponse)?.statusCode ?? 0, d, nil)
        } catch {
            let ns = error as NSError
            return (0, nil, ns.code == NSURLErrorTimedOut ? "timeout" : ns.localizedDescription)
        }
    }

    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieAcceptPolicy = .never
        c.httpShouldSetCookies = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForResource = 120
        c.httpAdditionalHeaders = ["User-Agent": MioWebKitCompat.desktopUserAgent]
        return URLSession(configuration: c)
    }()

    public init(secrets: MioSecretStore = MioKeychainSecretStore.shared, cache: MioTranslateCache = MioTranslateCache()) {
        self.secrets = secrets
        self.cache = cache
    }

    public var settings: [MioModuleSetting] {
        [
            MioModuleSetting(key: Self.key("target"), title: "翻译成",
                             kind: .choice(options: MioTranslateCore.languages.map { MioChoiceOption(.string($0.code), $0.name) }, default: .string("zh-CN"))),
            MioModuleSetting(key: Self.key("engine"), title: "翻译服务",
                             kind: .choice(options: MioTranslateCore.engines.map { MioChoiceOption(.string($0.id), $0.name) }, default: .string("microsoft"))),
            MioModuleSetting(key: Self.key("display"), title: "显示方式",
                             kind: .choice(options: [MioChoiceOption(.string("bilingual"), "双语对照"), MioChoiceOption(.string("translation"), "仅显示译文")], default: .string("bilingual"))),
            MioModuleSetting(key: Self.key("selection"), title: "划词翻译", kind: .toggle(default: true)),
            MioModuleSetting(key: Self.key("youtube"), title: "YouTube 双语字幕", kind: .toggle(default: true)),
            MioModuleSetting(key: Self.key("autoSites"), title: "自动翻译的网站", kind: .stringList(placeholder: "example.com"),
                             footer: "打开这些网站（含子域名）时自动翻译。"),
            MioModuleSetting(key: Self.key("openaiBase"), title: "API 地址", kind: .text(default: "", placeholder: "https://api.openai.com/v1"),
                             visibleWhen: .init(key: Self.key("engine"), equals: .string("openai"))),
            MioModuleSetting(key: Self.key("openaiModel"), title: "模型", kind: .text(default: "", placeholder: "gpt-4o-mini"),
                             visibleWhen: .init(key: Self.key("engine"), equals: .string("openai"))),
            MioModuleSetting(key: Self.secretName, title: "API Key", kind: .text(default: "", placeholder: "sk-…", secure: true),
                             footer: "存在钥匙串里（key 只做标识，宿主用 MioTranslateModule.setAPIKey 写入，不要写进 UserDefaults）。",
                             visibleWhen: .init(key: Self.key("engine"), equals: .string("openai"))),
            MioModuleSetting(key: Self.key("openaiPrompt"), title: "提示词（可选）", kind: .text(default: "", placeholder: "留空用默认", secure: false),
                             visibleWhen: .init(key: Self.key("engine"), equals: .string("openai"))),
            MioModuleSetting(key: "translate.clearCache", title: "清除翻译缓存", kind: .action(title: "清除")),
        ]
    }

    // MARK: 设置读取（与 v0.3.x MioTranslateSettings 相同的默认值 / 校验）

    public func config(_ prefs: MioPrefs) -> MioTranslateCore.Config {
        let target = { () -> String in let v = prefs.string(Self.key("target"), default: "zh-CN"); return MioTranslateCore.languages.contains { $0.code == v } ? v : "zh-CN" }()
        let engine = { () -> String in let v = prefs.string(Self.key("engine"), default: "microsoft"); return MioTranslateCore.engines.contains { $0.id == v } ? v : "microsoft" }()
        let display = prefs.string(Self.key("display"), default: "bilingual") == "translation" ? "translation" : "bilingual"
        let base = MioTranslateCore.normalizeBase(prefs.string(Self.key("openaiBase"), default: ""))
        let model = prefs.string(Self.key("openaiModel"), default: "").trimmingCharacters(in: .whitespacesAndNewlines)
        let ready = !base.isEmpty && !model.isEmpty && (secrets.secret(Self.secretName)?.isEmpty == false)
        return MioTranslateCore.Config(token: token, platform: MioKitInfo.platform, target: target, engine: engine, display: display,
                                       autoSites: autoSites(prefs), selection: prefs.bool(Self.key("selection"), default: true),
                                       youtube: prefs.bool(Self.key("youtube"), default: true), ytSubs: prefs.bool(Self.key("ytSubs"), default: true),
                                       openaiBase: base, openaiModel: model, openaiPrompt: String(prefs.string(Self.key("openaiPrompt"), default: "").prefix(2000)),
                                       openaiReady: ready)
    }

    public func autoSites(_ prefs: MioPrefs) -> [String] {
        Array(Set(prefs.strings(Self.key("autoSites")).compactMap { MioTranslateCore.normalizeHost($0) })).sorted()
    }

    public func setAPIKey(_ key: String?) { secrets.setSecret(Self.secretName, key) }

    // MARK: MioModule

    public func scripts(prefs: MioPrefs) -> [MioModuleScript] {
        guard let t = template, let src = MioTranslateCore.script(template: t, config: config(prefs)) else { return [] }
        return [MioModuleScript(source: src, injection: .documentStart, mainFrameOnly: true, world: .page)]
    }

    public func menuItems(page: MioPageContext, prefs: MioPrefs) -> [MioModuleMenuItem] {
        guard let h = page.host, let norm = MioTranslateCore.normalizeHost(h), page.url?.scheme?.hasPrefix("http") == true else { return [] }
        let auto = MioTranslateCore.isAuto(host: h, sites: autoSites(prefs))
        return [
            MioModuleMenuItem(moduleID: id, itemID: "translate", title: "翻译此页", symbol: "character.bubble"),
            MioModuleMenuItem(moduleID: id, itemID: "original", title: "显示原文", symbol: "arrow.uturn.backward"),
            MioModuleMenuItem(moduleID: id, itemID: auto ? "autoOff" : "autoOn", title: auto ? "不再自动翻译 \(norm)" : "总是翻译 \(norm)", symbol: "wand.and.stars", checked: auto),
        ]
    }

    public func perform(_ itemID: String, page: MioPageContext, prefs: MioPrefs) -> MioModuleAction {
        switch itemID {
        case "translate":
            let mode = config(prefs).display
            return .evaluateJavaScript("window.__mioTranslate && window.__mioTranslate.setMode('\(mode)'); void 0", world: .page)
        case "original":
            return .evaluateJavaScript("window.__mioTranslate && window.__mioTranslate.setMode('off'); void 0", world: .page)
        case "autoOn", "autoOff":
            guard let h = page.host, let norm = MioTranslateCore.normalizeHost(h) else { return .none }
            var sites = autoSites(prefs)
            if itemID == "autoOn" { sites.append(norm) } else { sites = sites.filter { $0 != norm && !MioTranslateCore.hostMatches(h, $0) } }
            prefs.set(Array(Set(sites)).sorted(), forKey: Self.key("autoSites"))
            return .reload
        default:
            return .none
        }
    }

    public func performSettingAction(_ key: String, prefs: MioPrefs) async -> String? {
        guard key == "translate.clearCache" else { return nil }
        cache.clear()
        return "翻译缓存已清除"
    }

    // MARK: 原生通道

    public func messageEndpoints(prefs: MioPrefs) -> [MioMessageEndpoint] { [MioMessageEndpoint(name: Self.messageName, world: .page)] }

    public func handle(_ message: MioScriptMessage, prefs: MioPrefs) async -> MioScriptReply {
        guard message.isMainFrame, let body = message.body as? [String: Any], (body["t"] as? String) == token, let op = body["op"] as? String else {
            return .error("forbidden")
        }
        switch op {
        case "fetch":
            guard let req = body["req"] as? [String: Any] else { return .value(["error": "bad request"]) }
            return .value(await fetch(req, prefs: prefs))
        case "cacheGet":
            let keys = ((body["keys"] as? [Any]) ?? []).compactMap { $0 as? String }
            return .value(["values": cache.get(keys)])
        case "cachePut":
            var entries: [String: String] = [:]
            for (k, v) in (body["entries"] as? [String: Any]) ?? [:] { if let s = v as? String { entries[k] = s } }
            cache.put(entries)
            return .value(["ok": true])
        case "setPref":
            if (body["key"] as? String) == "ytSubs", let v = body["value"] as? Bool {
                prefs.set(v, forKey: Self.key("ytSubs")) // 不重建脚本，下次加载生效
                return .value(["ok": true])
            }
            return .value(["error": "unknown pref"])
        default:
            return .value(["error": "unknown op"])
        }
    }

    func fetch(_ req: [String: Any], prefs: MioPrefs) async -> [String: Any] {
        let checked: MioTranslateCore.CheckedRequest
        switch MioTranslateCore.check(req, openaiBase: config(prefs).openaiBase) {
        case .failure(let e): return ["error": e.description]
        case .success(let c): checked = c
        }
        var r = URLRequest(url: checked.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: checked.timeout)
        r.httpMethod = checked.method
        for (k, v) in checked.headers { r.setValue(v, forHTTPHeaderField: k) }
        if checked.openAIAuth {
            guard let key = secrets.secret(Self.secretName), !key.isEmpty else { return ["error": "没有设置 API Key"] }
            r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        if let b = checked.body { r.httpBody = Data(b.utf8) }
        let (status, data, err) = await send(r)
        if let err = err { return ["error": err] }
        var d = data ?? Data()
        if d.count > MioTranslateCore.maxResponse { d = d.prefix(MioTranslateCore.maxResponse) }
        let text = String(decoding: d, as: UTF8.self)
        if let p = checked.picks { return ["status": status, "picks": MioTranslateCore.runPicks(text, p)] }
        return ["status": status, "body": text]
    }
}

/// 翻译结果持久缓存（LRU 2 万条，Caches/mio-translate-cache.json，与 v0.3.x 同一个文件）
public final class MioTranslateCache {
    private let queue = DispatchQueue(label: "mio.kit.translate.cache")
    private var lru: MioTranslateLRU?
    private var saveScheduled = false
    let file: URL?

    public init(file: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("mio-translate-cache.json")) {
        self.file = file
    }

    private func loaded() -> MioTranslateLRU {
        if let l = lru { return l }
        let l = file.flatMap { try? Data(contentsOf: $0) }.map { MioTranslateLRU.decode($0) } ?? MioTranslateLRU()
        lru = l
        return l
    }

    public func get(_ keys: [String]) -> [String: String] {
        queue.sync {
            var l = loaded()
            let out = l.get(keys)
            lru = l
            return out
        }
    }

    public func put(_ entries: [String: String]) {
        queue.sync {
            var l = loaded()
            l.put(entries)
            lru = l
        }
        scheduleSave()
    }

    public func clear() {
        queue.sync {
            lru = MioTranslateLRU()
            if let f = file { try? FileManager.default.removeItem(at: f) }
        }
    }

    public var count: Int { queue.sync { loaded().count } }

    private func scheduleSave() {
        queue.async {
            guard !self.saveScheduled else { return }
            self.saveScheduled = true
            self.queue.asyncAfter(deadline: .now() + 3) { self.saveNow() }
        }
    }

    private func saveNow() {
        saveScheduled = false
        guard let l = lru, let f = file else { return }
        try? l.encode().write(to: f, options: .atomic)
    }

    /// 进入后台时宿主调用
    public func flush() { queue.async { self.saveNow() } }
}
