'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { TabStore, displayHost, normalizeNewTabUrl, DEFAULT_NEW_TAB_URL } = require('../src/tabs-core');

const urls = (s) => s.tabs.map((t) => t.url.replace('https://', '').replace(/\/$/, ''));

test('add: new tab goes right of the active one and becomes active', () => {
  const s = new TabStore();
  const a = s.add('https://a.com/');
  s.add('https://b.com/');
  s.select(a.id);
  const c = s.add('https://c.com/');
  assert.deepEqual(urls(s), ['a.com', 'c.com', 'b.com']);
  assert.equal(s.activeId, c.id);
});

test('add: background tabs from the active tab keep opening order', () => {
  const s = new TabStore();
  s.add('https://a.com/');
  s.add('https://z.com/', { index: 1, activate: false });
  s.selectIndex(0);
  s.add('https://1.com/', { activate: false, fromActive: true });
  s.add('https://2.com/', { activate: false, fromActive: true });
  s.add('https://3.com/', { activate: false, fromActive: true });
  assert.deepEqual(urls(s), ['a.com', '1.com', '2.com', '3.com', 'z.com']);
  s.selectIndex(4);
  s.selectIndex(0);
  s.add('https://4.com/', { activate: false, fromActive: true });
  assert.deepEqual(urls(s), ['a.com', '4.com', '1.com', '2.com', '3.com', 'z.com']);
});

test('foreground tab opened from the active tab keeps its opener', () => {
  const s = new TabStore();
  const a = s.add('https://a.com/');
  const b = s.add('https://b.com/', { fromActive: true });
  assert.equal(s.activeId, b.id);
  assert.equal(b.openerId, a.id);
});

test('close: active → right neighbour, then left; last tab → null', () => {
  const s = new TabStore();
  const a = s.add('https://a.com/');
  const b = s.add('https://b.com/');
  const c = s.add('https://c.com/');
  s.select(b.id);
  assert.equal(s.close(b.id).activeId, c.id);
  assert.equal(s.close(c.id).activeId, a.id);
  assert.equal(s.close(a.id).activeId, null);
  assert.equal(s.size, 0);
});

test('reopenClosed restores url, title, position and container (LIFO)', () => {
  const s = new TabStore();
  s.add('https://a.com/');
  const b = s.add('https://b.com/', { title: 'B', containerId: 'work', locked: true });
  s.add('https://c.com/');
  s.close(b.id);
  s.close(s.tabs[0].id);
  assert.equal(s.reopenClosed().url, 'https://a.com/');
  const r = s.reopenClosed();
  assert.equal(r.url, 'https://b.com/');
  assert.equal(r.title, 'B');
  assert.equal(r.containerId, 'work');
  assert.equal(r.locked, true);
  assert.deepEqual(urls(s), ['a.com', 'b.com', 'c.com']);
  assert.equal(s.reopenClosed(), null);
});

test('closed stack keeps only http(s) and at most maxClosed', () => {
  const s = new TabStore({ maxClosed: 2 });
  for (const u of ['https://1.com/', 'about:blank', 'https://2.com/', 'https://3.com/']) s.close(s.add(u).id);
  assert.deepEqual(s.closed.map((c) => c.url), ['https://2.com/', 'https://3.com/']);
});

test('max tabs: add returns null at the limit', () => {
  const s = new TabStore({ maxTabs: 2 });
  assert.ok(s.add('https://a.com/'));
  assert.ok(s.add('https://b.com/'));
  assert.equal(s.add('https://c.com/'), null);
});

test('selectRelative wraps, selectNumber 9 = last', () => {
  const s = new TabStore();
  ['a', 'b', 'c'].forEach((x) => s.add(`https://${x}.com/`));
  s.selectIndex(2);
  s.selectRelative(1);
  assert.equal(s.activeIndex, 0);
  s.selectRelative(-1);
  assert.equal(s.activeIndex, 2);
  s.selectNumber(1);
  assert.equal(s.activeIndex, 0);
  s.selectNumber(9);
  assert.equal(s.activeIndex, 2);
  assert.equal(s.selectNumber(5), false);
});

test('move reorders tabs', () => {
  const s = new TabStore();
  ['a', 'b', 'c'].forEach((x) => s.add(`https://${x}.com/`));
  assert.ok(s.move(0, 2));
  assert.deepEqual(urls(s), ['b.com', 'c.com', 'a.com']);
  assert.equal(s.move(1, 1), false);
  assert.ok(s.move(0, 99));
  assert.deepEqual(urls(s), ['c.com', 'a.com', 'b.com']);
  assert.equal(s.move(5, 0), false);
});

test('toUnload: least recently used background tabs beyond the limit', () => {
  const s = new TabStore();
  const ids = ['a', 'b', 'c', 'd'].map((x) => s.add(`https://${x}.com/`).id);
  s.select(ids[1]);
  s.select(ids[0]);
  s.select(ids[3]);
  const all = () => true;
  assert.deepEqual(s.toUnload(2, all), [ids[2], ids[1]]);
  assert.deepEqual(s.toUnload(10, all), []);
  assert.ok(!s.toUnload(1, all).includes(ids[3]));
});

