// YouTube 媒体脚本（MioMediaScripts.youtubeMediaScriptTemplate）：
// SponsorBlock（videoID 解析、哈希前缀匹配、跳过 / 撤销 / 手动 seek）、后台自动续播、MediaSession、画中画按钮、Trusted Types。
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash, webcrypto } from 'node:crypto';
import { JSDOM } from 'jsdom';
import { mediaScript, mediaConfig, extractMediaScript } from './media-harness.mjs';

const PAGE = `<!doctype html><html><head></head><body>
<ytd-app><div id="movie_player" class="html5-video-player"><video class="html5-main-video"></video>
<div class="ytp-progress-bar-container"><div class="ytp-progress-bar"></div></div></div>
<ytd-watch-metadata><h1>Never Gonna Give You Up</h1><ytd-channel-name><a>Rick Astley</a></ytd-channel-name></ytd-watch-metadata></ytd-app>
</body></html>`;

const ID = 'dQw4w9WgXcQ';
const plain = (x) => JSON.parse(JSON.stringify(x));   // jsdom 里的数组属于另一个 realm
const sha = (s) => createHash('sha256').update(s).digest('hex');

function sbResponse(id = ID, extra = []) {
  return [
    { videoID: 'aaaaaaaaaaa', segments: [{ category: 'sponsor', actionType: 'skip', segment: [1, 2], UUID: 'other' }] },
    {
      videoID: id,
      segments: [
        { category: 'sponsor', actionType: 'skip', segment: [10, 20], UUID: 's1', videoDuration: 212 },
        { category: 'intro', actionType: 'skip', segment: [0, 5], UUID: 'i1' },            // 分类没开
        { category: 'selfpromo', actionType: 'mute', segment: [30, 40], UUID: 'm1' },      // 不是 skip
        { category: 'interaction', actionType: 'skip', segment: [100, 110], UUID: 'x1' },
        { category: 'sponsor', actionType: 'skip', segment: [50, 50.2], UUID: 'tiny' },    // 太短
        ...extra,
      ],
    },
  ];
}

function setup({ url = `https://www.youtube.com/watch?v=${ID}`, cfg = mediaConfig(), html = PAGE, fetchImpl, mediaSession = true, pip = 'webkit', trustedTypes = true } = {}) {
  const dom = new JSDOM(html, { url, runScripts: 'outside-only', pretendToBeVisual: true });
  const w = dom.window;
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
  Object.defineProperty(w, 'crypto', { configurable: true, value: webcrypto });
  w.TextEncoder = TextEncoder;
  let vis = 'visible';
  Object.defineProperty(w.Document.prototype, 'visibilityState', { configurable: true, get: () => vis });
  const setHidden = (h) => { vis = h ? 'hidden' : 'visible'; };

  const fetches = [];
  w.fetch = (u, opts) => {
    fetches.push({ url: String(u), opts });
    if (fetchImpl) return fetchImpl(String(u));
    return Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve(sbResponse()) });
  };

  // 媒体会话
  const handlers = {};
  if (mediaSession) {
    w.navigator.mediaSession = {
      metadata: null,
      setActionHandler(a, h) { handlers[a] = h; },
      setPositionState(s) { this.position = s; },
    };
    w.MediaMetadata = class { constructor(o) { Object.assign(this, o); } };
  }

  // 假 video
  const v = w.document.querySelector('video');
  const vs = { currentTime: 0, paused: true, duration: 212, ended: false, playbackRate: 1, plays: 0, pauses: 0, mode: 'inline', modes: [] };
  Object.defineProperty(v, 'currentTime', { configurable: true, get: () => vs.currentTime, set: (t) => { vs.currentTime = t; vs.seeks = (vs.seeks || []).concat(t); } });
  for (const k of ['paused', 'duration', 'ended', 'playbackRate']) Object.defineProperty(v, k, { configurable: true, get: () => vs[k] });
  v.play = () => { vs.plays++; vs.paused = false; return Promise.resolve(); };
  v.pause = () => { vs.pauses++; vs.paused = true; };
  if (pip === 'webkit') {
    v.webkitSupportsPresentationMode = (m) => m === 'picture-in-picture';
    v.webkitSetPresentationMode = (m) => { vs.modes.push(m); vs.mode = m; };
    Object.defineProperty(v, 'webkitPresentationMode', { configurable: true, get: () => vs.mode });
  }
  const fire = (type, target = v) => target.dispatchEvent(new w.Event(type));

  // 模拟 YouTube 的 Trusted Types：HTML 字符串 sink 抛错
  const sinks = [];
  if (trustedTypes) {
    const boom = (name) => function () { sinks.push(name); throw new w.TypeError(`requires TrustedHTML (${name})`); };
    Object.defineProperty(w.Element.prototype, 'innerHTML', { configurable: true, get() { return ''; }, set: boom('innerHTML') });
    Object.defineProperty(w.Element.prototype, 'outerHTML', { configurable: true, get() { return ''; }, set: boom('outerHTML') });
    w.Element.prototype.insertAdjacentHTML = boom('insertAdjacentHTML');
  }

  w.eval(mediaScript(cfg));
  const flush = async () => { for (let i = 0; i < 5; i++) { await new Promise((r) => setTimeout(r, 5)); await new Promise((r) => setImmediate(r)); } };
  return { dom, w, d: w.document, v, vs, fire, advance, flush, fetches, handlers, setHidden, sinks, api: w.__mioMedia };
}

