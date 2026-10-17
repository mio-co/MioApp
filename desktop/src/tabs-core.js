'use strict';
// 内置浏览器多标签页：纯逻辑（无 Electron 依赖，node --test 可测）。
// 与 iOS / Mac 的 MioTabsCore.swift、Android 的 TabsCore.java 同一套规则：
//   - 新标签插在当前标签右边；从当前标签打开的一串后台标签按打开顺序排在一起（openerId）
//   - 关闭当前标签 → 激活右边的，没有就左边的；最近关闭的最多记 20 个，可恢复（插回原位置，连同容器 / 锁定）
//   - 标签数上限 MAX_TABS；超过「同时加载」上限时按最近使用时间卸载后台标签（只留 URL / 标题，切回时重新加载）
//   - 容器（登录状态隔离）：每个标签一个 containerId（'default' = 原来的浏览器数据）；从标签里打开的子标签 / 弹窗继承容器，
//     锁定的标签（locked）连锁定一起继承，且不能改容器
//   - 持久化只存 http(s) 的 URL + 标题 + 容器 + 锁定 + 当前标签序号

const MAX_TABS = 50;
const MAX_CLOSED = 20;
const MAX_TITLE = 300;
const DEFAULT_CONTAINER = 'default';
const DEFAULT_NEW_TAB_URL = 'https://mio.300031.xyz/mio/nav';

function isHttpUrl(url) {
  try {
    const u = new URL(String(url));
    return u.protocol === 'http:' || u.protocol === 'https:';
  } catch {
    return false;
  }
}

/** 地址栏 / 标签条显示用的域名：小写、去掉 www. */
function displayHost(url) {
  try {
    const u = new URL(String(url));
    if (u.protocol !== 'http:' && u.protocol !== 'https:') return '';
    return u.hostname.toLowerCase().replace(/\.$/, '').replace(/^www\./, '');
  } catch {
    return '';
  }
}

/** 设置里的新标签页地址：空 → 默认（MioCore 导航）；补 https://；不是 http(s) → null（拒绝） */
function normalizeNewTabUrl(input) {
  let s = String(input == null ? '' : input).trim();
  if (!s) return DEFAULT_NEW_TAB_URL;
  if (!/^[a-z][a-z0-9+.-]*:/i.test(s) || /^[^\s/:]+:\d+(\/|$)/.test(s)) s = 'https://' + s;
  if (!isHttpUrl(s)) return null;
  try {
    const u = new URL(s);
    if (!u.hostname || (!u.hostname.includes('.') && u.hostname !== 'localhost')) return null;
    return u.toString();
  } catch {
    return null;
  }
}

function cleanTitle(t) {
  return String(t == null ? '' : t).replace(/\s+/g, ' ').trim().slice(0, MAX_TITLE);
}

/** 标签的稳定字符串 key（容器模块的标签映射用；随会话持久化，重启不变） */
function makeTabKey() {
  return 't' + Date.now().toString(36) + Math.random().toString(36).slice(2, 10);
}

function cleanKey(k) {
  const s = String(k == null ? '' : k);
  return /^[A-Za-z0-9_-]{1,64}$/.test(s) ? s : null;
}

function cleanContainer(c) {
  const s = String(c == null ? '' : c).trim();
  return /^[A-Za-z0-9_-]{1,64}$/.test(s) ? s : DEFAULT_CONTAINER;
}

class TabStore {
  constructor({ maxTabs = MAX_TABS, maxClosed = MAX_CLOSED } = {}) {
    this.maxTabs = maxTabs;
    this.maxClosed = maxClosed;
    this.tabs = [];
    this.activeId = null;
    this.closed = [];
    this.nextId = 1;
    this.clock = 0;
  }

  get size() {
    return this.tabs.length;
  }

  get active() {
    return this.get(this.activeId);
  }

  get activeIndex() {
    return this.indexOf(this.activeId);
  }

  get(id) {
    return this.tabs.find((t) => t.id === id) || null;
  }

  indexOf(id) {
    return this.tabs.findIndex((t) => t.id === id);
  }

  canAdd() {
    return this.tabs.length < this.maxTabs;
  }

