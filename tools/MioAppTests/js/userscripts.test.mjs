// 用户脚本运行时（ios/App/App/MioUserScriptCore.swift 的 userscriptRuntime）在 jsdom 里跑：
// @match / @include 判定（Swift 编译的正则在 JS 引擎里结果一致）、@run-at 调度、@noframes、重复注入、
// GM 存储（同步缓存 + 发给原生、按脚本隔离）、GM_xmlhttpRequest（原生代发的各种返回）、GM_addStyle 不用 innerHTML、@grant none。
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { JSDOM } from 'jsdom';
import { extractFrom, swiftStringConstant, repoPath } from './swift-js.mjs';

const SWIFT = 'ios/App/App/MioUserScriptCore.swift';
const RUNTIME = extractFrom(SWIFT, 'userscriptRuntime');
const PARAMS = swiftStringConstant(SWIFT, 'apiParams');
const FIXTURE = JSON.parse(readFileSync(repoPath('tools/MioAppTests/js/fixtures/userscript-rules.json'), 'utf8'));

function rule(s, i = false) { return { s, i }; }
const R_EXAMPLE = FIXTURE.find((c) => c.pattern === 'https://*.example.com/*').rule;

function config(over = {}) {
  return {
    id: 'sid-1', name: 'Test', isolated: true, handler: 'mioUserScript', runAt: 'document-start', noframes: false,
    grants: ['GM_getValue'], match: [rule(R_EXAMPLE.source, R_EXAMPLE.ignoreCase)], include: [], exclude: [], excludeMatch: [],
    matchAll: false, values: {}, resources: {}, info: { script: { name: 'Test', version: '1' }, scriptHandler: 'Mio' },
    ...over,
  };
}

function source(cfg, body) {
  return `${RUNTIME}(${JSON.stringify(cfg)}, function(${PARAMS}){\n${body}\n});`;
}

/// jsdom 窗口 + 假的 webkit.messageHandlers（WKScriptMessageHandlerWithReply：postMessage 返回 Promise）
function setup({ url = 'https://www.example.com/page', reply, html = '<!doctype html><html><head></head><body></body></html>' } = {}) {
  const dom = new JSDOM(html, { url, runScripts: 'outside-only', pretendToBeVisual: true });
  const w = dom.window;
  const posted = [];
  w.webkit = {
    messageHandlers: {
      mioUserScript: {
        postMessage(msg) {
          posted.push(JSON.parse(JSON.stringify(msg)));
          return Promise.resolve(reply ? reply(msg) : true);
        },
      },
    },
  };
  // Trusted Types 模拟：任何 innerHTML 赋值都报错
  Object.defineProperty(w.Element.prototype, 'innerHTML', { set() { throw new Error('TrustedHTML required'); }, get() { return ''; }, configurable: true });
  w.__out = [];
  return { dom, w, posted, run: (cfg, body) => w.eval(source(cfg, body)) };
}

const plain = (x) => JSON.parse(JSON.stringify(x));
const tick = () => new Promise((r) => setTimeout(r, 0));

test('Swift 编译的规则在 JS 正则里结果与 ICU 一致', () => {
  for (const c of FIXTURE) {
    const re = new RegExp(c.rule.source, c.rule.ignoreCase ? 'i' : '');
    for (const [u, want] of Object.entries(c.urls)) {
      assert.equal(re.test(c.kind === 'match' ? u.split('#')[0] : u), want, `${c.pattern} vs ${u}`);
    }
  }
});

