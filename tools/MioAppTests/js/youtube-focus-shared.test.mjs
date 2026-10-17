// 共享防沉迷脚本（shared/scripts/youtube-focus.js）：
// - 与 iOS 内嵌的 MioWebCompat.youtubeFocusScriptTemplate 逐字一致（单一来源，防三端漂移）
// - 手机版 m.youtube.com 2026 组件：首页 Shorts 架子（ytm-shorts-lockup-view-model 等）、底部栏 Shorts（.pivot-shorts / 文本）
// - 游戏大本营（Playables）：首页 / 推荐区块和卡片、guide 入口隐藏；/playables 页面本身不受影响；子开关关掉时不隐藏
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { JSDOM } from 'jsdom';
import { extractScript } from './harness.mjs';

const SHARED = readFileSync(fileURLToPath(new URL('../../../shared/scripts/youtube-focus.js', import.meta.url)), 'utf8');
const render = ({ ms = 60000, playables = true } = {}) =>
  SHARED.replaceAll('__MIO_YT_INTERVAL_MS__', String(ms)).replaceAll('__MIO_YT_PLAYABLES__', playables ? '1' : '0');

test('shared/scripts/youtube-focus.js is byte-identical to the Swift-embedded template', () => {
  assert.equal(extractScript('youtubeFocus'), SHARED, 'run `node scripts/sync-shared-scripts.mjs`');
  assert.equal((SHARED.match(/__MIO_YT_INTERVAL_MS__/g) || []).length, 1);
  assert.equal((SHARED.match(/__MIO_YT_PLAYABLES__/g) || []).length, 1);
  assert.doesNotMatch(SHARED, /innerHTML|outerHTML|insertAdjacentHTML|document\.write/);
});

// 手机版首页（2026）：ytm-rich-section-renderer 里的 Shorts 架子（lockup 卡片没有 /shorts/ 链接也要隐藏）、
// 底部 pivot 栏（Shorts tab 是 div + 图标 + 标题，没有链接）、Playables 区块 / 卡片
const MOBILE = `<!doctype html><html><head></head><body><ytm-app>
<ytm-browse>
  <ytm-rich-grid-renderer>
    <ytm-rich-item-renderer id="m-video"><ytm-video-with-context-renderer><a href="/watch?v=v1">普通视频</a></ytm-video-with-context-renderer></ytm-rich-item-renderer>
    <ytm-rich-section-renderer id="m-shorts-shelf">
      <ytm-reel-shelf-renderer id="m-reel-inner"><div class="reel-shelf-title">Shorts</div>
        <ytm-shorts-lockup-view-model id="m-lockup1"><div class="shortsLockupViewModelHostThumbnail"></div></ytm-shorts-lockup-view-model>
      </ytm-reel-shelf-renderer>
    </ytm-rich-section-renderer>
    <ytm-rich-section-renderer id="m-shorts-grid">
      <grid-shelf-view-model id="m-grid"><ytm-shorts-lockup-view-model-v2 id="m-lockup2"></ytm-shorts-lockup-view-model-v2></grid-shelf-view-model>
    </ytm-rich-section-renderer>
    <ytm-rich-item-renderer id="m-short-card"><ytm-shorts-lockup-view-model></ytm-shorts-lockup-view-model></ytm-rich-item-renderer>
    <ytm-rich-section-renderer id="m-news"><ytm-shelf-renderer><a href="/watch?v=n1">新闻</a></ytm-shelf-renderer></ytm-rich-section-renderer>
    <ytm-rich-section-renderer id="m-play-shelf"><ytm-shelf-renderer><a href="/playables">游戏大本营</a><mini-game-card-view-model id="m-game"></mini-game-card-view-model></ytm-shelf-renderer></ytm-rich-section-renderer>
    <ytm-rich-item-renderer id="m-play-card"><a href="/playables/abc">小游戏</a></ytm-rich-item-renderer>
    <ytm-rich-item-renderer id="m-play-abs"><a href="https://m.youtube.com/playables/x">小游戏</a></ytm-rich-item-renderer>
  </ytm-rich-grid-renderer>
</ytm-browse>
<ytm-pivot-bar-renderer>
  <ytm-pivot-bar-item-renderer id="p-home"><div class="pivot-bar-item-tab pivot-w2w" role="tab" aria-label="首页"><c3-icon></c3-icon><div class="pivot-bar-item-title">首页</div></div></ytm-pivot-bar-item-renderer>
  <ytm-pivot-bar-item-renderer id="p-shorts-class"><div class="pivot-bar-item-tab pivot-shorts" role="tab"><c3-icon aria-label="图标"></c3-icon><div class="pivot-bar-item-title">短视频</div></div></ytm-pivot-bar-item-renderer>
  <ytm-pivot-bar-item-renderer id="p-shorts-text"><div class="pivot-bar-item-tab" role="tab" aria-label="首页附近"><c3-icon></c3-icon><div class="pivot-bar-item-title">Shorts</div><span class="badge">new</span></div></ytm-pivot-bar-item-renderer>
  <ytm-pivot-bar-item-renderer id="p-shorts-aria"><div class="pivot-bar-item-tab" role="tab"><c3-icon title="x"></c3-icon><span aria-label="Shorts 短视频"></span></div></ytm-pivot-bar-item-renderer>
  <ytm-pivot-bar-item-renderer id="p-subs"><div class="pivot-bar-item-tab pivot-subs" role="tab"><div class="pivot-bar-item-title">订阅</div></div></ytm-pivot-bar-item-renderer>
  <ytm-pivot-bar-item-renderer id="p-you"><div class="pivot-bar-item-tab" role="tab"><div class="pivot-bar-item-title">我的</div></div></ytm-pivot-bar-item-renderer>
</ytm-pivot-bar-renderer>
</ytm-app></body></html>`;

