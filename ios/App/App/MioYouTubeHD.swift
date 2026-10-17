// MioYouTubeHD.swift — Mac 内置浏览器 YouTube 高清诊断（v0.3.4）。
// Mac 冒烟测试里依次检查：
//   1. bare：完全默认的 WKWebViewConfiguration（不注入脚本），example.com 上 MediaSource / ManagedMediaSource 是否存在
//   2. tuned：同内置浏览器的 UA / 内容模式 / MSE 偏好，但不注入任何脚本
//   3. tab：内置浏览器真实标签（全部脚本）打开 YouTube watch 页：UA、MSE、isTypeSupported、MediaCapabilities、可用画质
// 并列出 WKPreferences 里与媒体相关的 feature 开关状态，用来区分「WebKit 本身没开 MSE」和「注入脚本破坏了检测」。

import UIKit
import WebKit

enum MioYouTubeHD {
    /// 用于检测的 watch 页（Big Buck Bunny，官方上传，有 4K）
    static let watchURL = "https://www.youtube.com/watch?v=aqz-KE-bpKQ"

    /// 媒体能力探测（callAsyncJavaScript，返回 JSON 字符串）
    static let probeJS = #"""
    const r = { href: location.href, ua: navigator.userAgent };
    try { r.mediaSource = typeof window.MediaSource; } catch (e) { r.mediaSource = 'err ' + e; }
    try { r.managedMediaSource = typeof window.ManagedMediaSource; } catch (e) {}
    try { r.webKitMediaSource = typeof window.WebKitMediaSource; } catch (e) {}
    try { r.msInWindow = 'MediaSource' in window; } catch (e) {}
    try { const d = Object.getOwnPropertyDescriptor(window, 'MediaSource'); r.msDescriptor = d ? Object.keys(d).join(',') : 'none'; } catch (e) {}
    try { if (window.MediaSource) r.msNative = /\[native code\]/.test(Function.prototype.toString.call(window.MediaSource)); } catch (e) {}
    const types = { vp9: 'video/webm; codecs="vp9"', vp09: 'video/webm; codecs="vp09.00.40.08"', avc1: 'video/mp4; codecs="avc1.4d401f"', avc1080: 'video/mp4; codecs="avc1.640028"', av1: 'video/mp4; codecs="av01.0.08M.08"', opus: 'audio/webm; codecs="opus"', aac: 'audio/mp4; codecs="mp4a.40.2"' };
    const MS = window.MediaSource || window.ManagedMediaSource;
    if (MS && MS.isTypeSupported) { r.isTypeSupported = {}; for (const k in types) { try { r.isTypeSupported[k] = MS.isTypeSupported(types[k]); } catch (e) { r.isTypeSupported[k] = String(e); } } }
    try { const v = document.createElement('video'); r.canPlayType = { avc1: v.canPlayType(types.avc1), vp9: v.canPlayType(types.vp9), hls: v.canPlayType('application/vnd.apple.mpegurl') }; } catch (e) {}
    try {
      if (navigator.mediaCapabilities && navigator.mediaCapabilities.decodingInfo) {
        const q = async (type, ct) => { try { const i = await navigator.mediaCapabilities.decodingInfo({ type, video: { contentType: ct, width: 1920, height: 1080, bitrate: 4000000, framerate: 30 } }); return i.supported + '/' + i.smooth + '/' + i.powerEfficient; } catch (e) { return 'err ' + (e && e.name); } };
        r.mediaCapabilities = { msVp9: await q('media-source', types.vp9), msAvc1: await q('media-source', types.avc1080), fileAvc1: await q('file', types.avc1080) };
      } else r.mediaCapabilities = 'missing';
    } catch (e) { r.mediaCapabilities = 'err ' + e; }
    try {
      const p = document.getElementById('movie_player');
      let pr = window.ytInitialPlayerResponse;
      if (p && typeof p.getPlayerResponse === 'function') pr = p.getPlayerResponse() || pr;
      const sd = pr && pr.streamingData;
      if (sd) {
        const af = sd.adaptiveFormats || [];
        r.adaptiveFormats = af.length;
        r.maxHeight = af.reduce((m, f) => Math.max(m, f.height || 0), 0);
        r.progressive = (sd.formats || []).map(f => f.qualityLabel || f.itag);
      } else if (pr) { r.streamingData = 'missing'; r.playability = pr.playabilityStatus && pr.playabilityStatus.status; }
      if (p && typeof p.getAvailableQualityLevels === 'function') r.qualityLevels = p.getAvailableQualityLevels();
      if (p && typeof p.getPlaybackQuality === 'function') r.playbackQuality = p.getPlaybackQuality();
      const v = document.querySelector('video');
      if (v) { r.videoSrc = String(v.currentSrc || v.src || '').slice(0, 5); r.videoHeight = v.videoHeight; }
    } catch (e) { r.ytError = String(e); }
    return JSON.stringify(r);
    """#

    /// WKPreferences 私有 feature 列表里与媒体有关的开关（诊断用；私有 API 只读，失败返回错误串）
    static func mediaFeatures(_ prefs: WKPreferences) -> [String: Any] {
        var out: [String: Any] = [:]
        let cls: AnyObject = WKPreferences.self
        let sel = NSSelectorFromString("_features")
        guard cls.responds(to: sel), let list = cls.perform(sel)?.takeUnretainedValue() as? [NSObject] else { return ["error": "no _features"] }
        let isOn = NSSelectorFromString("_isEnabledForFeature:")
        for f in list {
            guard let key = f.value(forKey: "key") as? String else { continue }
            let k = key.lowercased()
            guard k.contains("mediasource") || k.contains("managedmedia") || k.contains("vp9") || k.contains("webm") || k.contains("mediacapabil") || k.contains("av1") || k.contains("hevc") || k.contains("remoteplayback") || k.contains("alternatewebmplayer") else { continue }
            if prefs.responds(to: isOn), let m = class_getInstanceMethod(type(of: prefs), isOn) {
                typealias Fn = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
                let fn = unsafeBitCast(method_getImplementation(m), to: Fn.self)
                out[key] = fn(prefs, isOn, f)
            } else {
                out[key] = "?"
            }
        }
        return out
    }
}

/// Mac 冒烟：bare / tuned / tab 三种 WebView 的媒体能力 + YouTube 画质
enum MioYouTubeHDSmoke {
    private static var holders: [WKWebView] = []

    static func run(completion: @escaping ([String: Any], Bool) -> Void) {
        var r: [String: Any] = [:]
        probeStandalone(tuned: false) { bare in
            r["bare"] = bare
            probeStandalone(tuned: true) { tuned in
                r["tuned"] = tuned
                probeTab { tab, ok in
                    r["tab"] = tab
                    r["ok"] = ok
                    NSLog("⚡️ Mio smoke: youtube HD %@ %@", ok ? "OK" : "INFO", "\(r)")
                    completion(r, ok)
                }
            }
        }
    }

    private static func probeStandalone(tuned: Bool, completion: @escaping (Any) -> Void) {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        if tuned {
            config.applicationNameForUserAgent = MioWebCompat.desktopApplicationName(safariVersion: MioWebKitCompat.safariVersion)
            config.defaultWebpagePreferences.preferredContentMode = .desktop
            MioWebKitCompat.enableMediaSource(config.preferences)
        }
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        if tuned { wv.customUserAgent = MioWebKitCompat.desktopUserAgent }
        wv.isHidden = true
        if let win = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.windows.first }).first { win.addSubview(wv) }
        holders.append(wv)
        let features = MioYouTubeHD.mediaFeatures(config.preferences)
        wv.load(URLRequest(url: URL(string: tuned ? MioYouTubeHD.watchURL : "https://example.com/")!))
        DispatchQueue.main.asyncAfter(deadline: .now() + (tuned ? 8 : 4)) {
            wv.callAsyncJavaScript(MioYouTubeHD.probeJS, arguments: [:], in: nil, in: .page) { res in
                var out: [String: Any] = ["features": features]
                switch res {
                case .success(let v): out["probe"] = (v as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } ?? "\(String(describing: v))"
                case .failure(let e): out["error"] = "\(e)"
                }
                wv.removeFromSuperview()
                holders.removeAll { $0 === wv }
                completion(out)
            }
        }
    }

    private static func probeTab(completion: @escaping ([String: Any], Bool) -> Void) {
        guard let tabs = MioTabsViewController.shared, tabs.presentingViewController != nil else {
            completion(["error": "browser not presented"], false); return
        }
        let t = tabs.openTab(MioYouTubeHD.watchURL, activate: true)
        var out: [String: Any] = [:]
        if let wv = tabs.activeController?.webView { out["features"] = MioYouTubeHD.mediaFeatures(wv.configuration.preferences) }
        func attempt(_ n: Int) {
            guard let wv = tabs.activeController?.webView else { completion(["error": "no webview"], false); return }
            wv.callAsyncJavaScript(MioYouTubeHD.probeJS, arguments: [:], in: nil, in: .page) { res in
                var probe: [String: Any] = [:]
                switch res {
                case .success(let v): probe = (v as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
                case .failure(let e): out["error"] = "\(e)"
                }
                let levels = probe["qualityLevels"] as? [String] ?? []
                let maxH = probe["maxHeight"] as? Int ?? 0
                let hd = maxH >= 720 || levels.contains(where: { $0.hasPrefix("hd") })
                if !hd && n < 3 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { attempt(n + 1) }
                    return
                }
                out["probe"] = probe
                out["hd"] = hd
                if let t = t { tabs.closeTab(t.id) }
                completion(out, hd)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { attempt(0) }
    }
}
