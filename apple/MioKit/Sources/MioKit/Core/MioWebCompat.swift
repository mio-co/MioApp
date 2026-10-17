// MioWebCompat.swift — 内置浏览器 / Mac 主界面的网页兼容逻辑。
// 只依赖 Foundation（不 import UIKit / WebKit），这样 tools/MioAppTests 可以在 Linux / macOS 上直接 swift test，
// 注入页面的 JS 也放在这里，由 tools/MioAppTests/js/*.test.mjs 抽出来用 node 跑。
//
// 1. UA / 内容模式：Mac Catalyst（和 iPad）用桌面 Safari 的 UA + preferredContentMode = .desktop。
//    以前所有平台都追加 "Mobile/15E148 Safari/604.1"，YouTube 把 Mac 当成 iPhone：给 m.youtube.com，
//    并且按 iPhone（没有 MediaSource）只下发渐进式 mp4（itag 18 = 360p）。
// 2. 回车键兜底：Mac Catalyst 的 WKWebView 里 textarea / contenteditable 按 Enter / Shift+Enter 不换行时，
//    在页面没有自己处理（preventDefault / beforeinput / input / 内容变化）的前提下补一次与 Safari 相同的编辑命令。
// 3. 通行密钥提示：未签名（没有 Apple 审批的浏览器权限）的 App 用不了第三方站点的 Passkey / iCloud 钥匙串，
//    页面调用 WebAuthn 失败时提示用户改用 Safari（不尝试绕过）。
// 4. 拦截规则体检：找出可能删掉 YouTube 播放器 streamingData（会导致只剩低画质）的 scriptlet 规则。

import Foundation

public enum MioBrowserProfile: String, Equatable {
    /// iPhone：保持原来的手机 UA（Google 登录需要带 Safari 标识）
    case mobile
    /// Mac Catalyst / iPad：与系统 Safari 桌面版一致的 UA + 桌面内容模式
    case desktop
}

public enum MioWebCompat {
    // MARK: - Profile

    public static func profile(isMacCatalyst: Bool, isPad: Bool) -> MioBrowserProfile {
        (isMacCatalyst || isPad) ? .desktop : .mobile
    }

    // MARK: - User agent

    /// Safari 桌面版至今仍冻结在这两个片段（真实系统版本不再出现在 UA 里）
    public static let macPlatformToken = "Macintosh; Intel Mac OS X 10_15_7"
    public static let webKitToken = "AppleWebKit/605.1.15 (KHTML, like Gecko)"

    /// macOS 版本 → 该系统自带 Safari（= 系统 WebKit）的版本号
    public static func safariVersion(macOSMajor major: Int, minor: Int) -> String {
        let m = max(0, minor)
        switch major {
        case ..<12:
            return "14.1"                        // Big Sur（Catalyst 部署目标 iOS 15 ⇒ 实际最低 macOS 12，兜底）
        case 12:
            return "15.\(min(m + 1, 6))"         // Monterey 12.0 自带 15.1 … 12.5+ 为 15.6
        case 13:
            return "16.\(min(m + 1, 6))"         // Ventura 13.0 自带 16.1 … 13.5+ 为 16.6
        case 14:
            return "17.\(m)"                     // Sonoma 14.x ↔ Safari 17.x
        case 15:
            return "18.\(m)"                     // Sequoia 15.x ↔ Safari 18.x
        default:
            return "\(major).\(m)"               // macOS 26 起系统与 Safari 同号（Tahoe 26.x ↔ Safari 26.x）
        }
    }

    /// Mac Catalyst 下确定真实的 macOS 版本：优先 /System/Library/CoreServices/SystemVersion.plist；
    /// 读不到时用 ProcessInfo（Catalyst 进程里它可能给出 iOS 对应版本：iOS 16/17/18 ↔ macOS 13/14/15）。
    public static func macOSVersion(systemVersionPlist: [String: Any]?, processVersion: (major: Int, minor: Int)) -> (major: Int, minor: Int) {
        if let s = systemVersionPlist?["ProductVersion"] as? String, let v = parseVersion(s), !(v.major == 10 && v.minor >= 16) {
            // 10.16 是 SYSTEM_VERSION_COMPAT 兼容模式给旧程序看的假版本，忽略
            if v.major >= 11 { return v }
        }
        let (major, minor) = processVersion
        switch major {
        case 16...19: return (major - 3, minor)   // iOS 对应版本
        default: return (major, minor)
        }
    }

