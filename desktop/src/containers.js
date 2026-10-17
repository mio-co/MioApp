'use strict';
// 内置浏览器「容器」：每个容器一个持久化 Electron 会话（Cookie / LocalStorage / IndexedDB / 缓存完全隔离）。
// - 默认容器（'default'）= 原来的 persist:mio-browser 会话，不迁移、不丢登录
// - 其他容器 = session.fromPartition('persist:mio-c-<uuid>')
// - 会话配置统一走 configure(fn)：已经创建的会话立即应用，之后新建的容器会话创建时应用。
//   main.js 把「浏览器会话该有的一切」（广告拦截 webRequest / preload、权限处理…）注册成 configurator，
//   所以默认会话和每个容器会话的行为完全一致。以后新增的会话级功能也请注册到这里，而不是只挂在 persist:mio-browser 上。
// 标签管理器接入：
//   const ses = containers.sessionFor(containerId)          // new WebContentsView({ webPreferences: { session: ses, ... } })
//   containers.store.containerForNewTab({ url, opener, requested }) / childOf(parent) / getTab / setTab / retainTabs
//   containers.store.on('removed', ({ container, tabKeys }) => 关闭这些标签)   // 在清理数据之前发出
const fs = require('node:fs');
const path = require('node:path');
const { EventEmitter } = require('node:events');
const { session, ipcMain } = require('electron');
const { DEFAULT_ID, COLORS, COLOR_HEX, COLOR_NAMES, MAX_CONTAINERS, isContainerId } = require('./containers-core');

const PARTITION_PREFIX = 'mio-c-';

function partitionName(containerId) {
  return `persist:${PARTITION_PREFIX}${containerId}`;
}

class ContainerSessions extends EventEmitter {
  /**
   * @param {{ store: import('./containers-store').ContainerStore, defaultPartition: string, userDataDir: string }} opts
   */
  constructor({ store, defaultPartition, userDataDir }) {
    super();
    this.store = store;
    this.defaultPartition = defaultPartition;
    this.userDataDir = userDataDir;
    this.configurators = [];
    this.sessions = new Map(); // partition → Session（已配置）
  }

  /** 平台是否支持容器（Electron 总是支持） */
  isSupported() {
    return true;
  }

  /** 注册会话配置函数 fn(session, containerId)：对已创建的会话立即执行，之后创建的会话创建时执行 */
  configure(fn) {
    this.configurators.push(fn);
    for (const [partition, ses] of this.sessions) this.applyOne(fn, ses, this.idForPartition(partition));
  }

  applyOne(fn, ses, containerId) {
    try {
      fn(ses, containerId);
    } catch (e) {
      console.error('[containers] configure', containerId, e);
    }
  }

  idForPartition(partition) {
    if (partition === this.defaultPartition) return DEFAULT_ID;
    return partition.slice(`persist:${PARTITION_PREFIX}`.length);
  }

  partitionFor(containerId) {
    const id = this.store.resolve(containerId);
    return id === DEFAULT_ID ? this.defaultPartition : partitionName(id);
  }

  /** 容器的会话（未知 / 已删除 → 默认容器的会话）。首次取用时应用全部 configurator */
  sessionFor(containerId) {
    const partition = this.partitionFor(containerId);
    let ses = this.sessions.get(partition);
    if (ses) return ses;
    ses = session.fromPartition(partition);
    this.sessions.set(partition, ses);
    const id = this.idForPartition(partition);
    for (const fn of this.configurators) this.applyOne(fn, ses, id);
    this.emit('session-created', { containerId: id, session: ses });
    return ses;
  }

  defaultSession() {
    return this.sessionFor(DEFAULT_ID);
  }

  /** 某个会话属于哪个容器（不是浏览器会话 → null） */
  containerIdOfSession(ses) {
    for (const [partition, s] of this.sessions) if (s === ses) return this.idForPartition(partition);
    return null;
  }

  isBrowserSession(ses) {
    return this.containerIdOfSession(ses) !== null;
  }

