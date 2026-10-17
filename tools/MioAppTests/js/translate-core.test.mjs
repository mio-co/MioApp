// 翻译纯逻辑：语言识别 / 段落选取规则 / 批处理切分 / 缓存 / 引擎请求与解析 / 引擎回退（全部 mock，不访问网络）
import test from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';
import { loadCore } from './translate-harness.mjs';

const C = loadCore();
const plain = (x) => JSON.parse(JSON.stringify(x));

test('normLang / engineLang', () => {
  assert.equal(C.normLang('zh-Hans'), 'zh-CN');
  assert.equal(C.normLang('zh_CN'), 'zh-CN');
  assert.equal(C.normLang('zh-Hant-TW'), 'zh-TW');
  assert.equal(C.normLang('zh-HK'), 'zh-TW');
  assert.equal(C.normLang('pt-BR'), 'pt');
  assert.equal(C.engineLang('microsoft', 'zh-CN'), 'zh-Hans');
  assert.equal(C.engineLang('microsoft', 'zh-TW'), 'zh-Hant');
  assert.equal(C.engineLang('google', 'zh-CN'), 'zh-CN');
  assert.equal(C.engineLang('openai', 'ja'), 'Japanese');
  assert.ok(C.sameLang('zh-Hans', 'zh-TW'));
  assert.ok(!C.sameLang('en', 'zh-CN'));
});

test('guessLang / isAlreadyTarget', () => {
  assert.equal(C.guessLang('今天天气很好，我们去公园散步吧。'), 'zh');
  assert.equal(C.guessLang('今日はとても良い天気ですね。'), 'ja');
  assert.equal(C.guessLang('오늘은 날씨가 좋네요'), 'ko');
  assert.equal(C.guessLang('The quick brown fox jumps over the lazy dog and the cat.'), 'en');
  assert.equal(C.guessLang('Le chat est sur la table et il dort.'), 'fr');
  assert.equal(C.guessLang('Привет, как дела?'), 'ru');
  assert.equal(C.guessLang('12:30 — 45%'), null);
  assert.ok(C.isAlreadyTarget('这是中文段落，包含 iPhone 和 GitHub。', 'zh-CN'));
  assert.ok(C.isAlreadyTarget('這是繁體中文。', 'zh-CN'), '简繁视为同一种');
  assert.ok(!C.isAlreadyTarget('This is an English paragraph about the web.', 'zh-CN'));
  assert.ok(C.isAlreadyTarget('This is an English paragraph about the web.', 'en'));
  assert.ok(!C.isAlreadyTarget('今日はとても良い天気ですね。', 'zh-CN'), '日文不当成中文');
});

test('makeBatches: 条数 / 字数上限、超长单条独立成批、保持顺序', () => {
  const texts = ['a'.repeat(300), 'b'.repeat(300), 'c'.repeat(300), 'd'.repeat(2000), 'e', 'f'];
  const b = C.makeBatches(texts, { maxItems: 50, maxChars: 900, sepLen: 1 });
  assert.deepEqual(plain(JSON.parse(JSON.stringify(b))), [[0, 1], [2], [3], [4, 5]]);
  const many = Array.from({ length: 120 }, (_, i) => 'x' + i);
  const b2 = C.makeBatches(many, { maxItems: 50, maxChars: 100000 });
  assert.deepEqual(plain(b2.map((x) => x.length)), [50, 50, 20]);
  assert.deepEqual(plain([].concat(...b2)), many.map((_, i) => i));
  assert.deepEqual(plain(JSON.parse(JSON.stringify(C.makeBatches([], {})))), []);
});

test('LRU 缓存：最近使用的保留，超出上限淘汰最旧', () => {
  const l = new C.LRU(3);
  l.set('a', 1); l.set('b', 2); l.set('c', 3);
  assert.equal(l.get('a'), 1); // a 变成最新
  l.set('d', 4);
  assert.equal(l.has('b'), false);
  assert.equal(l.get('a'), 1);
  assert.equal(l.size, 3);
});

test('cacheKey 区分引擎 / 目标语言 / 文本', () => {
  const k1 = C.cacheKey('microsoft', 'zh-CN', 'Hello');
  assert.equal(k1, C.cacheKey('microsoft', 'zh-Hans', 'Hello'));
  assert.notEqual(k1, C.cacheKey('google', 'zh-CN', 'Hello'));
  assert.notEqual(k1, C.cacheKey('microsoft', 'ja', 'Hello'));
  assert.notEqual(k1, C.cacheKey('microsoft', 'zh-CN', 'Hello!'));
  assert.ok(k1.length < 64);
});

