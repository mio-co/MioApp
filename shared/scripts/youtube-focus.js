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