// ------------------------------------------------------------------ 纯逻辑

test('parseVideoId: watch / youtu.be / shorts / embed / live / m. / music. and rejects junk', () => {
  const { api } = setup();
  const p = api.lib.parseVideoId;
  assert.equal(p(`https://www.youtube.com/watch?v=${ID}`), ID);
  assert.equal(p(`https://m.youtube.com/watch?feature=share&v=${ID}&t=42s`), ID);
  assert.equal(p(`https://music.youtube.com/watch?v=${ID}&list=RD`), ID);
  assert.equal(p(`https://youtu.be/${ID}?si=abc`), ID);
  assert.equal(p(`https://www.youtube.com/shorts/${ID}`), ID);
  assert.equal(p(`https://www.youtube.com/embed/${ID}?autoplay=1`), ID);
  assert.equal(p(`https://www.youtube-nocookie.com/embed/${ID}`), ID);
  assert.equal(p(`https://www.youtube.com/live/${ID}`), ID);
  assert.equal(p(`/watch?v=${ID}`), ID);   // 相对地址（站内）
  assert.equal(p('https://www.youtube.com/watch?v=short'), null);
  assert.equal(p('https://www.youtube.com/watch?v=dQw4w9WgXcQ!'), null);
  assert.equal(p('https://www.youtube.com/@channel'), null);
  assert.equal(p('https://www.youtube.com/feed/subscriptions'), null);
  assert.equal(p(`https://evil.example/watch?v=${ID}`), null);
  assert.equal(p(`https://notyoutube.com/watch?v=${ID}`), null);
  assert.equal(p('::::'), null);
});

test('hashPrefix = first 4 hex chars of SHA-256(videoID); request URL carries only the prefix', async () => {
  const { api } = setup();
  assert.equal(await api.lib.hashPrefix(ID), sha(ID).slice(0, 4));
  assert.equal(await api.lib.sha256Hex('abc'), sha('abc'));
  const url = api.lib.segmentsUrl('5f6b', ['sponsor', 'selfpromo']);
  assert.equal(url, 'https://sponsor.ajay.app/api/skipSegments/5f6b?categories=%5B%22sponsor%22%2C%22selfpromo%22%5D&actionTypes=%5B%22skip%22%5D');
  assert.ok(!url.includes(ID));
});

