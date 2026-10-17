// MioReaderCore.swift — 内置浏览器「阅读模式 / 强制深色 / 存到 Mio」的纯逻辑部分（只依赖 Foundation，tools/MioAppTests 里单测）。
//
// 页面里运行的 JS 在 www/mio-browser/{reader,dark,mio-save}.js（cap sync 拷进 App 包的 public/mio-browser/，
// Android 拷进 assets/public/mio-browser/，Windows 版打包进 resources/mio-browser/），三个平台共用同一份。
// 这里负责：设置项（UserDefaults，key 前缀 mio.reader.* / mio.dark.* / mio.save.*）、按站点的深色开关解析（与 dark.js 的
// resolveEnabled 规则一致）、拼注入脚本和传给 JS 的配置 JSON。UI 在 MioPageTools.swift。

import Foundation

// MARK: - 阅读视图设置

public struct MioReaderPrefs: Equatable {
    public enum Theme: String, CaseIterable { case auto, light, sepia, dark }
    public enum Font: String, CaseIterable { case sans, serif, mono }

    public var theme: Theme = .auto
    public var font: Font = .sans
    public var fontSize: Int = 18

    public static let fontSizeRange = 12...32

    /// 传给 MioReader.buildPage / applyPrefsScript 的字典；auto 按系统外观解析成 light / dark
    public func jsPrefs(systemDark: Bool) -> [String: Any] {
        let t: Theme = theme == .auto ? (systemDark ? .dark : .light) : theme
        return ["theme": t.rawValue, "font": font.rawValue, "fontSize": Self.clamp(fontSize)]
    }

    public static func clamp(_ size: Int) -> Int { min(max(size, fontSizeRange.lowerBound), fontSizeRange.upperBound) }

    public var themeTitle: String {
        switch theme { case .auto: return "跟随系统"; case .light: return "白"; case .sepia: return "米"; case .dark: return "深" }
    }
    public var fontTitle: String {
        switch font { case .sans: return "无衬线"; case .serif: return "衬线"; case .mono: return "等宽" }
    }
}

// MARK: - 强制深色：按站点开关