test('@match 命中才运行；@exclude 生效；#片段不影响 @match', () => {
  const { w, run } = setup({ url: 'https://www.example.com/page#x' });
  run(config(), 'window.__out.push("ran")');
  assert.deepEqual(plain(w.__out), ['ran']);

  const miss = setup({ url: 'https://other.org/' });
  miss.run(config(), 'window.__out.push("ran")');
  assert.deepEqual(plain(miss.w.__out), []);

  const ex = setup({ url: 'https://www.example.com/admin/x' });
  ex.run(config({ exclude: [rule('^.*://(?:[^/]+\\.)?example\\.com/admin/.*$', true)] }), 'window.__out.push("ran")');
  assert.deepEqual(plain(ex.w.__out), []);

  const inc = setup({ url: 'https://other.org/x' });
  inc.run(config({ match: [], include: [rule('^https?://other\\.org/.*$', true)] }), 'window.__out.push("inc")');
  assert.deepEqual(plain(inc.w.__out), ['inc']);

  const all = setup({ url: 'https://whatever.net/' });
  all.run(config({ match: [], matchAll: true }), 'window.__out.push("all")');
  assert.deepEqual(plain(all.w.__out), ['all']);
});

test('同一脚本重复注入只运行一次；不同脚本互不影响', () => {
  const { w, run } = setup();
  run(config(), 'window.__out.push("a")');
  run(config(), 'window.__out.push("a-again")');
  run(config({ id: 'sid-2' }), 'window.__out.push("b")');
  assert.deepEqual(plain(w.__out), ['a', 'b']);
});

test('@noframes：iframe 里不运行，顶层运行', () => {
  const run = (isTop) => {
    const out = [];
    const win = { out };
    win.top = isTop ? win : {};
    const ctx = vm.createContext({ window: win, document: {}, location: { protocol: 'https:', href: 'https://www.example.com/' }, console });
    vm.runInContext(source(config({ noframes: true, matchAll: true, match: [], isolated: false }), 'window.out.push(1)'), ctx);
    return out.length;
  };
  assert.equal(run(false), 0);
  assert.equal(run(true), 1);
  // 不带 @noframes 时 iframe 里也运行
  const out = [];
  const win = { out, top: {} };
  vm.runInContext(source(config({ matchAll: true, match: [], isolated: false }), 'window.out.push(1)'),
    vm.createContext({ window: win, document: {}, location: { protocol: 'https:', href: 'https://www.example.com/' }, console }));
  assert.equal(out.length, 1);
});

test('@run-at：document-start 同步运行；document-end 等 DOMContentLoaded；document-idle 再晚一拍', async () => {
  const { w, run } = setup();
  assert.equal(w.document.readyState, 'loading');
  run(config({ runAt: 'document-idle' }), 'window.__out.push("idle")');
  run(config({ id: 's2', runAt: 'document-start' }), 'window.__out.push("start")');
  run(config({ id: 's3', runAt: 'document-end' }), 'window.__out.push("end:" + document.readyState)');
  assert.deepEqual(plain(w.__out), ['start']);
  await new Promise((r) => w.addEventListener('load', r));
  await tick();
  assert.deepEqual(plain(w.__out), ['start', 'end:interactive', 'idle']);
  // 页面已加载完再注入：document-end 立即运行
  run(config({ id: 's4', runAt: 'document-end' }), 'window.__out.push("late-end")');
  assert.equal(plain(w.__out).at(-1), 'late-end');
});

test('GM 存储：同步读快照、写入发给原生、按脚本隔离', async () => {
  const { w, posted, run } = setup();
  run(config({ values: { count: '1', obj: '{"a":[1,2]}' } }), `
    window.__out.push(GM_getValue('count'), GM_getValue('obj').a[1], GM_getValue('missing', 'def'));
    GM_setValue('count', 2);
    GM_setValue('flag', true);
    GM_deleteValue('obj');
    window.__out.push(GM_getValue('count'), JSON.stringify(GM_listValues().sort()));
    GM.getValue('flag').then(function (v) { window.__out.push('promise:' + v); });
  `);
  run(config({ id: 'other', values: { count: '99' } }), 'window.__out.push("other:" + GM_getValue("count") + ":" + GM_getValue("flag", "none"))');
  await tick();
  assert.deepEqual(plain(w.__out), [1, 2, 'def', 2, '["count","flag"]', 'other:99:none', 'promise:true']);
  assert.deepEqual(posted.map((m) => [m.op, m.id, m.key, m.value]), [
    ['setValue', 'sid-1', 'count', '2'],
    ['setValue', 'sid-1', 'flag', 'true'],
    ['deleteValue', 'sid-1', 'obj', undefined],
  ]);
});

