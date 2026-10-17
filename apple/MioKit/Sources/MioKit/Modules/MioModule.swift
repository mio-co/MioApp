// MioModule.swift — 「Mio 扩展」：每个功能（广告拦截、YouTube 防沉迷、SponsorBlock、翻译、WebRTC、阅读 / 深色、用户脚本、容器、MioCore）
// 都是一个 MioModule。只依赖 Foundation：iOS（firefox-ios fork）和 Mac 原生壳共用，Linux 上可单测。
//
// 宿主（A：iOS 的 Tab / WKWebView 配置；B：Mac 的 AppKit 窗口）只认这里的接口：
//   - scripts → WKUserScript（WebKit 适配见 MioWebKitInstaller.swift）
//   - messageHandlers → WKScriptMessageHandlerWithReply（按 world 挂）
//   - contentRuleLists → WKContentRuleList（广告拦截，见 MioContentBlocker）
//   - menuItems → 工具栏「…」/ 地址栏菜单 / 分享菜单；perform → MioModuleAction（宿主执行）
//   - settings → 设置页由 MioExtensionSettingsModel 生成数据模型，UI 各端自己画（SwiftUI / UIKit / AppKit 都行）
// 用户脚本模块的脚本来自 MioUserScriptStore（用户自装），走同一个注入通道。

import Foundation

// MARK: - 设置分区（照搬 Safari / Firefox 设置；Mio 独有的单独分区）

public enum MioSettingsSection: String, CaseIterable, Identifiable, Codable {
    case general, tabs, autofill, search, privacy, websites, advanced
    case extensions, containers, userScripts, mioCore

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .general: return "通用"
        case .tabs: return "标签页"
        case .autofill: return "自动填充"
        case .search: return "搜索"
        case .privacy: return "隐私与安全"
        case .websites: return "网站设置"
        case .advanced: return "高级"
        case .extensions: return "Mio 扩展"
        case .containers: return "容器"
        case .userScripts: return "用户脚本"
        case .mioCore: return "MioCore"
        }
    }

    /// SF Symbols 名（iOS / macOS 都有）
    public var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .tabs: return "square.on.square"
        case .autofill: return "pencil.and.list.clipboard"
        case .search: return "magnifyingglass"
        case .privacy: return "hand.raised"
        case .websites: return "globe"
        case .advanced: return "gearshape.2"
        case .extensions: return "puzzlepiece.extension"
        case .containers: return "square.stack.3d.up"
        case .userScripts: return "curlybraces"
        case .mioCore: return "house"
        }
    }
}

// MARK: - 声明式设置项

public struct MioChoiceOption: Hashable, Codable {
    public let value: MioPrefValue
    public let label: String
    public init(_ value: MioPrefValue, _ label: String) { self.value = value; self.label = label }
}

public struct MioModuleSetting: Hashable, Identifiable {
    public enum Kind: Hashable {
        case toggle(default: Bool)
        /// 单选；default 的类型（.int / .string）决定存储类型
        case choice(options: [MioChoiceOption], default: MioPrefValue)
        /// secure = 密码框（例如 API Key 由宿主存钥匙串，key 只做标识）
        case text(default: String, placeholder: String, secure: Bool = false)
        /// 字符串列表（站点白名单、订阅地址……）；UI 画成可增删的列表
        case stringList(placeholder: String)
        /// 按钮：点了调用 MioModule.performSettingAction(key)
        case action(title: String)
        /// 只读说明 / 状态（value 由 MioModule.settingStatus(key:) 提供）
        case info
    }

    public let key: String
    public let title: String
    public let kind: Kind
    public var footer: String?
    /// 只有当另一个设置（同模块）等于某值时才显示，例如 SponsorBlock 分类只在总开关打开时显示
    public var visibleWhen: Condition?
    public var id: String { key }

    public struct Condition: Hashable {
        public let key: String
        public let equals: MioPrefValue
        public init(key: String, equals: MioPrefValue) { self.key = key; self.equals = equals }
    }

    public init(key: String, title: String, kind: Kind, footer: String? = nil, visibleWhen: Condition? = nil) {
        self.key = key; self.title = title; self.kind = kind; self.footer = footer; self.visibleWhen = visibleWhen
    }