test('pickSegments: exact videoID match among hash-prefix results, enabled categories, skip only, sorted, drops tiny', () => {
  const { api } = setup();
  const segs = api.lib.pickSegments(sbResponse(), ID, ['sponsor', 'selfpromo', 'interaction']);
  assert.deepEqual(plain(segs.map((s) => [s.start, s.end, s.category])), [[10, 20, 'sponsor'], [100, 110, 'interaction']]);
  assert.deepEqual(plain(api.lib.pickSegments(sbResponse(), 'zzzzzzzzzzz', ['sponsor'])), []);
  assert.deepEqual(plain(api.lib.pickSegments(sbResponse(), ID, ['intro']).map((s) => s.category)), ['intro']);
  assert.deepEqual(plain(api.lib.pickSegments({ nope: 1 }, ID, ['sponsor'])), []);
  assert.deepEqual(plain(api.lib.normalizeCategories(['sponsor', 'bogus', 'sponsor', 'outro'])), ['sponsor', 'outro']);
});

test('SkipController: auto-skip, undo disarms, manual seek into segment disarms, seek before keeps armed, own seeks ignored', () => {
  const { api } = setup();
  const C = api.lib.SkipController;
  let c = new C([{ start: 10, end: 20, category: 'sponsor' }, { start: 100, end: 110, category: 'interaction' }]);
  assert.equal(c.check(5), null);
  const s = c.check(10.1);
  assert.equal(s.end, 20);
  assert.equal(c.check(10.3), null, 'no double skip while our seek is pending');
  assert.equal(c.seeking(20), 'self');
  assert.equal(c.check(20.2), null);
  // 撤销：回到跳过前的位置，之后不再自动跳
  assert.equal(c.undo(), 10.1);
  assert.equal(c.seeking(10.1), 'self');
  assert.equal(c.check(10.5), null);
  assert.equal(c.check(15), null);
  assert.equal(c.undo(), null, 'nothing left to undo');
  // 手动 seek 进第二个片段内部 → 不跳
  assert.equal(c.seeking(104), 'manual-in-segment');
  assert.equal(c.check(104.2), null);
  // 新控制器：手动 seek 到片段之前，播放到片段仍会跳
  c = new C([{ start: 10, end: 20, category: 'sponsor' }]);
  assert.equal(c.seeking(3), 'manual');
  assert.ok(c.check(10.05));
  // 片段末尾 0.25 秒内不再跳（避免卡在结尾来回跳）
  c = new C([{ start: 10, end: 20, category: 'sponsor' }]);
  assert.equal(c.check(19.9), null);
});

test('shouldResume: only when really hidden / just backgrounded, not after a user pause, not when ended or in PiP', () => {
  const { api } = setup();
  const r = api.lib.shouldResume;
  const base = { ended: false, hidden: true, pip: false, sinceUserPause: null, sincePlaying: 100, sinceBackground: null };
  assert.equal(r(base), true);
  assert.equal(r({ ...base, hidden: false }), false);
  assert.equal(r({ ...base, hidden: false, sinceBackground: 300 }), true);
  assert.equal(r({ ...base, sinceUserPause: 200 }), false);
  assert.equal(r({ ...base, sinceUserPause: 5000 }), true);
  assert.equal(r({ ...base, ended: true }), false);
  assert.equal(r({ ...base, pip: true }), false);
  assert.equal(r({ ...base, sincePlaying: null }), false);
  assert.equal(r({ ...base, sincePlaying: 10_000 }), false);
});

// ------------------------------------------------------------------ 页面集成

