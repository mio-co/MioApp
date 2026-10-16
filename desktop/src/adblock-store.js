'use strict';
// 过滤列表下载 / 缓存 / 引擎构建与缓存（与 iOS MioAdblockCore、Android AdblockStore 同一套逻辑）
// - App 内置：resources/adblock/（filter-<id>.txt、resources.json、manifest.json 带 ETag / Last-Modified）
// - 本机缓存：userData/adblock/（lists/、resources.json、state.json、engine.bin）
// - 更新：距上次检查超过 24 小时（启动时 + 每小时检查一次）逐个列表 If-None-Match / If-Modified-Since；
//   有变化 → 后台重建引擎；下载失败 / 内容不像过滤列表 → 继续用已有版本，首装用内置版本
// 不依赖 Electron：fetch、builder（构建函数）由调用方注入，node --test 可测。
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { EventEmitter } = require('node:events');
const config = require('./config');
const { looksLikeFilterList, countRules, listVersion } = require('./util');

const sha256 = (s) => crypto.createHash('sha256').update(s).digest('hex');

function readJSON(file, fallback) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return fallback;
  }
}

function writeAtomic(file, data) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, data);
  fs.renameSync(tmp, file);
}

class AdblockStore extends EventEmitter {
  /**
   * @param {object} o
   * @param {string} o.bundledDir  内置资源目录
   * @param {string} o.cacheDir    本机缓存目录
   * @param {Function} o.fetch     fetch 实现
   * @param {(lists: string[], resources: string) => Promise<{bytes: Uint8Array, stats: object}>} o.build
   * @param {string} o.engineFormat
   * @param {Function} [o.now]
   */
  constructor(o) {
    super();
    this.bundledDir = o.bundledDir;
    this.cacheDir = o.cacheDir;
    this.fetch = o.fetch;
    this.build = o.build;
    this.engineFormat = o.engineFormat;
    this.now = o.now || Date.now;
    this.listsDir = path.join(this.cacheDir, 'lists');
    this.stateFile = path.join(this.cacheDir, 'state.json');
    this.engineFile = path.join(this.cacheDir, 'engine.bin');
    this.engineMetaFile = path.join(this.cacheDir, 'engine.json');
    this.resourcesFile = path.join(this.cacheDir, 'resources.json');
    this.busy = null; // 'building' | 'updating' | null
    this.lastError = null;
    fs.mkdirSync(this.listsDir, { recursive: true });
  }

  state() {
    return readJSON(this.stateFile, {});
  }

  saveState(s) {
    writeAtomic(this.stateFile, JSON.stringify(s, null, 2));
  }

  listFile(id) {
    return path.join(this.listsDir, `filter-${id}.txt`);
  }

  allIds() {
    return [...config.FILTER_LISTS.map((l) => l.id), config.BUILTIN_LIST.id];
  }

  /** 首次 / 升级后内置资源更新：把内置版本放进缓存（缓存里已是更新的远程版本则保留） */
  prepare() {
    const manifest = readJSON(path.join(this.bundledDir, 'manifest.json'), { lists: {}, resources: {} });
    const bundledAt = Date.parse(manifest.generatedAt || 0) || 0;
    const s = this.state();
    s.lists = s.lists || {};
    for (const id of this.allIds()) {
      const src = path.join(this.bundledDir, `filter-${id}.txt`);
      if (!fs.existsSync(src)) continue;
      const meta = s.lists[id] || {};
      const cached = fs.existsSync(this.listFile(id));
      // 内置列表（id 0）随 App 版本走：总是用内置
      const useBundled = id === config.BUILTIN_LIST.id || !cached || (meta.downloadedAt || 0) < bundledAt;
      if (!useBundled) continue;
      const text = fs.readFileSync(src, 'utf8');
      if (cached && meta.sha256 === sha256(text)) continue;
      writeAtomic(this.listFile(id), text);
      const m = (manifest.lists && manifest.lists[id]) || {};
      s.lists[id] = {
        etag: m.etag || null,
        lastModified: m.lastModified || null,
        version: listVersion(text),
        rules: countRules(text),
        sha256: sha256(text),
        downloadedAt: bundledAt || this.now(),
        source: 'bundled',
      };
    }
    const resSrc = path.join(this.bundledDir, 'resources.json');
    if (fs.existsSync(resSrc)) {
      const r = s.resources || {};
      if (!fs.existsSync(this.resourcesFile) || (r.downloadedAt || 0) < bundledAt) {
        const text = fs.readFileSync(resSrc, 'utf8');
        if (r.sha256 !== sha256(text)) {
          writeAtomic(this.resourcesFile, text);
          const m = manifest.resources || {};
          s.resources = {
            etag: m.etag || null,
            lastModified: m.lastModified || null,
            scriptlets: scriptletCount(text),
            sha256: sha256(text),
            downloadedAt: bundledAt || this.now(),
            source: 'bundled',
          };
        }
      }
    }
    this.saveState(s);
    return s;
  }

  /** 当前缓存内容的指纹：列表 + 资源 + 引擎格式 */
  fingerprint(s = this.state()) {
    const parts = [this.engineFormat];
    for (const id of this.allIds()) parts.push(`${id}:${(s.lists && s.lists[id] && s.lists[id].sha256) || '-'}`);
    parts.push(`r:${(s.resources && s.resources.sha256) || '-'}`);
    return sha256(parts.join('|'));
  }