    public var defaultValue: MioPrefValue {
        switch kind {
        case .toggle(let d): return .bool(d)
        case .choice(_, let d): return d
        case .text(let d, _, _): return .string(d)
        case .stringList: return .strings([])
        case .action, .info: return .none
        }
    }
}

// MARK: - 注入脚本

public enum MioScriptWorld: Hashable, Codable {
    /// 与页面共享 window（需要改页面 API 的脚本：YouTube 防沉迷、WebRTC、媒体）
    case page
    /// 独立 WKContentWorld（页面看不到也改不了）
    case isolated(String)

    public var name: String? { if case .isolated(let n) = self { return n }; return nil }
}

public struct MioModuleScript: Hashable {
    public enum Injection: String, Hashable, Codable { case documentStart, documentEnd }
    public let source: String
    public var injection: Injection
    public var mainFrameOnly: Bool
    public var world: MioScriptWorld

    public init(source: String, injection: Injection = .documentStart, mainFrameOnly: Bool = true, world: MioScriptWorld = .page) {
        self.source = source; self.injection = injection; self.mainFrameOnly = mainFrameOnly; self.world = world
    }
}

// MARK: - 页面上下文 / 菜单 / 动作

public struct MioPageContext: Hashable {
    public var url: URL?
    public var title: String
    /// 宿主当前标签所在容器（容器模块用）
    public var containerID: String?
    public var host: String? { url?.host?.lowercased() }
    public init(url: URL?, title: String = "", containerID: String? = nil) { self.url = url; self.title = title; self.containerID = containerID }
}

public struct MioModuleMenuItem: Hashable, Identifiable {
    public enum Placement: String, Hashable { case pageMenu, share }
    public let moduleID: String
    public let itemID: String
    public let title: String
    public var symbol: String?
    /// 是否显示勾选状态（例如「在此网站强制深色」）
    public var checked: Bool?
    public var placement: Placement
    public var id: String { moduleID + "." + itemID }
    public init(moduleID: String, itemID: String, title: String, symbol: String? = nil, checked: Bool? = nil, placement: Placement = .pageMenu) {
        self.moduleID = moduleID; self.itemID = itemID; self.title = title; self.symbol = symbol; self.checked = checked; self.placement = placement
    }
}

/// 在页面里执行一段 async 函数体（宿主用 callAsyncJavaScript），结果交回 registry.handleScriptResult
public struct MioScriptCall: Hashable {
    public let body: String
    /// 参数（JSON 对象字符串；宿主 JSONSerialization 解出来传给 callAsyncJavaScript）
    public let argumentsJSON: String
    public let world: MioScriptWorld
    /// 结果交回哪个处理器（nil = 不关心结果）
    public let resultHandler: String?
    public init(body: String, arguments: [String: Any] = [:], world: MioScriptWorld, resultHandler: String? = nil) {
        self.body = body
        self.argumentsJSON = (try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        self.world = world
        self.resultHandler = resultHandler
    }
    public var arguments: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
    }
}

/// 需要宿主 UI 的动作（宿主各自实现；不认识的忽略）
public enum MioHostCommand: Hashable {
    /// 显示阅读视图：reader.js 提取出的文章（JSON 字符串）
    case showReader(articleJSON: String)
    /// 存到 MioCore：kind = bookmark / note / clip，payload JSON（见 mio-save.js）；宿主交给 MioSaveRunner
    case saveToMio(kind: String, payloadJSON: String)
    /// 在指定容器里重新打开当前页
    case reopenInContainer(containerID: String)
    /// 打开用户脚本安装确认（url 指向 .user.js）
    case installUserScript(URL)
    /// 提示一句话（toast / HUD）
    case toast(String)
}

public enum MioModuleAction: Hashable {
    case none
    case openURL(URL, newTab: Bool)
    case evaluateJavaScript(String, world: MioScriptWorld)
    case runScript(MioScriptCall)
    case openSettings(MioSettingsSection)
    /// 设置已改，宿主重装脚本后重新载入当前页
    case reload
    case host(MioHostCommand)
}

