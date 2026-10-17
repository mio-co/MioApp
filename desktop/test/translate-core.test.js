'use strict';
// 翻译原生侧纯逻辑：请求白名单 / Key 只在原生加 / 正则摘取 / 设置校验 / 持久缓存 / 注入脚本配置
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const core = require('../src/translate-core');

const tmp = () => fs.mkdtempSync(path.join(os.tmpdir(), 'mio-tr-'));

test('checkRequest：只放行免费引擎域名和用户配置的 OpenAI 地址', () => {
  const s = { openaiBase: 'https://api.example.com/v1' };
  assert.equal(core.checkRequest({ url: 'https://www.bing.com/ttranslatev3?x=1', method: 'POST', body: 'a=b' }, s).ok, true);
  assert.equal(core.checkRequest({ url: 'https://translate.googleapis.com/translate_a/t' }, s).ok, true);
  assert.equal(core.checkRequest({ url: 'http://www.bing.com/x' }, s).ok, false, '免费引擎只允许 https');
  assert.equal(core.checkRequest({ url: 'https://evil.example.org/steal' }, s).ok, false);
  assert.equal(core.checkRequest({ url: 'https://api.example.com/v1/chat/completions', method: 'POST', auth: 'openai' }, s).auth, 'openai');
  assert.equal(core.checkRequest({ url: 'https://api.example.com/v1/models', auth: 'openai' }, s).ok, false, 'Key 只给 chat/completions');
  assert.equal(core.checkRequest({ url: 'https://www.bing.com/x', auth: 'openai' }, s).ok, false, '不能把 Key 发给别的域名');
  assert.equal(core.checkRequest({ url: 'https://api.example.com/v1/chat/completions', auth: 'openai' }, {}).ok, false, '没配置时不放行');
  assert.equal(core.checkRequest({ url: 'https://www.bing.com/x', method: 'DELETE' }, s).ok, false);
  assert.equal(core.checkRequest({ url: 'https://www.bing.com/x', method: 'GET', body: 'x' }, s).ok, false);
  assert.equal(core.checkRequest({ url: 'https://www.bing.com/x', method: 'POST', body: 'x'.repeat(300000) }, s).ok, false);
});

test('checkRequest：过滤请求头，Authorization 只给 Edge 翻译 API', () => {
  const r = core.checkRequest({ url: 'https://www.bing.com/x', method: 'POST', headers: { 'Content-Type': 'a', Cookie: 'x', Authorization: 'Bearer t', 'X-Evil': '1' } }, {});
  assert.deepEqual(r.headers, { 'content-type': 'a' });
  const e = core.checkRequest({ url: 'https://api-edge.cognitive.microsofttranslator.com/translate', method: 'POST', headers: { Authorization: 'Bearer t' } }, {});
  assert.equal(e.headers.authorization, 'Bearer t');
  assert.equal(core.checkRequest({ url: 'https://www.bing.com/x', timeoutMs: 999999 }, {}).timeoutMs, 90000);
});

test('performFetch：OpenAI 由原生加 Key；超时；picks', async () => {
  const s = { openaiBase: 'https://api.example.com/v1/' };
  const seen = [];
  const fetchImpl = async (url, init) => {
    seen.push({ url, init });
    return { status: 200, text: async () => 'xx IG:"ABC123" yy params_AbusePreventionHelper = [17,"TOK",3600000]' };
  };
  const c = core.checkRequest({ url: 'https://api.example.com/v1/chat/completions', method: 'POST', auth: 'openai', body: '{}' }, s);
  const r = await core.performFetch(c, { key: 'sk-secret', fetchImpl });
  assert.equal(r.status, 200);
  assert.equal(seen[0].init.headers.authorization, 'Bearer sk-secret');
  assert.deepEqual(await core.performFetch(c, { key: '', fetchImpl }), { error: '没有设置 API Key' });

  const p = core.checkRequest({ url: 'https://www.bing.com/translator', pick: ['IG:"([0-9A-F]+)"', 'nomatch(\\d)', 'params_AbusePreventionHelper\\s*=\\s*\\[(\\d+),"([^"]+)",(\\d+)'] }, {});
  const pr = await core.performFetch(p, { fetchImpl });
  assert.deepEqual(pr, { status: 200, picks: [['ABC123'], null, ['17', 'TOK', '3600000']] });

  const slow = core.checkRequest({ url: 'https://www.bing.com/x', timeoutMs: 1000 }, {});
  const t = await core.performFetch(slow, {
    fetchImpl: (url, init) => new Promise((_, rej) => init.signal.addEventListener('abort', () => rej(new Error('aborted')))),
  });
  assert.deepEqual(t, { error: 'timeout' });
});

