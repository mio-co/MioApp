// YouTube 防沉迷脚本（MioWebCompat.youtubeFocusScriptTemplate），在 jsdom 里跑：
// Shorts 卡片 / 区块 / 导航入口隐藏、频道页不隐藏、路由切换开始 / 停止计时、页面不可见时暂停、不用 innerHTML（模拟 Trusted Types）。
import test from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';
import { extractScript } from './harness.mjs';

const TEMPLATE = extractScript('youtubeFocus');
const script = (ms = 60000) => TEMPLATE.replace('__MIO_YT_INTERVAL_MS__', String(ms)).replace('__MIO_YT_PLAYABLES__', '1');

const PAGE = `<!doctype html><html><head><meta name="apple-itunes-app" content="app-id=544007664"></head><body>
<ytd-app>
  <ytd-guide-renderer>
    <ytd-guide-entry-renderer id="g-home"><a id="endpoint" title="首页" href="/">首页</a></ytd-guide-entry-renderer>
    <ytd-guide-entry-renderer id="g-shorts"><a id="endpoint" title="Shorts">Shorts</a></ytd-guide-entry-renderer>
    <ytd-guide-entry-renderer id="g-fan"><a id="endpoint" title="Shorts Fan Club" href="/@shortsfanclub">Shorts Fan Club</a></ytd-guide-entry-renderer>
  </ytd-guide-renderer>
  <ytd-mini-guide-renderer>
    <ytd-mini-guide-entry-renderer id="mg-shorts" aria-label="Shorts"><a id="endpoint"><span>Shorts</span></a></ytd-mini-guide-entry-renderer>
    <ytd-mini-guide-entry-renderer id="mg-subs" aria-label="订阅"><a id="endpoint" href="/feed/subscriptions">订阅</a></ytd-mini-guide-entry-renderer>
  </ytd-mini-guide-renderer>
  <ytd-rich-grid-renderer>
    <ytd-rich-item-renderer id="d-video"><a id="thumbnail" href="/watch?v=abc"></a></ytd-rich-item-renderer>
    <ytd-rich-item-renderer id="d-short"><a id="thumbnail" href="/shorts/xyz"></a></ytd-rich-item-renderer>
    <ytd-rich-section-renderer id="d-shelf"><ytd-rich-shelf-renderer is-shorts id="d-shelf-inner"><a href="/shorts/1"></a></ytd-rich-shelf-renderer></ytd-rich-section-renderer>
    <ytd-rich-section-renderer id="d-news"><ytd-rich-shelf-renderer><a href="/watch?v=n1"></a></ytd-rich-shelf-renderer></ytd-rich-section-renderer>
    <grid-shelf-view-model id="d-grid-shorts"><ytm-shorts-lockup-view-model><a href="/shorts/2"></a></ytm-shorts-lockup-view-model></grid-shelf-view-model>
    <grid-shelf-view-model id="d-grid-normal"><a href="/watch?v=g1"></a></grid-shelf-view-model>
  </ytd-rich-grid-renderer>
  <ytd-search>
    <ytd-reel-shelf-renderer id="d-reel"><a href="/shorts/3"></a></ytd-reel-shelf-renderer>
    <ytd-video-renderer id="d-sr-video"><a id="thumbnail" href="/watch?v=s1"></a><a href="/shorts/linked-in-description"></a></ytd-video-renderer>
    <ytd-video-renderer id="d-sr-short"><a id="thumbnail" href="/shorts/s2"></a></ytd-video-renderer>
  </ytd-search>
</ytd-app>
<ytm-app>
  <ytm-rich-item-renderer id="m-video"><a href="/watch?v=m1"></a></ytm-rich-item-renderer>
  <ytm-rich-section-renderer id="m-shelf"><ytm-shorts-lockup-view-model><a href="/shorts/m2"></a></ytm-shorts-lockup-view-model></ytm-rich-section-renderer>
  <ytm-reel-shelf-renderer id="m-reel"></ytm-reel-shelf-renderer>
  <ytm-promoted-app-install-renderer id="m-promo"></ytm-promoted-app-install-renderer>
  <ytm-pivot-bar-renderer>
    <ytm-pivot-bar-item-renderer id="p-home"><a href="/">首页</a></ytm-pivot-bar-item-renderer>
    <ytm-pivot-bar-item-renderer id="p-shorts"><div class="pivot-bar-item-tab"><span>Shorts</span></div></ytm-pivot-bar-item-renderer>
    <ytm-pivot-bar-item-renderer id="p-subs"><a href="/feed/subscriptions">订阅</a></ytm-pivot-bar-item-renderer>
  </ytm-pivot-bar-renderer>
</ytm-app>
</body></html>`;

