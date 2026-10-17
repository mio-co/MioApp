'use strict';
// 用户脚本管理器纯逻辑（Windows / Electron）：与 ios/App/App/MioUserScriptCore.swift 一一对应的 JS 移植
// （元数据解析、@match / @include 编译成正则源码、版本比较、@connect 判定、安装地址、注入代码生成）。
// 编译出的正则源码与 Swift 完全一致：desktop/test/userscripts.test.js 用 tools/MioAppTests/js/fixtures/userscript-rules.json 校验。
// 注入运行时（src/inject/userscript-runtime.js）由 scripts/sync-userscript-runtime.mjs 从 Swift 生成。
const fs = require('fs');
const path = require('path');

const MAX_SCRIPT_BYTES = 5 * 1024 * 1024;
const MAX_VALUE_BYTES = 5 * 1024 * 1024;
const TLD_RE = '\\.(?:[a-z0-9-]{2,63}|(?:com?|net|org|gov|edu|ac|ne|or|go)\\.[a-z]{2})';

// ---------------------------------------------------------------- 元数据

function runAtOf(v) {
  switch (String(v || '').trim().toLowerCase()) {
    case 'document-start':
      return 'document-start';
    case 'document-end':
    case 'document-body':
      return 'document-end';
    default:
      return 'document-idle';
  }
}

function isMarker(line, marker) {
  if (!line.startsWith('//')) return false;
  return line.slice(2).trim().startsWith(marker);
}

class UserScriptError extends Error {}

/** 解析 ==UserScript== 块；错误时抛 UserScriptError（消息与 iOS 相同） */
function parseMeta(code) {
  code = String(code);
  const bytes = Buffer.byteLength(code, 'utf8');
  if (bytes > MAX_SCRIPT_BYTES) throw new UserScriptError(`文件太大（${Math.floor(bytes / 1024)} KB）`);
  const m = {
    name: '', localizedNames: {}, namespace: '', version: '', description: '', author: '',
    matches: [], includes: [], excludes: [], excludeMatches: [], runAt: 'document-idle', grants: [], requires: [],
    resources: {}, connects: [], noframes: false, updateURL: null, downloadURL: null, homepage: null, icon: null, header: '',
  };
  let inBlock = false;
  let found = false;
  let sawName = false;
  const header = [];
  for (const raw of code.split(/\r\n|\r|\n/)) {
    const line = raw.trim();
    if (!inBlock) {
      if (isMarker(line, '==UserScript==')) {
        inBlock = true;
        header.push(raw);
      }
      continue;
    }
    header.push(raw);
    if (isMarker(line, '==/UserScript==')) {
      found = true;
      break;
    }
    if (!line.startsWith('//')) continue;
    const body = line.slice(2).trim();
    if (!body.startsWith('@')) continue;
    const rest = body.slice(1);
    const ws = rest.search(/[ \t]/);
    const rawKey = ws < 0 ? rest : rest.slice(0, ws);
    const value = ws < 0 ? '' : rest.slice(ws).trim();
    const ci = rawKey.indexOf(':');
    const key = (ci < 0 ? rawKey : rawKey.slice(0, ci)).toLowerCase();
    const locale = ci < 0 ? null : rawKey.slice(ci + 1);
    switch (key) {
      case 'name':
        if (locale !== null) m.localizedNames[locale] = value;
        else { m.name = value; sawName = true; }
        break;
      case 'description': if (locale === null) m.description = value; break;
      case 'namespace': m.namespace = value; break;
      case 'version': m.version = value; break;
      case 'author': m.author = value; break;
      case 'match': if (value) m.matches.push(value); break;
      case 'include': if (value) m.includes.push(value); break;
      case 'exclude': if (value) m.excludes.push(value); break;
      case 'exclude-match': if (value) m.excludeMatches.push(value); break;
      case 'run-at': m.runAt = runAtOf(value); break;
      case 'grant': if (value) m.grants.push(value); break;
      case 'require': if (value) m.requires.push(value); break;
      case 'resource': {
        const kv = value.split(/[ \t]+/).filter(Boolean);
        if (kv.length >= 2) m.resources[kv[0]] = kv[kv.length - 1];
        break;
      }
      case 'connect': if (value) m.connects.push(value); break;
      case 'noframes': m.noframes = true; break;
      case 'updateurl': m.updateURL = value || null; break;
      case 'downloadurl': case 'installurl': m.downloadURL = value || null; break;
      case 'homepage': case 'homepageurl': case 'website': case 'source': if (m.homepage === null && value) m.homepage = value; break;
      case 'icon': case 'iconurl': case 'defaulticon': if (m.icon === null && value) m.icon = value; break;
      default: break;
    }
  }
  if (!found) throw new UserScriptError('没有找到 // ==UserScript== … // ==/UserScript== 元数据块');
  if (!sawName || !m.name) throw new UserScriptError('元数据缺少 @name');
  m.header = header.join('\n');
  return m;
}

