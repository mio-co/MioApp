/*
 * 存到 MioCore：内置浏览器把当前网页存为导航书签 / 新建笔记 / 推到云剪贴板（"在另一台设备继续"）。
 *
 * 在 App 主窗口（已登录 MioCore 的 WebView，同源 https://mio.300031.xyz）的隔离脚本环境里执行：
 *   await MioSave.run('bookmark' | 'note' | 'clip', payload, opts)
 *     payload = { url, title, selection, article: { markdown, excerpt, byline, siteName } }
 *     opts    = { origin, token, category, fetch }
 *   → { ok: true, kind, id, duplicate?, category? } | { ok: false, code: 'auth'|'network'|'server'|'invalid', status?, message }
 *
 * 认证：默认同源 fetch 带上主窗口的会话 Cookie（含 Cloudflare Access）；设置里填了 API 令牌时另加 Authorization: Bearer。
 * 接口与 MioCore CLI（packages/cli/src/commands/{nav,notes,snippets}.ts）一致：
 *   GET  /api/navigation                      → { categories: [{ id, name, links: [{ id, url, … }] }] }
 *   POST /api/navigation/categories { name }  → { category: { id } }
 *   POST /api/navigation/links { categoryId, title, url, description }
 *   POST /api/notes { title, content }        → { note: { id } }
 *   POST /api/snippets { type: 'link', title, content }  → { snippet: { id } }
 */
