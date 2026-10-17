// MioAdblockModule.swift — 「广告 / 跟踪拦截」模块：开关、站点白名单、订阅开关、自定义订阅、立即更新。
// 规则本身由 MioFilterManager 管理；WebKit 挂载由 MioContentBlocker 完成（白名单站点不挂规则，与 v0.3.x 相同做法）。

import Foundation

public final class MioAdblockModule: MioModuleContentRules {
    public let id = "adblock"
    public let title = "广告 / 跟踪拦截"
    public let summary = "用 WebKit 内容规则拦截广告和跟踪器、隐藏广告元素，并支持 AdGuard scriptlet / 扩展 CSS。默认订阅 AdGuard / EasyList，首次打开自动下载，之后每天更新。"
    public let symbol = "shield.lefthalf.filled"
    public let section = MioSettingsSection.privacy
    public var enabledKey: String? { MioFilterCatalog.enabledKey }
    public let manager: MioFilterManager
    /// 规则有更新、需要重新编译时调用（WebKit 宿主：MioContentBlocker.reload）
    public var recompile: (() async -> Void)?

    public init(manager: MioFilterManager) { self.manager = manager }

    public var settings: [MioModuleSetting] {
        var s: [MioModuleSetting] = [
            MioModuleSetting(key: "adblock.status", title: "状态", kind: .info),
            MioModuleSetting(key: "adblock.update", title: "立即更新", kind: .action(title: "立即更新"),
                             footer: "重新下载全部订阅并编译。平时启动、回到前台时自动检查（每 24 小时一次，失败会自动重试）。"),
            MioModuleSetting(key: "adblock.lists", title: "各列表", kind: .info),
            MioModuleSetting(key: MioFilterCatalog.allowlistKey, title: "不拦截的网站", kind: .stringList(placeholder: "example.com"),
                             footer: "这些网站（含子域名）上关闭拦截。"),
        ]
        s += MioFilterCatalog.subscriptions.map { MioModuleSetting(key: $0.enabledKey, title: $0.name, kind: .toggle(default: $0.defaultEnabled)) }
        s.append(MioModuleSetting(key: MioFilterCatalog.customListsKey, title: "自定义订阅", kind: .stringList(placeholder: "https://easylist.to/easylist/easylist.txt"),
                                  footer: "EasyList / AdGuard 语法的规则列表地址（https）。每个列表超过 15 万条会自动拆分。"))
        return s
    }

    public func settingStatus(_ key: String, prefs: MioPrefs) -> String? {
        switch key {
        case "adblock.status": return manager.statusText()
        case "adblock.lists": return manager.listDetails()
        default: return nil
        }
    }

    public func performSettingAction(_ key: String, prefs: MioPrefs) async -> String? {
        guard key == "adblock.update" else { return nil }
        let msg: String
        if let h = manager.refreshHandler {
            msg = await h(true)
        } else {
            msg = await manager.refresh(force: true)
            await recompile?()
        }
        return msg + "。" + manager.statusText()
    }

    public func shouldApplyContentRules(topURL: URL?, prefs: MioPrefs) -> Bool {
        guard let u = topURL, let sc = u.scheme?.lowercased(), sc == "http" || sc == "https" else { return true }
        // Cloudflare Access / 身份提供商的登录页不挂规则（拦截列表误伤登录脚本会让 MioCore 登录卡住）
        if MioAccessAuth.isAuthFlowURL(u, prefs: prefs) { return false }
        return MioFilterCatalog.allowlistEntry(for: u.host, prefs: prefs) == nil
    }

    public func menuItems(page: MioPageContext, prefs: MioPrefs) -> [MioModuleMenuItem] {
        guard let h = page.host, page.url?.scheme?.hasPrefix("http") == true else { return [] }
        let allowed = MioFilterCatalog.allowlistEntry(for: h, prefs: prefs) != nil
        return [MioModuleMenuItem(moduleID: id, itemID: allowed ? "block" : "allow", title: "在此网站关闭拦截", symbol: "shield.slash", checked: allowed)]
    }

    public func perform(_ itemID: String, page: MioPageContext, prefs: MioPrefs) -> MioModuleAction {
        guard let h = page.host else { return .none }
        let entry = MioFilterCatalog.normalizeHost(h)
        var list = prefs.strings(MioFilterCatalog.allowlistKey).map(MioFilterCatalog.normalizeHost)
        switch itemID {
        case "allow": list.append(entry)
        case "block": list.removeAll { entry == $0 || entry.hasSuffix("." + $0) }
        default: return .none
        }
        prefs.set(Array(Set(list.filter { !$0.isEmpty })).sorted(), forKey: MioFilterCatalog.allowlistKey)
        return .reload
    }
}