function grantsNone(meta) {
  const g = (meta.grants || []).filter(Boolean);
  return g.length === 0 || g.includes('none');
}

function displayName(meta) {
  for (const k of ['zh-CN', 'zh-Hans', 'zh-cn', 'zh']) if (meta.localizedNames && meta.localizedNames[k]) return meta.localizedNames[k];
  return meta.name;
}

const identity = (meta) => `${meta.namespace}\u001f${meta.name}`;

// ---------------------------------------------------------------- URL 规则

function escape(s) {
  let out = '';
  for (const ch of s) out += ('\\^$.|?*+()[]{}/'.includes(ch) ? '\\' : '') + ch;
  return out;
}

/** Chrome match pattern → { source, ignoreCase }；无效 null（与 Swift matchPattern 相同） */
function matchPattern(pattern) {
  const p = String(pattern).trim();
  if (p === '<all_urls>') return { source: '^(?:https?|file):\\/\\/.*$', ignoreCase: false };
  const sep = p.indexOf('://');
  if (sep < 0) return null;
  const scheme = p.slice(0, sep).toLowerCase();
  let schemeRe;
  if (scheme === '*') schemeRe = 'https?';
  else if (['http', 'https', 'file', 'ftp', 'ws', 'wss'].includes(scheme)) schemeRe = scheme;
  else return null;
  const rest = p.slice(sep + 3);
  const slash = rest.indexOf('/');
  const hostPart = (slash < 0 ? rest : rest.slice(0, slash)).toLowerCase();
  const pathPart = slash < 0 ? '/*' : rest.slice(slash);
  let hostRe;
  if (scheme === 'file') {
    if (hostPart) return null;
    hostRe = '';
  } else {
    if (!hostPart) return null;
    let host = hostPart;
    let portRe = '(?::\\d+)?';
    const colon = host.lastIndexOf(':');
    if (colon >= 0 && (!host.startsWith('[') || host.includes(']:'))) {
      const port = host.slice(colon + 1);
      if (port === '*' || (port && /^[0-9]+$/.test(port))) {
        portRe = port === '*' ? '(?::\\d+)?' : ':' + port;
        host = host.slice(0, colon);
      }
    }
    let tld = false;
    if (host.endsWith('.tld')) { tld = true; host = host.slice(0, -4); }
    if (host === '*') hostRe = '[^\\/:?#]+';
    else if (host.startsWith('*.')) {
      const base = host.slice(2);
      if (!base || base.includes('*')) return null;
      hostRe = '(?:[^\\/:?#]+\\.)?' + escape(base);
    } else {
      if (host.includes('*')) return null;
      hostRe = escape(host);
    }
    if (tld) hostRe += TLD_RE;
    hostRe += portRe;
  }
  if (!pathPart.startsWith('/')) return null;
  const pathRe = pathPart.split('*').map(escape).join('.*');
  return { source: '^' + schemeRe + ':\\/\\/' + hostRe + pathRe + '$', ignoreCase: false };
}

/** @include / @exclude：/正则/i 或 glob（与 Swift glob 相同） */
function glob(pattern) {
  const p = String(pattern).trim();
  if (!p) return null;
  if (p.length >= 2 && p.startsWith('/')) {
    const last = p.lastIndexOf('/');
    if (last > 0) {
      const flags = p.slice(last + 1);
      if (/^[igmsuy]*$/.test(flags)) {
        const src = p.slice(1, last);
        if (!src) return null;
        try { new RegExp(src); } catch { return null; }
        return { source: src, ignoreCase: flags.includes('i') };
      }
    }
  }
  if (p === '*') return { source: '^.*$', ignoreCase: true };
  let re = '';
  for (let i = 0; i < p.length; ) {
    const ch = p[i];
    if (ch === '*') re += '.*';
    else if (ch === '.' && p.slice(i, i + 4).toLowerCase() === '.tld' && (i + 4 === p.length || '/:?#'.includes(p[i + 4]))) {
      re += TLD_RE;
      i += 4;
      continue;
    } else re += escape(ch);
    i++;
  }
  return { source: '^' + re + '$', ignoreCase: true };
}

