'use strict';
// 内置浏览器：阅读模式、强制深色、存到 Mio（Windows / macOS Electron）。页面脚本与 iOS / Android 共用 www/mio-browser/*.js。
//  - 强制深色：browser-frame-preload 在 document-start 同步取 dark.js（只给主框架），按站点 + 全局开关；智能反色，
//    网站本身已经是深色时撤掉反色并记住（下次不先反色）。Electron 的 prefers-color-scheme 跟随系统主题（不按站点切换）。
//  - 阅读模式：在页面的隔离世界里提取正文，单独的窗口显示（菜单 / 右键：背景、字体、字号、存到 Mio、返回原页）。
//  - 存到 Mio：在主窗口（已登录 MioCore，同源会话 Cookie / Cloudflare Access）的隔离世界里调 MioCore API。
const { ipcMain, Menu, BrowserWindow, Notification, dialog, shell } = require('electron');
const config = require('./config');
const { hostOf, isHttpUrl } = require('./util');
const store_ = require('./page-tools-store');

const WORLD_READER = 1701;
const WORLD_SAVE = 1702;

const SAVE_KINDS = [
  { kind: 'bookmark', label: '存为导航书签' },
  { kind: 'note', label: '新建笔记（标题 + 链接 + 选中文字 / 正文）' },
  { kind: 'clip', label: '在另一台设备继续（推到云剪贴板）' },
];

class PageTools {
  constructor({ store, scripts, browserSession, getMainWebContents, icon }) {
    this.store = store;
    this.scripts = scripts;
    this.session = browserSession;
    this.getMainWebContents = getMainWebContents;
    this.icon = icon;
    this.readerable = new Map();
    this.readers = new Set();
    this.installIpc();
  }

  installIpc() {
    const fromBrowser = (event) => event && event.sender && event.sender.session === this.session;
    ipcMain.on('mio-pagetools:dark-script', (event, url) => {
      let code = '';
      try {
        const top = event.senderFrame && event.senderFrame.parent === null;
        if (fromBrowser(event) && top && isHttpUrl(url) && this.scripts) code = store_.darkInjection(this.store, this.scripts.dark);
      } catch (e) {
        console.error('[page-tools] dark-script', e);
      }
      event.returnValue = code;
    });
    ipcMain.on('mio-pagetools:dark-report', (event, data) => {
      if (!fromBrowser(event) || !data || typeof data.host !== 'string') return;
      this.store.reportDark(data.host, data.verdict === 'native' ? 'native' : 'invert');
    });
  }

  isReaderable(wc) {
    return !!(wc && this.readerable.get(wc.id));
  }

  async checkReaderable(wc) {
    if (!wc || wc.isDestroyed() || !this.scripts) return false;
    let ok = false;
    try {
      if (isHttpUrl(wc.getURL())) {
        ok = (await wc.executeJavaScriptInIsolatedWorld(WORLD_READER, [{ code: store_.readerableCode(this.scripts.reader) }])) === true;
      }
    } catch {
      ok = false;
    }
    if (!wc.isDestroyed()) this.readerable.set(wc.id, ok);
    return ok;
  }

  clear(wc) {
    if (wc) this.readerable.delete(wc.id);
  }

  async extract(wc, force) {
    if (!wc || wc.isDestroyed() || !this.scripts) return null;
    try {
      return await wc.executeJavaScriptInIsolatedWorld(WORLD_READER, [{ code: store_.extractCode(this.scripts.reader, this.store.readerPrefs, force) }]);
    } catch {
      return null;
    }
  }

  notify(text, ok = true) {
    try {
      if (Notification.isSupported()) {
        new Notification({ title: ok ? '存到 Mio' : '存到 Mio 失败', body: text, icon: this.icon, silent: ok }).show();
        return;
      }
    } catch {
      // 通知不可用时用对话框
    }
    dialog.showMessageBox({ type: ok ? 'info' : 'warning', message: text, buttons: ['好'] }).catch(() => undefined);
  }

  /** 存到 MioCore：在主窗口的隔离世界里执行（同源 fetch 带会话 Cookie） */
  async save(kind, wc, extracted) {
    const url = extracted ? extracted.url : wc && wc.getURL();
    if (!isHttpUrl(url)) return this.notify('只能保存网页', false);
    const main = this.getMainWebContents();
    if (!main || main.isDestroyed() || hostOf(main.getURL()) !== config.SITE_HOST) {
      return this.notify('主窗口没有打开 MioCore，请先在主窗口登录', false);
    }
    let payload = { url, title: extracted ? extracted.title : wc.getTitle() };
    if (kind !== 'clip') {
      const out = extracted || (await this.extract(wc, kind === 'note'));
      if (out) {
        if (kind === 'note' && out.selection) payload.selection = out.selection;
        if (out.article) {
          const a = out.article;
          payload.article = kind === 'note'
            ? { title: a.title, byline: a.byline, siteName: a.siteName, excerpt: a.excerpt, markdown: a.markdown }
            : { excerpt: a.excerpt };
        }
      }
    }
    let result = null;
    try {
      const opts = { origin: config.SITE_ORIGIN, category: this.store.saveCategory };
      result = await main.executeJavaScriptInIsolatedWorld(WORLD_SAVE, [{ code: store_.saveCode(this.scripts.save, kind, payload, opts) }]);
    } catch (e) {
      result = { ok: false, message: `保存失败：${e && e.message ? e.message : e}` };
    }
    const msg = store_.saveMessage(result);
    this.notify(msg.text, msg.ok);
    return result;
  }

