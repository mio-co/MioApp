'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const z = require('../src/zoom-core');

test('Safari zoom levels and steps', () => {
  assert.deepEqual(z.LEVELS, [0.5, 0.75, 0.85, 1, 1.15, 1.25, 1.5, 1.75, 2, 2.5, 3]);
  assert.equal(z.zoomIn(1), 1.15);
  assert.equal(z.zoomIn(1.15), 1.25);
  assert.equal(z.zoomOut(1), 0.85);
  assert.equal(z.zoomOut(0.5), 0.5);
  assert.equal(z.zoomIn(3), 3);
  assert.equal(z.zoomIn(1.1), 1.15);
  assert.equal(z.zoomOut(1.1), 1);
  assert.equal(z.label(1.15), '115%');
  assert.equal(z.nearest(1.12), 1.15);
  assert.equal(z.nearest(NaN), 1);
});

test('site key strips www and ignores non-http', () => {
  assert.equal(z.siteKey('https://WWW.Example.com/a'), 'example.com');
  assert.equal(z.siteKey('http://news.example.com'), 'news.example.com');
  assert.equal(z.siteKey('about:blank'), null);
  assert.equal(z.siteKey('garbage'), null);
});

test('per-site table persists via JSON and drops default', () => {
  const t = new z.SiteTable();
  t.set('example.com', 1.25);
  t.set('b.com', 0.75);
  const back = new z.SiteTable(JSON.parse(JSON.stringify(t)));
  assert.equal(back.get('example.com'), 1.25);
  assert.equal(back.get('b.com'), 0.75);
  assert.equal(back.get('c.com'), 1);
  assert.equal(back.get('c.com', 1.5), 1.5);
  back.set('example.com', 1);
  assert.equal(back.size, 1);
  assert.equal(new z.SiteTable({ sites: { a: 9, b: 1.24 } }).get('b'), 1.25);
  assert.equal(new z.SiteTable({ sites: { a: 9 } }).size, 0);
  assert.equal(new z.SiteTable(null).size, 0);
});

test('table limit drops oldest', () => {
  const t = new z.SiteTable();
  for (let i = 0; i <= z.LIMIT; i++) t.set(`s${i}.com`, 1.5);
  assert.equal(t.size, z.LIMIT);
  assert.equal(t.get('s0.com'), 1);
});

test('ZoomStore persists to disk', () => {
  const fs = require('node:fs');
  const os = require('node:os');
  const path = require('node:path');
  // zoom.js 只在 attach / step 里用 Electron 对象；ZoomStore 本身纯 Node
  const { ZoomStore, step } = require('../src/zoom');
  const file = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'mio-zoom-')), 'zoom.json');
  const s = new ZoomStore(file);
  let factor = 1;
  const wc = { isDestroyed: () => false, getURL: () => 'https://www.example.com/x', setZoomFactor: (f) => { factor = f; } };
  assert.equal(step(s, wc, 'in'), 1.15);
  assert.equal(factor, 1.15);
  step(s, wc, 'in');
  const s2 = new ZoomStore(file);
  assert.equal(s2.levelFor('https://example.com/other'), 1.25);
  step(s2, wc, 'reset');
  assert.equal(new ZoomStore(file).table.size, 0);
  s2.setDefault(1.5);
  assert.equal(new ZoomStore(file).levelFor('https://x.org'), 1.5);
});
