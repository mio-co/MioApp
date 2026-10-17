// MioMediaScripts.swift — 内置浏览器的媒体功能（v0.3.3）：后台播放 / 自动续播、锁屏 Now Playing、画中画按钮、SponsorBlock。
// 只依赖 Foundation（不 import UIKit / WebKit）：tools/MioAppTests 通过符号链接直接 swift test；
// 注入页面的 JS 放在 MIO_JS_BEGIN/END 段里，由 tools/MioAppTests/js/media-*.test.mjs 抽出来用 node 跑。
//
// SponsorBlock 数据来自 https://sponsor.ajay.app（CC BY-NC-SA 4.0，署名见 README / NOTICE）。
// 隐私方式：只发 videoID 的 SHA-256 前 4 位，在本地按 videoID 匹配。

import Foundation

enum MioMediaScripts {
    // MARK: - SponsorBlock 分类

    struct Category: Equatable {
        let key: String
        let title: String
        let defaultOn: Bool
    }

    /// 顺序 = 设置页顺序。默认只开 sponsor / selfpromo / interaction
    static let categories: [Category] = [
        Category(key: "sponsor", title: "赞助广告", defaultOn: true),
        Category(key: "selfpromo", title: "自我推广 / 无偿推广", defaultOn: true),
        Category(key: "interaction", title: "互动提醒（求订阅 / 点赞）", defaultOn: true),
        Category(key: "intro", title: "片头 / 开场动画", defaultOn: false),
        Category(key: "outro", title: "片尾 / 结束画面", defaultOn: false),
    ]

    static var defaultCategoryKeys: [String] { categories.filter { $0.defaultOn }.map { $0.key } }

    static let sponsorBlockHost = "sponsor.ajay.app"

    /// 原生代取（页面 fetch 失败时的兜底）只允许 SponsorBlock 的 skipSegments 哈希前缀接口
    static func isAllowedSponsorBlockURL(_ s: String) -> Bool {
        guard let c = URLComponents(string: s), c.scheme == "https", c.host?.lowercased() == sponsorBlockHost,
              c.port == nil, c.user == nil, c.password == nil else { return false }
        let parts = c.path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[0] == "api", parts[1] == "skipSegments" else { return false }
        let prefix = parts[2]
        return (4...32).contains(prefix.count) && prefix.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }

    /// 与 JS 里 parseVideoId 相同的规则（原生侧用于日志 / 冒烟）
    static func videoID(from url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let valid: (String) -> String? = { id in
            id.count == 11 && id.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-").contains($0) } ? id : nil
        }
        let parts = url.path.split(separator: "/").map(String.init)
        if host == "youtu.be" { return parts.first.flatMap(valid) }
        guard host == "youtube.com" || host.hasSuffix(".youtube.com") || host == "youtube-nocookie.com" || host.hasSuffix(".youtube-nocookie.com") else { return nil }
        if parts.first == "watch" || parts.isEmpty {
            let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value
            return v.flatMap(valid)
        }
        if parts.count >= 2, ["shorts", "embed", "live", "v", "e"].contains(parts[0]) { return valid(parts[1]) }
        return nil
    }

    // MARK: - 配置（烘焙进注入脚本，设置改了对之后加载的页面生效）

    struct Config: Equatable {
        var platform: String            // ios | mac | android | desktop
        var background: Bool            // 后台播放：自动续播（可见性伪造在独立脚本里）
        var nowPlaying: Bool            // 锁屏 / 控制中心 Now Playing（MediaSession 元数据 + 控制）
        var pip: Bool                   // 播放器上的画中画按钮
        var sponsorBlock: Bool
        var categories: [String]

        init(platform: String, background: Bool = true, nowPlaying: Bool = true, pip: Bool = true,
             sponsorBlock: Bool = true, categories: [String] = MioMediaScripts.defaultCategoryKeys) {
            self.platform = platform
            self.background = background
            self.nowPlaying = nowPlaying
            self.pip = pip
            self.sponsorBlock = sponsorBlock
            let known = Set(MioMediaScripts.categories.map { $0.key })
            // 去重、只保留已知分类，按设置页顺序
            self.categories = MioMediaScripts.categories.map { $0.key }.filter { categories.contains($0) && known.contains($0) }
        }

        /// 稳定顺序的 JSON（不依赖 JSONSerialization 的键顺序，便于测试与缓存）
        var json: String {
            func s(_ v: String) -> String {
                var out = "\""
                for u in v.unicodeScalars {
                    switch u {
                    case "\"": out += "\\\""
                    case "\\": out += "\\\\"
                    case "\n": out += "\\n"
                    case "\r": out += "\\r"
                    case "\t": out += "\\t"
                    case "<": out += "\\u003c"       // 不让 </script> 之类出现在脚本里
                    default:
                        if u.value < 0x20 || u.value == 0x2028 || u.value == 0x2029 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
                    }
                }
                return out + "\""
            }
            let cats = categories.map(s).joined(separator: ",")
            return "{\"platform\":\(s(platform)),\"background\":\(background),\"nowPlaying\":\(nowPlaying),\"pip\":\(pip),\"sponsorBlock\":\(sponsorBlock),\"categories\":[\(cats)]}"
        }
    }

    static let configPlaceholder = "__MIO_MEDIA_CONFIG__"