public enum MioForceDarkPolicy {
    public static func normalize(_ host: String) -> String {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while h.hasPrefix(".") { h.removeFirst() }
        while h.hasSuffix(".") { h.removeLast() }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    /// 站点设置优先（含父域名，越具体越优先），没有设置时跟随全局「所有网站深色」。与 dark.js resolveEnabled 相同
    public static func isEnabled(host: String?, global: Bool, sites: [String: Bool]) -> Bool {
        let h = normalize(host ?? "")
        if !h.isEmpty {
            let parts = h.split(separator: ".").map(String.init)
            if parts.count >= 2 {
                for i in 0..<(parts.count - 1) {
                    let key = parts[i...].joined(separator: ".")
                    if let v = sites[key] { return v }
                }
            } else if let v = sites[h] {
                return v
            }
        }
        return global
    }

    /// 站点设置对应的那一项（例如在 news.example.com 上，实际生效的是 example.com 的设置）
    public static func matchingSiteKey(host: String?, sites: [String: Bool]) -> String? {
        let h = normalize(host ?? "")
        guard !h.isEmpty else { return nil }
        let parts = h.split(separator: ".").map(String.init)
        if parts.count < 2 { return sites[h] != nil ? h : nil }
        for i in 0..<(parts.count - 1) {
            let key = parts[i...].joined(separator: ".")
            if sites[key] != nil { return key }
        }
        return nil
    }

    /// 是否需要注入深色脚本（全局关、也没有任何站点开启时完全不注入）
    public static func needsScript(global: Bool, sites: [String: Bool]) -> Bool {
        global || sites.values.contains(true)
    }

    /// 传给 MioDark.install 的配置 JSON（按键排序，便于测试和缓存）
    public static func configJSON(global: Bool, sites: [String: Bool], nativeHosts: [String]) -> String {
        let obj: [String: Any] = ["global": global, "sites": sites, "nativeHosts": Array(Set(nativeHosts.map(normalize))).sorted()]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    /// 记录「这个站点自己有深色」的结果（最多 maxNative 个，最近的在前）；返回新列表和是否有变化
    public static func updateNativeHosts(_ list: [String], host: String, native: Bool, maxNative: Int = 300) -> (list: [String], changed: Bool) {
        let h = normalize(host)
        guard !h.isEmpty else { return (list, false) }
        var l = list.filter { $0 != h }
        if native { l.insert(h, at: 0) }
        if l.count > maxNative { l = Array(l.prefix(maxNative)) }
        return (l, l != list)
    }
}

// MARK: - 存到 Mio

public enum MioSaveKind: String, CaseIterable {
    case bookmark, note, clip

    public var title: String {
        switch self {
        case .bookmark: return "存为导航书签"
        case .note: return "新建笔记"
        case .clip: return "在另一台设备继续"
        }
    }
    public var subtitle: String {
        switch self {
        case .bookmark: return "加入 MioCore 导航"
        case .note: return "标题 + 链接 + 选中文字 / 正文"
        case .clip: return "推到 MioCore 云剪贴板"
        }
    }
    public var systemImage: String {
        switch self {
        case .bookmark: return "bookmark"
        case .note: return "note.text.badge.plus"
        case .clip: return "arrow.up.forward.app"
        }
    }

    /// MioSave.run 的结果 → 提示文字
    public static func message(for result: [String: Any]?) -> (ok: Bool, text: String) {
        guard let r = result else { return (false, "保存失败：没有返回结果") }
        if (r["ok"] as? Bool) == true {
            let kind = MioSaveKind(rawValue: r["kind"] as? String ?? "")
            switch kind {
            case .bookmark?:
                let cat = (r["category"] as? String).map { "「\($0)」" } ?? ""
                return (true, (r["duplicate"] as? Bool) == true ? "导航里已有这个网页\(cat)" : "已存到导航\(cat)")
            case .note?: return (true, "已新建笔记")
            case .clip?: return (true, "已推到云剪贴板，可在另一台设备继续")
            case nil: return (true, "已保存")
            }
        }
        let msg = (r["message"] as? String) ?? "未知错误"
        return (false, msg)
    }
}

public enum MioPageToolsDefaults {
    public static let readerThemeKey = "mio.reader.theme"
    public static let readerFontKey = "mio.reader.font"
    public static let readerFontSizeKey = "mio.reader.fontSize"
    public static let darkGlobalKey = "mio.dark.global"
    public static let darkSitesKey = "mio.dark.sites"
    public static let darkNativeHostsKey = "mio.dark.nativeHosts"
    public static let saveCategoryKey = "mio.save.category"
    public static let defaultCategory = "稍后阅读"
}

/// 设置存储（UserDefaults）；测试里传入独立的 suite
public struct MioPageToolsStore {
    public let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var readerPrefs: MioReaderPrefs {
        get {
            var p = MioReaderPrefs()
            if let t = defaults.string(forKey: MioPageToolsDefaults.readerThemeKey), let v = MioReaderPrefs.Theme(rawValue: t) { p.theme = v }
            if let f = defaults.string(forKey: MioPageToolsDefaults.readerFontKey), let v = MioReaderPrefs.Font(rawValue: f) { p.font = v }
            let s = defaults.integer(forKey: MioPageToolsDefaults.readerFontSizeKey)
            if s > 0 { p.fontSize = MioReaderPrefs.clamp(s) }
            return p
        }
        nonmutating set {
            defaults.set(newValue.theme.rawValue, forKey: MioPageToolsDefaults.readerThemeKey)
            defaults.set(newValue.font.rawValue, forKey: MioPageToolsDefaults.readerFontKey)
            defaults.set(MioReaderPrefs.clamp(newValue.fontSize), forKey: MioPageToolsDefaults.readerFontSizeKey)
        }
    }

    public var darkGlobal: Bool {
        get { defaults.bool(forKey: MioPageToolsDefaults.darkGlobalKey) }
        nonmutating set { defaults.set(newValue, forKey: MioPageToolsDefaults.darkGlobalKey) }
    }

    public var darkSites: [String: Bool] {
        get { (defaults.dictionary(forKey: MioPageToolsDefaults.darkSitesKey) as? [String: Bool]) ?? [:] }
        nonmutating set { defaults.set(newValue, forKey: MioPageToolsDefaults.darkSitesKey) }
    }

    public var darkNativeHosts: [String] {
        get { defaults.stringArray(forKey: MioPageToolsDefaults.darkNativeHostsKey) ?? [] }
        nonmutating set { defaults.set(newValue, forKey: MioPageToolsDefaults.darkNativeHostsKey) }
    }

    public var saveCategory: String {
        get {
            let s = defaults.string(forKey: MioPageToolsDefaults.saveCategoryKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return s.isEmpty ? MioPageToolsDefaults.defaultCategory : s
        }
        nonmutating set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: MioPageToolsDefaults.saveCategoryKey) }
    }

    public func isDarkEnabled(host: String?) -> Bool {
        MioForceDarkPolicy.isEnabled(host: host, global: darkGlobal, sites: darkSites)
    }

    /// 当前站点的开关：nil = 跟随全局（删除站点设置）
    public func setDark(host: String, enabled: Bool?) {
        let h = MioForceDarkPolicy.normalize(host)
        guard !h.isEmpty else { return }
        var s = darkSites
        // 写在实际生效的那一级（例如 example.com 的设置在子域名页面上改）
        let key = MioForceDarkPolicy.matchingSiteKey(host: h, sites: s) ?? h
        if let e = enabled {
            s[key] = e
        } else {
            s.removeValue(forKey: key)
        }
        darkSites = s
    }
}

// MARK: - 注入脚本

public enum MioPageScripts {
    /// www/mio-browser/<name>.js 在 App 包里的位置（cap sync 拷到 public/）
    public static func bundledSource(_ name: String, bundle: Bundle = .main) -> String? {
        let candidates = [
            bundle.url(forResource: name, withExtension: "js", subdirectory: "public/mio-browser"),
            bundle.resourceURL?.appendingPathComponent("public/mio-browser/\(name).js"),
        ]
        for case let url? in candidates {
            if let s = try? String(contentsOf: url, encoding: .utf8), !s.isEmpty { return s }
        }
        return nil
    }