    public static func parseVersion(_ s: String) -> (major: Int, minor: Int)? {
        let parts = s.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".").map { Int($0) }
        guard let first = parts.first, let major = first else { return nil }
        let minor = parts.count > 1 ? (parts[1] ?? 0) : 0
        return (major, minor)
    }

    /// 与系统 Safari 完全相同格式的桌面 UA
    public static func desktopUserAgent(safariVersion v: String) -> String {
        "Mozilla/5.0 (\(macPlatformToken)) \(webKitToken) Version/\(v) Safari/605.1.15"
    }

    /// 追加在 WebKit 默认 UA 后的应用名（桌面）
    public static func desktopApplicationName(safariVersion v: String) -> String {
        "Version/\(v) Safari/605.1.15"
    }

    /// 追加在 WebKit 默认 UA 后的应用名（iPhone，保持 v0.3.x 行为不变）
    public static func mobileApplicationName(iOSMajor: Int) -> String {
        "Version/\(iOSMajor).0 Mobile/15E148 Safari/604.1"
    }

    // MARK: - Desktop URL rewrite

    /// 桌面模式下把手机版站点换成桌面版（旧链接 / 历史记录 / 站点按旧 Cookie 重定向到 m. 时）
    public static let mobileToDesktopHosts: [String: String] = [
        "m.youtube.com": "www.youtube.com",
    ]

    /// 需要改写时返回桌面版地址，否则 nil。只改主机名，路径 / 查询 / 片段原样保留（m.youtube.com/watch?v= 与桌面版相同）
    public static func desktopURL(for url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), let target = mobileToDesktopHosts[host],
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        // m.youtube.com 上「切换到电脑版」以外的显式要求手机版（app=m / persist_app=1）尊重用户
        if let items = comps.queryItems, items.contains(where: { $0.name == "app" && $0.value == "m" }) { return nil }
        comps.scheme = "https"
        comps.host = target
        return comps.url
    }

    // MARK: - Adblock quality audit

    /// 播放器响应里决定可选清晰度的字段：被删掉 / 置空后播放器只能退回低画质或直接失败
    public static let streamingKeys: Set<String> = [
        "streamingData", "adaptiveFormats", "formats", "hlsManifestUrl", "dashManifestUrl", "serverAbrStreamingUrl",
    ]

    /// 按「删除 / 覆盖哪个属性」解释第一个参数的 scriptlet
    private static let propertyScriptlets: Set<String> = [
        "json-prune", "json-prune-fetch-response", "json-prune-xhr-response",
        "set-constant", "trusted-set-constant", "abort-on-property-read", "abort-on-property-write",
    ]
    /// 直接改写清单（DASH / HLS）的 scriptlet：在 YouTube 上出现就值得人工看一眼
    private static let manifestScriptlets: Set<String> = ["xml-prune", "m3u-prune"]

    /// 返回在 YouTube 上可能导致清晰度被限制的规则（原文）。
    /// 只看「要删除 / 覆盖的属性」：json-prune 的第二个参数（obligatory props，只是匹配条件）不算。
    public static func qualityRiskRules(_ text: String) -> [String] {
        var out: [String] = []
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("!") { continue }
            if let (domains, name, args) = parseScriptletRule(line) {
                guard domains.contains(where: isYouTubeDomain) else { continue }
                if manifestScriptlets.contains(name) { out.append(line); continue }
                guard propertyScriptlets.contains(name), let first = args.first else { continue }
                let paths = first.split(separator: " ").map(String.init)
                if paths.contains(where: { pathTouchesStreaming($0) }) { out.append(line) }
                continue
            }
            // 自定义 JS（AdGuard `#%#`，不含 `#@%#` 例外）：出现 delete …streamingData 之类就标记
            if let r = line.range(of: "#%#"), !line.contains("#@%#") {
                let domains = line[..<r.lowerBound].split(separator: ",").map { String($0) }
                guard domains.contains(where: isYouTubeDomain) else { continue }
                let js = String(line[r.upperBound...])
                if streamingKeys.contains(where: { k in js.contains("delete") && js.contains(k) && js.range(of: "delete[^;]{0,80}\\b\(k)\\b", options: .regularExpression) != nil }) {
                    out.append(line)
                }
            }
        }
        return out
    }

    public static func isYouTubeDomain(_ d: String) -> Bool {
        let host = d.trimmingCharacters(in: .whitespaces).lowercased()
        if host.isEmpty || host.hasPrefix("~") { return false }
        return host == "youtube.com" || host.hasSuffix(".youtube.com") || host == "youtube.*" || host == "youtube-nocookie.com"
            || host.hasSuffix(".youtube-nocookie.com") || host == "youtubekids.com"
    }

    public static func pathTouchesStreaming(_ path: String) -> Bool {
        // JSONPath 形式（$..streamingData）和点路径（playerResponse.streamingData.adaptiveFormats）都拆成段
        let segments = path.split(whereSeparator: { ".[]$?()@*-".contains($0) }).map(String.init)
        return segments.contains(where: { streamingKeys.contains($0) })
    }

    /// 解析 `domains#%#//scriptlet('name', 'a', 'b')`（AdGuard）或 `domains##+js(name, a, b)`（uBO）
    public static func parseScriptletRule(_ line: String) -> (domains: [String], name: String, args: [String])? {
        if let r = line.range(of: "#%#//scriptlet(") {
            let domains = line[..<r.lowerBound].split(separator: ",").map(String.init)
            guard line.hasSuffix(")") else { return nil }
            let inner = String(line[r.upperBound..<line.index(before: line.endIndex)])
            let args = quotedArgs(inner)
            guard let name = args.first else { return nil }
            return (domains, name, Array(args.dropFirst()))
        }
        if let r = line.range(of: "##+js(") {
            let domains = line[..<r.lowerBound].split(separator: ",").map(String.init)
            guard line.hasSuffix(")") else { return nil }
            let inner = String(line[r.upperBound..<line.index(before: line.endIndex)])
            let args = inner.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let name = args.first, !name.isEmpty else { return nil }
            return (domains, name, Array(args.dropFirst()))
        }
        return nil
    }

    /// 'a', "b", 'c\'d' → [a, b, c'd]
    public static func quotedArgs(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var quote: Character?
        var escaped = false
        for ch in s {
            if let q = quote {
                if escaped { cur.append(ch); escaped = false; continue }
                if ch == "\\" { escaped = true; continue }
                if ch == q { out.append(cur); cur = ""; quote = nil; continue }
                cur.append(ch)
            } else if ch == "'" || ch == "\"" {
                quote = ch
            }
        }
        return out
    }

    // MARK: - Injected scripts

    /// 回车键兜底（Mac Catalyst，主界面和内置浏览器，所有 frame）。
    /// 页面自己处理了（preventDefault keydown/keypress、beforeinput、input、内容变了）或在输入法组字时一律不动；
    /// 否则补 Safari 的默认编辑命令：textarea → insertText "\n"；contenteditable → Enter insertParagraph / Shift+Enter insertLineBreak。
    /// 判定放在按键之后 120ms 或下一次按键时（WebKit 原生插入的消息一定排在它们前面），避免与原生插入重复。
    // MIO_JS_BEGIN returnKeyFix
    public static let returnKeyFixScript = #"""
    (function () {
      'use strict';
      if (typeof window === 'undefined' || window.__mioReturnKeyFix) return;
      var SETTLE_MS = 120;
      var api = { count: 0, last: null };
      try { Object.defineProperty(window, '__mioReturnKeyFix', { value: api, configurable: true }); } catch (e) { window.__mioReturnKeyFix = api; }

      function kindOf(el) {
        if (!el || el.nodeType !== 1) return null;
        var tag = String(el.tagName || '').toUpperCase();
        if (tag === 'TEXTAREA') return (el.readOnly || el.disabled) ? null : 'textarea';
        if (el.isContentEditable) return 'contenteditable';
        return null;
      }
      function isReturn(e) {
        return e.key === 'Enter' || e.code === 'Enter' || e.code === 'NumpadEnter' || e.keyCode === 13 || e.which === 13;
      }
      // 纯函数：给定按键状态，返回要补的编辑命令（null = 不动）
      function decide(s) {
        if (!s || !s.kind) return null;
        if (s.composing || s.defaultPrevented || s.handled) return null;
        if (s.ctrl || s.alt || s.meta) return null;
        if (s.kind === 'textarea') return 'insertText';
        return s.shift ? 'insertLineBreak' : 'insertParagraph';
      }
      api.decide = decide;

      var pending = null;
      var composing = false;

      function snapshot(el, kind) {
        try { return kind === 'textarea' ? String(el.value) : String(el.innerHTML); } catch (e) { return ''; }
      }
      function inside(root, node) {
        return !!root && !!node && (root === node || (typeof root.contains === 'function' && root.contains(node)));
      }
      // 焦点已经离开（页面回车后提交 / 关闭了编辑器）就不再补
      function focusedIn(el) {
        return inside(el, document.activeElement);
      }
      function insertFallbackText(el) {
        // execCommand 不可用时：直接改 value 并派发 input（失去撤销栈，只作最后手段）
        var start = el.selectionStart, end = el.selectionEnd, v = String(el.value);
        if (typeof start !== 'number' || typeof end !== 'number') { start = end = v.length; }
        if (typeof el.setRangeText === 'function') el.setRangeText('\n', start, end, 'end');
        else { el.value = v.slice(0, start) + '\n' + v.slice(end); el.selectionStart = el.selectionEnd = start + 1; }
        try { el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertLineBreak', data: null })); }
        catch (e) { var ev = document.createEvent('Event'); ev.initEvent('input', true, false); el.dispatchEvent(ev); }
      }
      function resolve() {
        var p = pending;
        pending = null;
        if (!p) return;
        clearTimeout(p.timer);
        var changed = snapshot(p.el, p.kind) !== p.before;
        var action = decide({
          kind: p.kind,
          shift: !!p.e.shiftKey, alt: !!p.e.altKey, ctrl: !!p.e.ctrlKey, meta: !!p.e.metaKey,
          composing: p.composing,
          defaultPrevented: !!p.e.defaultPrevented || !!(p.press && p.press.defaultPrevented),
          handled: p.handled || changed
        });
        api.last = { action: action, kind: p.kind, changed: changed, handled: p.handled };
        if (!action || !focusedIn(p.el)) return;
        var ok = false;
        try {
          ok = action === 'insertText' ? document.execCommand('insertText', false, '\n') : document.execCommand(action, false, null);
        } catch (e) { ok = false; }
        if (!ok && p.kind === 'textarea') { try { insertFallbackText(p.el); ok = true; } catch (e) {} }
        if (ok) {
          api.count++;
          try { console.info('[Mio] Return key not handled natively; inserted via ' + action); } catch (e) {}
        }
      }

      document.addEventListener('keydown', function (e) {
        if (pending) resolve();
        if (!isReturn(e)) return;
        var el = e.target;
        var kind = kindOf(el);
        if (!kind) return;
        pending = {
          e: e, el: el, kind: kind, press: null, handled: false,
          before: snapshot(el, kind),
          composing: !!e.isComposing || e.keyCode === 229 || composing,
          timer: setTimeout(resolve, SETTLE_MS)
        };
      }, true);
      document.addEventListener('keypress', function (e) {
        if (pending && isReturn(e)) pending.press = e;
      }, true);
      function markHandled(e) {
        if (pending && inside(pending.el, e.target)) pending.handled = true;
      }
      document.addEventListener('beforeinput', markHandled, true);
      document.addEventListener('input', markHandled, true);
      document.addEventListener('compositionstart', function () { composing = true; }, true);
      document.addEventListener('compositionend', function () {
        composing = false;
        if (pending) pending.composing = true;   // 这次回车是用来上屏的
      }, true);
    })();
    """#
    // MIO_JS_END returnKeyFix

    /// WebAuthn（通行密钥）调用失败时通知原生 → 提示「用 Safari 打开」。只观察，不改变页面拿到的结果。
    // MIO_JS_BEGIN passkeyHint
    public static let passkeyHintScript = #"""
    (function () {
      'use strict';
      if (typeof window === 'undefined' || window.__mioPasskeyHint) return;
      window.__mioPasskeyHint = true;
      var nav = window.navigator, c = nav && nav.credentials;
      if (!c) return;
      function report(method, err) {
        try {
          var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.mioPasskey;
          if (h) h.postMessage({ method: method, error: String((err && err.name) || err), host: location.hostname });
        } catch (e) {}
      }
      ['get', 'create'].forEach(function (method) {
        var orig = c[method];
        if (typeof orig !== 'function') return;
        var wrapped = function (options) {
          var p = orig.apply(this, arguments);
          // 只关心通行密钥；mediation: 'conditional'（自动填充式的静默请求）失败不打扰用户
          if (options && options.publicKey && options.mediation !== 'conditional' && p && typeof p.then === 'function') {
            p.then(null, function (err) {
              var n = err && err.name;
              if (n === 'NotAllowedError' || n === 'SecurityError' || n === 'NotSupportedError' || n === 'InvalidStateError') report(method, err);
            });
          }
          return p;
        };
        try { Object.defineProperty(c, method, { value: wrapped, configurable: true, writable: true }); } catch (e) {}
      });
    })();
    """#
    // MIO_JS_END passkeyHint

    /// 诊断：媒体能力 + YouTube 播放器拿到的清晰度（日志 / Mac 冒烟测试用），返回 JSON 字符串
    // MIO_JS_BEGIN mediaProbe
    public static let mediaProbeScript = #"""
    (function () {
      var r = { ua: navigator.userAgent, host: location.hostname };
      try { r.mediaSource = typeof window.MediaSource; } catch (e) {}
      try { r.managedMediaSource = typeof window.ManagedMediaSource; } catch (e) {}
      try {
        var MS = window.MediaSource || window.ManagedMediaSource;
        if (MS && MS.isTypeSupported) {
          r.avc1080 = MS.isTypeSupported('video/mp4; codecs="avc1.640028"');
          r.vp9 = MS.isTypeSupported('video/webm; codecs="vp9"');
        }
      } catch (e) {}
      try {
        var pr = window.ytInitialPlayerResponse;
        var p = document.getElementById('movie_player');
        if (p && typeof p.getPlayerResponse === 'function') pr = p.getPlayerResponse() || pr;
        var sd = pr && pr.streamingData;
        if (sd) {
          var af = sd.adaptiveFormats || [];
          r.adaptiveFormats = af.length;
          r.maxHeight = af.reduce(function (m, f) { return Math.max(m, f.height || 0); }, 0);
          r.progressiveFormats = (sd.formats || []).length;
          r.hlsManifest = !!sd.hlsManifestUrl;
        } else if (pr) {
          r.streamingData = 'missing';
        }
        if (p && typeof p.getAvailableQualityLevels === 'function') r.qualityLevels = p.getAvailableQualityLevels();
      } catch (e) { r.ytError = String(e); }
      return JSON.stringify(r);
    })();
    """#
    // MIO_JS_END mediaProbe

    // MARK: - YouTube 防沉迷

    /// 内置浏览器：YouTube 防沉迷（*.youtube.com 主框架，document-start）。来自用户脚本「最简 YouTube 防沉迷」，改成事件驱动：
    /// 隐藏首页 / 推荐 / 搜索里的 Shorts（频道页保留）、导航栏 Shorts 入口、App 下载推广，删 apple-itunes-app meta；
    /// 在 /shorts/ 立即提醒，之后页面可见时每 N 秒提醒一次（离开即重置）。全部用 DOM API 构建，不用 innerHTML（YouTube 有 Trusted Types）。
    public static let youtubeFocusDefaultInterval = 60
    public static let youtubeFocusIntervalChoices = [30, 60, 120, 300, 600]

    /// 模板来自 shared/scripts/youtube-focus.js（三端共用；`node scripts/sync-shared-scripts.mjs` 同步到下面的 MIO_JS 段，CI 校验一致）
    public static func youtubeFocusScript(intervalSeconds: Int, hidePlayables: Bool = true) -> String {
        let s = max(5, min(3600, intervalSeconds))
        return youtubeFocusScriptTemplate
            .replacingOccurrences(of: "__MIO_YT_INTERVAL_MS__", with: String(s * 1000))
            .replacingOccurrences(of: "__MIO_YT_PLAYABLES__", with: hidePlayables ? "1" : "0")
    }

    /// 只在这些主机上注入（脚本自己也会再检查一次 location.hostname）
    public static func isYouTubeHost(_ host: String?) -> Bool {
        guard let h = host?.lowercased(), !h.isEmpty else { return false }
        return h == "youtube.com" || h.hasSuffix(".youtube.com")
    }

    // MIO_JS_BEGIN youtubeFocus
    public static let youtubeFocusScriptTemplate = #"""
    (function () {
      'use strict';
      // YouTube 防沉迷（内置浏览器，*.youtube.com 主框架，document-start）
      // 单一来源：shared/scripts/youtube-focus.js。Android 从 APK assets 读、Windows/Electron 从 resources 读；
      // iOS / Mac 内嵌在 MioWebCompat.swift（MIO_JS_BEGIN youtubeFocus），由 `node scripts/sync-shared-scripts.mjs` 同步、CI --check 校验一致。
      // 占位符（各端加载时替换）：提醒间隔毫秒 MIO_YT_INTERVAL_MS、是否屏蔽游戏大本营 / Playables MIO_YT_PLAYABLES（"1" / "0"），两侧各带两个下划线。
      // 不轮询、不常驻观察整份文档：路由变化靠 yt-navigate-finish / yt-page-data-updated / state-navigateend / popstate / history 钩子；
      // 文本识别 Shorts 导航项只在路由变化时和导航容器自己的（节流）观察器里做。
      var w = window, d = document;
      if (w.top !== w.self) return;
      if (!/(^|\.)youtube\.com$/i.test(location.hostname)) return;
      if (w.__mioYTFocus) return;
      w.__mioYTFocus = true;

      // Electron 的 preload（webFrame.executeJavaScript）可能早到 <html> 还没创建：等 documentElement 出现再初始化
      function boot(start) {
        if (d.documentElement || typeof MutationObserver !== 'function') { start(); return; }
        var mo = new MutationObserver(function () {
          if (!d.documentElement) return;
          mo.disconnect();
          start();
        });
        mo.observe(d, { childList: true });
      }
      boot(function () {

      var INTERVAL = Number('__MIO_YT_INTERVAL_MS__');
      if (!(INTERVAL >= 5000)) INTERVAL = 60000;
      var PLAYABLES = '__MIO_YT_PLAYABLES__' !== '0';   // 占位符没替换时默认屏蔽
      var SHOW_MS = 4000;
      var root = d.documentElement;
      var NAV_ITEMS = 'ytm-pivot-bar-item-renderer, ytd-guide-entry-renderer, ytd-mini-guide-entry-renderer';
      var NAV_CONTAINERS = 'ytm-pivot-bar-renderer, ytd-guide-renderer, ytd-mini-guide-renderer, tp-yt-app-drawer#guide';
      var NC = 'html:not(.mio-channel-page) ';
      // 游戏大本营（Playables）：html.mio-hide-playables 开关；直接访问 /playables 页面时（html.mio-playables-page）不隐藏页面内容
      var PG = 'html.mio-hide-playables:not(.mio-playables-page) ';
      var PNAV = 'html.mio-hide-playables ';
      var PLAY = ['a[href^="/playables"]', 'a[href*="youtube.com/playables"]', 'mini-game-card-view-model'];
      function hasPlay(tag) { return PLAY.map(function (x) { return PG + tag + ':has(' + x + ')'; }).join(',\n'); }

      var css = [
        // ---- 首页 / 推荐 / 搜索里的 Shorts 区块和卡片（频道页 html.mio-channel-page 保留）----
        NC + 'ytd-reel-shelf-renderer',
        NC + 'ytm-reel-shelf-renderer',
        NC + 'ytd-rich-shelf-renderer[is-shorts]',
        NC + 'ytd-rich-section-renderer:has(ytd-rich-shelf-renderer[is-shorts])',
        NC + 'ytd-rich-section-renderer:has(a[href^="/shorts/"])',
        NC + 'ytm-rich-section-renderer:has(a[href^="/shorts/"])',
        // 2026 手机版首页 Shorts 架子：ytm-shorts-lockup-view-model(-v2) 卡片（链接不一定在 <a href> 上）
        NC + 'ytm-rich-section-renderer:has(ytm-shorts-lockup-view-model)',
        NC + 'ytm-rich-section-renderer:has(ytm-shorts-lockup-view-model-v2)',
        NC + 'ytm-rich-section-renderer:has(ytm-reel-shelf-renderer)',
        NC + 'ytd-rich-section-renderer:has(ytm-shorts-lockup-view-model)',
        NC + 'ytd-rich-section-renderer:has(ytm-shorts-lockup-view-model-v2)',
        NC + 'grid-shelf-view-model:has(ytm-shorts-lockup-view-model)',
        NC + 'grid-shelf-view-model:has(ytm-shorts-lockup-view-model-v2)',
        NC + 'ytm-rich-item-renderer:has(ytm-shorts-lockup-view-model)',
        NC + 'ytm-rich-item-renderer:has(ytm-shorts-lockup-view-model-v2)',
        NC + 'ytd-rich-item-renderer:has(ytm-shorts-lockup-view-model)',
        NC + 'ytd-rich-item-renderer:has(ytm-shorts-lockup-view-model-v2)',
        NC + 'ytm-shorts-lockup-view-model',
        NC + 'ytm-shorts-lockup-view-model-v2',
        NC + 'grid-shelf-view-model:has(a[href^="/shorts/"])',
        NC + 'ytd-rich-item-renderer:has(a[href^="/shorts/"])',
        NC + 'ytm-rich-item-renderer:has(a[href^="/shorts/"])',
        NC + 'ytd-video-renderer:has(a#thumbnail[href^="/shorts/"])',
        NC + 'ytm-video-with-context-renderer:has(a[href^="/shorts/"])',
        NC + 'ytd-compact-video-renderer:has(a[href^="/shorts/"])',
        // ---- 导航里的 Shorts 入口（底部 pivot 栏 / 侧边 guide / mini guide）----
        'ytm-pivot-bar-item-renderer:has(a[href^="/shorts"])',
        'ytm-pivot-bar-item-renderer:has(.pivot-shorts)',
        'ytm-pivot-bar-item-renderer:has([aria-label="Shorts"])',
        'ytd-guide-entry-renderer:has(a[href^="/shorts"])',
        'ytd-guide-entry-renderer:has(a[title="Shorts"])',
        'ytd-mini-guide-entry-renderer:has(a[href^="/shorts"])',
        'ytd-mini-guide-entry-renderer[aria-label="Shorts"]',
        '[data-mio-shorts-nav]',
        // ---- 「打开 App / 下载 App」推广 ----
        'ytm-unplugged-app-promo-renderer',
        'ytm-promoted-app-install-renderer',
        '.ytm-unplugged-app-promo-renderer',
        '#unplugged-app-promo',
        'ytm-bottom-sheet-promo-renderer',
        '.ytm-promoted-app-install-action',
        // ---- 游戏大本营 / Playables：首页 / 推荐里的区块和卡片，guide / 探索里的入口 ----
        hasPlay('ytd-rich-section-renderer'),
        hasPlay('ytm-rich-section-renderer'),
        hasPlay('ytd-rich-shelf-renderer'),
        hasPlay('ytd-rich-item-renderer'),
        hasPlay('ytm-rich-item-renderer'),
        hasPlay('grid-shelf-view-model'),
        PG + 'mini-game-card-view-model',
        PNAV + 'ytd-guide-entry-renderer:has(a[href^="/playables"])',
        PNAV + 'ytd-mini-guide-entry-renderer:has(a[href^="/playables"])',
        PNAV + 'ytm-pivot-bar-item-renderer:has(a[href^="/playables"])',
        PNAV + 'ytm-guide-entry-renderer:has(a[href^="/playables"])',
        PNAV + 'ytm-compact-link-renderer:has(a[href^="/playables"])',
        PNAV + 'yt-chip-cloud-chip-renderer:has(a[href^="/playables"])'
      ].join(',\n').split(',\n').map(function (sel) {
        // 每条选择器单独一条规则：旧版 WebView（Chromium < 105 不支持 :has）只丢掉不认识的那几条，不会整组失效
        return sel + ' { display: none !important; }';
      }).join('\n') + '\n' +
        '#mio-shorts-reminder { position: fixed; top: calc(env(safe-area-inset-top, 0px) + 12px); left: 50%;' +
        ' transform: translate(-50%, calc(-100% - 40px)) scale(0.95); opacity: 0; z-index: 2147483647; pointer-events: none;' +
        ' box-sizing: border-box; max-width: calc(100vw - 24px); padding: 12px 24px; border-radius: 9999px;' +
        ' display: flex; flex-direction: column; align-items: center; text-align: center;' +
        ' font: 400 12px/1.35 -apple-system, BlinkMacSystemFont, "PingFang SC", "Helvetica Neue", sans-serif;' +
        ' background: rgba(28, 28, 30, 0.82); color: #f2f2f7;' +
        ' box-shadow: 0 10px 40px rgba(0,0,0,0.3), 0 0 0 1px rgba(255,255,255,0.10) inset;' +
        ' -webkit-backdrop-filter: blur(20px); backdrop-filter: blur(20px);' +
        ' transition: transform 0.6s cubic-bezier(0.16, 1, 0.3, 1), opacity 0.4s ease; }\n' +
        '#mio-shorts-reminder.mio-show { transform: translate(-50%, 0) scale(1); opacity: 1; }\n' +
        '#mio-shorts-reminder .mio-r-title { display: flex; align-items: center; gap: 6px; font-size: 15px; font-weight: 600; letter-spacing: 0.3px; }\n' +
        '#mio-shorts-reminder .mio-r-sub { margin-top: 3px; opacity: 0.7; letter-spacing: 0.2px; }\n' +
        '@media (prefers-color-scheme: light) { #mio-shorts-reminder { background: rgba(255, 255, 255, 0.88); color: #1c1c1e;' +
        ' box-shadow: 0 10px 40px rgba(0,0,0,0.18), 0 0 0 1px rgba(0,0,0,0.08) inset; } }\n';

      function addStyle() {
        if (d.getElementById('mio-yt-focus-style')) return;
        var s = d.createElement('style');
        s.id = 'mio-yt-focus-style';
        s.textContent = css;
        (d.head || root).appendChild(s);
      }
      addStyle();

      // ---- 删掉 apple-itunes-app meta（「在 App 中打开」横幅）：只看 <html> / <head> 的直接子节点，DOMContentLoaded 后断开 ----
      function dropAppMeta() {
        var m = d.querySelectorAll('meta[name="apple-itunes-app"]');
        for (var i = 0; i < m.length; i++) m[i].remove();
      }
      var headWatch = null, rootWatch = null;
      function watchHead() {
        if (headWatch || !d.head || typeof MutationObserver !== 'function') return;
        headWatch = new MutationObserver(dropAppMeta);
        headWatch.observe(d.head, { childList: true });
      }
      if (typeof MutationObserver === 'function') {
        rootWatch = new MutationObserver(function () { if (d.head) { watchHead(); dropAppMeta(); } });
        rootWatch.observe(root, { childList: true });
      }
      watchHead();
      dropAppMeta();

      // ---- 文本识别 Shorts 导航项（有些手机版底部栏的 Shorts 没有链接）----
      // 手机版底部栏（ytm-pivot-bar-item-renderer）只有固定几个 tab，不会是频道名：沿用原版用户脚本的「包含 Shorts」匹配
      // （标题后面可能紧跟角标文字，如 "Shortsnew"）；桌面 guide / mini guide 里还列着订阅的频道（如「Shorts Fan Club」），
      // 只认整段文本 / title / aria-label 恰好是 Shorts。
      var EXACT = /^\s*shorts\s*$/i, CONTAINS = /shorts/i;
      function isShortsNav(el) {
        var re = String(el.tagName || '').toLowerCase() === 'ytm-pivot-bar-item-renderer' ? CONTAINS : EXACT;
        if (re.test(el.textContent || '')) return true;
        if (el.getAttribute && (re.test(el.getAttribute('aria-label') || '') || re.test(el.getAttribute('title') || ''))) return true;
        var ts = el.querySelectorAll('[title], [aria-label]');
        for (var i = 0; i < ts.length; i++) {
          if (re.test(ts[i].getAttribute('title') || '') || re.test(ts[i].getAttribute('aria-label') || '')) return true;
        }
        return false;
      }
      function markNav(scope) {
        var items = (scope || d).querySelectorAll(NAV_ITEMS);
        for (var i = 0; i < items.length; i++) {
          if (!items[i].hasAttribute('data-mio-shorts-nav') && isShortsNav(items[i])) items[i].setAttribute('data-mio-shorts-nav', '');
        }
      }
      var observed = [];
      var navTimer = 0;
      function scheduleNav() {
        if (navTimer) return;
        navTimer = w.setTimeout(function () { navTimer = 0; markNav(d); }, 200);
      }
      function attachNavObservers() {
        if (typeof MutationObserver !== 'function') return;
        var cs = d.querySelectorAll(NAV_CONTAINERS);
        for (var i = 0; i < cs.length; i++) {
          if (observed.indexOf(cs[i]) >= 0) continue;
          observed.push(cs[i]);
          new MutationObserver(scheduleNav).observe(cs[i], { childList: true, subtree: true });
        }
      }
      // 导航容器常常比路由事件晚出现：每次路由变化后再补查几次（有限次数，不常驻）
      var retryTimers = [];
      function scanNavSoon() {
        for (var i = 0; i < retryTimers.length; i++) w.clearTimeout(retryTimers[i]);
        retryTimers = [];
        [0, 600, 2000, 5000].forEach(function (ms) {
          retryTimers.push(w.setTimeout(function () { attachNavObservers(); markNav(d); }, ms));
        });
      }

      // ---- Shorts 提醒 ----
      var popup = null, hideTimer = 0;
      function buildPopup() {
        var p = d.createElement('div');
        p.id = 'mio-shorts-reminder';
        p.setAttribute('role', 'status');
        p.setAttribute('aria-live', 'polite');
        var title = d.createElement('div');
        title.className = 'mio-r-title';
        var NS = 'http://www.w3.org/2000/svg';
        var svg = d.createElementNS(NS, 'svg');
        svg.setAttribute('width', '18'); svg.setAttribute('height', '18'); svg.setAttribute('viewBox', '0 0 24 24');
        svg.setAttribute('fill', 'none'); svg.setAttribute('stroke', '#FF453A'); svg.setAttribute('stroke-width', '2.5');
        svg.setAttribute('stroke-linecap', 'round'); svg.setAttribute('stroke-linejoin', 'round'); svg.setAttribute('aria-hidden', 'true');
        var c = d.createElementNS(NS, 'circle'); c.setAttribute('cx', '12'); c.setAttribute('cy', '12'); c.setAttribute('r', '10'); svg.appendChild(c);
        [['12', '8', '12', '12'], ['12', '16', '12.01', '16']].forEach(function (a) {
          var l = d.createElementNS(NS, 'line');
          l.setAttribute('x1', a[0]); l.setAttribute('y1', a[1]); l.setAttribute('x2', a[2]); l.setAttribute('y2', a[3]);
          svg.appendChild(l);
        });
        title.appendChild(svg);
        title.appendChild(d.createTextNode('已进入 Shorts 短视频区'));
        var sub = d.createElement('div');
        sub.className = 'mio-r-sub';
        var secs = Math.round(INTERVAL / 1000);
        sub.textContent = '每 ' + (secs % 60 === 0 ? (secs / 60) + ' 分钟' : secs + ' 秒') + '提醒一次，注意时间！';
        p.appendChild(title);
        p.appendChild(sub);
        return p;
      }
      function showPopup() {
        addStyle();
        if (!popup || !popup.isConnected) {
          popup = buildPopup();
          (d.body || root).appendChild(popup);
        }
        if (hideTimer) w.clearTimeout(hideTimer);
        popup.classList.remove('mio-show');
        void popup.offsetWidth;
        popup.classList.add('mio-show');
        hideTimer = w.setTimeout(function () { hideTimer = 0; if (popup) popup.classList.remove('mio-show'); }, SHOW_MS);
        w.__mioYTReminderCount = (w.__mioYTReminderCount || 0) + 1;
      }
      function hidePopup() {
        if (hideTimer) { w.clearTimeout(hideTimer); hideTimer = 0; }
        if (popup) popup.classList.remove('mio-show');
      }

      // 真实可见性：后台播放脚本会把 document.hidden 改成恒 false，这里读原型上的 getter
      var visDesc = null;
      try {
        var DP = w.Document && w.Document.prototype;
        visDesc = DP && Object.getOwnPropertyDescriptor(DP, 'visibilityState');
      } catch (e) {}
      function visible() {
        try { if (visDesc && visDesc.get) return visDesc.get.call(d) !== 'hidden'; } catch (e) {}
        return d.visibilityState !== 'hidden';
      }
      function now() { return Date.now(); }

      var onShorts = false;   // 当前在 /shorts/
      var elapsed = 0;        // 本轮已累计的可见时长（ms）
      var runningSince = 0;   // 正在计时的起点（0 = 暂停）
      var tick = 0;
      function pause() {
        if (runningSince) { elapsed += now() - runningSince; runningSince = 0; }
        if (tick) { w.clearTimeout(tick); tick = 0; }
      }
      function resume() {
        if (!onShorts || runningSince || !visible()) return;
        runningSince = now();
        tick = w.setTimeout(function () {
          tick = 0; runningSince = 0; elapsed = 0;
          showPopup();
          resume();
        }, Math.max(0, INTERVAL - elapsed));
      }
      function setShorts(on) {
        if (on === onShorts) return;
        onShorts = on;
        pause();
        elapsed = 0;
        if (on) { showPopup(); resume(); } else { hidePopup(); }
      }

      var lastPath = null;
      function route() {
        var p = location.pathname || '/';
        dropAppMeta();
        root.classList.toggle('mio-channel-page', /^\/(@|c\/|channel\/|user\/)/i.test(p));
        root.classList.toggle('mio-hide-playables', PLAYABLES);
        root.classList.toggle('mio-playables-page', /^\/playables(\/|$)/i.test(p));
        setShorts(/^\/shorts(\/|$)/i.test(p));
        if (p !== lastPath) { lastPath = p; scanNavSoon(); }
      }

      ['pushState', 'replaceState'].forEach(function (k) {
        var orig = history[k];
        if (typeof orig !== 'function') return;
        history[k] = function () {
          var r = orig.apply(this, arguments);
          try { route(); } catch (e) {}
          return r;
        };
      });
      w.addEventListener('popstate', route);
      ['yt-navigate-finish', 'yt-page-data-updated', 'state-navigateend'].forEach(function (t) {
        d.addEventListener(t, route);
      });
      // window 捕获阶段：比后台播放脚本挂在 document 上的 stopImmediatePropagation 更早
      w.addEventListener('visibilitychange', function () { if (visible()) resume(); else pause(); }, true);
      w.addEventListener('pageshow', function () { route(); if (visible()) resume(); });
      w.addEventListener('pagehide', pause);
      d.addEventListener('DOMContentLoaded', function () {
        addStyle(); watchHead(); dropAppMeta();
        if (rootWatch) { rootWatch.disconnect(); rootWatch = null; }
        if (headWatch) { headWatch.disconnect(); headWatch = null; }
        route();
        scanNavSoon();
      });
      route();
      });
    })();
    """#
    // MIO_JS_END youtubeFocus

    /// Mac 冒烟测试：YouTube 页面里防沉迷脚本是否生效（pushState 到 /shorts/ 看提醒，再 replaceState 回来）
    // MIO_JS_BEGIN youtubeFocusSmoke
    public static let youtubeFocusSmokeScript = #"""
    (function () {
      var r = { host: location.hostname, installed: !!window.__mioYTFocus, style: !!document.getElementById('mio-yt-focus-style') };
      try { r.trustedTypes = !!(window.trustedTypes && window.trustedTypes.createPolicy); } catch (e) {}
      var before = window.__mioYTReminderCount || 0;
      try { history.pushState({}, '', '/shorts/mio-smoke'); } catch (e) { r.pushError = String(e); }
      var p = document.getElementById('mio-shorts-reminder');
      r.reminder = !!p;
      r.count = (window.__mioYTReminderCount || 0) - before;
      r.shown = !!(p && p.classList.contains('mio-show'));
      r.text = p ? p.textContent : '';
      try { history.replaceState({}, '', '/'); } catch (e) {}
      r.hiddenAfterLeave = !!(p && !p.classList.contains('mio-show'));
      return JSON.stringify(r);
    })();
    """#
    // MIO_JS_END youtubeFocusSmoke
}

// MARK: - 内置浏览器：滚动时自动隐藏顶部 / 底部栏（纯逻辑，单测在 tools/MioAppTests）

/// 方向 / 阈值状态机。坐标都是 UIScrollView 的 contentOffset.y（向下滚动变大）。
/// - 只认用户手势驱动的滚动（拖动 / 惯性）；隐藏 / 显示引起的 contentInset 变化、页面自己 scrollTo 不计入，避免来回抖动。
/// - 同方向累计超过阈值才切换；方向反转累计清零。
/// - 顶部（含橡皮筋下拉区）：显示，且不会隐藏；底部橡皮筋区：不累计。滚动停在底部时显示（Safari 行为）。
/// - 内容不够一屏：始终显示。
public struct MioToolbarAutoHide: Equatable {
    public enum Action: Equatable { case none, hide, show }

    public struct Metrics: Equatable {
        /// contentOffset.y
        var offsetY: Double
        /// contentSize.height
        var contentHeight: Double
        /// scrollView.bounds.height
        var viewportHeight: Double
        /// 工具栏隐藏时的顶部 inset（极简域名条）；offsetY <= -hiddenTopInset 即「到顶」
        var hiddenTopInset: Double
        /// 当前的底部 inset
        var bottomInset: Double

        init(offsetY: Double, contentHeight: Double, viewportHeight: Double, hiddenTopInset: Double = 0, bottomInset: Double = 0) {
            self.offsetY = offsetY
            self.contentHeight = contentHeight
            self.viewportHeight = viewportHeight
            self.hiddenTopInset = hiddenTopInset
            self.bottomInset = bottomInset
        }

        var topEdge: Double { -hiddenTopInset }
        var maxOffsetY: Double { contentHeight - viewportHeight + bottomInset }
        /// 内容比一屏长（还能往下滚）
        var scrollable: Bool { maxOffsetY > topEdge + 1 }
    }

    public var threshold: Double = 16
    private(set) var hidden = false
    private var lastY: Double?
    private var accumulated: Double = 0

    public init(threshold: Double = 16) { self.threshold = threshold }

    /// 开始拖动：以当前位置为起点重新累计
    public mutating func beginDrag(at y: Double) {
        lastY = y
        accumulated = 0
    }

    /// 每次 scrollViewDidScroll。userDriven = isTracking || isDragging || isDecelerating
    public mutating func scrolled(_ m: Metrics, userDriven: Bool) -> Action {
        let y = m.offsetY
        defer { lastY = y }
        guard userDriven else { accumulated = 0; return .none }
        guard m.scrollable else { accumulated = 0; return setHidden(false) }
        if y <= m.topEdge + 1 {
            accumulated = 0
            return setHidden(false)
        }
        // 底部橡皮筋区：不累计（回弹时 offset 往回走，不能当成「向上滚动」）
        if y >= m.maxOffsetY - 0.5 { accumulated = 0; return .none }
        guard let last = lastY else { return .none }
        let dy = y - last
        if dy == 0 { return .none }
        if (dy > 0) != (accumulated > 0) && accumulated != 0 { accumulated = 0 }
        accumulated += dy
        if accumulated > threshold, !hidden, y > m.topEdge + threshold {
            accumulated = 0
            return setHidden(true)
        }
        if accumulated < -threshold, hidden {
            accumulated = 0
            return setHidden(false)
        }
        return .none
    }

    /// 拖动结束且没有惯性 / 惯性结束：停在底部就显示
    public mutating func scrollEnded(_ m: Metrics) -> Action {
        accumulated = 0
        guard hidden else { return .none }
        if !m.scrollable || m.offsetY >= m.maxOffsetY - 2 || m.offsetY <= m.topEdge + 1 { return setHidden(false) }
        return .none
    }

    /// 点状态栏回到顶部、新导航、地址栏聚焦、关闭此功能、全屏退出……
    public mutating func forceShow() -> Action {
        accumulated = 0
        lastY = nil
        return setHidden(false)
    }

    /// inset 改动后调用：下一次 didScroll 不和改动前的位置比较
    public mutating func resetTracking() {
        lastY = nil
        accumulated = 0
    }

    private mutating func setHidden(_ h: Bool) -> Action {
        guard h != hidden else { return .none }
        hidden = h
        return h ? .hide : .show
    }
}
