'use strict';
// 内置浏览器窗口：BaseWindow = 工具栏（本地页面，独立的 UI 会话；Safari 式：上面一行按钮 + 居中地址栏，下面一行标签条）
// + 每个标签一个网页视图（persist:mio-browser 会话，带拦截；同一容器的标签共享 Cookie / 登录状态）。
// MioCore 打开外链 → 新标签并显示窗口；target=_blank / window.open → 新标签（Ctrl / 中键点击 → 后台标签）；
// 带窗口尺寸参数的 window.open（OAuth 登录弹窗）仍是真正的弹窗；mailto: / tel: 等交给系统。
// 关窗口（✕ / 收起）= 隐藏：标签都留在后台不销毁，主窗口右下角显示「N 个标签」角标（tabs-badge.js），点一下回来。
// 标签管理的纯逻辑在 tabs-core.js；会话（URL + 标题 + 容器 + 锁定）存在 userData/browser-tabs.json，重启后恢复（懒加载）。
// 容器（登录隔离）：sessionForContainer(containerId) 由容器模块提供（feat/containers-core），默认所有标签用同一个浏览器会话。
const fs = require('node:fs');
const path = require('node:path');
const { EventEmitter } = require('node:events');
const { app, BaseWindow, BrowserWindow, WebContentsView, Menu, clipboard, shell, ipcMain, nativeTheme, session: electronSession } = require('electron');
const config = require('./config');
const { hostOf, isHttpUrl, addressToUrl } = require('./util');
const closeAfterExternal = require('./close-after-external');
const { TabStore, DEFAULT_CONTAINER, DEFAULT_NEW_TAB_URL, displayHost, normalizeNewTabUrl } = require('./tabs-core');

const ROW_HEIGHT = 44; // 按钮 + 地址栏
const TABSTRIP_HEIGHT = 34; // 标签条
const TOOLBAR_HEIGHT = ROW_HEIGHT + TABSTRIP_HEIGHT;
const MAX_LOADED_TABS = 16; // 同时保留网页进程的标签数，超过时卸载最久没用的后台标签
const UI_PARTITION = 'mio-ui'; // 工具栏 / 设置页：内存会话，不带拦截 preload

function bg() {
  return nativeTheme.shouldUseDarkColors ? '#0a0a0a' : '#ffffff';
}

class BrowserManager extends EventEmitter {
  /**
   * @param {object} o
   * @param {(containerId: string) => Electron.Session} [o.sessionForContainer] 容器模块接入点：返回该容器的会话（已配置拦截 / 脚本 / 权限）
   * @param {() => Array<{id: string, name: string, color: string}>} [o.listContainers] 容器列表（新建标签 / 在容器中打开的菜单）
   */
  constructor({ adblock, settings, browserSession, openSettings, icon, sessionForContainer, listContainers }) {
    super();
    this.adblock = adblock;
    this.settings = settings;
    this.session = browserSession;
    this.sessionForContainer = sessionForContainer || null;
    this.listContainers = listContainers || null;
    this.openSettings = openSettings;
    this.icon = icon;
    this.win = null;
    this.toolbar = null;
    this.store = new TabStore();
    this.views = new Map(); // tabId → WebContentsView（未加载 / 已卸载的标签没有）
    this.restored = false;
    this.quitting = false;
    this.htmlFullscreen = false;
    this.sessionFile = path.join(app.getPath('userData'), 'browser-tabs.json');
    this.saveTimer = null;
    adblock.onChange(() => this.pushState());
    settings.on('change', () => this.pushState());
    app.on('before-quit', () => {
      this.quitting = true;
      this.saveNow();
    });
    this.installIpc();
  }

  /** 当前标签的网页视图（其它模块 / 冒烟测试用 browser.content.webContents） */
  get content() {
    const t = this.store.active;
    return (t && this.views.get(t.id)) || null;
  }

  /** 标签用的会话：容器模块接入后按 containerId 取，否则都是默认浏览器会话 */
  sessionFor(tab) {
    if (this.sessionForContainer && tab && tab.containerId && tab.containerId !== DEFAULT_CONTAINER) {
      try {
        const s = this.sessionForContainer(tab.containerId);
        if (s) return s;
      } catch {
        // 容器不可用：退回默认会话
      }
    }
    return this.session;
  }

  installIpc() {
    ipcMain.on('mio-toolbar:cmd', (event, cmd, arg) => {
      if (!this.toolbar || event.sender !== this.toolbar.webContents) return;
      this.command(cmd, arg);
    });
    ipcMain.handle('mio-toolbar:state', (event) => {
      if (!this.toolbar || event.sender !== this.toolbar.webContents) return null;
      return this.state();
    });
  }

