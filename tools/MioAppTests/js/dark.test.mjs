// 强制深色（www/mio-browser/dark.js）：按站点 / 全局开关解析、颜色解析、「网站自己是不是深色」判断，
// 以及在 jsdom 里注入：document-start 就反色（不闪白）、DOMContentLoaded 后发现页面自带深色就撤掉反色并上报。
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { JSDOM, VirtualConsole } from 'jsdom';

const require = createRequire(import.meta.url);
const DARK_PATH = new URL('../../../www/mio-browser/dark.js', import.meta.url);
const MioDark = require(DARK_PATH.pathname);
const SRC = readFileSync(DARK_PATH, 'utf8');

test('resolveEnabled: per-site beats global, parent domains, www stripped', () => {
  const cfg = { global: false, sites: { 'example.com': true, 'news.example.com': false, 'dark.test': true } };
  assert.equal(MioDark.resolveEnabled('example.com', cfg), true);
  assert.equal(MioDark.resolveEnabled('www.example.com', cfg), true);
  assert.equal(MioDark.resolveEnabled('blog.example.com', cfg), true);
  assert.equal(MioDark.resolveEnabled('news.example.com', cfg), false);
  assert.equal(MioDark.resolveEnabled('a.news.example.com', cfg), false);
  assert.equal(MioDark.resolveEnabled('other.org', cfg), false);
  assert.equal(MioDark.resolveEnabled('other.org', { ...cfg, global: true }), true);
  assert.equal(MioDark.resolveEnabled('news.example.com', { ...cfg, global: true }), false, 'site off overrides global on');
  assert.equal(MioDark.resolveEnabled('', { global: true }), true);
  assert.equal(MioDark.resolveEnabled('x.com', undefined), false);
});

test('parseColor / luminance', () => {
  assert.deepEqual(MioDark.parseColor('rgb(255, 255, 255)'), { r: 255, g: 255, b: 255, a: 1 });
  assert.deepEqual(MioDark.parseColor('rgba(0, 0, 0, 0)'), { r: 0, g: 0, b: 0, a: 0 });
  assert.deepEqual(MioDark.parseColor('rgb(10 20 30 / 50%)'), { r: 10, g: 20, b: 30, a: 0.5 });
  assert.deepEqual(MioDark.parseColor('#0a0a0a'), { r: 10, g: 10, b: 10, a: 1 });
  assert.deepEqual(MioDark.parseColor('#fff'), { r: 255, g: 255, b: 255, a: 1 });
  assert.equal(MioDark.parseColor('transparent').a, 0);
  assert.ok(MioDark.luminance(MioDark.parseColor('#fff')) > 0.99);
  assert.ok(MioDark.luminance(MioDark.parseColor('#121212')) < 0.01);
});

test('decide: respects sites that are already dark, inverts light ones', () => {
  // 白底 → 反色
  assert.equal(MioDark.decide({ bodyBg: 'rgb(255, 255, 255)', htmlBg: 'rgba(0, 0, 0, 0)' }), 'invert');
  // 什么背景都没有（浏览器默认白画布）→ 反色
  assert.equal(MioDark.decide({ bodyBg: 'rgba(0, 0, 0, 0)', htmlBg: 'rgba(0, 0, 0, 0)', textColor: 'rgb(0, 0, 0)' }), 'invert');
  // 网站自带深色（prefers-color-scheme: dark 生效后 body 是深色）→ 不动
  assert.equal(MioDark.decide({ bodyBg: 'rgb(13, 17, 23)' }), 'native');
  // body 透明、背景在 #app 上（视口中心探测）
  assert.equal(MioDark.decide({ probeBg: 'rgba(24,24,27,1)', bodyBg: 'rgba(0,0,0,0)', htmlBg: 'rgb(255,255,255)' }), 'native');
  assert.equal(MioDark.decide({ probeBg: 'rgba(250,250,250,1)', bodyBg: 'rgb(0,0,0)' }), 'invert', 'probe wins over body');
  // 只声明了 color-scheme（没写背景色），系统是深色 → 画布已经是深色
  assert.equal(MioDark.decide({ colorScheme: 'light dark', prefersDark: true }), 'native');
  assert.equal(MioDark.decide({ colorScheme: 'light dark', prefersDark: false }), 'invert');
  assert.equal(MioDark.decide({ metaColorScheme: 'dark' }), 'native');
  // 背景是图片、文字是浅色 → 深色设计
  assert.equal(MioDark.decide({ textColor: 'rgb(240, 240, 240)' }), 'native');
  // 中灰：按亮度
  assert.equal(MioDark.decide({ bodyBg: 'rgb(128,128,128)' }), 'invert');
  assert.equal(MioDark.decide({ bodyBg: 'rgb(40,40,40)' }), 'native');
});