const DESKTOP = `<!doctype html><html><head></head><body><ytd-app>
<ytd-guide-renderer>
  <ytd-guide-entry-renderer id="g-home"><a id="endpoint" href="/" title="首页">首页</a></ytd-guide-entry-renderer>
  <ytd-guide-entry-renderer id="g-play"><a id="endpoint" href="/playables" title="Playables">Playables</a></ytd-guide-entry-renderer>
  <ytd-guide-entry-renderer id="g-gaming"><a id="endpoint" href="/gaming" title="游戏">游戏</a></ytd-guide-entry-renderer>
</ytd-guide-renderer>
<ytd-rich-grid-renderer>
  <ytd-rich-item-renderer id="d-video"><a id="thumbnail" href="/watch?v=a"></a></ytd-rich-item-renderer>
  <ytd-rich-section-renderer id="d-play-section"><ytd-rich-shelf-renderer id="d-play-shelf"><a href="/playables">YouTube Playables</a><mini-game-card-view-model></mini-game-card-view-model></ytd-rich-shelf-renderer></ytd-rich-section-renderer>
  <ytd-rich-item-renderer id="d-play-item"><a href="/playables/game1"></a></ytd-rich-item-renderer>
  <ytd-rich-item-renderer id="d-game-only"><mini-game-card-view-model id="d-game-card"></mini-game-card-view-model></ytd-rich-item-renderer>
  <ytd-rich-section-renderer id="d-shorts-lockup"><ytm-shorts-lockup-view-model></ytm-shorts-lockup-view-model></ytd-rich-section-renderer>
  <ytd-rich-section-renderer id="d-normal"><ytd-rich-shelf-renderer><a href="/watch?v=n"></a></ytd-rich-shelf-renderer></ytd-rich-section-renderer>
</ytd-rich-grid-renderer>
<ytd-browse id="playables-page"><mini-game-card-view-model id="pp-card"></mini-game-card-view-model><ytd-rich-item-renderer id="pp-item"><a href="/playables/g2"></a></ytd-rich-item-renderer></ytd-browse>
</ytd-app></body></html>`;

function setup({ url = 'https://m.youtube.com/', html = MOBILE, playables = true } = {}) {
  const dom = new JSDOM(html, { url, runScripts: 'outside-only', pretendToBeVisual: true });
  const w = dom.window;
  const timers = new Map();
  let id = 1;
  w.setTimeout = (fn) => { const i = id++; timers.set(i, fn); return i; };
  w.clearTimeout = (i) => timers.delete(i);
  const flush = () => { for (let n = 0; n < 5 && timers.size; n++) { const fns = [...timers.values()]; timers.clear(); fns.forEach((f) => f()); } };
  w.eval(render({ playables }));
  const $ = (x) => w.document.getElementById(x);
  const hidden = (x) => w.getComputedStyle($(x)).display === 'none';
  return { w, $, hidden, flush, go: (p) => w.history.pushState({}, '', p) };
}