test('GM_addValueChangeListener 在本页写入时回调', () => {
  const { w, run } = setup();
  run(config(), `
    GM_addValueChangeListener('k', function (name, oldV, newV, remote) { window.__out.push([name, oldV, newV, remote]); });
    GM_setValue('k', 'v1'); GM_setValue('k', 'v2'); GM_deleteValue('k');
  `);
  assert.deepEqual(plain(w.__out), [['k', null, 'v1', false], ['k', 'v1', 'v2', false], ['k', 'v2', null, false]]);
});

test('GM_xmlhttpRequest：JSON / arraybuffer / 错误 / 超时 / abort', async () => {
  const replies = {
    'https://api.example.com/json': { status: 200, statusText: 'OK', headers: 'content-type: application/json', text: '{"ok":1}', finalUrl: 'https://api.example.com/json' },
    'https://api.example.com/bin': { status: 200, headers: 'content-type: application/octet-stream', base64: Buffer.from([1, 2, 255]).toString('base64') },
    'https://api.example.com/denied': { error: 'api.example.com 不在脚本的 @connect 列表中，已拒绝' },
    'https://api.example.com/slow': { error: 'timed out', timeout: true },
  };
  const { w, posted, run } = setup({ reply: (m) => (m.op === 'xhr' ? replies[m.url] : true) });
  run(config({ grants: ['GM_xmlhttpRequest'] }), `
    GM_xmlhttpRequest({ url: 'https://api.example.com/json', responseType: 'json', headers: { 'X-A': 1 }, data: 'q=1', method: 'post',
      onload: function (r) { window.__out.push(['json', r.status, r.response.ok, r.responseText, r.finalUrl, r.readyState]); } });
    GM_xmlhttpRequest({ url: 'https://api.example.com/bin', responseType: 'arraybuffer',
      onload: function (r) { window.__out.push(['bin', Array.from(new Uint8Array(r.response))]); } });
    GM_xmlhttpRequest({ url: 'https://api.example.com/denied', onerror: function (r) { window.__out.push(['err', r.status, r.error]); } });
    GM_xmlhttpRequest({ url: 'https://api.example.com/slow', ontimeout: function () { window.__out.push(['timeout']); } });
    var h = GM_xmlhttpRequest({ url: '/relative', onabort: function () { window.__out.push(['abort']); }, onload: function () { window.__out.push(['should-not-load']); } });
    h.abort();
    GM.xmlHttpRequest({ url: 'https://api.example.com/json' }).then(function (r) { window.__out.push(['promise', r.status]); });
  `);
  await tick(); await tick(); await tick();
  const out = plain(w.__out);
  assert.deepEqual(out.find((x) => x[0] === 'json'), ['json', 200, 1, '{"ok":1}', 'https://api.example.com/json', 4]);
  assert.deepEqual(out.find((x) => x[0] === 'bin'), ['bin', [1, 2, 255]]);
  assert.deepEqual(out.find((x) => x[0] === 'err'), ['err', 0, 'api.example.com 不在脚本的 @connect 列表中，已拒绝']);
  assert.ok(out.find((x) => x[0] === 'timeout'));
  assert.ok(out.find((x) => x[0] === 'abort'));
  assert.ok(!out.find((x) => x[0] === 'should-not-load'));
  assert.deepEqual(out.find((x) => x[0] === 'promise'), ['promise', 200]);
  const first = posted.find((m) => m.op === 'xhr' && m.url.endsWith('/json'));
  assert.equal(first.method, 'POST');
  assert.deepEqual(first.headers, { 'X-A': '1' });
  assert.deepEqual(first.body, { text: 'q=1' });
  assert.equal(first.id, 'sid-1');
  assert.ok(first.reqId.startsWith('sid-1:'));
  assert.ok(posted.find((m) => m.op === 'xhrAbort'));
  // 相对地址按页面地址解析；abort 后不再发请求
  assert.ok(!posted.find((m) => m.op === 'xhr' && m.url === 'https://www.example.com/relative'));
});

