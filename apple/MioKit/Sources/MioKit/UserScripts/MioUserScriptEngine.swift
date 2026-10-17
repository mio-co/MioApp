// MioUserScriptEngine.swift — 用户脚本引擎（Greasemonkey / Tampermonkey 兼容）：安装 / 更新 / 启停 / 删除 / GM 值，以及生成注入脚本。
// 解析、匹配（@match / @include / @exclude / @exclude-match）、@run-at、@grant、运行时 JS（GM_getValue / setValue / xmlHttpRequest / addStyle …）
// 都在 Core/MioUserScriptCore.swift（v0.3.x 原样复制，已有单测）。这里是 v0.3.x MioUserScripts.swift 去掉 UIKit 的部分：
//   - MioUserScriptEngine：store + 变化通知 + 模块脚本生成（每个有 @grant 的脚本一个独立 WKContentWorld：mio.userscript.<id>）
//   - MioUserScriptInstaller：下载（含 @require / @resource、#sha256= 完整性校验）、检查更新
//   - MioUserScriptsModule：「Mio 扩展」里的开关 + 管理入口；GM 原生通道 mioUserScript 的消息处理（WebKit 适配在 WebKit/MioUserScriptBridge.swift）
// 只依赖 Foundation。

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public final class MioUserScriptEngine {
    public let store: MioUserScriptStore
    public var appVersion: String
    /// GM 值变化计数：宿主在下一次主框架导航前比较，变了就重装脚本（代码里带值快照，GM_getValue 才能同步返回）
    public private(set) var valuesVersion = 0
    public var onChange: () -> Void = { NotificationCenter.default.post(name: .mioSettingsDidChange, object: nil, userInfo: ["key": "userscripts"]) }

    public init(directory: URL = MioUserScriptEngine.defaultDirectory(), appVersion: String = MioKitInfo.version) {
        store = MioUserScriptStore(directory: directory)
        self.appVersion = appVersion
    }

    /// 与 v0.3.x 同一个目录（Application Support/MioUserScripts）：升级后脚本和 GM 值都在
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("MioUserScripts", isDirectory: true)
    }

    public var scripts: [MioUserScript] { store.scripts }

    @discardableResult
    public func install(_ pkg: MioUserScriptPackage) -> MioUserScript { let s = store.install(pkg); onChange(); return s }
    public func setEnabled(_ id: String, _ on: Bool) { store.setEnabled(id, on); onChange() }
    public func delete(_ id: String) { store.delete(id); onChange() }
    public func move(from: Int, to: Int) { store.move(from: from, to: to); onChange() }
    public func setConnectDecision(_ id: String, host: String, allow: Bool?) { store.setConnectDecision(id, host: host, allow: allow) }

    public func setValue(_ id: String, _ key: String, _ json: String) -> Bool {
        let ok = store.values.set(id, key, json)
        if ok { valuesVersion += 1 }
        return ok
    }

    public func deleteValue(_ id: String, _ key: String) { store.values.delete(id, key); valuesVersion += 1 }

    /// 启用脚本的注入代码（按列表顺序）。@grant none → 页面世界；否则各自的 world
    public func moduleScripts() -> [MioModuleScript] {
        store.scripts.filter { $0.enabled }.map { s in
            let src = MioUserScriptRuntime.source(for: s, values: s.isolated ? store.values.all(s.id) : [:], appVersion: appVersion, platform: MioKitInfo.platform)
            return MioModuleScript(source: src, injection: s.meta.runAt == .documentStart ? .documentStart : .documentEnd,
                                   mainFrameOnly: s.meta.noframes, world: s.isolated ? .isolated(s.worldName) : .page)
        }
    }

    /// 需要 GM 原生通道的 world（启用、且有 @grant 的脚本）
    public var isolatedWorldNames: Set<String> { Set(store.scripts.filter { $0.enabled && $0.isolated }.map { $0.worldName }) }

    public static let worldPrefix = "mio.userscript."
    public func script(forWorld name: String?) -> MioUserScript? {
        guard let n = name, n.hasPrefix(Self.worldPrefix) else { return nil }
        return store.script(id: String(n.dropFirst(Self.worldPrefix.count)))
    }
}

