'use strict';
// 内置浏览器的翻译（网页双语 / 划词 / YouTube 双语字幕）：
// - 每个 frame 的 preload（translate-preload.js）同步取注入脚本（只给主框架），暴露 window.__mioTranslateNative.request → IPC
// - 主进程代理翻译请求（net.fetch，走系统代理；域名白名单；OpenAI Key 用 safeStorage 加密存、只在这里加到请求头）
// - 工具栏「译」按钮菜单、翻译设置窗口（ui/translate-settings.html）
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { app, ipcMain, Menu, BrowserWindow, net, safeStorage, shell, nativeTheme, session: electronSession } = require('electron');
const core = require('./translate-core');

const PRELOAD = path.join(__dirname, 'translate-preload.js');

class Translate {
  constructor({ session, icon, uiPartition, isBrowserSession }) {
    this.session = session;
    // 容器（containers.js）：每个容器会话都算内置浏览器；新会话由 main.js 的 containers.configure 调 attachSession
    this.isBrowserSession = isBrowserSession || ((ses) => ses === this.session);
    this.icon = icon;
    this.uiPartition = uiPartition;
    this.token = crypto.randomBytes(24).toString('hex');
    const dir = app.getPath('userData');
    this.settings = new core.TranslateSettings(path.join(dir, 'translate.json'));
    this.cache = new core.TranslateCache(path.join(dir, 'translate-cache.json'));
    this.template = null;
    this.templateError = null;
    this.settingsWin = null;
    this.contents = new Set();
    this.loadTemplate();
    this.attachSession(session);
    this.installIpc();
    this.settings.on('change', () => this.pushConfig());
    app.on('before-quit', () => this.cache.flush());
  }

  loadTemplate() {
    for (const f of core.scriptCandidates(__dirname, process.resourcesPath)) {
      try {
        this.template = fs.readFileSync(f, 'utf8');
        this.templatePath = f;
        return;
      } catch {
        // 试下一个
      }
    }
    this.templateError = 'mio-translate.js not found';
    console.error('[translate]', this.templateError);
  }

  config() {
    return core.buildConfig(this.settings.data, this.token, process.platform === 'darwin' ? 'mac' : 'desktop');
  }

  script() {
    if (!this.template) return null;
    return core.scriptWithConfig(this.template, this.config());
  }

  key() {
    const enc = this.settings.get('openaiKeyEnc');
    if (!enc) return '';
    try {
      if (enc.startsWith('plain:')) return Buffer.from(enc.slice(6), 'base64').toString('utf8');
      return safeStorage.decryptString(Buffer.from(enc, 'base64'));
    } catch {
      return '';
    }
  }

  setKey(key) {
    const k = String(key || '').trim();
    if (!k) {
      this.settings.setKeyEnc('');
      return;
    }
    // safeStorage 不可用（Linux 没有钥匙串）时退化为本地编码存储，设置页会提示
    const enc = safeStorage.isEncryptionAvailable() ? safeStorage.encryptString(k).toString('base64') : `plain:${Buffer.from(k, 'utf8').toString('base64')}`;
    this.settings.setKeyEnc(enc);
  }

  /** 给一个浏览器会话注册翻译的 frame preload（重复调用无害） */
  attachSession(ses) {
    if (!this.attached) this.attached = new WeakSet();
    if (this.attached.has(ses)) return;
    this.attached.add(ses);
    ses.registerPreloadScript({ type: 'frame', id: 'mio-translate', filePath: PRELOAD });
  }

  fromBrowser(event) {
    return !!event.sender && this.isBrowserSession(event.sender.session);
  }

