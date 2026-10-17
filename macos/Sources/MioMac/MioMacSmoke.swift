// MioMacSmoke.swift — CI 冒烟（MIO_SMOKE_OUT=<json> 时运行，写完结果退出；0 = 通过）：
//   1. example.com：typeof MediaSource / ManagedMediaSource（门槛：MediaSource 必须存在——Catalyst 版这里是 undefined）
//   2. ⌘+ / ⌘0：pageZoom 跟随 Safari 档位并复位
//   3. 新标签打开 YouTube 视频页（桌面 Safari UA）：记录 MSE isTypeSupported、ytInitialPlayerResponse 的可用格式
//      （playabilityStatus 不是 OK —— 例如 LOGIN_REQUIRED / 机房 IP 被要求登录 —— 只记录，不算失败）
//   4. 容器：新容器标签用 WKWebsiteDataStore(forIdentifier: 容器 UUID) 加载页面
//   5. Firefox 式界面：mio://home、本机桥来源校验、固定 / 静音 / 拖拽排序 / 关闭 / 溢出 / 拖出成新窗口、地址栏下拉、缩放 HUD、
//      查找栏、Mio 扩展面板、应用菜单（含子视图滑动）、侧边栏 / 垂直标签、全屏；录屏（.mov）+ 每个动画的连拍帧条 + 帧率
//   6. 设置窗口（about:preferences 风格）截图 → MIO_SMOKE_SHOTS 目录（默认与 json 同目录）

import AppKit
import WebKit

@MainActor
final class MioMacSmoke {
    let controller: MioMacBrowserWindowController
    weak var delegate: MioMacAppDelegate?
    let outPath: String
    var report: [String: Any] = [:]

    static let youtubeURL = ProcessInfo.processInfo.environment["MIO_SMOKE_YT"] ?? "https://www.youtube.com/watch?v=aqz-KE-bpKQ"

    init(controller: MioMacBrowserWindowController, delegate: MioMacAppDelegate, outPath: String) {
        self.controller = controller
        self.delegate = delegate
        self.outPath = outPath
    }

