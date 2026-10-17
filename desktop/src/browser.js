'use strict';
// 内置浏览器窗口：BaseWindow = 工具栏（本地页面，独立的 UI 会话）+ 网页（persist:mio-browser 会话，带拦截）
// 与 iOS 一致：MioCore 每次打开外链都在这个窗口里打开（已开着就换页面并置前）；target=_blank / window.open 在当前页打开，
// 带窗口尺寸参数的 window.open（OAuth 登录弹窗）作为真正的弹窗；mailto: / tel: 等交给系统
const path = require('node:path');
const { BaseWindow, BrowserWindow, WebContentsView, Menu, clipboard, shell, ipcMain, nativeTheme } = require('electron');
const config = require('./config');
const { hostOf, isHttpUrl, addressToUrl } = require('./util');

const TOOLBAR_HEIGHT = 44;
const UI_PARTITION = 'mio-ui'; // 工具栏 / 设置页：内存会话，不带拦截 preload

function bg() {
  return nativeTheme.shouldUseDarkColors ? '#0a0a0a' : '#ffffff';
}

class BrowserManager {
  constructor({ adblock, settings, browserSession, openSettings, icon, pageTools }) {
    this.adblock = adblock;
    this.pageTools = pageTools || null;
    this.settings = settings;
    this.session = browserSession;
    this.openSettings = openSettings;
    this.icon = icon;
    this.win = null;
    this.toolbar = null;
    this.content = null;
    this.htmlFullscreen = false;
    adblock.onChange(() => this.pushState());
    settings.on('change', () => this.pushState());
    this.installIpc();
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

  /** 打开（或复用）浏览器窗口并加载 url */
  open(url) {
    if (!isHttpUrl(url)) throw new Error('invalid url');
    if (!this.isOpen()) this.create();
    this.content.webContents.loadURL(url).catch(() => undefined);
    if (this.win.isMinimized()) this.win.restore();
    this.win.show();
    this.win.focus();
    this.content.webContents.focus();
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
    const content = new WebContentsView({
      webPreferences: {
        session: this.session,
        contextIsolation: true,
        sandbox: true,
        nodeIntegration: false,
        // 让拦截 preload（scriptlets / 元素隐藏）也在 iframe 里运行；preload 仍在沙箱里，页面拿不到 Node
        nodeIntegrationInSubFrames: true,
        backgroundThrottling: false,
        spellcheck: true,
      },
    });
    toolbar.setBackgroundColor(bg());
    content.setBackgroundColor('#ffffff');
    win.contentView.addChildView(content);
    win.contentView.addChildView(toolbar);
    this.win = win;
    this.toolbar = toolbar;
    this.content = content;

    toolbar.webContents.loadFile(path.join(__dirname, 'ui', 'toolbar.html'));
    this.layout();
    win.on('resize', () => this.layout());
    win.on('closed', () => {
      try {
        if (!content.webContents.isDestroyed()) content.webContents.close();
        if (!toolbar.webContents.isDestroyed()) toolbar.webContents.close();
      } catch {
        // ignore
      }
      this.win = this.toolbar = this.content = null;
    });
    win.once('ready-to-show', () => win.show());
    setTimeout(() => this.isOpen() && !win.isVisible() && win.show(), 300);

    this.wireContent(content.webContents);
    this.wireShortcuts(content.webContents);
    this.wireShortcuts(toolbar.webContents);
  }

  layout() {
    if (!this.isOpen()) return;
    const { width, height } = this.win.getContentBounds();
    const tb = this.htmlFullscreen ? 0 : TOOLBAR_HEIGHT;
    this.toolbar.setVisible(!this.htmlFullscreen);
    this.toolbar.setBounds({ x: 0, y: 0, width, height: TOOLBAR_HEIGHT });
    this.content.setBounds({ x: 0, y: tb, width, height: Math.max(0, height - tb) });
  }

  wireContent(wc) {
    const push = () => this.pushState();
    wc.on('did-start-loading', push);
    wc.on('did-stop-loading', push);
    wc.on('did-navigate', push);
    wc.on('did-navigate-in-page', push);
    wc.on('page-title-updated', (e, title) => {
      if (this.isOpen()) this.win.setTitle(title ? `${title} — Mio 浏览器` : 'Mio 浏览器');
      push();
    });
    wc.on('did-start-navigation', (details) => {
      if (details.isMainFrame && !details.isSameDocument) this.adblock.resetCount(wc.id);
      if (details.isMainFrame && !details.isSameDocument && this.pageTools) this.pageTools.clear(wc);
    });
    // 阅读模式按钮：页面加载完 / SPA 换地址后判断是否像文章
    if (this.pageTools) {
      const check = () => this.pageTools.checkReaderable(wc).then(push, () => undefined);
      wc.on('did-stop-loading', check);
      wc.on('did-navigate-in-page', (e, url, isMainFrame) => isMainFrame && setTimeout(check, 1000));
    }
    // 网页被拦截数：节流刷新
    let timer = null;
    // 计数在 adblock 的 onBeforeRequest 里累加
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
      // 带尺寸参数的弹窗（OAuth 登录等）：真正的弹窗，同一会话，保留 opener
      if (features && /(width|height)=/i.test(features) && disposition === 'new-window') {
        return {
          action: 'allow',
          overrideBrowserWindowOptions: {
            width: 520,
            height: 680,
            autoHideMenuBar: true,
            parent: undefined,
            webPreferences: { session: this.session, contextIsolation: true, sandbox: true, nodeIntegrationInSubFrames: true },
          },
        };
      }
      wc.loadURL(url).catch(() => undefined);
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
        items.push({ label: '打开链接', click: () => wc.loadURL(p.linkURL).catch(() => undefined) });
        items.push({ label: '用系统浏览器打开链接', click: () => shell.openExternal(p.linkURL).catch(() => undefined) });
        items.push({ label: '复制链接地址', click: () => clipboard.writeText(p.linkURL) });
        items.push({ type: 'separator' });
      }
      if (p.mediaType === 'image' && p.srcURL) {
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
          click: () => wc.loadURL(config.SEARCH_URL + encodeURIComponent(p.selectionText)).catch(() => undefined),
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

  wireShortcuts(wc) {
    wc.on('before-input-event', (event, input) => {
      if (input.type !== 'keyDown') return;
      const mod = process.platform === 'darwin' ? input.meta : input.control;
      const key = (input.key || '').toLowerCase();
      let cmd = null;
      if ((mod && key === 'l') || key === 'f6') cmd = 'focusAddress';
      else if ((mod && key === 'r') || key === 'f5') cmd = input.shift ? 'hardReload' : 'reload';
      else if ((input.alt && key === 'arrowleft') || (mod && key === '[')) cmd = 'back';
      else if ((input.alt && key === 'arrowright') || (mod && key === ']')) cmd = 'forward';
      else if (mod && key === 'w') cmd = 'close';
      else if (key === 'f12' || (mod && input.shift && key === 'i')) cmd = 'devtools';
      else if (key === 'f9') cmd = 'reader';
      else if (key === 'escape' && wc === (this.content && this.content.webContents)) cmd = 'stop';
      if (cmd) {
        event.preventDefault();
        this.command(cmd);
      }
    });
  }

  command(cmd, arg) {
    if (!this.isOpen()) return;
    const wc = this.content.webContents;
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
        if (url) wc.loadURL(url).catch(() => undefined);
        wc.focus();
        break;
      }
      case 'openExternal': {
        const url = wc.getURL();
        if (isHttpUrl(url)) shell.openExternal(url).catch(() => undefined);
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
        if (this.webrtc) items.push(...this.webrtc.menuItems(s.host, () => wc.reload()));
        if (this.userscripts) items.push(...this.userscripts.menuItems(wc, s.host));
        items.push({ label: '拦截设置…', click: () => this.command('settings') });
        const { width } = this.win.getContentBounds();
        Menu.buildFromTemplate(items).popup({ window: this.win, x: Math.max(0, width - 260), y: TOOLBAR_HEIGHT });
        break;
      }
      case 'reader':
        if (this.pageTools) this.pageTools.openReader(wc, true);
        break;
      case 'pageMenu': {
        if (!this.pageTools) break;
        const { width } = this.win.getContentBounds();
        Menu.buildFromTemplate(this.pageTools.menuTemplate(wc, { reload: () => wc.reload() })).popup({ window: this.win, x: Math.max(0, width - 360), y: TOOLBAR_HEIGHT });
        break;
      }
      case 'translateMenu':
        if (this.translate) this.translate.menu(this.win, wc, TOOLBAR_HEIGHT);
        break;
      case 'focusAddress':
        this.toolbar.webContents.focus();
        this.toolbar.webContents.send('mio-toolbar:focus-address');
        break;
      case 'devtools':
        wc.toggleDevTools();
        break;
      case 'close':
        this.win.close();
        break;
      default:
        break;
    }
  }

  state() {
    if (!this.isOpen()) return null;
    const wc = this.content.webContents;
    const url = wc.getURL();
    const host = hostOf(url);
    return {
      url,
      host,
      title: wc.getTitle(),
      loading: wc.isLoading(),
      canGoBack: wc.navigationHistory.canGoBack(),
      canGoForward: wc.navigationHistory.canGoForward(),
      adblockEnabled: !!this.settings.get('adblockEnabled'),
      adblockReady: !!this.adblock.engine,
      siteWhitelisted: !!host && this.settings.isWhitelisted(host),
      blocked: this.adblock.blockedCount(wc.id),
      dark: nativeTheme.shouldUseDarkColors,
      readerable: !!this.pageTools && this.pageTools.isReaderable(wc),
      pageTools: !!this.pageTools,
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

module.exports = { BrowserManager, SettingsWindow, UI_PARTITION };
