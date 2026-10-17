'use strict';
// 页面缩放（v0.3.4，跟 Safari 一致）：Ctrl + = / - / 0、Ctrl + 滚轮、触控板捏合；按站点记住（userData/zoom.json）；
// 设置里的默认缩放；地址栏百分比小标签。每个标签的 webContents 在导航后按站点规则 setZoomFactor。
const fs = require('node:fs');
const path = require('node:path');
const { EventEmitter } = require('node:events');
const core = require('./zoom-core');

class ZoomStore extends EventEmitter {
  /** @param {string} file  @param {() => number} [getDefault] 设置里的默认缩放（settings-store 的 defaultZoom） */
  constructor(file, getDefault) {
    super();
    this.file = file;
    this.getDefault = getDefault || (() => this.ownDefault);
    this.ownDefault = 1;
    let data = null;
    try {
      data = JSON.parse(fs.readFileSync(file, 'utf8'));
    } catch {
      // 首次启动 / 损坏
    }
    if (data && typeof data.defaultZoom === 'number') this.ownDefault = core.nearest(data.defaultZoom);
    this.table = new core.SiteTable(data);
  }
  get defaultZoom() {
    return core.nearest(Number(this.getDefault()) || 1);
  }
  levelFor(url) {
    return this.table.get(core.siteKey(url), this.defaultZoom);
  }
  setFor(url, z) {
    const site = core.siteKey(url);
    if (!site) return;
    this.table.set(site, z, this.defaultZoom);
    this.save();
    this.emit('change', site);
  }
  /** 只在没接设置时用（单测）；App 里默认值在 settings.json 的 defaultZoom */
  setDefault(z) {
    this.ownDefault = core.nearest(Number(z));
    this.save();
    this.emit('change', null);
  }
  clearSites() {
    this.table.clear();
    this.save();
    this.emit('change', null);
  }
  save() {
    try {
      fs.mkdirSync(path.dirname(this.file), { recursive: true });
      const tmp = `${this.file}.tmp`;
      fs.writeFileSync(tmp, JSON.stringify({ defaultZoom: this.ownDefault, ...this.table.toJSON() }));
      fs.renameSync(tmp, this.file);
    } catch {
      // 写失败：本次会话内仍有效
    }
  }
}

/** 给一个标签的 webContents 接上缩放：导航后按站点设置；Ctrl+滚轮按档位；允许触控板捏合 */
function attach(store, wc, onChange) {
  const apply = () => {
    if (wc.isDestroyed()) return;
    const z = store.levelFor(wc.getURL());
    if (Math.abs(wc.getZoomFactor() - z) > 0.001) wc.setZoomFactor(z);
    if (onChange) onChange();
  };
  wc.on('did-navigate', apply);
  wc.on('did-finish-load', apply);
  // Ctrl + 滚轮 / 触控板缩放手势：走同一套档位
  wc.on('zoom-changed', (_e, dir) => step(store, wc, dir === 'in' ? 'in' : 'out'));
  try {
    wc.setVisualZoomLevelLimits(1, 3).catch(() => undefined); // 触控板捏合（视觉缩放）
  } catch {
    // ignore
  }
  const listener = (site) => {
    if (wc.isDestroyed()) return store.off('change', listener);
    if (!site || site === core.siteKey(wc.getURL())) apply();
  };
  store.on('change', listener);
  wc.once('destroyed', () => store.off('change', listener));
  return apply;
}

/** dir = 'in' | 'out' | 'reset' */
function step(store, wc, dir) {
  if (!wc || wc.isDestroyed()) return null;
  const url = wc.getURL();
  const cur = store.levelFor(url);
  const z = dir === 'in' ? core.zoomIn(cur) : dir === 'out' ? core.zoomOut(cur) : store.defaultZoom;
  store.setFor(url, z);
  wc.setZoomFactor(z);
  return z;
}

module.exports = { ZoomStore, attach, step, core };
