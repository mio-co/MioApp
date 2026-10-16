'use strict';
// AdblockStore：内置 → 缓存、引擎缓存指纹、条件请求更新（304 / 200 / 失败回退）
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const config = require('../src/config');
const { AdblockStore } = require('../src/adblock-store');
const { buildEngine, ENGINE_FORMAT } = require('../src/adblock-engine');
const { FiltersEngine, Request } = require('@ghostery/adblocker');

const listText = (id, extra = '') => `! Title: list ${id}\n! Version: 1.0.${id}\n` + `||ads${id}.example^\n`.repeat(1) + 'x'.repeat(0) + Array.from({ length: 80 }, (_, i) => `||t${id}-${i}.example^`).join('\n') + '\n' + extra;
const resources = JSON.stringify({ scriptlets: Array.from({ length: 30 }, (_, i) => ({ name: `s${i}.js`, aliases: [], body: 'function x(){}', dependencies: [], executionWorld: 'MAIN', requiresTrust: false })), redirects: [] });

function setup() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mio-adblock-'));
  const bundled = path.join(root, 'bundled');
  fs.mkdirSync(bundled);
  for (const l of config.FILTER_LISTS) fs.writeFileSync(path.join(bundled, `filter-${l.id}.txt`), listText(l.id));
  fs.writeFileSync(path.join(bundled, 'filter-0.txt'), '! Mio\n||mio-yt.example^\n');
  fs.writeFileSync(path.join(bundled, 'resources.json'), resources);
  fs.writeFileSync(path.join(bundled, 'manifest.json'), JSON.stringify({ generatedAt: '2026-10-16T00:00:00Z', lists: { 2: { etag: '"e2"' } }, resources: {} }));
  return { root, bundled, cache: path.join(root, 'cache') };
}

test('prepare + build + cached engine + updates', async () => {
  const { bundled, cache } = setup();
  let now = Date.parse('2026-10-16T10:00:00Z');
  let builds = 0;
  const requests = [];
  let mode = '304';
  const fetchImpl = async (url, opts) => {
    requests.push({ url, headers: opts.headers });
    const headers = new Map([['etag', '"new"']]);
    const h = { get: (k) => headers.get(k.toLowerCase()) || null };
    if (mode === '304') return { status: 304, ok: false, headers: h, text: async () => '' };
    if (mode === 'fail') return { status: 500, ok: false, headers: h, text: async () => '' };
    if (url === config.RESOURCES_URL) return { status: 200, ok: true, headers: h, text: async () => resources };
    if (url.endsWith('/2.txt')) return { status: 200, ok: true, headers: h, text: async () => listText(2, '||updated-only.example^\n') };
    if (url.endsWith('/3.txt')) return { status: 200, ok: true, headers: h, text: async () => '<html>captive portal</html>' + ' '.repeat(2000) };
    return { status: 304, ok: false, headers: h, text: async () => '' };
  };
  const store = new AdblockStore({
    bundledDir: bundled,
    cacheDir: cache,
    fetch: fetchImpl,
    build: async (lists, res) => {
      builds++;
      return buildEngine(lists, res);
    },
    engineFormat: ENGINE_FORMAT,
    now: () => now,
  });
  store.prepare();
  const snap = store.snapshot();
  assert.equal(snap.lists.length, 7);
  assert.ok(snap.lists.every((l) => l.rules > 0 && l.source === 'bundled'));

  let r = await store.engineBytes();
  assert.equal(r.cached, false);
  let engine = FiltersEngine.deserialize(r.bytes);
  const blocked = (u) => engine.match(Request.fromRawDetails({ url: u, sourceUrl: 'https://site.example/', type: 'script' })).match;
  assert.ok(blocked('https://ads2.example/a.js'));
  assert.ok(blocked('https://mio-yt.example/a.js'));
  assert.ok(!blocked('https://updated-only.example/a.js'));

  r = await store.engineBytes();
  assert.equal(r.cached, true);
  assert.equal(builds, 1);

  // 24 小时内不检查
  assert.equal(store.needsUpdateCheck(), true);
  mode = '304';
  let u = await store.checkForUpdates();
  assert.equal(u.changed, false);
  assert.equal(u.message, '已是最新');
  const first = requests.find((q) => q.url.endsWith('/2.txt'));
  assert.equal(first.headers['If-None-Match'], '"e2"');
  assert.equal(store.needsUpdateCheck(), false);
  u = await store.checkForUpdates();
  assert.equal(u.message, '24 小时内已检查');

  // 强制更新：列表 2 有新内容；列表 3 返回 HTML（拒绝，保留旧版）；资源没变
  mode = 'mixed';
  u = await store.checkForUpdates({ force: true });
  assert.equal(u.changed, true);
  assert.match(u.message, /1 个更新，1 个失败/);
  r = await store.engineBytes();
  assert.equal(r.cached, false);
  engine = FiltersEngine.deserialize(r.bytes);
  assert.ok(blocked('https://updated-only.example/a.js'));
  assert.ok(blocked('https://ads3.example/a.js'), 'list 3 kept after rejected download');
  assert.equal(store.snapshot().lists.find((l) => l.id === 2).source, 'remote');

  // 网络失败：不改变任何东西
  now += 25 * 3600 * 1000;
  mode = 'fail';
  u = await store.checkForUpdates();
  assert.equal(u.changed, false);
  assert.match(u.message, /失败/);
  assert.equal((await store.engineBytes()).cached, true);

  // App 升级带了更新的内置列表（generatedAt 晚于远程下载时间）→ 用内置
  fs.writeFileSync(path.join(bundled, 'filter-2.txt'), listText(2, '||bundled-new.example^\n'));
  fs.writeFileSync(path.join(bundled, 'manifest.json'), JSON.stringify({ generatedAt: new Date(now + 1000).toISOString(), lists: {}, resources: {} }));
  store.prepare();
  engine = FiltersEngine.deserialize((await store.engineBytes()).bytes);
  assert.ok(blocked('https://bundled-new.example/a.js'));
});
