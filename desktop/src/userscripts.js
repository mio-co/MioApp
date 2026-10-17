'use strict';
// 用户脚本管理器（Windows / Electron 内置浏览器），与 iOS / Mac（MioUserScripts.swift）功能对应：
// - 安装：粘贴代码 / 网址（Greasy Fork 脚本页、GitHub blob 自动换下载地址）/ 从文件导入 / 内置浏览器打开 *.user.js 时提示；
//   @require / @resource 安装时下载缓存（支持 #sha256= 校验），同 @name + @namespace 再装 = 就地更新。
// - 注入：frame preload（userscripts-preload.js）同步取「本 frame 匹配的启用脚本」（带最新 GM 值快照）。
//   有 @grant 的脚本各自跑在独立的隔离 world（webFrame.executeJavaScriptInIsolatedWorld，world id 1100+序号），
//   原生桥只通过 contextBridge.exposeInIsolatedWorld 暴露在它自己的 world 里，桥里写死脚本 id（页面和其他脚本拿不到）；
//   @grant none 跑页面主世界。运行时与 iOS 是同一段（inject/userscript-runtime.js，从 Swift 生成）。
// - GM API 原生部分：GM_setValue / deleteValue（userData/userscripts/values/<id>.json，每脚本 5 MB）、
//   GM_xmlhttpRequest（session.fetch 代发，同主机放行；@connect 声明的域名首次询问「拒绝 / 仅这一次 / 总是允许」；未声明拒绝；
//   默认带内置浏览器 Cookie，anonymous 不带）、GM_openInTab（当前浏览器打开）、GM_setClipboard、GM_registerMenuCommand（盾牌菜单里执行）。
// - 管理窗口 ui/userscripts.html：启用 / 禁用、查看代码、检查更新、删除（连同数据）、重置跨域授权。
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { EventEmitter } = require('node:events');
const core = require('./userscript-core');

const WORLD_BASE = 1100;
const PRELOAD = path.join(__dirname, 'userscripts-preload.js');

// ---------------------------------------------------------------- 存储（纯 Node，可单测）

class UserScriptStore extends EventEmitter {
  constructor(dir) {
    super();
    this.dir = dir;
    this.file = path.join(dir, 'scripts.json');
    this.valuesDir = path.join(dir, 'values');
    this.scripts = [];
    this.valueCache = new Map();
    try {
      const j = JSON.parse(fs.readFileSync(this.file, 'utf8'));
      if (Array.isArray(j)) this.scripts = j.filter((s) => s && s.id && s.meta && typeof s.code === 'string');
    } catch {
      // 首次
    }
  }

