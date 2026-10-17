'use strict';
// Windows / Electron 用户脚本管理器纯逻辑：与 Swift（MioUserScriptCore.swift）编译结果逐字一致、元数据解析、版本、@connect、
// 安装地址、存储（按脚本隔离 / 上限 / 同身份更新）、注入代码、xhr 代发、安装 / 更新流程（mock fetch）。
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const core = require('../src/userscript-core');
const { UserScriptStore, prepare, checkUpdate, performXhr, verifyIntegrity } = require('../src/userscripts');

const FIXTURE = JSON.parse(fs.readFileSync(path.join(__dirname, '../../tools/MioAppTests/js/fixtures/userscript-rules.json'), 'utf8'));

const SAMPLE = `// ==UserScript==
// @name         Demo
// @name:zh-CN   演示
// @namespace    https://mio.test
// @version      1.2.0
// @description  demo script
// @match        https://*.example.com/*
// @include      /^https?://other\\.org/.*$/i
// @exclude      *://*.example.com/admin*
// @RUN-AT       document-start
// @grant        GM_setValue
// @grant        GM_xmlhttpRequest
// @connect      api.example.net
// @require      https://cdn.test/lib.js
// @resource     css https://cdn.test/a.css
// @updateURL    https://mio.test/demo.meta.js
// @downloadURL  https://mio.test/demo.user.js
// @noframes
// ==/UserScript==
window.__ran = true;
`;

test('@match / @include 编译出的正则源码与 Swift 完全一致（fixture）', () => {
  for (const c of FIXTURE) {
    const r = c.kind === 'match' ? core.matchPattern(c.pattern) : core.glob(c.pattern);
    assert.deepEqual(r, c.rule, c.pattern);
  }
});

test('无效 @match 返回 null', () => {
  for (const p of ['example.com', 'chrome://x/*', 'https://exa*mple.com/*', 'https:///x', 'file://host/x', 'https://*.', 'https://a.com']) {
    if (p === 'https://a.com') assert.ok(core.matchPattern(p), 'missing path is lenient /*');
    else assert.equal(core.matchPattern(p), null, p);
  }
});

test('元数据解析（大小写不敏感键、本地化名称、@resource、@noframes）', () => {
  const m = core.parseMeta(SAMPLE);
  assert.equal(m.name, 'Demo');
  assert.equal(core.displayName(m), '演示');
  assert.equal(m.runAt, 'document-start');
  assert.deepEqual(m.grants, ['GM_setValue', 'GM_xmlhttpRequest']);
  assert.deepEqual(m.resources, { css: 'https://cdn.test/a.css' });
  assert.equal(m.noframes, true);
  assert.equal(m.updateURL, 'https://mio.test/demo.meta.js');
  assert.ok(m.header.startsWith('// ==UserScript=='));
  assert.ok(m.header.endsWith('// ==/UserScript=='));
  assert.equal(core.grantsNone(m), false);
  assert.throws(() => core.parseMeta('var x = 1'), /元数据块/);
  assert.throws(() => core.parseMeta('// ==UserScript==\n// @version 1\n// ==/UserScript=='), /@name/);
  assert.equal(core.parseMeta('// ==UserScript==\n// @name x\n// @run-at document-body\n// ==/UserScript==').runAt, 'document-end');
  assert.equal(core.parseMeta('// ==UserScript==\n// @name x\n// ==/UserScript==').runAt, 'document-idle');
});

test('规则组合判定：match 去 #，exclude 生效，无规则 = 所有 http(s)', () => {
  const rules = core.compileRules(core.parseMeta(SAMPLE));
  assert.equal(core.rulesMatch(rules, 'https://www.example.com/a#b'), true);
  assert.equal(core.rulesMatch(rules, 'https://www.example.com/admin/x'), false);
  assert.equal(core.rulesMatch(rules, 'HTTPS://OTHER.org/x'), true);
  assert.equal(core.rulesMatch(rules, 'https://evil.org/'), false);
  const all = core.compileRules(core.parseMeta('// ==UserScript==\n// @name a\n// ==/UserScript=='));
  assert.equal(all.matchAll, true);
  assert.equal(core.rulesMatch(all, 'http://x.y/'), true);
  assert.equal(core.rulesMatch(all, 'file:///x'), false);
  const bad = core.compileRules(core.parseMeta('// ==UserScript==\n// @name a\n// @match nope\n// ==/UserScript=='));
  assert.deepEqual(bad.invalid, ['nope']);
});