  isOpen() {
    return !!(this.win && !this.win.isDestroyed());
  }

  /** 窗口开着且没被收起 */
  isVisible() {
    return this.isOpen() && this.win.isVisible();
  }

  newTabUrl() {
    return normalizeNewTabUrl(this.settings.get('newTabUrl')) || DEFAULT_NEW_TAB_URL;
  }

  /** MioCore 打开外链：在新标签里打开并显示浏览器（窗口没开就先开并恢复上次的标签） */
  open(url, opts = {}) {
    if (!isHttpUrl(url)) throw new Error('invalid url');
    this.ensureWindow();
    this.newTab(url, { activate: true, containerId: opts.containerId });
    this.focusWindow();
  }

  /** 角标 / 菜单：回到浏览器（没有标签就开一个新标签页） */
  show() {
    this.ensureWindow();
    if (!this.store.size) this.newTab(null, { activate: true });
    else this.showActive();
    this.focusWindow();
  }

  /** 收起：窗口隐藏，标签全部留在后台（不销毁、不暂停），主窗口显示角标 */
  hide() {
    if (!this.isOpen()) return;
    this.win.hide();
    this.emitChange();
  }

  ensureWindow() {
    if (!this.restored) {
      this.restored = true;
      try {
        const known = this.listContainers ? this.listContainers().map((c) => c.id) : undefined;
        this.store.restore(JSON.parse(fs.readFileSync(this.sessionFile, 'utf8')), known);
      } catch {
        // 第一次 / 文件损坏：没有可恢复的标签
      }
    }
    if (!this.isOpen()) this.create();
  }

  focusWindow() {
    if (!this.isOpen()) return;
    if (this.win.isMinimized()) this.win.restore();
    this.win.show();
    this.win.focus();
    const c = this.content;
    if (c) c.webContents.focus();
    this.emitChange();
  }

  emitChange() {
    this.emit('change', { count: this.store.size, visible: this.isVisible() });
  }

  create() {
    const win = new BaseWindow({
      width: 1200,
      height: 820,
      minWidth: 480,
      minHeight: 360,
      title: 'Mio 浏览器',
      backgroundColor: bg(),
      icon: this.icon,
      autoHideMenuBar: true,
      show: false,
    });
    const toolbar = new WebContentsView({
      webPreferences: {
        preload: path.join(__dirname, 'ui', 'toolbar-preload.js'),
        partition: UI_PARTITION,
        contextIsolation: true,
        sandbox: true,
        nodeIntegration: false,
        spellcheck: false,
      },
    });
    toolbar.setBackgroundColor(bg());
    win.contentView.addChildView(toolbar);
    this.win = win;
    this.toolbar = toolbar;

    toolbar.webContents.loadFile(path.join(__dirname, 'ui', 'toolbar.html'));
    this.layout();
    win.on('resize', () => this.layout());
    // ✕ = 收起（标签留在后台）；退出 App 时才真正关闭
    win.on('close', (e) => {
      if (this.quitting) return;
      e.preventDefault();
      this.hide();
    });
    win.on('show', () => this.emitChange());
    win.on('hide', () => this.emitChange());
    win.on('closed', () => {
      for (const v of this.views.values()) this.destroyView(v);
      this.views.clear();
      try {
        if (!toolbar.webContents.isDestroyed()) toolbar.webContents.close();
      } catch {
        // ignore
      }
      this.win = this.toolbar = null;
      this.saveNow();
      this.emitChange();
    });
    win.once('ready-to-show', () => win.show());
    this.wireShortcuts(toolbar.webContents);
  }

  // ------------------------------------------------------------------ tabs

  /** 新建标签；url 省略 = 新标签页（设置里的地址，默认 MioCore 导航）。containerId 省略 = 默认容器 / 继承来源标签 */
  newTab(url, { activate = true, fromActive = false, containerId } = {}) {
    this.ensureWindow();
    const target = url && isHttpUrl(url) ? url : this.newTabUrl();
    const tab = this.store.add(target, { activate, fromActive, containerId });
    if (!tab) {
      this.notify(`最多同时打开 ${this.store.maxTabs} 个标签`);
      return null;
    }
    this.loadTab(tab, target);
    if (activate) this.showActive();
    else this.pushState();
    this.scheduleSave();
    this.emitChange();
    return tab;
  }

  /** 给标签建网页视图并加载 url（MioCore 自己的页面：先把主窗口的登录 Cookie 同步过来） */
  loadTab(tab, url) {
    let view = this.views.get(tab.id);
    if (!view) view = this.createView(tab);
    const go = () => {
      if (!view.webContents.isDestroyed()) view.webContents.loadURL(url).catch(() => undefined);
    };
    if (hostOf(url) === config.SITE_HOST) this.syncSiteCookies(this.sessionFor(tab)).finally(go);
    else go();
  }