function setup({ url = 'https://m.youtube.com/', html = PAGE, interval = 60000, trustedTypes = true } = {}) {
  const dom = new JSDOM(html, { url, runScripts: 'outside-only', pretendToBeVisual: true });
  const w = dom.window;
  // 假时钟：setTimeout / clearTimeout / Date.now
  let now = 1_000_000;
  const timers = new Map();
  let nextId = 1;
  w.setTimeout = (fn, ms = 0) => { const id = nextId++; timers.set(id, { fn, at: now + Math.max(0, ms) }); return id; };
  w.clearTimeout = (id) => { timers.delete(id); };
  w.Date.now = () => now;
  const advance = (ms) => {
    const end = now + ms;
    for (;;) {
      let best = null;
      for (const [id, t] of timers) if (t.at <= end && (!best || t.at < best[1].at)) best = [id, t];
      if (!best) break;
      timers.delete(best[0]);
      now = best[1].at;
      best[1].fn();
    }
    now = end;
  };
  // 可见性（脚本读 Document.prototype 上的 getter）
  let vis = 'visible';
  Object.defineProperty(w.Document.prototype, 'visibilityState', { configurable: true, get: () => vis });
  const setVisible = (v) => { vis = v ? 'visible' : 'hidden'; w.document.dispatchEvent(new w.Event('visibilitychange')); };
  // 模拟 YouTube 的 Trusted Types：任何 HTML 字符串 sink 都抛错
  const sinks = [];
  if (trustedTypes) {
    const boom = (name) => function () { sinks.push(name); throw new w.TypeError(`This document requires 'TrustedHTML' assignment (${name})`); };
    for (const P of [w.Element.prototype]) {
      Object.defineProperty(P, 'innerHTML', { configurable: true, get() { return ''; }, set: boom('innerHTML') });
      Object.defineProperty(P, 'outerHTML', { configurable: true, get() { return ''; }, set: boom('outerHTML') });
      P.insertAdjacentHTML = boom('insertAdjacentHTML');
    }
    w.document.write = boom('document.write');
  }
  w.eval(script(interval));
  const $ = (id) => w.document.getElementById(id);
  const hidden = (id) => w.getComputedStyle($(id)).display === 'none';
  const reminders = () => w.__mioYTReminderCount || 0;
  const go = (path) => w.history.pushState({}, '', path);
  return { dom, w, $, hidden, reminders, go, advance, setVisible, sinks, timers };
}

test('home: Shorts cards, shelves and promos are hidden; normal videos stay', () => {
  const t = setup();
  for (const id of ['d-short', 'd-shelf', 'd-shelf-inner', 'd-grid-shorts', 'd-reel', 'd-sr-short', 'm-shelf', 'm-reel', 'm-promo']) {
    assert.equal(t.hidden(id), true, `${id} should be hidden`);
  }
  for (const id of ['d-video', 'd-news', 'd-grid-normal', 'd-sr-video', 'm-video', 'p-home', 'p-subs', 'g-home', 'g-fan', 'mg-subs']) {
    assert.equal(t.hidden(id), false, `${id} should stay visible`);
  }
});

