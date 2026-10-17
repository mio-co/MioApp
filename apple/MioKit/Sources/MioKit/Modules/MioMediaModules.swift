// MioMediaModules.swift — YouTube 防沉迷、YouTube 媒体（后台播放 / 画中画 / Now Playing）、SponsorBlock。
// 脚本逻辑来自 v0.3.x（MioWebCompat.youtubeFocusScript、MioMediaScripts），key 不变。

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// YouTube 防沉迷（隐藏推荐 / Shorts，定时提醒）—— key 与 v0.3.x 相同
public final class MioYouTubeFocusModule: MioModule {
    public static let enabledKey = "mio.browser.youtubeFocus"
    public static let intervalKey = "mio.browser.youtubeFocusInterval"
    public static let playablesKey = "mio.browser.youtubeFocusPlayables"
    public let id = "youtubeFocus"
    public let title = "YouTube 防沉迷"
    public let summary = "隐藏首页推荐和 Shorts，定时提醒休息。"
    public let symbol = "hourglass"
    public let section = MioSettingsSection.extensions
    public var enabledKey: String? { Self.enabledKey }
    public var defaultEnabled: Bool { true }
    public init() {}

    public var settings: [MioModuleSetting] {
        [
            MioModuleSetting(key: Self.intervalKey, title: "提醒间隔",
                             kind: .choice(options: MioWebCompat.youtubeFocusIntervalChoices.map { MioChoiceOption(.int($0), $0 < 60 ? "\($0) 秒" : "\($0 / 60) 分钟") },
                                           default: .int(MioWebCompat.youtubeFocusDefaultInterval))),
            MioModuleSetting(key: Self.playablesKey, title: "隐藏可玩内容（Playables）", kind: .toggle(default: true)),
        ]
    }

    public func scripts(prefs: MioPrefs) -> [MioModuleScript] {
        let i = prefs.int(Self.intervalKey, default: MioWebCompat.youtubeFocusDefaultInterval)
        let seconds = MioWebCompat.youtubeFocusIntervalChoices.contains(i) ? i : MioWebCompat.youtubeFocusDefaultInterval
        let js = MioWebCompat.youtubeFocusScript(intervalSeconds: seconds, hidePlayables: prefs.bool(Self.playablesKey, default: true))
        return [MioModuleScript(source: js, injection: .documentStart, mainFrameOnly: true, world: .page)]
    }

    public func menuItems(page: MioPageContext, prefs: MioPrefs) -> [MioModuleMenuItem] {
        guard MioWebCompat.isYouTubeHost(page.host) else { return [] }
        return [MioModuleMenuItem(moduleID: id, itemID: "settings", title: "YouTube 防沉迷设置…", symbol: "hourglass")]
    }

    public func perform(_ itemID: String, page: MioPageContext, prefs: MioPrefs) -> MioModuleAction {
        itemID == "settings" ? .openSettings(.extensions) : .none
    }
}

/// SponsorBlock：声明式（开关 + 分类）。脚本本身在 MioMediaModule 里（同一段 YouTube 媒体脚本），按本模块的开关决定是否跳过片段。
public final class MioSponsorBlockModule: MioModule {
    public static let enabledKey = "mio.media.sponsorBlock"
    public static func categoryKey(_ c: String) -> String { "mio.media.sb.\(c)" }
    public let id = "sponsorBlock"
    public let title = "SponsorBlock"
    public let summary = "自动跳过 YouTube 视频里社区标注的赞助 / 推广片段，可撤销。只发送视频 ID 哈希前 4 位。数据来自 sponsor.ajay.app（CC BY-NC-SA 4.0）。"
    public let symbol = "forward.end"
    public let section = MioSettingsSection.extensions
    public var enabledKey: String? { Self.enabledKey }
    public init() {}

    public var settings: [MioModuleSetting] {
        MioMediaScripts.categories.map { c in
            MioModuleSetting(key: Self.categoryKey(c.key), title: c.title, kind: .toggle(default: c.defaultOn))
        }
    }

    public static func enabledCategories(_ prefs: MioPrefs) -> [String] {
        MioMediaScripts.categories.filter { prefs.bool(categoryKey($0.key), default: $0.defaultOn) }.map { $0.key }
    }

    public static func isOn(_ prefs: MioPrefs) -> Bool { prefs.bool(enabledKey, default: true) }
}