// MARK: - 下载 / 安装 / 更新

public enum MioUserScriptInstaller {
    /// 可替换（单测用）
    public static var fetch: (URLRequest) async throws -> (Data, Int) = { req in
        let (d, r) = try await URLSession.shared.data(for: req)
        return (d, (r as? HTTPURLResponse)?.statusCode ?? 200)
    }

    public static func download(_ url: URL) async throws -> String {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let fragment = comps?.fragment
        comps?.fragment = nil
        guard let target = comps?.url else { throw MioUserScriptError.download("无效地址") }
        var req = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        req.setValue("text/javascript, application/javascript, text/plain, */*", forHTTPHeaderField: "Accept")
        let data: Data, code: Int
        do { (data, code) = try await fetch(req) } catch { throw MioUserScriptError.download(error.localizedDescription) }
        guard (200..<300).contains(code) else { throw MioUserScriptError.download("HTTP \(code)（\(target.absoluteString)）") }
        guard data.count <= MioUserScriptParser.maxScriptBytes else { throw MioUserScriptError.tooLarge(data.count) }
        try verifyIntegrity(data, fragment: fragment, url: target)
        guard let s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { throw MioUserScriptError.download("无法解码文本") }
        return s
    }

    /// @require https://…/x.js#sha256=<hex 或 base64>（sha384 / sha512 在有 CryptoKit 的平台校验；md5 跳过）
    public static func verifyIntegrity(_ data: Data, fragment: String?, url: URL) throws {
        guard let f = fragment, !f.isEmpty else { return }
        for part in f.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            let kv = part.split(maxSplits: 1, whereSeparator: { $0 == "=" || $0 == "-" }).map(String.init)
            guard kv.count == 2, let digest = MioHash.digest(kv[0].lowercased(), data) else { continue }
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            if kv[1].lowercased() == hex || kv[1] == digest.base64EncodedString() { return }
            throw MioUserScriptError.download("\(url.lastPathComponent) 校验失败（\(kv[0])）")
        }
    }

    public static func resolve(_ s: String, base: String?) -> URL? {
        let b = base.flatMap(URL.init(string:))
        guard let u = URL(string: s, relativeTo: b)?.absoluteURL, let sc = u.scheme?.lowercased(), sc == "http" || sc == "https" else { return nil }
        return u
    }

    /// 解析元数据并下载 @require / @resource（任何一个失败都不安装，与 Tampermonkey 一致）
    public static func prepare(code: String, sourceURL: String?) async throws -> MioUserScriptPackage {
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

    public static func prepare(url: URL) async throws -> MioUserScriptPackage {
        try await prepare(code: try await download(url), sourceURL: url.absoluteString)
    }

    /// 有新版本时返回准备好的包（还没安装）；没有更新返回 nil
    public static func checkUpdate(_ s: MioUserScript) async throws -> MioUserScriptPackage? {
        guard let checkURL = MioUserScriptSource.updateCheckURL(meta: s.meta, sourceURL: s.sourceURL) else {
            throw MioUserScriptError.download("脚本没有 @updateURL / @downloadURL，也不是从网址安装的")
        }
        let text = try await download(checkURL)
        let remote = try MioUserScriptParser.parse(text)
        guard MioUserScriptVersion.isNewer(remote.version, than: s.meta.version) else { return nil }
        if checkURL.path.lowercased().hasSuffix(".meta.js") {
            guard let dl = MioUserScriptSource.downloadURL(meta: remote, sourceURL: s.sourceURL) else { throw MioUserScriptError.download("找不到新版本的下载地址") }
            return try await prepare(code: try await download(dl), sourceURL: s.sourceURL ?? dl.absoluteString)
        }
        return try await prepare(code: text, sourceURL: s.sourceURL ?? checkURL.absoluteString)
    }

    /// 检查全部启用脚本的更新并安装。返回 (已更新的脚本名, 失败的脚本名)
    public static func updateAll(_ engine: MioUserScriptEngine) async -> (updated: [String], failed: [String]) {
        var updated: [String] = [], failed: [String] = []
        for s in engine.scripts where MioUserScriptSource.updateCheckURL(meta: s.meta, sourceURL: s.sourceURL) != nil {
            do {
                if let pkg = try await checkUpdate(s) { engine.install(pkg); updated.append(pkg.meta.displayName) }
                engine.store.markChecked(s.id)
            } catch { failed.append(s.meta.displayName) }
        }
        return (updated, failed)
    }
}

