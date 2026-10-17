// MioCoreModules.swift — MioCore（主页 / 新标签页 mio://home、保存到 Mio）、WebRTC 防泄露、阅读 / 强制深色。

import Foundation

/// MioCore：mio://home 主页 + 新标签页、「保存到 Mio」菜单 / 分享项。常开（关不掉；改 MioCore 地址在这里）
public final class MioCoreModule: MioModule {
    public let id = "miocore"
    public let title = "MioCore"
    public let summary = "Mio 作为主页和新标签页（地址栏显示「Mio」），把网页保存到 MioCore。相册同步、控制设备在后续版本。"
    public let symbol = "house"
    public let section = MioSettingsSection.mioCore
    public var enabledKey: String? { nil }
    public init() {}

    public var settings: [MioModuleSetting] {
        [
            MioModuleSetting(key: MioCoreOrigin.originKey, title: "MioCore 地址", kind: .text(default: MioCoreOrigin.defaultOrigin, placeholder: "https://…"),
                             footer: "只接受 https。只有这个地址（和 Mio 内置页面）能使用本机功能，其他网站拿不到。"),
            MioModuleSetting(key: MioHomeModel.homePathKey, title: "主页路径", kind: .text(default: MioHomeModel.defaultHomePath, placeholder: "/mio/nav")),
            MioModuleSetting(key: MioPageToolsDefaults.saveCategoryKey, title: "保存到导航的分类", kind: .text(default: MioPageToolsDefaults.defaultCategory, placeholder: "稍后阅读")),
        ]
    }

    public func menuItems(page: MioPageContext, prefs: MioPrefs) -> [MioModuleMenuItem] {
        var out = [MioModuleMenuItem(moduleID: id, itemID: "home", title: "打开 Mio 主页", symbol: "house")]
        if let u = page.url, MioCoreBridge.openableURL(u.absoluteString) != nil, !MioHomeModel.isInternal(u), !MioCoreOrigin.isMioCore(u, prefs: prefs) {
            out.append(MioModuleMenuItem(moduleID: id, itemID: "save.bookmark", title: "保存到 Mio", symbol: "tray.and.arrow.down"))
            out.append(MioModuleMenuItem(moduleID: id, itemID: "save.bookmark", title: "保存到 Mio", symbol: "tray.and.arrow.down", placement: .share))
            out.append(MioModuleMenuItem(moduleID: id, itemID: "save.note", title: "保存为 Mio 笔记", symbol: "note.text"))
            out.append(MioModuleMenuItem(moduleID: id, itemID: "save.clip", title: "在另一台设备继续", symbol: "arrow.triangle.2.circlepath"))
        }
        return out
    }

    public func perform(_ itemID: String, page: MioPageContext, prefs: MioPrefs) -> MioModuleAction {
        if itemID == "home" { return .openURL(MioHomeModel(prefs: prefs).newTabURL, newTab: true) }
        guard itemID.hasPrefix("save."), let src = MioKitResources.script("reader") else { return .none }
        let kind = String(itemID.dropFirst(5))
        // 1) 在当前页提取正文（阅读世界），2) handleScriptResult → .host(.saveToMio) → 宿主交给 MioSaveRunner（MioCore 同源执行 mio-save.js）
        return .runScript(MioScriptCall(body: MioPageScripts.extractBody(source: src), arguments: ["prefs": [String: Any](), "force": false],
                                        world: .isolated(MioPageToolsModule.readerWorld), resultHandler: "save:" + kind))
    }

    public func handleScriptResult(_ handler: String, result: Any?, page: MioPageContext, prefs: MioPrefs) -> MioModuleAction {
        guard handler.hasPrefix("save:") else { return .none }
        let kind = String(handler.dropFirst(5))
        let r = result as? [String: Any] ?? [:]
        let payload = Self.savePayload(extracted: r, page: page)
        return .host(.saveToMio(kind: kind, payloadJSON: MioJSString.json(payload)))
    }

    /// mio-save.js 的 payload：{ url, title, selection, article: { markdown, excerpt, byline, siteName } }
    static func savePayload(extracted r: [String: Any], page: MioPageContext) -> [String: Any] {
        var p: [String: Any] = ["url": (r["url"] as? String) ?? page.url?.absoluteString ?? "",
                                "title": (r["title"] as? String) ?? page.title,
                                "selection": (r["selection"] as? String) ?? ""]
        if let a = r["article"] as? [String: Any] {
            p["article"] = ["markdown": a["markdown"] ?? "", "excerpt": a["excerpt"] ?? "", "byline": a["byline"] ?? "", "siteName": a["siteName"] ?? ""]
        }
        return p
    }
}