  /**
   * 新建标签。opts.activate（默认 true）；opts.fromActive：从当前标签打开（openerId = 当前标签，排在它的子标签后面，
   * 继承它的容器；它锁定了则连锁定一起继承，opts.containerId 被忽略）；opts.index 指定位置。满了返回 null。
   */
  add(url, opts = {}) {
    if (!this.canAdd()) return null;
    const activate = opts.activate !== false;
    const openerId = opts.openerId !== undefined ? opts.openerId : opts.fromActive ? this.activeId : null;
    const opener = openerId != null ? this.get(openerId) : null;
    let containerId = cleanContainer(opts.containerId);
    let locked = !!opts.locked;
    if (opener && opts.fromActive) {
      if (opener.locked) {
        containerId = opener.containerId;
        locked = true;
      } else if (opts.containerId == null) {
        containerId = opener.containerId;
      }
    }
    let key = cleanKey(opts.key);
    if (!key || this.tabs.some((t) => t.key === key)) key = makeTabKey();
    const tab = { id: this.nextId++, key, url: String(url || ''), title: cleanTitle(opts.title), openerId, containerId, locked, lastActive: 0 };
    let index;
    if (Number.isInteger(opts.index)) {
      index = Math.max(0, Math.min(this.tabs.length, opts.index));
    } else {
      const ai = this.activeIndex;
      if (ai < 0) {
        index = this.tabs.length;
      } else {
        index = ai + 1;
        if (tab.openerId != null && tab.openerId === this.activeId) {
          while (index < this.tabs.length && this.tabs[index].openerId === this.activeId) index++;
        }
      }
    }
    this.tabs.splice(index, 0, tab);
    if (activate || this.activeId == null) this.select(tab.id);
    return tab;
  }

  select(id) {
    const t = this.get(id);
    if (!t) return false;
    // 切到别的标签：之前「从当前标签打开」的关系不再用于插入位置
    if (this.activeId !== id) {
      for (const x of this.tabs) if (x.openerId != null && x.openerId === this.activeId && x.id !== id) x.openerId = null;
    }
    this.activeId = id;
    t.lastActive = ++this.clock;
    return true;
  }

  selectIndex(i) {
    const t = this.tabs[i];
    return t ? this.select(t.id) : false;
  }

  /** ⌃Tab / ⌃⇧Tab：循环切换 */
  selectRelative(delta) {
    if (!this.tabs.length) return false;
    const n = this.tabs.length;
    const i = this.activeIndex < 0 ? 0 : this.activeIndex;
    return this.selectIndex((((i + delta) % n) + n) % n);
  }

  /** ⌘1…⌘8 选第 n 个，⌘9 选最后一个（与 Safari / Chrome 相同） */
  selectNumber(n) {
    if (n === 9) return this.selectIndex(this.tabs.length - 1);
    return this.selectIndex(n - 1);
  }

  update(id, { url, title } = {}) {
    const t = this.get(id);
    if (!t) return false;
    let changed = false;
    if (url !== undefined && url !== null && String(url) !== t.url) {
      t.url = String(url);
      changed = true;
    }
    if (title !== undefined && title !== null) {
      const c = cleanTitle(title);
      if (c !== t.title) {
        t.title = c;
        changed = true;
      }
    }
    return changed;
  }

  /** 改标签的容器：锁定的标签不能改（返回 false）；调用方随后用新容器重建网页视图 */
  setContainer(id, containerId) {
    const t = this.get(id);
    if (!t || t.locked) return false;
    const c = cleanContainer(containerId);
    if (c === t.containerId) return false;
    t.containerId = c;
    return true;
  }

  setLocked(id, locked) {
    const t = this.get(id);
    if (!t || t.locked === !!locked) return false;
    t.locked = !!locked;
    return true;
  }

  /** 删除容器：它的标签全部关闭（返回被关闭的标签 id），最近关闭里它的条目也删掉（数据已清除，不能再恢复到它） */
  removeContainer(containerId) {
    const c = cleanContainer(containerId);
    if (c === DEFAULT_CONTAINER) return [];
    const ids = this.tabs.filter((t) => t.containerId === c).map((t) => t.id);
    for (const id of ids) this.close(id);
    this.closed = this.closed.filter((x) => x.containerId !== c);
    return ids;
  }

