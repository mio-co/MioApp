'use strict';
// 用 scripts/fetch-assets.mjs 下载的真实列表（assets/adblock）构建引擎；没有资源时跳过（CI 里先下载，MIO_ADBLOCK_REQUIRE=1 强制）
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const config = require('../src/config');
const { buildEngine } = require('../src/adblock-engine');
const { FiltersEngine, Request } = require('@ghostery/adblocker');

const dir = process.env.MIO_DESKTOP_ADBLOCK_DIR || path.join(__dirname, '..', 'assets', 'adblock');
const have = fs.existsSync(path.join(dir, 'filter-2.txt'));
if (!have && process.env.MIO_ADBLOCK_REQUIRE) throw new Error(`no lists in ${dir}`);

test('real lists: network, cosmetic, scriptlets', { skip: !have && 'no bundled lists' }, () => {
  const ids = [...config.FILTER_LISTS.map((l) => l.id), 0];
  const lists = ids.map((id) => fs.readFileSync(path.join(dir, `filter-${id}.txt`), 'utf8'));
  const { bytes, stats } = buildEngine(lists, fs.readFileSync(path.join(dir, 'resources.json'), 'utf8'));
  console.log(stats);
  assert.ok(stats.networkFilters > 100000, 'network filters');
  assert.ok(stats.cosmeticFilters > 50000, 'cosmetic filters');
  assert.ok(stats.scriptlets > 50, 'scriptlets');
  const t = Date.now();
  const e = FiltersEngine.deserialize(bytes);
  console.log('deserialize ms', Date.now() - t);
  const m = (url, src, type) => e.match(Request.fromRawDetails({ url, sourceUrl: src, type })).match;
  assert.ok(m('https://googleads.g.doubleclick.net/pagead/id', 'https://www.youtube.com/watch?v=1', 'xmlhttprequest'));
  assert.ok(m('https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js', 'https://example.com/', 'script'));
  assert.ok(m('https://www.google-analytics.com/analytics.js', 'https://example.com/', 'script'));
  assert.ok(m('https://www.youtube.com/api/stats/ads?x=1', 'https://www.youtube.com/watch?v=1', 'xmlhttprequest'));
  assert.ok(!m('https://www.youtube.com/youtubei/v1/player?key=1', 'https://www.youtube.com/watch?v=1', 'xmlhttprequest'));
  assert.ok(!m('https://i.ytimg.com/vi/x/hqdefault.jpg', 'https://www.youtube.com/', 'image'));
  assert.ok(!m('https://mio.300031.xyz/api/navigation', 'https://mio.300031.xyz/mio/nav', 'xmlhttprequest'));

  const yt = e.getCosmeticsFilters({ url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ', hostname: 'www.youtube.com', domain: 'youtube.com', getBaseRules: false, getInjectionRules: true, getExtendedRules: false, getRulesFromHostname: true });
  const js = yt.scripts.join('\n');
  assert.ok(yt.scripts.length > 3, 'youtube scriptlets');
  assert.match(js, /adPlacements/);
  const css = e.getCosmeticsFilters({ url: 'https://www.youtube.com/', hostname: 'www.youtube.com', domain: 'youtube.com', getBaseRules: true, getInjectionRules: false, getExtendedRules: true, getRulesFromHostname: true });
  assert.match(css.styles, /ytd-ad-slot-renderer/);
  // 中文站点：AdGuard 中文列表生效
  const baidu = e.getCosmeticsFilters({ url: 'https://www.baidu.com/s?wd=1', hostname: 'www.baidu.com', domain: 'baidu.com', getBaseRules: false, getInjectionRules: true, getExtendedRules: true, getRulesFromHostname: true });
  assert.ok(baidu.styles.length > 0 || baidu.scripts.length > 0, 'baidu rules');
});
