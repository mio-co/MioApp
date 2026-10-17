// 用户脚本运行时在 Android（WebMessageListener：页面世界 + 每脚本 token）和 Windows（Electron 隔离 world 的 contextBridge invoke）
// 两种原生桥上的行为；生成的 Android / Electron 运行时副本与 Swift 唯一来源一致。
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { JSDOM } from 'jsdom';
import { renderRuntime, TARGETS } from '../../../scripts/sync-userscript-runtime.mjs';
import { repoPath } from './swift-js.mjs';

const require = createRequire(import.meta.url);
const core = require('../../../desktop/src/userscript-core.js');

const CODE = `// ==UserScript==
// @name  Bridge
// @match https://www.example.com/*
// @run-at document-start
// @grant GM_setValue
// @grant GM_xmlhttpRequest
// ==/UserScript==
window.__out.push('v:' + GM_getValue('k', 'none'));
GM_setValue('k', 2);
GM_xmlhttpRequest({ url: '/api', onload: function (r) { window.__out.push('xhr:' + r.status + ':' + r.responseText); }, onerror: function (r) { window.__out.push('err:' + r.error); } });
`;

const tick = () => new Promise((r) => setTimeout(r, 5));
const plain = (x) => JSON.parse(JSON.stringify(x));

function dom() {
  const d = new JSDOM('<!doctype html><html><head></head><body></body></html>', { url: 'https://www.example.com/page', runScripts: 'outside-only' });
  d.window.__out = [];
  return d.window;
}

function script(values, opts) {
  return core.buildSource({ id: 'sid-9', meta: core.parseMeta(CODE), code: CODE }, values, opts);
}

test('生成的 Android / Windows 运行时与 Swift 一致（node scripts/sync-userscript-runtime.mjs）', () => {
  const js = renderRuntime();
  for (const t of TARGETS) assert.equal(readFileSync(repoPath(t), 'utf8'), js, t);
});

test('Electron：隔离 world 里 contextBridge 暴露的 invoke（Promise 返回结果）', async () => {
  const w = dom();
  const calls = [];
  w.mioUserScriptNative = {
    invoke(m) {
      calls.push(plain(m));
      if (m.op === 'xhr') return Promise.resolve({ status: 200, text: 'ok', headers: '', finalUrl: m.url });
      return Promise.resolve(true);
    },
  };
  w.eval(script({ k: '1' }, { bridge: 'mioUserScriptNative' }));
  await tick();
  assert.deepEqual(plain(w.__out), ['v:1', 'xhr:200:ok']);
  assert.deepEqual(calls.map((c) => c.op), ['setValue', 'xhr']);
  assert.equal(calls[0].id, 'sid-9');
  assert.equal(calls[1].url, 'https://www.example.com/api');
});

test('Android：WebMessageListener 对象（字符串消息、按 sid + seq 对应回复、token 不经属性 setter）', async () => {
  const w = dom();
  const sent = [];
  const listeners = [];
  let stolen = null;
  // 页面给 Object.prototype 装 token setter：桥用 defineProperty 写 token，不会触发
  const obj = {
    postMessage(s) {
      const m = JSON.parse(s);
      sent.push(m);
      const reply = m.op === 'xhr' ? { status: 201, text: 'hi', headers: '' } : true;
      setTimeout(() => {
        // 别的脚本的回复（sid 不同）应被忽略
        listeners.forEach((l) => l({ data: JSON.stringify({ sid: 'other', seq: m.seq, result: { status: 500 } }) }));
        listeners.forEach((l) => l({ data: JSON.stringify({ sid: m.id, seq: m.seq, result: reply }) }));
      }, 1);
    },
    addEventListener(type, fn) { if (type === 'message') listeners.push(fn); },
  };
  w.mioUserScriptNative = obj;
  w.eval("Object.defineProperty(Object.prototype, 'token', { set: function (v) { window.__stolen = v; }, configurable: true })");
  w.eval(script({}, { bridge: 'mioUserScriptNative', token: 'tok-123', platform: 'android' }));
  await tick();
  await tick();
  stolen = w.__stolen;
  assert.equal(stolen, undefined);
  assert.deepEqual(plain(w.__out), ['v:none', 'xhr:201:hi']);
  assert.deepEqual(sent.map((m) => [m.op, m.token, m.id, typeof m.seq]), [['setValue', 'tok-123', 'sid-9', 'number'], ['xhr', 'tok-123', 'sid-9', 'number']]);
});

test('Android：原生回复 error 时 GM_setValue 只告警、xhr 走 onerror', async () => {
  const w = dom();
  const listeners = [];
  w.mioUserScriptNative = {
    postMessage(s) {
      const m = JSON.parse(s);
      setTimeout(() => listeners.forEach((l) => l({ data: JSON.stringify({ sid: m.id, seq: m.seq, error: 'forbidden' }) })), 1);
    },
    addEventListener(t, fn) { listeners.push(fn); },
  };
  w.console.warn = () => {};
  w.eval(script({}, { bridge: 'mioUserScriptNative', token: 'x' }));
  await tick();
  await tick();
  assert.deepEqual(plain(w.__out), ['v:none', 'err:forbidden']);
});

test('没有桥（旧 WebView）：GM API 报不可用，不抛到页面', async () => {
  const w = dom();
  w.console.warn = () => {};
  w.eval(script({}, { bridge: 'mioUserScriptNative' }));
  await tick();
  assert.equal(plain(w.__out)[0], 'v:none');
  assert.match(plain(w.__out)[1], /^err:GM API 不可用/);
});
