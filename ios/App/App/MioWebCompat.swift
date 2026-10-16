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

enum MioBrowserProfile: String, Equatable {
    /// iPhone：保持原来的手机 UA（Google 登录需要带 Safari 标识）
    case mobile
    /// Mac Catalyst / iPad：与系统 Safari 桌面版一致的 UA + 桌面内容模式
    case desktop
}

enum MioWebCompat {
    // MARK: - Profile

    static func profile(isMacCatalyst: Bool, isPad: Bool) -> MioBrowserProfile {
        (isMacCatalyst || isPad) ? .desktop : .mobile
    }

    // MARK: - User agent

    /// Safari 桌面版至今仍冻结在这两个片段（真实系统版本不再出现在 UA 里）
    static let macPlatformToken = "Macintosh; Intel Mac OS X 10_15_7"
    static let webKitToken = "AppleWebKit/605.1.15 (KHTML, like Gecko)"

    /// macOS 版本 → 该系统自带 Safari（= 系统 WebKit）的版本号
    static func safariVersion(macOSMajor major: Int, minor: Int) -> String {
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
    static func macOSVersion(systemVersionPlist: [String: Any]?, processVersion: (major: Int, minor: Int)) -> (major: Int, minor: Int) {
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

    static func parseVersion(_ s: String) -> (major: Int, minor: Int)? {
        let parts = s.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".").map { Int($0) }
        guard let first = parts.first, let major = first else { return nil }
        let minor = parts.count > 1 ? (parts[1] ?? 0) : 0
        return (major, minor)
    }

    /// 与系统 Safari 完全相同格式的桌面 UA
    static func desktopUserAgent(safariVersion v: String) -> String {
        "Mozilla/5.0 (\(macPlatformToken)) \(webKitToken) Version/\(v) Safari/605.1.15"
    }

    /// 追加在 WebKit 默认 UA 后的应用名（桌面）
    static func desktopApplicationName(safariVersion v: String) -> String {
        "Version/\(v) Safari/605.1.15"
    }

    /// 追加在 WebKit 默认 UA 后的应用名（iPhone，保持 v0.3.x 行为不变）
    static func mobileApplicationName(iOSMajor: Int) -> String {
        "Version/\(iOSMajor).0 Mobile/15E148 Safari/604.1"
    }

    // MARK: - Desktop URL rewrite

    /// 桌面模式下把手机版站点换成桌面版（旧链接 / 历史记录 / 站点按旧 Cookie 重定向到 m. 时）
    static let mobileToDesktopHosts: [String: String] = [
        "m.youtube.com": "www.youtube.com",
    ]

    /// 需要改写时返回桌面版地址，否则 nil。只改主机名，路径 / 查询 / 片段原样保留（m.youtube.com/watch?v= 与桌面版相同）
    static func desktopURL(for url: URL) -> URL? {
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
    static let streamingKeys: Set<String> = [
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
    static func qualityRiskRules(_ text: String) -> [String] {
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

    static func isYouTubeDomain(_ d: String) -> Bool {
        let host = d.trimmingCharacters(in: .whitespaces).lowercased()
        if host.isEmpty || host.hasPrefix("~") { return false }
        return host == "youtube.com" || host.hasSuffix(".youtube.com") || host == "youtube.*" || host == "youtube-nocookie.com"
            || host.hasSuffix(".youtube-nocookie.com") || host == "youtubekids.com"
    }

    static func pathTouchesStreaming(_ path: String) -> Bool {
        // JSONPath 形式（$..streamingData）和点路径（playerResponse.streamingData.adaptiveFormats）都拆成段
        let segments = path.split(whereSeparator: { ".[]$?()@*-".contains($0) }).map(String.init)
        return segments.contains(where: { streamingKeys.contains($0) })
    }

    /// 解析 `domains#%#//scriptlet('name', 'a', 'b')`（AdGuard）或 `domains##+js(name, a, b)`（uBO）
    static func parseScriptletRule(_ line: String) -> (domains: [String], name: String, args: [String])? {
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
    static func quotedArgs(_ s: String) -> [String] {
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
    static let returnKeyFixScript = #"""
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
    static let passkeyHintScript = #"""
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
    static let mediaProbeScript = #"""
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
        } else if (pr) {
          r.streamingData = 'missing';
        }
        if (p && typeof p.getAvailableQualityLevels === 'function') r.qualityLevels = p.getAvailableQualityLevels();
      } catch (e) { r.ytError = String(e); }
      return JSON.stringify(r);
    })();
    """#
    // MIO_JS_END mediaProbe
}