  /** 读取缓存的引擎；指纹不符 / 不存在则重建。返回序列化字节 */
  async engineBytes({ forceRebuild = false } = {}) {
    const s = this.state();
    const fp = this.fingerprint(s);
    const meta = readJSON(this.engineMetaFile, null);
    if (!forceRebuild && meta && meta.fingerprint === fp && fs.existsSync(this.engineFile)) {
      return { bytes: new Uint8Array(fs.readFileSync(this.engineFile)), stats: meta.stats, cached: true };
    }
    this.busy = 'building';
    this.emit('status');
    try {
      const lists = [];
      for (const id of this.allIds()) {
        if (fs.existsSync(this.listFile(id))) lists.push(fs.readFileSync(this.listFile(id), 'utf8'));
      }
      if (lists.length === 0) throw new Error('没有可用的过滤列表');
      const resources = fs.existsSync(this.resourcesFile) ? fs.readFileSync(this.resourcesFile, 'utf8') : '';
      const { bytes, stats } = await this.build(lists, resources);
      writeAtomic(this.engineFile, Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength));
      writeAtomic(this.engineMetaFile, JSON.stringify({ fingerprint: fp, stats, builtAt: this.now() }, null, 2));
      this.lastError = null;
      return { bytes, stats, cached: false };
    } catch (e) {
      this.lastError = String((e && e.message) || e);
      throw e;
    } finally {
      this.busy = null;
      this.emit('status');
    }
  }

  needsUpdateCheck() {
    const last = this.state().lastCheck || 0;
    return this.now() - last >= config.UPDATE_INTERVAL_MS;
  }

  async conditionalGet(url, meta) {
    const headers = { 'Cache-Control': 'no-cache' };
    if (meta && meta.etag) headers['If-None-Match'] = meta.etag;
    if (meta && meta.lastModified) headers['If-Modified-Since'] = meta.lastModified;
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 60000);
    try {
      const res = await this.fetch(url, { headers, signal: ctrl.signal, redirect: 'follow' });
      if (res.status === 304) return { notModified: true };
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const text = await res.text();
      return { text, etag: res.headers.get('etag'), lastModified: res.headers.get('last-modified') };
    } finally {
      clearTimeout(timer);
    }
  }

  /**
   * 检查更新。返回 { changed, message }；changed 时调用方重新加载引擎（engineBytes）。
   */
  async checkForUpdates({ force = false } = {}) {
    if (this.busy === 'updating') return { changed: false, message: '正在更新' };
    if (!force && !this.needsUpdateCheck()) return { changed: false, message: '24 小时内已检查' };
    this.busy = 'updating';
    this.emit('status');
    const s = this.state();
    s.lists = s.lists || {};
    let changed = 0;
    let unchanged = 0;
    const failed = [];
    try {
      for (const list of config.FILTER_LISTS) {
        const meta = s.lists[list.id] || {};
        try {
          const r = await this.conditionalGet(list.url, meta);
          if (r.notModified) {
            unchanged++;
            continue;
          }
          if (!looksLikeFilterList(r.text)) throw new Error('内容不像过滤列表');
          const hash = sha256(r.text);
          if (hash === meta.sha256) {
            unchanged++;
            s.lists[list.id] = { ...meta, etag: r.etag || meta.etag || null, lastModified: r.lastModified || meta.lastModified || null };
            continue;
          }
          writeAtomic(this.listFile(list.id), r.text);
          s.lists[list.id] = {
            etag: r.etag || null,
            lastModified: r.lastModified || null,
            version: listVersion(r.text),
            rules: countRules(r.text),
            sha256: hash,
            downloadedAt: this.now(),
            source: 'remote',
          };
          changed++;
        } catch (e) {
          failed.push(`${list.name}: ${(e && e.message) || e}`);
        }
      }
      // scriptlets 资源
      try {
        const meta = s.resources || {};
        const r = await this.conditionalGet(config.RESOURCES_URL, meta);
        if (!r.notModified) {
          if (scriptletCount(r.text) < 20) throw new Error('resources.json 无效');
          const hash = sha256(r.text);
          if (hash !== meta.sha256) {
            writeAtomic(this.resourcesFile, r.text);
            s.resources = { etag: r.etag || null, lastModified: r.lastModified || null, scriptlets: scriptletCount(r.text), sha256: hash, downloadedAt: this.now(), source: 'remote' };
            changed++;
          }
        }
      } catch (e) {
        failed.push(`Scriptlets: ${(e && e.message) || e}`);
      }
      const message = failed.length
        ? `${changed} 个更新，${failed.length} 个失败（${failed.join('；')}）`
        : changed
          ? `${changed} 个列表 / 资源已更新`
          : '已是最新';
      s.lastCheck = this.now();
      s.lastResult = message;
      this.saveState(s);
      return { changed: changed > 0, message };
    } finally {
      this.busy = null;
      this.emit('status');
    }
  }

  /** 设置页显示用 */
  snapshot() {
    const s = this.state();
    const meta = readJSON(this.engineMetaFile, null);
    const lists = [...config.FILTER_LISTS, config.BUILTIN_LIST].map((l) => {
      const m = (s.lists && s.lists[l.id]) || {};
      return { id: l.id, name: l.name, rules: m.rules || 0, version: m.version || null, downloadedAt: m.downloadedAt || null, source: m.source || null };
    });
    return {
      lists,
      resources: s.resources ? { scriptlets: s.resources.scriptlets, downloadedAt: s.resources.downloadedAt, source: s.resources.source } : null,
      lastCheck: s.lastCheck || null,
      lastResult: s.lastResult || null,
      engine: meta ? { ...meta.stats, builtAt: meta.builtAt } : null,
      busy: this.busy,
      error: this.lastError,
    };
  }
}

function scriptletCount(text) {
  try {
    const j = JSON.parse(text);
    return Array.isArray(j.scriptlets) ? j.scriptlets.length : 0;
  } catch {
    return 0;
  }
}

module.exports = { AdblockStore };
