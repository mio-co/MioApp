'use strict';
// src/media.js：只在顶层 YouTube 页面注入、配置 JSON、分类解析；生成的脚本与 iOS 源一致（tools/MioAppTests/js/media-visibility.test.mjs 也会检查）
const test = require('node:test');
const assert = require('node:assert/strict');
const media = require('../src/media');

const settings = (over = {}) => {
  const s = { backgroundPlayback: true, sponsorBlock: true, sponsorBlockCategories: 'sponsor,selfpromo,interaction', ...over };
  return (k) => s[k];
};

test('injects only into top-level https YouTube pages', () => {
  assert.notEqual(media.scriptFor('https://www.youtube.com/watch?v=dQw4w9WgXcQ', settings()), '');
  assert.notEqual(media.scriptFor('https://m.youtube.com/', settings()), '');
  assert.equal(media.scriptFor('https://www.youtube.com/', settings(), false), '');
  assert.equal(media.scriptFor('https://example.com/', settings()), '');
  assert.equal(media.scriptFor('https://youtube.com.evil.net/', settings()), '');
  assert.equal(media.scriptFor('http://www.youtube.com/', settings()), '');
  assert.equal(media.scriptFor('not a url', settings()), '');
});

test('config is baked in place of the placeholder', () => {
  const js = media.scriptFor('https://www.youtube.com/', settings({ sponsorBlockCategories: 'outro, sponsor,bogus', backgroundPlayback: false }));
  assert.ok(!js.includes('__MIO_MEDIA_CONFIG__'));
  const m = /var CFG = (\{.*?\});/.exec(js);
  assert.ok(m);
  assert.deepEqual(JSON.parse(m[1]), { platform: 'desktop', background: false, nowPlaying: true, pip: true, sponsorBlock: true, categories: ['sponsor', 'outro'] });
  const off = JSON.parse(/var CFG = (\{.*?\});/.exec(media.scriptFor('https://www.youtube.com/', settings({ sponsorBlock: false })))[1]);
  assert.equal(off.sponsorBlock, false);
});

test('parseCategories keeps known categories in fixed order', () => {
  assert.deepEqual(media.parseCategories('interaction,sponsor,sponsor, intro ,x'), ['sponsor', 'interaction', 'intro']);
  assert.deepEqual(media.parseCategories(''), []);
  assert.deepEqual(media.parseCategories(undefined), []);
  assert.deepEqual(media.parseCategories(media.DEFAULT_CATEGORIES), ['sponsor', 'selfpromo', 'interaction']);
});

test('bundled template exists and has no HTML string sinks', () => {
  const js = media.scriptFor('https://www.youtube.com/', settings());
  assert.ok(js.length > 5000);
  assert.ok(!/innerHTML|insertAdjacentHTML/.test(js));
});