test('GM_xmlhttpRequest：二进制请求体转 base64、URLSearchParams 带 Content-Type', async () => {
  const { posted, run } = setup({ reply: () => ({ status: 204, headers: '', text: '' }) });
  run(config({ grants: ['GM_xmlhttpRequest'] }), `
    GM_xmlhttpRequest({ url: 'https://x.example.com/a', method: 'PUT', data: new Uint8Array([104, 105]) });
    GM_xmlhttpRequest({ url: 'https://x.example.com/b', method: 'POST', data: new URLSearchParams({ a: '1 2' }) });
  `);
  await tick(); await tick();
  const [a, b] = posted.filter((m) => m.op === 'xhr');
  assert.deepEqual(a.body, { base64: Buffer.from('hi').toString('base64') });
  assert.deepEqual(b.body, { text: 'a=1+2' });
  assert.equal(b.headers['Content-Type'], 'application/x-www-form-urlencoded;charset=UTF-8');
});

test('GM_addStyle / GM_addElement 用 DOM API（Trusted Types 下不报错）、GM_info、unsafeWindow', () => {
  const { w, run } = setup();
  run(config(), `
    var s = GM_addStyle('body { color: red }');
    var el = GM_addElement(document.body, 'div', { id: 'mio-x', textContent: 'hello' });
    window.__out.push(s.tagName, s.textContent, s.parentNode === document.head, el.id, el.textContent);
    window.__out.push(GM_info.scriptHandler, GM_info.script.name, unsafeWindow === window, typeof GM.info);
  `);
  assert.deepEqual(plain(w.__out), ['STYLE', 'body { color: red }', true, 'mio-x', 'hello', 'Mio', 'Test', true, 'object']);
});

test('@grant none（页面世界）：没有存储 / xhr，不碰原生通道；GM_info / GM_addStyle 可用', () => {
  const { w, posted, run } = setup();
  run(config({ isolated: false, grants: ['none'] }), `
    window.__out.push(typeof GM_getValue, typeof GM_xmlhttpRequest, typeof GM.getValue, typeof GM_info, typeof GM_addStyle);
    GM_addStyle('a{}');
  `);
  assert.deepEqual(plain(w.__out), ['undefined', 'undefined', 'undefined', 'object', 'function']);
  assert.equal(posted.length, 0);
});

test('GM_setClipboard / GM_openInTab 发给原生；GM_registerMenuCommand 可由原生调用', async () => {
  const { w, posted, run } = setup();
  run(config(), `
    GM_setClipboard('<b>x</b>', 'html');
    GM_openInTab('/next', { active: false });
    GM_registerMenuCommand('Say hi', function () { window.__out.push('menu-hi'); });
  `);
  await tick();
  assert.deepEqual(posted.find((m) => m.op === 'setClipboard'), { op: 'setClipboard', id: 'sid-1', data: '<b>x</b>', type: 'html' });
  assert.deepEqual(posted.find((m) => m.op === 'openTab'), { op: 'openTab', id: 'sid-1', url: 'https://www.example.com/next', active: false });
  const menu = posted.find((m) => m.op === 'menu');
  assert.deepEqual(menu.commands, [{ id: '1', name: 'Say hi' }]);
  w.__mioUserScriptMenu('1');
  assert.deepEqual(plain(w.__out), ['menu-hi']);
});

test('脚本抛异常不影响页面，也不影响其他脚本', () => {
  const { w, run } = setup();
  const errors = [];
  w.console.error = (...a) => errors.push(a.join(' '));
  run(config(), 'throw new Error("boom")');
  run(config({ id: 'ok' }), 'window.__out.push("still")');
  assert.deepEqual(plain(w.__out), ['still']);
  assert.match(errors[0], /Mio 用户脚本/);
});
