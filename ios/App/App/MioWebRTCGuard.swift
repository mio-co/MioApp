// MioWebRTCGuard.swift — WebRTC 控制（自研，防止网页通过 WebRTC 泄露本机 / 局域网 IP、静默调用摄像头麦克风）
//
// 页面世界、所有 frame、document-start 注入：按设置删掉 RTCPeerConnection / webkitRTCPeerConnection、RTCDataChannel、
// RTCSessionDescription、RTCIceCandidate 等 RTC* 接口和 MediaStreamTrack，navigator.mediaDevices.getUserMedia /
// getDisplayMedia 直接拒绝（NotAllowedError），enumerateDevices 返回空列表。动态创建的 iframe / window.open 出来的窗口
// 在拿到 contentWindow 或插入文档时同样处理（防止从干净的 about:blank frame 里取回原始构造函数）。
// 全局开关默认开；按站点放行列表（含子域名；放行的站点无论在顶层还是作为 iframe 都不处理）。
//
// 注入的 JS 在 MIO_JS_BEGIN webrtcGuard 段里，tools/MioAppTests/js/webrtc-guard.test.mjs 抽出来用 jsdom 跑。
//
// 纯逻辑部分只依赖 Foundation（swift test 在 Linux 上跑），WKUserScript 和设置页在下面的 #if canImport(UIKit) 段。

import Foundation

enum MioWebRTCSettings {
    static let enabledKey = "mio.webrtc.enabled"
    static let allowlistKey = "mio.webrtc.allowlist"
    /// 与 MioBrowser.swift 的 .mioBrowserSettingsDidChange 同名：内置浏览器收到后重建用户脚本（下一次加载页面生效）
    static let changedNotification = Notification.Name("mio.browser.settingsDidChange")

    /// 单测可替换
    static var defaults: UserDefaults = .standard

    /// 常见网页通话站点（设置页一键放行）
    static let presets: [(name: String, host: String)] = [
        ("Google Meet", "meet.google.com"),
        ("Zoom", "zoom.us"),
        ("Microsoft Teams", "teams.microsoft.com"),
        ("Discord", "discord.com"),
        ("Jitsi Meet", "meet.jit.si"),
        ("Whereby", "whereby.com"),
        ("Slack", "app.slack.com"),
    ]

    /// 总开关，默认开
    static var enabled: Bool {
        get { defaults.object(forKey: enabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: enabledKey); changed() }
    }

    static var allowlist: [String] {
        get { (defaults.stringArray(forKey: allowlistKey) ?? []).map(normalize).filter { !$0.isEmpty } }
        set {
            let clean = Array(Set(newValue.map(normalize).filter { !$0.isEmpty })).sorted()
            defaults.set(clean, forKey: allowlistKey)
            changed()
        }
    }

    /// 用户输入（域名或网址）→ 小写主机名，去掉 www. 和末尾的点
    static func normalize(_ input: String) -> String {
        var h = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let r = h.range(of: "://") { h = String(h[r.upperBound...]) }
        if let i = h.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { h = String(h[h.startIndex..<i]) }
        if let at = h.lastIndex(of: "@") { h = String(h[h.index(after: at)...]) }
        if let colon = h.lastIndex(of: ":"), !h.contains("]") { h = String(h[h.startIndex..<colon]) }
        while h.hasSuffix(".") { h.removeLast() }
        if h.hasPrefix("*.") { h = String(h.dropFirst(2)) }
        if h.hasPrefix("www.") { h = String(h.dropFirst(4)) }
        return h
    }

    /// 放行列表里的条目（含子域名）
    static func allowlistEntry(for host: String?, in list: [String]? = nil) -> String? {
        guard let host = host else { return nil }
        var h = host.lowercased()
        while h.hasSuffix(".") { h.removeLast() }
        guard !h.isEmpty else { return nil }
        for e in list ?? allowlist where h == e || h.hasSuffix("." + e) { return e }
        return nil
    }

    static func isAllowed(_ host: String?) -> Bool { allowlistEntry(for: host) != nil }

    static func setAllowed(_ host: String, _ allow: Bool) {
        if allow {
            let h = normalize(host)
            guard !h.isEmpty else { return }
            allowlist = allowlist + [h]
        } else {
            // 去掉所有覆盖该主机的条目
            allowlist = allowlist.filter { e in !(host.lowercased() == e || host.lowercased().hasSuffix("." + e) || normalize(host) == e) }
        }
    }