  storageDirFor(containerId) {
    return path.join(this.userDataDir, 'Partitions', `${PARTITION_PREFIX}${containerId}`);
  }

  /**
   * 删除容器：元数据去掉并发 'removed'（标签管理器关掉它的标签）→ 清空会话数据（Cookie、存储、IndexedDB、缓存、HTTP 认证）
   * → 尽量删掉分区目录（Windows 上会话还被占用时删不掉，留到下次启动 purgePending）。
   */
  async removeContainer(containerId) {
    if (!isContainerId(containerId)) throw new Error('默认容器不能删除');
    const partition = partitionName(containerId);
    const result = this.store.remove(containerId);
    const ses = this.sessions.get(partition);
    // 本次运行没加载过这个会话：数据只在磁盘上，直接删目录
    let cleared = !ses;
    if (ses) {
      try {
        await ses.clearStorageData();
        await ses.clearCache();
        await ses.clearAuthCache();
        cleared = true;
      } catch (e) {
        console.error('[containers] clear', containerId, e);
      }
    }
    this.sessions.delete(partition);
    const dir = this.storageDirFor(containerId);
    let dirRemoved = false;
    try {
      fs.rmSync(dir, { recursive: true, force: true, maxRetries: 2 });
      dirRemoved = !fs.existsSync(dir);
    } catch {
      dirRemoved = false;
    }
    // 数据已清空即算完成；目录残留时保留 pendingRemovals，下次启动（会话还没加载）再删目录
    if (cleared && dirRemoved) this.store.markRemoved(containerId);
    return { ...result, cleared, dirRemoved };
  }

  /** 启动时（任何容器会话创建之前）删掉上次没删干净的分区目录 */
  purgePending() {
    const done = [];
    for (const id of this.store.pendingRemovals) {
      const dir = this.storageDirFor(id);
      try {
        fs.rmSync(dir, { recursive: true, force: true, maxRetries: 2 });
        if (!fs.existsSync(dir)) {
          this.store.markRemoved(id);
          done.push(id);
        }
      } catch (e) {
        console.error('[containers] purge', id, e);
      }
    }
    return done;
  }

  /** 设置页「容器管理」IPC（isAllowedSender(event) 判断调用方是设置窗口） */
  installIpc(isAllowedSender) {
    const guard = (fn) => async (event, ...args) => {
      if (!isAllowedSender(event)) return null;
      return fn(...args);
    };
    const snap = () => this.snapshot();
    ipcMain.handle('mio-containers:get', guard(snap));
    ipcMain.handle('mio-containers:create', guard((name, color) => {
      this.store.create({ name: String(name || ''), color: COLORS.includes(color) ? color : undefined });
      return snap();
    }));
    ipcMain.handle('mio-containers:update', guard((id, patch) => {
      const p = patch && typeof patch === 'object' ? patch : {};
      this.store.update(String(id), { name: p.name === undefined ? undefined : String(p.name), color: p.color === undefined ? undefined : String(p.color) });
      return snap();
    }));
    ipcMain.handle('mio-containers:remove', guard(async (id) => {
      await this.removeContainer(String(id));
      return snap();
    }));
    ipcMain.handle('mio-containers:site-rule-set', guard((host, id) => {
      this.store.setSiteRule(String(host || ''), String(id || ''));
      return snap();
    }));
    ipcMain.handle('mio-containers:site-rule-remove', guard((host) => {
      this.store.removeSiteRule(String(host || ''));
      return snap();
    }));
  }

  snapshot() {
    return {
      supported: this.isSupported(),
      max: MAX_CONTAINERS,
      colors: COLORS.map((c) => ({ id: c, hex: COLOR_HEX[c], name: COLOR_NAMES[c] })),
      containers: this.store.list().map((c) => ({ ...c, hex: COLOR_HEX[c.color] || COLOR_HEX.gray, tabs: this.store.state.tabsIn(c.id).length })),
      siteRules: this.store.state.siteRules.map((r) => ({ ...r })),
    };
  }
}

module.exports = { ContainerSessions, partitionName, PARTITION_PREFIX };
