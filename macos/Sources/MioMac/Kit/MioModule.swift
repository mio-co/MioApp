// MioModule.swift — v0.4.0 统一的「可开关功能模块」接口（只依赖 Foundation：iOS / macOS 共用，tools/MioAppTests 在 Linux 上单测）。
//
// 浏览器是 App 本体；每个功能（YouTube 防沉迷 / SponsorBlock、翻译、阅读、广告拦截、WebRTC、强制深色、MioCore……）都是一个 MioModule：
//   - id / 标题 / 简介 / 属于设置里的哪个分区
//   - 开关（enabledKey；沿用 v0.3.x 已有的 UserDefaults key，升级后用户设置不丢）+ 设置项（声明式，设置页自动生成）
//   - 注入脚本（document-start / end、主框架 / 所有 frame、页面世界 / 独立 WKContentWorld）
//   - 页面菜单项（工具栏「…」/ 地址栏菜单，按当前页面过滤）和它们的动作
// 宿主（iOS 的 UIKit 标签控制器、macOS 的 AppKit 窗口）只认这个接口：把 scripts 变成 WKUserScript，把 menuItems 放进菜单，执行 MioModuleAction。
// 用户脚本（Tampermonkey 兼容）是用户自装的插件，走同一个注入通道，但由 MioUserScriptStore 管理，不注册成内置模块。

import Foundation

// MARK: - 设置分区（照搬 Safari；Safari 没有的单独分区）

enum MioSettingsSection: String, CaseIterable, Identifiable {
    // Safari（macOS 设置窗口 / iOS「设置 › Safari」的分区顺序）
    case general, tabs, autofill, search, privacy, websites, advanced
    // Mio 独有
    case containers, userScripts, modules, mioCore

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .tabs: return "标签页"
        case .autofill: return "自动填充"
        case .search: return "搜索"
        case .privacy: return "隐私与安全"
        case .websites: return "网站设置"
        case .advanced: return "高级"
        case .containers: return "容器"
        case .userScripts: return "用户脚本"
        case .modules: return "模块"
        case .mioCore: return "MioCore"
        }
    }

    /// SF Symbols 名（两端都有）
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .tabs: return "square.on.square"
        case .autofill: return "pencil.and.list.clipboard"
        case .search: return "magnifyingglass"
        case .privacy: return "hand.raised"
        case .websites: return "globe"
        case .advanced: return "gearshape.2"
        case .containers: return "square.stack.3d.up"
        case .userScripts: return "curlybraces"
        case .modules: return "puzzlepiece.extension"
        case .mioCore: return "house"
        }
    }

    var isSafari: Bool {
        switch self {
        case .general, .tabs, .autofill, .search, .privacy, .websites, .advanced: return true
        default: return false
        }
    }

    static var safariSections: [MioSettingsSection] { allCases.filter { $0.isSafari } }
    static var mioSections: [MioSettingsSection] { allCases.filter { !$0.isSafari } }
}

// MARK: - 偏好存储（UserDefaults 直接满足；单测用字典）

protocol MioPrefs: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: MioPrefs {}

final class MioMemoryPrefs: MioPrefs {
    private(set) var values: [String: Any] = [:]
    init(_ v: [String: Any] = [:]) { values = v }
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

extension MioPrefs {
    func bool(_ key: String, default d: Bool) -> Bool { (object(forKey: key) as? Bool) ?? (object(forKey: key) as? NSNumber)?.boolValue ?? d }
    func int(_ key: String, default d: Int) -> Int { (object(forKey: key) as? Int) ?? (object(forKey: key) as? NSNumber)?.intValue ?? d }
    func string(_ key: String, default d: String) -> String { (object(forKey: key) as? String) ?? d }
}

// MARK: - 模块声明

struct MioModuleSetting: Equatable, Identifiable {
    enum Kind: Equatable {
        case toggle(default: Bool)
        case choice(options: [(value: Int, label: String)], default: Int)
        case text(default: String, placeholder: String)

        static func == (a: Kind, b: Kind) -> Bool {
            switch (a, b) {
            case let (.toggle(x), .toggle(y)): return x == y
            case let (.choice(o1, d1), .choice(o2, d2)): return d1 == d2 && o1.map { $0.value } == o2.map { $0.value } && o1.map { $0.label } == o2.map { $0.label }
            case let (.text(d1, p1), .text(d2, p2)): return d1 == d2 && p1 == p2
            default: return false
            }
        }
    }

