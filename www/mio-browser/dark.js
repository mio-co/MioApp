/*
 * Mio 强制深色（内置浏览器，document-start 注入主框架）。
 *
 *   MioDark.resolveEnabled(hostname, cfg)  → 这个站点要不要深色（按站点开关 > 全局「所有网站深色」）
 *   MioDark.decide(env)                    → 'native'（网站自己已经是深色）| 'invert'（智能反色）
 *   MioDark.install(document, window, cfg) → 注入时调用；cfg = { global, sites: { host: true|false }, nativeHosts: [host…] }
 *
 * 策略：
 *   1. 宿主把 WebView 的外观切成深色（iOS overrideUserInterfaceStyle = .dark），网站自带的 prefers-color-scheme: dark 样式直接生效；
 *   2. document-start 先乐观地反色（html filter: invert + hue-rotate，背景设白色 → 反色后为深色），避免白屏闪烁；
 *      之前判断过「自带深色」的站点（nativeHosts）不反色，只给 html 一个深色底；
 *   3. DOMContentLoaded / load 后读页面真实背景色（临时去掉我们的属性，同一个任务里读完再恢复，不会触发绘制）：
 *      页面本来就是深色 → 去掉反色（并上报宿主记住这个站点），否则保持反色；
 *   4. 反色模式下图片 / 视频 / canvas / iframe / 带背景图的元素再反一次，还原成原色。
 * 只用 DOM API（不使用 innerHTML），样式优先用 adoptedStyleSheets（不受页面 CSP 的 style-src 限制），同时放一个 <style> 兜底。
 */
