// MioBuiltinModules.swift — 第一批按 MioModule 接口包装的内置模块（只依赖 Foundation + 共享核心，iOS / macOS 共用）。
// 已接入：MioCore（主页 / 新标签页）、YouTube 防沉迷、WebRTC 防泄露。
// 待接入（v0.4.0 PR 计划，见 docs/mac-native-migration.md）：SponsorBlock / 媒体（MioMediaScripts）、翻译（mio-translate.js + 原生桥）、
// 阅读 / 强制深色 / 存到 Mio（www/mio-browser/*.js）、广告拦截（MioAdblockCore：内容规则 + scriptlets）。

import Foundation

/// MioCore 降为内置模块：默认主页 / 新标签页、导航；之后加 保存到 MioCore、同步、登录
final class MioCoreModule: MioModule {
    static let newTabKey = "mio.tabs.newTabURL" // 与 iOS MioTabs 同一个 key
    let id = "miocore"
    let title = "MioCore"
    let summary = "Mio 导航作为主页和新标签页，保存网页到 MioCore（同步、登录在后续版本）。"
    let section = MioSettingsSection.mioCore
    var enabledKey: String? { nil } // 常开：关掉的话新标签页变空白（设置里改主页地址即可）

    var settings: [MioModuleSetting] {
        [MioModuleSetting(key: Self.newTabKey, title: "主页 / 新标签页", kind: .text(default: MioTabStore.defaultNewTabURL, placeholder: "https://…"),
                          footer: "默认是 Mio 导航。只接受 http(s) 地址。")]
    }

    static func homeURL(_ prefs: MioPrefs) -> String {
        MioTabStore.normalizeNewTabURL(prefs.object(forKey: newTabKey) as? String) ?? MioTabStore.defaultNewTabURL
    }

    func menuItems(page: MioPageContext, prefs: MioPrefs) -> [MioModuleMenuItem] {
        [MioModuleMenuItem(moduleID: id, itemID: "home", title: "打开 Mio 主页", symbol: "house")]
    }

    func perform(_ itemID: String, page: MioPageContext, prefs: MioPrefs) -> MioModuleAction {
        guard itemID == "home", let u = URL(string: Self.homeURL(prefs)) else { return .none }
        return .openURL(u, newTab: true)
    }
}

/// YouTube 防沉迷（定时暂停 / 隐藏推荐）—— 设置 key 与 v0.3.x 相同
final class MioYouTubeFocusModule: MioModule {
    static let enabledKey = "mio.browser.youtubeFocus"
    static let intervalKey = "mio.browser.youtubeFocusInterval"
    static let playablesKey = "mio.browser.youtubeFocusPlayables"
    let id = "youtubeFocus"
    let title = "YouTube 防沉迷"
    let summary = "隐藏首页推荐和 Shorts，定时提醒休息。"
    let section = MioSettingsSection.modules
    var enabledKey: String? { Self.enabledKey }

    var settings: [MioModuleSetting] {
        [
            MioModuleSetting(key: Self.intervalKey, title: "提醒间隔",
                             kind: .choice(options: MioWebCompat.youtubeFocusIntervalChoices.map { ($0, $0 < 60 ? "\($0) 秒" : "\($0 / 60) 分钟") },
                                           default: MioWebCompat.youtubeFocusDefaultInterval)),
            MioModuleSetting(key: Self.playablesKey, title: "隐藏可玩内容（Playables）", kind: .toggle(default: true)),
        ]
    }

    func scripts(prefs: MioPrefs) -> [MioModuleScript] {
        let i = prefs.int(Self.intervalKey, default: MioWebCompat.youtubeFocusDefaultInterval)
        let seconds = MioWebCompat.youtubeFocusIntervalChoices.contains(i) ? i : MioWebCompat.youtubeFocusDefaultInterval
        let js = MioWebCompat.youtubeFocusScript(intervalSeconds: seconds, hidePlayables: prefs.bool(Self.playablesKey, default: true))
        return [MioModuleScript(source: js, injection: .documentStart, mainFrameOnly: true, world: .page)]
    }

    func menuItems(page: MioPageContext, prefs: MioPrefs) -> [MioModuleMenuItem] {
        guard MioWebCompat.isYouTubeHost(page.host) else { return [] }
        return [MioModuleMenuItem(moduleID: id, itemID: "settings", title: "YouTube 防沉迷设置…", symbol: "hourglass")]
    }

    func perform(_ itemID: String, page: MioPageContext, prefs: MioPrefs) -> MioModuleAction {
        itemID == "settings" ? .openSettings(.modules) : .none
    }
}

/// WebRTC 防泄露（本机 IP）—— 放行列表沿用 mio.webrtc.allowlist；显示在「隐私与安全」
final class MioWebRTCModule: MioModule {
    let id = "webrtc"
    let title = "WebRTC 防泄露"
    let summary = "默认屏蔽网页的 WebRTC（防止泄露本机 / 真实 IP），视频通话站点可单独放行。"
    let section = MioSettingsSection.privacy
    var enabledKey: String? { MioWebRTCSettings.enabledKey }

    func scripts(prefs: MioPrefs) -> [MioModuleScript] {
        let allow = ((prefs.object(forKey: MioWebRTCSettings.allowlistKey) as? [String]) ?? []).map(MioWebRTCSettings.normalize).filter { !$0.isEmpty }
        return [MioModuleScript(source: MioWebRTCGuard.script(allow: allow), injection: .documentStart, mainFrameOnly: false, world: .page)]
    }

    func menuItems(page: MioPageContext, prefs: MioPrefs) -> [MioModuleMenuItem] {
        guard let h = page.host, !h.isEmpty else { return [] }
        let list = (prefs.object(forKey: MioWebRTCSettings.allowlistKey) as? [String]) ?? []
        let allowed = MioWebRTCSettings.allowlistEntry(for: h, in: list) != nil
        return [MioModuleMenuItem(moduleID: id, itemID: allowed ? "block" : "allow", title: allowed ? "在此网站屏蔽 WebRTC" : "在此网站允许 WebRTC", symbol: "video")]
    }

    func perform(_ itemID: String, page: MioPageContext, prefs: MioPrefs) -> MioModuleAction {
        guard let h = page.host.map(MioWebRTCSettings.normalize), !h.isEmpty else { return .none }
        var list = Set((prefs.object(forKey: MioWebRTCSettings.allowlistKey) as? [String]) ?? [])
        if itemID == "allow" { list.insert(h) } else if itemID == "block" {
            list.remove(h)
            if let e = MioWebRTCSettings.allowlistEntry(for: h, in: Array(list)) { list.remove(e) }
        } else { return .none }
        prefs.set(list.sorted(), forKey: MioWebRTCSettings.allowlistKey)
        return .reload // 注入脚本在新建 WebView 时生成：宿主重建当前标签的脚本后重新载入
    }
}

enum MioBuiltinModules {
    static func all() -> [MioModule] { [MioCoreModule(), MioYouTubeFocusModule(), MioWebRTCModule()] }
}