  createView(tab) {
    const view = new WebContentsView({
      webPreferences: {
        session: this.sessionFor(tab),
        contextIsolation: true,
        sandbox: true,
        nodeIntegration: false,
        // 让拦截 preload（scriptlets / 元素隐藏）也在 iframe 里运行；preload 仍在沙箱里，页面拿不到 Node
        nodeIntegrationInSubFrames: true,
        backgroundThrottling: false,
        spellcheck: true,
      },
    });
    view.setBackgroundColor('#ffffff');
    view.setVisible(false);
    this.views.set(tab.id, view);
    if (this.isOpen()) {
      this.win.contentView.addChildView(view);
      this.layout();
    }
    const wc = view.webContents;
    // 每个标签各自注册（per-tab setup）：拦截计数、按 webContents 挂的功能（阅读模式 / 翻译 / 媒体…）、右键菜单、快捷键
    this.wireTab(tab.id, wc);
    this.wireContent(wc);
    this.wireShortcuts(wc);
    this.emit('tab-created', { tabId: tab.id, webContents: wc, containerId: tab.containerId });
    this.enforceLoadedLimit();
    return view;
  }

  destroyView(view) {
    try {
      if (this.isOpen()) this.win.contentView.removeChildView(view);
    } catch {
      // ignore
    }
    try {
      if (!view.webContents.isDestroyed()) view.webContents.close();
    } catch {
      // ignore
    }
  }

  /** 标签 ↔ store：地址、标题变化写回（会话恢复用） */
  wireTab(tabId, wc) {
    const sync = () => {
      const url = wc.getURL();
      const changed = this.store.update(tabId, { url: isHttpUrl(url) ? url : undefined, title: wc.getTitle() });
      if (changed) this.scheduleSave();
    };
    wc.on('did-navigate', sync);
    wc.on('did-navigate-in-page', sync);
    wc.on('page-title-updated', sync);
    wc.on('render-process-gone', () => {
      // 网页进程崩溃：当前标签重新加载，后台标签卸载（切回时再加载）
      if (!this.store.get(tabId)) return;
      if (this.store.activeId === tabId) setTimeout(() => !wc.isDestroyed() && wc.reload(), 300);
      else this.unloadTab(tabId);
    });
  }

  showActive() {
    if (!this.isOpen()) return;
    const tab = this.store.active;
    if (tab && !this.views.has(tab.id)) this.loadTab(tab, tab.url || this.newTabUrl());
    for (const [id, v] of this.views) v.setVisible(!!tab && id === tab.id);
    this.layout();
    const c = this.content;
    if (c) {
      const title = c.webContents.getTitle();
      this.win.setTitle(title ? `${title} — Mio 浏览器` : 'Mio 浏览器');
      if (!this.toolbar.webContents.isFocused()) c.webContents.focus();
    }
    this.enforceLoadedLimit();
    this.pushState();
  }

  selectTab(id) {
    if (this.store.select(id)) {
      this.showActive();
      this.scheduleSave();
    }
  }

  /**
   * 统一的关闭标签（✕、中键、Ctrl+W、window.close()、跳转系统浏览器后自动关闭）。
   * 最后一个标签关闭 → 收起浏览器窗口（App 不退出，主窗口照常），角标消失。
   */
  closeTab(id = this.store.activeId) {
    if (id == null) return;
    const view = this.views.get(id);
    const { closed } = this.store.close(id);
    if (!closed) return;
    if (view) this.destroyView(view);
    this.views.delete(id);
    this.scheduleSave();
    if (!this.store.size) {
      this.pushState();
      this.hide();
      return;
    }
    this.showActive();
    this.emitChange();
  }

  reopenClosedTab() {
    this.ensureWindow();
    const tab = this.store.reopenClosed();
    if (!tab) return;
    this.loadTab(tab, tab.url);
    this.showActive();
    this.scheduleSave();
    this.emitChange();
  }

  unloadTab(id) {
    if (id === this.store.activeId) return;
    const view = this.views.get(id);
    if (!view) return;
    this.views.delete(id);
    this.destroyView(view);
    this.pushState();
  }

  enforceLoadedLimit() {
    for (const id of this.store.toUnload(MAX_LOADED_TABS, (t) => this.views.has(t.id))) this.unloadTab(id);
  }