function dom(html) {
  return new JSDOM(`<!doctype html><html><body>${html}</body></html>`).window.document;
}
const texts = (units) => units.map((u) => u.text);

test('段落选取：块级元素里的行内内容是一段；跳过 code/pre/输入框/notranslate/已是目标语言', () => {
  const d = dom(`
    <article>
      <h1>Hello <em>World</em> title</h1>
      <p>First paragraph with a <a href="#">link</a> and <code>inline_code()</code> inside.</p>
      <pre>const x = "do not translate";</pre>
      <p><code>only_code()</code></p>
      <div class="notranslate">Brand Name Here</div>
      <p translate="no">Keep me as is</p>
      <textarea>user typing here</textarea>
      <p>这是一段中文，不需要翻译。</p>
      <ul><li>Item one text</li><li>Item two <b>bold</b><ul><li>Nested item</li></ul></li></ul>
      <div>Leading text in div<p>Para inside div</p>trailing words</div>
      <button>Click me</button>
      <p>12:30</p>
      <script>var notText = "x";</script>
      <ytd-text-renderer><span>Custom element text content</span></ytd-text-renderer>
    </article>`);
  const u = C.collectUnits(d.body, { target: 'zh-CN' });
  assert.deepEqual(plain(texts(u)), [
    'Hello World title',
    'First paragraph with a link and inline_code() inside.',
    'Item one text',
    'Item two bold',
    'Nested item',
    'Leading text in div',
    'Para inside div',
    'trailing words',
    'Custom element text content',
  ]);
  const h1 = u[0];
  assert.equal(h1.el.tagName, 'H1');
  assert.equal(h1.whole, true);
  const li2 = u[3];
  assert.equal(li2.el.tagName, 'LI');
  assert.equal(li2.whole, false, '后面还有嵌套列表：译文插在 run 之后');
  assert.equal(li2.nodes[li2.nodes.length - 1].tagName, 'B');
  assert.equal(u[8].el.tagName, 'ARTICLE', '自定义元素只含行内内容：并入父级的段落');
});

test('段落选取：链接包着块级卡片时按块处理；已插入的译文不重复收集', () => {
  const d = dom(`<div><a href="/x"><div>Card title text</div><div>Card description goes here</div></a></div>
    <p>Already done<mio-tr data-mio-tr>已经翻译</mio-tr></p>`);
  const u = C.collectUnits(d.body, { target: 'zh-CN' });
  assert.deepEqual(plain(texts(u)), ['Card title text', 'Card description goes here', 'Already done']);
  assert.equal(u[2].whole, true);
});

test('段落选取：contenteditable / aria-hidden / hidden 跳过', () => {
  const d = dom(`<div contenteditable="true"><p>Editor content</p></div><p aria-hidden="true">Decor text</p><p hidden>Hidden text</p><p>Visible text</p>`);
  assert.deepEqual(plain(texts(C.collectUnits(d.body, { target: 'zh-CN' }))), ['Visible text']);
});

test('blockAncestor 找最近的块级祖先', () => {
  const d = dom(`<p id="p">Hello <b><i id="i">x</i></b></p>`);
  assert.equal(C.blockAncestor(d.getElementById('i'), d.body).id, 'p');
  assert.equal(C.blockAncestor(d.getElementById('i').firstChild, d.body).id, 'p');
});

test('hostMatches / siteAuto', () => {
  assert.ok(C.hostMatches('www.example.com', 'example.com'));
  assert.ok(C.hostMatches('example.com', 'www.example.com'));
  assert.ok(C.hostMatches('a.b.example.com', '*.example.com'));
  assert.ok(!C.hostMatches('notexample.com', 'example.com'));
  assert.ok(C.siteAuto('news.ycombinator.com', ['ycombinator.com']));
  assert.ok(!C.siteAuto('x.com', []));
});

// ---------------------------------------------------------------- 引擎请求 / 解析