function compileRules(meta) {
  const invalid = [];
  const compile = (list, f) => (list || []).map((x) => { const r = f(x); if (!r) invalid.push(x); return r; }).filter(Boolean);
  return {
    matches: compile(meta.matches, matchPattern),
    includes: compile(meta.includes, glob),
    excludes: compile(meta.excludes, glob),
    excludeMatches: compile(meta.excludeMatches, matchPattern),
    matchAll: !(meta.matches || []).length && !(meta.includes || []).length,
    invalid,
  };
}

function ruleTest(r, url) {
  try { return new RegExp(r.source, r.ignoreCase ? 'i' : '').test(url); } catch { return false; }
}

/** 与注入运行时相同的判定（主进程用来决定要不要把脚本发给某个 frame） */
function rulesMatch(rules, url) {
  const noHash = String(url).split('#')[0];
  const included = rules.matchAll ? /^https?:\/\//i.test(url) : rules.matches.some((r) => ruleTest(r, noHash)) || rules.includes.some((r) => ruleTest(r, url));
  if (!included) return false;
  if (rules.excludes.some((r) => ruleTest(r, url))) return false;
  if (rules.excludeMatches.some((r) => ruleTest(r, noHash))) return false;
  return true;
}

// ---------------------------------------------------------------- 版本 / @connect / 安装地址

function splitVer(s) {
  const m = /^[0-9]*/.exec(s)[0];
  return [m ? Number(m.slice(0, 18)) || 0 : 0, s.slice(m.length)];
}

/** -1 / 0 / 1（Tampermonkey 风格，与 Swift 相同） */
function compareVersions(a, b) {
  const pa = String(a).trim().split('.').filter((x) => x !== '');
  const pb = String(b).trim().split('.').filter((x) => x !== '');
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const [na, sa] = splitVer(i < pa.length ? pa[i] : '0');
    const [nb, sb] = splitVer(i < pb.length ? pb[i] : '0');
    if (na !== nb) return na < nb ? -1 : 1;
    if (sa !== sb) {
      if (!sa) return 1;
      if (!sb) return -1;
      return sa < sb ? -1 : 1;
    }
  }
  return 0;
}