test('navigation Shorts entries are hidden (desktop guide / mini guide by attribute, mobile pivot by text)', () => {
  const t = setup();
  assert.equal(t.hidden('g-shorts'), true);
  assert.equal(t.hidden('mg-shorts'), true);
  t.advance(0);   // 路由变化后的导航扫描（0ms 那一次）
  assert.equal(t.hidden('p-shorts'), true, 'pivot item without link is matched by its text');
  assert.equal(t.hidden('g-fan'), false, 'a channel whose name merely contains "Shorts" is not hidden');
});

test('pivot items added later are caught by the throttled nav observer (no document-wide observer)', async () => {
  const t = setup();
  t.advance(10000);
  const bar = t.w.document.querySelector('ytm-pivot-bar-renderer');
  const item = t.w.document.createElement('ytm-pivot-bar-item-renderer');
  item.id = 'p-late';
  item.appendChild(t.w.document.createTextNode(' Shorts '));
  bar.appendChild(item);
  await new Promise((r) => setImmediate(r));   // MutationObserver 回调（微任务）
  assert.equal(t.hidden('p-late'), false, 'debounced: not handled synchronously');
  t.advance(200);
  assert.equal(t.hidden('p-late'), true);
});

test('channel pages keep their Shorts (html.mio-channel-page) but nav entry stays hidden', () => {
  const t = setup({ url: 'https://www.youtube.com/@somecreator/shorts' });
  assert.equal(t.w.document.documentElement.classList.contains('mio-channel-page'), true);
  for (const id of ['d-short', 'd-shelf', 'd-reel', 'm-shelf', 'd-grid-shorts']) assert.equal(t.hidden(id), false, `${id} visible on channel page`);
  assert.equal(t.hidden('g-shorts'), true);
  t.go('/');
  assert.equal(t.w.document.documentElement.classList.contains('mio-channel-page'), false);
  assert.equal(t.hidden('d-short'), true);
});

test('apple-itunes-app meta is removed', () => {
  const t = setup();
  assert.equal(t.w.document.querySelector('meta[name="apple-itunes-app"]'), null);
});

test('entering /shorts/ reminds immediately, then every interval; leaving stops and resets', () => {
  const t = setup();
  assert.equal(t.reminders(), 0);
  t.go('/shorts/abc');
  assert.equal(t.reminders(), 1, 'immediate reminder');
  const pop = t.$('mio-shorts-reminder');
  assert.ok(pop.classList.contains('mio-show'));
  assert.equal(pop.getAttribute('role'), 'status');
  t.advance(4000);
  assert.equal(pop.classList.contains('mio-show'), false, 'capsule hides after 4s');
  t.advance(55000);
  assert.equal(t.reminders(), 1);
  t.go('/shorts/def');   // 刷到下一个短视频：仍在 Shorts，不重置
  t.advance(1000);
  assert.equal(t.reminders(), 2, 'second reminder at 60s');
  t.advance(60000);
  assert.equal(t.reminders(), 3);
  t.go('/watch?v=1');
  t.advance(10 * 60000);
  assert.equal(t.reminders(), 3, 'no reminders after leaving Shorts');
  t.go('/shorts/again');
  assert.equal(t.reminders(), 4, 'reset: re-entering reminds immediately');
  t.advance(30000);
  assert.equal(t.reminders(), 4, 'timer restarted from zero');
});

test('route detection also works through yt-navigate-finish and popstate', () => {
  const t = setup();
  t.dom.reconfigure({ url: 'https://m.youtube.com/shorts/x' });   // URL 变了但没有 pushState
  assert.equal(t.reminders(), 0);
  t.w.document.dispatchEvent(new t.w.Event('yt-navigate-finish'));
  assert.equal(t.reminders(), 1);
  t.dom.reconfigure({ url: 'https://m.youtube.com/' });
  t.w.dispatchEvent(new t.w.PopStateEvent('popstate'));
  t.advance(120000);
  assert.equal(t.reminders(), 1);
});

