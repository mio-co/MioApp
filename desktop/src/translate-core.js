'use strict';
// 翻译（内置浏览器）原生侧的纯逻辑，不依赖 electron（node --test 直接测）：
// - 设置（userData/translate.json）：目标语言、引擎、显示方式、自动翻译站点、划词、YouTube 双语、OpenAI 兼容 API（Key 用 safeStorage 加密后存）
// - 代理请求：只允许翻译引擎的域名 + 用户配置的 OpenAI 地址；OpenAI 的 Authorization 头只在这里加，页面脚本拿不到 Key
// - 持久缓存（userData/translate-cache.json，LRU）
// 页面脚本：shared/translate/mio-translate.js（打包时作为 extraResources/translate 带上）
const fs = require('node:fs');
const path = require('node:path');
const { EventEmitter } = require('node:events');

const LANGS = [
  ['zh-CN', '简体中文'], ['zh-TW', '繁體中文'], ['en', 'English'], ['ja', '日本語'], ['ko', '한국어'], ['fr', 'Français'],
  ['de', 'Deutsch'], ['es', 'Español'], ['ru', 'Русский'], ['pt', 'Português'], ['it', 'Italiano'], ['vi', 'Tiếng Việt'],
  ['th', 'ไทย'], ['id', 'Bahasa Indonesia'], ['ar', 'العربية'],
];
const ENGINES = [['microsoft', '微软翻译（免费）'], ['google', '谷歌翻译（免费）'], ['openai', '自定义 OpenAI 兼容 API']];

const FREE_HOSTS = new Set([
  'www.bing.com', 'bing.com', 'edge.microsoft.com',
  'api-edge.cognitive.microsofttranslator.com', 'api.cognitive.microsofttranslator.com',
  'translate.googleapis.com', 'translate.google.com',
]);
// 只放行这些请求头（页面脚本传来的其他头一律丢掉）
const ALLOWED_HEADERS = new Set(['content-type', 'accept', 'authorization']);
const MAX_BODY = 256 * 1024;
const MAX_RESPONSE = 3 * 1024 * 1024;

const DEFAULTS = {
  target: 'zh-CN',
  engine: 'microsoft',
  display: 'bilingual',
  autoSites: [],
  selection: true,
  youtube: true,
  ytSubs: true,
  openaiBase: '',
  openaiModel: '',
  openaiPrompt: '',
  openaiKeyEnc: '',
};