function normalizeHost(s) {
  let h = String(s || '').trim().toLowerCase();
  const r = h.indexOf('://');
  if (r >= 0) h = h.slice(r + 3);
  const i = h.search(/[/?#]/);
  if (i >= 0) h = h.slice(0, i);
  if (h.startsWith('[') && h.includes(']')) h = h.slice(1, h.indexOf(']'));
  else if ((h.match(/:/g) || []).length === 1) h = h.slice(0, h.lastIndexOf(':'));
  if (h.startsWith('*.')) h = h.slice(2);
  if (h.startsWith('.')) h = h.slice(1);
  if (h.endsWith('.')) h = h.slice(0, -1);
  return h;
}

function isDeclared(host, connects, pageHost) {
  const h = normalizeHost(host);
  if (!h) return false;
  for (const c of connects || []) {
    const raw = String(c).trim().toLowerCase();
    if (raw === '*') return true;
    const d = raw === 'self' ? normalizeHost(pageHost || '') : normalizeHost(raw);
    if (!d) continue;
    if (h === d || h.endsWith('.' + d)) return true;
  }
  return false;
}

/** 'sameOrigin' | 'declared' | 'undeclared' */
function connectVerdict(target, pageHost, connects) {
  const h = normalizeHost(target);
  if (pageHost && normalizeHost(pageHost) === h) return 'sameOrigin';
  return isDeclared(h, connects, pageHost) ? 'declared' : 'undeclared';
}

function installURL(input) {
  let u;
  try { u = new URL(String(input).trim()); } catch { return null; }
  if (u.protocol !== 'http:' && u.protocol !== 'https:') return null;
  const host = u.hostname.toLowerCase();
  if (!host) return null;
  const segs = u.pathname.split('/').filter(Boolean).map((s) => decodeURIComponent(s));
  if ((host === 'github.com' || host === 'www.github.com') && segs.length >= 5 && (segs[2] === 'blob' || segs[2] === 'raw')) {
    return 'https://raw.githubusercontent.com/' + [segs[0], segs[1], ...segs.slice(3)].map(encodeURIComponent).join('/');
  }
  if (['greasyfork.org', 'www.greasyfork.org', 'sleazyfork.org', 'www.sleazyfork.org'].includes(host)) {
    let i = 0;
    if (segs.length > 0 && segs[0] !== 'scripts') i = 1;
    if (segs.length > i + 1 && segs[i] === 'scripts') {
      const id = /^[0-9]*/.exec(segs[i + 1])[0];
      const isCode = segs.length > i + 2 && segs[i + 2] === 'code';
      if (id && (!isCode || !(segs[segs.length - 1] || '').endsWith('.user.js'))) {
        return `https://${host.replace('www.', '')}/scripts/${id}/code/script.user.js`;
      }
    }
  }
  u.hash = '';
  return u.href;
}

function looksLikeUserScript(url) {
  try {
    const u = new URL(url);
    return (u.protocol === 'http:' || u.protocol === 'https:') && u.pathname.toLowerCase().endsWith('.user.js');
  } catch {
    return false;
  }
}

const httpURL = (s) => {
  if (!s) return null;
  try { const u = new URL(s); return u.protocol === 'http:' || u.protocol === 'https:' ? u.href : null; } catch { return null; }
};

function updateCheckURL(meta, sourceURL) {
  for (const s of [meta.updateURL, meta.downloadURL, sourceURL]) { const u = httpURL(s); if (u) return u; }
  return null;
}

function downloadURL(meta, sourceURL) {
  const c = [meta.downloadURL, sourceURL];
  if (meta.updateURL && !meta.updateURL.toLowerCase().endsWith('.meta.js')) c.push(meta.updateURL);
  for (const s of c) { const u = httpURL(s); if (u) return u; }
  return null;
}

// ---------------------------------------------------------------- 注入代码

let runtimeCache = null;
function runtime() {
  if (!runtimeCache) {
    const src = fs.readFileSync(path.join(__dirname, 'inject', 'userscript-runtime.js'), 'utf8');
    const m = /^\/\/ MIO_PARAMS (.*)$/m.exec(src);
    runtimeCache = { src, params: m ? m[1] : '' };
  }
  return runtimeCache;
}

/**
 * 注入页面的完整代码（与 Swift MioUserScriptRuntime.source 相同的配置结构）。
 * opts.bridge：隔离 world 里原生桥对象名（Electron preload 用 contextBridge.exposeInIsolatedWorld 暴露）。
 */
function buildSource(s, values, { appVersion = '', platform = 'windows', bridge = 'mioUserScriptNative', token = '' } = {}) {
  const meta = s.meta;
  const rules = compileRules(meta);
  const isolated = !grantsNone(meta);
  const ruleList = (r) => r.map((x) => ({ s: x.source, i: x.ignoreCase }));
  const resources = {};
  for (const k of Object.keys(meta.resources || {})) resources[k] = (s.resourceCache || {})[k] || '';
  const info = {
    script: {
      name: meta.name, namespace: meta.namespace, version: meta.version, description: meta.description, author: meta.author,
      matches: meta.matches, includes: meta.includes, excludes: meta.excludes, grant: meta.grants, requires: meta.requires,
      resources: Object.keys(meta.resources || {}).map((k) => ({ name: k, url: meta.resources[k] })),
      'run-at': meta.runAt, noframes: meta.noframes, connects: meta.connects, uuid: s.id,
    },
    scriptMetaStr: meta.header, scriptHandler: 'Mio', version: appVersion, platform,
  };
  const config = {
    id: s.id, name: displayName(meta), isolated, handler: 'mioUserScript', bridge, token, runAt: meta.runAt, noframes: meta.noframes,
    grants: meta.grants, match: ruleList(rules.matches), include: ruleList(rules.includes), exclude: ruleList(rules.excludes),
    excludeMatch: ruleList(rules.excludeMatches), matchAll: rules.matchAll, values: isolated ? values || {} : {}, resources, info,
  };
  let body = '';
  for (const url of meta.requires || []) {
    const code = (s.requireCache || {})[url];
    if (typeof code === 'string') body += `// @require ${String(url).replace(/\n/g, '')}\n${code}\n;\n`;
  }
  body += s.code;
  const rt = runtime();
  // JSON 里的 U+2028/2029 在旧引擎里是换行：转义一下
  const json = JSON.stringify(config).replace(/\u2028/g, '\\u2028').replace(/\u2029/g, '\\u2029');
  return `${rt.src}(${json}, function(${rt.params}){\n${body}\n});\n`;
}

module.exports = {
  MAX_SCRIPT_BYTES, MAX_VALUE_BYTES, UserScriptError,
  parseMeta, grantsNone, displayName, identity, matchPattern, glob, compileRules, rulesMatch,
  compareVersions, normalizeHost, isDeclared, connectVerdict, installURL, looksLikeUserScript, updateCheckURL, downloadURL,
  buildSource, runtime,
};
