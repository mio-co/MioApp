'use strict';
// Mio 桌面壳（Electron）：主窗口加载 MioCore（/mio/nav），站外链接交给内置浏览器（独立会话 + Ghostery 拦截）
const path = require('node:path');
const { app, BrowserWindow, Menu, session, shell, ipcMain, nativeTheme, nativeImage } = require('electron');
const config = require('./config');
const { hostOf, isHttpUrl, hostInList } = require('./util');
const { SettingsStore } = require('./settings-store');
const { Adblock } = require('./adblock');
const { BrowserManager, SettingsWindow, UI_PARTITION } = require('./browser');
const { Updater } = require('./updater');
const { PageTools } = require('./page-tools');
const pageToolsStore = require('./page-tools-store');
const { ContainerStore } = require('./containers-store');
const { ContainerSessions } = require('./containers');
const { COLOR_HEX } = require('./containers-core');
const { Translate } = require('./translate');

app.setAppUserModelId('xyz.mio.desktop');

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  let mainWindow = null;
  let browser = null;
  let settingsWindow = null;
  let settings = null;
  let adblock = null;
  let containers = null;

  const iconPath = path.join(__dirname, '..', 'assets', 'icon.png');
  const icon = nativeImage.createFromPath(iconPath);
  const bg = () => (nativeTheme.shouldUseDarkColors ? '#0a0a0a' : '#ffffff');

  const isSiteUrl = (url) => hostOf(url) === config.SITE_HOST;
  const mainMayNavigate = (url) => {
    const h = hostOf(url);
    return !!h && hostInList(h, config.MAIN_ALLOWED_HOSTS);
  };

  function openExternalLink(url, mode = 'auto') {
    if (!isHttpUrl(url)) return { opened: 'none' };
    const system = mode === 'safari' || mode === 'system' || (mode === 'auto' && settings.get('preferSystemBrowser'));
    if (system) {
      shell.openExternal(url).catch(() => undefined);
      return { opened: 'system' };
    }
    browser.open(url);
    return { opened: 'inapp' };
  }

  function createMainWindow() {
    const win = new BrowserWindow({
      width: 1280,
      height: 860,
      minWidth: 400,
      minHeight: 400,
      title: 'Mio',
      backgroundColor: bg(),
      icon,
      autoHideMenuBar: true,
      show: false,
      webPreferences: {
        preload: path.join(__dirname, 'preload.js'),
        partition: config.MAIN_PARTITION,
        contextIsolation: true,
        sandbox: true,
        nodeIntegration: false,
        spellcheck: true,
      },
    });
    mainWindow = win;
    win.once('ready-to-show', () => win.show());
    setTimeout(() => !win.isDestroyed() && !win.isVisible() && win.show(), 4000);
    win.on('closed', () => {
      mainWindow = null;
    });

    const wc = win.webContents;
    // 站内 / 登录相关域名在主窗口跳转；其余交给内置浏览器
    wc.on('will-navigate', (event) => {
      if (event.url.startsWith('file:')) return; // 离线页
      if (mainMayNavigate(event.url)) return;
      event.preventDefault();
      if (isHttpUrl(event.url)) openExternalLink(event.url);
      else if (/^(mailto|tel):/i.test(event.url)) shell.openExternal(event.url).catch(() => undefined);
    });
    wc.setWindowOpenHandler(({ url }) => {
      if (isSiteUrl(url)) {
        // 站内新窗口（图片预览、文件下载页等）：同一会话的普通窗口
        return {
          action: 'allow',
          overrideBrowserWindowOptions: {
            autoHideMenuBar: true,
            icon,
            backgroundColor: bg(),
            webPreferences: { partition: config.MAIN_PARTITION, contextIsolation: true, sandbox: true },
          },
        };
      }
      if (mainMayNavigate(url)) {
        // 登录弹窗（Google / GitHub / Access）
        return { action: 'allow', overrideBrowserWindowOptions: { width: 520, height: 700, autoHideMenuBar: true, icon, webPreferences: { partition: config.MAIN_PARTITION, contextIsolation: true, sandbox: true } } };
      }
      if (isHttpUrl(url)) openExternalLink(url);
      else if (/^(mailto|tel):/i.test(url)) shell.openExternal(url).catch(() => undefined);
      return { action: 'deny' };
    });
    wc.on('did-fail-load', (event, code, desc, url, isMainFrame) => {
      if (!isMainFrame || code === -3 /* ABORTED */) return;
      wc.loadFile(path.join(__dirname, 'ui', 'offline.html'), { query: { code: String(code), desc: String(desc || ''), url: String(url || config.START_URL) } });
    });
    wc.on('before-input-event', (event, input) => {
      if (input.type !== 'keyDown') return;
      const mod = process.platform === 'darwin' ? input.meta : input.control;
      const key = (input.key || '').toLowerCase();
      if ((mod && key === 'r') || key === 'f5') {
        event.preventDefault();
        if (wc.getURL().startsWith('file:')) wc.loadURL(config.START_URL);
        else if (input.shift) wc.reloadIgnoringCache();
        else wc.reload();
      } else if ((input.alt && key === 'arrowleft') || (mod && key === '[')) {
        event.preventDefault();
        if (wc.navigationHistory.canGoBack()) wc.navigationHistory.goBack();
      } else if ((input.alt && key === 'arrowright') || (mod && key === ']')) {
        event.preventDefault();
        if (wc.navigationHistory.canGoForward()) wc.navigationHistory.goForward();
      } else if (key === 'f12' || (mod && input.shift && key === 'i')) {
        event.preventDefault();
        wc.toggleDevTools();
      }
    });
    wc.loadURL(config.START_URL);
  }

  function installMainIpc() {
    // 只接受主窗口里 MioCore 站点（或离线页）的调用
    const fromMain = (event) => {
      if (!mainWindow || mainWindow.isDestroyed() || event.sender !== mainWindow.webContents) return false;
      const url = (event.senderFrame && event.senderFrame.url) || '';
      return isSiteUrl(url);
    };
    ipcMain.handle('mio-desktop:browser-open', (event, options) => {
      if (!fromMain(event)) throw new Error('forbidden');
      const url = String((options && options.url) || '').trim();
      if (!isHttpUrl(url)) throw new Error('invalid url');
      const mode = String((options && options.mode) || 'auto');
      return openExternalLink(url, mode === 'inapp' || mode === 'safari' || mode === 'system' ? mode : 'auto');
    });
    ipcMain.handle('mio-desktop:browser-settings', (event) => {
      if (!fromMain(event)) throw new Error('forbidden');
      settingsWindow.open(null);
      return true;
    });
    ipcMain.handle('mio-desktop:browser-info', (event) => {
      if (!fromMain(event)) throw new Error('forbidden');
      const snap = adblock.snapshot();
      return {
        version: app.getVersion(),
        platform: process.platform,
        adblock: !!settings.get('adblockEnabled'),
        preferSafari: !!settings.get('preferSystemBrowser'),
        preferSystemBrowser: !!settings.get('preferSystemBrowser'),
        ruleLists: snap.lists.filter((l) => l.rules > 0).length,
        rulesCheckedAt: snap.lastCheck ? new Date(snap.lastCheck).toISOString() : null,
        scriptlets: snap.resources ? snap.resources.scriptlets : null,
      };
    });
  }

  function buildMenu() {
    const isMac = process.platform === 'darwin';
    const template = [
      ...(isMac ? [{ role: 'appMenu' }] : []),
      {
        label: '文件',
        submenu: [
          { label: '浏览器设置…', accelerator: 'CmdOrCtrl+,', click: () => settingsWindow.open(null) },
          { type: 'separator' },
          isMac ? { role: 'close', label: '关闭窗口' } : { role: 'quit', label: '退出' },
        ],
      },
      { role: 'editMenu', label: '编辑' },
      {
        label: '视图',
        submenu: [
          { role: 'resetZoom', label: '实际大小' },
          { role: 'zoomIn', label: '放大' },
          { role: 'zoomOut', label: '缩小' },
          { type: 'separator' },
          { role: 'togglefullscreen', label: '全屏' },
        ],
      },
      { role: 'windowMenu', label: '窗口' },
    ];
    Menu.setApplicationMenu(Menu.buildFromTemplate(template));
  }

  app.on('second-instance', () => {
    if (!mainWindow) return createMainWindow();
    if (mainWindow.isMinimized()) mainWindow.restore();
    mainWindow.show();
    mainWindow.focus();
  });

  app.whenReady().then(() => {
    settings = new SettingsStore(path.join(app.getPath('userData'), 'settings.json'));
    // 容器（登录状态隔离）：默认容器 = 原来的 persist:mio-browser 会话；其他容器各自一个 persist:mio-c-<id> 会话（desktop/src/containers.js）
    containers = new ContainerSessions({
      store: new ContainerStore(path.join(app.getPath('userData'), 'containers.json')),
      defaultPartition: config.BROWSER_PARTITION,
      userDataDir: app.getPath('userData'),
    });
    containers.purgePending();
    const browserSession = containers.defaultSession();
    adblock = new Adblock({ settings, browserSession });
    settingsWindow = new SettingsWindow({ adblock, settings, icon, appVersion: app.getVersion() });
    // 阅读模式 / 强制深色 / 存到 Mio（脚本与 iOS / Android 共用 www/mio-browser）
    const pageTools = new PageTools({
      store: new pageToolsStore.PageToolsStore(path.join(app.getPath('userData'), 'page-tools.json')),
      scripts: pageToolsStore.loadScripts(pageToolsStore.scriptDirCandidates(app.isPackaged ? process.resourcesPath : null, __dirname)),
      browserSession,
      isBrowserSession: (ses) => containers.isBrowserSession(ses),
      getMainWebContents: () => (mainWindow && !mainWindow.isDestroyed() ? mainWindow.webContents : null),
      icon,
    });
    browser = new BrowserManager({
      adblock,
      settings,
      browserSession,
      containers,
      // 多标签接入点（feat/tabs-top-toolbar）：标签的容器会话、容器列表（颜色为 #hex）
      sessionForContainer: (id) => containers.sessionFor(id),
      listContainers: () => containers.store.list().map((c) => ({ id: c.id, name: c.name, color: COLOR_HEX[c.color] || COLOR_HEX.gray })),
      icon,
      pageTools,
      openSettings: (host) => settingsWindow.open(host),
    });
    // 翻译（网页双语 / 划词 / YouTube 双语字幕）：工具栏「译」按钮
    browser.translate = new Translate({ session: browserSession, icon, uiPartition: UI_PARTITION, isBrowserSession: (ses) => containers.isBrowserSession(ses) });

    // 主会话、浏览器会话都不需要的权限一律拒绝；常见的（通知、剪贴板、全屏、媒体自动播放）放行
    const allow = new Set(['clipboard-read', 'clipboard-sanitized-write', 'fullscreen', 'notifications', 'pointerLock', 'media', 'window-management']);
    session.fromPartition(config.MAIN_PARTITION).setPermissionRequestHandler((wc, permission, callback) => callback(allow.has(permission)));
    // 每个浏览器会话（默认容器 + 每个容器）都走同一个配置：权限、广告拦截（webRequest + frame preload）。
    // 新的会话级功能请加在这里，容器会话会自动得到同样的配置
    containers.configure(function configureBrowserSession(ses) {
      ses.setPermissionRequestHandler((wc, permission, callback) => callback(allow.has(permission)));
      adblock.attachSession(ses);
      browser.translate.attachSession(ses);
    });
    containers.installIpc((event) => !!(settingsWindow.win && !settingsWindow.win.isDestroyed() && event.sender === settingsWindow.win.webContents));

    installMainIpc();
    buildMenu();
    createMainWindow();
    adblock.start();

    if (process.env.MIO_SMOKE_OUT) {
      require('./smoke').runSmoke({ out: process.env.MIO_SMOKE_OUT, adblock, browser, containers, getMainWindow: () => mainWindow });
    } else {
      // 软件内更新（GitHub Releases）：冒烟测试时不启动
      new Updater({ getWindow: () => mainWindow, icon }).start();
    }

    app.on('activate', () => {
      if (!mainWindow) createMainWindow();
    });
  });

  app.on('window-all-closed', () => {
    if (process.platform !== 'darwin') app.quit();
  });

  // 任何窗口都不允许加载 file: 以外的本地协议、也不允许 webview
  app.on('web-contents-created', (e, contents) => {
    contents.on('will-attach-webview', (ev) => ev.preventDefault());
  });
}