test('SponsorBlock end-to-end: fetch by hash prefix, markers on progress bar, skip with toast, undo seeks back and never re-skips', async () => {
  const t = setup();
  t.fire('loadedmetadata');
  await t.flush();
  assert.equal(t.fetches.length, 1);
  assert.ok(t.fetches[0].url.startsWith(`https://sponsor.ajay.app/api/skipSegments/${sha(ID).slice(0, 4)}?`));
  assert.ok(!t.fetches[0].url.includes(ID));
  assert.equal(t.fetches[0].opts.credentials, 'omit');
  assert.equal(t.api.state.videoId, ID);
  assert.equal(t.api.state.segments.length, 2);
  const m = t.d.querySelector('.ytp-progress-bar .mio-sb-markers');
  assert.ok(m, 'markers rendered');
  assert.equal(m.children.length, 2);
  assert.equal(m.children[0].style.left, (100 * 10 / 212).toFixed(3) + '%');

  // 播放进入片段 → 跳到结尾
  t.vs.paused = false;
  t.vs.currentTime = 10.4;
  t.fire('timeupdate');
  assert.equal(t.vs.currentTime, 20);
  assert.equal(t.api.state.skips, 1);
  t.fire('seeking');
  const toast = t.d.getElementById('mio-sb-toast');
  assert.ok(toast.classList.contains('mio-show'));
  assert.match(toast.textContent, /已跳过赞助广告（0:10–0:20）/);
  const undo = toast.querySelector('button');
  assert.equal(undo.textContent, '撤销');
  undo.click();
  assert.equal(t.vs.currentTime, 10.4);
  t.fire('seeking');
  assert.ok(!toast.classList.contains('mio-show'));
  t.vs.currentTime = 11;
  t.fire('timeupdate');
  assert.equal(t.vs.currentTime, 11, 'not skipped again after undo');
  // toast 5 秒后自动消失
  t.vs.currentTime = 100.5;
  t.fire('timeupdate');
  assert.equal(t.vs.currentTime, 110);
  assert.ok(toast.classList.contains('mio-show'));
  t.advance(5001);
  assert.ok(!toast.classList.contains('mio-show'));
  assert.deepEqual(t.sinks, [], 'no HTML string sinks (Trusted Types)');
});

test('manual seek back into a skipped segment is respected', async () => {
  const t = setup();
  t.fire('loadedmetadata');
  await t.flush();
  t.vs.paused = false;
  t.vs.currentTime = 10.2;
  t.fire('timeupdate');
  t.fire('seeking');          // 我们自己的 seek（到 20）
  assert.equal(t.vs.currentTime, 20);
  t.vs.currentTime = 12;      // 用户拖回片段里
  t.fire('seeking');
  t.fire('timeupdate');
  assert.equal(t.vs.currentTime, 12);
  t.vs.currentTime = 15;
  t.fire('timeupdate');
  assert.equal(t.vs.currentTime, 15);
});

test('SponsorBlock disabled or no categories → no request; 404 → no segments; navigation switches video', async () => {
  let t = setup({ cfg: mediaConfig({ sponsorBlock: false }) });
  t.fire('loadedmetadata');
  await t.flush();
  assert.equal(t.fetches.length, 0);
  t = setup({ cfg: mediaConfig({ categories: [] }) });
  t.fire('loadedmetadata');
  await t.flush();
  assert.equal(t.fetches.length, 0);

  t = setup({ fetchImpl: () => Promise.resolve({ ok: false, status: 404, json: () => Promise.reject(new Error('x')) }) });
  t.fire('loadedmetadata');
  await t.flush();
  assert.equal(t.fetches.length, 1);
  assert.deepEqual(plain(t.api.state.segments), []);
  assert.equal(t.api.state.sbError, null);

  const other = 'bbbbbbbbbbb';
  t = setup({ fetchImpl: () => Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve(sbResponse(other)) }) });
  t.fire('loadedmetadata');
  await t.flush();
  assert.equal(t.api.state.segments.length, 0, 'prefix results for other videos are ignored');
  t.w.history.pushState({}, '', `/watch?v=${other}`);
  t.d.dispatchEvent(new t.w.Event('yt-navigate-finish'));
  await t.flush();
  assert.equal(t.api.state.videoId, other);
  assert.equal(t.api.state.segments.length, 2);
  assert.equal(t.fetches.length, 2);
});

