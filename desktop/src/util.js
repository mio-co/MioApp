'use strict';
// 纯函数（无 Electron 依赖，node --test 可测）

/** 主机名（小写，去掉末尾的点）；非 http(s) / 无法解析 → '' */
function hostOf(url) {
  try {
    const u = new URL(url);
    if (u.protocol !== 'http:' && u.protocol !== 'https:') return '';
    return u.hostname.toLowerCase().replace(/\.$/, '');
  } catch {
    return '';
  }
}

function isHttpUrl(url) {
  try {
    const u = new URL(String(url).trim());
    return u.protocol === 'http:' || u.protocol === 'https:';
  } catch {
    return false;
  }
}

/** host 是否匹配模式：'example.com' 匹配自身及子域名；'*.example.com' 只匹配子域名 */
function hostMatches(host, pattern) {
  host = String(host || '').toLowerCase();
  pattern = String(pattern || '').toLowerCase().trim();
  if (!host || !pattern) return false;
  if (pattern.startsWith('*.')) {
    const base = pattern.slice(2);
    return host.endsWith('.' + base);
  }
  return host === pattern || host.endsWith('.' + pattern);
}

function hostInList(host, list) {
  return Array.isArray(list) && list.some((p) => hostMatches(host, p));
}

/** 白名单条目规范化：接受网址或域名，返回小写域名（去掉 www.）；无效 → '' */
function normalizeWhitelistEntry(input) {
  let s = String(input || '').trim().toLowerCase();
  if (!s) return '';
  if (!/^[a-z][a-z0-9+.-]*:\/\//.test(s)) s = 'https://' + s;
  const h = hostOf(s);
  if (!h || !/^[a-z0-9.-]+$/.test(h) || !h.includes('.')) return h === 'localhost' ? h : '';
  return h.replace(/^www\./, '');
}

/** 地址栏输入 → 网址：带协议的直接用；像域名的补 https://；否则搜索 */
function addressToUrl(input, searchUrl) {
  const s = String(input || '').trim();
  if (!s) return '';
  if (/^https?:\/\//i.test(s)) return isHttpUrl(s) ? s : searchUrl + encodeURIComponent(s);
  if (/^[a-z][a-z0-9+.-]*:/i.test(s) && !/^[^\s/:]+:\d+(\/|$)/.test(s)) {
    // about: / mailto: 等：当作搜索词（内置浏览器只打开 http(s)）
    return searchUrl + encodeURIComponent(s);
  }
  if (!/\s/.test(s) && (/^[^\s/]+\.[a-z]{2,}(:\d+)?(\/.*)?$/i.test(s) || /^localhost(:\d+)?(\/.*)?$/i.test(s) || /^\d{1,3}(\.\d{1,3}){3}(:\d+)?(\/.*)?$/.test(s))) {
    const u = 'https://' + s;
    if (isHttpUrl(u)) return u;
  }
  return searchUrl + encodeURIComponent(s);
}

/** 过滤列表文本粗检：太短、像 HTML → false */
function looksLikeFilterList(text) {
  if (typeof text !== 'string' || text.length < 1000) return false;
  if (/<html|<!doctype/i.test(text.slice(0, 2048))) return false;
  return true;
}

function countRules(text) {
  let n = 0;
  for (const line of String(text).split('\n')) {
    const l = line.trim();
    if (l && !l.startsWith('!') && !l.startsWith('[')) n++;
  }
  return n;
}

function listVersion(text) {
  const m = /^! Version:\s*(.+)$/m.exec(String(text));
  return m ? m[1].trim() : null;
}

module.exports = {
  hostOf,
  isHttpUrl,
  hostMatches,
  hostInList,
  normalizeWhitelistEntry,
  addressToUrl,
  looksLikeFilterList,
  countRules,
  listVersion,
};