test('版本比较（Tampermonkey 风格）', () => {
  assert.equal(core.compareVersions('1.10', '1.9'), 1);
  assert.equal(core.compareVersions('1.0', '1.0.0'), 0);
  assert.equal(core.compareVersions('1.0b', '1.0'), -1);
  assert.equal(core.compareVersions('1.0a', '1.0b'), -1);
  assert.equal(core.compareVersions('2', '10'), -1);
});

test('@connect 判定', () => {
  assert.equal(core.connectVerdict('www.a.com', 'www.a.com', []), 'sameOrigin');
  assert.equal(core.connectVerdict('api.b.com', 'a.com', ['b.com']), 'declared');
  assert.equal(core.connectVerdict('evilb.com', 'a.com', ['b.com']), 'undeclared');
  assert.equal(core.connectVerdict('x.a.com', 'x.a.com:8080', []), 'sameOrigin');
  assert.equal(core.connectVerdict('a.com', 'b.com', ['*']), 'declared');
  assert.equal(core.connectVerdict('sub.a.com', 'a.com', ['self']), 'declared');
  assert.equal(core.normalizeHost('https://[::1]:8080/x'), '::1');
});

test('安装地址：GitHub blob → raw，Greasy Fork 脚本页 → 安装地址', () => {
  assert.equal(core.installURL('https://github.com/u/r/blob/main/a/b.user.js'), 'https://raw.githubusercontent.com/u/r/main/a/b.user.js');
  assert.equal(core.installURL('https://greasyfork.org/zh-CN/scripts/12345-some-name'), 'https://greasyfork.org/scripts/12345/code/script.user.js');
  assert.equal(core.installURL('https://greasyfork.org/scripts/12345-x/code/x.user.js'), 'https://greasyfork.org/scripts/12345-x/code/x.user.js');
  assert.equal(core.installURL('ftp://x/y'), null);
  assert.equal(core.installURL('https://a.test/x.user.js#frag'), 'https://a.test/x.user.js');
  assert.equal(core.looksLikeUserScript('https://a.test/X.USER.JS?x=1'), true);
  assert.equal(core.looksLikeUserScript('https://a.test/x.js'), false);
  const m = core.parseMeta(SAMPLE);
  assert.equal(core.updateCheckURL(m, null), 'https://mio.test/demo.meta.js');
  assert.equal(core.downloadURL(m, null), 'https://mio.test/demo.user.js');
});

function tmpStore() {
  return new UserScriptStore(fs.mkdtempSync(path.join(os.tmpdir(), 'mio-us-')));
}

test('存储：安装 / 同身份更新保留 id、启用状态和 GM 值；删除连同数据；重新加载', () => {
  const st = tmpStore();
  const meta = core.parseMeta(SAMPLE);
  const a = st.install({ meta, code: SAMPLE, sourceURL: 'https://mio.test/demo.user.js' });
  st.setEnabled(a.id, false);
  assert.equal(st.setValue(a.id, 'k', '"v"'), true);
  st.setConnectDecision(a.id, 'api.example.net', true);
  st.setConnectDecision(a.id, 'gone.test', true);
  const meta2 = core.parseMeta(SAMPLE.replace('1.2.0', '1.3.0').replace('@connect      api.example.net', '@connect      api.example.net'));
  const b = st.install({ meta: meta2, code: SAMPLE });
  assert.equal(b.id, a.id);
  assert.equal(b.enabled, false);
  assert.equal(b.meta.version, '1.3.0');
  assert.deepEqual(b.connectDecisions, { 'api.example.net': true }, '不再声明的授权丢弃');
  const re = new UserScriptStore(st.dir);
  assert.equal(re.scripts.length, 1);
  assert.deepEqual(re.values(a.id), { k: '"v"' });
  re.delete(a.id);
  assert.equal(re.scripts.length, 0);
  assert.deepEqual(new UserScriptStore(st.dir).values(a.id), {});
});