test('m.youtube.com home (2026): Shorts shelves / lockups hidden, normal content stays', () => {
  const t = setup();
  assert.equal(t.w.__mioYTFocus, true);
  assert.ok(t.$('mio-yt-focus-style'));
  for (const id of ['m-shorts-shelf', 'm-reel-inner', 'm-lockup1', 'm-shorts-grid', 'm-grid', 'm-lockup2', 'm-short-card']) {
    assert.equal(t.hidden(id), true, `${id} should be hidden`);
  }
  for (const id of ['m-video', 'm-news']) assert.equal(t.hidden(id), false, `${id} should stay`);
});

test('m.youtube.com bottom bar: Shorts tab hidden by .pivot-shorts, by text and by aria-label; other tabs stay', () => {
  const t = setup();
  t.flush();
  for (const id of ['p-shorts-class', 'p-shorts-text', 'p-shorts-aria']) assert.equal(t.hidden(id), true, `${id} should be hidden`);
  for (const id of ['p-home', 'p-subs', 'p-you']) assert.equal(t.hidden(id), false, `${id} should stay`);
});

test('channel page keeps mobile Shorts shelves', () => {
  const t = setup({ url: 'https://m.youtube.com/@creator/shorts' });
  for (const id of ['m-shorts-shelf', 'm-lockup1', 'm-short-card', 'm-grid']) assert.equal(t.hidden(id), false, `${id} visible on channel page`);
  t.flush();
  assert.equal(t.hidden('p-shorts-text'), true, 'nav entry still hidden');
});

test('Playables: home shelves / cards (relative + absolute links, mini-game cards) hidden on mobile', () => {
  const t = setup();
  assert.ok(t.w.document.documentElement.classList.contains('mio-hide-playables'));
  for (const id of ['m-play-shelf', 'm-game', 'm-play-card', 'm-play-abs']) assert.equal(t.hidden(id), true, `${id} should be hidden`);
  assert.equal(t.hidden('m-video'), false);
});

test('Playables: desktop sections / shelves / items and guide entry hidden; other guide entries stay', () => {
  const t = setup({ url: 'https://www.youtube.com/', html: DESKTOP });
  for (const id of ['d-play-section', 'd-play-shelf', 'd-play-item', 'd-game-only', 'd-game-card', 'g-play', 'd-shorts-lockup']) {
    assert.equal(t.hidden(id), true, `${id} should be hidden`);
  }
  for (const id of ['d-video', 'd-normal', 'g-home', 'g-gaming']) assert.equal(t.hidden(id), false, `${id} should stay`);
});

test('Playables: visiting /playables itself is not blocked; leaving restores hiding', () => {
  const t = setup({ url: 'https://www.youtube.com/playables', html: DESKTOP });
  assert.ok(t.w.document.documentElement.classList.contains('mio-playables-page'));
  for (const id of ['pp-card', 'pp-item', 'd-play-item']) assert.equal(t.hidden(id), false, `${id} visible on /playables`);
  t.go('/playables/some-game');
  assert.equal(t.hidden('pp-card'), false);
  t.go('/');
  assert.equal(t.hidden('pp-card'), true);
  assert.equal(t.hidden('d-play-item'), true);
});

test('Playables sub-switch off: nothing Playables-related is hidden, Shorts still are', () => {
  const t = setup({ playables: false });
  assert.equal(t.w.document.documentElement.classList.contains('mio-hide-playables'), false);
  for (const id of ['m-play-shelf', 'm-game', 'm-play-card']) assert.equal(t.hidden(id), false, `${id} should stay`);
  assert.equal(t.hidden('m-shorts-shelf'), true);
  const d = setup({ url: 'https://www.youtube.com/', html: DESKTOP, playables: false });
  assert.equal(d.hidden('g-play'), false);
});

test('each hide selector is its own rule (old WebView without :has only drops those rules)', () => {
  const t = setup();
  const sheet = t.$('mio-yt-focus-style').sheet;
  const hideRules = [...sheet.cssRules].filter((r) => /display: none/.test(r.cssText));
  assert.ok(hideRules.length > 40, `got ${hideRules.length}`);
  for (const r of hideRules) assert.doesNotMatch(r.selectorText, /,/, r.selectorText);
});