// MARK: - 模块协议

public protocol MioModule: AnyObject {
    var id: String { get }
    var title: String { get }
    var summary: String { get }
    var symbol: String { get }
    /// 开关与设置显示在哪个分区（「Mio 扩展」总页永远列出全部模块）
    var section: MioSettingsSection { get }
    /// 开关的 UserDefaults key（v0.3.x 已有的 key 继续用）；nil = 常开
    var enabledKey: String? { get }
    var defaultEnabled: Bool { get }
    var settings: [MioModuleSetting] { get }
    func scripts(prefs: MioPrefs) -> [MioModuleScript]
    func menuItems(page: MioPageContext, prefs: MioPrefs) -> [MioModuleMenuItem]
    func perform(_ itemID: String, page: MioPageContext, prefs: MioPrefs) -> MioModuleAction
    /// runScript 的结果回调
    func handleScriptResult(_ handler: String, result: Any?, page: MioPageContext, prefs: MioPrefs) -> MioModuleAction
    /// .action 设置项被点击（例如「立即更新规则」）；返回给用户看的一句话
    func performSettingAction(_ key: String, prefs: MioPrefs) async -> String?
    /// .info 设置项的当前文字
    func settingStatus(_ key: String, prefs: MioPrefs) -> String?
}

public extension MioModule {
    var symbol: String { "puzzlepiece.extension" }
    var enabledKey: String? { "mio.kit.module.\(id).enabled" }
    var defaultEnabled: Bool { true }
    var settings: [MioModuleSetting] { [] }
    func scripts(prefs: MioPrefs) -> [MioModuleScript] { [] }
    func menuItems(page: MioPageContext, prefs: MioPrefs) -> [MioModuleMenuItem] { [] }
    func perform(_ itemID: String, page: MioPageContext, prefs: MioPrefs) -> MioModuleAction { .none }
    func handleScriptResult(_ handler: String, result: Any?, page: MioPageContext, prefs: MioPrefs) -> MioModuleAction { .none }
    func performSettingAction(_ key: String, prefs: MioPrefs) async -> String? { nil }
    func settingStatus(_ key: String, prefs: MioPrefs) -> String? { nil }

    func isEnabled(_ prefs: MioPrefs) -> Bool {
        guard let k = enabledKey else { return true }
        return prefs.bool(k, default: defaultEnabled)
    }
}

// MARK: - 可选能力（需要原生配合的模块）

/// 原生消息通道：宿主为每个 (world, name) 注册一个 WKScriptMessageHandlerWithReply，消息转给 handle
public struct MioMessageEndpoint: Hashable {
    public let name: String
    public let world: MioScriptWorld
    public init(name: String, world: MioScriptWorld) { self.name = name; self.world = world }
}

/// 页面发来的消息（WebKit 无关的形式，适配层从 WKScriptMessage 转换）
public struct MioScriptMessage {
    public let endpoint: MioMessageEndpoint
    public let body: Any
    public let isMainFrame: Bool
    /// 发消息的 frame 的安全来源（scheme / host / port）
    public let origin: MioFrameOrigin
    public let pageURL: URL?
    public init(endpoint: MioMessageEndpoint, body: Any, isMainFrame: Bool, origin: MioFrameOrigin, pageURL: URL?) {
        self.endpoint = endpoint; self.body = body; self.isMainFrame = isMainFrame; self.origin = origin; self.pageURL = pageURL
    }
}

/// 回复：成功值（JSON 兼容）或错误字符串（JS 端 reject）
public enum MioScriptReply {
    case value(Any?)
    case error(String)
}

public protocol MioModuleMessageHandling: MioModule {
    func messageEndpoints(prefs: MioPrefs) -> [MioMessageEndpoint]
    func handle(_ message: MioScriptMessage, prefs: MioPrefs) async -> MioScriptReply
}

/// 内容拦截规则（WKContentRuleList）：宿主从 MioContentBlocker 取编译好的规则挂到 WKUserContentController
public protocol MioModuleContentRules: MioModule {
    /// 当前页面是否应挂规则（白名单站点返回 false）
    func shouldApplyContentRules(topURL: URL?, prefs: MioPrefs) -> Bool
}

