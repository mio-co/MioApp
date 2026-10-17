// MioTranslate.swift — 内置浏览器的轻量翻译（iOS / Mac Catalyst）
// - 页面脚本：shared/translate/mio-translate.js（App 资源，document-start，主框架，页面主世界）
//   网页双语对照 / 仅译文、划词翻译、YouTube 双语字幕
// - 原生桥：WKScriptMessageHandlerWithReply（mioTranslate），带每次启动随机的 token；
//   网络请求在原生发（不受页面 CSP / CORS 影响），只放行翻译引擎域名 + 用户配置的 OpenAI 地址
// - OpenAI 兼容 API 的 Key 存钥匙串（kSecClassGenericPassword），只在原生加到请求头
// - 设置：UserDefaults mio.translate.*；设置页 MioTranslateSettingsViewController（浏览器设置里的「翻译」）
// 纯逻辑（请求校验 / 缓存 / 配置）在 MioTranslateCore.swift，单测在 tools/MioAppTests。

import UIKit
import WebKit
import Security

extension Notification.Name {
    static let mioTranslateSettingsDidChange = Notification.Name("mio.translate.settingsDidChange")
}

// MARK: - Settings

enum MioTranslateSettings {
    private static let d = UserDefaults.standard
    private static func key(_ k: String) -> String { "mio.translate." + k }

    static var target: String {
        get { let v = d.string(forKey: key("target")) ?? "zh-CN"; return MioTranslateCore.languages.contains { $0.code == v } ? v : "zh-CN" }
        set { d.set(newValue, forKey: key("target")); changed() }
    }

    static var engine: String {
        get { let v = d.string(forKey: key("engine")) ?? "microsoft"; return MioTranslateCore.engines.contains { $0.id == v } ? v : "microsoft" }
        set { d.set(newValue, forKey: key("engine")); changed() }
    }

    /// bilingual（双语对照）/ translation（仅译文）
    static var display: String {
        get { d.string(forKey: key("display")) == "translation" ? "translation" : "bilingual" }
        set { d.set(newValue == "translation" ? "translation" : "bilingual", forKey: key("display")); changed() }
    }

    static var autoSites: [String] {
        get { (d.stringArray(forKey: key("autoSites")) ?? []).sorted() }
        set { d.set(Array(Set(newValue.compactMap { MioTranslateCore.normalizeHost($0) })).sorted(), forKey: key("autoSites")); changed() }
    }

    static var selection: Bool {
        get { d.object(forKey: key("selection")) as? Bool ?? true }
        set { d.set(newValue, forKey: key("selection")); changed() }
    }

    static var youtube: Bool {
        get { d.object(forKey: key("youtube")) as? Bool ?? true }
        set { d.set(newValue, forKey: key("youtube")); changed() }
    }

    /// 播放器里「双语」开关的状态（YouTube 双语打开时）
    static var ytSubs: Bool {
        get { d.object(forKey: key("ytSubs")) as? Bool ?? true }
        set { d.set(newValue, forKey: key("ytSubs")); changed() }
    }

    static var openaiBase: String {
        get { d.string(forKey: key("openaiBase")) ?? "" }
        set { d.set(MioTranslateCore.normalizeBase(newValue), forKey: key("openaiBase")); changed() }
    }

    static var openaiModel: String {
        get { d.string(forKey: key("openaiModel")) ?? "" }
        set { d.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: key("openaiModel")); changed() }
    }

    static var openaiPrompt: String {
        get { d.string(forKey: key("openaiPrompt")) ?? "" }
        set { d.set(String(newValue.prefix(2000)), forKey: key("openaiPrompt")); changed() }
    }

    static var openaiReady: Bool { !openaiBase.isEmpty && !openaiModel.isEmpty && MioTranslateKeychain.hasKey }

    static func isAuto(_ host: String?) -> Bool { MioTranslateCore.isAuto(host: host, sites: autoSites) }

    static func setAuto(_ host: String, _ on: Bool) {
        guard let h = MioTranslateCore.normalizeHost(host) else { return }
        if on {
            autoSites = autoSites + [h]
        } else {
            autoSites = autoSites.filter { $0 != h && !MioTranslateCore.hostMatches(host, $0) }
        }
    }

    static func config(token: String) -> MioTranslateCore.Config {
        MioTranslateCore.Config(token: token, platform: MioWebKitCompat.isMac ? "mac" : "ios", target: target, engine: engine, display: display,
                                autoSites: autoSites, selection: selection, youtube: youtube, ytSubs: ytSubs,
                                openaiBase: openaiBase, openaiModel: openaiModel, openaiPrompt: openaiPrompt, openaiReady: openaiReady)
    }

    /// 设置变了：通知设置页；发 mioBrowserSettingsDidChange 让浏览器重建用户脚本（下次加载页面用新配置）；已打开的页面热更新
    static func changed() {
        NotificationCenter.default.post(name: .mioTranslateSettingsDidChange, object: nil)
        NotificationCenter.default.post(name: .mioBrowserSettingsDidChange, object: nil)
        MioTranslate.pushLiveConfig()
    }
}