  /** 新标签页打开 MioCore 时复用主窗口的登录状态：把站点 Cookie（含 Cloudflare Access）复制到标签的会话 */
  async syncSiteCookies(target = this.session) {
    try {
      const main = electronSession.fromPartition(config.MAIN_PARTITION);
      const cookies = await main.cookies.get({ url: config.SITE_ORIGIN });
      await Promise.all(
        cookies.map((c) => {
          const details = {
            url: config.SITE_ORIGIN,
            name: c.name,
            value: c.value,
            path: c.path || '/',
            secure: c.secure,
            httpOnly: c.httpOnly,
          };
          if (c.sameSite && c.sameSite !== 'unspecified') details.sameSite = c.sameSite;
          if (!c.hostOnly && c.domain) details.domain = c.domain;
          if (!c.session && c.expirationDate) details.expirationDate = c.expirationDate;
          return target.cookies.set(details).catch(() => undefined);
        }),
      );
    } catch {
      // 主窗口没有登录：新标签页会走正常的 Access 登录
    }
  }

  scheduleSave() {
    clearTimeout(this.saveTimer);
    this.saveTimer = setTimeout(() => this.saveNow(), 800);
  }

  saveNow() {
    clearTimeout(this.saveTimer);
    this.saveTimer = null;
    if (!this.restored) return; // 还没读过旧会话：不要用空列表覆盖它
    try {
      fs.mkdirSync(path.dirname(this.sessionFile), { recursive: true });
      const tmp = `${this.sessionFile}.tmp`;
      fs.writeFileSync(tmp, JSON.stringify(this.store.serialize()));
      fs.renameSync(tmp, this.sessionFile);
    } catch {
      // 磁盘写不了：下次只是不恢复标签
    }
  }

  notify(text) {
    if (this.toolbar && !this.toolbar.webContents.isDestroyed()) this.toolbar.webContents.send('mio-toolbar:notice', String(text));
  }

  // ------------------------------------------------------------------ layout

  layout() {
    if (!this.isOpen()) return;
    const { width, height } = this.win.getContentBounds();
    const tb = this.htmlFullscreen ? 0 : TOOLBAR_HEIGHT;
    this.toolbar.setVisible(!this.htmlFullscreen);
    this.toolbar.setBounds({ x: 0, y: 0, width, height: TOOLBAR_HEIGHT });
    const bounds = { x: 0, y: tb, width, height: Math.max(0, height - tb) };
    for (const v of this.views.values()) v.setBounds(bounds);
  }