// MARK: - 注册表

public final class MioModuleRegistry {
    public private(set) var modules: [MioModule] = []
    public let prefs: MioPrefs
    /// 设置变化回调（默认发 .mioSettingsDidChange）
    public var onChange: (String) -> Void = { key in
        NotificationCenter.default.post(name: .mioSettingsDidChange, object: nil, userInfo: ["key": key])
    }

    public init(prefs: MioPrefs, modules: [MioModule] = []) {
        self.prefs = prefs
        for m in modules { register(m) }
    }

    /// 同 id 只保留第一个（内置模块先注册，不会被覆盖）
    @discardableResult
    public func register(_ m: MioModule) -> Bool {
        guard !m.id.isEmpty, !modules.contains(where: { $0.id == m.id }) else { return false }
        modules.append(m)
        return true
    }

    public func module(_ id: String) -> MioModule? { modules.first { $0.id == id } }
    public func module<T: MioModule>(_ type: T.Type) -> T? { modules.first { $0 is T } as? T }

    public var enabled: [MioModule] { modules.filter { $0.isEnabled(prefs) } }

    public func isEnabled(_ id: String) -> Bool { module(id)?.isEnabled(prefs) ?? false }

    public func setEnabled(_ id: String, _ on: Bool) {
        guard let m = module(id), let k = m.enabledKey else { return }
        prefs.set(on, forKey: k)
        onChange(k)
    }

    public func set(_ value: MioPrefValue, forKey key: String) {
        prefs.setValue(value, forKey: key)
        onChange(key)
    }

    /// 新建 WebView / 设置变化后要装的全部脚本（按注册顺序；关掉的模块不注入任何东西）
    public func scripts() -> [(moduleID: String, script: MioModuleScript)] {
        enabled.flatMap { m in m.scripts(prefs: prefs).map { (m.id, $0) } }
    }

    /// 启用模块需要的消息通道
    public func messageEndpoints() -> [(moduleID: String, endpoint: MioMessageEndpoint)] {
        enabled.compactMap { $0 as? MioModuleMessageHandling }.flatMap { m in m.messageEndpoints(prefs: prefs).map { (m.id, $0) } }
    }

    /// 把消息路由给声明了该通道的启用模块；模块已关 → 拒绝
    public func handle(_ message: MioScriptMessage) async -> MioScriptReply {
        for m in enabled.compactMap({ $0 as? MioModuleMessageHandling }) where m.messageEndpoints(prefs: prefs).contains(message.endpoint) {
            return await m.handle(message, prefs: prefs)
        }
        return .error("no handler")
    }

    public func menuItems(page: MioPageContext) -> [MioModuleMenuItem] {
        enabled.flatMap { $0.menuItems(page: page, prefs: prefs) }
    }

    public func perform(_ item: MioModuleMenuItem, page: MioPageContext) -> MioModuleAction {
        guard let m = module(item.moduleID), m.isEnabled(prefs) else { return .none }
        let a = m.perform(item.itemID, page: page, prefs: prefs)
        if a == .reload { onChange("\(m.id).\(item.itemID)") }
        return a
    }

    public func handleScriptResult(moduleID: String, handler: String, result: Any?, page: MioPageContext) -> MioModuleAction {
        guard let m = module(moduleID), m.isEnabled(prefs) else { return .none }
        return m.handleScriptResult(handler, result: result, page: page, prefs: prefs)
    }

    public func performSettingAction(moduleID: String, key: String) async -> String? {
        guard let m = module(moduleID) else { return nil }
        return await m.performSettingAction(key, prefs: prefs)
    }

    /// 当前页面要挂内容规则的模块
    public func contentRuleModules(topURL: URL?) -> [MioModuleContentRules] {
        enabled.compactMap { $0 as? MioModuleContentRules }.filter { $0.shouldApplyContentRules(topURL: topURL, prefs: prefs) }
    }

    public func modules(in section: MioSettingsSection) -> [MioModule] { modules.filter { $0.section == section } }
}
