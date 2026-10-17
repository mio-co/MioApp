'use strict';
// 内置浏览器会话（persist:mio-browser）的广告拦截：Ghostery @ghostery/adblocker-electron 引擎
// - 网络：webRequest.onBeforeRequest / onHeadersReceived（CSP 规则）
// - 元素隐藏：Ghostery 的 frame preload（DOM 变化时取 generic / 特定规则）+ insertCSS
// - Scriptlets（##+js()）：Mio 自己的 frame preload 在页面脚本之前同步取到脚本并注入主世界（比 Ghostery 默认的异步注入早，YouTube 的 set-constant 等才有效）
// - 总开关 / 白名单（含子域名）在每个钩子里判断；引擎更新时原子替换，钩子不重新注册
const path = require('node:path');
const { app, ipcMain, utilityProcess, net } = require('electron');
const { ElectronBlocker } = require('@ghostery/adblocker-electron');
const config = require('./config');
const { AdblockStore } = require('./adblock-store');
const { ENGINE_FORMAT } = require('./adblock-engine');
const { hostOf } = require('./util');

const GHOSTERY_PRELOAD = require.resolve('@ghostery/adblocker-electron-preload');
const MIO_FRAME_PRELOAD = path.join(__dirname, 'browser-frame-preload.js');
const CH_INJECT = '@ghostery/adblocker/inject-cosmetic-filters';
const CH_MUTATION = '@ghostery/adblocker/is-mutation-observer-enabled';

/** utilityProcess 里构建引擎（解析 60 万条规则约 3 秒，不卡界面） */
function buildInUtilityProcess(lists, resources) {
  return new Promise((resolve, reject) => {
    const child = utilityProcess.fork(path.join(__dirname, 'adblock-builder.js'), [], { serviceName: 'Mio adblock builder' });
    const timer = setTimeout(() => {
      child.kill();
      reject(new Error('构建超时'));
    }, 180000);
    child.once('message', (msg) => {
      clearTimeout(timer);
      child.kill();
      if (msg && msg.error) reject(new Error(msg.error));
      else resolve({ bytes: new Uint8Array(msg.bytes), stats: msg.stats });
    });
    child.once('exit', (code) => {
      clearTimeout(timer);
      reject(new Error(`builder exited ${code}`));
    });
    child.postMessage({ id: 1, lists, resources });
  });
}

class Adblock {
  constructor({ settings, browserSession }) {
    this.settings = settings;
    this.session = browserSession;
    this.engine = null;
    this.blockedByWebContents = new Map();
    this.listeners = new Set();
    this.store = new AdblockStore({
      bundledDir: app.isPackaged ? path.join(process.resourcesPath, 'adblock') : path.join(__dirname, '..', 'assets', 'adblock'),
      cacheDir: path.join(app.getPath('userData'), 'adblock'),
      fetch: (url, opts) => net.fetch(url, { ...opts, bypassCustomProtocolHandlers: true }),
      build: buildInUtilityProcess,
      engineFormat: ENGINE_FORMAT,
    });
    this.store.on('status', () => this.notify());
    this.readyPromise = null;
  }

