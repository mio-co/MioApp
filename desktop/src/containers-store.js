'use strict';
// 容器元数据 + 标签映射的持久化（userData/containers.json，原子写入）。只依赖 node，node --test 可测。
// 事件：'change'（任何修改后）、'removed'（容器被删除：{ container, tabKeys }，在底层数据清理之前发出）
const fs = require('node:fs');
const path = require('node:path');
const { EventEmitter } = require('node:events');
const { ContainerState } = require('./containers-core');

class ContainerStore extends EventEmitter {
  constructor(file, opts = {}) {
    super();
    this.file = file;
    let text = null;
    try {
      text = fs.readFileSync(file, 'utf8');
    } catch {
      // 首次启动
    }
    this.state = ContainerState.parse(text, opts);
  }

  save() {
    fs.mkdirSync(path.dirname(this.file), { recursive: true });
    const tmp = `${this.file}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(this.state.toJSON(), null, 2));
    fs.renameSync(tmp, this.file);
    this.emit('change', this.snapshot());
  }

  snapshot() {
    return { containers: this.state.list(), siteRules: this.state.siteRules.map((r) => ({ ...r })) };
  }

  list() {
    return this.state.list();
  }

  get(id) {
    return this.state.get(id);
  }

  resolve(id) {
    return this.state.resolve(id);
  }

  create(opts) {
    const c = this.state.create(opts);
    this.save();
    return c;
  }

  update(id, patch) {
    const c = this.state.update(id, patch);
    this.save();
    return c;
  }

  /** 去掉元数据并保存（pendingRemovals 里留着 id），发 'removed'；底层数据由调用方清理后 markRemoved */
  remove(id) {
    const r = this.state.remove(id);
    this.save();
    this.emit('removed', r);
    return r;
  }

  markRemoved(id) {
    this.state.markRemoved(id);
    this.save();
  }

  get pendingRemovals() {
    return [...this.state.pendingRemovals];
  }

  // 标签映射
  getTab(key) {
    return this.state.getTab(key);
  }

  setTab(key, v) {
    const r = this.state.setTab(key, v);
    this.save();
    return r;
  }

  setTabLocked(key, locked) {
    const r = this.state.setTabLocked(key, locked);
    this.save();
    return r;
  }

  removeTab(key) {
    this.state.removeTab(key);
    this.save();
  }

  retainTabs(keys) {
    this.state.retainTabs(keys);
    this.save();
  }

  childOf(parent, requested) {
    return this.state.childOf(parent, requested);
  }

  containerForNewTab(opts) {
    return this.state.containerForNewTab(opts);
  }

  // 站点规则
  setSiteRule(host, containerId) {
    const h = this.state.setSiteRule(host, containerId);
    this.save();
    return h;
  }

  removeSiteRule(host) {
    this.state.removeSiteRule(host);
    this.save();
  }

  containerForUrl(url) {
    return this.state.containerForUrl(url);
  }
}

module.exports = { ContainerStore };