  /** 每个标签的网页：导航 / 弹窗 / 全屏 / 右键菜单（按 webContents 注册的功能都挂在这里，对每个标签生效） */
  wireContent(wc) {
    const push = () => this.pushState();
    const isActive = () => this.content && this.content.webContents === wc;
    wc.on('did-start-loading', push);
    wc.on('did-stop-loading', push);
    wc.on('did-navigate', push);
    wc.on('did-navigate-in-page', push);
    wc.on('page-title-updated', (e, title) => {
      if (this.isOpen() && isActive()) this.win.setTitle(title ? `${title} — Mio 浏览器` : 'Mio 浏览器');
      push();
    });
    wc.on('did-start-navigation', (details) => {
      if (details.isMainFrame && !details.isSameDocument) this.adblock.resetCount(wc.id);
    });
    // 网页被拦截数：节流刷新（计数在 adblock 的 onBeforeRequest 里累加）
    let timer = null;
    wc.on('did-frame-finish-load', () => {
      if (timer) return;
      timer = setTimeout(() => {
        timer = null;
        push();
      }, 500);
    });

    wc.setWindowOpenHandler(({ url, features, disposition }) => {
      if (!isHttpUrl(url)) {
        if (/^(mailto|tel|sms|facetime|maps|weixin|alipays?):/i.test(url)) shell.openExternal(url).catch(() => undefined);
        return { action: 'deny' };
      }
      // 带尺寸参数的弹窗（OAuth 登录等）：真正的弹窗，同一会话（同一容器），保留 opener
      if (features && /(width|height)=/i.test(features) && disposition === 'new-window') {
        return {
          action: 'allow',
          overrideBrowserWindowOptions: {
            width: 520,
            height: 680,
            autoHideMenuBar: true,
            parent: undefined,
            webPreferences: { session: wc.session, contextIsolation: true, sandbox: true, nodeIntegrationInSubFrames: true },
          },
        };
      }
      // target=_blank / window.open：新标签（继承来源标签的容器 / 锁定）；Ctrl / ⌘ / 中键点击 → 后台标签
      this.openFrom(wc, url, disposition !== 'background-tab');
      return { action: 'deny' };
    });

    wc.on('will-navigate', (event) => {
      const url = event.url;
      if (!isHttpUrl(url) && !/^(about|data|blob):/i.test(url)) {
        event.preventDefault();
        if (/^(mailto|tel|sms|facetime|maps|weixin|alipays?):/i.test(url)) shell.openExternal(url).catch(() => undefined);
      }
    });

    wc.on('enter-html-full-screen', () => {
      this.htmlFullscreen = true;
      this.layout();
    });
    wc.on('leave-html-full-screen', () => {
      this.htmlFullscreen = false;
      this.layout();
    });

    wc.on('context-menu', (e, p) => {
      const items = [];
      if (p.linkURL && isHttpUrl(p.linkURL)) {
        items.push({ label: '在新标签页中打开链接', click: () => this.openFrom(wc, p.linkURL, false) });
        const inContainer = this.containerMenu(wc, (containerId) => this.openFrom(wc, p.linkURL, true, containerId));
        if (inContainer) items.push({ label: '在容器中打开链接', submenu: inContainer });
        items.push({ label: '打开链接', click: () => wc.loadURL(p.linkURL).catch(() => undefined) });
        items.push({ label: '用系统浏览器打开链接', click: () => shell.openExternal(p.linkURL).catch(() => undefined) });
        items.push({ label: '复制链接地址', click: () => clipboard.writeText(p.linkURL) });
        items.push({ type: 'separator' });
      }
      if (p.mediaType === 'image' && p.srcURL) {
        if (isHttpUrl(p.srcURL)) items.push({ label: '在新标签页中打开图片', click: () => this.openFrom(wc, p.srcURL, false) });
        items.push({ label: '复制图片', click: () => wc.copyImageAt(p.x, p.y) });
        items.push({ label: '复制图片地址', click: () => clipboard.writeText(p.srcURL) });
        items.push({ type: 'separator' });
      }
      if (p.isEditable) {
        items.push({ role: 'cut', label: '剪切' }, { role: 'copy', label: '复制' }, { role: 'paste', label: '粘贴' }, { role: 'selectAll', label: '全选' });
        items.push({ type: 'separator' });
      } else if (p.selectionText) {
        items.push({ role: 'copy', label: '复制' });
        items.push({
          label: `搜索“${p.selectionText.slice(0, 20)}${p.selectionText.length > 20 ? '…' : ''}”`,
          click: () => this.openFrom(wc, config.SEARCH_URL + encodeURIComponent(p.selectionText), true),
        });
        items.push({ type: 'separator' });
      }
      items.push(
        { label: '后退', enabled: wc.navigationHistory.canGoBack(), click: () => wc.navigationHistory.goBack() },
        { label: '前进', enabled: wc.navigationHistory.canGoForward(), click: () => wc.navigationHistory.goForward() },
        { label: '刷新', click: () => wc.reload() },
        { type: 'separator' },
        { label: '检查元素', click: () => wc.inspectElement(p.x, p.y) },
      );
      Menu.buildFromTemplate(items).popup({ window: this.win });
    });
  }

  tabIdOf(wc) {
    for (const [id, v] of this.views) if (v.webContents === wc) return id;
    return null;
  }

  /** 从某个标签里打开新标签：插在它右边，继承它的容器（锁定时强制继承） */
  openFrom(wc, url, activate, containerId) {
    const from = this.tabIdOf(wc);
    if (from != null && from !== this.store.activeId) this.store.select(from);
    return this.newTab(url, { activate, fromActive: from != null, containerId });
  }

  /** 「在容器中打开」子菜单；没有容器模块 / 只有默认容器时返回 null；来源标签锁定时不可选别的容器 */
  containerMenu(wc, pick) {
    if (!this.listContainers) return null;
    let list = [];
    try {
      list = this.listContainers() || [];
    } catch {
      list = [];
    }
    if (list.length < 2) return null;
    const from = this.store.get(this.tabIdOf(wc));
    return list.map((c) => ({
      label: c.name || c.id,
      enabled: !(from && from.locked && from.containerId !== c.id),
      click: () => pick(c.id),
    }));
  }

  wireShortcuts(wc) {
    wc.on('before-input-event', (event, input) => {
      if (input.type !== 'keyDown') return;
      const mod = process.platform === 'darwin' ? input.meta : input.control;
      const key = (input.key || '').toLowerCase();
      let cmd = null;
      let arg;
      if ((mod && key === 'l') || key === 'f6') cmd = 'focusAddress';
      else if ((mod && key === 'r') || key === 'f5') cmd = input.shift ? 'hardReload' : 'reload';
      else if ((input.alt && key === 'arrowleft') || (mod && key === '[')) cmd = 'back';
      else if ((input.alt && key === 'arrowright') || (mod && key === ']')) cmd = 'forward';
      else if (mod && input.shift && key === 't') cmd = 'reopenTab';
      else if (mod && !input.shift && key === 't') cmd = 'newTab';
      else if (mod && input.shift && key === 'w') cmd = 'hide';
      else if ((mod && key === 'w') || (mod && key === 'f4')) cmd = 'closeTab';
      else if (input.control && key === 'tab') cmd = input.shift ? 'prevTab' : 'nextTab';
      else if (input.control && key === 'pagedown') cmd = 'nextTab';
      else if (input.control && key === 'pageup') cmd = 'prevTab';
      else if (mod && !input.shift && /^[1-9]$/.test(key)) {
        cmd = 'selectNumber';
        arg = key;
      } else if (key === 'f12' || (mod && input.shift && key === 'i')) cmd = 'devtools';
      else if (key === 'escape' && this.content && wc === this.content.webContents) cmd = 'stop';
      if (cmd) {
        event.preventDefault();
        this.command(cmd, arg);
      }
    });
  }

