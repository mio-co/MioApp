// MioMacWebKit.swift — 原生 macOS 的 WKWebView 配置：容器（每个容器一个 WKWebsiteDataStore(forIdentifier:)）、桌面 Safari UA、
// 注入脚本全部来自启用的 MioModule（MioModuleRegistry；YouTube 防沉迷、WebRTC 防泄露……开关读与 iOS 相同的 UserDefaults key）。
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
        installScripts(c.userContentController)
        // mio://home 的本机桥（占位）：只回应 MioCore 来源，其他网站调用一律拒绝。API 本体由 MioKit（线路 C）提供
        c.userContentController.addScriptMessageHandler(MioMacHomeBridge.shared, contentWorld: .page, name: MioMacHomeBridge.name)
        return c
    }

    /// 内置模块注册表（iOS 以后用同一份 MioBuiltinModules.all()）
    static let modules = MioModuleRegistry(prefs: UserDefaults.standard, modules: MioBuiltinModules.all())

    /// 把启用模块的脚本装进 WebView（设置改了以后对已有 WebView 再调一次 + 重新载入即可生效）
    static func installScripts(_ ucc: WKUserContentController) {
        ucc.removeAllUserScripts()
        for (_, s) in modules.scripts() {
            let world: WKContentWorld
            switch s.world {
            case .page: world = .page
            case .isolated(let name): world = .world(name: name)
            }
            ucc.addUserScript(WKUserScript(source: s.source, injectionTime: s.injection == .documentStart ? .atDocumentStart : .atDocumentEnd,
                                           forMainFrameOnly: s.mainFrameOnly, in: world))
        }
    }

    static func colorFor(container: MioContainer?) -> NSColor? {
        guard let c = container, let hex = MioContainerCore.colorHex[c.color] else { return nil }
        return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// MioCore 本机桥占位（window.webkit.messageHandlers.mioHome.postMessage(...)）：
/// 来源校验在这里（MioMacHome.isTrustedOrigin），具体能力（相册同步、控制本机……）等 MioKit 的 MioCore 桥接入后转发过去。
@MainActor
final class MioMacHomeBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = MioMacHomeBridge()
    static let name = "mioHome"

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        let origin = message.frameInfo.securityOrigin
        var c = URLComponents()
        c.scheme = origin.protocol
        c.host = origin.host
        if origin.port != 0 { c.port = origin.port }
        guard message.frameInfo.isMainFrame, MioMacHome.isTrustedOrigin(c.url) else { return (nil, "origin-not-allowed") }
        let op = (message.body as? [String: Any])?["op"] as? String ?? ""
        if op == "ping" { return (["ok": true, "platform": "macOS", "bridge": "placeholder"], nil) }
        return (nil, "not-implemented")
    }
}
