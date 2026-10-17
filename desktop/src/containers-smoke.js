'use strict';
// CI 冒烟：两个容器访问同一个本地测试页（127.0.0.1），互相看不到对方的 Cookie / LocalStorage / IndexedDB；
// 默认容器也看不到；容器会话装上了广告拦截；删除容器后数据被清空。只在 MIO_SMOKE_OUT 冒烟模式下由 smoke.js 调用。
const http = require('node:http');
const { BrowserWindow } = require('electron');

function startServer() {
  return new Promise((resolve) => {
    const server = http.createServer((req, res) => {
      if (req.url.startsWith('/echo')) {
        res.writeHead(200, { 'content-type': 'text/plain', 'cache-control': 'no-store' });
        res.end(req.headers.cookie || '');
        return;
      }
      if (req.url.startsWith('/set')) {
        const v = new URL(req.url, 'http://x').searchParams.get('v') || '';
        res.writeHead(200, { 'content-type': 'text/plain', 'set-cookie': `srv=${encodeURIComponent(v)}; Path=/; Max-Age=3600`, 'cache-control': 'no-store' });
        res.end('ok');
        return;
      }
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
      res.end('<!doctype html><title>mio container smoke</title><p>container smoke</p>');
    });
    server.listen(0, '127.0.0.1', () => resolve(server));
  });
}

function load(win, url) {
  return win.webContents.loadURL(url);
}

const WRITE = (v) => `(async () => {
  document.cookie = 'js=${v}; path=/; max-age=3600';
  localStorage.setItem('mio', '${v}');
  await new Promise((ok, bad) => {
    const r = indexedDB.open('mio-smoke', 1);
    r.onupgradeneeded = () => r.result.createObjectStore('kv');
    r.onsuccess = () => { const tx = r.result.transaction('kv', 'readwrite'); tx.objectStore('kv').put('${v}', 'k'); tx.oncomplete = () => { r.result.close(); ok(); }; tx.onerror = bad; };
    r.onerror = bad;
  });
  await fetch('/set?v=${v}', { credentials: 'include' });
  return true;
})()`;

const READ = `(async () => {
  const dbs = indexedDB.databases ? (await indexedDB.databases()).map((d) => d.name) : [];
  let idb = null;
  if (dbs.includes('mio-smoke')) {
    idb = await new Promise((ok) => {
      const r = indexedDB.open('mio-smoke');
      r.onsuccess = () => { try { const g = r.result.transaction('kv').objectStore('kv').get('k'); g.onsuccess = () => { r.result.close(); ok(g.result || null); }; g.onerror = () => ok(null); } catch (e) { ok(null); } };
      r.onerror = () => ok(null);
    });
  }
  const server = await (await fetch('/echo', { credentials: 'include', cache: 'no-store' })).text();
  return JSON.stringify({ cookie: document.cookie, local: localStorage.getItem('mio'), idb, server });
})()`;

async function run({ containers, adblock }) {
  const out = { ok: false };
  const server = await startServer();
  const base = `http://127.0.0.1:${server.address().port}/`;
  const wins = [];
  const created = [];
  try {
    const a = containers.store.create({ name: 'smoke-a' });
    const b = containers.store.create({ name: 'smoke-b' });
    created.push(a.id, b.id);
    const sesA = containers.sessionFor(a.id);
    const sesB = containers.sessionFor(b.id);
    const sesD = containers.defaultSession();
    out.partitions = { a: containers.partitionFor(a.id), b: containers.partitionFor(b.id), def: containers.partitionFor('default') };
    out.distinctSessions = sesA !== sesB && sesA !== sesD && sesB !== sesD;
    const preloadIds = (ses) => (typeof ses.getPreloadScripts === 'function' ? ses.getPreloadScripts().map((p) => p.id || p.filePath || String(p)) : []);
    out.adblockAttached = {
      a: !!(adblock && adblock.isBrowserSession(sesA)),
      b: !!(adblock && adblock.isBrowserSession(sesB)),
      preloadsA: preloadIds(sesA),
    };
    const mk = (ses) => {
      const w = new BrowserWindow({ show: false, width: 400, height: 300, webPreferences: { session: ses, contextIsolation: true, sandbox: true } });
      wins.push(w);
      return w;
    };
    const wA = mk(sesA);
    const wB = mk(sesB);
    const wD = mk(sesD);
    await load(wA, base);
    await wA.webContents.executeJavaScript(WRITE('A'));
    await load(wB, base);
    await wB.webContents.executeJavaScript(WRITE('B'));
    await load(wD, base);
    const readA = JSON.parse(await wA.webContents.executeJavaScript(READ));
    const readB = JSON.parse(await wB.webContents.executeJavaScript(READ));
    const readD = JSON.parse(await wD.webContents.executeJavaScript(READ));
    out.read = { a: readA, b: readB, def: readD };
    const has = (r, v) => r.cookie.includes(`js=${v}`) && r.cookie.includes(`srv=${v}`) && r.local === v && r.idb === v && r.server.includes(`js=${v}`) && r.server.includes(`srv=${v}`);
    const clean = (r) => !/js=|srv=/.test(r.cookie) && r.local === null && r.idb === null && !/js=|srv=/.test(r.server);
    out.isolated = has(readA, 'A') && has(readB, 'B') && !readA.cookie.includes('=B') && !readB.cookie.includes('=A') && clean(readD);

    // 重启不丢：元数据写进了 containers.json（重新解析一份）
    const { ContainerStore } = require('./containers-store');
    const reread = new ContainerStore(containers.store.file);
    out.persisted = !!(reread.get(a.id) && reread.get(b.id));

    for (const w of wins.splice(0)) w.destroy();
    const r = await containers.removeContainer(a.id);
    const cookiesAfter = await sesA.cookies.get({});
    out.removeA = { cleared: r.cleared, dirRemoved: r.dirRemoved, cookiesAfter: cookiesAfter.length, stillListed: !!containers.store.get(a.id) };
    await containers.removeContainer(b.id);
    created.length = 0;
    out.ok =
      out.distinctSessions &&
      out.adblockAttached.a &&
      out.adblockAttached.b &&
      out.isolated &&
      out.persisted &&
      out.removeA.cleared &&
      out.removeA.cookiesAfter === 0 &&
      !out.removeA.stillListed;
  } catch (e) {
    out.error = String((e && e.stack) || e);
  } finally {
    for (const w of wins) if (!w.isDestroyed()) w.destroy();
    for (const id of created) await containers.removeContainer(id).catch(() => undefined);
    server.close();
  }
  return out;
}

module.exports = { run };