  command(cmd, arg) {
    if (!this.isOpen()) return;
    // 标签 / 窗口相关：不需要当前网页
    switch (cmd) {
      case 'newTab':
        this.newTab(null, { activate: true, containerId: arg || undefined });
        this.command('focusAddress');
        return;
      case 'newTabMenu': {
        const list = this.containerMenu(null, (id) => this.command('newTab', id));
        if (!list) return this.command('newTab');
        const { width } = this.win.getContentBounds();
        Menu.buildFromTemplate([{ label: '新建标签页（选择容器）', enabled: false }, { type: 'separator' }, ...list]).popup({ window: this.win, x: Math.max(0, width - 260), y: ROW_HEIGHT });
        return;
      }
      case 'closeTab':
        this.closeTab(arg !== undefined ? Number(arg) : this.store.activeId);
        return;
      case 'selectTab':
        this.selectTab(Number(arg));
        return;
      case 'nextTab':
      case 'prevTab':
        if (this.store.selectRelative(cmd === 'nextTab' ? 1 : -1)) this.showActive();
        return;
      case 'selectNumber':
        if (this.store.selectNumber(Number(arg))) this.showActive();
        return;
      case 'reopenTab':
        this.reopenClosedTab();
        return;
      case 'moveTab': {
        const [from, to] = String(arg || '').split(',').map(Number);
        if (Number.isInteger(from) && Number.isInteger(to) && this.store.move(from, to)) {
          this.pushState();
          this.scheduleSave();
        }
        return;
      }
      case 'tabsMenu':
        this.tabsMenu();
        return;
      case 'tabContextMenu':
        this.tabContextMenu(Number(arg));
        return;
      case 'hide':
      case 'close':
        this.hide();
        return;
      default:
        break;
    }
    const c = this.content;
    if (!c) return;
    const wc = c.webContents;
    switch (cmd) {
      case 'back':
        if (wc.navigationHistory.canGoBack()) wc.navigationHistory.goBack();
        break;
      case 'forward':
        if (wc.navigationHistory.canGoForward()) wc.navigationHistory.goForward();
        break;
      case 'reload':
        wc.reload();
        break;
      case 'hardReload':
        wc.reloadIgnoringCache();
        break;
      case 'stop':
        wc.stop();
        break;
      case 'navigate': {
        const url = addressToUrl(arg, config.SEARCH_URL);
        if (url) {
          if (hostOf(url) === config.SITE_HOST) this.syncSiteCookies(wc.session).finally(() => wc.loadURL(url).catch(() => undefined));
          else wc.loadURL(url).catch(() => undefined);
        }
        wc.focus();
        break;
      }
      case 'openExternal': {
        const url = wc.getURL();
        if (!isHttpUrl(url)) break;
        // 跳转系统浏览器后自动关闭标签页（默认关）：打开成功才关，走统一的 closeTab（最后一个标签 → 收起窗口，App 不退出）
        const tabId = this.store.activeId;
        closeAfterExternal.openExternalThenMaybeClose({
          url,
          enabled: !!this.settings.get(closeAfterExternal.SETTING_KEY),
          openExternal: (u) => shell.openExternal(u),
          close: () => this.closeTab(tabId),
        });
        break;
      }
      case 'share': {
        const url = wc.getURL();
        if (!isHttpUrl(url)) break;
        const { width } = this.win.getContentBounds();
        Menu.buildFromTemplate([
          { label: '复制链接', click: () => clipboard.writeText(url) },
          { label: '复制标题和链接', click: () => clipboard.writeText(`${wc.getTitle()}\n${url}`) },
          { label: '用系统浏览器打开', click: () => this.command('openExternal') },
        ]).popup({ window: this.win, x: Math.max(0, width - 300), y: ROW_HEIGHT });
        break;
      }
      case 'copyUrl':
        clipboard.writeText(wc.getURL());
        break;
      case 'settings':
        this.openSettings(hostOf(wc.getURL()));
        break;
      case 'toggleSite': {
        const host = hostOf(wc.getURL());
        if (!host) break;
        this.settings.setSiteEnabled(host, this.settings.isWhitelisted(host));
        wc.reload();
        break;
      }
      case 'shieldMenu': {
        const s = this.state();
        const items = [
          { label: s.host || '广告拦截', enabled: false },
          {
            label: !s.adblockEnabled ? '广告拦截总开关已关闭' : s.siteWhitelisted ? '此网站在白名单中，不拦截' : !s.adblockReady ? '正在准备拦截规则…' : `本页已拦截 ${s.blocked} 个请求`,
            enabled: false,
          },
          { type: 'separator' },
        ];
        if (s.host && s.adblockEnabled) {
          items.push({ label: s.siteWhitelisted ? '在此网站启用拦截' : '在此网站停用拦截', click: () => this.command('toggleSite') });
        }
        if (!s.adblockEnabled) items.push({ label: '打开广告拦截', click: () => this.settings.set('adblockEnabled', true) });
        items.push({ label: '拦截设置…', click: () => this.command('settings') });
        const { width } = this.win.getContentBounds();
        Menu.buildFromTemplate(items).popup({ window: this.win, x: Math.max(0, width - 260), y: ROW_HEIGHT });
        break;
      }
      case 'focusAddress':
        this.toolbar.webContents.focus();
        this.toolbar.webContents.send('mio-toolbar:focus-address');
        break;
      case 'devtools':
        wc.toggleDevTools();
        break;
      default:
        break;
    }
  }