test('fetch failure falls back to the iOS native bridge (allowlisted on the native side)', async () => {
  const calls = [];
  const t = setup({ fetchImpl: () => Promise.reject(new TypeError('Load failed')) });
  // 脚本在注入时取桥；这里在之后挂上也能用（每次调用时再取）
  t.w.webkit = { messageHandlers: { mioMedia: { postMessage: (m) => { calls.push(m); return m.type === 'sbFetch' ? Promise.resolve(JSON.stringify(sbResponse())) : Promise.resolve(null); } } } };
  t.fire('loadedmetadata');
  await t.flush();
  const sb = calls.filter((c) => c.type === 'sbFetch');
  assert.equal(sb.length, 1);
  assert.ok(sb[0].url.startsWith('https://sponsor.ajay.app/api/skipSegments/'));
  assert.equal(t.api.state.segments.length, 2);
});

test('background playback: resumes when WebKit pauses a hidden page, never after user / lock-screen pause or in PiP', () => {
  const t = setup();
  t.vs.paused = false;
  t.fire('playing');
  t.fire('timeupdate');
  // 前台暂停（用户点的）：不续播
  t.vs.paused = true;
  t.fire('pause');
  t.advance(3000);
  assert.equal(t.vs.plays, 0);

  // 切到后台，系统把视频停了 → 续播
  t.vs.paused = false;
  t.fire('playing');
  t.fire('timeupdate');
  t.setHidden(true);
  t.vs.paused = true;
  t.fire('pause');
  t.advance(300);
  assert.equal(t.vs.plays, 1);
  assert.equal(t.vs.paused, false);
  assert.equal(t.api.state.resumes, 1);

  // 锁屏「暂停」走 MediaSession → 记为用户意图 → 不续播
  t.fire('timeupdate');
  t.handlers.pause({ action: 'pause' });
  assert.equal(t.vs.pauses, 1);
  t.fire('pause');
  t.advance(3000);
  assert.equal(t.vs.plays, 1);

  // 锁屏「播放」恢复
  t.handlers.play({ action: 'play' });
  assert.equal(t.vs.plays, 2);

  // 耳机拔出 / 来电：原生调 userIntent → 不续播
  t.fire('timeupdate');
  t.api.userIntent('route');
  t.vs.paused = true;
  t.fire('pause');
  t.advance(3000);
  assert.equal(t.vs.plays, 2);

  // 画中画里点暂停 → 不续播
  t.advance(5000);
  t.vs.paused = false;
  t.fire('timeupdate');
  t.vs.mode = 'picture-in-picture';
  t.vs.paused = true;
  t.fire('pause');
  t.advance(3000);
  assert.equal(t.vs.plays, 2);
});

test('appState(background) from native re-plays if WebKit paused before visibility flipped', () => {
  const t = setup();
  t.vs.paused = false;
  t.fire('playing');
  t.api.appState('background');
  t.vs.paused = true;           // WebKit 暂停但页面还没变成 hidden
  t.advance(1000);
  assert.equal(t.vs.plays, 1);
  t.api.appState('foreground');
  t.vs.paused = true;
  t.advance(3000);
  assert.equal(t.vs.plays, 1);
});

test('background disabled → never auto-resumes', () => {
  const t = setup({ cfg: mediaConfig({ background: false }) });
  t.vs.paused = false;
  t.fire('playing');
  t.fire('timeupdate');
  t.setHidden(true);
  t.vs.paused = true;
  t.fire('pause');
  t.advance(3000);
  assert.equal(t.vs.plays, 0);
});