(function (root) {
  'use strict';

  var ATTR = 'data-mio-dark';
  var BG_ATTR = 'data-mio-dark-bg';
  var FILTER = 'invert(1) hue-rotate(180deg)';
  var MEDIA = 'img,video,canvas,iframe,embed,object,picture>source,[' + BG_ATTR + ']';

  var CSS = [
    'html[' + ATTR + '=invert]{filter:' + FILTER + ' !important;background-color:#fff !important}',
    'html[' + ATTR + '=invert] :is(' + MEDIA + '){filter:' + FILTER + ' !important}',
    // 已经被祖先还原过的不再还原（否则又变回反色）
    'html[' + ATTR + '=invert] [' + BG_ATTR + '] :is(' + MEDIA + '){filter:none !important}',
    // 全屏视频：还原
    'html[' + ATTR + '=invert] :fullscreen{filter:' + FILTER + ' !important}',
    'html[' + ATTR + '=invert] :fullscreen :is(' + MEDIA + '){filter:none !important}',
    'html[' + ATTR + '=pending-native]{background-color:#121212}',
    'html[' + ATTR + '=native]{color-scheme:dark}'
  ].join('\n');

  function normalizeHost(h) { return String(h || '').trim().toLowerCase().replace(/^\.+|\.+$/g, '').replace(/^www\./, ''); }

  /// 按站点设置（含父域名：在 example.com 上设置对 news.example.com 也生效，更具体的优先），没有设置时跟随全局开关
  function resolveEnabled(hostname, cfg) {
    cfg = cfg || {};
    var host = normalizeHost(hostname);
    var sites = cfg.sites || {};
    if (host) {
      var parts = host.split('.');
      for (var i = 0; i < parts.length - 1; i++) {
        var key = parts.slice(i).join('.');
        if (Object.prototype.hasOwnProperty.call(sites, key) && typeof sites[key] === 'boolean') return sites[key];
      }
    }
    return !!cfg.global;
  }

  function isNativeHost(hostname, cfg) {
    var host = normalizeHost(hostname);
    var list = (cfg && cfg.nativeHosts) || [];
    for (var i = 0; i < list.length; i++) if (normalizeHost(list[i]) === host) return true;
    return false;
  }

  /// "rgb(1, 2, 3)" / "rgba(1,2,3,0.5)" / "#fff" / "transparent" → { r, g, b, a } | null
  function parseColor(s) {
    s = String(s || '').trim().toLowerCase();
    if (!s || s === 'transparent' || s === 'none') return { r: 0, g: 0, b: 0, a: 0 };
    var m = /^rgba?\(\s*([\d.]+)[\s,]+([\d.]+)[\s,]+([\d.]+)(?:[\s,/]+([\d.]+%?))?\s*\)$/.exec(s);
    if (m) {
      var a = m[4] === undefined ? 1 : /%$/.test(m[4]) ? parseFloat(m[4]) / 100 : parseFloat(m[4]);
      return { r: +m[1], g: +m[2], b: +m[3], a: a };
    }
    m = /^#([0-9a-f]{3,8})$/.exec(s);
    if (m) {
      var h = m[1];
      if (h.length === 3 || h.length === 4) h = h.split('').map(function (c) { return c + c; }).join('');
      return { r: parseInt(h.slice(0, 2), 16), g: parseInt(h.slice(2, 4), 16), b: parseInt(h.slice(4, 6), 16), a: h.length === 8 ? parseInt(h.slice(6, 8), 16) / 255 : 1 };
    }
    if (s === 'white') return { r: 255, g: 255, b: 255, a: 1 };
    if (s === 'black') return { r: 0, g: 0, b: 0, a: 1 };
    return null;
  }

  /// WCAG 相对亮度 0（黑）…1（白）
  function luminance(c) {
    if (!c) return 1;
    function ch(v) { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); }
    return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
  }

  function opaque(c) { return c && c.a >= 0.5; }

  /**
   * env = { probeBg, bodyBg, htmlBg, textColor, colorScheme, metaColorScheme, prefersDark }
   *   probeBg：视口中心元素往上第一个不透明背景（SPA 常把背景放在 #app 上，body 透明）
   * → 'native' | 'invert'
   */
  function decide(env) {
    env = env || {};
    var candidates = [env.probeBg, env.bodyBg, env.htmlBg];
    var bg = null;
    for (var i = 0; i < candidates.length; i++) {
      var c = typeof candidates[i] === 'string' ? parseColor(candidates[i]) : candidates[i];
      if (opaque(c)) { bg = c; break; }
    }
    if (!bg) {
      // 没有任何背景色：画布颜色由 color-scheme 决定（声明了 dark 且系统是深色 → 深色画布）
      var scheme = String(env.colorScheme || '') + ' ' + String(env.metaColorScheme || '');
      var dark = /\bdark\b/.test(scheme) && (env.prefersDark || !/\blight\b/.test(scheme));
      if (dark) return 'native';
      // 文字本身是浅色（深色设计但背景靠图片 / 渐变）
      var text = parseColor(env.textColor);
      if (text && text.a > 0.5 && luminance(text) > 0.6) return 'native';
      return 'invert';
    }
    return luminance(bg) < 0.2 ? 'native' : 'invert';
  }

  // ---------- 页面里运行 ----------

  function install(doc, win, cfg) {
    cfg = cfg || {};
    if (!doc || !doc.documentElement || !win) return null;
    if (win.top && win.top !== win) return null;         // 只管主框架：iframe 整体会被还原
    if (win.__mioDarkInstalled) return win.__mioDarkInstalled;
    var host = (win.location && win.location.hostname) || '';
    var proto = (win.location && win.location.protocol) || '';
    if (proto && proto !== 'http:' && proto !== 'https:') return null;
    if (!resolveEnabled(host, cfg)) return null;

    var html = doc.documentElement;
    var state = { mode: isNativeHost(host, cfg) ? 'pending-native' : 'invert', decided: false };
    html.setAttribute(ATTR, state.mode);
    addStyles(doc, win);

    function measure() {
      var prev = html.getAttribute(ATTR);
      html.removeAttribute(ATTR);
      var env = {};
      try {
        var cs = function (el) { return el ? win.getComputedStyle(el) : null; };
        var hs = cs(html), bs = cs(doc.body);
        env.htmlBg = hs && hs.backgroundColor;
        env.bodyBg = bs && bs.backgroundColor;
        env.textColor = (bs || hs) && (bs || hs).color;
        env.colorScheme = hs && (hs.colorScheme || hs.getPropertyValue('color-scheme'));
        var meta = doc.querySelector('meta[name="color-scheme"]');
        env.metaColorScheme = meta ? meta.getAttribute('content') : '';
        env.prefersDark = !!(win.matchMedia && win.matchMedia('(prefers-color-scheme: dark)').matches);
        env.probeBg = probe(doc, win);
      } catch (e) {}
      if (prev) html.setAttribute(ATTR, prev);
      return env;
    }

    function apply(final) {
      var env = measure();
      var verdict = decide(env);
      var next = verdict === 'native' ? 'native' : 'invert';
      if (next !== html.getAttribute(ATTR)) html.setAttribute(ATTR, next);
      state.mode = next;
      if (final && !state.decided) {
        state.decided = true;
        report(win, { host: host, verdict: verdict });
      }
      if (next === 'invert') scheduleScan();
    }

    // 背景图元素（只看计算样式里有 url(...) 的）：初始全量 + 之后新增节点，节流
    var scanTimer = 0, pending = [];
    function scheduleScan(nodes) {
      if (nodes) pending.push.apply(pending, nodes); else pending.push(doc.body || html);
      if (scanTimer) return;
      scanTimer = win.setTimeout(function () {
        scanTimer = 0;
        var roots = pending.splice(0, pending.length);
        if (html.getAttribute(ATTR) !== 'invert') return;
        markBackgrounds(roots, win, 3000);
      }, 300);
    }

    var onReady = function () { apply(false); };
    var onLoad = function () { apply(true); };
    if (doc.readyState === 'loading') doc.addEventListener('DOMContentLoaded', onReady, { once: true }); else onReady();
    if (doc.readyState === 'complete') win.setTimeout(onLoad, 0); else win.addEventListener('load', onLoad, { once: true });
    // SPA 晚渲染：1.5 秒后再判断一次
    win.setTimeout(function () { apply(true); }, 1500);

    try {
      var mo = new win.MutationObserver(function (records) {
        if (html.getAttribute(ATTR) !== 'invert') return;
        var added = [];
        for (var i = 0; i < records.length; i++) {
          var r = records[i];
          for (var j = 0; j < r.addedNodes.length; j++) if (r.addedNodes[j].nodeType === 1) added.push(r.addedNodes[j]);
        }
        // 页面把 <html> 属性重置了（少数框架会整个替换 attributes）→ 补回
        if (added.length) scheduleScan(added);
      });
      mo.observe(doc, { childList: true, subtree: true });
      var amo = new win.MutationObserver(function () {
        if (!html.hasAttribute(ATTR) && state.mode) html.setAttribute(ATTR, state.mode);
      });
      amo.observe(html, { attributes: true, attributeFilter: [ATTR] });
    } catch (e) {}

    var api = {
      state: state,
      measure: measure,
      apply: apply,
      disable: function () { state.mode = ''; html.removeAttribute(ATTR); }
    };
    win.__mioDarkInstalled = api;
    return api;
  }

  function addStyles(doc, win) {
    var done = false;
    try {
      if (win.CSSStyleSheet && 'adoptedStyleSheets' in doc) {
        var sheet = new win.CSSStyleSheet();
        sheet.replaceSync(CSS);
        doc.adoptedStyleSheets = doc.adoptedStyleSheets.concat([sheet]);
        done = true;
      }
    } catch (e) {}
    try {
      var style = doc.createElement('style');
      style.id = 'mio-dark-style';
      style.textContent = CSS;
      (doc.head || doc.documentElement).appendChild(style);
      // <head> 出现前就插入了：DOMContentLoaded 时挪进 head，避免页面脚本整体替换 <html> 子节点时丢掉
      if (!doc.head) doc.addEventListener('DOMContentLoaded', function () { if (doc.head && style.parentNode !== doc.head) doc.head.appendChild(style); }, { once: true });
    } catch (e) {}
    return done;
  }

  /// 视口中心元素往上第一个不透明背景色
  function probe(doc, win) {
    try {
      var w = win.innerWidth || 0, h = win.innerHeight || 0;
      var el = doc.elementFromPoint ? doc.elementFromPoint(w / 2, Math.min(h / 2, 300)) : null;
      for (var depth = 0; el && depth < 30; el = el.parentElement, depth++) {
        var c = parseColor(win.getComputedStyle(el).backgroundColor);
        if (c && c.a >= 0.5) return 'rgba(' + c.r + ',' + c.g + ',' + c.b + ',' + c.a + ')';
      }
    } catch (e) {}
    return '';
  }

  function markBackgrounds(roots, win, limit) {
    var count = 0;
    for (var i = 0; i < roots.length && count < limit; i++) {
      var r = roots[i];
      if (!r || r.nodeType !== 1) continue;
      var list = [r];
      var all = r.getElementsByTagName ? r.getElementsByTagName('*') : [];
      for (var k = 0; k < all.length && list.length < limit; k++) list.push(all[k]);
      for (var j = 0; j < list.length && count < limit; j++, count++) {
        var el = list[j];
        if (el.hasAttribute(BG_ATTR)) continue;
        var tag = el.tagName;
        if (tag === 'HTML' || tag === 'BODY' || tag === 'IMG' || tag === 'VIDEO' || tag === 'SCRIPT' || tag === 'STYLE') continue;
        var bi;
        try { bi = win.getComputedStyle(el).backgroundImage; } catch (e) { continue; }
        if (bi && bi !== 'none' && /url\(/i.test(bi)) el.setAttribute(BG_ATTR, '');
      }
    }
  }

  function report(win, data) {
    try {
      var h = win.webkit && win.webkit.messageHandlers && win.webkit.messageHandlers.mioDark;
      if (h) { h.postMessage(data); return; }
      if (win.MioDarkBridge && win.MioDarkBridge.report) win.MioDarkBridge.report(JSON.stringify(data));   // Android
      if (win.mioDarkReport) win.mioDarkReport(data);                                                     // Electron preload
    } catch (e) {}
  }

  var api = {
    version: 1,
    CSS: CSS,
    ATTR: ATTR,
    resolveEnabled: resolveEnabled,
    isNativeHost: isNativeHost,
    normalizeHost: normalizeHost,
    parseColor: parseColor,
    luminance: luminance,
    decide: decide,
    install: install,
    markBackgrounds: markBackgrounds
  };
  root.MioDark = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