test('Bing（微软）：参数提取、请求、按行解析、行数不符报错', () => {
  const now = 1_800_000_000_000;
  const p = C.bingParamsFromPicks([['IGX'], ['translator.5026'], [String(now - 1000), 'TOK', '3600000']], now);
  assert.equal(p.ig, 'IGX');
  assert.equal(p.iid, 'translator.5026');
  assert.ok(p.exp > now && p.exp < now + 3600000);
  assert.equal(C.bingParamsFromPicks([null, null, null], now), null);
  const req = C.bingRequest(['Hello', 'World'], 'zh-CN', p, 3);
  assert.match(req.url, /^https:\/\/www\.bing\.com\/ttranslatev3\?isVertical=1&IG=IGX&IID=translator\.5026\.3$/);
  const body = new URLSearchParams(req.body);
  assert.equal(body.get('text'), 'Hello\nWorld');
  assert.equal(body.get('to'), 'zh-Hans');
  assert.equal(body.get('token'), 'TOK');
  const ok = JSON.stringify([{ detectedLanguage: { language: 'en' }, translations: [{ text: '你好\n世界', to: 'zh-Hans' }] }]);
  assert.deepEqual(plain(JSON.parse(JSON.stringify(C.parseBing(ok, 2)))), [{ text: '你好', detected: 'en' }, { text: '世界', detected: 'en' }]);
  assert.throws(() => C.parseBing(ok, 3), /count/);
  assert.throws(() => C.parseBing('{"statusCode":205}', 1), (e) => e.kind === 'auth');
  // 正则在原生侧执行：确认能匹配真实页面片段
  const page = 'x;IG:"6F33281EA7124DA59F5AA885EEDCB22C",y data-iid="translator.5023" var params_AbusePreventionHelper = [1792195186283,"Y0RQ",3600000];';
  const picks = C.BING_PICKS.map((re) => { const m = new RegExp(re).exec(page); return m ? m.slice(1) : null; });
  assert.deepEqual(plain(picks), [['6F33281EA7124DA59F5AA885EEDCB22C'], ['translator.5023'], ['1792195186283', 'Y0RQ', '3600000']]);
});

test('Edge API（微软旧端点）：请求与解析', () => {
  const req = C.msEdgeRequest(['a', 'b'], 'zh-TW', 'JWT');
  assert.match(req.url, /to=zh-Hant/);
  assert.equal(req.headers.Authorization, 'Bearer JWT');
  assert.deepEqual(plain(JSON.parse(req.body)), [{ Text: 'a' }, { Text: 'b' }]);
  const r = C.parseMsEdge(JSON.stringify([{ translations: [{ text: '甲' }], detectedLanguage: { language: 'en' } }, { translations: [{ text: '乙' }] }]), 2);
  assert.equal(r[0].text, '甲');
  assert.equal(r[0].detected, 'en');
  assert.throws(() => C.parseMsEdge('[]', 2));
});

test('谷歌：批量请求（多个 q）与两种返回格式', () => {
  const req = C.googleRequest(['Hello', 'Good & bad'], 'zh-CN');
  assert.match(req.url, /translate_a\/t\?client=gtx&sl=auto&tl=zh-CN&format=text/);
  assert.deepEqual(plain(new URLSearchParams(req.body).getAll('q')), ['Hello', 'Good & bad']);
  assert.deepEqual(plain(C.parseGoogle('[["你好","en"],["好与坏","en"]]', 2).map((x) => x.text)), ['你好', '好与坏']);
  assert.deepEqual(plain(C.parseGoogle('["你好","再见"]', 2).map((x) => x.text)), ['你好', '再见']);
  assert.deepEqual(plain(C.parseGoogle('["你好","en"]', 1).map((x) => x.text)), ['你好']);
  assert.throws(() => C.parseGoogle('[["a","en"]]', 2));
  const single = C.parseGoogleSingle('[[["你好。","Hello.",null],["世界","World",null]],null,"en"]');
  assert.equal(single.text, '你好。世界');
  assert.equal(single.detected, 'en');
});

