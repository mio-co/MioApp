'use strict';
// 阅读模式 / 强制深色 / 存到 Mio 的桌面端纯逻辑（src/page-tools-store.js）：设置、按站点深色、注入脚本、共用脚本能在页面里跑
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const S = require('../src/page-tools-store');

const tmp = () => path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'mio-pt-')), 'page-tools.json');

test('dark: per-site beats global, parent domains, persisted', () => {
  const file = tmp();
  const s = new S.PageToolsStore(file);
  assert.equal(s.isDarkEnabled('example.com'), false);
  assert.equal(s.needsDarkScript(), false);
  s.setSiteDark('www.example.com', true);
  assert.deepEqual(s.data.darkSites, { 'example.com': true });
  assert.equal(s.isDarkEnabled('blog.example.com'), true);
  assert.equal(s.needsDarkScript(), true);
  s.setDarkGlobal(true);
  s.setSiteDark('blog.example.com', true); // 与全局一致 → 去掉站点设置
  assert.deepEqual(s.data.darkSites, {});
  s.setSiteDark('blog.example.com', false);
  assert.deepEqual(s.data.darkSites, { 'blog.example.com': false });
  assert.equal(s.isDarkEnabled('a.blog.example.com'), false);
  assert.equal(s.isDarkEnabled('other.org'), true);
  const again = new S.PageToolsStore(file);
  assert.deepEqual(again.darkConfig(), { global: true, sites: { 'blog.example.com': false }, nativeHosts: [] });
});

test('native-dark hosts list', () => {
  const s = new S.PageToolsStore(tmp());
  assert.equal(s.reportDark('www.github.com', 'native'), true);
  assert.equal(s.reportDark('github.com', 'native'), false);
  assert.deepEqual(s.data.darkNativeHosts, ['github.com']);
  assert.equal(s.reportDark('github.com', 'invert'), true);
  assert.deepEqual(s.data.darkNativeHosts, []);
});

test('reader prefs clamp + corrupt file falls back to defaults', () => {
  const file = tmp();
  fs.writeFileSync(file, JSON.stringify({ readerTheme: 'neon', readerFontSize: 99, darkSites: { 'a.com': 'yes', 'b.com': true }, saveCategory: '  ' }));
  const s = new S.PageToolsStore(file);
  assert.deepEqual(s.readerPrefs, { theme: 'light', font: 'sans', fontSize: 32 });
  assert.deepEqual(s.data.darkSites, { 'b.com': true });
  assert.equal(s.saveCategory, '稍后阅读');
  s.setReaderPrefs({ theme: 'sepia', font: 'serif', fontSize: 5 });
  assert.deepEqual(s.readerPrefs, { theme: 'sepia', font: 'serif', fontSize: 12 });
});

test('shared scripts are found in the repo (dev) and wrap correctly', () => {
  const dirs = S.scriptDirCandidates(null, path.join(__dirname, '..', 'src'));
  const scripts = S.loadScripts(dirs);
  assert.ok(scripts, 'www/mio-browser not found');
  assert.match(scripts.reader, /MioReader/);
  const s = new S.PageToolsStore(null);
  assert.equal(S.darkInjection(s, scripts.dark), '', 'no script when dark is off everywhere');
  s.data.darkGlobal = true;
  const inj = S.darkInjection(s, scripts.dark);
  assert.ok(inj.endsWith(';try{MioDark.install(document,window,{"global":true,"sites":{},"nativeHosts":[]});}catch(e){}\n'));
  // 拼出来的代码在一个最小环境里能跑（语法正确、返回结果）
  const ctx = vm.createContext({ globalThis: undefined, URL, JSON, Math, Array, Object, String, Number, Set, Map });
  ctx.globalThis = ctx;
  const save = vm.runInContext(S.saveCode(scripts.save, 'clip', { url: 'about:blank' }, {}), ctx);
  return save.then((r) => assert.equal(r.code, 'invalid'));
});

test('save result messages', () => {
  assert.deepEqual(S.saveMessage({ ok: true, kind: 'bookmark', category: '稍后阅读' }), { ok: true, text: '已存到导航「稍后阅读」' });
  assert.deepEqual(S.saveMessage({ ok: true, kind: 'bookmark', duplicate: true }), { ok: true, text: '导航里已有这个网页' });
  assert.equal(S.saveMessage({ ok: false, message: '未登录' }).text, '未登录');
  assert.equal(S.saveMessage(null).ok, false);
});