// MARK: - Keychain（OpenAI 兼容 API Key）

enum MioTranslateKeychain {
    private static let service = "xyz.mio.translate"
    private static let account = "openai-api-key"
    /// 钥匙串不可用时（例如 ad-hoc 签名的 Mac 包没有 application-identifier 权限，errSecMissingEntitlement）退回 UserDefaults
    private static let fallbackKey = "mio.translate.openaiKeyFallback"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static var key: String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data, let s = String(data: data, encoding: .utf8), !s.isEmpty {
            return s
        }
        if let b = UserDefaults.standard.string(forKey: fallbackKey), let data = Data(base64Encoded: b), let s = String(data: data, encoding: .utf8), !s.isEmpty {
            return s
        }
        return nil
    }

    static var hasKey: Bool { key != nil }

    /// 是否存在退回方案里（设置页提示）
    static var usingFallback: Bool { UserDefaults.standard.string(forKey: fallbackKey) != nil }

    @discardableResult
    static func set(_ value: String?) -> OSStatus {
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: fallbackKey)
        guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else {
            MioTranslateSettings.changed()
            return errSecSuccess
        }
        var add = query
        add[kSecValueData as String] = Data(v.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            NSLog("⚡️ Mio translate: keychain add failed (%d), using app storage", status)
            UserDefaults.standard.set(Data(v.utf8).base64EncodedString(), forKey: fallbackKey)
        }
        MioTranslateSettings.changed()
        return status
    }
}

// MARK: - 持久缓存

final class MioTranslateCacheStore {
    static let shared = MioTranslateCacheStore()
    private let queue = DispatchQueue(label: "mio.translate.cache")
    private var lru: MioTranslateLRU?
    private var saveScheduled = false
    private let file: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return dir.appendingPathComponent("mio-translate-cache.json")
    }()

    private init() {
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.flush()
        }
    }

    private func loaded() -> MioTranslateLRU {
        if let l = lru { return l }
        let l = (try? Data(contentsOf: file)).map { MioTranslateLRU.decode($0) } ?? MioTranslateLRU()
        lru = l
        return l
    }

    func get(_ keys: [String], completion: @escaping ([String: String]) -> Void) {
        queue.async {
            var l = self.loaded()
            let out = l.get(keys)
            self.lru = l
            completion(out)
        }
    }

    func put(_ entries: [String: String]) {
        queue.async {
            var l = self.loaded()
            l.put(entries)
            self.lru = l
            self.scheduleSave()
        }
    }

    func clear() {
        queue.async {
            self.lru = MioTranslateLRU()
            try? FileManager.default.removeItem(at: self.file)
        }
    }

    func count(_ completion: @escaping (Int) -> Void) {
        queue.async { completion(self.loaded().count) }
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        queue.asyncAfter(deadline: .now() + 3) { self.save() }
    }

    private func save() {
        saveScheduled = false
        guard let l = lru else { return }
        try? l.encode().write(to: file, options: .atomic)
    }

    func flush() { queue.async { self.save() } }
}

// MARK: - Bridge