test('TranslateSettings：校验、自动翻译站点、Key 不出现在 publicView', () => {
  const dir = tmp();
  const s = new core.TranslateSettings(path.join(dir, 't.json'));
  assert.equal(s.get('target'), 'zh-CN');
  s.set('target', 'ja');
  assert.throws(() => s.set('target', 'xx'));
  assert.throws(() => s.set('engine', 'deepl'));
  assert.throws(() => s.set('openaiBase', 'ftp://x'));
  s.set('openaiBase', 'https://api.example.com/v1/?q=1');
  assert.equal(s.get('openaiBase'), 'https://api.example.com/v1');
  s.setAuto('https://www.Example.com/path', true);
  assert.deepEqual(s.get('autoSites'), ['example.com']);
  assert.ok(s.isAuto('docs.example.com'));
  s.setAuto('docs.example.com', false);
  assert.deepEqual(s.get('autoSites'), []);
  assert.throws(() => s.setAuto('not a host', true));
  s.setKeyEnc('ENC');
  const v = s.publicView();
  assert.equal(v.hasKey, true);
  assert.equal('openaiKeyEnc' in v, false);
  const again = new core.TranslateSettings(path.join(dir, 't.json'));
  assert.equal(again.get('target'), 'ja');
  assert.equal(again.openaiReady(), false, '没有模型');
});

test('TranslateCache：LRU、上限、写盘后重新读取', () => {
  const dir = tmp();
  const f = path.join(dir, 'c.json');
  const c = new core.TranslateCache(f, 3);
  c.put({ a: '1', b: '2', c: '3' });
  assert.deepEqual(c.get(['a']), { a: '1' });
  c.put({ d: '4' });
  assert.deepEqual(c.get(['a', 'b', 'c', 'd']), { a: '1', c: '3', d: '4' });
  c.put({ big: 'x'.repeat(30000) });
  assert.deepEqual(c.get(['big']), {});
  c.flush();
  const c2 = new core.TranslateCache(f, 3);
  assert.equal(c2.size, 3);
  assert.deepEqual(c2.get(['d']), { d: '4' });
  c2.clear();
  assert.equal(c2.size, 0);
});

test('注入脚本：配置替换占位符（base64，不含 Key），模板存在', () => {
  const tpl = fs.readFileSync(path.join(__dirname, '..', '..', 'shared', 'translate', 'mio-translate.js'), 'utf8');
  const s = new core.TranslateSettings(null);
  s.data.openaiKeyEnc = 'SECRET';
  s.data.openaiBase = 'https://x/v1';
  s.data.openaiModel = 'm';
  const cfg = core.buildConfig(s.data, 'tok', 'desktop');
  assert.equal(cfg.openai.ready, true);
  assert.ok(!JSON.stringify(cfg).includes('SECRET'));
  const out = core.scriptWithConfig(tpl, cfg);
  assert.ok(!out.includes("'__MIO_TRANSLATE_CONFIG__'"));
  const b64 = /var CONFIG_B64 = '([^']+)'/.exec(out)[1];
  assert.equal(JSON.parse(Buffer.from(b64, 'base64').toString('utf8')).token, 'tok');
  assert.throws(() => core.scriptWithConfig('nothing', cfg));
  // 打包时（electron-builder extraResources）或开发时都能找到脚本
  assert.ok(core.scriptCandidates(path.join(__dirname, '..', 'src'), null).some((f) => fs.existsSync(f)));
});