/// WebRTC 防泄露（本机 IP）—— key 与 v0.3.x 相同（mio.webrtc.enabled / allowlist）；显示在「隐私与安全」
public final class MioWebRTCModule: MioModule {
    public let id = "webrtc"
    public let title = "WebRTC 防泄露"
    public let summary = "默认屏蔽网页的 WebRTC（防止泄露本机 / 真实 IP），视频通话站点可单独放行。"
    public let symbol = "video.slash"
    public let section = MioSettingsSection.privacy
    public var enabledKey: String? { MioWebRTCSettings.enabledKey }
    public init() {}

    public var settings: [MioModuleSetting] {
        [MioModuleSetting(key: MioWebRTCSettings.allowlistKey, title: "允许 WebRTC 的网站", kind: .stringList(placeholder: "meet.google.com"),
                          footer: "常用：" + MioWebRTCSettings.presets.map { $0.host }.prefix(6).joined(separator: "、"))]
    }

    func allowlist(_ prefs: MioPrefs) -> [String] { prefs.strings(MioWebRTCSettings.allowlistKey).map(MioWebRTCSettings.normalize).filter { !$0.isEmpty } }

    public func scripts(prefs: MioPrefs) -> [MioModuleScript] {
        [MioModuleScript(source: MioWebRTCGuard.script(allow: allowlist(prefs)), injection: .documentStart, mainFrameOnly: false, world: .page)]
    }

    public func menuItems(page: MioPageContext, prefs: MioPrefs) -> [MioModuleMenuItem] {
        guard let h = page.host, !h.isEmpty, !MioHomeModel.isInternal(page.url) else { return [] }
        let allowed = MioWebRTCSettings.allowlistEntry(for: h, in: prefs.strings(MioWebRTCSettings.allowlistKey)) != nil
        return [MioModuleMenuItem(moduleID: id, itemID: allowed ? "block" : "allow", title: "在此网站允许 WebRTC", symbol: "video", checked: allowed)]
    }

    public func perform(_ itemID: String, page: MioPageContext, prefs: MioPrefs) -> MioModuleAction {
        guard let h = page.host.map(MioWebRTCSettings.normalize), !h.isEmpty else { return .none }
        var list = Set(prefs.strings(MioWebRTCSettings.allowlistKey))
        switch itemID {
        case "allow": list.insert(h)
        case "block":
            list.remove(h)
            if let e = MioWebRTCSettings.allowlistEntry(for: h, in: Array(list)) { list.remove(e) }
        default: return .none
        }
        prefs.set(list.sorted(), forKey: MioWebRTCSettings.allowlistKey)
        return .reload
    }
}

/// 阅读视图 + 强制深色（www/mio-browser/reader.js、dark.js；key 与 v0.3.x 相同 mio.reader.* / mio.dark.*）
public final class MioPageToolsModule: MioModuleMessageHandling {
    public static let readerWorld = "mio-reader"
    public static let darkWorld = "mio-dark"
    public static let darkMessage = "mioDark"
    public let id = "pageTools"
    public let title = "阅读 / 强制深色"
    public let summary = "阅读视图（去掉广告和杂乱排版），给不支持深色的网站强制深色。"
    public let symbol = "doc.plaintext"
    public let section = MioSettingsSection.extensions
    public var enabledKey: String? { "mio.kit.module.pageTools.enabled" }
    var readerSource: String? = MioKitResources.script("reader")
    var darkSource: String? = MioKitResources.script("dark")
    public init() {}

    public var settings: [MioModuleSetting] {
        [
            MioModuleSetting(key: MioPageToolsDefaults.darkGlobalKey, title: "所有网站强制深色", kind: .toggle(default: false),
                             footer: "网站本身有深色模式时不重复处理。单个网站可在页面菜单里单独开关。"),
            MioModuleSetting(key: MioPageToolsDefaults.readerThemeKey, title: "阅读视图主题",
                             kind: .choice(options: MioReaderPrefs.Theme.allCases.map { t in MioChoiceOption(.string(t.rawValue), MioReaderPrefs(theme: t).themeTitle) }, default: .string("auto"))),
            MioModuleSetting(key: MioPageToolsDefaults.readerFontKey, title: "阅读视图字体",
                             kind: .choice(options: MioReaderPrefs.Font.allCases.map { f in MioChoiceOption(.string(f.rawValue), MioReaderPrefs(font: f).fontTitle) }, default: .string("sans"))),
            MioModuleSetting(key: MioPageToolsDefaults.readerFontSizeKey, title: "阅读视图字号",
                             kind: .choice(options: stride(from: 14, through: 26, by: 2).map { MioChoiceOption(.int($0), "\($0)") }, default: .int(18))),
        ]
    }