    static func youtubeMediaScript(_ config: Config) -> String {
        youtubeMediaScriptTemplate.replacingOccurrences(of: configPlaceholder, with: config.json)
    }

    // MARK: - 后台播放：可见性伪造（v0.3.2 MioBrowser.backgroundPlaybackScripts 的同一份逻辑，移到这里并补强）

    /// 所有站点主框架，document-start：页面始终认为自己可见。
    /// v0.3.2 只在 document 捕获阶段拦 visibilitychange；页面在 window 捕获阶段挂的监听器仍会收到。
    /// 现在先在 window 捕获阶段拦（事件路径的最前面），document 上也保留。
    /// 注意：YouTube 防沉迷脚本在本脚本之前注入，它在 window 捕获阶段的监听器先注册，仍然能收到真实的可见性变化。
    // MIO_JS_BEGIN visibility
    static let visibilityScript = #"""
    (function () {
      'use strict';
      if (window.__mioVisibility) return;
      try {
        Object.defineProperty(window, '__mioVisibility', { value: true, configurable: true });
        var d = document;
        Object.defineProperty(d, 'hidden', { configurable: true, get: function () { return false; } });
        Object.defineProperty(d, 'visibilityState', { configurable: true, get: function () { return 'visible'; } });
        Object.defineProperty(d, 'webkitHidden', { configurable: true, get: function () { return false; } });
        Object.defineProperty(d, 'webkitVisibilityState', { configurable: true, get: function () { return 'visible'; } });
        var stop = function (e) { e.stopImmediatePropagation(); };
        ['visibilitychange', 'webkitvisibilitychange'].forEach(function (t) {
          window.addEventListener(t, stop, true);
          d.addEventListener(t, stop, true);
        });
      } catch (e) {}
    })();
    """#
    // MIO_JS_END visibility

    // MARK: - YouTube 媒体脚本

    /// *.youtube.com 主框架，document-start。配置占位符 __MIO_MEDIA_CONFIG__ 由原生替换成 Config.json。
    /// 全部用 DOM API 构建（YouTube 有 Trusted Types），不用 innerHTML。
    /// 原生桥（可选）：iOS window.webkit.messageHandlers.mioMedia（WKScriptMessageHandlerWithReply），Android window.MioMediaBridge。
    /// 原生调用页面：window.__mioMedia.command('play'|'pause'|'toggle'|'next'|'previous'|'seek', seconds)、
    ///               window.__mioMedia.appState('background'|'foreground')、window.__mioMedia.userIntent('pause')（耳机拔出 / 来电）
    // MIO_JS_BEGIN youtubeMedia
    static let youtubeMediaScriptTemplate = #"""
    (function () {
      'use strict';
      var w = window, d = document;
      if (w.top !== w.self) return;
      if (!/(^|\.)youtube\.com$/i.test(location.hostname)) return;
      if (w.__mioMedia) return;

      var CFG = __MIO_MEDIA_CONFIG__;
      if (!CFG || typeof CFG !== 'object') CFG = {};
      var CATS_ALL = ['sponsor', 'selfpromo', 'interaction', 'intro', 'outro'];
      var CAT_LABEL = { sponsor: '赞助广告', selfpromo: '自我推广', interaction: '互动提醒', intro: '片头', outro: '片尾' };
      var CAT_COLOR = { sponsor: '#00d400', selfpromo: '#ffff00', interaction: '#cc00ff', intro: '#00ffff', outro: '#0202ed' };
      var SB_API = 'https://sponsor.ajay.app/api/skipSegments/';
      var nativeFetch = typeof w.fetch === 'function' ? w.fetch.bind(w) : null;
      var now = function () { return Date.now(); };

      // ------------------------------------------------------------------ 纯逻辑（单测直接调用 __mioMedia.lib）

      var ID_RE = /^[A-Za-z0-9_-]{11}$/;
      function parseVideoId(href) {
        var u;
        try { u = new URL(String(href), 'https://www.youtube.com/'); } catch (e) { return null; }
        var host = u.hostname.toLowerCase();
        var parts = u.pathname.split('/').filter(Boolean);
        var ok = function (id) { return id && ID_RE.test(id) ? id : null; };
        if (host === 'youtu.be') return ok(parts[0]);
        if (!/(^|\.)youtube(-nocookie)?\.com$/.test(host)) return null;
        if (parts[0] === 'watch' || parts.length === 0) return ok(u.searchParams.get('v'));
        if (parts.length >= 2 && ['shorts', 'embed', 'live', 'v', 'e'].indexOf(parts[0]) >= 0) return ok(parts[1]);
        return null;
      }

      function sha256Hex(text) {
        var c = w.crypto && w.crypto.subtle;
        if (!c || typeof TextEncoder !== 'function') return Promise.reject(new Error('no crypto.subtle'));
        return c.digest('SHA-256', new TextEncoder().encode(String(text))).then(function (buf) {
          var b = new Uint8Array(buf), s = '';
          for (var i = 0; i < b.length; i++) s += (b[i] < 16 ? '0' : '') + b[i].toString(16);
          return s;
        });
      }
      function hashPrefix(id) { return sha256Hex(id).then(function (h) { return h.slice(0, 4); }); }

      function normalizeCategories(list) {
        var out = [];
        (Array.isArray(list) ? list : []).forEach(function (c) { if (CATS_ALL.indexOf(c) >= 0 && out.indexOf(c) < 0) out.push(c); });
        return out;
      }
      function segmentsUrl(prefix, categories) {
        return SB_API + prefix + '?categories=' + encodeURIComponent(JSON.stringify(categories)) +
          '&actionTypes=' + encodeURIComponent(JSON.stringify(['skip']));
      }

      // 哈希前缀接口返回同前缀的多个视频：本地按 videoID 精确匹配，只留启用的分类 + skip 类型，按开始时间排序
      function pickSegments(json, videoId, categories) {
        if (!Array.isArray(json)) return [];
        var cats = normalizeCategories(categories);
        var entry = null;
        for (var i = 0; i < json.length; i++) if (json[i] && json[i].videoID === videoId) { entry = json[i]; break; }
        if (!entry || !Array.isArray(entry.segments)) return [];
        var out = [];
        entry.segments.forEach(function (s) {
          if (!s || !Array.isArray(s.segment) || s.segment.length < 2) return;
          if (cats.indexOf(s.category) < 0) return;
          if (s.actionType && s.actionType !== 'skip') return;
          var a = Number(s.segment[0]), b = Number(s.segment[1]);
          if (!isFinite(a) || !isFinite(b) || b - a < 0.5 || a < 0) return;
          out.push({ start: a, end: b, category: s.category, uuid: String(s.UUID || ''), videoDuration: Number(s.videoDuration) || 0 });
        });
        out.sort(function (x, y) { return x.start - y.start || x.end - y.end; });
        return out;
      }

      // 跳过逻辑（不碰 DOM）：
      // - 播放进入「已武装」的片段 → 跳到片段结尾，记一次可撤销操作
      // - 撤销 → 回到跳过前的位置，这个片段解除武装（本次观看不再自动跳）
      // - 用户手动 seek 进某个片段内部 → 该片段解除武装（想看就让他看）；seek 到片段之前不影响
      // - 我们自己发起的 seek（跳过 / 撤销）不算手动
      var EPS = 0.25;
      function SkipController(segments) {
        this.segments = (segments || []).map(function (s) { return { start: s.start, end: s.end, category: s.category, uuid: s.uuid, armed: true }; });
        this.pendingSeek = null;   // 我们发起、尚未看到 seeking 事件的目标时间
        this.lastSkip = null;      // { seg, from, to }
      }
      SkipController.prototype.segmentAt = function (t) {
        for (var i = 0; i < this.segments.length; i++) {
          var s = this.segments[i];
          if (t >= s.start && t < s.end - EPS) return s;
        }
        return null;
      };
      // 播放进度更新：返回需要跳过的片段（并记录），否则 null
      SkipController.prototype.check = function (t) {
        if (this.pendingSeek !== null) return null;
        var s = this.segmentAt(t);
        if (!s || !s.armed) return null;
        this.lastSkip = { seg: s, from: t, to: s.end };
        this.pendingSeek = s.end;
        return s;
      };
      // seeking 事件：kind = 'self' | 'manual-in-segment' | 'manual'
      SkipController.prototype.seeking = function (t) {
        if (this.pendingSeek !== null && Math.abs(t - this.pendingSeek) < 0.75) { this.pendingSeek = null; return 'self'; }
        this.pendingSeek = null;
        var s = this.segmentAt(t);
        if (s) { s.armed = false; return 'manual-in-segment'; }
        return 'manual';
      };
      // 撤销最近一次跳过：返回要回到的时间（null = 没有可撤销的）
      SkipController.prototype.undo = function () {
        var l = this.lastSkip;
        if (!l) return null;
        this.lastSkip = null;
        l.seg.armed = false;
        var back = Math.max(l.seg.start, Math.min(l.from, l.seg.end - 1));
        this.pendingSeek = back;
        return back;
      };

      // 后台自动续播判定：页面真的不可见（或刚切到后台 2 秒内），不是用户 / 系统要求的暂停，暂停前确实在播放，没有播完
      function shouldResume(s) {
        if (!s || s.ended || s.pip) return false;   // 画中画窗口里的暂停是用户点的
        if (s.sinceUserPause !== null && s.sinceUserPause < 1500) return false;
        if (s.sincePlaying === null || s.sincePlaying > 2000) return false;
        return !!(s.hidden || (s.sinceBackground !== null && s.sinceBackground < 2500));
      }

      function fmtTime(t) {
        t = Math.max(0, Math.round(t));
        var h = Math.floor(t / 3600), m = Math.floor((t % 3600) / 60), s = t % 60;
        return (h ? h + ':' + (m < 10 ? '0' : '') : '') + m + ':' + (s < 10 ? '0' : '') + s;
      }

      var api = {
        config: CFG,
        lib: { parseVideoId: parseVideoId, sha256Hex: sha256Hex, hashPrefix: hashPrefix, pickSegments: pickSegments, segmentsUrl: segmentsUrl,
               normalizeCategories: normalizeCategories, SkipController: SkipController, shouldResume: shouldResume, fmtTime: fmtTime },
        state: { videoId: null, segments: [], skips: 0, resumes: 0, sbError: null, pipButton: false }
      };
      try { Object.defineProperty(w, '__mioMedia', { value: api, configurable: true }); } catch (e) { w.__mioMedia = api; }

      // ------------------------------------------------------------------ 页面 / 原生桥

      var visDesc = null;
      try { visDesc = Object.getOwnPropertyDescriptor(w.Document.prototype, 'visibilityState'); } catch (e) {}
      function reallyHidden() {
        try { if (visDesc && visDesc.get) return visDesc.get.call(d) === 'hidden'; } catch (e) {}
        return false;
      }
      function iosBridge() {
        try { return w.webkit && w.webkit.messageHandlers && w.webkit.messageHandlers.mioMedia; } catch (e) { return null; }
      }
      function post(msg) {
        try {
          var h = iosBridge();
          if (h) { var p = h.postMessage(msg); if (p && typeof p.catch === 'function') p.catch(function () {}); return; }
          var a = w.MioMediaBridge;
          if (a && typeof a.post === 'function') a.post(JSON.stringify(msg));
        } catch (e) {}
      }

      function mainVideo() {
        return d.querySelector('#movie_player video.html5-main-video') || d.querySelector('video.html5-main-video') ||
          d.querySelector('#movie_player video') || d.querySelector('ytm-player video, .html5-video-player video');
      }
      function isMain(v) { return !!v && v.tagName === 'VIDEO' && v === mainVideo(); }
      function player() { return d.getElementById('movie_player'); }

      // ------------------------------------------------------------------ 后台播放：自动续播

      var lastUserPauseAt = null, lastPlayingAt = null, backgroundAt = null, resumeTimers = [];
      function userIntent() { lastUserPauseAt = now(); clearResume(); }
      api.userIntent = userIntent;
      function clearResume() { resumeTimers.forEach(function (t) { w.clearTimeout(t); }); resumeTimers = []; }
      function resumeState(v) {
        var t = now();
        return {
          ended: !!(v && v.ended), hidden: reallyHidden(), pip: inPip(v),
          sinceUserPause: lastUserPauseAt === null ? null : t - lastUserPauseAt,
          sincePlaying: lastPlayingAt === null ? null : t - lastPlayingAt,
          sinceBackground: backgroundAt === null ? null : t - backgroundAt
        };
      }
      function tryResume(v) {
        if (!CFG.background || !v || !v.paused || !shouldResume(resumeState(v))) return;
        try {
          var p = v.play();
          api.state.resumes++;
          if (p && typeof p.catch === 'function') p.catch(function () {});
        } catch (e) {}
      }
      function scheduleResume(v) {
        clearResume();
        [250, 900, 1800].forEach(function (ms) { resumeTimers.push(w.setTimeout(function () { tryResume(v); }, ms)); });
      }
      api.appState = function (state) {
        if (state === 'background') {
          backgroundAt = now();
          var v = mainVideo();
          if (v && !v.paused) lastPlayingAt = now();
          if (v) scheduleResume(v);
        } else if (state === 'foreground') {
          backgroundAt = null;
          clearResume();
        }
        return true;
      };

      // ------------------------------------------------------------------ MediaSession：锁屏 / 控制中心

      var ms = navigator.mediaSession || null;
      var pageHandlers = {};
      function defaultAction(action, details) {
        var v = mainVideo(), p = player();
        if (!v) return;
        switch (action) {
          case 'play': var r = v.play(); if (r && r.catch) r.catch(function () {}); break;
          case 'pause': case 'stop': v.pause(); break;
          case 'nexttrack':
            if (p && typeof p.nextVideo === 'function') p.nextVideo();
            else { var n = d.querySelector('.ytp-next-button'); if (n) n.click(); }
            break;
          case 'previoustrack':
            if (v.currentTime > 3 || !(p && typeof p.previousVideo === 'function')) v.currentTime = 0; else p.previousVideo();
            break;
          case 'seekto': if (details && typeof details.seekTime === 'number') v.currentTime = details.seekTime; break;
          case 'seekbackward': v.currentTime = Math.max(0, v.currentTime - ((details && details.seekOffset) || 10)); break;
          case 'seekforward': v.currentTime = v.currentTime + ((details && details.seekOffset) || 10); break;
        }
      }
      function runAction(action, details) {
        if (action === 'pause' || action === 'stop') userIntent();
        if (action === 'play') lastUserPauseAt = null;
        var h = pageHandlers[action];
        if (typeof h === 'function') { try { h.call(ms, details || { action: action }); return; } catch (e) {} }
        defaultAction(action, details);
      }
      var ACTIONS = ['play', 'pause', 'stop', 'nexttrack', 'previoustrack', 'seekto', 'seekbackward', 'seekforward'];
      if (ms && typeof ms.setActionHandler === 'function' && CFG.nowPlaying !== false) {
        var origSet = ms.setActionHandler;
        var install = function (action) {
          try { origSet.call(ms, action, function (details) { runAction(action, details); }); } catch (e) {}
        };
        // 页面（YouTube）自己设的处理器照常生效，只是先经过我们记一下「用户要暂停」
        try {
          ms.setActionHandler = function (action, handler) {
            if (ACTIONS.indexOf(action) < 0) return origSet.apply(ms, arguments);
            pageHandlers[action] = handler || null;
            install(action);
          };
        } catch (e) {}
        ACTIONS.forEach(install);
      }

      api.command = function (name, arg) {
        var v = mainVideo();
        switch (name) {
          case 'play': runAction('play'); break;
          case 'pause': runAction('pause'); break;
          case 'toggle': runAction(v && !v.paused ? 'pause' : 'play'); break;
          case 'next': runAction('nexttrack'); break;
          case 'previous': runAction('previoustrack'); break;
          case 'seek': runAction('seekto', { action: 'seekto', seekTime: Number(arg) || 0 }); break;
          default: return false;
        }
        return true;
      };

      function videoTitle() {
        var p = player();
        try { var vd = p && typeof p.getVideoData === 'function' && p.getVideoData(); if (vd && vd.title) return { title: vd.title, author: vd.author || '' }; } catch (e) {}
        var h = d.querySelector('ytd-watch-metadata h1, h1.ytd-watch-metadata, .slim-video-metadata-title, .slim-video-information-title, h2.slim-video-metadata-title');
        var a = d.querySelector('ytd-watch-metadata ytd-channel-name a, #owner #channel-name a, .slim-owner-channel-name, ytm-slim-owner-renderer .slim-owner-channel-name');
        var t = (h && h.textContent || '').trim() || String(d.title || '').replace(/\s*-\s*YouTube\s*$/i, '');
        return { title: t, author: (a && a.textContent || '').trim() };
      }
      var lastMetaKey = '', lastStatePost = 0;
      function updateNowPlaying(v, force) {
        if (CFG.nowPlaying === false || !v) return;
        var info = videoTitle();
        var id = api.state.videoId || parseVideoId(location.href);
        var art = id ? 'https://i.ytimg.com/vi/' + id + '/hqdefault.jpg' : '';
        var key = id + '|' + info.title + '|' + info.author;
        if (ms && typeof w.MediaMetadata === 'function' && info.title) {
          var cur = ms.metadata;
          if (key !== lastMetaKey || !cur || cur.title !== info.title) {
            try {
              ms.metadata = new w.MediaMetadata({ title: info.title, artist: info.author, album: 'YouTube',
                artwork: art ? [{ src: art, sizes: '480x360', type: 'image/jpeg' }] : [] });
            } catch (e) {}
          }
        }
        if (ms && typeof ms.setPositionState === 'function' && isFinite(v.duration) && v.duration > 0) {
          try { ms.setPositionState({ duration: v.duration, playbackRate: v.playbackRate || 1, position: Math.min(v.currentTime, v.duration) }); } catch (e) {}
        }
        var t = now();
        if (force || key !== lastMetaKey || t - lastStatePost > 5000) {
          lastStatePost = t;
          post({ type: 'state', playing: !v.paused, title: info.title, artist: info.author, artwork: art,
                 duration: isFinite(v.duration) ? v.duration : 0, position: v.currentTime || 0, rate: v.playbackRate || 1,
                 hasMediaSession: !!(ms && typeof w.MediaMetadata === 'function'), videoId: id });
        }
        lastMetaKey = key;
      }

      // ------------------------------------------------------------------ 画中画按钮

      var PIP_CSS = '#mio-pip-btn{position:absolute;top:10px;left:10px;z-index:80;width:36px;height:36px;border:0;border-radius:18px;' +
        'background:rgba(0,0,0,.55);color:#fff;display:flex;align-items:center;justify-content:center;padding:0;cursor:pointer;' +
        'opacity:0;pointer-events:none;transition:opacity .2s ease;-webkit-tap-highlight-color:transparent}' +
        '#mio-pip-btn.mio-on{opacity:1;pointer-events:auto}' +
        '#mio-sb-toast{position:fixed;left:50%;bottom:calc(env(safe-area-inset-bottom,0px) + 72px);transform:translate(-50%,20px);opacity:0;' +
        'z-index:2147483647;display:flex;align-items:center;gap:12px;max-width:calc(100vw - 24px);box-sizing:border-box;padding:10px 12px 10px 16px;' +
        'border-radius:22px;background:rgba(28,28,30,.9);color:#f2f2f7;font:500 13px/1.3 -apple-system,BlinkMacSystemFont,"PingFang SC","Segoe UI",Roboto,sans-serif;' +
        'box-shadow:0 8px 30px rgba(0,0,0,.3);transition:transform .3s ease,opacity .25s ease;pointer-events:none}' +
        '#mio-sb-toast.mio-show{transform:translate(-50%,0);opacity:1;pointer-events:auto}' +
        '#mio-sb-toast button{border:0;border-radius:14px;padding:6px 12px;background:#f0a3bf;color:#1c1c1e;font:600 13px/1 inherit;cursor:pointer}' +
        '.mio-sb-markers{position:absolute;left:0;right:0;top:0;bottom:0;pointer-events:none;z-index:40}' +
        '.mio-sb-markers>div{position:absolute;top:0;bottom:0;min-width:2px;opacity:.85}';
      function addStyle() {
        if (d.getElementById('mio-media-style')) return;
        var s = d.createElement('style');
        s.id = 'mio-media-style';
        s.textContent = PIP_CSS;
        (d.head || d.documentElement).appendChild(s);
      }
      function pipSupported(v) {
        if (!v) return false;
        try { if (typeof v.webkitSupportsPresentationMode === 'function') return v.webkitSupportsPresentationMode('picture-in-picture'); } catch (e) {}
        return !!(d.pictureInPictureEnabled && typeof v.requestPictureInPicture === 'function');
      }
      function inPip(v) {
        return !!(v && (v.webkitPresentationMode === 'picture-in-picture' || d.pictureInPictureElement === v));
      }
      function togglePip() {
        var v = mainVideo();
        if (!v) return;
        try { v.disablePictureInPicture = false; v.removeAttribute('disablepictureinpicture'); } catch (e) {}
        try {
          if (typeof v.webkitSetPresentationMode === 'function' && typeof v.webkitSupportsPresentationMode === 'function') {
            v.webkitSetPresentationMode(v.webkitPresentationMode === 'picture-in-picture' ? 'inline' : 'picture-in-picture');
          } else if (d.pictureInPictureElement) {
            d.exitPictureInPicture();
          } else if (typeof v.requestPictureInPicture === 'function') {
            var p = v.requestPictureInPicture(); if (p && p.catch) p.catch(function () {});
          }
        } catch (e) {}
      }
      api.togglePip = togglePip;
      var pipBtn = null, pipHide = 0;
      function buildPipButton() {
        var b = d.createElement('button');
        b.id = 'mio-pip-btn';
        b.type = 'button';
        b.setAttribute('aria-label', '画中画');
        b.title = '画中画';
        var NS = 'http://www.w3.org/2000/svg';
        var svg = d.createElementNS(NS, 'svg');
        svg.setAttribute('width', '20'); svg.setAttribute('height', '20'); svg.setAttribute('viewBox', '0 0 24 24');
        svg.setAttribute('fill', 'none'); svg.setAttribute('stroke', 'currentColor'); svg.setAttribute('stroke-width', '2');
        svg.setAttribute('aria-hidden', 'true');
        var r1 = d.createElementNS(NS, 'rect');
        r1.setAttribute('x', '2'); r1.setAttribute('y', '4'); r1.setAttribute('width', '20'); r1.setAttribute('height', '16'); r1.setAttribute('rx', '2');
        var r2 = d.createElementNS(NS, 'rect');
        r2.setAttribute('x', '12'); r2.setAttribute('y', '11'); r2.setAttribute('width', '8'); r2.setAttribute('height', '7'); r2.setAttribute('rx', '1');
        r2.setAttribute('fill', 'currentColor');
        svg.appendChild(r1); svg.appendChild(r2);
        b.appendChild(svg);
        var stop = function (e) { e.stopPropagation(); };
        ['mousedown', 'touchstart', 'pointerdown', 'mouseup', 'touchend', 'pointerup'].forEach(function (t) { b.addEventListener(t, stop); });
        b.addEventListener('click', function (e) { e.preventDefault(); e.stopPropagation(); togglePip(); });
        return b;
      }
      function showPipButton() {
        if (!pipBtn) return;
        pipBtn.classList.add('mio-on');
        if (pipHide) w.clearTimeout(pipHide);
        pipHide = w.setTimeout(function () { pipHide = 0; if (pipBtn) pipBtn.classList.remove('mio-on'); }, 3000);
      }
      function ensurePipButton() {
        if (CFG.pip === false) return;
        var v = mainVideo(), p = player();
        if (!v || !p || !pipSupported(v)) return;
        if (pipBtn && pipBtn.parentNode === p) return;
        addStyle();
        if (!pipBtn) pipBtn = buildPipButton();
        p.appendChild(pipBtn);
        api.state.pipButton = true;
        if (!p.__mioPipWatch) {
          p.__mioPipWatch = true;
          ['mousemove', 'touchstart', 'pointerdown'].forEach(function (t) { p.addEventListener(t, showPipButton, { passive: true }); });
        }
      }

      // ------------------------------------------------------------------ SponsorBlock

      var sbCats = normalizeCategories(CFG.categories);
      var sbOn = CFG.sponsorBlock !== false && sbCats.length > 0;
      var cache = {};          // videoId → segments
      var inflight = {};
      var controller = null, controllerFor = null;

      function fetchJSON(url) {
        function viaNative(err) {
          var h = iosBridge();
          if (!h) return Promise.reject(err);
          var p = h.postMessage({ type: 'sbFetch', url: url });
          if (!p || typeof p.then !== 'function') return Promise.reject(err);
          return p.then(function (text) { return text ? JSON.parse(text) : []; });
        }
        if (!nativeFetch) return viaNative(new Error('no fetch'));
        return nativeFetch(url, { credentials: 'omit', mode: 'cors', cache: 'default' }).then(function (r) {
          if (r.status === 404) return [];
          if (!r.ok) throw new Error('HTTP ' + r.status);
          return r.json();
        }).catch(viaNative);
      }
      function loadSegments(id) {
        if (cache[id]) return Promise.resolve(cache[id]);
        if (inflight[id]) return inflight[id];
        var p = hashPrefix(id).then(function (prefix) {
          return fetchJSON(segmentsUrl(prefix, sbCats));
        }).then(function (json) {
          var segs = pickSegments(json, id, sbCats);
          cache[id] = segs;
          delete inflight[id];
          return segs;
        }, function (err) {
          delete inflight[id];
          api.state.sbError = String(err && err.message || err);
          return [];
        });
        inflight[id] = p;
        return p;
      }

      var toast = null, toastTimer = 0;
      function showToast(text, actionLabel, action) {
        addStyle();
        if (!toast || !toast.isConnected) {
          toast = d.createElement('div');
          toast.id = 'mio-sb-toast';
          toast.setAttribute('role', 'status');
          toast.setAttribute('aria-live', 'polite');
          (d.body || d.documentElement).appendChild(toast);
        }
        while (toast.firstChild) toast.removeChild(toast.firstChild);
        var span = d.createElement('span');
        span.textContent = text;
        toast.appendChild(span);
        if (actionLabel) {
          var b = d.createElement('button');
          b.type = 'button';
          b.textContent = actionLabel;
          b.addEventListener('click', function (e) { e.preventDefault(); e.stopPropagation(); hideToast(); action(); });
          toast.appendChild(b);
        }
        toast.classList.add('mio-show');
        if (toastTimer) w.clearTimeout(toastTimer);
        toastTimer = w.setTimeout(hideToast, 5000);
      }
      function hideToast() {
        if (toastTimer) { w.clearTimeout(toastTimer); toastTimer = 0; }
        if (toast) toast.classList.remove('mio-show');
      }

      var BAR_SELECTORS = ['.ytp-progress-bar', '.ytm-progress-bar', '.ytProgressBarLineProgressBarLine', '.YtProgressBarLineProgressBarLine', 'yt-progress-bar', '.progress-bar-line'];
      var markers = null;
      function progressBar() {
        for (var i = 0; i < BAR_SELECTORS.length; i++) { var el = d.querySelector(BAR_SELECTORS[i]); if (el) return el; }
        return null;
      }
      function clearMarkers() { if (markers && markers.parentNode) markers.parentNode.removeChild(markers); markers = null; }
      function renderMarkers() {
        var v = mainVideo();
        if (!controller || !v || !(v.duration > 0) || !isFinite(v.duration)) return;
        var bar = progressBar();
        if (!bar) return;
        if (markers && markers.parentNode === bar && markers.__mioFor === controllerFor && markers.__mioDur === v.duration) return;
        clearMarkers();
        markers = d.createElement('div');
        markers.className = 'mio-sb-markers';
        markers.__mioFor = controllerFor;
        markers.__mioDur = v.duration;
        controller.segments.forEach(function (s) {
          var m = d.createElement('div');
          m.style.left = (100 * s.start / v.duration).toFixed(3) + '%';
          m.style.width = (100 * (Math.min(s.end, v.duration) - s.start) / v.duration).toFixed(3) + '%';
          m.style.background = CAT_COLOR[s.category] || '#00d400';
          m.title = CAT_LABEL[s.category] || s.category;
          markers.appendChild(m);
        });
        try { if (w.getComputedStyle(bar).position === 'static') bar.style.position = 'relative'; } catch (e) {}
        bar.appendChild(markers);
      }

      function currentVideoId() {
        var p = player();
        try { var vd = p && typeof p.getVideoData === 'function' && p.getVideoData(); if (vd && vd.video_id && ID_RE.test(vd.video_id)) return vd.video_id; } catch (e) {}
        return parseVideoId(location.href);
      }
      function syncVideo() {
        var id = currentVideoId();
        if (id === api.state.videoId) return;
        api.state.videoId = id;
        api.state.segments = [];
        controller = null; controllerFor = null;
        clearMarkers();
        hideToast();
        if (!id) return;
        updateNowPlaying(mainVideo(), true);
        if (!sbOn) return;
        loadSegments(id).then(function (segs) {
          if (api.state.videoId !== id) return;
          api.state.segments = segs;
          controller = segs.length ? new SkipController(segs) : null;
          controllerFor = controller ? id : null;
          renderMarkers();
          var v = mainVideo();
          if (v) onProgress(v);
        });
      }

      function doSkip(v, seg) {
        try { v.currentTime = seg.end; } catch (e) { return; }
        api.state.skips++;
        var label = CAT_LABEL[seg.category] || seg.category;
        showToast('已跳过' + label + '（' + fmtTime(seg.start) + '–' + fmtTime(seg.end) + '）', '撤销', function () {
          if (!controller) return;
          var back = controller.undo();
          if (back !== null) { try { v.currentTime = back; } catch (e) {} }
        });
      }
      function onProgress(v) {
        if (!controller || controllerFor !== api.state.videoId) return;
        var seg = controller.check(v.currentTime);
        if (seg) doSkip(v, seg);
      }
      api.sb = {
        // 冒烟 / 调试：当前视频的片段和控制器
        controller: function () { return controller; },
        reload: function () { api.state.videoId = null; syncVideo(); }
      };

      // ------------------------------------------------------------------ 事件

      // 媒体事件不冒泡，但捕获阶段会经过 document
      d.addEventListener('playing', function (e) {
        var v = e.target;
        if (!isMain(v)) return;
        lastPlayingAt = now();
        clearResume();
        syncVideo();
        ensurePipButton();
        updateNowPlaying(v, true);
      }, true);
      d.addEventListener('pause', function (e) {
        var v = e.target;
        if (!isMain(v)) return;
        updateNowPlaying(v, true);
        if (CFG.background && shouldResume(resumeState(v))) scheduleResume(v);
      }, true);
      d.addEventListener('timeupdate', function (e) {
        var v = e.target;
        if (!isMain(v)) return;
        if (!v.paused) lastPlayingAt = now();
        onProgress(v);
        updateNowPlaying(v, false);
        if (controller && (!markers || !markers.isConnected)) renderMarkers();
      }, true);
      d.addEventListener('seeking', function (e) {
        var v = e.target;
        if (!isMain(v) || !controller) return;
        controller.seeking(v.currentTime);
      }, true);
      ['loadedmetadata', 'durationchange', 'loadeddata'].forEach(function (t) {
        d.addEventListener(t, function (e) {
          if (!isMain(e.target)) return;
          syncVideo();
          renderMarkers();
          ensurePipButton();
        }, true);
      });
      d.addEventListener('ended', function (e) { if (isMain(e.target)) updateNowPlaying(e.target, true); }, true);
      // 键盘 k / 空格暂停、点击暂停都发生在页面可见时，不影响续播判定（续播只在真正不可见时）
      ['yt-navigate-finish', 'state-navigateend', 'yt-page-data-updated'].forEach(function (t) {
        d.addEventListener(t, function () { syncVideo(); ensurePipButton(); });
      });
      w.addEventListener('popstate', function () { syncVideo(); });
      w.addEventListener('pageshow', function () { syncVideo(); });
      d.addEventListener('DOMContentLoaded', function () { addStyle(); syncVideo(); });
    })();
    """#
    // MIO_JS_END youtubeMedia

    // MARK: - 诊断 / 冒烟

    /// EME（DRM）能力：Widevine / FairPlay / ClearKey。evaluateJavaScript 启动后结果写进 window.__mioEmeProbe（JSON 字符串），再读一次
    // MIO_JS_BEGIN emeProbe
    static let emeProbeScript = #"""
    (function () {
      var r = { host: location.hostname, ua: navigator.userAgent, requestMediaKeySystemAccess: typeof navigator.requestMediaKeySystemAccess,
                WebKitMediaKeys: typeof window.WebKitMediaKeys, MediaKeys: typeof window.MediaKeys, secure: !!window.isSecureContext };
      try { if (window.WebKitMediaKeys && WebKitMediaKeys.isTypeSupported) r.webkitFps = WebKitMediaKeys.isTypeSupported('com.apple.fps.1_0', 'video/mp4'); } catch (e) { r.webkitFps = String(e); }
      window.__mioEmeProbe = null;
      var systems = [
        ['com.widevine.alpha', ['cenc']],
        ['com.apple.fps', ['sinf', 'skd', 'cenc']],
        ['com.apple.fps.1_0', ['skd', 'sinf']],
        ['org.w3.clearkey', ['cenc', 'keyids']]
      ];
      if (typeof navigator.requestMediaKeySystemAccess !== 'function') {
        systems.forEach(function (s) { r[s[0]] = 'no-api'; });
        window.__mioEmeProbe = JSON.stringify(r);
        return 'started';
      }
      var pending = systems.length;
      systems.forEach(function (s) {
        var cfg = [{ initDataTypes: s[1], videoCapabilities: [{ contentType: 'video/mp4; codecs="avc1.42E01E"' }], audioCapabilities: [{ contentType: 'audio/mp4; codecs="mp4a.40.2"' }] }];
        navigator.requestMediaKeySystemAccess(s[0], cfg).then(function () { r[s[0]] = true; }, function (e) { r[s[0]] = (e && e.name) || String(e); })
          .then(function () { if (--pending === 0) window.__mioEmeProbe = JSON.stringify(r); });
      });
      setTimeout(function () { if (!window.__mioEmeProbe) { r.timeout = true; window.__mioEmeProbe = JSON.stringify(r); } }, 8000);
      return 'started';
    })();
    """#
    // MIO_JS_END emeProbe

    /// Mac 冒烟：YouTube 页面里媒体脚本已注入、SponsorBlock 纯逻辑在真实 WebKit 里可用（videoID 解析 + crypto.subtle 哈希前缀）
    /// 结果写进 window.__mioMediaSmoke（JSON 字符串）
    // MIO_JS_BEGIN mediaSmoke
    static let mediaSmokeScript = #"""
    (function () {
      var m = window.__mioMedia;
      var r = { host: location.hostname, installed: !!m, visibilitySpoof: !!window.__mioVisibility, hidden: document.hidden,
                mediaSession: !!navigator.mediaSession, MediaMetadata: typeof window.MediaMetadata,
                pipApi: typeof HTMLVideoElement !== 'undefined' && !!(HTMLVideoElement.prototype.webkitSetPresentationMode || HTMLVideoElement.prototype.requestPictureInPicture) };
      window.__mioMediaSmoke = null;
      if (!m) { window.__mioMediaSmoke = JSON.stringify(r); return 'started'; }
      r.config = m.config;
      r.state = m.state;
      r.parse = m.lib.parseVideoId('https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1') === 'dQw4w9WgXcQ' && m.lib.parseVideoId('https://youtu.be/dQw4w9WgXcQ') === 'dQw4w9WgXcQ';
      m.lib.hashPrefix('dQw4w9WgXcQ').then(function (p) { r.prefix = p; r.hashOK = p === '5f6b'; }, function (e) { r.hashError = String(e); })
        .then(function () { window.__mioMediaSmoke = JSON.stringify(r); });
      return 'started';
    })();
    """#
    // MIO_JS_END mediaSmoke
}