  /** 关闭标签，返回 { closed, activeId }（activeId = 关闭后应该显示的标签；没有标签了为 null） */
  close(id) {
    const i = this.indexOf(id);
    if (i < 0) return { closed: null, activeId: this.activeId };
    const [t] = this.tabs.splice(i, 1);
    if (isHttpUrl(t.url)) {
      this.closed.push({ url: t.url, title: t.title, index: i, containerId: t.containerId, locked: t.locked, key: t.key });
      while (this.closed.length > this.maxClosed) this.closed.shift();
    }
    for (const x of this.tabs) if (x.openerId === id) x.openerId = null;
    if (this.activeId === id) {
      this.activeId = null;
      const next = this.tabs[i] || this.tabs[i - 1] || null;
      if (next) this.select(next.id);
    }
    return { closed: t, activeId: this.activeId };
  }

  hasClosed() {
    return this.closed.length > 0;
  }

  /** ⌘⇧T：恢复最近关闭的标签（回到原来的位置、原来的容器）并激活；满了或没有 → null */
  reopenClosed() {
    if (!this.closed.length || !this.canAdd()) return null;
    const c = this.closed.pop();
    return this.add(c.url, { title: c.title, index: c.index, activate: true, openerId: null, containerId: c.containerId, locked: c.locked, key: c.key });
  }

  /** 拖拽排序 */
  move(from, to) {
    if (from < 0 || from >= this.tabs.length) return false;
    const dest = Math.max(0, Math.min(this.tabs.length - 1, to));
    if (dest === from) return false;
    const [t] = this.tabs.splice(from, 1);
    this.tabs.splice(dest, 0, t);
    return true;
  }

  /** 超过 maxLoaded 个已加载的标签时该卸载哪些（不含当前标签）：最久没用的先卸载 */
  toUnload(maxLoaded, isLoaded) {
    const loaded = this.tabs.filter((t) => isLoaded(t));
    const extra = loaded.length - Math.max(1, maxLoaded);
    if (extra <= 0) return [];
    return loaded
      .filter((t) => t.id !== this.activeId)
      .sort((a, b) => a.lastActive - b.lastActive)
      .slice(0, extra)
      .map((t) => t.id);
  }

  /** 持久化：{ v: 2, active, tabs: [{ url, title, key, container?, locked? }] }，只存 http(s) */
  serialize() {
    const keep = this.tabs.filter((t) => isHttpUrl(t.url));
    const active = keep.findIndex((t) => t.id === this.activeId);
    return {
      v: 2,
      active: active < 0 ? 0 : active,
      tabs: keep.map((t) => {
        const o = { url: t.url, title: t.title, key: t.key };
        if (t.containerId !== DEFAULT_CONTAINER) o.container = t.containerId;
        if (t.locked) o.locked = true;
        return o;
      }),
    };
  }

  /** 从 serialize() 的结果恢复（校验、截断到上限），替换现有标签。knownContainers：现存容器 id（已删除的回到默认容器）。返回恢复数 */
  restore(data, knownContainers) {
    if (!data || typeof data !== 'object' || !Array.isArray(data.tabs)) return 0;
    const items = data.tabs.filter((x) => x && isHttpUrl(x.url)).slice(0, this.maxTabs);
    if (!items.length) return 0;
    this.tabs = [];
    this.activeId = null;
    for (const x of items) {
      let c = cleanContainer(x.container);
      let locked = !!x.locked;
      if (knownContainers && c !== DEFAULT_CONTAINER && !knownContainers.includes(c)) {
        c = DEFAULT_CONTAINER; // 容器已删除：回到默认容器，不再锁定
        locked = false;
      }
      this.add(x.url, { title: x.title, activate: false, index: this.tabs.length, openerId: null, containerId: c, locked, key: x.key });
    }
    const a = Number.isInteger(data.active) ? Math.max(0, Math.min(items.length - 1, data.active)) : 0;
    this.selectIndex(a);
    return items.length;
  }
}

module.exports = { TabStore, MAX_TABS, MAX_CLOSED, DEFAULT_CONTAINER, DEFAULT_NEW_TAB_URL, displayHost, normalizeNewTabUrl, isHttpUrl, cleanTitle, cleanContainer, makeTabKey };