final class MioTranslateBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let name = "mioTranslate"
    static let token = MioTranslateCore.makeToken()
    static let shared = MioTranslateBridge()

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieAcceptPolicy = .never
        c.httpShouldSetCookies = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForResource = 120
        c.httpAdditionalHeaders = ["User-Agent": MioWebKitCompat.desktopUserAgent]
        return URLSession(configuration: c)
    }()

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
              (body["t"] as? String) == Self.token, let op = body["op"] as? String else {
            replyHandler(nil, "forbidden")
            return
        }
        switch op {
        case "fetch":
            guard let req = body["req"] as? [String: Any] else { replyHandler(["error": "bad request"], nil); return }
            fetch(req) { r in DispatchQueue.main.async { replyHandler(r, nil) } }
        case "cacheGet":
            let keys = ((body["keys"] as? [Any]) ?? []).compactMap { $0 as? String }
            MioTranslateCacheStore.shared.get(keys) { values in DispatchQueue.main.async { replyHandler(["values": values], nil) } }
        case "cachePut":
            var entries: [String: String] = [:]
            for (k, v) in (body["entries"] as? [String: Any]) ?? [:] { if let s = v as? String { entries[k] = s } }
            MioTranslateCacheStore.shared.put(entries)
            replyHandler(["ok": true], nil)
        case "setPref":
            if (body["key"] as? String) == "ytSubs", let v = body["value"] as? Bool {
                // 只改存储，不重建脚本（避免打断正在播放的页面）；下次加载页面生效
                UserDefaults.standard.set(v, forKey: "mio.translate.ytSubs")
                replyHandler(["ok": true], nil)
            } else {
                replyHandler(["error": "unknown pref"], nil)
            }
        default:
            replyHandler(["error": "unknown op"], nil)
        }
    }

    func fetch(_ req: [String: Any], completion: @escaping ([String: Any]) -> Void) {
        let checked: MioTranslateCore.CheckedRequest
        switch MioTranslateCore.check(req, openaiBase: MioTranslateSettings.openaiBase) {
        case .failure(let e):
            completion(["error": e.description])
            return
        case .success(let c):
            checked = c
        }
        var r = URLRequest(url: checked.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: checked.timeout)
        r.httpMethod = checked.method
        for (k, v) in checked.headers { r.setValue(v, forHTTPHeaderField: k) }
        if checked.openAIAuth {
            guard let key = MioTranslateKeychain.key else { completion(["error": "没有设置 API Key"]); return }
            r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        if let b = checked.body { r.httpBody = Data(b.utf8) }
        session.dataTask(with: r) { data, resp, err in
            if let err = err as NSError? {
                completion(["error": err.code == NSURLErrorTimedOut ? "timeout" : err.localizedDescription])
                return
            }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            var d = data ?? Data()
            if d.count > MioTranslateCore.maxResponse { d = d.prefix(MioTranslateCore.maxResponse) }
            let text = String(decoding: d, as: UTF8.self)
            if let p = checked.picks {
                completion(["status": status, "picks": MioTranslateCore.runPicks(text, p)])
            } else {
                completion(["status": status, "body": text])
            }
        }.resume()
    }
}

// MARK: - Glue（MioBrowser.swift 只调用这里）

enum MioTranslate {
    private static let template: String? = {
        guard let url = Bundle.main.url(forResource: "mio-translate", withExtension: "js"),
              let s = try? String(contentsOf: url, encoding: .utf8) else {
            NSLog("⚡️ Mio translate: mio-translate.js not in bundle")
            return nil
        }
        return s
    }()

    private static let webViews = NSHashTable<WKWebView>.weakObjects()

    static var scriptAvailable: Bool { template != nil }

    /// 注册消息处理器（页面主世界）。WKWebView 创建之前调用
    static func install(on controller: WKUserContentController) {
        controller.removeScriptMessageHandler(forName: MioTranslateBridge.name, contentWorld: .page)
        controller.addScriptMessageHandler(MioTranslateBridge.shared, contentWorld: .page, name: MioTranslateBridge.name)
    }

    static func uninstall(from controller: WKUserContentController?) {
        controller?.removeScriptMessageHandler(forName: MioTranslateBridge.name, contentWorld: .page)
    }

    static func register(_ webView: WKWebView) { webViews.add(webView) }