  installIpc() {
    ipcMain.on('mio-translate:script', (event, url) => {
      try {
        if (!this.fromBrowser(event) || !/^https?:/i.test(String(url || ''))) {
          event.returnValue = null;
          return;
        }
        if (!this.contents.has(event.sender)) {
          const wc = event.sender;
          this.contents.add(wc);
          wc.once('destroyed', () => this.contents.delete(wc));
        }
        event.returnValue = this.script();
      } catch (e) {
        console.error('[translate] script', e);
        event.returnValue = null;
      }
    });
    ipcMain.handle('mio-translate:request', async (event, json) => {
      if (!this.fromBrowser(event)) return { error: 'forbidden' };
      let msg;
      try {
        msg = JSON.parse(String(json));
      } catch {
        return { error: 'bad message' };
      }
      if (!msg || msg.t !== this.token) return { error: 'bad token' };
      return this.handle(msg);
    });

    const own = (event) => this.settingsWin && !this.settingsWin.isDestroyed() && event.sender === this.settingsWin.webContents;
    ipcMain.handle('mio-translate-settings:get', (event) => (own(event) ? this.snapshot() : null));
    ipcMain.handle('mio-translate-settings:set', (event, key, value) => {
      if (!own(event)) return null;
      this.settings.set(String(key), value);
      return this.snapshot();
    });
    ipcMain.handle('mio-translate-settings:site', (event, host, on) => {
      if (!own(event)) return null;
      this.settings.setAuto(String(host), !!on);
      return this.snapshot();
    });
    ipcMain.handle('mio-translate-settings:key', (event, key) => {
      if (!own(event)) return null;
      this.setKey(key);
      return this.snapshot();
    });
    ipcMain.handle('mio-translate-settings:clear-cache', (event) => {
      if (!own(event)) return null;
      this.cache.clear();
      return this.snapshot();
    });
    // 浏览器设置页的「翻译设置…」按钮（设置页在 UI 会话里）
    ipcMain.handle('mio-translate-settings:open', (event) => {
      if (!event.sender || event.sender.session !== electronSession.fromPartition(this.uiPartition)) return false;
      this.openSettings();
      return true;
    });
    ipcMain.handle('mio-translate-settings:test', async (event) => {
      if (!own(event)) return null;
      return this.testOpenAI();
    });
  }

  async handle(msg) {
    switch (msg.op) {
      case 'fetch': {
        const checked = core.checkRequest(msg.req, this.settings.data);
        if (!checked.ok) return { error: checked.error };
        return core.performFetch(checked, { key: this.key(), fetchImpl: net.fetch.bind(net), userAgent: this.userAgent() });
      }
      case 'cacheGet':
        return { values: this.cache.get(msg.keys) };
      case 'cachePut':
        this.cache.put(msg.entries);
        return { ok: true };
      case 'setPref':
        if (msg.key === 'ytSubs' && typeof msg.value === 'boolean') {
          this.settings.data.ytSubs = msg.value;
          this.settings.save();
          return { ok: true };
        }
        return { error: 'unknown pref' };
      default:
        return { error: 'unknown op' };
    }
  }

  userAgent() {
    return this.session.getUserAgent().replace(/\s*(Electron|mio-desktop|Mio)\/[\d.]+/gi, '');
  }

  async testOpenAI() {
    const s = this.settings.data;
    const url = core.openaiEndpoint(s.openaiBase);
    if (!url || !s.openaiModel) return { ok: false, message: '请先填写 API 地址和模型' };
    if (!this.key()) return { ok: false, message: '请先保存 API Key' };
    const checked = core.checkRequest({
      url,
      method: 'POST',
      auth: 'openai',
      headers: { 'Content-Type': 'application/json' },
      timeoutMs: 30000,
      body: JSON.stringify({ model: s.openaiModel, temperature: 0, messages: [{ role: 'user', content: 'Translate to Simplified Chinese, reply with the translation only: Good morning' }] }),
    }, s);
    if (!checked.ok) return { ok: false, message: checked.error };
    const t0 = Date.now();
    const r = await core.performFetch(checked, { key: this.key(), fetchImpl: net.fetch.bind(net) });
    if (r.error) return { ok: false, message: r.error };
    let text = '';
    try {
      const j = JSON.parse(r.body);
      text = (j.choices && j.choices[0] && j.choices[0].message && j.choices[0].message.content) || (j.error && j.error.message) || '';
    } catch {
      text = String(r.body || '').slice(0, 200);
    }
    return { ok: r.status === 200, message: `HTTP ${r.status} · ${Date.now() - t0} ms · ${String(text).trim().slice(0, 120)}` };
  }

  snapshot() {
    return {
      settings: this.settings.publicView(),
      langs: core.LANGS,
      engines: core.ENGINES,
      cacheSize: this.cache.size,
      encryption: safeStorage.isEncryptionAvailable(),
      scriptLoaded: !!this.template,
    };
  }

