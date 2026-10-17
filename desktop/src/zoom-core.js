'use strict';
// 页面缩放纯逻辑（v0.3.4，与 Mac 的 ios/App/App/MioDesktopParityCore.swift 同一套规则）：
// Safari 的档位、Ctrl/⌘ + = / - / 0、按站点（host，去掉 www.）记住，等于默认值时不单独记。

const LEVELS = [0.5, 0.75, 0.85, 1, 1.15, 1.25, 1.5, 1.75, 2, 2.5, 3];
const MIN = 0.5;
const MAX = 3;
const LIMIT = 500;

function nearest(z) {
  if (typeof z !== 'number' || !Number.isFinite(z)) return 1;
  return LEVELS.reduce((best, l) => (Math.abs(l - z) < Math.abs(best - z) ? l : best), 1);
}
const zoomIn = (z) => LEVELS.find((l) => l > z + 0.001) ?? MAX;
const zoomOut = (z) => [...LEVELS].reverse().find((l) => l < z - 0.001) ?? MIN;
const label = (z) => `${Math.round(z * 100)}%`;
const isDefault = (z, d) => Math.abs(z - d) < 0.001;

/** 站点键：http(s) 地址的小写 host，去掉 www.；其他返回 null */
function siteKey(url) {
  try {
    const u = new URL(String(url));
    if (u.protocol !== 'http:' && u.protocol !== 'https:') return null;
    const h = u.hostname.toLowerCase();
    if (!h) return null;
    return h.startsWith('www.') ? h.slice(4) : h;
  } catch {
    return null;
  }
}

/** 按站点的缩放表（可 JSON 往返；按设置先后保留最近 LIMIT 个） */
class SiteTable {
  constructor(data) {
    this.sites = new Map();
    const s = data && typeof data === 'object' && data.sites && typeof data.sites === 'object' ? data.sites : {};
    const order = Array.isArray(data && data.order) ? data.order : [];
    const keys = [...order.filter((k) => k in s), ...Object.keys(s).sort().filter((k) => !order.includes(k))];
    for (const k of keys) {
      const v = s[k];
      if (typeof v === 'number' && v >= MIN && v <= MAX) this.sites.set(k, nearest(v));
    }
  }
  get(site, def = 1) {
    return site && this.sites.has(site) ? this.sites.get(site) : def;
  }
  set(site, z, def = 1) {
    if (!site) return;
    this.sites.delete(site);
    if (isDefault(z, def)) return;
    this.sites.set(site, nearest(z));
    while (this.sites.size > LIMIT) this.sites.delete(this.sites.keys().next().value);
  }
  clear() {
    this.sites.clear();
  }
  get size() {
    return this.sites.size;
  }
  toJSON() {
    return { sites: Object.fromEntries(this.sites), order: [...this.sites.keys()] };
  }
}

module.exports = { LEVELS, MIN, MAX, LIMIT, nearest, zoomIn, zoomOut, label, isDefault, siteKey, SiteTable };