    /// 要注入的代码；总开关关掉时 nil（完全不注入）
    static func script() -> String? {
        guard enabled else { return nil }
        return MioWebRTCGuard.script(allow: allowlist)
    }

    private static func changed() {
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }
}

enum MioWebRTCGuard {
    static let configPlaceholder = "__MIO_WEBRTC_CONFIG__"

    static func script(allow: [String]) -> String {
        let cfg: [String: Any] = ["allow": allow]
        let json = (try? JSONSerialization.data(withJSONObject: cfg, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? #"{"allow":[]}"#
        return template.replacingOccurrences(of: configPlaceholder, with: json)
    }

    /// 冒烟测试：当前页面 WebRTC 是否可用
    static let probeScript = "JSON.stringify({host: location.hostname, pc: typeof RTCPeerConnection, wpc: typeof webkitRTCPeerConnection, dc: typeof RTCDataChannel, track: typeof MediaStreamTrack, gum: !!(navigator.mediaDevices && navigator.mediaDevices.getUserMedia), guard: (window.__mioRTCGuard === undefined ? null : window.__mioRTCGuard)})"

    // MIO_JS_BEGIN webrtcGuard
    static let template = #"""
    (function () {
      'use strict';
      var CFG = __MIO_WEBRTC_CONFIG__;
      var ALLOW = (CFG && CFG.allow) || [];
      var NAMES = ['RTCPeerConnection', 'webkitRTCPeerConnection', 'mozRTCPeerConnection', 'RTCDataChannel',
        'RTCSessionDescription', 'mozRTCSessionDescription', 'RTCIceCandidate', 'mozRTCIceCandidate', 'MediaStreamTrack',
        'RTCRtpSender', 'RTCRtpReceiver', 'RTCRtpTransceiver', 'RTCDtlsTransport', 'RTCIceTransport', 'RTCSctpTransport',
        'RTCPeerConnectionIceEvent', 'RTCPeerConnectionIceErrorEvent', 'RTCDataChannelEvent', 'RTCTrackEvent',
        'RTCCertificate', 'RTCDTMFSender', 'RTCDTMFToneChangeEvent', 'RTCStatsReport', 'RTCError', 'RTCErrorEvent',
        'RTCRtpScriptTransform', 'RTCEncodedAudioFrame', 'RTCEncodedVideoFrame', 'MediaStreamTrackEvent'];
      var RTC_RE = /^(webkit|moz)?RTC[A-Z]/;

      function allowedHost(h) {
        h = String(h || '').toLowerCase().replace(/\.+$/, '');
        if (!h) return false;
        for (var i = 0; i < ALLOW.length; i++) {
          var a = ALLOW[i];
          if (h === a || h.slice(-(a.length + 1)) === '.' + a) return true;
        }
        return false;
      }
      function originHost(o) {
        var m = /^[a-z][a-z0-9+.-]*:\/\/(?:[^@\/]*@)?(\[[^\]]*\]|[^:\/]*)/i.exec(String(o || ''));
        return m ? m[1] : '';
      }
      // 放行：frame 自己的主机，或顶层页面的主机在放行列表里
      function siteAllowed(win) {
        if (!ALLOW.length) return false;
        try { if (allowedHost(win.location.hostname)) return true; } catch (e) {}
        try {
          var ao = win.location.ancestorOrigins;
          if (ao && ao.length) {
            if (allowedHost(originHost(ao[ao.length - 1]))) return true;
            for (var i = 0; i < ao.length; i++) if (allowedHost(originHost(ao[i]))) return true;
          }
        } catch (e) {}
        try { if (win.top !== win && allowedHost(win.top.location.hostname)) return true; } catch (e) {}
        try { if (win.parent !== win && win.location.hostname === '' && allowedHost(originHost(win.document.referrer))) return true; } catch (e) {}
        return false;
      }

      function hide(obj, name) {
        if (!obj) return;
        try { delete obj[name]; } catch (e) {}
        try {
          if (name in obj) Object.defineProperty(obj, name, { value: undefined, writable: true, configurable: true, enumerable: false });
        } catch (e) {}
      }

      function wrapMethod(proto, name, after) {
        if (!proto) return;
        var desc = Object.getOwnPropertyDescriptor(proto, name);
        if (!desc || typeof desc.value !== 'function') return;
        var orig = desc.value;
        var wrapped = function () {
          var r = orig.apply(this, arguments);
          try { after(this, arguments, r); } catch (e) {}
          return r;
        };
        try { Object.defineProperty(wrapped, 'name', { value: name }); } catch (e) {}
        try { Object.defineProperty(proto, name, { value: wrapped, writable: desc.writable, configurable: desc.configurable, enumerable: desc.enumerable }); } catch (e) {}
      }

      function wrapGetter(proto, name, after) {
        if (!proto) return;
        var desc = Object.getOwnPropertyDescriptor(proto, name);
        if (!desc || typeof desc.get !== 'function') return;
        var get = desc.get;
        try {
          Object.defineProperty(proto, name, {
            get: function () { var r = get.call(this); try { after(this, r); } catch (e) {} return r; },
            set: desc.set, configurable: desc.configurable, enumerable: desc.enumerable
          });
        } catch (e) {}
      }

      function wrapSetter(proto, name, after) {
        if (!proto) return;
        var desc = Object.getOwnPropertyDescriptor(proto, name);
        if (!desc || typeof desc.set !== 'function') return;
        var set = desc.set;
        try {
          Object.defineProperty(proto, name, {
            get: desc.get,
            set: function (v) { set.call(this, v); try { after(this); } catch (e) {} },
            configurable: desc.configurable, enumerable: desc.enumerable
          });
        } catch (e) {}
      }

      function guardFramesIn(node) {
        if (!node || node.nodeType !== 1 && node.nodeType !== 11) return;
        var tag = node.nodeType === 1 ? String(node.tagName || '').toUpperCase() : '';
        if (tag === 'IFRAME' || tag === 'FRAME' || tag === 'OBJECT' || tag === 'EMBED') {
          try { guard(node.contentWindow); } catch (e) {}
        }
        if (node.querySelectorAll && (node.firstElementChild || node.nodeType === 11)) {
          var list;
          try { list = node.querySelectorAll('iframe,frame,object,embed'); } catch (e) { list = []; }
          for (var i = 0; i < list.length; i++) { try { guard(list[i].contentWindow); } catch (e) {} }
        }
      }

      function guard(win) {
        if (!win) return;
        try {
          if (win.__mioRTCGuard !== undefined) return;
          Object.defineProperty(win, '__mioRTCGuard', { value: false, writable: true, configurable: false, enumerable: false });
        } catch (e) { return; }
        if (siteAllowed(win)) return;
        try { win.__mioRTCGuard = true; } catch (e) {}

        var names = NAMES.slice();
        try {
          Object.getOwnPropertyNames(win).forEach(function (n) { if (RTC_RE.test(n) && names.indexOf(n) < 0) names.push(n); });
        } catch (e) {}
        names.forEach(function (n) { hide(win, n); });

        // 摄像头 / 麦克风 / 屏幕共享：拒绝；设备列表：空
        var P = win.Promise || Promise;
        var DE = win.DOMException || (typeof DOMException !== 'undefined' ? DOMException : Error);
        var deny = function () { return P.reject(new DE('WebRTC 已被 Mio 屏蔽（可在浏览器设置里放行此网站）', 'NotAllowedError')); };
        var none = function () { return P.resolve([]); };
        var nav = win.navigator;
        var MD = win.MediaDevices && win.MediaDevices.prototype;
        [MD, nav && nav.mediaDevices].forEach(function (o) {
          if (!o) return;
          try { Object.defineProperty(o, 'getUserMedia', { value: deny, writable: true, configurable: true }); } catch (e) {}
          try { Object.defineProperty(o, 'getDisplayMedia', { value: deny, writable: true, configurable: true }); } catch (e) {}
          try { Object.defineProperty(o, 'enumerateDevices', { value: none, writable: true, configurable: true }); } catch (e) {}
        });
        var NP = win.Navigator && win.Navigator.prototype;
        ['getUserMedia', 'webkitGetUserMedia', 'mozGetUserMedia'].forEach(function (n) { hide(NP, n); hide(nav, n); });

        // 子窗口：拿到 contentWindow / contentDocument、插入文档、window.open 时同样处理
        var IF = win.HTMLIFrameElement && win.HTMLIFrameElement.prototype;
        var FR = win.HTMLFrameElement && win.HTMLFrameElement.prototype;
        var OB = win.HTMLObjectElement && win.HTMLObjectElement.prototype;
        [IF, FR, OB].forEach(function (p) {
          wrapGetter(p, 'contentWindow', function (el, cw) { guard(cw); });
          wrapGetter(p, 'contentDocument', function (el, doc) { if (doc) guard(doc.defaultView); });
        });
        var NodeP = win.Node && win.Node.prototype;
        var ElP = win.Element && win.Element.prototype;
        var after = function (self, args) {
          for (var i = 0; i < args.length; i++) guardFramesIn(args[i]);
        };
        ['appendChild', 'insertBefore', 'replaceChild'].forEach(function (n) { wrapMethod(NodeP, n, after); });
        ['append', 'prepend', 'after', 'before', 'replaceWith', 'insertAdjacentElement', 'replaceChildren'].forEach(function (n) { wrapMethod(ElP, n, after); });
        var DF = win.DocumentFragment && win.DocumentFragment.prototype;
        ['append', 'prepend', 'replaceChildren'].forEach(function (n) { wrapMethod(DF, n, after); });
        wrapMethod(ElP, 'insertAdjacentHTML', function (self) { guardFramesIn(self.parentNode || self); });
        wrapSetter(ElP, 'innerHTML', function (self) { guardFramesIn(self); });
        wrapSetter(ElP, 'outerHTML', function () { guardFramesIn(win.document && win.document.documentElement); });
        var DocP = win.Document && win.Document.prototype;
        ['write', 'writeln'].forEach(function (n) { wrapMethod(DocP, n, function (doc) { guardFramesIn(doc.documentElement); }); });
        try {
          var open = win.open;
          if (typeof open === 'function') {
            win.open = function () { var w2 = open.apply(this, arguments); try { guard(w2); } catch (e) {} return w2; };
          }
        } catch (e) {}
        // 兜底：解析器插入的 iframe（不经过上面的方法）
        try {
          var MO = win.MutationObserver;
          if (MO && win.document) {
            new MO(function (records) {
              for (var i = 0; i < records.length; i++) {
                var added = records[i].addedNodes;
                for (var j = 0; j < added.length; j++) guardFramesIn(added[j]);
              }
            }).observe(win.document, { childList: true, subtree: true });
          }
        } catch (e) {}
      }

      guard(window);
    })();
    """#
    // MIO_JS_END webrtcGuard
}

#if canImport(UIKit) && canImport(WebKit)
import UIKit
import WebKit

extension MioWebRTCGuard {
    /// Mac：WKWebView 默认可能没开 WebRTC / 媒体设备（CI 上 RTCPeerConnection、MediaStreamTrack 都不存在）。
    /// 放行站点要能用网页通话，这里用 WKPreferences 的私有开关尽力打开（先 responds(to:)，ObjC 异常也接住；只在 Mac 上设置）。
    /// 屏蔽仍由注入脚本负责，与这些开关无关。
    @discardableResult
    static func enableNativeWebRTC(_ prefs: WKPreferences) -> [String: Bool] {
        var applied: [String: Bool] = [:]
        for (key, setter) in [("peerConnectionEnabled", "_setPeerConnectionEnabled:"), ("mediaDevicesEnabled", "_setMediaDevicesEnabled:"), ("mediaStreamEnabled", "_setMediaStreamEnabled:")] {
            guard prefs.responds(to: NSSelectorFromString(setter)) else { applied[key] = false; continue }
            let exc = MioObjCSafe.catching { prefs.setValue(true, forKey: key) }
            applied[key] = exc == nil
        }
        nativePrefs = applied
        NSLog("⚡️ Mio browser WebRTC prefs: %@", "\(applied)")
        return applied
    }

    /// 最近一次 enableNativeWebRTC 的结果（冒烟报告）
    static var nativePrefs: [String: Bool] = [:]

    /// 内置浏览器用：页面世界、所有 frame、document-start（总开关关掉时空）
    static func webKitScripts() -> [WKUserScript] {
        guard let js = MioWebRTCSettings.script() else { return [] }
        return [WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: false)]
    }
}

/// 设置页：总开关、当前站点放行、常见网页通话站点一键放行、放行列表（左滑删除）
final class MioWebRTCSettingsViewController: UITableViewController {
    private enum Row {
        case master, currentSite(String), preset(name: String, host: String), entry(String), add
    }

    private let currentHost: String?
    private var sections: [(title: String?, footer: String?, rows: [Row])] = []
    private var observer: NSObjectProtocol?

    init(currentHost: String?) {
        self.currentHost = currentHost
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { if let o = observer { NotificationCenter.default.removeObserver(o) } }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "WebRTC 控制"
        observer = NotificationCenter.default.addObserver(forName: MioWebRTCSettings.changedNotification, object: nil, queue: .main) { [weak self] _ in
            self?.rebuild()
        }
        rebuild()
    }

    private func rebuild() {
        var s: [(String?, String?, [Row])] = []
        var first: [Row] = [.master]
        if let h = currentHost, !h.isEmpty, MioWebRTCSettings.enabled { first.append(.currentSite(h)) }
        s.append((nil, "开启后网页无法使用 WebRTC（RTCPeerConnection、RTCDataChannel 等）和摄像头 / 麦克风 / 屏幕共享，防止网页借 WebRTC 获取你的本机和局域网 IP（使用代理 / VPN 时尤其重要）。所有 frame 都生效。改动对之后打开的页面生效。", first))
        if MioWebRTCSettings.enabled {
            let presets: [Row] = MioWebRTCSettings.presets.map { .preset(name: $0.name, host: $0.host) }
            s.append(("网页通话（一键放行）", "放行后该网站（含子域名）可以正常使用视频会议、语音通话。", presets))
            var list: [Row] = MioWebRTCSettings.allowlist.map { .entry($0) }
            list.append(.add)
            s.append(("放行的网站", "包含其所有子域名。左滑删除。", list))
        }
        sections = s.map { (title: $0.0, footer: $0.1, rows: $0.2) }
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].rows.count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { sections[section].title }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? { sections[section].footer }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.selectionStyle = .none
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.detailTextLabel?.numberOfLines = 0
        switch sections[indexPath.section].rows[indexPath.row] {
        case .master:
            cell.textLabel?.text = "屏蔽 WebRTC"
            cell.detailTextLabel?.text = "防 IP 泄露，默认开启"
            cell.accessoryView = makeSwitch(MioWebRTCSettings.enabled) { MioWebRTCSettings.enabled = $0 }
        case .currentSite(let host):
            cell.textLabel?.text = "允许 \(host) 使用 WebRTC"
            cell.detailTextLabel?.text = MioWebRTCSettings.allowlistEntry(for: host).map { "放行列表：\($0)" }
            cell.accessoryView = makeSwitch(MioWebRTCSettings.isAllowed(host)) { MioWebRTCSettings.setAllowed(host, $0) }
        case .preset(let name, let host):
            cell.textLabel?.text = name
            cell.detailTextLabel?.text = host
            cell.accessoryView = makeSwitch(MioWebRTCSettings.allowlist.contains(host)) { MioWebRTCSettings.setAllowed(host, $0) }
        case .entry(let host):
            cell.textLabel?.text = host
        case .add:
            cell.textLabel?.text = "添加网站…"
            cell.textLabel?.textColor = .systemBlue
            cell.selectionStyle = .default
        }
        return cell
    }

    private func makeSwitch(_ on: Bool, _ change: @escaping (Bool) -> Void) -> UISwitch {
        let sw = UISwitch()
        sw.isOn = on
        sw.addAction(UIAction { action in
            if let s = action.sender as? UISwitch { change(s.isOn) }
        }, for: .valueChanged)
        return sw
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard case .add = sections[indexPath.section].rows[indexPath.row] else { return }
        let a = UIAlertController(title: "放行网站", message: "输入域名，例如 meet.google.com", preferredStyle: .alert)
        a.addTextField {
            $0.keyboardType = .URL
            $0.autocapitalizationType = .none
            $0.autocorrectionType = .no
            $0.text = self.currentHost.map(MioWebRTCSettings.normalize)
        }
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        a.addAction(UIAlertAction(title: "放行", style: .default) { _ in
            if let t = a.textFields?.first?.text, !t.isEmpty { MioWebRTCSettings.setAllowed(t, true) }
        })
        present(a, animated: true)
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        if case .entry = sections[indexPath.section].rows[indexPath.row] { return true }
        return false
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete, case .entry(let host) = sections[indexPath.section].rows[indexPath.row] else { return }
        MioWebRTCSettings.allowlist = MioWebRTCSettings.allowlist.filter { $0 != host }
    }
}
#endif