  onChange(fn) {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  notify() {
    for (const fn of this.listeners) {
      try {
        fn();
      } catch {
        // ignore
      }
    }
  }

  /** 这个页面（顶层地址）是否拦截 */
  activeFor(topUrl) {
    if (!this.engine || !this.settings.get('adblockEnabled')) return false;
    const host = hostOf(topUrl);
    return !(host && this.settings.isWhitelisted(host));
  }

  blockedCount(webContentsId) {
    return this.blockedByWebContents.get(webContentsId) || 0;
  }

  resetCount(webContentsId) {
    this.blockedByWebContents.set(webContentsId, 0);
  }

  start() {
    const ses = this.session;
    ses.registerPreloadScript({ type: 'frame', id: 'mio-adblock-scriptlets', filePath: MIO_FRAME_PRELOAD });
    ses.registerPreloadScript({ type: 'frame', id: 'ghostery-adblocker', filePath: GHOSTERY_PRELOAD });

    const isBrowserSender = (event) => event && event.sender && event.sender.session === ses;
    const topUrlOf = (event) => {
      try {
        return event.sender.getURL();
      } catch {
        return '';
      }
    };

    // Ghostery preload：DOM 变化后取元素隐藏规则（scripts 由 Mio preload 负责，这里只插 CSS）
    ipcMain.handle(CH_INJECT, (event, url, msg) => {
      if (!isBrowserSender(event) || !this.activeFor(topUrlOf(event))) return;
      const parsed = require('tldts-experimental').parse(url);
      const isFirstRun = msg === undefined;
      const { active, styles } = this.engine.getCosmeticsFilters({
        domain: parsed.domain || '',
        hostname: parsed.hostname || '',
        url,
        classes: msg && msg.classes,
        hrefs: msg && msg.hrefs,
        ids: msg && msg.ids,
        getBaseRules: isFirstRun,
        getInjectionRules: false,
        getExtendedRules: true,
        getRulesFromHostname: isFirstRun,
        getRulesFromDOM: !isFirstRun,
        callerContext: { frameId: event.frameId, processId: event.processId, lifecycle: msg && msg.lifecycle },
      });
      if (active === false || !styles) return;
      event.sender.insertCSS(styles, { cssOrigin: 'user' }).catch(() => undefined);
    });
    ipcMain.handle(CH_MUTATION, () => !!(this.engine && this.engine.config.enableMutationObserver));

    // Mio frame preload：同步取 scriptlets（页面脚本执行前）
    ipcMain.on('mio-adblock:page-scripts', (event, url) => {
      let result = { scripts: '', background: false };
      try {
        if (isBrowserSender(event)) {
          result.background = !!this.settings.get('backgroundPlayback') && event.senderFrame && event.senderFrame.parent === null;
          // YouTube 防沉迷：只给顶层 frame（脚本自己也检查 window.top / 主机名），与拦截开关、白名单无关
          if (event.senderFrame && event.senderFrame.parent === null) result.ytFocus = require('./youtube-focus').scriptFor(url, this.settings);
          const top = event.senderFrame && event.senderFrame.top ? event.senderFrame.top.url : topUrlOf(event);
          if (this.activeFor(top || url)) {
            const parsed = require('tldts-experimental').parse(url);
            const { active, scripts } = this.engine.getCosmeticsFilters({
              domain: parsed.domain || '',
              hostname: parsed.hostname || '',
              url,
              getBaseRules: false,
              getInjectionRules: true,
              getExtendedRules: false,
              getRulesFromHostname: true,
              getRulesFromDOM: false,
            });
            if (active !== false && scripts && scripts.length) result.scripts = scripts.join('\n;\n');
          }
        }
      } catch (e) {
        console.error('[adblock] page-scripts', e);
      }
      event.returnValue = result;
    });

    ses.webRequest.onBeforeRequest({ urls: ['<all_urls>'] }, (details, callback) => {
      if (!this.engine || details.resourceType === 'mainFrame') return callback({});
      const wc = details.webContents;
      const top = wc && !wc.isDestroyed() ? wc.getURL() : details.referrer;
      if (!this.activeFor(top)) return callback({});
      try {
        this.engine.onBeforeRequest(details, (res) => {
          if (res && (res.cancel || res.redirectURL) && details.webContentsId) {
            this.blockedByWebContents.set(details.webContentsId, this.blockedCount(details.webContentsId) + 1);
          }
          callback(res);
        });
      } catch (e) {
        callback({});
      }
    });

    ses.webRequest.onHeadersReceived({ urls: ['<all_urls>'] }, (details, callback) => {
      if (!this.engine || !this.activeFor(details.url)) return callback({});
      try {
        this.engine.onHeadersReceived(details, callback);
      } catch {
        callback({});
      }
    });

    this.readyPromise = this.load().catch((e) => console.error('[adblock] load', e));
    // 启动后稍等再检查更新；之后每小时看一次是否已满 24 小时
    setTimeout(() => this.maybeUpdate(false), 15000);
    setInterval(() => this.maybeUpdate(false), 3600 * 1000).unref?.();
    return this.readyPromise;
  }

  async load({ forceRebuild = false } = {}) {
    this.store.prepare();
    const { bytes, stats, cached } = await this.store.engineBytes({ forceRebuild });
    this.engine = ElectronBlocker.deserialize(bytes);
    console.log(`[adblock] engine ${cached ? 'cached' : 'built'}`, stats);
    this.notify();
  }

  async maybeUpdate(force) {
    try {
      const r = await this.store.checkForUpdates({ force });
      if (r.changed) await this.load();
      this.notify();
      return r;
    } catch (e) {
      this.notify();
      return { changed: false, message: String((e && e.message) || e) };
    }
  }

  snapshot() {
    return { ...this.store.snapshot(), ready: !!this.engine };
  }
}

module.exports = { Adblock };