  /** 设置变了：已打开的页面立即更新可热切换的项（目标语言 / 引擎在下次加载页面时生效） */
  pushConfig() {
    const c = this.config();
    const partial = JSON.stringify({ selection: c.selection, display: c.display, autoSites: c.autoSites, ytSubs: c.ytSubs });
    for (const wc of this.contents) {
      if (wc.isDestroyed()) {
        this.contents.delete(wc);
        continue;
      }
      wc.executeJavaScript(`window.__mioTranslate && window.__mioTranslate.configure(${partial})`).catch(() => undefined);
    }
    if (this.settingsWin && !this.settingsWin.isDestroyed()) this.settingsWin.webContents.send('mio-translate-settings:changed', this.snapshot());
  }

  async pageState(wc) {
    try {
      return await wc.executeJavaScript('window.__mioTranslate ? window.__mioTranslate.state() : null');
    } catch {
      return null;
    }
  }

  setMode(wc, mode) {
    return wc.executeJavaScript(`window.__mioTranslate ? window.__mioTranslate.setMode(${JSON.stringify(mode)}) : null`).catch(() => null);
  }

  /** 工具栏「译」按钮 */
  async menu(win, wc, y) {
    const st = await this.pageState(wc);
    let host = '';
    try {
      host = new URL(wc.getURL()).hostname;
    } catch {
      host = '';
    }
    const s = this.settings.data;
    const items = [];
    if (!st) {
      items.push({ label: this.template ? '此页面不能翻译' : '翻译脚本未加载', enabled: false });
    } else {
      const mode = st.mode;
      items.push({ label: '双语对照', type: 'radio', checked: mode === 'bilingual', click: () => this.setMode(wc, 'bilingual') });
      items.push({ label: '仅显示译文', type: 'radio', checked: mode === 'translation', click: () => this.setMode(wc, 'translation') });
      items.push({ label: '显示原文（关闭翻译）', type: 'radio', checked: mode === 'off', click: () => this.setMode(wc, 'off') });
      if (st.lastError) items.push({ label: `上次失败：${String(st.lastError).slice(0, 40)}`, enabled: false });
    }
    items.push({ type: 'separator' });
    if (host) {
      const auto = this.settings.isAuto(host);
      items.push({
        label: `总是翻译 ${host.replace(/^www\./, '')}`,
        type: 'checkbox',
        checked: auto,
        click: () => {
          this.settings.setAuto(host, !auto);
          if (!auto && st && st.mode === 'off') this.setMode(wc, s.display);
        },
      });
    }
    const targetName = (core.LANGS.find((l) => l[0] === s.target) || [s.target, s.target])[1];
    items.push({
      label: `译为：${targetName}`,
      submenu: core.LANGS.map(([code, name]) => ({
        label: name,
        type: 'radio',
        checked: s.target === code,
        click: () => {
          this.settings.set('target', code);
          wc.reload();
        },
      })),
    });
    items.push({ label: '划词翻译', type: 'checkbox', checked: !!s.selection, click: () => this.settings.set('selection', !s.selection) });
    items.push({ label: 'YouTube 双语字幕', type: 'checkbox', checked: !!s.youtube, click: () => this.settings.set('youtube', !s.youtube) });
    items.push({ type: 'separator' });
    items.push({ label: '翻译设置…', click: () => this.openSettings() });
    const { width } = win.getContentBounds();
    Menu.buildFromTemplate(items).popup({ window: win, x: Math.max(0, width - 300), y });
  }

  openSettings() {
    if (this.settingsWin && !this.settingsWin.isDestroyed()) {
      this.settingsWin.show();
      this.settingsWin.focus();
      return;
    }
    this.settingsWin = new BrowserWindow({
      width: 560,
      height: 720,
      minWidth: 420,
      minHeight: 480,
      title: '翻译设置',
      backgroundColor: nativeTheme.shouldUseDarkColors ? '#0a0a0a' : '#ffffff',
      icon: this.icon,
      autoHideMenuBar: true,
      show: false,
      webPreferences: {
        preload: path.join(__dirname, 'ui', 'translate-settings-preload.js'),
        partition: this.uiPartition,
        contextIsolation: true,
        sandbox: true,
        nodeIntegration: false,
      },
    });
    this.settingsWin.loadFile(path.join(__dirname, 'ui', 'translate-settings.html'));
    this.settingsWin.once('ready-to-show', () => this.settingsWin && this.settingsWin.show());
    this.settingsWin.on('closed', () => {
      this.settingsWin = null;
    });
    this.settingsWin.webContents.setWindowOpenHandler(({ url }) => {
      if (/^https?:/i.test(url)) shell.openExternal(url).catch(() => undefined);
      return { action: 'deny' };
    });
  }
}

module.exports = { Translate };
