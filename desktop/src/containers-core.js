'use strict';
// 内置浏览器「容器」（登录状态隔离）纯逻辑：无 Electron 依赖，node --test 可测。
// 与 iOS / Mac 的 MioContainerCore.swift、Android 的 xyz.mio.app.containers.ContainerState 同一套规则、同一份 JSON：
//   {
//     "version": 1,
//     "containers": [{ "id": "<uuid 小写>", "name": "工作", "color": "blue", "createdAt": <ms> }],
//     "tabs":       { "<tabKey>": { "containerId": "<id>", "locked": true } },
//     "siteRules":  [{ "host": "github.com", "containerId": "<id>" }],
//     "pendingRemovals": ["<id>"]          // 已删除、但底层数据还没清干净的容器（下次启动重试）
//   }
// - 默认容器 id = 'default'：就是原来内置浏览器的那份数据（不迁移、不丢登录），不存进 containers、不能删除。
// - 未知 / 已删除的容器 id 一律按默认容器处理（resolve）。
// - 标签 → 容器映射以调用方给的稳定字符串 tabKey 为键（标签管理器自己决定，如持久化标签 id）。
// - 锁定继承：锁定标签打开的子标签 / 弹窗继承容器且同样锁定；没锁定的标签打开的子标签默认继承容器（可被显式指定覆盖）。

const DEFAULT_ID = 'default';
const DEFAULT_NAME = '默认';
const DEFAULT_COLOR = 'gray';
const MAX_CONTAINERS = 20;
const MAX_NAME = 32;
// Firefox Multi-Account Containers 的配色
const COLORS = ['blue', 'turquoise', 'green', 'yellow', 'orange', 'red', 'pink', 'purple'];
const COLOR_HEX = {
  blue: '#37ADFF',
  turquoise: '#00C79A',
  green: '#51CD00',
  yellow: '#FFCB00',
  orange: '#FF9F00',
  red: '#FF613D',
  pink: '#FF4BDA',
  purple: '#AF51F5',
  gray: '#8E8E93',
};
const COLOR_NAMES = { blue: '蓝', turquoise: '青', green: '绿', yellow: '黄', orange: '橙', red: '红', pink: '粉', purple: '紫', gray: '灰' };

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

function isContainerId(id) {
  return typeof id === 'string' && UUID_RE.test(id);
}

function cleanName(name) {
  return String(name == null ? '' : name).replace(/\s+/g, ' ').trim().slice(0, MAX_NAME);
}

function cleanColor(c) {
  return COLORS.includes(c) ? c : null;
}