test('GM 值：按脚本隔离、上限 5 MB、路径穿越无效', () => {
  const st = tmpStore();
  st.setValue('a', 'x', '1');
  st.setValue('b', 'x', '2');
  assert.deepEqual(st.values('a'), { x: '1' });
  assert.deepEqual(st.values('b'), { x: '2' });
  assert.equal(st.setValue('a', 'big', 'x'.repeat(core.MAX_VALUE_BYTES)), false);
  assert.deepEqual(st.values('a'), { x: '1' });
  st.setValue('../../evil', 'k', '1');
  assert.ok(st.valueFile('../../evil').startsWith(st.valuesDir));
  st.deleteValue('a', 'x');
  assert.deepEqual(new UserScriptStore(st.dir).values('a'), {});
});

test('scriptsFor：只给匹配 / 启用的脚本；@noframes 不给子 frame；隔离脚本带值快照和桥名', () => {
  const st = tmpStore();
  const s = st.install({ meta: core.parseMeta(SAMPLE), code: SAMPLE, requireCache: { 'https://cdn.test/lib.js': 'window.__lib=1' }, resourceCache: { css: 'b{}' } });
  st.setValue(s.id, 'n', '5');
  const none = st.install({ meta: core.parseMeta('// ==UserScript==\n// @name plain\n// @grant none\n// ==/UserScript==\nwindow.__plain=1'), code: '// ==UserScript==\n// @name plain\n// @grant none\n// ==/UserScript==\nwindow.__plain=1' });
  let list = st.scriptsFor('https://www.example.com/x', { isTop: true });
  assert.deepEqual(list.map((x) => [x.id, x.isolated, x.world]), [[s.id, true, 1100], [none.id, false, 1101]]);
  assert.ok(list[0].source.includes('"bridge":"mioUserScriptNative"'));
  assert.ok(list[0].source.includes('"values":{"n":"5"}'));
  assert.ok(list[0].source.includes('window.__lib=1'));
  assert.ok(!list[1].source.includes('"n":"5"'));
  list = st.scriptsFor('https://www.example.com/x', { isTop: false });
  assert.deepEqual(list.map((x) => x.id), [none.id]);
  st.setEnabled(none.id, false);
  assert.deepEqual(st.scriptsFor('https://evil.org/', { isTop: true }), []);
  assert.deepEqual(st.scriptsFor('about:blank'), []);
});

test('注入代码：运行时 + 配置 + @require 内联 + 参数表与 Swift 相同', () => {
  const rt = core.runtime();
  const swift = fs.readFileSync(path.join(__dirname, '../../ios/App/App/MioUserScriptCore.swift'), 'utf8');
  const params = /static let apiParams = "([^"]*)"/.exec(swift)[1];
  assert.equal(rt.params, params);
  const src = core.buildSource({ id: 'x', meta: core.parseMeta(SAMPLE), code: 'BODY()', requireCache: { 'https://cdn.test/lib.js': 'LIB()' } }, {}, { appVersion: '9' });
  assert.ok(src.indexOf('LIB()') < src.indexOf('BODY()'));
  assert.ok(src.endsWith('});\n'));
  assert.ok(/function\(GM, GM_info, unsafeWindow/.test(src));
});

function fakeFetch(map) {
  return async (url, opts = {}) => {
    const h = map[url];
    if (!h) return { ok: false, status: 404, arrayBuffer: async () => new ArrayBuffer(0) };
    const r = typeof h === 'function' ? h(url, opts) : { body: h };
    const buf = Buffer.from(r.body);
    return {
      ok: (r.status || 200) < 300, status: r.status || 200, statusText: 'OK', url: r.url || url,
      headers: new Map(Object.entries(r.headers || { 'content-type': 'text/plain' })),
      arrayBuffer: async () => buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength),
    };
  };
}