test('containers: children inherit container; locked tabs force container + lock', () => {
  const s = new TabStore();
  const a = s.add('https://a.com/', { containerId: 'shop' });
  const child = s.add('https://a.com/x', { fromActive: true });
  assert.equal(child.containerId, 'shop');
  assert.equal(child.locked, false);
  s.select(a.id);
  const other = s.add('https://a.com/y', { fromActive: true, containerId: 'work' });
  assert.equal(other.containerId, 'work', 'unlocked opener: explicit container wins');
  s.setLocked(a.id, true);
  s.select(a.id);
  const forced = s.add('https://a.com/z', { fromActive: true, containerId: 'work' });
  assert.equal(forced.containerId, 'shop');
  assert.equal(forced.locked, true);
  assert.equal(s.setContainer(forced.id, 'work'), false, 'locked tab cannot switch');
  s.setLocked(forced.id, false);
  assert.equal(s.setContainer(forced.id, 'work'), true);
  assert.equal(s.add('https://b.com/', { containerId: '../evil' }).containerId, 'default');
});

test('containers: removeContainer closes its tabs and forgets closed entries', () => {
  const s = new TabStore();
  s.add('https://a.com/');
  const b = s.add('https://b.com/', { containerId: 'p2' });
  s.add('https://c.com/', { containerId: 'p2' });
  const d = s.add('https://d.com/', { containerId: 'p2' });
  s.close(d.id);
  const closed = s.removeContainer('p2');
  assert.equal(closed.length, 2);
  assert.ok(closed.includes(b.id));
  assert.deepEqual(urls(s), ['a.com']);
  assert.equal(s.closed.some((x) => x.containerId === 'p2'), false);
  assert.deepEqual(s.removeContainer('default'), []);
});

test('serialize / restore round trip with containers + lock; unknown container → default', () => {
  const s = new TabStore();
  s.add('https://a.com/', { title: '  A \n title ' });
  s.add('about:blank');
  const c = s.add('https://c.com/x?y=1', { title: 'C', containerId: 'acc2', locked: true });
  s.add('https://d.com/', { containerId: 'gone' });
  s.select(c.id);
  const data = JSON.parse(JSON.stringify(s.serialize()));
  assert.deepEqual(data, {
    v: 2,
    active: 1,
    tabs: [
      { url: 'https://a.com/', title: 'A title' },
      { url: 'https://c.com/x?y=1', title: 'C', container: 'acc2', locked: true },
      { url: 'https://d.com/', title: '', container: 'gone' },
    ],
  });
  const r = new TabStore();
  assert.equal(r.restore(data, ['acc2']), 3);
  assert.equal(r.active.url, 'https://c.com/x?y=1');
  assert.equal(r.active.containerId, 'acc2');
  assert.equal(r.active.locked, true);
  assert.equal(r.tabs[2].containerId, 'default');
  assert.equal(new TabStore().restore({ tabs: [{ url: 'javascript:alert(1)' }] }), 0);
  assert.equal(new TabStore().restore(null), 0);
  // v1（只有 url / title）照样能读
  assert.equal(new TabStore().restore({ v: 1, active: 0, tabs: [{ url: 'https://a.com/', title: 'A' }] }), 1);
  const big = new TabStore({ maxTabs: 3 });
  assert.equal(big.restore({ active: 99, tabs: Array.from({ length: 10 }, (_, i) => ({ url: `https://${i}.com/` })) }), 3);
  assert.equal(big.activeIndex, 2);
});

test('update reports changes', () => {
  const s = new TabStore();
  const a = s.add('https://a.com/');
  assert.equal(s.update(a.id, { title: 'x' }), true);
  assert.equal(s.update(a.id, { title: 'x' }), false);
  assert.equal(s.update(a.id, { url: 'https://b.com/' }), true);
  assert.equal(s.update(999, { url: 'https://b.com/' }), false);
});

test('displayHost / normalizeNewTabUrl', () => {
  assert.equal(displayHost('https://www.YouTube.com/watch?v=1'), 'youtube.com');
  assert.equal(displayHost('about:blank'), '');
  assert.equal(normalizeNewTabUrl(''), DEFAULT_NEW_TAB_URL);
  assert.equal(normalizeNewTabUrl('example.com'), 'https://example.com/');
  assert.equal(normalizeNewTabUrl('localhost:8080'), 'https://localhost:8080/');
  assert.equal(normalizeNewTabUrl('http://example.com/a'), 'http://example.com/a');
  assert.equal(normalizeNewTabUrl('javascript:alert(1)'), null);
  assert.equal(normalizeNewTabUrl('file:///etc/passwd'), null);
  assert.equal(normalizeNewTabUrl('nodot'), null);
});

test('settings: newTabUrl validated and normalized', () => {
  const fs = require('node:fs');
  const os = require('node:os');
  const path = require('node:path');
  const { SettingsStore } = require('../src/settings-store');
  const file = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'mio-tabs-')), 'settings.json');
  const s = new SettingsStore(file);
  assert.equal(s.get('newTabUrl'), '');
  s.set('newTabUrl', 'example.com/start');
  assert.equal(s.get('newTabUrl'), 'https://example.com/start');
  assert.throws(() => s.set('newTabUrl', 'javascript:alert(1)'));
  s.set('newTabUrl', DEFAULT_NEW_TAB_URL);
  assert.equal(s.get('newTabUrl'), '');
});