    func darkSites(_ prefs: MioPrefs) -> [String: Bool] {
        var out: [String: Bool] = [:]
        for (k, v) in prefs.dictionary(MioPageToolsDefaults.darkSitesKey) { if let b = v as? Bool { out[k] = b } else if let n = v as? NSNumber { out[k] = n.boolValue } }
        return out
    }

    public func readerPrefs(_ prefs: MioPrefs) -> MioReaderPrefs {
        var p = MioReaderPrefs()
        if let t = MioReaderPrefs.Theme(rawValue: prefs.string(MioPageToolsDefaults.readerThemeKey, default: "auto")) { p.theme = t }
        if let f = MioReaderPrefs.Font(rawValue: prefs.string(MioPageToolsDefaults.readerFontKey, default: "sans")) { p.font = f }
        let s = prefs.int(MioPageToolsDefaults.readerFontSizeKey, default: 18)
        p.fontSize = MioReaderPrefs.clamp(s > 0 ? s : 18)
        return p
    }

    public func scripts(prefs: MioPrefs) -> [MioModuleScript] {
        let global = prefs.bool(MioPageToolsDefaults.darkGlobalKey, default: false)
        let sites = darkSites(prefs)
        guard let src = darkSource, MioForceDarkPolicy.needsScript(global: global, sites: sites) else { return [] }
        let json = MioForceDarkPolicy.configJSON(global: global, sites: sites, nativeHosts: prefs.strings(MioPageToolsDefaults.darkNativeHostsKey))
        return [MioModuleScript(source: MioPageScripts.darkInstallScript(source: src, configJSON: json), injection: .documentStart, mainFrameOnly: true, world: .isolated(Self.darkWorld))]
    }

    public func menuItems(page: MioPageContext, prefs: MioPrefs) -> [MioModuleMenuItem] {
        guard let h = page.host, page.url?.scheme?.hasPrefix("http") == true else { return [] }
        let dark = MioForceDarkPolicy.isEnabled(host: h, global: prefs.bool(MioPageToolsDefaults.darkGlobalKey, default: false), sites: darkSites(prefs))
        return [
            MioModuleMenuItem(moduleID: id, itemID: "reader", title: "阅读视图", symbol: "doc.plaintext"),
            MioModuleMenuItem(moduleID: id, itemID: dark ? "darkOff" : "darkOn", title: "在此网站强制深色", symbol: "moon", checked: dark),
        ]
    }

    public func perform(_ itemID: String, page: MioPageContext, prefs: MioPrefs) -> MioModuleAction {
        switch itemID {
        case "reader":
            guard let src = readerSource else { return .host(.toast("阅读脚本未加载")) }
            return .runScript(MioScriptCall(body: MioPageScripts.extractBody(source: src), arguments: ["prefs": readerPrefs(prefs).jsPrefs(systemDark: false), "force": true],
                                            world: .isolated(Self.readerWorld), resultHandler: "reader"))
        case "darkOn", "darkOff":
            guard let h = page.host else { return .none }
            let norm = MioForceDarkPolicy.normalize(h)
            var s = darkSites(prefs)
            let key = MioForceDarkPolicy.matchingSiteKey(host: norm, sites: s) ?? norm
            s[key] = itemID == "darkOn"
            prefs.set(s, forKey: MioPageToolsDefaults.darkSitesKey)
            return .reload
        default: return .none
        }
    }

    public func handleScriptResult(_ handler: String, result: Any?, page: MioPageContext, prefs: MioPrefs) -> MioModuleAction {
        guard handler == "reader" else { return .none }
        guard let r = result as? [String: Any], r["article"] != nil else { return .host(.toast("这个页面没有可提取的正文")) }
        return .host(.showReader(articleJSON: MioJSString.json(r)))
    }

    /// dark.js 报告「网站自己就是深色」→ 记进 nativeHosts（下次不注入）
    public func messageEndpoints(prefs: MioPrefs) -> [MioMessageEndpoint] { [MioMessageEndpoint(name: Self.darkMessage, world: .isolated(Self.darkWorld))] }

    public func handle(_ message: MioScriptMessage, prefs: MioPrefs) async -> MioScriptReply {
        // dark.js 发 { host, verdict: 'native' | 'forced' }；只认主框架、且 host 必须是发消息页面自己的来源（不让别的页面改别站的记录）
        guard message.isMainFrame, let body = message.body as? [String: Any], let host = body["host"] as? String,
              host.lowercased() == message.origin.host else { return .error("bad message") }
        let native = (body["verdict"] as? String) == "native"
        let r = MioForceDarkPolicy.updateNativeHosts(prefs.strings(MioPageToolsDefaults.darkNativeHostsKey), host: host, native: native)
        if r.changed { prefs.set(r.list, forKey: MioPageToolsDefaults.darkNativeHostsKey) }
        return .value(true)
    }
}