/** 站点规则的主机名：小写、去掉末尾点和 www.；接受网址 */
function normalizeHost(input) {
  let s = String(input == null ? '' : input).trim().toLowerCase();
  if (!s) return null;
  if (/^[a-z][a-z0-9+.-]*:\/\//.test(s)) {
    try {
      s = new URL(s).hostname;
    } catch {
      return null;
    }
  } else {
    s = s.split(/[/?#]/)[0].replace(/:\d+$/, '');
  }
  s = s.replace(/\.$/, '').replace(/^www\./, '');
  if (!/^[a-z0-9.-]+$/.test(s) || !s.includes('.') || s.startsWith('.') || s.includes('..')) return null;
  return s;
}

function hostOfUrl(url) {
  try {
    const u = new URL(String(url));
    if (u.protocol !== 'http:' && u.protocol !== 'https:') return null;
    return u.hostname.toLowerCase().replace(/\.$/, '');
  } catch {
    return null;
  }
}

/**
 * 锁定继承规则（纯函数）：子标签 / 弹窗用哪个容器。
 * parent: { containerId, locked } | null；requested: 调用方显式要求的容器 id（可空）。
 * - 父标签锁定 → { 父容器, locked: true }（忽略 requested）
 * - 有 requested → { requested, locked: false }
 * - 有父标签 → { 父容器, locked: false }
 * - 都没有 → 默认容器
 * 返回的 containerId 尚未 resolve（交给 ContainerState.resolve 处理已删除的容器）。
 */
function inheritContainer(parent, requested) {
  if (parent && parent.locked) return { containerId: parent.containerId || DEFAULT_ID, locked: true };
  if (requested) return { containerId: requested, locked: false };
  if (parent) return { containerId: parent.containerId || DEFAULT_ID, locked: false };
  return { containerId: DEFAULT_ID, locked: false };
}

/** 站点默认容器规则匹配：rules = [{ host, containerId }]，主机名本身或其子域名命中；多条命中取最长（最具体）的 */
function matchSiteRule(url, rules) {
  const host = hostOfUrl(url);
  if (!host || !Array.isArray(rules)) return null;
  let best = null;
  for (const r of rules) {
    if (!r || !r.host) continue;
    if (host === r.host || host.endsWith('.' + r.host) || host === 'www.' + r.host) {
      if (!best || r.host.length > best.host.length) best = r;
    }
  }
  return best ? best.containerId : null;
}

function randomUuid() {
  return require('node:crypto').randomUUID().toLowerCase();
}

class ContainerState {
  /**
   * @param {object} data 已解析的 JSON（容错：缺字段 / 坏字段都丢掉）
   * @param {{ now?: () => number, newId?: () => string }} opts
   */
  constructor(data, opts = {}) {
    this.now = opts.now || (() => Date.now());
    this.newId = opts.newId || randomUuid;
    this.containers = [];
    this.tabs = {};
    this.siteRules = [];
    this.pendingRemovals = [];
    const d = data && typeof data === 'object' ? data : {};
    const seen = new Set();
    for (const c of Array.isArray(d.containers) ? d.containers : []) {
      if (!c || !isContainerId(c.id) || seen.has(c.id) || this.containers.length >= MAX_CONTAINERS) continue;
      const name = cleanName(c.name);
      if (!name) continue;
      seen.add(c.id);
      this.containers.push({ id: c.id, name, color: cleanColor(c.color) || COLORS[0], createdAt: Number.isFinite(c.createdAt) ? c.createdAt : 0 });
    }
    if (d.tabs && typeof d.tabs === 'object') {
      for (const [k, v] of Object.entries(d.tabs)) {
        if (!k || !v || typeof v !== 'object') continue;
        const cid = this.exists(v.containerId) ? v.containerId : null;
        if (!cid) continue; // 指向已删除容器的映射丢掉（= 默认容器、不锁定）
        this.tabs[k] = { containerId: cid, locked: !!v.locked };
      }
    }
    const hosts = new Set();
    for (const r of Array.isArray(d.siteRules) ? d.siteRules : []) {
      const host = r && normalizeHost(r.host);
      if (!host || hosts.has(host) || !this.exists(r.containerId)) continue;
      hosts.add(host);
      this.siteRules.push({ host, containerId: r.containerId });
    }
    for (const id of Array.isArray(d.pendingRemovals) ? d.pendingRemovals : []) {
      if (isContainerId(id) && !seen.has(id) && !this.pendingRemovals.includes(id)) this.pendingRemovals.push(id);
    }
  }

  static parse(json, opts) {
    let data = null;
    try {
      data = typeof json === 'string' ? JSON.parse(json) : json;
    } catch {
      data = null;
    }
    return new ContainerState(data, opts);
  }

  toJSON() {
    return {
      version: 1,
      containers: this.containers.map((c) => ({ ...c })),
      tabs: Object.fromEntries(Object.entries(this.tabs).map(([k, v]) => [k, { ...v }])),
      siteRules: this.siteRules.map((r) => ({ ...r })),
      pendingRemovals: [...this.pendingRemovals],
    };
  }

  static defaultContainer() {
    return { id: DEFAULT_ID, name: DEFAULT_NAME, color: DEFAULT_COLOR, createdAt: 0, isDefault: true };
  }

  /** 默认容器在前 */
  list() {
    return [ContainerState.defaultContainer(), ...this.containers.map((c) => ({ ...c, isDefault: false }))];
  }

  get(id) {
    if (id === DEFAULT_ID) return ContainerState.defaultContainer();
    const c = this.containers.find((x) => x.id === id);
    return c ? { ...c, isDefault: false } : null;
  }

  exists(id) {
    return id === DEFAULT_ID || this.containers.some((c) => c.id === id);
  }

  /** 有效 id 原样返回，其他（空、未知、已删除）→ 'default' */
  resolve(id) {
    return this.exists(id) ? id : DEFAULT_ID;
  }

  canCreate() {
    return this.containers.length < MAX_CONTAINERS;
  }

  /** 下一个没被用过的颜色（都用过就按数量轮转） */
  nextColor() {
    const used = new Set(this.containers.map((c) => c.color));
    return COLORS.find((c) => !used.has(c)) || COLORS[this.containers.length % COLORS.length];
  }

  create({ name, color } = {}) {
    if (!this.canCreate()) throw new Error(`最多 ${MAX_CONTAINERS} 个容器`);
    const n = cleanName(name);
    if (!n) throw new Error('容器名称不能为空');
    let id = String(this.newId()).toLowerCase();
    while (!isContainerId(id) || this.exists(id) || this.pendingRemovals.includes(id)) id = randomUuid();
    const c = { id, name: n, color: cleanColor(color) || this.nextColor(), createdAt: this.now() };
    this.containers.push(c);
    return { ...c, isDefault: false };
  }

  update(id, { name, color } = {}) {
    const c = this.containers.find((x) => x.id === id);
    if (!c) throw new Error(id === DEFAULT_ID ? '默认容器不能修改' : '容器不存在');
    if (name !== undefined) {
      const n = cleanName(name);
      if (!n) throw new Error('容器名称不能为空');
      c.name = n;
    }
    if (color !== undefined) {
      const col = cleanColor(color);
      if (!col) throw new Error('无效的颜色');
      c.color = col;
    }
    return { ...c, isDefault: false };
  }

  /**
   * 删除容器：去掉元数据、它的标签映射（这些标签回到默认容器、解除锁定——标签管理器应直接关掉它们）、站点规则，
   * 并记入 pendingRemovals（底层数据清理完成后调用 markRemoved）。返回 { container, tabKeys }。
   */
  remove(id) {
    if (id === DEFAULT_ID) throw new Error('默认容器不能删除');
    const i = this.containers.findIndex((x) => x.id === id);
    if (i < 0) throw new Error('容器不存在');
    const [container] = this.containers.splice(i, 1);
    const tabKeys = this.tabsIn(id);
    for (const k of tabKeys) delete this.tabs[k];
    this.siteRules = this.siteRules.filter((r) => r.containerId !== id);
    if (!this.pendingRemovals.includes(id)) this.pendingRemovals.push(id);
    return { container: { ...container, isDefault: false }, tabKeys };
  }

  markRemoved(id) {
    this.pendingRemovals = this.pendingRemovals.filter((x) => x !== id);
  }

  // ---- 标签 → 容器映射（restore 用）

  /** 记录标签的容器和锁定。默认容器且不锁定 = 删除记录（省空间，读出来一样） */
  setTab(tabKey, { containerId, locked } = {}) {
    const key = String(tabKey == null ? '' : tabKey);
    if (!key) throw new Error('tabKey 不能为空');
    const cid = this.resolve(containerId);
    if (cid === DEFAULT_ID && !locked) delete this.tabs[key];
    else this.tabs[key] = { containerId: cid, locked: !!locked };
    return this.getTab(key);
  }

  /** 没记录 → { containerId: 'default', locked: false } */
  getTab(tabKey) {
    const t = this.tabs[String(tabKey)];
    return t ? { containerId: this.resolve(t.containerId), locked: !!t.locked } : { containerId: DEFAULT_ID, locked: false };
  }

  setTabLocked(tabKey, locked) {
    const t = this.getTab(tabKey);
    return this.setTab(tabKey, { containerId: t.containerId, locked: !!locked });
  }

  removeTab(tabKey) {
    delete this.tabs[String(tabKey)];
  }

  /** 只保留这些标签的记录（恢复标签后清掉已经不存在的标签） */
  retainTabs(tabKeys) {
    const keep = new Set([...tabKeys].map(String));
    for (const k of Object.keys(this.tabs)) if (!keep.has(k)) delete this.tabs[k];
  }

  tabsIn(containerId) {
    return Object.keys(this.tabs).filter((k) => this.tabs[k].containerId === containerId);
  }

  /** 锁定继承 + resolve：子标签 / 弹窗的 { containerId, locked } */
  childOf(parent, requested) {
    const r = inheritContainer(parent, requested && this.exists(requested) ? requested : null);
    return { containerId: this.resolve(r.containerId), locked: r.locked && this.exists(r.containerId) };
  }

  /**
   * 新标签用哪个容器（完整规则）：锁定的打开者 > 显式指定 > 站点默认容器规则 > 未锁定的打开者 > 默认容器。
   * opts: { url, opener: { containerId, locked } | null, requested }
   */
  containerForNewTab({ url, opener, requested } = {}) {
    if (opener && opener.locked) return this.childOf(opener, null);
    if (requested && this.exists(requested)) return { containerId: requested, locked: false };
    const rule = this.containerForUrl(url);
    if (rule) return { containerId: rule, locked: false };
    return this.childOf(opener || null, null);
  }

  // ---- 站点默认容器规则（可选）

  setSiteRule(input, containerId) {
    const host = normalizeHost(input);
    if (!host) throw new Error('无效的域名');
    if (containerId === DEFAULT_ID || !this.exists(containerId)) throw new Error('只能指定已有的非默认容器');
    this.siteRules = this.siteRules.filter((r) => r.host !== host);
    this.siteRules.push({ host, containerId });
    this.siteRules.sort((a, b) => a.host.localeCompare(b.host));
    return host;
  }

  removeSiteRule(input) {
    const host = normalizeHost(input) || String(input);
    this.siteRules = this.siteRules.filter((r) => r.host !== host);
  }

  containerForUrl(url) {
    const id = matchSiteRule(url, this.siteRules);
    return id && this.exists(id) ? id : null;
  }
}

module.exports = {
  ContainerState,
  inheritContainer,
  matchSiteRule,
  normalizeHost,
  isContainerId,
  DEFAULT_ID,
  DEFAULT_NAME,
  DEFAULT_COLOR,
  COLORS,
  COLOR_HEX,
  COLOR_NAMES,
  MAX_CONTAINERS,
  MAX_NAME,
};