test('安装：下载 @require / @resource；sha256 校验失败不安装；更新检查走 .meta.js', async () => {
  const lib = 'window.__lib = 1;';
  const sha = crypto.createHash('sha256').update(lib).digest('hex');
  const code = SAMPLE.replace('https://cdn.test/lib.js', `https://cdn.test/lib.js#sha256=${sha}`);
  const f = fakeFetch({ 'https://cdn.test/lib.js': lib, 'https://cdn.test/a.css': 'a{}' });
  const pkg = await prepare(code, 'https://mio.test/demo.user.js', f);
  assert.equal(pkg.requireCache[`https://cdn.test/lib.js#sha256=${sha}`], lib);
  assert.equal(pkg.resourceCache.css, 'a{}');
  await assert.rejects(prepare(code.replace(sha, '0'.repeat(64)), null, f), /校验失败/);
  assert.throws(() => verifyIntegrity(Buffer.from('x'), 'sha512=abc', 'https://a/x.js'), /校验失败/);

  const st = tmpStore();
  const s = st.install(pkg);
  const newer = code.replace('1.2.0', '1.3.0');
  const f2 = fakeFetch({ 'https://mio.test/demo.meta.js': newer.split('window.__ran')[0], 'https://mio.test/demo.user.js': newer, 'https://cdn.test/lib.js': lib, 'https://cdn.test/a.css': 'a{}' });
  const up = await checkUpdate(s, f2);
  assert.equal(up.meta.version, '1.3.0');
  const same = fakeFetch({ 'https://mio.test/demo.meta.js': code.split('window.__ran')[0] });
  assert.equal(await checkUpdate(s, same), null);
});

test('GM_xmlhttpRequest 代发：请求头过滤、Basic 认证、匿名不带 Cookie、二进制、超时', async () => {
  let seen;
  const f = fakeFetch({
    'https://api.test/x': (url, opts) => { seen = opts; return { body: '{"a":1}', headers: { 'content-type': 'application/json; charset=utf-8', 'x-y': 'z' } }; },
  });
  const r = await performXhr({ url: 'https://api.test/x', method: 'post', headers: { Host: 'evil', 'X-A': '1' }, body: { text: 'hi' }, user: 'u', password: 'p', userAgent: 'UA' }, { fetchImpl: f });
  assert.equal(r.status, 200);
  assert.equal(r.text, '{"a":1}');
  assert.match(r.headers, /x-y: z/);
  assert.equal(seen.method, 'POST');
  assert.equal(seen.body, 'hi');
  assert.equal(seen.headers.Host, undefined);
  assert.equal(seen.headers['X-A'], '1');
  assert.equal(seen.headers['User-Agent'], 'UA');
  assert.equal(seen.headers.Authorization, 'Basic ' + Buffer.from('u:p').toString('base64'));
  assert.equal(seen.credentials, 'include');
  await performXhr({ url: 'https://api.test/x', anonymous: true }, { fetchImpl: f });
  assert.equal(seen.credentials, 'omit');
  const bin = await performXhr({ url: 'https://api.test/x', responseType: 'arraybuffer', body: { base64: 'AAE=' }, method: 'PUT' }, { fetchImpl: f });
  assert.equal(bin.base64, Buffer.from('{"a":1}').toString('base64'));
  assert.deepEqual([...seen.body], [0, 1]);
  const slow = (url, opts) => new Promise((_, rej) => opts.signal.addEventListener('abort', () => rej(new Error('aborted'))));
  const t = await performXhr({ url: 'https://slow.test/', timeout: 20 }, { fetchImpl: slow });
  assert.deepEqual(t, { error: 'timeout', timeout: true });
  const ctrl = new AbortController();
  const p = performXhr({ url: 'https://slow.test/' }, { fetchImpl: slow, signal: ctrl.signal });
  ctrl.abort();
  assert.deepEqual(await p, { error: 'aborted' });
});