test('OpenAI 兼容：端点、请求（Key 不在脚本里）、解析容错', () => {
  assert.equal(C.openaiEndpoint('https://api.openai.com/v1/'), 'https://api.openai.com/v1/chat/completions');
  assert.equal(C.openaiEndpoint('https://x.test/v1/chat/completions'), 'https://x.test/v1/chat/completions');
  const req = C.openaiRequest(['Hi', 'Bye'], 'zh-CN', { base: 'https://api.example.com/v1', model: 'm1', prompt: 'Use casual tone' });
  assert.equal(req.auth, 'openai');
  assert.equal(req.headers.Authorization, undefined);
  const body = JSON.parse(req.body);
  assert.equal(body.model, 'm1');
  assert.match(body.messages[0].content, /Simplified Chinese/);
  assert.match(body.messages[0].content, /Use casual tone/);
  assert.deepEqual(plain(JSON.parse(body.messages[1].content)), ['Hi', 'Bye']);
  const wrap = (content) => JSON.stringify({ choices: [{ message: { content } }] });
  assert.deepEqual(plain(C.parseOpenAI(wrap('["嗨","再见"]'), 2).map((x) => x.text)), ['嗨', '再见']);
  assert.deepEqual(plain(C.parseOpenAI(wrap('```json\n["嗨","再见"]\n```'), 2).map((x) => x.text)), ['嗨', '再见']);
  assert.deepEqual(plain(C.parseOpenAI(wrap('{"translations":["嗨","再见"]}'), 2).map((x) => x.text)), ['嗨', '再见']);
  assert.throws(() => C.parseOpenAI(wrap('["只有一条"]'), 2), /count/);
  assert.throws(() => C.parseOpenAI(JSON.stringify({ error: { message: 'invalid key' } }), 1), /invalid key/);
});

test('engineChain：用户选的在前，其后免费引擎；OpenAI 未配置时跳过', () => {
  assert.deepEqual(plain(C.engineChain('openai', true)), ['openai', 'microsoft', 'google']);
  assert.deepEqual(plain(C.engineChain('openai', false)), ['microsoft', 'google']);
  assert.deepEqual(plain(C.engineChain('google', true)), ['google', 'microsoft']);
  assert.deepEqual(plain(C.engineChain('microsoft', false)), ['microsoft', 'google']);
});

// ---------------------------------------------------------------- 翻译服务：缓存 + 回退

function memCache() {
  const m = new Map();
  return {
    m,
    cacheGet: async (keys) => Object.fromEntries(keys.filter((k) => m.has(k)).map((k) => [k, m.get(k)])),
    cachePut: async (e) => { for (const [k, v] of Object.entries(e)) m.set(k, v); },
  };
}

test('翻译服务：OpenAI 超时 / 失败 → 自动回退微软（Edge 404 → Bing），结果写入持久缓存', async () => {
  const reqs = [];
  const cache = memCache();
  const t = C.createTranslator({ engine: 'openai', target: 'zh-CN', openai: { ready: true, base: 'https://ai.test/v1', model: 'm' } }, {
    ...cache,
    http: async (req) => {
      reqs.push(req);
      if (req.url.startsWith('https://ai.test')) return { error: 'timeout' };
      if (req.url.startsWith('https://edge.microsoft.com')) return { status: 404, body: '' };
      if (req.url.startsWith('https://www.bing.com/translator')) return { status: 200, picks: [['IG'], ['translator.1'], [String(Date.now()), 'T', '3600000']] };
      if (req.url.startsWith('https://www.bing.com/ttranslatev3')) {
        const lines = new URLSearchParams(req.body).get('text').split('\n');
        return { status: 200, body: JSON.stringify([{ translations: [{ text: lines.map((l) => '微:' + l).join('\n') }], detectedLanguage: { language: 'en' } }]) };
      }
      throw new Error('unexpected ' + req.url);
    },
  });
  const out = await t.translate(['Hello', 'World', 'Hello'], 'zh-CN');
  assert.deepEqual(plain(out.map((x) => x.text)), ['微:Hello', '微:World', '微:Hello']);
  assert.equal(out[0].engine, 'microsoft');
  assert.equal(reqs.filter((r) => r.url.startsWith('https://ai.test')).length, 1, '同一批只请求一次 OpenAI');
  assert.equal(reqs.filter((r) => r.url.includes('ttranslatev3')).length, 1, '重复文本去重');
  assert.equal(reqs.find((r) => r.url.startsWith('https://ai.test')).timeoutMs, 45000);
  assert.ok(t.stats.fallbacks >= 1);
  assert.ok(cache.m.has('__edge_dead'), 'Edge 端点 404 记 24 小时');
  assert.ok(cache.m.has('__bing_params'));
  // 第二次：全部命中缓存，不发请求
  const n = reqs.length;
  const again = await t.translate(['World'], 'zh-CN');
  assert.equal(again[0].text, '微:World');
  assert.equal(reqs.length, n);
  // 新实例（新页面）：从持久缓存读
  const t2 = C.createTranslator({ engine: 'openai', target: 'zh-CN', openai: { ready: true, base: 'https://ai.test/v1', model: 'm' } }, {
    ...cache,
    http: async () => { throw new Error('should not fetch'); },
  });
  assert.equal((await t2.translate(['Hello'], 'zh-CN'))[0].text, '微:Hello');
});