/// YouTube 媒体增强：后台继续播放、播放器画中画按钮、锁屏 Now Playing；SponsorBlock 跳过也在这段脚本里。
/// 原生消息 mioMedia：sbFetch（页面 fetch 失败时代取 SponsorBlock，只允许 skipSegments 哈希前缀接口）、state（Now Playing 兜底 → onMediaState）
public final class MioMediaModule: MioModuleMessageHandling {
    public static let backgroundKey = "mio.browser.backgroundPlayback"
    public static let pipKey = "mio.media.pipButton"
    public static let nowPlayingKey = "mio.media.nowPlaying"
    public static let messageName = "mioMedia"
    public let id = "media"
    public let title = "YouTube 媒体增强"
    public let summary = "后台继续播放、画中画按钮、锁屏 / 控制中心显示正在播放。"
    public let symbol = "play.rectangle"
    public let section = MioSettingsSection.extensions
    /// 新 key（v0.3.x 没有总开关，默认开 = 行为不变）
    public var enabledKey: String? { "mio.kit.module.media.enabled" }
    /// 页面报告的播放状态（宿主接 MPNowPlayingInfoCenter；有 navigator.mediaSession 时 WebKit 自己处理）
    public var onMediaState: (([String: Any]) -> Void)?
    /// SponsorBlock 代取（可替换，单测用）
    public var fetcher: (URL) async -> (Int, Data?) = { url in
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (d, r) = try? await URLSession.shared.data(for: req) else { return (0, nil) }
        return ((r as? HTTPURLResponse)?.statusCode ?? 0, d)
    }
    public init() {}

    public var settings: [MioModuleSetting] {
        [
            MioModuleSetting(key: Self.backgroundKey, title: "后台继续播放", kind: .toggle(default: true), footer: "切到别的 App / 锁屏时不暂停（YouTube 等）。"),
            MioModuleSetting(key: Self.pipKey, title: "播放器上显示画中画按钮", kind: .toggle(default: true)),
            MioModuleSetting(key: Self.nowPlayingKey, title: "锁屏 / 控制中心显示正在播放", kind: .toggle(default: true)),
        ]
    }

    public func config(_ prefs: MioPrefs) -> MioMediaScripts.Config {
        MioMediaScripts.Config(platform: MioKitInfo.platform,
                               background: prefs.bool(Self.backgroundKey, default: true),
                               nowPlaying: prefs.bool(Self.nowPlayingKey, default: true),
                               pip: prefs.bool(Self.pipKey, default: true),
                               sponsorBlock: MioSponsorBlockModule.isOn(prefs),
                               categories: MioSponsorBlockModule.enabledCategories(prefs))
    }

    public func scripts(prefs: MioPrefs) -> [MioModuleScript] {
        var out: [MioModuleScript] = []
        if prefs.bool(Self.backgroundKey, default: true) {
            out.append(MioModuleScript(source: MioMediaScripts.visibilityScript, injection: .documentStart, mainFrameOnly: true, world: .page))
        }
        out.append(MioModuleScript(source: MioMediaScripts.youtubeMediaScript(config(prefs)), injection: .documentStart, mainFrameOnly: true, world: .page))
        return out
    }

    public func messageEndpoints(prefs: MioPrefs) -> [MioMessageEndpoint] { [MioMessageEndpoint(name: Self.messageName, world: .page)] }

    public func handle(_ message: MioScriptMessage, prefs: MioPrefs) async -> MioScriptReply {
        guard message.isMainFrame, let body = message.body as? [String: Any], let type = body["type"] as? String else { return .error("bad message") }
        switch type {
        case "sbFetch":
            let s = body["url"] as? String ?? ""
            guard MioSponsorBlockModule.isOn(prefs), MioMediaScripts.isAllowedSponsorBlockURL(s), let url = URL(string: s) else { return .error("not allowed") }
            let (code, data) = await fetcher(url)
            if code == 404 { return .value("[]") }
            if code == 200, let d = data, d.count < 2_000_000, let t = String(data: d, encoding: .utf8) { return .value(t) }
            return .error("HTTP \(code)")
        case "state":
            if prefs.bool(Self.nowPlayingKey, default: true) { onMediaState?(body) }
            return .value(nil)
        default:
            return .error("unknown type")
        }
    }
}
