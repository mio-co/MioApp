// MioMacSmoke.swift — CI 冒烟（MIO_SMOKE_OUT=<json> 时运行，写完结果退出；0 = 通过）：
//   1. example.com：typeof MediaSource / ManagedMediaSource（门槛：MediaSource 必须存在——Catalyst 版这里是 undefined）
//   2. ⌘+ / ⌘0：pageZoom 跟随 Safari 档位并复位
//   3. 新标签打开 YouTube 视频页（桌面 Safari UA）：记录 MSE isTypeSupported、ytInitialPlayerResponse 的可用格式
//      （playabilityStatus 不是 OK —— 例如 LOGIN_REQUIRED / 机房 IP 被要求登录 —— 只记录，不算失败）
//   4. 容器：新容器标签用 WKWebsiteDataStore(forIdentifier: 容器 UUID) 加载页面
//   5. 截图：窗口（工具栏 + 标签条 + 网页）→ MIO_SMOKE_SHOTS 目录（默认与 json 同目录）

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

        // 5. 截图 + 界面结构
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let shotsDir = ProcessInfo.processInfo.environment["MIO_SMOKE_SHOTS"] ?? (outPath as NSString).deletingLastPathComponent
        var shots: [String: Any] = [:]
        shots["main"] = await screenshot(window: controller.window, webView: controller.activeWebView, dir: shotsDir, name: "mac-native-window", chrome: true)
        // 侧边栏展开（Safari macOS 布局）
        controller.setSidebar(visible: true)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        shots["sidebar"] = await screenshot(window: controller.window, webView: controller.activeWebView, dir: shotsDir, name: "mac-native-sidebar", chrome: false)
        report["sidebarTabs"] = controller.sidebarModel.tabs.count
        shots["screenSidebar"] = screencapture(dir: shotsDir, name: "screen-sidebar")
        // 设置窗口（Safari 分区 + Mio 分区），选中「模块」
        if let d = delegate {
            d.openSettings(section: .modules)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            shots["settings"] = await screenshot(window: d.settingsWindow, webView: nil, dir: shotsDir, name: "mac-native-settings", chrome: false)
            shots["screenSettings"] = screencapture(dir: shotsDir, name: "screen-settings")
            report["settingsWindow"] = d.settingsWindow?.isVisible ?? false
        }
        report["screenshots"] = shots
        report["settingsSections"] = MioSettingsSection.allCases.map { $0.title }
        report["modules"] = MioMacWebKit.modules.modules.map { ["id": $0.id, "section": $0.section.rawValue, "enabled": $0.isEnabled(MioMacWebKit.modules.prefs)] as [String: Any] }
        report["moduleScripts"] = MioMacWebKit.modules.scripts().map { $0.moduleID }
        let toolbarIDs = controller.window?.toolbar?.items.map { $0.itemIdentifier.rawValue } ?? []
        report["toolbarItems"] = toolbarIDs
        report["tabs"] = controller.store.tabs.map { ["id": $0.id, "url": $0.url, "title": $0.title, "container": $0.containerID] as [String: Any] }
        report["tabStripItems"] = controller.tabStrip.items.count
        let keys = MioMacMenu.keyEquivalents(NSApp.mainMenu)
        report["menuKeyEquivalents"] = keys
        let requiredKeys = ["⌘,", "⌘t", "⌘w", "⌘l", "⌘+", "⌘-", "⌘0", "⌘=", "⇧⌘t", "⌘r", "⌘[", "⌘]"]
        let keysOK = requiredKeys.allSatisfy { keys.contains($0) }
        let chromeOK = ["mio.back", "mio.forward", "mio.address", "mio.newTab", "mio.menu"].allSatisfy { toolbarIDs.contains($0) } && controller.store.tabs.count >= 3
        report["keysOK"] = keysOK
        report["chromeOK"] = chromeOK
        report["mseOK"] = mseOK
        let zoomOK = (report["zoomOK"] as? Bool) ?? false
        let modulesOK = MioMacWebKit.modules.scripts().count >= 2 && ((report["youtubeModuleMenu"] as? [String]) ?? []).contains("youtubeFocus.settings")
        report["modulesOK"] = modulesOK
        let pass = mseOK && zoomOK && containerOK && keysOK && chromeOK && modulesOK
        report["pass"] = pass
        report["seconds"] = Int(Date().timeIntervalSince(started))
        write()
        print("MIO_MAC_NATIVE_SMOKE " + (pass ? "PASS" : "FAIL"))
        exit(pass ? 0 : 1)
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
        let chromeHeight = bounds.height - win.contentLayoutRect.height + MioMacTabStrip.height + 4
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
