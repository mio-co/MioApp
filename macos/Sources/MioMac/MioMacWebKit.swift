// MioMacWebKit.swift — 原生 macOS 的 WKWebView 配置：容器（每个容器一个 WKWebsiteDataStore(forIdentifier:)）、桌面 Safari UA、
// 共享的注入脚本（YouTube 防沉迷、WebRTC 防泄露，开关读与 iOS 相同的 UserDefaults key）。
//
// 与 Catalyst 版的区别：
//   - 不需要 MioMacMetrics 的 77% 换算：AppKit 窗口按 1:1 显示，pageZoom 直接等于 Safari 档位
//   - 不需要 YouTube「v0.3.0 移动 UA → HLS」兜底（MioYouTubeCompat.legacyMacUserAgent）：AppKit WKWebView 有 MSE，桌面 UA 即可拿到 DASH 高清
//   - 不注入 returnKeyFixScript：那是 Catalyst / iPad 的回车键兜底，AppKit 的 NSTextInputClient 正常

import AppKit
import WebKit

@MainActor
enum MioMacWebKit {
    /// 默认容器 = 与 iOS / Catalyst 内置浏览器相同的固定 UUID（MioBrowserSettings.dataStoreID）
    static let defaultDataStoreID = UUID(uuidString: "6D696F00-6272-6F77-7365-720000000001")!
    static let containersStateKey = "mio.containers.state" // = MioContainerStore.stateKey
    static let youtubeFocusKey = "mio.browser.youtubeFocus"
    static let youtubeFocusIntervalKey = "mio.browser.youtubeFocusInterval"
    static let youtubePlayablesKey = "mio.browser.youtubeFocusPlayables"

    private static var stores: [String: WKWebsiteDataStore] = [:]

    static var safariVersion: String {
        let pv = ProcessInfo.processInfo.operatingSystemVersion
        let plist = NSDictionary(contentsOfFile: "/System/Library/CoreServices/SystemVersion.plist") as? [String: Any]
        let v = MioWebCompat.macOSVersion(systemVersionPlist: plist, processVersion: (pv.majorVersion, pv.minorVersion))
        return MioWebCompat.safariVersion(macOSMajor: v.major, minor: v.minor)
    }

    static var desktopUserAgent: String { MioWebCompat.desktopUserAgent(safariVersion: safariVersion) }

    /// 容器 id → 数据存储。"default" / 非法 id → 固定 UUID 的默认数据；其他 = 容器自己的 UUID
    static func dataStore(for containerID: String) -> WKWebsiteDataStore {
        let key = MioContainerCore.isContainerId(containerID) ? containerID.lowercased() : MioContainerCore.defaultId
        if let s = stores[key] { return s }
        let id = key == MioContainerCore.defaultId ? defaultDataStoreID : (UUID(uuidString: key) ?? defaultDataStoreID)
        let s = WKWebsiteDataStore(forIdentifier: id)
        stores[key] = s
        return s
    }

    /// 已保存的容器（与 iOS 同一个 JSON 格式；Mac 原生版 bundle id 不同时是独立的一份）
    static func containerState() -> MioContainerState {
        MioContainerState(json: UserDefaults.standard.data(forKey: containersStateKey))
    }

    static func configuration(containerID: String) -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = dataStore(for: containerID)
        c.applicationNameForUserAgent = MioWebCompat.desktopApplicationName(safariVersion: safariVersion)
        c.preferences.isElementFullscreenEnabled = true
        c.preferences.javaScriptCanOpenWindowsAutomatically = false
        c.allowsAirPlayForMediaPlayback = true
        let ucc = c.userContentController
        let d = UserDefaults.standard
        if (d.object(forKey: youtubeFocusKey) as? Bool) ?? true {
            let interval = d.integer(forKey: youtubeFocusIntervalKey)
            let seconds = MioWebCompat.youtubeFocusIntervalChoices.contains(interval) ? interval : MioWebCompat.youtubeFocusDefaultInterval
            let playables = (d.object(forKey: youtubePlayablesKey) as? Bool) ?? true
            ucc.addUserScript(WKUserScript(source: MioWebCompat.youtubeFocusScript(intervalSeconds: seconds, hidePlayables: playables),
                                           injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        if let rtc = MioWebRTCSettings.script() {
            ucc.addUserScript(WKUserScript(source: rtc, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        return c
    }

    static func colorFor(container: MioContainer?) -> NSColor? {
        guard let c = container, let hex = MioContainerCore.colorHex[c.color] else { return nil }
        return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