  /** 标签概览：所有标签 + 新建 / 恢复关闭 / 关闭其他 / 收起 */
  tabsMenu() {
    const items = this.store.tabs.map((t, i) => ({
      label: `${i < 9 ? `${i + 1}. ` : ''}${(t.title || displayHost(t.url) || t.url).slice(0, 60)}`,
      sublabel: displayHost(t.url),
      type: 'radio',
      checked: t.id === this.store.activeId,
      click: () => this.selectTab(t.id),
    }));
    items.push({ type: 'separator' });
    items.push({ label: '新建标签页', accelerator: 'CmdOrCtrl+T', click: () => this.command('newTab') });
    items.push({ label: '重新打开关闭的标签页', accelerator: 'CmdOrCtrl+Shift+T', enabled: this.store.hasClosed(), click: () => this.reopenClosedTab() });
    items.push({ label: '关闭其他标签页', enabled: this.store.size > 1, click: () => this.closeOthers(this.store.activeId) });
    items.push({ label: '收起浏览器（标签保留在后台）', accelerator: 'CmdOrCtrl+Shift+W', click: () => this.hide() });
    const { width } = this.win.getContentBounds();
    Menu.buildFromTemplate(items).popup({ window: this.win, x: Math.max(0, width - 320), y: ROW_HEIGHT });
  }

  tabContextMenu(id) {
    const t = this.store.get(id);
    if (!t) return;
    const view = this.views.get(id);
    Menu.buildFromTemplate([
      { label: '刷新', enabled: !!view, click: () => view && view.webContents.reload() },
      { label: '复制链接', click: () => clipboard.writeText(t.url) },
      { label: '复制标签页', click: () => this.newTab(t.url, { activate: true, containerId: t.containerId }) },
      { type: 'separator' },
      { label: '关闭标签页', click: () => this.closeTab(id) },
      { label: '关闭其他标签页', enabled: this.store.size > 1, click: () => this.closeOthers(id) },
      { label: '关闭右侧标签页', enabled: this.store.indexOf(id) < this.store.size - 1, click: () => this.closeRight(id) },
      { type: 'separator' },
      { label: '重新打开关闭的标签页', enabled: this.store.hasClosed(), click: () => this.reopenClosedTab() },
    ]).popup({ window: this.win });
  }

  closeOthers(id) {
    this.store.select(id);
    for (const t of [...this.store.tabs]) if (t.id !== id) this.closeTab(t.id);
  }

  closeRight(id) {
    const i = this.store.indexOf(id);
    for (const t of this.store.tabs.slice(i + 1)) this.closeTab(t.id);
  }