test('time only accumulates while the page is visible', () => {
  const t = setup();
  t.go('/shorts/abc');
  t.advance(30000);
  t.setVisible(false);
  t.advance(10 * 60000);
  assert.equal(t.reminders(), 1, 'paused while hidden');
  t.setVisible(true);
  t.advance(29000);
  assert.equal(t.reminders(), 1);
  t.advance(1000);
  assert.equal(t.reminders(), 2, '30s before + 30s after = 60s visible');
});

test('visibility is read even when background-playback fakes document.hidden and swallows visibilitychange', () => {
  const t = setup();
  const d = t.w.document;
  // 与 MioBrowser.backgroundPlaybackScripts 相同的处理（在本脚本之后注入）
  Object.defineProperty(d, 'visibilityState', { configurable: true, get: () => 'visible' });
  d.addEventListener('visibilitychange', (e) => e.stopImmediatePropagation(), true);
  t.go('/shorts/abc');
  t.advance(10000);
  t.setVisible(false);
  t.advance(5 * 60000);
  assert.equal(t.reminders(), 1);
});

test('custom interval from settings', () => {
  const t = setup({ interval: 30000 });
  t.go('/shorts/abc');
  t.advance(30000);
  assert.equal(t.reminders(), 2);
  assert.match(t.$('mio-shorts-reminder').textContent, /每 30 秒提醒一次/);
  const u = setup({ interval: 120000 });
  u.go('/shorts/abc');
  assert.match(u.$('mio-shorts-reminder').textContent, /每 2 分钟提醒一次/);
});

test('no innerHTML / HTML string sinks (Trusted Types)', () => {
  const t = setup({ trustedTypes: true });
  t.go('/shorts/abc');
  t.advance(60000);
  assert.deepEqual(t.sinks, []);
  const pop = t.$('mio-shorts-reminder');
  assert.equal(pop.querySelector('.mio-r-title').textContent, '已进入 Shorts 短视频区');
  assert.ok(pop.querySelector('svg circle'));
  assert.doesNotMatch(TEMPLATE, /innerHTML|outerHTML|insertAdjacentHTML|document\.write/);
});

test('capsule respects safe area, ignores pointer events, has a light-mode variant', () => {
  const css = setup().$('mio-yt-focus-style').textContent;
  assert.match(css, /top: calc\(env\(safe-area-inset-top, 0px\) \+ 12px\)/);
  assert.match(css, /pointer-events: none/);
  assert.match(css, /prefers-color-scheme: light/);
});

test('does nothing outside youtube.com or inside iframes, and only runs once', () => {
  const other = setup({ url: 'https://example.com/shorts/x' });
  assert.equal(other.$('mio-yt-focus-style'), null);
  assert.equal(other.reminders(), 0);
  const t = setup();
  t.w.eval(script());
  assert.equal(t.w.document.querySelectorAll('#mio-yt-focus-style').length, 1);
  const framed = new JSDOM('<iframe></iframe>', { url: 'https://www.youtube.com/', runScripts: 'outside-only' });
  const fw = framed.window.frames[0];
  fw.eval(script());
  assert.equal(fw.document.getElementById('mio-yt-focus-style'), null);
});

test('Mac smoke check script (youtubeFocusSmoke) sees the reminder and cleans up', () => {
  const t = setup({ url: 'https://www.youtube.com/' });
  const out = JSON.parse(t.w.eval(extractScript('youtubeFocusSmoke')));
  assert.equal(out.installed, true);
  assert.equal(out.style, true);
  assert.equal(out.reminder, true);
  assert.equal(out.count, 1);
  assert.equal(out.shown, true);
  assert.equal(out.hiddenAfterLeave, true);
  assert.equal(t.w.location.pathname, '/');
});