  save() {
    fs.mkdirSync(this.dir, { recursive: true });
    const tmp = `${this.file}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(this.scripts));
    fs.renameSync(tmp, this.file);
    this.emit('change');
  }

  get(id) {
    return this.scripts.find((s) => s.id === id) || null;
  }

  existing(meta) {
    const k = core.identity(meta);
    return this.scripts.find((s) => core.identity(s.meta) === k) || null;
  }

  /** pkg = { meta, code, requireCache, resourceCache, sourceURL } */
  install(pkg) {
    const now = new Date().toISOString();
    const old = this.existing(pkg.meta);
    if (old) {
      old.meta = pkg.meta;
      old.code = pkg.code;
      old.requireCache = pkg.requireCache || {};
      old.resourceCache = pkg.resourceCache || {};
      if (pkg.sourceURL) old.sourceURL = pkg.sourceURL;
      old.updatedAt = now;
      const dec = {};
      for (const [h, v] of Object.entries(old.connectDecisions || {})) if (core.isDeclared(h, pkg.meta.connects, null)) dec[h] = v;
      old.connectDecisions = dec;
      this.save();
      return old;
    }
    const s = {
      id: crypto.randomUUID(), meta: pkg.meta, code: pkg.code, requireCache: pkg.requireCache || {}, resourceCache: pkg.resourceCache || {},
      enabled: true, sourceURL: pkg.sourceURL || null, installedAt: now, updatedAt: now, lastUpdateCheck: null, connectDecisions: {},
    };
    this.scripts.push(s);
    this.save();
    return s;
  }

  setEnabled(id, on) {
    const s = this.get(id);
    if (!s || s.enabled === !!on) return;
    s.enabled = !!on;
    this.save();
  }

  setConnectDecision(id, host, allow) {
    const s = this.get(id);
    if (!s) return;
    const h = core.normalizeHost(host);
    s.connectDecisions = s.connectDecisions || {};
    if (allow === null || allow === undefined) delete s.connectDecisions[h];
    else s.connectDecisions[h] = !!allow;
    this.save();
  }

  resetConnect(id) {
    const s = this.get(id);
    if (!s) return;
    s.connectDecisions = {};
    this.save();
  }

  markChecked(id) {
    const s = this.get(id);
    if (!s) return;
    s.lastUpdateCheck = new Date().toISOString();
    this.save();
  }

  delete(id) {
    this.scripts = this.scripts.filter((s) => s.id !== id);
    this.removeValues(id);
    this.save();
  }

  // ---- GM 值（按脚本隔离；值是 JS 端 JSON.stringify 后的字符串）
  valueFile(id) {
    const safe = String(id).replace(/[^A-Za-z0-9-]/g, '') || '_';
    return path.join(this.valuesDir, `${safe}.json`);
  }

  values(id) {
    if (this.valueCache.has(id)) return this.valueCache.get(id);
    let v = {};
    try {
      const j = JSON.parse(fs.readFileSync(this.valueFile(id), 'utf8'));
      if (j && typeof j === 'object') for (const [k, x] of Object.entries(j)) if (typeof x === 'string') v[k] = x;
    } catch {
      v = {};
    }
    this.valueCache.set(id, v);
    return v;
  }

  persistValues(id, v) {
    this.valueCache.set(id, v);
    fs.mkdirSync(this.valuesDir, { recursive: true });
    const f = this.valueFile(id);
    if (!Object.keys(v).length) {
      fs.rmSync(f, { force: true });
      return;
    }
    fs.writeFileSync(`${f}.tmp`, JSON.stringify(v));
    fs.renameSync(`${f}.tmp`, f);
  }

  setValue(id, key, json) {
    const v = { ...this.values(id), [String(key)]: String(json) };
    let size = 0;
    for (const [k, x] of Object.entries(v)) size += Buffer.byteLength(k) + Buffer.byteLength(x);
    if (size > core.MAX_VALUE_BYTES) return false;
    this.persistValues(id, v);
    return true;
  }

  deleteValue(id, key) {
    const v = { ...this.values(id) };
    if (!(String(key) in v)) return;
    delete v[String(key)];
    this.persistValues(id, v);
  }

  removeValues(id) {
    this.valueCache.delete(id);
    fs.rmSync(this.valueFile(id), { force: true });
  }

  /** 给某个 frame 的脚本列表（frame preload 用） */
  scriptsFor(url, { isTop = true, appVersion = '', platform = 'windows' } = {}) {
    if (!/^(https?|file):/i.test(String(url || ''))) return [];
    const out = [];
    this.scripts.forEach((s, index) => {
      if (!s.enabled) return;
      if (s.meta.noframes && !isTop) return;
      if (!core.rulesMatch(core.compileRules(s.meta), url)) return;
      const isolated = !core.grantsNone(s.meta);
      out.push({
        id: s.id,
        world: WORLD_BASE + index,
        isolated,
        runAt: s.meta.runAt,
        source: core.buildSource(s, isolated ? this.values(s.id) : {}, { appVersion, platform, bridge: 'mioUserScriptNative' }),
      });
    });
    return out;
  }
}

// ---------------------------------------------------------------- 下载 / 安装 / 更新

function verifyIntegrity(buf, fragment, url) {
  if (!fragment) return;
  for (const part of fragment.split(/[,;]/)) {
    const m = /^([a-z0-9]+)[=-](.+)$/i.exec(part.trim());
    if (!m) continue;
    const algo = m[1].toLowerCase();
    if (!['sha256', 'sha384', 'sha512'].includes(algo)) continue;
    const d = crypto.createHash(algo).update(buf);
    const digest = d.digest();
    if (m[2].toLowerCase() === digest.toString('hex') || m[2] === digest.toString('base64')) return;
    throw new core.UserScriptError(`${path.basename(new URL(url).pathname)} 校验失败（${algo}）`);
  }
}

async function download(url, fetchImpl) {
  const u = new URL(url);
  const fragment = u.hash ? u.hash.slice(1) : '';
  u.hash = '';
  let res;
  try {
    res = await fetchImpl(u.href, { headers: { Accept: 'text/javascript, application/javascript, text/plain, */*' }, cache: 'no-store' });
  } catch (e) {
    throw new core.UserScriptError(`下载失败：${(e && e.message) || e}`);
  }
  if (!res.ok) throw new core.UserScriptError(`下载失败：HTTP ${res.status}（${u.href}）`);
  const buf = Buffer.from(await res.arrayBuffer());
  if (buf.length > core.MAX_SCRIPT_BYTES) throw new core.UserScriptError(`文件太大（${Math.floor(buf.length / 1024)} KB）`);
  verifyIntegrity(buf, fragment, u.href);
  return buf.toString('utf8');
}

function resolveUrl(s, base) {
  try {
    const u = new URL(s, base || undefined);
    return u.protocol === 'http:' || u.protocol === 'https:' ? u.href : null;
  } catch {
    return null;
  }
}

async function prepare(code, sourceURL, fetchImpl) {
  const meta = core.parseMeta(code);
  const requireCache = {};
  for (const r of meta.requires) {
    if (r in requireCache) continue;
    const u = resolveUrl(r, sourceURL);
    if (!u) throw new core.UserScriptError(`下载失败：无效的 @require：${r}`);
    requireCache[r] = await download(u, fetchImpl);
  }
  const resourceCache = {};
  for (const [name, r] of Object.entries(meta.resources)) {
    const u = resolveUrl(r, sourceURL);
    if (!u) throw new core.UserScriptError(`下载失败：无效的 @resource：${r}`);
    resourceCache[name] = await download(u, fetchImpl);
  }
  return { meta, code, requireCache, resourceCache, sourceURL: sourceURL || null };
}

async function prepareUrl(input, fetchImpl) {
  const url = core.installURL(input);
  if (!url) throw new core.UserScriptError('请输入 http(s) 网址');
  return prepare(await download(url, fetchImpl), url, fetchImpl);
}

/** 有新版本时返回准备好的包，没有返回 null */
async function checkUpdate(s, fetchImpl) {
  const checkURL = core.updateCheckURL(s.meta, s.sourceURL);
  if (!checkURL) throw new core.UserScriptError('脚本没有 @updateURL / @downloadURL，也不是从网址安装的');
  const text = await download(checkURL, fetchImpl);
  const remote = core.parseMeta(text);
  if (core.compareVersions(remote.version, s.meta.version) <= 0) return null;
  if (new URL(checkURL).pathname.toLowerCase().endsWith('.meta.js')) {
    const dl = core.downloadURL(remote, s.sourceURL);
    if (!dl) throw new core.UserScriptError('找不到新版本的下载地址');
    return prepare(await download(dl, fetchImpl), s.sourceURL || dl, fetchImpl);
  }
  return prepare(text, s.sourceURL || checkURL, fetchImpl);
}

// ---------------------------------------------------------------- GM_xmlhttpRequest

const FORBIDDEN_HEADERS = new Set(['host', 'content-length', 'connection', 'transfer-encoding']);

/** 主进程代发；返回与 iOS 相同的结构 { status, statusText, finalUrl, headers, text | base64 } 或 { error, timeout } */
async function performXhr(body, { fetchImpl, signal }) {
  const headers = {};
  let hasUA = false;
  let hasAuth = false;
  for (const [k, v] of Object.entries(body.headers || {})) {
    const lk = k.toLowerCase();
    if (FORBIDDEN_HEADERS.has(lk)) continue;
    if (lk === 'user-agent') hasUA = true;
    if (lk === 'authorization') hasAuth = true;
    headers[k] = String(v);
  }
  if (!hasUA && body.userAgent) headers['User-Agent'] = String(body.userAgent);
  if (!hasAuth && body.user) headers.Authorization = 'Basic ' + Buffer.from(`${body.user}:${body.password || ''}`).toString('base64');
  const method = String(body.method || 'GET').toUpperCase();
  let data;
  if (body.body && typeof body.body.text === 'string') data = body.body.text;
  else if (body.body && typeof body.body.base64 === 'string') data = Buffer.from(body.body.base64, 'base64');
  const ctrl = new AbortController();
  const onAbort = () => ctrl.abort();
  if (signal) signal.addEventListener('abort', onAbort);
  let timedOut = false;
  const ms = Number(body.timeout) > 0 ? Number(body.timeout) : 120000;
  const timer = setTimeout(() => { timedOut = true; ctrl.abort(); }, ms);
  try {
    const res = await fetchImpl(body.url, {
      method, headers, body: method === 'GET' || method === 'HEAD' ? undefined : data, redirect: 'follow',
      credentials: body.anonymous ? 'omit' : 'include', signal: ctrl.signal,
    });
    const buf = Buffer.from(await res.arrayBuffer());
    const lines = [];
    res.headers.forEach((v, k) => lines.push(`${k}: ${v}`));
    const out = { status: res.status, statusText: res.statusText || '', finalUrl: res.url || body.url, headers: lines.join('\r\n') };
    const type = String(body.responseType || '').toLowerCase();
    if (type === 'arraybuffer' || type === 'blob') out.base64 = buf.toString('base64');
    else {
      const mime = String(body.overrideMimeType || res.headers.get('content-type') || '');
      const cs = (/charset=([^;]+)/i.exec(mime) || [])[1];
      let text;
      try { text = new TextDecoder(cs ? cs.trim() : 'utf-8').decode(buf); } catch { text = buf.toString('utf8'); }
      out.text = text;
    }
    return out;
  } catch (e) {
    if (timedOut) return { error: 'timeout', timeout: true };
    if (signal && signal.aborted) return { error: 'aborted' };
    return { error: String((e && e.message) || e) };
  } finally {
    clearTimeout(timer);
    if (signal) signal.removeEventListener('abort', onAbort);
  }
}

// ---------------------------------------------------------------- Electron 部分

class UserScripts {
  constructor({ session, icon, uiPartition, appVersion, openUrl, isBrowserSession }) {
    const { app } = require('electron');
    this.session = session;
    // 容器（containers.js）：每个容器会话都算内置浏览器；新会话由 main.js 的 containers.configure 调 attachSession
    this.isBrowserSession = isBrowserSession || ((ses) => ses === this.session);
    this.icon = icon;
    this.uiPartition = uiPartition;
    this.appVersion = appVersion || app.getVersion();
    this.openUrl = openUrl || (() => undefined);
    this.store = new UserScriptStore(path.join(app.getPath('userData'), 'userscripts'));
    this.xhrs = new Map();
    this.asks = new Map();
    this.menus = new Map(); // webContents id → Map(scriptId → [{id,name}])
    this.win = null;
    // 安装 / 更新下载用默认会话；GM_xmlhttpRequest 用发起页面所在的会话（Cookie 按容器隔离）
    this.fetch = (url, opts) => this.session.fetch(url, opts);
    this.attachSession(session);
    this.installIpc();
    this.store.on('change', () => this.push());
    this.watchUserScriptLinks(app);
  }

  /** 给一个浏览器会话注册用户脚本的 frame preload（重复调用无害） */
  attachSession(ses) {
    if (!this.attached) this.attached = new WeakSet();
    if (this.attached.has(ses)) return;
    this.attached.add(ses);
    ses.registerPreloadScript({ type: 'frame', id: 'mio-userscripts', filePath: PRELOAD });
  }

  fromBrowser(event) {
    return !!event.sender && this.isBrowserSession(event.sender.session);
  }

  installIpc() {
    const { ipcMain, session: electronSession } = require('electron');
    ipcMain.on('mio-userscripts:scripts', (event, url) => {
      let list = [];
      try {
        if (this.fromBrowser(event)) {
          const f = event.senderFrame;
          const isTop = !f || f.parent === null;
          if (isTop) this.menus.delete(event.sender.id);
          list = this.store.scriptsFor(String(url || ''), { isTop, appVersion: this.appVersion, platform: process.platform === 'darwin' ? 'mac' : 'windows' });
        }
      } catch (e) {
        console.error('[userscripts] scripts', e);
      }
      event.returnValue = list;
    });
    ipcMain.handle('mio-userscripts:op', async (event, id, msg) => {
      if (!this.fromBrowser(event)) throw new Error('forbidden');
      const s = this.store.get(String(id));
      if (!s || !s.enabled || core.grantsNone(s.meta)) throw new Error('script not found');
      return this.handle(s, msg || {}, event);
    });

    const own = (event) => this.win && !this.win.isDestroyed() && event.sender === this.win.webContents;
    const h = (name, fn) => ipcMain.handle(`mio-userscripts-ui:${name}`, async (event, ...args) => {
      if (!own(event)) return null;
      try {
        const r = await fn(...args);
        return { ok: true, result: r === undefined ? null : r, list: this.snapshot() };
      } catch (e) {
        return { ok: false, error: String((e && e.message) || e), list: this.snapshot() };
      }
    });
    h('list', () => null);
    h('install-code', (code) => this.installCode(String(code || ''), null));
    h('install-url', (url) => this.installUrl(String(url || '')));
    h('install-file', () => this.installFile());
    h('enable', (id, on) => this.store.setEnabled(String(id), !!on));
    h('delete', (id) => this.store.delete(String(id)));
    h('reset-connect', (id) => this.store.resetConnect(String(id)));
    h('code', (id) => (this.store.get(String(id)) || {}).code || '');
    h('check-update', (id) => this.updateOne(String(id)));
    h('check-all', () => this.updateAll());
    // 浏览器设置页里的「用户脚本…」按钮（设置页在 UI 会话里）
    ipcMain.handle('mio-userscripts-ui:open', (event) => {
      if (!event.sender || event.sender.session !== electronSession.fromPartition(this.uiPartition)) return false;
      this.open();
      return true;
    });
  }

  async handle(s, msg, event) {
    const { clipboard } = require('electron');
    switch (msg.op) {
      case 'setValue':
        if (typeof msg.key !== 'string' || typeof msg.value !== 'string') throw new Error('bad value');
        if (!this.store.setValue(s.id, msg.key, msg.value)) throw new Error('存储超出上限（每个脚本 5 MB）');
        return true;
      case 'deleteValue':
        if (typeof msg.key !== 'string') throw new Error('bad key');
        this.store.deleteValue(s.id, msg.key);
        return true;
      case 'xhr':
        return this.xhr(s, msg, event);
      case 'xhrAbort': {
        const r = String(msg.reqId || '');
        if (r.startsWith(`${s.id}:`) && this.xhrs.has(r)) this.xhrs.get(r).abort();
        return true;
      }
      case 'openTab': {
        const u = resolveUrl(String(msg.url || ''), null);
        if (!u) throw new Error('invalid url');
        this.openUrl(u);
        return true;
      }
      case 'setClipboard': {
        const data = String(msg.data || '');
        if (String(msg.type || '').toLowerCase().includes('html')) clipboard.write({ html: data, text: data });
        else clipboard.writeText(data);
        return true;
      }
      case 'menu': {
        const f = event.senderFrame;
        if (f && f.parent === null) {
          const wcId = event.sender.id;
          if (!this.menus.has(wcId)) this.menus.set(wcId, new Map());
          const list = (Array.isArray(msg.commands) ? msg.commands : []).map((c) => ({ id: String(c.id), name: String(c.name) }));
          if (list.length) this.menus.get(wcId).set(s.id, list);
          else this.menus.get(wcId).delete(s.id);
        }
        return true;
      }
      default:
        throw new Error(`unknown op ${msg.op}`);
    }
  }

  async xhr(s, msg, event) {
    const url = resolveUrl(String(msg.url || ''), null);
    if (!url) return { error: '不支持的地址' };
    const host = new URL(url).hostname;
    let pageHost = '';
    try { pageHost = new URL(event.senderFrame ? event.senderFrame.url : event.sender.getURL()).hostname; } catch { pageHost = ''; }
    const verdict = core.connectVerdict(host, pageHost, s.meta.connects);
    if (verdict === 'undeclared') return { error: `${host} 不在脚本的 @connect 列表中，已拒绝` };
    if (verdict === 'declared') {
      const n = core.normalizeHost(host);
      const d = (s.connectDecisions || {})[n];
      const allow = d === undefined ? await this.ask(s, n, event.sender) : d;
      if (!allow) return { error: `已拒绝脚本访问 ${host}` };
    }
    const reqId = String(msg.reqId || '');
    const ctrl = new AbortController();
    if (reqId) this.xhrs.set(reqId, ctrl);
    try {
      const ses = event.sender && event.sender.session ? event.sender.session : this.session;
      return await performXhr({ ...msg, url }, { fetchImpl: (u, o) => ses.fetch(u, o), signal: ctrl.signal });
    } finally {
      this.xhrs.delete(reqId);
    }
  }

  ask(s, host, wc) {
    const { dialog, BrowserWindow } = require('electron');
    const key = `${s.id}|${host}`;
    if (this.asks.has(key)) return this.asks.get(key);
    const win = BrowserWindow.fromWebContents(wc) || BrowserWindow.getFocusedWindow();
    const opts = {
        type: 'question',
        title: '允许脚本跨域访问？',
        message: `用户脚本「${core.displayName(s.meta)}」想向 ${host} 发送请求（脚本的 @connect 已声明该域名）。`,
        detail: '请求会带上你在该网站的 Cookie（登录状态）。',
        buttons: ['拒绝', '仅这一次', '总是允许'],
        defaultId: 0,
        cancelId: 0,
        noLink: true,
    };
    const p = (win ? dialog.showMessageBox(win, opts) : dialog.showMessageBox(opts))
      .then(({ response }) => {
        if (response === 0) this.store.setConnectDecision(s.id, host, false);
        if (response === 2) this.store.setConnectDecision(s.id, host, true);
        return response !== 0;
      })
      .catch(() => false)
      .finally(() => this.asks.delete(key));
    this.asks.set(key, p);
    return p;
  }

  // ---- 安装
  async confirmInstall(pkg) {
    const { dialog } = require('electron');
    const m = pkg.meta;
    const old = this.store.existing(m);
    const lines = [];
    if (m.version) lines.push(`版本：${m.version}${old && old.meta.version ? `（已安装 ${old.meta.version}）` : ''}`);
    if (m.author) lines.push(`作者：${m.author}`);
    if (m.description) lines.push(m.description);
    const where = [...m.matches, ...m.includes];
    lines.push(`运行于：${where.length ? where.slice(0, 6).join('、') + (where.length > 6 ? ' …' : '') : '所有网页'}`);
    if (!core.grantsNone(m)) lines.push(`权限：${m.grants.join('、')}`);
    if (m.connects.length) lines.push(`可访问的域名：${m.connects.join('、')}`);
    const bad = core.compileRules(m).invalid;
    if (bad.length) lines.push(`⚠️ 忽略无效规则：${bad.join('、')}`);
    lines.push('', '只安装你信任的脚本：脚本可以读取和修改它运行的网页。');
    const opts = {
      type: 'question', title: old ? '更新用户脚本' : '安装用户脚本', message: core.displayName(m), detail: lines.join('\n'),
      buttons: ['取消', old ? '更新' : '安装'], defaultId: 1, cancelId: 0, noLink: true,
    };
    const w = this.win && !this.win.isDestroyed() ? this.win : null;
    const { response } = await (w ? dialog.showMessageBox(w, opts) : dialog.showMessageBox(opts));
    if (response !== 1) return null;
    return this.store.install(pkg);
  }

  async installCode(code, sourceURL) {
    const pkg = await prepare(code, sourceURL, this.fetch);
    const s = await this.confirmInstall(pkg);
    return s ? core.displayName(s.meta) : null;
  }

  async installUrl(input) {
    const pkg = await prepareUrl(input, this.fetch);
    const s = await this.confirmInstall(pkg);
    return s ? core.displayName(s.meta) : null;
  }

  async installFile() {
    const { dialog } = require('electron');
    const opts = { title: '导入用户脚本', properties: ['openFile'], filters: [{ name: '用户脚本', extensions: ['js'] }, { name: '所有文件', extensions: ['*'] }] };
    const w = this.win && !this.win.isDestroyed() ? this.win : null;
    const r = await (w ? dialog.showOpenDialog(w, opts) : dialog.showOpenDialog(opts));
    if (r.canceled || !r.filePaths[0]) return null;
    const st = fs.statSync(r.filePaths[0]);
    if (st.size > core.MAX_SCRIPT_BYTES) throw new core.UserScriptError(`文件太大（${Math.floor(st.size / 1024)} KB）`);
    return this.installCode(fs.readFileSync(r.filePaths[0], 'utf8'), null);
  }

  async updateOne(id) {
    const s = this.store.get(id);
    if (!s) throw new Error('脚本不存在');
    const pkg = await checkUpdate(s, this.fetch);
    this.store.markChecked(id);
    if (!pkg) return `「${core.displayName(s.meta)}」已是最新版本（${s.meta.version || '无版本号'}）`;
    this.store.install(pkg);
    return `「${core.displayName(pkg.meta)}」已更新到 ${pkg.meta.version}`;
  }

  async updateAll() {
    const out = [];
    for (const s of [...this.store.scripts]) {
      if (!core.updateCheckURL(s.meta, s.sourceURL)) continue;
      try {
        out.push(await this.updateOne(s.id));
      } catch (e) {
        out.push(`「${core.displayName(s.meta)}」：${(e && e.message) || e}`);
      }
    }
    return out.length ? out.join('\n') : '没有可检查更新的脚本';
  }

  /** 内置浏览器打开 *.user.js：询问是否安装 */
  watchUserScriptLinks(app) {
    app.on('web-contents-created', (e, wc) => {
      if (!this.isBrowserSession(wc.session)) return;
      wc.on('did-navigate', (ev, url) => {
        if (!core.looksLikeUserScript(url)) return;
        this.installUrl(url).catch((err) => {
          const { dialog } = require('electron');
          dialog.showMessageBox({ type: 'error', title: '无法安装用户脚本', message: String((err && err.message) || err) }).catch(() => undefined);
        });
      });
    });
  }

  // ---- 内置浏览器盾牌菜单
  menuItems(wc, host) {
    const items = [{ type: 'separator' }];
    const url = wc.getURL();
    const running = this.store.scripts.filter((s) => s.enabled && core.rulesMatch(core.compileRules(s.meta), url));
    const cmds = this.menus.get(wc.id);
    if (running.length) {
      items.push({ label: `本页用户脚本（${running.length}）`, enabled: false });
      for (const s of running) {
        const list = (cmds && cmds.get(s.id)) || [];
        if (list.length) {
          items.push({
            label: core.displayName(s.meta),
            submenu: list.map((c) => ({ label: c.name, click: () => this.runMenu(wc, s.id, c.id) })),
          });
        }
      }
    }
    items.push({ label: '用户脚本…', click: () => this.open() });
    return items;
  }

  runMenu(wc, scriptId, cmdId) {
    const index = this.store.scripts.findIndex((s) => s.id === scriptId);
    if (index < 0 || wc.isDestroyed()) return;
    const code = `window.__mioUserScriptMenu && window.__mioUserScriptMenu(${JSON.stringify(cmdId)})`;
    wc.executeJavaScriptInIsolatedWorld(WORLD_BASE + index, [{ code }]).catch(() => undefined);
  }

  // ---- 管理窗口
  snapshot() {
    return this.store.scripts.map((s) => ({
      id: s.id, name: core.displayName(s.meta), version: s.meta.version, description: s.meta.description, author: s.meta.author,
      enabled: s.enabled, grants: s.meta.grants, matches: [...s.meta.matches, ...s.meta.includes], runAt: s.meta.runAt,
      invalid: core.compileRules(s.meta).invalid, connects: s.meta.connects, decisions: s.connectDecisions || {},
      canUpdate: !!core.updateCheckURL(s.meta, s.sourceURL), sourceURL: s.sourceURL, updatedAt: s.updatedAt, lastUpdateCheck: s.lastUpdateCheck,
      homepage: s.meta.homepage,
    }));
  }

  push() {
    if (this.win && !this.win.isDestroyed()) this.win.webContents.send('mio-userscripts-ui:changed', this.snapshot());
  }

  open() {
    const { BrowserWindow, shell, nativeTheme } = require('electron');
    if (this.win && !this.win.isDestroyed()) {
      this.win.show();
      this.win.focus();
      return;
    }
    this.win = new BrowserWindow({
      width: 640, height: 720, minWidth: 460, minHeight: 480, title: '用户脚本', icon: this.icon, autoHideMenuBar: true, show: false,
      backgroundColor: nativeTheme.shouldUseDarkColors ? '#1c1c1e' : '#f2f2f7',
      webPreferences: { preload: path.join(__dirname, 'ui', 'userscripts-preload.js'), partition: this.uiPartition, contextIsolation: true, sandbox: true, nodeIntegration: false },
    });
    this.win.loadFile(path.join(__dirname, 'ui', 'userscripts.html'));
    this.win.once('ready-to-show', () => this.win && this.win.show());
    this.win.on('closed', () => { this.win = null; });
    this.win.webContents.setWindowOpenHandler(({ url }) => {
      if (/^https?:/i.test(url)) shell.openExternal(url).catch(() => undefined);
      return { action: 'deny' };
    });
  }
}

module.exports = { UserScripts, UserScriptStore, prepare, prepareUrl, checkUpdate, download, verifyIntegrity, performXhr, WORLD_BASE };