(function (root) {
  'use strict';

  var DEFAULT_ORIGIN = 'https://mio.300031.xyz';
  var DEFAULT_CATEGORY = '稍后阅读';
  var LIMITS = { linkTitle: 200, linkUrl: 2000, linkDescription: 500, noteTitle: 200, snippetTitle: 200, snippetBytes: 1024 * 1024 - 1024, categoryName: 100 };

  function str(v) { return v == null ? '' : String(v); }
  function clip(s, n) { s = str(s).replace(/\s+/g, ' ').trim(); return Array.from(s).length > n ? Array.from(s).slice(0, n - 1).join('') + '…' : s; }
  function byteLength(s) {
    var n = 0;
    for (var i = 0; i < s.length; i++) {
      var c = s.charCodeAt(i);
      if (c < 0x80) n += 1; else if (c < 0x800) n += 2; else if (c >= 0xd800 && c <= 0xdbff) { n += 4; i++; } else n += 3;
    }
    return n;
  }
  function truncateBytes(s, max) {
    if (byteLength(s) <= max) return s;
    var lo = 0, hi = s.length;
    while (lo < hi) { var mid = (lo + hi + 1) >> 1; if (byteLength(s.slice(0, mid)) <= max) lo = mid; else hi = mid - 1; }
    return s.slice(0, lo) + '\n\n…（内容过长，已截断）';
  }

  function validUrl(u) {
    try { var x = new URL(str(u)); return x.protocol === 'http:' || x.protocol === 'https:' ? x.href : ''; } catch (e) { return ''; }
  }

  function hostOf(u) { try { return new URL(u).host; } catch (e) { return ''; } }

  /// 书签：标题 ≤200、地址 ≤2000、描述 ≤500（MioCore 校验上限）
  function buildBookmark(p) {
    var url = validUrl(p.url);
    var a = p.article || {};
    return {
      title: clip(p.title || a.title || hostOf(url) || url, LIMITS.linkTitle),
      url: url,
      description: clip(p.description || a.excerpt || '', LIMITS.linkDescription)
    };
  }

  /// 笔记（markdown）：标题、来源链接、选中的文字（引用块）、阅读模式正文
  function buildNote(p) {
    var url = validUrl(p.url);
    var a = p.article || {};
    var title = clip(p.title || a.title || hostOf(url) || '网页笔记', LIMITS.noteTitle);
    var lines = ['# ' + title.replace(/\n/g, ' '), ''];
    var meta = [];
    if (url) meta.push('来源：[' + (a.siteName || hostOf(url) || url).replace(/[\[\]]/g, '') + '](' + url.replace(/\)/g, '%29') + ')');
    if (a.byline) meta.push('作者：' + clip(a.byline, 100));
    meta.push('保存于：' + (p.savedAt || new Date().toISOString().slice(0, 16).replace('T', ' ')));
    lines.push(meta.join('  \n'), '');
    var sel = str(p.selection).trim();
    if (sel) {
      lines.push(sel.split(/\r?\n/).map(function (l) { return '> ' + l; }).join('\n'), '');
    }
    var body = str(a.markdown).trim();
    if (body) {
      if (sel) lines.push('---', '');
      lines.push(body, '');
    } else if (!sel && a.excerpt) {
      lines.push(str(a.excerpt).trim(), '');
    }
    return { title: title, content: lines.join('\n').trim() + '\n' };
  }

  /// 云剪贴板（"在另一台设备继续"）：链接片段，内容就是网址
  function buildClip(p) {
    var url = validUrl(p.url);
    return { type: 'link', title: clip('继续阅读：' + (p.title || hostOf(url) || url), LIMITS.snippetTitle), content: url };
  }

  /// 构造请求（不发送）：{ method, url, headers, body }。单测只测这一层 + 用假 fetch 跑 run()
  function buildRequest(method, path, body, opts) {
    opts = opts || {};
    var origin = str(opts.origin || DEFAULT_ORIGIN).replace(/\/+$/, '');
    var headers = { accept: 'application/json' };
    if (body !== undefined) headers['content-type'] = 'application/json';
    if (opts.token) headers.authorization = 'Bearer ' + opts.token;
    var req = { method: method, url: origin + path, headers: headers };
    if (body !== undefined) req.body = JSON.stringify(body);
    return req;
  }

  function fail(code, message, status) { var e = { ok: false, code: code, message: message }; if (status) e.status = status; return e; }

  async function send(method, path, body, opts) {
    var req = buildRequest(method, path, body, opts);
    var f = opts.fetch || (typeof fetch === 'function' ? fetch : null);
    if (!f) throw fail('network', '没有可用的 fetch');
    var res;
    try {
      res = await f(req.url, {
        method: req.method, headers: req.headers, body: req.body,
        credentials: 'include', redirect: 'manual', cache: 'no-store'
      });
    } catch (e) {
      throw fail('network', '无法连接 MioCore：' + (e && e.message ? e.message : String(e)));
    }
    // Cloudflare Access / 登录页会 302：fetch(redirect: 'manual') 得到 opaqueredirect（status 0）
    if (res.type === 'opaqueredirect' || res.status === 0 || (res.status >= 300 && res.status < 400)) {
      throw fail('auth', '未登录 MioCore（请求被重定向到登录页），请先在主窗口登录，或在设置里填 API 令牌', res.status || undefined);
    }
    var data = null;
    var text = '';
    try { text = await res.text(); data = text ? JSON.parse(text) : null; } catch (e) { data = null; }
    if (res.status === 401 || res.status === 403) {
      throw fail('auth', (data && data.error) || (res.status === 401 ? '未登录 MioCore 或令牌无效' : '没有权限（令牌缺少所需的权限范围？）'), res.status);
    }
    if (!res.ok) throw fail(res.status >= 500 ? 'server' : 'invalid', (data && data.error) || ('MioCore 返回 HTTP ' + res.status), res.status);
    if (data === null && text && /<html/i.test(text)) throw fail('auth', 'MioCore 返回了网页而不是 JSON（可能是登录页）', res.status);
    return data || {};
  }

  function findCategory(categories, ref) {
    var lower = str(ref).trim().toLowerCase();
    for (var i = 0; i < categories.length; i++) if (categories[i].id === ref) return categories[i];
    for (var j = 0; j < categories.length; j++) if (str(categories[j].name).trim().toLowerCase() === lower) return categories[j];
    return null;
  }

  function sameUrl(a, b) {
    var na = validUrl(a), nb = validUrl(b);
    if (!na || !nb) return false;
    return na.replace(/\/$/, '').replace(/#.*$/, '') === nb.replace(/\/$/, '').replace(/#.*$/, '');
  }

  async function saveBookmark(payload, opts) {
    var link = buildBookmark(payload);
    if (!link.url) return fail('invalid', '只能保存 http / https 网页');
    var overview = await send('GET', '/api/navigation', undefined, opts);
    var categories = (overview && overview.categories) || [];
    // 已经在导航里（任意分类）→ 不重复添加
    for (var i = 0; i < categories.length; i++) {
      var links = categories[i].links || [];
      for (var j = 0; j < links.length; j++) {
        if (sameUrl(links[j].url, link.url)) return { ok: true, kind: 'bookmark', id: links[j].id, duplicate: true, category: categories[i].name };
      }
    }
    var name = clip(opts.category || DEFAULT_CATEGORY, LIMITS.categoryName);
    var cat = findCategory(categories, name);
    if (!cat) {
      var created = await send('POST', '/api/navigation/categories', { name: name }, opts);
      cat = (created && created.category) || null;
      if (!cat || !cat.id) return fail('server', '创建导航分类失败');
      cat.name = cat.name || name;
    }
    var res = await send('POST', '/api/navigation/links', { categoryId: cat.id, title: link.title, url: link.url, description: link.description }, opts);
    var created2 = (res && (res.link || res)) || {};
    return { ok: true, kind: 'bookmark', id: created2.id || null, category: cat.name };
  }

  async function saveNote(payload, opts) {
    var note = buildNote(payload);
    note.content = truncateBytes(note.content, 900 * 1024);
    var res = await send('POST', '/api/notes', { title: note.title, content: note.content }, opts);
    return { ok: true, kind: 'note', id: (res && res.note && res.note.id) || null };
  }

  async function saveClip(payload, opts) {
    var c = buildClip(payload);
    if (!c.content) return fail('invalid', '只能推送 http / https 网页');
    var res = await send('POST', '/api/snippets', c, opts);
    return { ok: true, kind: 'clip', id: (res && res.snippet && res.snippet.id) || null };
  }

  async function run(kind, payload, opts) {
    opts = opts || {};
    payload = payload || {};
    try {
      if (kind === 'bookmark') return await saveBookmark(payload, opts);
      if (kind === 'note') return await saveNote(payload, opts);
      if (kind === 'clip') return await saveClip(payload, opts);
      return fail('invalid', '未知操作：' + kind);
    } catch (e) {
      if (e && e.ok === false) return e;
      return fail('network', e && e.message ? e.message : String(e));
    }
  }

  var api = {
    version: 1,
    DEFAULT_ORIGIN: DEFAULT_ORIGIN,
    DEFAULT_CATEGORY: DEFAULT_CATEGORY,
    LIMITS: LIMITS,
    buildBookmark: buildBookmark,
    buildNote: buildNote,
    buildClip: buildClip,
    buildRequest: buildRequest,
    run: run
  };
  root.MioSave = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