  state() {
    if (!this.isOpen()) return null;
    const tabs = this.store.tabs.map((t) => {
      const v = this.views.get(t.id);
      const wc = v && !v.webContents.isDestroyed() ? v.webContents : null;
      return {
        id: t.id,
        title: (wc && wc.getTitle()) || t.title || '',
        host: displayHost((wc && wc.getURL()) || t.url),
        loading: !!(wc && wc.isLoading()),
        loaded: !!wc,
        active: t.id === this.store.activeId,
        containerId: t.containerId,
        locked: !!t.locked,
      };
    });
    const base = {
      tabs,
      containers: this.listContainers ? (this.listContainers() || []).map((c) => ({ id: c.id, name: c.name, color: c.color })) : [],
      canReopen: this.store.hasClosed(),
      adblockEnabled: !!this.settings.get('adblockEnabled'),
      adblockReady: !!this.adblock.engine,
      dark: nativeTheme.shouldUseDarkColors,
    };
    const c = this.content;
    if (!c || c.webContents.isDestroyed()) {
      return { ...base, url: '', host: '', displayHost: '', title: '', loading: false, canGoBack: false, canGoForward: false, siteWhitelisted: false, blocked: 0 };
    }
    const wc = c.webContents;
    const url = wc.getURL();
    const host = hostOf(url);
    return {
      ...base,
      url,
      host,
      displayHost: displayHost(url),
      title: wc.getTitle(),
      loading: wc.isLoading(),
      canGoBack: wc.navigationHistory.canGoBack(),
      canGoForward: wc.navigationHistory.canGoForward(),
      siteWhitelisted: !!host && this.settings.isWhitelisted(host),
      blocked: this.adblock.blockedCount(wc.id),
    };
  }

  pushState() {
    if (!this.isOpen() || this.toolbar.webContents.isDestroyed()) return;
    this.toolbar.webContents.send('mio-toolbar:state', this.state());
  }
}

/** 设置窗口（单例） */
class SettingsWindow {
  constructor({ adblock, settings, icon, appVersion }) {
    this.adblock = adblock;
    this.settings = settings;
    this.icon = icon;
    this.appVersion = appVersion;
    this.win = null;
    this.currentHost = null;
    const push = () => {
      if (this.win && !this.win.isDestroyed()) this.win.webContents.send('mio-settings:changed', this.snapshot());
    };
    adblock.onChange(push);
    settings.on('change', push);

    const own = (event) => this.win && !this.win.isDestroyed() && event.sender === this.win.webContents;
    ipcMain.handle('mio-settings:get', (event) => (own(event) ? this.snapshot() : null));
    ipcMain.handle('mio-settings:set', (event, key, value) => {
      if (!own(event)) return null;
      this.settings.set(key, value);
      return this.snapshot();
    });
    ipcMain.handle('mio-settings:whitelist-add', (event, input) => {
      if (!own(event)) return null;
      this.settings.addWhitelist(input);
      return this.snapshot();
    });
    ipcMain.handle('mio-settings:whitelist-remove', (event, host) => {
      if (!own(event)) return null;
      this.settings.removeWhitelist(String(host));
      return this.snapshot();
    });
    ipcMain.handle('mio-settings:site', (event, host, enabled) => {
      if (!own(event)) return null;
      this.settings.setSiteEnabled(String(host), !!enabled);
      return this.snapshot();
    });
    ipcMain.handle('mio-settings:update-now', async (event) => {
      if (!own(event)) return null;
      const r = await this.adblock.maybeUpdate(true);
      return { ...this.snapshot(), message: r.message };
    });
    ipcMain.handle('mio-settings:clear-data', async (event) => {
      if (!own(event)) return null;
      await this.adblock.session.clearStorageData();
      await this.adblock.session.clearCache();
      return this.snapshot();
    });
  }

  snapshot() {
    return {
      settings: this.settings.all(),
      adblock: this.adblock.snapshot(),
      currentHost: this.currentHost,
      appVersion: this.appVersion,
      platform: process.platform,
    };
  }

  open(currentHost) {
    this.currentHost = currentHost || null;
    if (this.win && !this.win.isDestroyed()) {
      this.win.webContents.send('mio-settings:changed', this.snapshot());
      this.win.show();
      this.win.focus();
      return;
    }
    this.win = new BrowserWindow({
      width: 560,
      height: 720,
      minWidth: 420,
      minHeight: 480,
      title: '浏览器设置',
      backgroundColor: bg(),
      icon: this.icon,
      autoHideMenuBar: true,
      show: false,
      webPreferences: {
        preload: path.join(__dirname, 'ui', 'settings-preload.js'),
        partition: UI_PARTITION,
        contextIsolation: true,
        sandbox: true,
        nodeIntegration: false,
      },
    });
    this.win.loadFile(path.join(__dirname, 'ui', 'settings.html'));
    this.win.once('ready-to-show', () => this.win && this.win.show());
    this.win.on('closed', () => {
      this.win = null;
    });
    this.win.webContents.setWindowOpenHandler(({ url }) => {
      if (isHttpUrl(url)) shell.openExternal(url).catch(() => undefined);
      return { action: 'deny' };
    });
  }
}

module.exports = { BrowserManager, SettingsWindow, UI_PARTITION, TOOLBAR_HEIGHT, ROW_HEIGHT };
