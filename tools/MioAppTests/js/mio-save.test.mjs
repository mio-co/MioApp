// 存到 MioCore（www/mio-browser/mio-save.js）：请求构造 + 用假 fetch 跑完整流程（不连线上）。
// 接口路径 / 请求体与 MioCore CLI 一致：/api/navigation、/api/navigation/categories、/api/navigation/links、/api/notes、/api/snippets
import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const MioSave = require(new URL('../../../www/mio-browser/mio-save.js', import.meta.url).pathname);

/// 假 MioCore：记录请求，按路由返回
function mockFetch(routes) {
  const calls = [];
  const f = async (url, init = {}) => {
    const u = new URL(url);
    const key = `${init.method || 'GET'} ${u.pathname}`;
    calls.push({ key, url, init, body: init.body ? JSON.parse(init.body) : undefined });
    const r = routes[key];
    if (!r) return { ok: false, status: 404, type: 'basic', text: async () => JSON.stringify({ error: 'no route ' + key }) };
    const out = typeof r === 'function' ? r(calls.at(-1)) : r;
    const status = out.status ?? 200;
    return { ok: status >= 200 && status < 300, status, type: out.type || 'basic', text: async () => (out.raw ?? JSON.stringify(out.json ?? {})) };
  };
  f.calls = calls;
  return f;
}

const page = { url: 'https://example.com/post/1?x=1#top', title: 'A great post', selection: 'the key sentence\nsecond line',
  article: { markdown: '## Intro\n\nBody text.', excerpt: 'An excerpt', byline: 'Jane', siteName: 'Example' } };

test('buildRequest: same-origin JSON, optional bearer token, no token by default', () => {
  const r = MioSave.buildRequest('POST', '/api/notes', { title: 't' }, { origin: 'https://mio.300031.xyz/' });
  assert.deepEqual(r, { method: 'POST', url: 'https://mio.300031.xyz/api/notes', headers: { accept: 'application/json', 'content-type': 'application/json' }, body: '{"title":"t"}' });
  const g = MioSave.buildRequest('GET', '/api/navigation', undefined, { token: 'mio_x' });
  assert.equal(g.url, 'https://mio.300031.xyz/api/navigation');
  assert.equal(g.headers.authorization, 'Bearer mio_x');
  assert.equal(g.body, undefined);
  assert.equal(g.headers['content-type'], undefined);
});

test('buildBookmark / buildNote / buildClip respect MioCore limits', () => {
  const b = MioSave.buildBookmark({ url: 'https://e.com/a', title: 'x'.repeat(300), article: { excerpt: 'y'.repeat(600) } });
  assert.equal(Array.from(b.title).length, 200);
  assert.equal(Array.from(b.description).length, 500);
  assert.equal(MioSave.buildBookmark({ url: 'javascript:alert(1)' }).url, '');
  const n = MioSave.buildNote({ ...page, savedAt: '2026-10-17 08:00' });
  assert.equal(n.title, 'A great post');
  assert.equal(n.content, '# A great post\n\n来源：[Example](https://example.com/post/1?x=1#top)  \n作者：Jane  \n保存于：2026-10-17 08:00\n\n> the key sentence\n> second line\n\n---\n\n## Intro\n\nBody text.\n');
  const c = MioSave.buildClip(page);
  assert.deepEqual(c, { type: 'link', title: '继续阅读：A great post', content: 'https://example.com/post/1?x=1#top' });
});