function normalizeHost(input) {
  let s = String(input || '').trim().toLowerCase();
  if (!s) return '';
  try {
    if (/^[a-z][a-z0-9+.-]*:\/\//.test(s)) s = new URL(s).hostname;
  } catch {
    return '';
  }
  s = s.replace(/^\*\./, '').replace(/^www\./, '').replace(/\/.*$/, '').replace(/:\d+$/, '').replace(/\.$/, '');
  return /^[a-z0-9-]+(\.[a-z0-9-]+)+$/.test(s) || s === 'localhost' ? s : '';
}

function hostMatches(host, entry) {
  const h = String(host || '').toLowerCase().replace(/\.$/, '');
  const e = normalizeHost(entry);
  return !!h && !!e && (h === e || h.endsWith('.' + e));
}

/** OpenAI 兼容地址：http(s)，去掉末尾斜杠和查询；空 = 未配置 */
function normalizeBase(input) {
  const s = String(input || '').trim();
  if (!s) return '';
  let u;
  try {
    u = new URL(s);
  } catch {
    return '';
  }
  if (u.protocol !== 'https:' && u.protocol !== 'http:') return '';
  u.search = '';
  u.hash = '';
  return u.toString().replace(/\/+$/, '');
}

function openaiEndpoint(base) {
  const b = normalizeBase(base);
  if (!b) return '';
  return /\/chat\/completions$/.test(b) ? b : `${b}/chat/completions`;
}

/**
 * 校验页面脚本发来的请求。返回 { ok, url, method, headers, body, timeoutMs, auth } 或 { ok: false, error }
 * 只允许免费引擎的 https 域名，或者 = 用户配置的 OpenAI 地址（auth: 'openai' 只在后者有效）
 */
function checkRequest(req, settings) {
  if (!req || typeof req !== 'object') return { ok: false, error: 'bad request' };
  let u;
  try {
    u = new URL(String(req.url || ''));
  } catch {
    return { ok: false, error: 'bad url' };
  }
  const method = String(req.method || 'GET').toUpperCase();
  if (method !== 'GET' && method !== 'POST') return { ok: false, error: 'method' };
  const endpoint = openaiEndpoint(settings && settings.openaiBase);
  const href = u.toString();
  const isOpenAI = !!endpoint && (href === endpoint || href.split('?')[0] === endpoint);
  if (!isOpenAI && !(u.protocol === 'https:' && FREE_HOSTS.has(u.hostname))) return { ok: false, error: 'host not allowed' };
  if (req.auth && (req.auth !== 'openai' || !isOpenAI)) return { ok: false, error: 'auth not allowed' };
  const headers = {};
  for (const [k, v] of Object.entries(req.headers || {})) {
    const lk = String(k).toLowerCase();
    if (!ALLOWED_HEADERS.has(lk)) continue;
    // Bearer 头只给 Edge 翻译 API（令牌来自 edge.microsoft.com）；OpenAI 的由原生加
    if (lk === 'authorization' && !/cognitive\.microsofttranslator\.com$/.test(u.hostname)) continue;
    headers[lk] = String(v).slice(0, 4096);
  }
  const body = req.body == null ? undefined : String(req.body);
  if (body && body.length > MAX_BODY) return { ok: false, error: 'body too large' };
  if (body && method === 'GET') return { ok: false, error: 'GET with body' };
  const timeoutMs = Math.max(1000, Math.min(Number(req.timeoutMs) || 15000, 90000));
  const pick = Array.isArray(req.pick) ? req.pick.slice(0, 8).map(String) : null;
  return { ok: true, url: href, method, headers, body, timeoutMs, auth: isOpenAI && req.auth === 'openai' ? 'openai' : null, pick };
}

/** 对响应文本跑正则，返回每个正则的捕获组（没匹配 = null） */
function runPicks(text, patterns) {
  return patterns.map((p) => {
    try {
      const m = new RegExp(p).exec(text);
      return m ? m.slice(1).map((x) => (x == null ? '' : x)) : null;
    } catch {
      return null;
    }
  });
}

/**
 * 执行请求（Node / Electron 的 fetch）。返回 { status, body } / { status, picks } / { error }
 * opts.key：OpenAI Key（只在 auth=openai 时用）；opts.fetchImpl 测试时替换
 */
async function performFetch(checked, opts = {}) {
  const fetchImpl = opts.fetchImpl || globalThis.fetch;
  const headers = { ...checked.headers };
  if (checked.auth === 'openai') {
    if (!opts.key) return { error: '没有设置 API Key' };
    headers.authorization = `Bearer ${opts.key}`;
  }
  if (opts.userAgent && !headers['user-agent']) headers['user-agent'] = opts.userAgent;
  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort(), checked.timeoutMs);
  try {
    const r = await fetchImpl(checked.url, { method: checked.method, headers, body: checked.body, signal: ac.signal, redirect: 'follow', credentials: 'omit' });
    const text = await r.text();
    const body = text.length > MAX_RESPONSE ? text.slice(0, MAX_RESPONSE) : text;
    if (checked.pick) return { status: r.status, picks: runPicks(body, checked.pick) };
    return { status: r.status, body };
  } catch (e) {
    return { error: ac.signal.aborted ? 'timeout' : String((e && e.message) || e) };
  } finally {
    clearTimeout(timer);
  }
}

class TranslateSettings extends EventEmitter {
  constructor(file) {
    super();
    this.file = file;
    this.data = { ...DEFAULTS, autoSites: [] };
    try {
      const j = JSON.parse(fs.readFileSync(file, 'utf8'));
      for (const k of Object.keys(DEFAULTS)) if (k in j && typeof j[k] === typeof DEFAULTS[k]) this.data[k] = j[k];
      if (!Array.isArray(this.data.autoSites)) this.data.autoSites = [];
    } catch {
      // 首次 / 损坏：默认值
    }
  }

  get(key) {
    return this.data[key];
  }

  /** 给设置页 / 菜单：不含加密的 Key 本身 */
  publicView() {
    const { openaiKeyEnc, ...rest } = this.data;
    return { ...rest, autoSites: [...this.data.autoSites], hasKey: !!openaiKeyEnc };
  }

  save() {
    if (this.file) {
      fs.mkdirSync(path.dirname(this.file), { recursive: true });
      const tmp = `${this.file}.tmp`;
      fs.writeFileSync(tmp, JSON.stringify(this.data, null, 2));
      fs.renameSync(tmp, this.file);
    }
    this.emit('change', this.publicView());
  }

  set(key, value) {
    if (!(key in DEFAULTS) || key === 'autoSites' || key === 'openaiKeyEnc') throw new Error(`unknown setting ${key}`);
    if (typeof value !== typeof DEFAULTS[key]) throw new Error(`bad value for ${key}`);
    if (key === 'target' && !LANGS.some((l) => l[0] === value)) throw new Error('bad language');
    if (key === 'engine' && !ENGINES.some((e) => e[0] === value)) throw new Error('bad engine');
    if (key === 'display' && value !== 'bilingual' && value !== 'translation') throw new Error('bad display');
    if (key === 'openaiBase' && value && !normalizeBase(value)) throw new Error('无效的地址（需要 http:// 或 https://）');
    this.data[key] = key === 'openaiBase' ? normalizeBase(value) : key === 'openaiPrompt' ? value.slice(0, 2000) : value;
    this.save();
  }

  setKeyEnc(enc) {
    this.data.openaiKeyEnc = String(enc || '');
    this.save();
  }

