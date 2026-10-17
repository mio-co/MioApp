// 后台播放的可见性伪造（MioMediaScripts.visibilityScript）+ 与 YouTube 防沉迷脚本共存；Android / Windows 生成文件没过期。
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { JSDOM } from 'jsdom';
import { extractMediaScript } from './media-harness.mjs';
import { extractScript } from './harness.mjs';
import { generated, TARGETS } from '../../../scripts/sync-media-js.mjs';

const VIS = extractMediaScript('visibility');

function setup(url = 'https://m.youtube.com/') {
  const dom = new JSDOM('<!doctype html><html><head></head><body></body></html>', { url, runScripts: 'outside-only' });
  const w = dom.window;
  let vis = 'visible';
  Object.defineProperty(w.Document.prototype, 'visibilityState', { configurable: true, get: () => vis });
  Object.defineProperty(w.Document.prototype, 'hidden', { configurable: true, get: () => vis === 'hidden' });
  const flip = (hidden) => { vis = hidden ? 'hidden' : 'visible'; w.document.dispatchEvent(new w.Event('visibilitychange')); };
  return { w, d: w.document, flip };
}

test('document always looks visible; page listeners on window and document never see visibilitychange', () => {
  const { w, d, flip } = setup();
  w.eval(VIS);
  let onWin = 0, onDoc = 0, onDocBubble = 0, prop = 0;
  w.addEventListener('visibilitychange', () => onWin++, true);
  d.addEventListener('visibilitychange', () => onDoc++, true);
  d.addEventListener('visibilitychange', () => onDocBubble++);
  d.onvisibilitychange = () => prop++;
  flip(true);
  assert.equal(d.hidden, false);
  assert.equal(d.visibilityState, 'visible');
  assert.equal(d.webkitHidden, false);
  assert.equal(d.webkitVisibilityState, 'visible');
  assert.deepEqual([onWin, onDoc, onDocBubble, prop], [0, 0, 0, 0]);
  // 真实值仍可从原型读到（防沉迷 / 媒体脚本用）
  assert.equal(Object.getOwnPropertyDescriptor(w.Document.prototype, 'visibilityState').get.call(d), 'hidden');
  w.eval(VIS);   // 重复注入无副作用
  assert.equal(d.hidden, false);
});

test('coexists with YouTube focus script injected before it (its window-capture listener still gets real changes)', () => {
  const { w, d, flip } = setup('https://m.youtube.com/shorts/abc');
  const timers = new Map();
  let id = 1;
  w.setTimeout = (fn) => { timers.set(id, fn); return id++; };
  w.clearTimeout = (i) => timers.delete(i);
  w.eval(extractScript('youtubeFocus').replace('__MIO_YT_INTERVAL_MS__', '60000'));
  w.eval(VIS);
  const before = timers.size;
  flip(true);
  assert.ok(timers.size < before, 'focus timer paused on real hide');
  flip(false);
  assert.ok(timers.size >= before, 'focus timer resumed on real show');
  assert.equal(d.hidden, false);
});

test('generated Android / Windows copies match the Swift source (run node scripts/sync-media-js.mjs)', () => {
  const want = generated();
  assert.equal(want.split('__MIO_MEDIA_CONFIG__').length, 2, 'exactly one config placeholder (header comment must not contain it)');
  for (const rel of TARGETS) {
    const p = fileURLToPath(new URL('../../../' + rel, import.meta.url));
    assert.equal(readFileSync(p, 'utf8'), want, `${rel} is stale`);
  }
});