// MARK: - 模块

/// 宿主为 GM API 提供的平台能力
public protocol MioUserScriptHost: AnyObject {
    func userScriptOpenTab(_ url: URL, background: Bool)
    func userScriptSetClipboard(_ text: String, html: Bool)
    /// @connect 已声明、用户还没决定过的跨域请求：问用户。返回 nil = 仅这一次允许 / 拒绝不记住（allowOnce），true/false = 记住
    func userScriptAskConnect(scriptName: String, host: String) async -> (allow: Bool, remember: Bool)
    func userScriptNotification(title: String, text: String)
}

public final class MioUserScriptsModule: MioModule {
    public let id = "userScripts"
    public let title = "用户脚本"
    public let summary = "安装 Greasemonkey / Tampermonkey 用户脚本（.user.js），每个脚本在独立环境里运行，可单独启停、自动更新。"
    public let symbol = "curlybraces"
    public let section = MioSettingsSection.userScripts
    /// 新 key（v0.3.x 没有总开关，默认开）
    public var enabledKey: String? { "mio.userscripts.enabled" }
    public let engine: MioUserScriptEngine
    public init(engine: MioUserScriptEngine) { self.engine = engine }

    public var settings: [MioModuleSetting] {
        [
            MioModuleSetting(key: "userscripts.summary", title: "已安装", kind: .info, footer: "脚本列表、编辑、从网址 / 文件安装在「用户脚本」设置页。"),
            MioModuleSetting(key: "userscripts.update", title: "检查全部更新", kind: .action(title: "检查")),
        ]
    }

    public func settingStatus(_ key: String, prefs: MioPrefs) -> String? {
        guard key == "userscripts.summary" else { return nil }
        let on = engine.scripts.filter { $0.enabled }.count
        return "\(engine.scripts.count) 个脚本，\(on) 个启用"
    }

    public func performSettingAction(_ key: String, prefs: MioPrefs) async -> String? {
        guard key == "userscripts.update" else { return nil }
        let r = await MioUserScriptInstaller.updateAll(engine)
        if r.updated.isEmpty && r.failed.isEmpty { return "全部已是最新" }
        return [r.updated.isEmpty ? nil : "已更新：\(r.updated.joined(separator: "、"))", r.failed.isEmpty ? nil : "失败：\(r.failed.joined(separator: "、"))"]
            .compactMap { $0 }.joined(separator: "；")
    }

    public func scripts(prefs: MioPrefs) -> [MioModuleScript] { engine.moduleScripts() }

    public func menuItems(page: MioPageContext, prefs: MioPrefs) -> [MioModuleMenuItem] {
        guard let u = page.url, MioUserScriptSource.looksLikeUserScript(u) else { return [] }
        return [MioModuleMenuItem(moduleID: id, itemID: "install", title: "安装此用户脚本…", symbol: "curlybraces")]
    }

    public func perform(_ itemID: String, page: MioPageContext, prefs: MioPrefs) -> MioModuleAction {
        guard itemID == "install", let u = page.url else { return .none }
        return .host(.installUserScript(u))
    }
}