test('翻译服务：Bing 行数对不上 → 回退谷歌；全部失败 → reject', async () => {
  const cache = memCache();
  const http = async (req) => {
    if (req.url.startsWith('https://edge.microsoft.com')) return { status: 404, body: '' };
    if (req.url.startsWith('https://www.bing.com/translator')) return { status: 200, picks: [['IG'], ['translator.1'], [String(Date.now()), 'T', '3600000']] };
    if (req.url.startsWith('https://www.bing.com/ttranslatev3')) return { status: 200, body: JSON.stringify([{ translations: [{ text: '合并成一行' }] }]) };
    if (req.url.startsWith('https://translate.googleapis.com/translate_a/t')) {
      const qs = new URLSearchParams(req.body).getAll('q');
      return { status: 200, body: JSON.stringify(qs.map((q) => ['谷:' + q, 'en'])) };
    }
    return { status: 500, body: '' };
  };
  const t = C.createTranslator({ engine: 'microsoft', target: 'zh-CN' }, { ...cache, http });
  const out = await t.translate(['One', 'Two'], 'zh-CN');
  assert.deepEqual(plain(out.map((x) => [x.text, x.engine])), [['谷:One', 'google'], ['谷:Two', 'google']]);

  const dead = C.createTranslator({ engine: 'google', target: 'zh-CN' }, { ...memCache(), http: async () => ({ status: 503, body: '' }) });
  await assert.rejects(dead.translate(['x y z'], 'zh-CN'));
});

test('翻译服务：Bing 令牌失效（205）时刷新一次参数再试', async () => {
  let pageFetches = 0, calls = 0;
  const t = C.createTranslator({ engine: 'microsoft', target: 'ja' }, {
    ...memCache(),
    http: async (req) => {
      if (req.url.startsWith('https://edge.microsoft.com')) return { status: 404 };
      if (req.url.startsWith('https://www.bing.com/translator')) { pageFetches++; return { status: 200, picks: [['IG' + pageFetches], ['translator.1'], [String(Date.now()), 'T', '3600000']] }; }
      calls++;
      if (calls === 1) return { status: 200, body: '{"statusCode":205}' };
      assert.match(req.url, /IG=IG2/);
      assert.equal(new URLSearchParams(req.body).get('to'), 'ja');
      return { status: 200, body: JSON.stringify([{ translations: [{ text: 'こんにちは' }] }]) };
    },
  });
  const out = await t.translate(['Hello'], 'ja');
  assert.equal(out[0].text, 'こんにちは');
  assert.equal(pageFetches, 2);
});

test('翻译服务：大批量按引擎上限切分，并发不超过 3', async () => {
  let inFlight = 0, peak = 0, batches = 0;
  const t = C.createTranslator({ engine: 'google', target: 'zh-CN', concurrency: 3 }, {
    ...memCache(),
    http: async (req) => {
      const qs = new URLSearchParams(req.body).getAll('q');
      batches++;
      inFlight++; peak = Math.max(peak, inFlight);
      await new Promise((r) => setTimeout(r, 5));
      inFlight--;
      return { status: 200, body: JSON.stringify(qs.map((q) => ['T' + q, 'en'])) };
    },
  });
  const many = Array.from({ length: 130 }, (_, i) => 'sentence number ' + i);
  const jobs = [t.translate(many.slice(0, 60), 'zh-CN'), t.translate(many.slice(60), 'zh-CN'), t.translate(['extra one'], 'zh-CN'), t.translate(['extra two'], 'zh-CN')];
  const res = await Promise.all(jobs);
  assert.equal(res[0][59].text, 'Tsentence number 59');
  assert.equal(res[1][69].text, 'Tsentence number 129');
  assert.ok(batches >= 3, 'google 每批最多 50 条');
  assert.ok(peak <= 3 * 2, `peak ${peak}`); // 每个 translate 任务内部按批并行，任务数受并发限制
});