    static let mseProbeJS = #"""
    (function () {
      var r = { href: location.href, ua: navigator.userAgent,
        mediaSource: typeof window.MediaSource, managedMediaSource: typeof window.ManagedMediaSource,
        webkitMediaSource: typeof window.WebKitMediaSource, pictureInPicture: typeof document.pictureInPictureEnabled,
        webkitPiP: typeof HTMLVideoElement !== 'undefined' && typeof HTMLVideoElement.prototype.webkitSetPresentationMode };
      var types = ['video/webm; codecs="vp9"', 'video/webm; codecs="vp09.00.51.08"', 'video/mp4; codecs="avc1.640028"',
                   'video/mp4; codecs="hvc1.1.6.L123.B0"', 'video/mp4; codecs="av01.0.12M.08"', 'audio/webm; codecs="opus"', 'audio/mp4; codecs="mp4a.40.2"'];
      try {
        if (window.MediaSource) { r.mseTypes = {}; types.forEach(function (t) { r.mseTypes[t] = MediaSource.isTypeSupported(t); }); }
        if (window.ManagedMediaSource) { r.mmsTypes = {}; types.forEach(function (t) { r.mmsTypes[t] = ManagedMediaSource.isTypeSupported(t); }); }
      } catch (e) { r.mseError = String(e); }
      return JSON.stringify(r);
    })()
    """#

    static let youtubeProbeJS = #"""
    (function () {
      var r = { href: location.href, title: document.title, ua: navigator.userAgent,
        mediaSource: typeof window.MediaSource, managedMediaSource: typeof window.ManagedMediaSource };
      var p = window.ytInitialPlayerResponse || null, src = 'ytInitialPlayerResponse';
      if (!p) { try { var mp0 = document.getElementById('movie_player'); if (mp0 && mp0.getPlayerResponse) { p = mp0.getPlayerResponse(); src = 'movie_player.getPlayerResponse'; } } catch (e) {} }
      if (p) {
        r.playerResponseSource = src;
        var ps = p.playabilityStatus || {};
        r.playability = { status: ps.status || null, reason: ps.reason || null };
        var sd = p.streamingData || {};
        r.hlsManifest = !!sd.hlsManifestUrl; r.dashManifest = !!sd.dashManifestUrl;
        r.formats = (sd.formats || []).map(function (f) { return { itag: f.itag, q: f.qualityLabel || null, h: f.height || null, mime: (f.mimeType || '').split(';')[0] }; });
        var af = sd.adaptiveFormats || [];
        r.adaptiveCount = af.length;
        r.adaptiveVideo = af.filter(function (f) { return /^video\//.test(f.mimeType || ''); })
          .map(function (f) { return { itag: f.itag, q: f.qualityLabel || null, h: f.height || null, mime: f.mimeType }; }).slice(0, 40);
        r.maxAdaptiveHeight = af.reduce(function (m, f) { return Math.max(m, f.height || 0); }, 0);
      } else { r.playerResponse = null; }
      try {
        var mp = document.getElementById('movie_player');
        if (mp && mp.getAvailableQualityLevels) { r.qualityLevels = mp.getAvailableQualityLevels(); r.playbackQuality = mp.getPlaybackQuality ? mp.getPlaybackQuality() : null; }
      } catch (e) { r.qualityError = String(e); }
      var v = document.querySelector('video');
      if (v) { r.video = { srcScheme: (v.currentSrc || v.src || '').split(':')[0] || null, w: v.videoWidth, h: v.videoHeight, readyState: v.readyState, paused: v.paused }; }
      return JSON.stringify(r);
    })()
    """#

    func run() async {
        let started = Date()
        report["platform"] = "macOS native (AppKit WKWebView)"
        report["os"] = ProcessInfo.processInfo.operatingSystemVersionString
        report["safariVersion"] = MioMacWebKit.safariVersion
        report["desktopUserAgent"] = MioMacWebKit.desktopUserAgent
        report["bundleIdentifier"] = orNull(Bundle.main.bundleIdentifier)

        // 1. MSE
        var mseOK = false
        if let t0 = controller.activeTabID, let wv0 = controller.webViews[t0] {
            await waitLoad(t0, timeout: 40)
            report["exampleError"] = orNull(controller.lastError[t0])
            let mse = await eval(wv0, Self.mseProbeJS)
            let rtc = await eval(wv0, MioWebRTCGuard.probeScript)
            report["webrtcProbe"] = orNull(rtc)
            report["mse"] = orNull(mse)
            mseOK = (mse?["mediaSource"] as? String) == "function"

            // 2. 缩放
            controller.zoomReset(nil)
            controller.zoomIn(nil)
            let afterIn = Double(wv0.pageZoom)
            controller.zoomIn(nil)
            let afterIn2 = Double(wv0.pageZoom)
            controller.zoomOut(nil)
            let afterOut = Double(wv0.pageZoom)
            controller.zoomReset(nil)
            let afterReset = Double(wv0.pageZoom)
            report["zoom"] = ["afterZoomIn": afterIn, "afterZoomIn2": afterIn2, "afterZoomOut": afterOut, "afterReset": afterReset]
            report["zoomOK"] = abs(afterIn - 1.15) < 0.001 && abs(afterIn2 - 1.25) < 0.001 && abs(afterOut - 1.15) < 0.001 && abs(afterReset - 1.0) < 0.001
        }

        // 4. 容器（后台标签）
        var state = MioMacWebKit.containerState()
        var containerOK = false
        var ciContainer = state.containers.first(where: { $0.name == "CI 冒烟" })
        if ciContainer == nil { ciContainer = try? state.create(name: "CI 冒烟") }
        if let c = ciContainer {
            UserDefaults.standard.set(state.jsonData(), forKey: MioMacWebKit.containersStateKey)
            if let ct = controller.newTab(url: "https://example.com/?container", containerID: c.id, activate: false) {
                await waitLoad(ct.id, timeout: 40)
                let ds = ct.webView.configuration.websiteDataStore
                let tabContainer = controller.store.tab(ct.id)?.containerID ?? ""
                containerOK = tabContainer == c.id && ds.identifier?.uuidString.lowercased() == c.id && controller.lastError[ct.id] == nil
                report["container"] = ["id": c.id, "tabContainer": tabContainer, "dataStoreIdentifier": orNull(ds.identifier?.uuidString.lowercased()),
                                       "persistent": ds.isPersistent, "error": orNull(controller.lastError[ct.id])] as [String: Any]
            }
        }
        report["containerOK"] = containerOK

        // 3. YouTube（新标签 = ⌘T 的同一路径）
        if let yt = controller.newTab(url: Self.youtubeURL) {
            await waitLoad(yt.id, timeout: 60)
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            report["youtubeError"] = orNull(controller.lastError[yt.id])
            let ytProbe = await eval(yt.webView, Self.youtubeProbeJS)
            report["youtube"] = orNull(ytProbe)
            report["youtubeModuleMenu"] = MioMacWebKit.modules.menuItems(page: controller.currentPage).map { $0.id }
        }

        // 5. Firefox 式界面 + 动画证据
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let dir = ProcessInfo.processInfo.environment["MIO_SMOKE_SHOTS"] ?? (outPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        self.dir = dir
        let c = controller
        var ui: [String: Any] = [:]
        // GitHub 的 macOS 机器默认开了「减少动态效果」：CI 用 MIO_REDUCE_MOTION=0 强制开动画来录证据（减少动态效果的路径在 5q 单独测）
        ui["systemReduceMotion"] = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        ui["forceReduceMotion"] = orNull(MioMotion.forceReduce)
        var shots: [String: Any] = [:]
        shots["main"] = await screenshot(window: c.window, webView: c.activeWebView, dir: dir, name: "mac-native-window-cache", chrome: false)
        shot("mac-native-window", &shots)
        shotChrome("mac-native-tabstrip", &shots)

        let rec = MioMacRecorder()
        rec.start(path: (dir as NSString).appendingPathComponent("mac-native-anim.mov"), fps: 10) { [weak c] in c?.window?.frame ?? .zero }
        let meter = MioFrameMeter()
        meter.start(on: c.tabBar)
        var strips: [String: Any] = [:]

        // 5a. mio://home 首页（地址栏显示「Mio」）
        let homeStrip = await strip("anim-tab-open", title: "新建标签页（mio://home）：标签从 0 宽度展开 + 淡入，其余标签收缩", chromeOnly: true) {
            c.newTab(url: MioMacHome.address)
        }
        strips["tabOpen"] = homeStrip
        if let hid = c.activeTabID { await waitLoad(hid, timeout: 25) }
        try? await Task.sleep(nanoseconds: 800_000_000)
        ui["homeAddressBar"] = c.navBar.urlBar.displayedText
        ui["homeURL"] = orNull(c.activeWebView?.url?.absoluteString)
        ui["homeIsHome"] = c.isHome(c.activeWebView?.url)
        ui["homeSecurity"] = c.navBar.urlBar.security.rawValue
        let homeOK = c.navBar.urlBar.displayedText == MioMacHome.displayName && c.isHome(c.activeWebView?.url)
        ui["homeOK"] = homeOK
        shot("mac-native-home", &shots)

        // 5b. 本机桥只对 MioCore 来源开放
        let bridgeJS = "try { const r = await window.webkit.messageHandlers.mioHome.postMessage({op:'ping'}); return 'allowed:' + JSON.stringify(r); } catch (e) { return 'rejected:' + (e && e.message ? e.message : String(e)); }"
        var bridge: [String: Any] = [:]
        if let hwv = c.activeWebView { bridge["home"] = await callAsync(hwv, bridgeJS) }
        if let ex = c.store.tabs.first(where: { $0.url.contains("example.com") }), let ewv = c.webViews[ex.id] {
            bridge["example"] = await callAsync(ewv, bridgeJS)
        }
        let bridgeOK = ((bridge["example"] as? String) ?? "").hasPrefix("rejected:") && ((bridge["example"] as? String) ?? "").contains("origin-not-allowed")
        bridge["gateOK"] = bridgeOK
        ui["bridge"] = bridge

        // 5c. 多标签：固定、静音、正在播放
        c.newTab(url: "https://example.org/", activate: false)
        try? await Task.sleep(nanoseconds: 600_000_000)
        if let first = c.store.tabs.first { c.togglePin(first.id) }
        try? await Task.sleep(nanoseconds: 500_000_000)
        if let yt = c.store.tabs.first(where: { $0.url.contains("youtube") }) { c.debugSetAudible(yt.id, true) }
        if let ex2 = c.store.tabs.first(where: { $0.url.contains("example.org") }) { c.toggleMute(ex2.id) }
        try? await Task.sleep(nanoseconds: 700_000_000)
        shot("mac-native-tabs", &shots)
        shotChrome("mac-native-tabstrip-multi", &shots)
        ui["pinnedOK"] = c.tabBar.items.first?.pinned == true && (c.tabBar.tabFrames[c.tabBar.items.first?.id ?? -1]?.width ?? 0) <= 40
        ui["tabItems"] = c.tabBar.items.map { ["id": $0.id, "title": $0.title, "pinned": $0.pinned, "audible": $0.audible, "muted": $0.muted, "home": $0.isHome] as [String: Any] }

        // 5d. 拖拽排序（模拟鼠标：最后一个标签拖到第一个普通标签的位置）
        let orderBefore = c.store.tabs.map(\.id)
        var dragOK = false
        if let last = c.tabBar.items.last, !last.pinned {
            c.tabBar.beginProgrammaticDrag(last.id)
            let start = c.tabBar.dragStartPoint ?? .zero
            let firstNormalX = c.tabBar.items.first(where: { !$0.pinned }).flatMap { c.tabBar.tabFrames[$0.id]?.midX } ?? 120
            let distance = start.x - (firstNormalX + c.tabBar.tabsOriginX) + 20
            let dragStrip = await strip("anim-tab-drag", title: "拖拽排序：被拖标签跟手（抬起阴影），其余标签让位", chromeOnly: true, count: 14, intervalMs: 50) {
                Task { @MainActor in
                    for i in 1...16 {
                        c.tabBar.dragMoved(to: NSPoint(x: start.x - distance * CGFloat(i) / 16, y: start.y), screenPoint: .zero)
                        try? await Task.sleep(nanoseconds: 35_000_000)
                    }
                    c.tabBar.dragEnded(screenPoint: .zero)
                }
            }
            strips["tabDrag"] = dragStrip
            try? await Task.sleep(nanoseconds: 500_000_000)
            let after = c.store.tabs.map(\.id)
            dragOK = after != orderBefore && after.firstIndex(of: last.id) ?? 99 < orderBefore.firstIndex(of: last.id) ?? 0
            ui["dragOrder"] = ["before": orderBefore, "after": after]
        }
        ui["dragOK"] = dragOK

        // 5e. 关闭标签（收缩 + 补位）
        if let victim = c.store.tabs.first(where: { $0.url.contains("example.org") }) {
            strips["tabClose"] = await strip("anim-tab-close", title: "关闭标签：宽度收缩到 0 + 淡出，其余标签平滑补位", chromeOnly: true) {
                c.closeTab(victim.id)
            }
        }
        try? await Task.sleep(nanoseconds: 400_000_000)

        // 5f. 地址栏聚焦 + 下拉建议
        strips["urlbarFocus"] = await strip("anim-urlbar-focus", title: "地址栏聚焦：突出放大 + 描边 + 阴影，下拉建议淡入下滑", chromeOnly: false, count: 9, intervalMs: 35, region: .top(250)) {
            c.focusAddressBar()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 120_000_000)
                c.navBar.urlBar.field.stringValue = "exam"
                c.navBar.urlBar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: c.navBar.urlBar.field))
            }
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
        ui["urlbarFocused"] = c.navBar.urlBar.isFocused
        ui["dropdownVisible"] = c.navBar.urlBar.dropdown.isVisible
        ui["dropdownRows"] = c.navBar.urlBar.dropdown.rowCount
        ui["suggestions"] = c.suggestions(for: "exam").map { "\($0.kind.rawValue): \($0.title)" }
        shot("mac-native-urlbar-dropdown", &shots)
        c.navBar.urlBar.dropdown.hide(animated: false)
        if let wv = c.activeWebView { c.window?.makeFirstResponder(wv) }
        try? await Task.sleep(nanoseconds: 400_000_000)

        // 5g. ⌘+ 缩放提示 HUD + 地址栏百分比
        if let ex = c.store.tabs.first(where: { $0.url.contains("example.com") && !$0.url.contains("container") }) { c.select(ex.id) }
        try? await Task.sleep(nanoseconds: 500_000_000)
        strips["zoomHUD"] = await strip("anim-zoom-hud", title: "⌘+ 缩放：中央 HUD 淡入 + 微缩放，地址栏滑出 115%", chromeOnly: false, count: 8, intervalMs: 40, region: .window) {
            c.zoomIn(nil)
        }
        c.zoomIn(nil) // 再放大一档：HUD 在显示中（0.9 秒后淡出）时读状态、截图
        try? await Task.sleep(nanoseconds: 250_000_000)
        ui["zoomHUDShown"] = c.zoomHUD.isShowing
        ui["zoomPill"] = c.navBar.urlBar.zoomButton.titleLabel.stringValue
        shot("mac-native-zoom-hud", &shots)
        try? await Task.sleep(nanoseconds: 1_400_000_000)
        c.zoomReset(nil)
        try? await Task.sleep(nanoseconds: 1_300_000_000)

        // 5h. 查找栏
        strips["findbar"] = await strip("anim-findbar", title: "⌘F 查找栏从底部滑出", chromeOnly: false, count: 8, intervalMs: 35, region: .window) {
            c.showFindBar(nil)
        }
        c.findBar.field.stringValue = "Example"
        c.findBar.find(backwards: false, fresh: true)
        try? await Task.sleep(nanoseconds: 900_000_000)
        ui["findStatus"] = c.findBar.status.stringValue
        ui["findBarVisible"] = c.findBarVisible
        shot("mac-native-findbar", &shots)
        c.hideFindBar()
        try? await Task.sleep(nanoseconds: 400_000_000)

        // 5i. Mio 扩展面板
        strips["extensions"] = await strip("anim-extensions-panel", title: "Mio 扩展面板：淡入 + 下滑 + 微缩放", chromeOnly: false, count: 7, intervalMs: 35, region: .top(480)) {
            c.showExtensionsPanel()
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
        ui["extensionsPanel"] = MioMacPopupPanel.current?.isVisible ?? false
        ui["extensionRows"] = rowTitles(MioMacPopupPanel.current?.contentView)
        shot("mac-native-extensions", &shots)
        c.dismissPanel()
        try? await Task.sleep(nanoseconds: 400_000_000)

        // 5j. 应用菜单 + 子菜单滑动
        strips["appMenu"] = await strip("anim-appmenu", title: "≡ 应用菜单打开", chromeOnly: false, count: 7, intervalMs: 35, region: .window) {
            c.showAppMenu()
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
        ui["appMenuRows"] = rowTitles(MioMacPopupPanel.current?.contentView)
        shot("mac-native-appmenu", &shots)
        if let row = findRow("更多工具", in: MioMacPopupPanel.current?.contentView) {
            strips["appMenuSub"] = await strip("anim-appmenu-subview", title: "应用菜单子视图左右滑动（更多工具）", chromeOnly: false, count: 8, intervalMs: 35, region: .window) {
                row.onClick?()
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
            shot("mac-native-appmenu-sub", &shots)
        }
        c.dismissPanel()
        try? await Task.sleep(nanoseconds: 400_000_000)

        // 5k. 列出所有标签页
        c.showAllTabsPanel(from: c.tabBar.listAllButton)
        try? await Task.sleep(nanoseconds: 500_000_000)
        shot("mac-native-alltabs", &shots)
        c.dismissPanel()
        try? await Task.sleep(nanoseconds: 300_000_000)

        // 5l. 侧边栏（垂直标签）滑入 / 垂直标签模式
        strips["sidebar"] = await strip("anim-sidebar", title: "侧边栏滑入（垂直标签页）", chromeOnly: false, count: 9, intervalMs: 40, region: .top(360)) {
            c.setSidebar(visible: true, animated: true)
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
        shot("mac-native-sidebar", &shots)
        UserDefaults.standard.set(true, forKey: MioMacPreferencesView.verticalTabsKey)
        strips["verticalMode"] = await strip("anim-vertical-tabs-mode", title: "切换垂直标签模式：横向标签条收起，导航栏升到红绿灯一行", chromeOnly: false, count: 8, intervalMs: 40, region: .top(300)) {
            c.applyPreferences()
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
        ui["verticalMode"] = c.verticalTabsMode
        shot("mac-native-vertical-tabs", &shots)
        UserDefaults.standard.set(false, forKey: MioMacPreferencesView.verticalTabsKey)
        c.applyPreferences()
        try? await Task.sleep(nanoseconds: 400_000_000)
        c.setSidebar(visible: false, animated: true)
        try? await Task.sleep(nanoseconds: 500_000_000)

        // 5m. 标签溢出：横向滚动 + 右端 +
        let extraBefore = c.store.count
        for _ in 0..<14 {
            c.newTab(url: "about:blank", activate: false)
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
        try? await Task.sleep(nanoseconds: 600_000_000)
        ui["overflow"] = c.tabBar.layoutResult.overflow
        ui["overflowTabWidth"] = c.tabBar.layoutResult.tabWidth
        shotChrome("mac-native-tabs-overflow", &shots)
        if let lastBlank = c.store.tabs.last { c.select(lastBlank.id) }
        try? await Task.sleep(nanoseconds: 600_000_000)
        shotChrome("mac-native-tabs-overflow-scrolled", &shots)
        for t in c.store.tabs where t.url == "about:blank" { c.closeTab(t.id) }
        try? await Task.sleep(nanoseconds: 600_000_000)
        ui["overflowRestored"] = c.store.count == extraBefore

        // 5n. 拖出成新窗口
        var detachOK = false
        if let ytTab = c.store.tabs.first(where: { $0.url.contains("youtube") }), let d = delegate, let w = c.window {
            let before = d.controllers.count
            c.detachTab(ytTab.id, at: NSPoint(x: w.frame.midX + 60, y: w.frame.midY))
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if d.controllers.count == before + 1, let nw = d.controllers.last, nw !== c {
                detachOK = nw.store.count == 1 && nw.activeWebView?.url?.host?.contains("youtube") == true
                MioMacRecorder.savePNG(MioMacRecorder.capture(window: nw.window), to: (dir as NSString).appendingPathComponent("mac-native-detached.png"))
                nw.window?.performClose(nil)
                nw.window?.close()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        ui["detachOK"] = detachOK
        c.window?.makeKeyAndOrderFront(nil)

        // 5o. 右键菜单内容
        if let id = c.activeTabID { ui["tabContextMenu"] = c.tabContextMenu(id)?.items.map { $0.isSeparatorItem ? "—" : $0.title } ?? [] }

        // 5p. 全屏过渡（CI 虚拟机上可能不可用：只记录）
        var fullscreen: [String: Any] = [:]
        if ProcessInfo.processInfo.environment["MIO_SMOKE_FULLSCREEN"] != "0", let w = c.window {
            let fsStrip = await strip("anim-fullscreen", title: "进入全屏：系统过渡 + 标签条左侧留白收回", chromeOnly: false, count: 10, intervalMs: 120, screen: true) {
                w.toggleFullScreen(nil)
            }
            strips["fullscreen"] = fsStrip
            var waited = 0
            while !w.styleMask.contains(.fullScreen) && waited < 30 { try? await Task.sleep(nanoseconds: 100_000_000); waited += 1 }
            fullscreen["entered"] = w.styleMask.contains(.fullScreen)
            fullscreen["tabBarInset"] = c.tabBar.leadingInset
            try? await Task.sleep(nanoseconds: 800_000_000)
            if w.styleMask.contains(.fullScreen) {
                MioMacRecorder.savePNG(MioMacRecorder.capture(screenRect: w.screen?.frame ?? w.frame), to: (dir as NSString).appendingPathComponent("mac-native-fullscreen.png"))
                w.toggleFullScreen(nil)
                waited = 0
                while w.styleMask.contains(.fullScreen) && waited < 40 { try? await Task.sleep(nanoseconds: 100_000_000); waited += 1 }
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
            fullscreen["exited"] = !w.styleMask.contains(.fullScreen)
        }
        ui["fullscreen"] = fullscreen

        meter.stop()
        ui["animationWhileRecording"] = meter.report
        ui["recording"] = await rec.stop()
        ui["strips"] = strips

        // 5p2. 帧率（不录屏、不连拍，正常速度）：开 / 关标签、侧边栏、面板、地址栏聚焦
        let perf = MioFrameMeter()
        perf.start(on: c.tabBar)
        for _ in 0..<3 {
            c.newTab(url: "about:blank", activate: true)
            try? await Task.sleep(nanoseconds: 350_000_000)
        }
        for t in c.store.tabs.reversed() where t.url == "about:blank" {
            c.closeTab(t.id)
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        c.setSidebar(visible: true, animated: true)
        try? await Task.sleep(nanoseconds: 450_000_000)
        c.setSidebar(visible: false, animated: true)
        try? await Task.sleep(nanoseconds: 450_000_000)
        c.showAppMenu()
        try? await Task.sleep(nanoseconds: 400_000_000)
        c.dismissPanel()
        try? await Task.sleep(nanoseconds: 300_000_000)
        c.focusAddressBar()
        try? await Task.sleep(nanoseconds: 300_000_000)
        if let wv = c.activeWebView { c.window?.makeFirstResponder(wv) }
        try? await Task.sleep(nanoseconds: 300_000_000)
        c.zoomIn(nil)
        try? await Task.sleep(nanoseconds: 300_000_000)
        c.zoomReset(nil)
        try? await Task.sleep(nanoseconds: 1_300_000_000)
        perf.stop()
        ui["animation"] = perf.report

        // 5q. 减少动态效果：动画时长 0，新标签立即到位
        MioMotion.forceReduce = true
        if let r = c.newTab(url: "about:blank", activate: false) {
            let wNow = c.tabBar.tabFrames[r.id]?.width ?? 0
            ui["reduceMotionImmediateWidth"] = wNow
            ui["reduceMotionOK"] = wNow > 30 && MioMotion.duration(MioMotion.normal) == 0
            c.closeTab(r.id)
        }
        MioMotion.forceReduce = ProcessInfo.processInfo.environment["MIO_REDUCE_MOTION"].map { $0 == "1" }

        // 5r. 布局结构（Firefox：标签条在导航栏上方、与红绿灯同一行）
        if let w = c.window, let cv = w.contentView {
            let tb = c.tabBar.convert(c.tabBar.bounds, to: nil)
            let nb = c.navBar.convert(c.navBar.bounds, to: nil)
            let close = w.standardWindowButton(.closeButton).map { $0.convert($0.bounds, to: nil) } ?? .zero
            ui["layout"] = ["tabBar": [tb.minX, tb.minY, tb.width, tb.height], "navBar": [nb.minX, nb.minY, nb.width, nb.height],
                            "closeButton": [close.minX, close.minY, close.width, close.height], "content": [cv.bounds.width, cv.bounds.height]]
            ui["tabsAboveNav"] = tb.minY >= nb.maxY - 0.5 && tb.maxY >= cv.bounds.height - 0.5
            ui["trafficLightsInTabRow"] = close.midY >= tb.minY && close.midY <= tb.maxY
        }

        // 6. 设置窗口（about:preferences 风格）
        if let d = delegate {
            d.openSettings(pane: .extensions)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            MioMacRecorder.savePNG(MioMacRecorder.capture(window: d.settingsWindow), to: (dir as NSString).appendingPathComponent("mac-native-settings.png"))
            shots["settingsCache"] = await screenshot(window: d.settingsWindow, webView: nil, dir: dir, name: "mac-native-settings-cache", chrome: false)
            d.openSettings(pane: .general)
            try? await Task.sleep(nanoseconds: 900_000_000)
            MioMacRecorder.savePNG(MioMacRecorder.capture(window: d.settingsWindow), to: (dir as NSString).appendingPathComponent("mac-native-settings-general.png"))
            report["settingsWindow"] = d.settingsWindow?.isVisible ?? false
            d.settingsWindow?.close()
        }
        report["ui"] = ui
        report["screenshots"] = shots
        report["settingsPanes"] = MioMacPrefsPane.allCases.map { $0.title }
        report["modules"] = MioMacWebKit.modules.modules.map { ["id": $0.id, "section": $0.section.rawValue, "enabled": $0.isEnabled(MioMacWebKit.modules.prefs)] as [String: Any] }
        report["moduleScripts"] = MioMacWebKit.modules.scripts().map { $0.moduleID }
        report["tabs"] = controller.store.tabs.map { ["id": $0.id, "url": $0.url, "title": $0.title, "container": $0.containerID] as [String: Any] }
        report["tabStripItems"] = controller.tabBar.items.count
        let keys = MioMacMenu.keyEquivalents(NSApp.mainMenu)
        report["menuKeyEquivalents"] = keys
        let requiredKeys = ["⌘,", "⌘t", "⌘n", "⌘w", "⌘l", "⌘+", "⌘-", "⌘0", "⌘=", "⇧⌘t", "⌘r", "⌘[", "⌘]", "⌘f", "⌘g", "⌘d", "⌃⇥", "⌃⇧⇥", "⌥⌘i", "⌃⌘s", "⌥⌘→"]
        let missingKeys = requiredKeys.filter { !keys.contains($0) }
        report["missingKeys"] = missingKeys
        let keysOK = missingKeys.isEmpty
        let navIDs = ["mio.nav.back", "mio.nav.forward", "mio.nav.reload", "mio.nav.extensions", "mio.nav.menu", "mio.nav.sidebar"]
        let foundIDs = Set(allIdentifiers(c.navBar))
        report["navBarIdentifiers"] = Array(foundIDs).sorted()
        let chromeOK = navIDs.allSatisfy { foundIDs.contains($0) } && foundIDs.contains("mio.urlbar") && controller.store.tabs.count >= 3
            && ((ui["tabsAboveNav"] as? Bool) ?? false)
        report["keysOK"] = keysOK
        report["chromeOK"] = chromeOK
        report["mseOK"] = mseOK
        let zoomOK = (report["zoomOK"] as? Bool) ?? false
        let modulesOK = MioMacWebKit.modules.scripts().count >= 2 && ((report["youtubeModuleMenu"] as? [String]) ?? []).contains("youtubeFocus.settings")
        report["modulesOK"] = modulesOK
        // 门槛：原有（MSE / 缩放 / 容器 / 快捷键 / 模块）+ Firefox 布局 + 桥来源校验；动画 / 截图 / 首页（依赖外网）只记录
        let pass = mseOK && zoomOK && containerOK && keysOK && chromeOK && modulesOK && bridgeOK
        report["pass"] = pass
        report["seconds"] = Int(Date().timeIntervalSince(started))
        write()
        print("MIO_MAC_NATIVE_SMOKE " + (pass ? "PASS" : "FAIL"))
        exit(pass ? 0 : 1)
    }

    // MARK: - UI 冒烟工具

    private var dir = ""

    /// 窗口（含子窗口面板）截图；屏幕截图不可用时退回 cacheDisplay
    private func shot(_ name: String, _ shots: inout [String: Any]) {
        let path = (dir as NSString).appendingPathComponent("\(name).png")
        if MioMacRecorder.savePNG(MioMacRecorder.capture(window: controller.window), to: path) {
            shots[name] = path
        } else if let w = controller.window, let fv = w.contentView?.superview, let rep = fv.bitmapImageRepForCachingDisplay(in: fv.bounds) {
            fv.cacheDisplay(in: fv.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]), (try? png.write(to: URL(fileURLWithPath: path))) != nil { shots[name] = path + " (cacheDisplay)" }
        }
    }

    /// 只截顶部（标签条 + 导航栏）
    private func shotChrome(_ name: String, _ shots: inout [String: Any]) {
        guard let w = controller.window else { return }
        let path = (dir as NSString).appendingPathComponent("\(name).png")
        if MioMacRecorder.savePNG(MioMacRecorder.capture(screenRect: chromeRect(w)), to: path) { shots[name] = path }
    }

    private func chromeRect(_ w: NSWindow) -> NSRect {
        let h = MioMacTabBar.height + MioMacNavBar.height + 2
        return NSRect(x: w.frame.minX, y: w.frame.maxY - h, width: w.frame.width, height: h)
    }

    enum Region { case chrome, window, top(CGFloat), screen }

    /// 动作 + 连拍 → 帧条 PNG；连拍期间动画放慢 4 倍（MioMotion.slowFactor），帧条里能看到中间帧。返回 {path, frames, changed}
    private func strip(_ name: String, title: String, chromeOnly: Bool, count: Int = 8, intervalMs: UInt64 = 30, screen: Bool = false,
                       region: Region? = nil, _ action: @escaping () -> Void) async -> [String: Any] {
        guard let w = controller.window else { return ["error": "no window"] }
        let reg = region ?? (screen ? .screen : (chromeOnly ? .chrome : .top(320)))
        let rect: () -> NSRect = { [weak w] in
            guard let w else { return .zero }
            switch reg {
            case .screen: return w.screen?.frame ?? w.frame
            case .chrome: return self.chromeRect(w)
            case .window: return w.frame
            case .top(let h): return NSRect(x: w.frame.minX, y: w.frame.maxY - min(h, w.frame.height), width: w.frame.width, height: min(h, w.frame.height))
            }
        }
        let slow = screen ? 1.0 : 4.0
        MioMotion.slowFactor = slow
        let task = Task { @MainActor in await MioMacRecorder.burst(count: count, intervalMs: intervalMs, rect: rect) }
        try? await Task.sleep(nanoseconds: 5_000_000)
        action()
        let shots = await task.value
        try? await Task.sleep(nanoseconds: UInt64(0.3 * slow * 1_000_000_000)) // 等放慢的动画走完
        MioMotion.slowFactor = 1
        let frames = shots.map(\.image)
        let path = (dir as NSString).appendingPathComponent("\(name).png")
        let label = slow > 1 ? title + "（连拍时动画放慢 \(Int(slow))×）" : title
        let saved = MioMacRecorder.saveStrip(screen ? frames.map { scaled($0, 0.5) } : frames, times: shots.map(\.ms), title: label, to: path)
        var changed = 0
        for i in 1..<max(1, frames.count) where MioMacRecorder.differs(frames[i - 1], frames[i]) { changed += 1 }
        return ["path": saved ? path as Any : NSNull() as Any, "frames": frames.count, "framesThatChanged": changed, "timesMs": shots.map(\.ms), "slowFactor": slow]
    }

    private func scaled(_ img: CGImage, _ f: CGFloat) -> CGImage {
        let w = Int(CGFloat(img.width) * f), h = Int(CGFloat(img.height) * f)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return img }
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? img
    }

    private func callAsync(_ wv: WKWebView, _ js: String) async -> String {
        await withCheckedContinuation { cont in
            wv.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let v): cont.resume(returning: (v as? String) ?? "\(v)")
                case .failure(let e): cont.resume(returning: "error:\(e.localizedDescription)")
                }
            }
        }
    }

    private func allIdentifiers(_ v: NSView) -> [String] {
        var out: [String] = []
        let id = v.accessibilityIdentifier()
        if !id.isEmpty { out.append(id) }
        for s in v.subviews { out += allIdentifiers(s) }
        return out
    }

    private func rowTitles(_ v: NSView?) -> [String] {
        guard let v else { return [] }
        var out: [String] = []
        if let r = v as? MioMacMenuRow { out.append(r.title.stringValue) }
        for s in v.subviews where !s.isHidden { out += rowTitles(s) }
        return out
    }

    private func findRow(_ title: String, in v: NSView?) -> MioMacMenuRow? {
        guard let v else { return nil }
        if let r = v as? MioMacMenuRow, r.title.stringValue == title { return r }
        for s in v.subviews { if let r = findRow(title, in: s) { return r } }
        return nil
    }

    private func orNull(_ v: Any?) -> Any { v ?? NSNull() }

    private func waitLoad(_ id: Int, timeout: TimeInterval) async {
        let end = Date().addingTimeInterval(timeout)
        while !controller.finished.contains(id) && Date() < end {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private func eval(_ wv: WKWebView, _ js: String) async -> [String: Any]? {
        let text: String? = await withCheckedContinuation { cont in
            wv.evaluateJavaScript(js) { result, error in
                cont.resume(returning: (result as? String) ?? error.map { "{\"evalError\":\(Self.jsonString("\($0)"))}" })
            }
        }
        guard let t = text, let data = t.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    nonisolated static func jsonString(_ s: String) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: [s]), let a = String(data: d, encoding: .utf8) else { return "\"\"" }
        return String(a.dropFirst().dropLast())
    }

    /// 窗口截图：标题栏 / 工具栏 / 标签条来自窗口框架视图的 cacheDisplay，网页区域来自 WKWebView.takeSnapshot（网页在独立进程里渲染，cacheDisplay 拍不到）
    private func screenshot(window: NSWindow?, webView: WKWebView?, dir: String, name: String, chrome: Bool) async -> [String: Any] {
        guard let win = window, let frameView = win.contentView?.superview else { return ["error": "no window"] }
        let bounds = frameView.bounds
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { return ["error": "no bitmap"] }
        frameView.cacheDisplay(in: bounds, to: rep)
        var snap: NSImage?
        var webRect = NSRect.zero
        if let wv = webView {
            snap = await withCheckedContinuation { cont in
                wv.takeSnapshot(with: nil) { image, _ in cont.resume(returning: image) }
            }
            webRect = wv.convert(wv.bounds, to: frameView)
            if frameView.isFlipped { webRect.origin.y = bounds.height - webRect.maxY }
        }
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: out) else { return ["error": "no context"] }
        out.size = bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        rep.draw(in: bounds)
        snap?.draw(in: webRect)
        NSGraphicsContext.restoreGraphicsState()

        var result: [String: Any] = ["windowPoints": [bounds.width, bounds.height], "pixels": [out.pixelsWide, out.pixelsHigh], "webSnapshot": snap != nil]
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let full = (dir as NSString).appendingPathComponent("\(name).png")
        if let png = out.representation(using: .png, properties: [:]), (try? png.write(to: URL(fileURLWithPath: full))) != nil { result["window"] = full }

        guard chrome else { return result }
        // 只要顶部：标题栏 + 工具栏 + 标签条
        let chromeHeight = bounds.height - win.contentLayoutRect.height + MioMacTabBar.height + MioMacNavBar.height + 2
        let scale = CGFloat(out.pixelsHigh) / bounds.height
        let cropPx = CGRect(x: 0, y: 0, width: CGFloat(out.pixelsWide), height: min(CGFloat(out.pixelsHigh), (chromeHeight * scale).rounded()))
        if let cg = out.cgImage, let cropped = cg.cropping(to: cropPx) { // CGImage 原点在左上
            let crep = NSBitmapImageRep(cgImage: cropped)
            let top = (dir as NSString).appendingPathComponent("mac-native-toolbar.png")
            if let png = crep.representation(using: .png, properties: [:]), (try? png.write(to: URL(fileURLWithPath: top))) != nil { result["toolbar"] = top }
        }
        result["chromeHeightPoints"] = chromeHeight
        return result
    }

    /// 整屏截图（/usr/sbin/screencapture；没有屏幕录制权限时可能只有桌面，冒烟不以它为准）
    private func screencapture(dir: String, name: String) -> String? {
        let path = (dir as NSString).appendingPathComponent("\(name).png")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", path]
        do { try p.run(); p.waitUntilExit() } catch { return nil }
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    private func write() {
        let obj = report
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else {
            try? "{\"error\":\"report not serializable\"}".write(toFile: outPath, atomically: true, encoding: .utf8)
            return
        }
        try? data.write(to: URL(fileURLWithPath: outPath))
    }
}