    /// document-start 注入的深色脚本：dark.js + install(配置)
    public static func darkInstallScript(source: String, configJSON: String) -> String {
        source + "\n;try{MioDark.install(document,window," + configJSON + ");}catch(e){}\n"
    }

    /// callAsyncJavaScript 的函数体：已经定义过就不重复解析（同一个内容世界里保留）
    public static func ensureDefined(_ globalName: String, source: String) -> String {
        "if (typeof globalThis.\(globalName) === 'undefined') {\n" + source + "\n}\n"
    }

    public static func readerableBody(source: String) -> String {
        ensureDefined("MioReader", source: source) + "return MioReader.isProbablyReaderable(document);"
    }

    /// 提取正文 + 选中文字 + 阅读视图 HTML；参数 prefs（字典）、force（Bool）
    public static func extractBody(source: String) -> String {
        ensureDefined("MioReader", source: source) + """
        var sel = '';
        try { sel = String(window.getSelection ? window.getSelection() : '').trim(); } catch (e) {}
        var a = null;
        try { a = MioReader.extract(document, { url: location.href, force: !!force }); } catch (e) { a = null; }
        var out = { url: location.href, title: document.title || '', selection: sel.slice(0, 20000) };
        if (a) {
          out.article = { title: a.title, byline: a.byline, siteName: a.siteName, excerpt: a.excerpt, markdown: a.markdown, textLength: a.textLength, url: a.url };
          out.page = MioReader.buildPage(a, prefs);
        }
        return out;
        """
    }

    /// 在主窗口（MioCore 同源）里执行；参数 kind、payload、opts
    public static func saveBody(source: String) -> String {
        ensureDefined("MioSave", source: source) + "return await MioSave.run(kind, payload, opts);"
    }
}