test('note: POST /api/notes with markdown, cookie credentials, manual redirect', async () => {
  const f = mockFetch({ 'POST /api/notes': { json: { note: { id: 'n1' } } } });
  const res = await MioSave.run('note', page, { fetch: f });
  assert.deepEqual(res, { ok: true, kind: 'note', id: 'n1' });
  assert.equal(f.calls.length, 1);
  const c = f.calls[0];
  assert.equal(c.url, 'https://mio.300031.xyz/api/notes');
  assert.equal(c.init.credentials, 'include');
  assert.equal(c.init.redirect, 'manual');
  assert.equal(c.init.headers.authorization, undefined);
  assert.equal(c.body.title, 'A great post');
  assert.match(c.body.content, /^# A great post\n/);
  assert.match(c.body.content, /## Intro\n\nBody text\./);
});

test('clip ("continue on another device"): POST /api/snippets link', async () => {
  const f = mockFetch({ 'POST /api/snippets': { json: { snippet: { id: 's1' } } } });
  const res = await MioSave.run('clip', page, { fetch: f, token: 'tok' });
  assert.deepEqual(res, { ok: true, kind: 'clip', id: 's1' });
  assert.deepEqual(f.calls[0].body, { type: 'link', title: '继续阅读：A great post', content: 'https://example.com/post/1?x=1#top' });
  assert.equal(f.calls[0].init.headers.authorization, 'Bearer tok');
});

test('bookmark: existing category by name (case-insensitive) → POST /api/navigation/links', async () => {
  const f = mockFetch({
    'GET /api/navigation': { json: { categories: [{ id: 'c0', name: 'Tools', links: [] }, { id: 'c1', name: 'Read Later', links: [{ id: 'l0', url: 'https://other.com/' }] }] } },
    'POST /api/navigation/links': { json: { link: { id: 'l9' } } }
  });
  const res = await MioSave.run('bookmark', page, { fetch: f, category: 'read later' });
  assert.deepEqual(res, { ok: true, kind: 'bookmark', id: 'l9', category: 'Read Later' });
  assert.deepEqual(f.calls.map((c) => c.key), ['GET /api/navigation', 'POST /api/navigation/links']);
  assert.deepEqual(f.calls[1].body, { categoryId: 'c1', title: 'A great post', url: 'https://example.com/post/1?x=1#top', description: 'An excerpt' });
});

test('bookmark: missing default category is created first', async () => {
  const f = mockFetch({
    'GET /api/navigation': { json: { categories: [{ id: 'c0', name: 'Tools', links: [] }] } },
    'POST /api/navigation/categories': (c) => ({ json: { category: { id: 'new1', name: c.body.name } } }),
    'POST /api/navigation/links': { json: { link: { id: 'l1' } } }
  });
  const res = await MioSave.run('bookmark', page, { fetch: f });
  assert.equal(res.ok, true);
  assert.equal(res.category, '稍后阅读');
  assert.deepEqual(f.calls[1].body, { name: '稍后阅读' });
  assert.equal(f.calls[2].body.categoryId, 'new1');
});

test('bookmark: URL already in navigation → no write', async () => {
  const f = mockFetch({
    'GET /api/navigation': { json: { categories: [{ id: 'c0', name: 'Tools', links: [{ id: 'l5', url: 'https://example.com/post/1?x=1' }] }] } }
  });
  const res = await MioSave.run('bookmark', page, { fetch: f });
  assert.deepEqual(res, { ok: true, kind: 'bookmark', id: 'l5', duplicate: true, category: 'Tools' });
  assert.equal(f.calls.length, 1);
});

test('errors: Access redirect / 401 / 403 → auth; 5xx → server; network → network; non-http page → invalid', async () => {
  const redirect = mockFetch({ 'POST /api/notes': { status: 0, type: 'opaqueredirect', raw: '' } });
  assert.equal((await MioSave.run('note', page, { fetch: redirect })).code, 'auth');
  const unauth = mockFetch({ 'POST /api/notes': { status: 401, json: { error: '未登录' } } });
  assert.deepEqual(await MioSave.run('note', page, { fetch: unauth }), { ok: false, code: 'auth', message: '未登录', status: 401 });
  const forbidden = mockFetch({ 'POST /api/snippets': { status: 403, json: {} } });
  assert.equal((await MioSave.run('clip', page, { fetch: forbidden })).code, 'auth');
  const html = mockFetch({ 'POST /api/notes': { status: 200, raw: '<html><body>Sign in</body></html>' } });
  assert.equal((await MioSave.run('note', page, { fetch: html })).code, 'auth');
  const boom = mockFetch({ 'POST /api/notes': { status: 500, json: { error: 'D1 down' } } });
  assert.deepEqual(await MioSave.run('note', page, { fetch: boom }), { ok: false, code: 'server', message: 'D1 down', status: 500 });
  const offline = async () => { throw new TypeError('Load failed'); };
  const r = await MioSave.run('clip', page, { fetch: offline });
  assert.equal(r.code, 'network');
  assert.match(r.message, /Load failed/);
  const bad = mockFetch({});
  assert.equal((await MioSave.run('bookmark', { url: 'about:blank' }, { fetch: bad })).code, 'invalid');
  assert.equal(bad.calls.length, 0);
  assert.equal((await MioSave.run('nope', page, { fetch: bad })).code, 'invalid');
});

test('huge article is truncated under the MioCore size limit', async () => {
  const f = mockFetch({ 'POST /api/notes': { json: { note: { id: 'n' } } } });
  await MioSave.run('note', { ...page, article: { markdown: '中'.repeat(400000) } }, { fetch: f });
  assert.ok(Buffer.byteLength(f.calls[0].body.content) <= 900 * 1024 + 100);
  assert.match(f.calls[0].body.content, /已截断/);
});