    let key: String
    let title: String
    let kind: Kind
    var footer: String? = nil
    var id: String { key }
}

struct MioModuleScript: Equatable {
    enum Injection: Equatable { case documentStart, documentEnd }
    enum World: Equatable {
        case page                 // 与页面共享 window（需要改页面 API 的脚本）
        case isolated(String)     // 独立 WKContentWorld（页面看不到也改不了）
    }
    let source: String
    var injection: Injection = .documentStart
    var mainFrameOnly: Bool = true
    var world: World = .page
}

/// 模块看到的当前页面
struct MioPageContext: Equatable {
    var url: URL?
    var title: String = ""
    var host: String? { url?.host?.lowercased() }
}

struct MioModuleMenuItem: Equatable, Identifiable {
    let moduleID: String
    let itemID: String
    let title: String
    var symbol: String? = nil
    var id: String { moduleID + "." + itemID }
}

enum MioModuleAction: Equatable {
    case none
    case openURL(URL, newTab: Bool)
    case evaluateJavaScript(String)
    case openSettings(MioSettingsSection)
    case reload
}

protocol MioModule: AnyObject {
    var id: String { get }
    var title: String { get }
    var summary: String { get }
    /// 开关与设置显示在哪个分区（模块总表永远在 .modules 里也会列出）
    var section: MioSettingsSection { get }
    /// 开关的 UserDefaults key（v0.3.x 已有的 key 继续用）；nil = 常开（例如 MioCore 本身）
    var enabledKey: String? { get }
    var defaultEnabled: Bool { get }
    var settings: [MioModuleSetting] { get }
    func scripts(prefs: MioPrefs) -> [MioModuleScript]
    func menuItems(page: MioPageContext, prefs: MioPrefs) -> [MioModuleMenuItem]
    func perform(_ itemID: String, page: MioPageContext, prefs: MioPrefs) -> MioModuleAction
}

extension MioModule {
    var enabledKey: String? { "mio.module.\(id).enabled" }
    var defaultEnabled: Bool { true }
    var settings: [MioModuleSetting] { [] }
    func scripts(prefs: MioPrefs) -> [MioModuleScript] { [] }
    func menuItems(page: MioPageContext, prefs: MioPrefs) -> [MioModuleMenuItem] { [] }
    func perform(_ itemID: String, page: MioPageContext, prefs: MioPrefs) -> MioModuleAction { .none }

    func isEnabled(_ prefs: MioPrefs) -> Bool {
        guard let k = enabledKey else { return true }
        return prefs.bool(k, default: defaultEnabled)
    }
}

// MARK: - 注册表

final class MioModuleRegistry {
    private(set) var modules: [MioModule] = []
    let prefs: MioPrefs

    init(prefs: MioPrefs, modules: [MioModule] = []) {
        self.prefs = prefs
        for m in modules { register(m) }
    }

    /// 同 id 只保留第一个（内置模块先注册，不会被覆盖）
    @discardableResult
    func register(_ m: MioModule) -> Bool {
        guard !m.id.isEmpty, !modules.contains(where: { $0.id == m.id }) else { return false }
        modules.append(m)
        return true
    }

    func module(_ id: String) -> MioModule? { modules.first { $0.id == id } }

    var enabled: [MioModule] { modules.filter { $0.isEnabled(prefs) } }

    func setEnabled(_ id: String, _ on: Bool) {
        guard let m = module(id), let k = m.enabledKey else { return }
        prefs.set(on, forKey: k)
    }

    /// 新建 WebView 时要装的全部脚本（按注册顺序；关掉的模块不注入任何东西）
    func scripts() -> [(moduleID: String, script: MioModuleScript)] {
        enabled.flatMap { m in m.scripts(prefs: prefs).map { (m.id, $0) } }
    }

    func menuItems(page: MioPageContext) -> [MioModuleMenuItem] {
        enabled.flatMap { $0.menuItems(page: page, prefs: prefs) }
    }

    func perform(_ item: MioModuleMenuItem, page: MioPageContext) -> MioModuleAction {
        guard let m = module(item.moduleID), m.isEnabled(prefs) else { return .none }
        return m.perform(item.itemID, page: page, prefs: prefs)
    }

    func modules(in section: MioSettingsSection) -> [MioModule] { modules.filter { $0.section == section } }
}