  isAuto(host) {
    return this.data.autoSites.some((e) => hostMatches(host, e));
  }

  setAuto(host, on) {
    const h = normalizeHost(host);
    if (!h) throw new Error('无效的域名');
    const before = this.data.autoSites.length;
    if (on) {
      if (!this.data.autoSites.includes(h)) this.data.autoSites.push(h);
      this.data.autoSites.sort();
    } else {
      this.data.autoSites = this.data.autoSites.filter((e) => !hostMatches(host, e) && e !== h);
    }
    if (on || this.data.autoSites.length !== before) this.save();
    return h;
  }

  openaiReady() {
    return !!(this.data.openaiBase && this.data.openaiModel && this.data.openaiKeyEnc);
  }
}

/** 注入脚本用的配置（不含 Key） */
function buildConfig(s, token, platform) {
  return {
    v: 1,
    token,
    platform,
    target: s.target,
    engine: s.engine,
    display: s.display,
    autoSites: [...s.autoSites],
    selection: !!s.selection,
    youtube: !!s.youtube,
    ytSubs: !!s.ytSubs,
    openai: { base: s.openaiBase, model: s.openaiModel, prompt: s.openaiPrompt, ready: !!(s.openaiBase && s.openaiModel && s.openaiKeyEnc) },
  };
}

const PLACEHOLDER = "'__MIO_TRANSLATE_CONFIG__'";

function scriptWithConfig(template, cfg) {
  if (!template.includes(PLACEHOLDER)) throw new Error('translate script placeholder missing');
  const b64 = Buffer.from(JSON.stringify(cfg), 'utf8').toString('base64');
  return template.replace(PLACEHOLDER, `'${b64}'`);
}

/** 持久缓存：{ key: [value, lastUsed] }，超过 limit 按最近使用淘汰；写盘去抖 */
class TranslateCache {
  constructor(file, limit = 20000) {
    this.file = file;
    this.limit = limit;
    this.map = null;
    this.timer = null;
  }

  load() {
    if (this.map) return;
    this.map = new Map();
    if (!this.file) return;
    try {
      const j = JSON.parse(fs.readFileSync(this.file, 'utf8'));
      const entries = Object.entries(j).filter(([, v]) => Array.isArray(v) && typeof v[0] === 'string');
      entries.sort((a, b) => (a[1][1] || 0) - (b[1][1] || 0));
      for (const [k, v] of entries) this.map.set(k, v[0]);
    } catch {
      // 没有缓存
    }
  }

  get(keys) {
    this.load();
    const out = {};
    for (const k of (Array.isArray(keys) ? keys : []).slice(0, 500)) {
      const key = String(k);
      if (!this.map.has(key)) continue;
      const v = this.map.get(key);
      this.map.delete(key);
      this.map.set(key, v);
      out[key] = v;
    }
    return out;
  }

  put(entries) {
    this.load();
    let n = 0;
    for (const [k, v] of Object.entries(entries || {})) {
      if (n++ >= 500) break;
      if (typeof v !== 'string' || k.length > 200 || v.length > 20000) continue;
      this.map.delete(k);
      this.map.set(k, v);
    }
    while (this.map.size > this.limit) this.map.delete(this.map.keys().next().value);
    this.scheduleSave();
  }

  clear() {
    this.map = new Map();
    this.scheduleSave(0);
  }

  get size() {
    this.load();
    return this.map.size;
  }

  scheduleSave(ms = 2000) {
    if (!this.file) return;
    if (this.timer) clearTimeout(this.timer);
    this.timer = setTimeout(() => this.flush(), ms);
    if (this.timer.unref) this.timer.unref();
  }

  flush() {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    if (!this.file || !this.map) return;
    const now = Date.now();
    const obj = {};
    let i = 0;
    for (const [k, v] of this.map) obj[k] = [v, now - (this.map.size - i++)];
    try {
      fs.mkdirSync(path.dirname(this.file), { recursive: true });
      fs.writeFileSync(`${this.file}.tmp`, JSON.stringify(obj));
      fs.renameSync(`${this.file}.tmp`, this.file);
    } catch {
      // 磁盘满等：下次再写
    }
  }
}

/** 页面脚本模板的位置：开发时在仓库 shared/，打包后在 resources/translate/ */
function scriptCandidates(dirname, resourcesPath) {
  const out = [];
  if (resourcesPath) out.push(path.join(resourcesPath, 'translate', 'mio-translate.js'));
  out.push(path.join(dirname, '..', '..', 'shared', 'translate', 'mio-translate.js'));
  return out;
}

module.exports = {
  LANGS, ENGINES, DEFAULTS, FREE_HOSTS, PLACEHOLDER,
  normalizeHost, hostMatches, normalizeBase, openaiEndpoint, checkRequest, runPicks, performFetch,
  TranslateSettings, TranslateCache, buildConfig, scriptWithConfig, scriptCandidates,
};