function page(html, { url = 'https://light.example/', cfg = { global: true }, bodyBg } = {}) {
  const dom = new JSDOM(html, { url, runScripts: 'outside-only', pretendToBeVisual: true, virtualConsole: new VirtualConsole() });
  const w = dom.window;
  const reports = [];
  w.webkit = { messageHandlers: { mioDark: { postMessage: (m) => reports.push(m) } } };
  const timers = [];
  w.setTimeout = (fn) => { timers.push(fn); return timers.length; };
  return { dom, w, reports, flush: () => { while (timers.length) timers.shift()(); }, run: () => w.eval(`${SRC}\nMioDark.install(document, window, ${JSON.stringify(cfg)});`) };
}

test('install on a light page: inverts at document-start, keeps invert after load, reports verdict', () => {
  const p = page('<!doctype html><html><head><style>body{background:#fff;color:#111}</style></head><body><p>hi</p><img src="a.png"><div style="background-image:url(x.png)">bg</div></body></html>');
  p.run();
  const html = p.w.document.documentElement;
  assert.equal(html.getAttribute('data-mio-dark'), 'invert');
  const style = p.w.document.getElementById('mio-dark-style');
  assert.ok(style && /invert\(1\) hue-rotate\(180deg\)/.test(style.textContent));
  assert.match(style.textContent, /:is\(img,video,canvas,iframe/);
  p.w.dispatchEvent(new p.w.Event('load'));
  p.flush();
  assert.equal(html.getAttribute('data-mio-dark'), 'invert');
  assert.deepEqual({ ...p.reports[0] }, { host: 'light.example', verdict: 'invert' });
  // 背景图元素被标记（反色模式下再反一次还原）
  assert.ok(p.w.document.querySelector('div[data-mio-dark-bg]'));
});

test('install on a page that is already dark: removes invert after measuring', () => {
  const p = page('<!doctype html><html><head><style>html,body{background:#0d1117;color:#e6edf3}</style></head><body><p>dark site</p></body></html>', { url: 'https://github.example/' });
  p.run();
  const html = p.w.document.documentElement;
  // jsdom 里 readyState 已经是 complete：install 立即测量
  p.flush();
  assert.equal(html.getAttribute('data-mio-dark'), 'native');
  assert.deepEqual({ ...p.reports[0] }, { host: 'github.example', verdict: 'native' });
});

test('document-start (readyState loading): optimistic invert, or pending-native for known dark hosts', async () => {
  const at = (url, cfg, body) => {
    const html = `<!doctype html><html><head><script>${SRC.replace(/<\/script/gi, '<\\/script')}
window.__api = MioDark.install(document, window, ${JSON.stringify(cfg)});
window.__initial = document.documentElement.getAttribute('data-mio-dark');
window.__readyState = document.readyState;</script></head><body style="${body}">x</body></html>`;
    const dom = new JSDOM(html, { url, runScripts: 'dangerously', virtualConsole: new VirtualConsole() });
    return dom.window;
  };
  const light = at('https://light.example/', { global: true }, 'background:#fff');
  const known = at('https://known.example/', { global: true, nativeHosts: ['known.example'] }, 'background:#111');
  await new Promise((r) => setTimeout(r, 50));   // DOMContentLoaded
  assert.equal(light.__readyState, 'loading');
  assert.equal(light.__initial, 'invert', 'invert before any paint → no white flash');
  assert.equal(light.document.documentElement.getAttribute('data-mio-dark'), 'invert', 'still invert after DOMContentLoaded');
  assert.equal(known.__initial, 'pending-native');
  assert.equal(known.document.documentElement.getAttribute('data-mio-dark'), 'native');
});

test('disabled for this site → no attribute, no style', () => {
  const p = page('<!doctype html><html><body>x</body></html>', { url: 'https://off.example/', cfg: { global: true, sites: { 'off.example': false } } });
  p.run();
  assert.equal(p.w.document.documentElement.hasAttribute('data-mio-dark'), false);
  assert.equal(p.w.document.getElementById('mio-dark-style'), null);
});

test('page resetting the html attribute gets it back', async () => {
  const p = page('<!doctype html><html><body style="background:#fff">x</body></html>');
  p.run();
  p.w.document.documentElement.removeAttribute('data-mio-dark');
  await new Promise((r) => setImmediate(r));
  assert.equal(p.w.document.documentElement.getAttribute('data-mio-dark'), 'invert');
});

test('source uses DOM APIs only (Trusted Types safe)', () => {
  assert.ok(!/\.innerHTML\s*=[^=]|insertAdjacentHTML\(|document\.write\(|new DOMParser/.test(SRC));
});