  /** 工具栏「存到 Mio」菜单 */
  menuTemplate(wc, { reload }) {
    const url = wc ? wc.getURL() : '';
    const host = hostOf(url);
    const items = SAVE_KINDS.map(({ kind, label }) => ({ label, enabled: isHttpUrl(url), click: () => this.save(kind, wc) }));
    items.push({ type: 'separator' });
    items.push({ label: '阅读模式\tF9', enabled: isHttpUrl(url), click: () => this.openReader(wc, true) });
    if (host) {
      items.push({
        label: `此网站深色（${store_.normalizeHost(host)}）`,
        type: 'checkbox',
        checked: this.store.isDarkEnabled(host),
        click: () => {
          this.store.setSiteDark(host, !this.store.isDarkEnabled(host));
          reload();
        },
      });
    }
    items.push({
      label: '所有网站深色',
      type: 'checkbox',
      checked: !!this.store.data.darkGlobal,
      click: () => {
        this.store.setDarkGlobal(!this.store.data.darkGlobal);
        reload();
      },
    });
    items.push({ type: 'separator' });
    items.push({ label: `书签分类：${this.store.saveCategory}`, enabled: false });
    return items;
  }

  // ---------------------------------------------------------------- 阅读视图

  async openReader(wc, force) {
    const out = await this.extract(wc, force);
    if (!out || !out.page) return this.notify('这个页面没有可提取的正文', false);
    const win = new BrowserWindow({
      width: 900,
      height: 900,
      title: out.article && out.article.title ? `${out.article.title} — 阅读模式` : '阅读模式',
      icon: this.icon,
      autoHideMenuBar: false,
      backgroundColor: this.background(),
      webPreferences: { session: this.session, contextIsolation: true, sandbox: true, nodeIntegration: false, spellcheck: false },
    });
    this.readers.add(win);
    win.on('closed', () => this.readers.delete(win));
    const rwc = win.webContents;
    const rebuildMenu = () => {
      if (win.isDestroyed()) return;
      const m = Menu.buildFromTemplate(this.readerMenu(win, wc, out));
      win.setMenu(m);
    };
    rwc.on('will-navigate', (e) => {
      e.preventDefault();
      if (isHttpUrl(e.url) && wc && !wc.isDestroyed()) {
        wc.loadURL(e.url).catch(() => undefined);
        win.close();
      } else if (/^mailto:/i.test(e.url)) shell.openExternal(e.url).catch(() => undefined);
    });
    rwc.setWindowOpenHandler(({ url }) => {
      if (isHttpUrl(url) && wc && !wc.isDestroyed()) wc.loadURL(url).catch(() => undefined);
      return { action: 'deny' };
    });
    rwc.on('context-menu', () => Menu.buildFromTemplate(this.readerMenu(win, wc, out).flatMap((m) => [...m.submenu, { type: 'separator' }]).slice(0, -1)).popup({ window: win }));
    rwc.on('before-input-event', (event, input) => {
      if (input.type === 'keyDown' && (input.key === 'Escape' || input.key === 'F9')) {
        event.preventDefault();
        win.close();
      }
    });
    win.mioRebuildMenu = rebuildMenu;
    rebuildMenu();
    rwc.loadURL(`data:text/html;charset=utf-8,${encodeURIComponent(out.page)}`).catch(() => undefined);
    return win;
  }

  background() {
    const t = this.store.readerPrefs.theme;
    return t === 'dark' ? '#121212' : t === 'sepia' ? '#f6efe1' : '#ffffff';
  }

  applyPrefs(win) {
    const p = this.store.readerPrefs;
    const js = `(function(d){d.setAttribute('data-theme',${JSON.stringify(p.theme)});d.setAttribute('data-font',${JSON.stringify(p.font)});d.style.setProperty('--fs',${JSON.stringify(`${p.fontSize}px`)});return true;})(document.documentElement)`;
    for (const w of this.readers) {
      if (w.isDestroyed()) continue;
      w.setBackgroundColor(this.background());
      w.webContents.executeJavaScript(js).catch(() => undefined);
      if (w.mioRebuildMenu) w.mioRebuildMenu();
    }
    void win;
  }

  readerMenu(win, wc, out) {
    const p = this.store.readerPrefs;
    const set = (change) => {
      this.store.setReaderPrefs(change);
      this.applyPrefs(win);
    };
    return [
      {
        label: '阅读设置',
        submenu: [
          { label: '白', type: 'radio', checked: p.theme === 'light', click: () => set({ theme: 'light' }) },
          { label: '米', type: 'radio', checked: p.theme === 'sepia', click: () => set({ theme: 'sepia' }) },
          { label: '深', type: 'radio', checked: p.theme === 'dark', click: () => set({ theme: 'dark' }) },
          { type: 'separator' },
          { label: '无衬线', type: 'radio', checked: p.font === 'sans', click: () => set({ font: 'sans' }) },
          { label: '衬线', type: 'radio', checked: p.font === 'serif', click: () => set({ font: 'serif' }) },
          { label: '等宽', type: 'radio', checked: p.font === 'mono', click: () => set({ font: 'mono' }) },
          { type: 'separator' },
          { label: `字号变大（${p.fontSize}）`, accelerator: 'CmdOrCtrl+=', enabled: p.fontSize < 32, click: () => set({ fontSize: this.store.readerPrefs.fontSize + 1 }) },
          { label: '字号变小', accelerator: 'CmdOrCtrl+-', enabled: p.fontSize > 12, click: () => set({ fontSize: this.store.readerPrefs.fontSize - 1 }) },
        ],
      },
      {
        label: '存到 Mio',
        submenu: SAVE_KINDS.map(({ kind, label }) => ({ label, click: () => this.save(kind, wc, out) })),
      },
      { label: '返回原页', submenu: [{ label: '返回原页（Esc）', click: () => win.close() }] },
    ];
  }
}

module.exports = { PageTools };