test('MediaSession: metadata from the watch page, page handlers wrapped (still called), defaults for next / seek, native commands', () => {
  const t = setup();
  const posts = [];
  t.w.webkit = { messageHandlers: { mioMedia: { postMessage: (m) => { posts.push(m); return Promise.resolve(null); } } } };
  t.vs.paused = false;
  t.fire('playing');
  const md = t.w.navigator.mediaSession.metadata;
  assert.equal(md.title, 'Never Gonna Give You Up');
  assert.equal(md.artist, 'Rick Astley');
  assert.equal(md.artwork[0].src, `https://i.ytimg.com/vi/${ID}/hqdefault.jpg`);
  const st = posts.find((p) => p.type === 'state');
  assert.equal(st.playing, true);
  assert.equal(st.hasMediaSession, true);
  assert.equal(st.videoId, ID);
  for (const a of ['play', 'pause', 'nexttrack', 'previoustrack', 'seekto']) assert.equal(typeof t.handlers[a], 'function', a);

  // YouTube 自己设 pause 处理器：仍然被调用（我们的包装先记用户意图）
  let pagePause = 0;
  t.w.navigator.mediaSession.setActionHandler('pause', () => { pagePause++; });
  t.handlers.pause({ action: 'pause' });
  assert.equal(pagePause, 1);
  assert.equal(t.vs.pauses, 0, 'page handler replaces default');

  // 默认 next：player.nextVideo()
  let nexts = 0;
  t.d.getElementById('movie_player').nextVideo = () => { nexts++; };
  assert.equal(t.api.command('next'), true);
  assert.equal(nexts, 1);
  t.api.command('seek', 42);
  assert.equal(t.vs.currentTime, 42);
  t.vs.paused = false;
  t.api.command('toggle');
  assert.equal(pagePause, 2);
  assert.equal(t.api.command('bogus'), false);
});

test('nowPlaying disabled → no metadata and mediaSession handlers untouched', () => {
  const t = setup({ cfg: mediaConfig({ nowPlaying: false }) });
  t.vs.paused = false;
  t.fire('playing');
  assert.equal(t.w.navigator.mediaSession.metadata, null);
  assert.equal(Object.keys(t.handlers).length, 0);
});

test('PiP button: added to the player when supported, toggles webkit presentation mode, hidden when disabled / unsupported', () => {
  let t = setup();
  t.vs.paused = false;
  t.fire('playing');
  const b = t.d.getElementById('mio-pip-btn');
  assert.ok(b);
  assert.equal(b.parentNode.id, 'movie_player');
  assert.equal(b.getAttribute('aria-label'), '画中画');
  t.d.getElementById('movie_player').dispatchEvent(new t.w.Event('mousemove'));
  assert.ok(b.classList.contains('mio-on'));
  t.advance(3100);
  assert.ok(!b.classList.contains('mio-on'));
  b.click();
  assert.deepEqual(t.vs.modes, ['picture-in-picture']);
  b.click();
  assert.deepEqual(t.vs.modes, ['picture-in-picture', 'inline']);
  assert.deepEqual(t.sinks, []);

  t = setup({ cfg: mediaConfig({ pip: false }) });
  t.fire('playing');
  assert.equal(t.d.getElementById('mio-pip-btn'), null);
  t = setup({ pip: 'none' });
  t.vs.paused = false;
  t.fire('playing');
  assert.equal(t.d.getElementById('mio-pip-btn'), null);
});

test('only runs on *.youtube.com top frame, installs once', () => {
  let t = setup({ url: 'https://example.com/watch?v=dQw4w9WgXcQ' });
  assert.equal(t.api, undefined);
  t = setup();
  const first = t.w.__mioMedia;
  t.w.eval(mediaScript());
  assert.equal(t.w.__mioMedia, first);
});

test('template has exactly one config placeholder and no innerHTML', () => {
  const src = extractMediaScript('youtubeMedia');
  assert.equal(src.split('__MIO_MEDIA_CONFIG__').length, 2);
  assert.ok(!/innerHTML|outerHTML|insertAdjacentHTML|document\.write/.test(src));
});