    /// 注入脚本（每次设置变化后由浏览器重建）
    static func userScript() -> WKUserScript? {
        guard let t = template, let src = MioTranslateCore.script(template: t, config: MioTranslateSettings.config(token: MioTranslateBridge.token)) else { return nil }
        return WKUserScript(source: src, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    /// 已打开的页面立即生效的设置（显示方式 / 划词 / 自动翻译站点 / YouTube 双语开关）
    static func pushLiveConfig() {
        let partial: [String: Any] = ["selection": MioTranslateSettings.selection, "display": MioTranslateSettings.display,
                                      "autoSites": MioTranslateSettings.autoSites, "ytSubs": MioTranslateSettings.ytSubs]
        guard let data = try? JSONSerialization.data(withJSONObject: partial), let json = String(data: data, encoding: .utf8) else { return }
        for wv in webViews.allObjects {
            wv.evaluateJavaScript("window.__mioTranslate && window.__mioTranslate.configure(\(json)); void 0", completionHandler: nil)
        }
    }

    static func pageState(_ webView: WKWebView, completion: @escaping ([String: Any]?) -> Void) {
        webView.evaluateJavaScript("window.__mioTranslate ? JSON.stringify(window.__mioTranslate.state()) : null") { result, _ in
            guard let s = result as? String, let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else { completion(nil); return }
            completion(obj)
        }
    }

    static func setMode(_ webView: WKWebView, _ mode: String) {
        webView.evaluateJavaScript("window.__mioTranslate && window.__mioTranslate.setMode('\(mode)'); void 0", completionHandler: nil)
    }

    /// 工具栏「翻译」按钮
    static func presentMenu(from vc: UIViewController, webView: WKWebView, barItem: UIBarButtonItem?) {
        pageState(webView) { state in
            let host = webView.url?.host
            let target = MioTranslateCore.languageName(MioTranslateSettings.target)
            let a = MioActionList(title: "翻译 → \(target)")
            let mode = state?["mode"] as? String ?? "off"
            if state != nil {
                a.add("双语对照", checked: mode == "bilingual") { MioTranslate.setMode(webView, "bilingual") }
                a.add("仅显示译文", checked: mode == "translation") { MioTranslate.setMode(webView, "translation") }
                if mode != "off" {
                    a.add("显示原文") { MioTranslate.setMode(webView, "off") }
                }
                if let err = state?["lastError"] as? String, !err.isEmpty { a.message = "上次失败：\(err)" }
            } else {
                a.message = scriptAvailable ? "此页面无法翻译（等页面加载完成再试）" : "翻译脚本未加载"
            }
            if let h = host, let norm = MioTranslateCore.normalizeHost(h) {
                if MioTranslateSettings.isAuto(h) {
                    a.add("不再自动翻译 \(norm)") { MioTranslateSettings.setAuto(h, false) }
                } else {
                    a.add("总是翻译 \(norm)") {
                        MioTranslateSettings.setAuto(h, true)
                        if mode == "off" { MioTranslate.setMode(webView, MioTranslateSettings.display) }
                    }
                }
            }
            a.add("译为…（\(target)）") {
                MioTranslate.presentLanguagePicker(from: vc, sourceItem: barItem, sourceView: nil) { webView.reload() }
            }
            a.add("翻译设置…") { MioTranslate.presentSettings(from: vc, host: host) }
            a.present(from: vc, barItem: barItem)
        }
    }

    /// 最近一次弹出的「翻译成」列表（冒烟测试检查是纵向列表）
    static weak var lastLanguagePicker: UIViewController?

    static func presentLanguagePicker(from vc: UIViewController, sourceItem: UIBarButtonItem?, sourceView: UIView?, done: (() -> Void)?) {
        let a = MioActionList(title: "翻译成")
        let cur = MioTranslateSettings.target
        for l in MioTranslateCore.languages {
            a.add(l.name, checked: l.code == cur) {
                guard l.code != cur else { return }
                MioTranslateSettings.target = l.code
                done?()
            }
        }
        lastLanguagePicker = a.present(from: vc, barItem: sourceItem, sourceView: sourceView)
    }

    static func presentSettings(from vc: UIViewController, host: String?) {
        let nav = UINavigationController(rootViewController: MioTranslateSettingsViewController(currentHost: host, modal: true))
        vc.present(nav, animated: true)
    }

    /// Mac 冒烟测试：当前内置浏览器页面里脚本已注入、原生桥往返正常（不访问翻译接口）；network = true 时再真实翻译一句（只记录，20 秒超时）
    static func smokeCheck(network: Bool, completion: @escaping ([String: Any]) -> Void) {
        guard let wv = webViews.allObjects.first else { completion(["installed": false, "error": "no browser"]); return }
        let js = """
        const r = { installed: !!window.__mioTranslate, host: location.hostname };
        if (!window.__mioTranslate) return JSON.stringify(r);
        r.state = window.__mioTranslate.state();
        try { Object.assign(r, await window.__mioTranslate.selfTest(false)); } catch (e) { r.selfTestError = String(e); }
        if (NETWORK) {
          try {
            const n = await Promise.race([window.__mioTranslate.selfTest(true), new Promise((res) => setTimeout(() => res({ networkError: 'timeout 20s' }), 20000))]);
            r.sample = n.sample; r.engine = n.engine; r.ms = n.ms; if (n.networkError) r.networkError = n.networkError;
          } catch (e) { r.networkError = String(e); }
        }
        return JSON.stringify(r);
        """
        wv.callAsyncJavaScript(js, arguments: ["NETWORK": network], in: nil, in: .page) { result in
            switch result {
            case .success(let v):
                let obj = (v as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? ["raw": "\(String(describing: v))"]
                completion(obj)
            case .failure(let e):
                completion(["installed": false, "error": "\(e)"])
            }
        }
    }
}

// MARK: - Settings UI

final class MioTranslateSettingsViewController: UITableViewController {
    private enum Row {
        case target, display, selection, youtube
        case site(String), addSite
        case engine(String)
        case base, model, key, prompt, test
        case clearCache
    }

    private let currentHost: String?
    private let modal: Bool
    private var sections: [(title: String?, footer: String?, rows: [Row])] = []
    private var observer: NSObjectProtocol?
    private var cacheCount: Int?
    private var testResult: String?

    init(currentHost: String?, modal: Bool = false) {
        self.currentHost = currentHost
        self.modal = modal
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { if let o = observer { NotificationCenter.default.removeObserver(o) } }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "翻译"
        if modal { navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(doneTapped)) }
        observer = NotificationCenter.default.addObserver(forName: .mioTranslateSettingsDidChange, object: nil, queue: .main) { [weak self] _ in self?.rebuild() }
        refreshCount()
        rebuild()
    }

    @objc private func doneTapped() { dismiss(animated: true) }

    private func refreshCount() {
        MioTranslateCacheStore.shared.count { n in
            DispatchQueue.main.async { [weak self] in
                self?.cacheCount = n
                self?.rebuild()
            }
        }
    }

    private func rebuild() {
        var s: [(String?, String?, [Row])] = []
        s.append(("网页翻译", "在内置浏览器工具栏点「翻译」按钮切换双语对照 / 仅译文 / 原文。代码、输入框和已经是目标语言的段落不翻译；只翻译看得到的部分，滚动和页面动态加载的内容会增量翻译。", [Row.target, Row.display, Row.selection, Row.youtube]))
        var sites: [Row] = MioTranslateSettings.autoSites.map { Row.site($0) }
        sites.append(Row.addSite)
        s.append(("自动翻译的网站", "打开这些网站（含子域名）时自动翻译。左滑删除。", sites))
        s.append(("翻译引擎", "免费引擎使用微软（Bing 网页翻译）和谷歌的公开网页接口，可能限流或变动。所选引擎失败或超时时自动改用免费引擎（微软 → 谷歌）。要翻译的文字会发送给所选引擎。", MioTranslateCore.engines.map { Row.engine($0.id) }))
        if MioTranslateSettings.engine == "openai" {
            let footer = MioTranslateKeychain.usingFallback ? "本机钥匙串不可用，API Key 保存在 App 设置里。" : "API Key 保存在系统钥匙串，只在 App 内发请求时使用，网页拿不到。"
            s.append(("自定义 OpenAI 兼容 API", footer, [Row.base, Row.model, Row.key, Row.prompt, Row.test]))
        }
        s.append(("缓存", nil, [Row.clearCache]))
        sections = s.map { (title: $0.0, footer: $0.1, rows: $0.2) }
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].rows.count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { sections[section].title }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? { sections[section].footer }

    private func makeSwitch(_ on: Bool, _ change: @escaping (Bool) -> Void) -> UISwitch {
        let sw = UISwitch()
        sw.isOn = on
        sw.addAction(UIAction { action in if let s = action.sender as? UISwitch { change(s.isOn) } }, for: .valueChanged)
        return sw
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.selectionStyle = .none
        cell.detailTextLabel?.textColor = .secondaryLabel
        switch sections[indexPath.section].rows[indexPath.row] {
        case .target:
            cell.textLabel?.text = "翻译成"
            cell.detailTextLabel?.text = MioTranslateCore.languageName(MioTranslateSettings.target)
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        case .display:
            cell.textLabel?.text = "显示方式"
            cell.detailTextLabel?.text = MioTranslateSettings.display == "translation" ? "仅译文" : "双语对照"
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        case .selection:
            cell.textLabel?.text = "划词翻译"
            cell.detailTextLabel?.text = "选中文字后点「译」"
            cell.accessoryView = makeSwitch(MioTranslateSettings.selection) { MioTranslateSettings.selection = $0 }
        case .youtube:
            cell.textLabel?.text = "YouTube 双语字幕"
            cell.detailTextLabel?.text = "播放器里可临时开关"
            cell.accessoryView = makeSwitch(MioTranslateSettings.youtube) { MioTranslateSettings.youtube = $0 }
        case .site(let h):
            cell.textLabel?.text = h
        case .addSite:
            cell.textLabel?.text = "添加网站…"
            cell.textLabel?.textColor = .systemBlue
            cell.selectionStyle = .default
        case .engine(let id):
            cell.textLabel?.text = MioTranslateCore.engines.first(where: { $0.id == id })?.name
            if id == "openai" { cell.detailTextLabel?.text = MioTranslateSettings.openaiReady ? MioTranslateSettings.openaiModel : "未配置" }
            cell.accessoryType = MioTranslateSettings.engine == id ? .checkmark : .none
            cell.selectionStyle = .default
        case .base:
            cell.textLabel?.text = "API 地址"
            cell.detailTextLabel?.text = MioTranslateSettings.openaiBase.isEmpty ? "未设置" : MioTranslateSettings.openaiBase
            cell.detailTextLabel?.lineBreakMode = .byTruncatingMiddle
            cell.selectionStyle = .default
        case .model:
            cell.textLabel?.text = "模型"
            cell.detailTextLabel?.text = MioTranslateSettings.openaiModel.isEmpty ? "未设置" : MioTranslateSettings.openaiModel
            cell.selectionStyle = .default
        case .key:
            cell.textLabel?.text = "API Key"
            cell.detailTextLabel?.text = MioTranslateKeychain.hasKey ? "已保存" : "未设置"
            cell.selectionStyle = .default
        case .prompt:
            cell.textLabel?.text = "附加提示（可选）"
            cell.detailTextLabel?.text = MioTranslateSettings.openaiPrompt.isEmpty ? "无" : MioTranslateSettings.openaiPrompt
            cell.selectionStyle = .default
        case .test:
            cell.textLabel?.text = "测试连接"
            cell.textLabel?.textColor = .systemBlue
            cell.detailTextLabel?.text = testResult
            cell.detailTextLabel?.numberOfLines = 0
            cell.selectionStyle = .default
        case .clearCache:
            cell.textLabel?.text = "清除翻译缓存"
            cell.textLabel?.textColor = .systemRed
            cell.detailTextLabel?.text = cacheCount.map { "\($0) 条" }
            cell.selectionStyle = .default
        }
        return cell
    }

    private func ask(_ title: String, message: String?, text: String?, placeholder: String, secure: Bool, keyboard: UIKeyboardType, extra: UIAlertAction?, save: @escaping (String) -> Void) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addTextField { f in
            f.text = text
            f.placeholder = placeholder
            f.isSecureTextEntry = secure
            f.keyboardType = keyboard
            f.autocapitalizationType = .none
            f.autocorrectionType = .no
            f.clearButtonMode = .whileEditing
        }
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let e = extra { a.addAction(e) }
        a.addAction(UIAlertAction(title: "保存", style: .default) { _ in save(a.textFields?.first?.text ?? "") })
        present(a, animated: true)
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let cell = tableView.cellForRow(at: indexPath)
        switch sections[indexPath.section].rows[indexPath.row] {
        case .target:
            MioTranslate.presentLanguagePicker(from: self, sourceItem: nil, sourceView: cell, done: nil)
        case .display:
            let a = MioActionList(title: "显示方式")
            for (v, name) in [("bilingual", "双语对照（原文下方显示淡色译文）"), ("translation", "仅译文（隐藏原文）")] {
                a.add(name, checked: MioTranslateSettings.display == v) { MioTranslateSettings.display = v }
            }
            a.present(from: self, sourceView: cell)
        case .addSite:
            let prefill = currentHost.flatMap { MioTranslateCore.normalizeHost($0) }
            ask("自动翻译网站", message: "输入域名，例如 example.com（含子域名）", text: prefill, placeholder: "example.com", secure: false, keyboard: .URL, extra: nil) { t in
                if !t.isEmpty { MioTranslateSettings.setAuto(t, true) }
            }
        case .engine(let id):
            if id == "openai" && !MioTranslateSettings.openaiReady {
                testResult = "填写 API 地址、模型和 Key 后才会使用；在此之前用免费引擎"
            }
            MioTranslateSettings.engine = id
        case .base:
            ask("API 地址", message: "OpenAI 兼容接口，例如 https://api.openai.com/v1（会请求 …/chat/completions）", text: MioTranslateSettings.openaiBase,
                placeholder: "https://…/v1", secure: false, keyboard: .URL, extra: nil) { [weak self] t in
                let n = MioTranslateCore.normalizeBase(t)
                if !t.isEmpty && n.isEmpty {
                    self?.testResult = "地址无效（需要 http:// 或 https://）"
                    self?.rebuild()
                    return
                }
                MioTranslateSettings.openaiBase = n
            }
        case .model:
            ask("模型", message: nil, text: MioTranslateSettings.openaiModel, placeholder: "gpt-4o-mini", secure: false, keyboard: .default, extra: nil) { t in
                MioTranslateSettings.openaiModel = t
            }
        case .key:
            let del: UIAlertAction? = MioTranslateKeychain.hasKey ? UIAlertAction(title: "删除", style: .destructive) { _ in MioTranslateKeychain.set(nil) } : nil
            ask("API Key", message: MioTranslateKeychain.hasKey ? "已保存。输入新的 Key 覆盖。" : "保存在系统钥匙串", text: nil, placeholder: "sk-…", secure: true, keyboard: .default, extra: del) { t in
                if !t.isEmpty { MioTranslateKeychain.set(t) }
            }
        case .prompt:
            ask("附加提示", message: "会附加在系统提示后面，例如：使用口语化表达；专有名词保留英文", text: MioTranslateSettings.openaiPrompt, placeholder: "可选",
                secure: false, keyboard: .default, extra: nil) { t in
                MioTranslateSettings.openaiPrompt = t
            }
        case .test:
            runTest()
        case .clearCache:
            MioTranslateCacheStore.shared.clear()
            cacheCount = 0
            rebuild()
        default:
            break
        }
    }

    private func runTest() {
        let endpoint = MioTranslateCore.openaiEndpoint(MioTranslateSettings.openaiBase)
        guard !endpoint.isEmpty, !MioTranslateSettings.openaiModel.isEmpty else {
            testResult = "请先填写 API 地址和模型"
            rebuild()
            return
        }
        testResult = "测试中…"
        rebuild()
        let body: [String: Any] = ["model": MioTranslateSettings.openaiModel, "temperature": 0,
                                   "messages": [["role": "user", "content": "Translate to Simplified Chinese, reply with the translation only: Good morning"]]]
        let json = (try? JSONSerialization.data(withJSONObject: body)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let started = Date()
        let req: [String: Any] = ["url": endpoint, "method": "POST", "auth": "openai", "timeoutMs": 30000,
                                  "headers": ["Content-Type": "application/json"], "body": json]
        MioTranslateBridge.shared.fetch(req) { [weak self] r in
            var msg: String
            if let e = r["error"] as? String {
                msg = "⚠️ \(e)"
            } else {
                let status = r["status"] as? Int ?? 0
                var text = ""
                if let b = r["body"] as? String, let j = try? JSONSerialization.jsonObject(with: Data(b.utf8)) as? [String: Any] {
                    let choice = (j["choices"] as? [[String: Any]])?.first
                    let content = (choice?["message"] as? [String: Any])?["content"] as? String
                    let errMsg = (j["error"] as? [String: Any])?["message"] as? String
                    text = content ?? errMsg ?? ""
                }
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                msg = "\(status == 200 ? "✅" : "⚠️") HTTP \(status) · \(ms) ms · \(String(text.prefix(80)))"
            }
            DispatchQueue.main.async {
                self?.testResult = msg
                self?.rebuild()
            }
        }
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        if case .site = sections[indexPath.section].rows[indexPath.row] { return true }
        return false
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete, case .site(let h) = sections[indexPath.section].rows[indexPath.row] else { return }
        MioTranslateSettings.autoSites = MioTranslateSettings.autoSites.filter { $0 != h }
    }
}
