'use strict';
// 软件内更新（Electron 主进程）
// - 启动 8 秒后、以及窗口重新获得焦点时：开关打开且距上次检查 ≥ 24 小时 → 查 GitHub Releases latest（公开仓库，无需 token）
// - Windows 安装版（NSIS）：electron-updater 从同一个 Release 的 latest.yml + blockmap 下载（sha512 校验，支持差分），
//   下载完提示「立即重启并安装 / 退出时安装」
// - Windows 便携版 / 其它情况：只提示，并打开 Release 下载页
// 状态存 userData/updater.json（与 settings.json 分开）；设置窗口通过 mio-update:* IPC 读写
const fs = require('node:fs');
const path = require('node:path');
const { app, BrowserWindow, dialog, ipcMain, net, shell } = require('electron');
const core = require('./update-core');

const DEFAULTS = { autoCheck: true, lastCheck: 0, lastAttempt: 0, skipVersion: '' };

class UpdateStore {
  constructor(file) {
    this.file = file;
    this.data = { ...DEFAULTS };
    try {
      const j = JSON.parse(fs.readFileSync(file, 'utf8'));
      for (const k of Object.keys(DEFAULTS)) if (k in j && typeof j[k] === typeof DEFAULTS[k]) this.data[k] = j[k];
    } catch {
      // 首次启动：默认值
    }
  }

  set(patch) {
    Object.assign(this.data, patch);
    try {
      fs.mkdirSync(path.dirname(this.file), { recursive: true });
      fs.writeFileSync(`${this.file}.tmp`, JSON.stringify(this.data, null, 2));
      fs.renameSync(`${this.file}.tmp`, this.file);
    } catch (e) {
      console.warn('[mio-update] save failed', e && e.message);
    }
  }
}

class Updater {
  constructor({ getWindow, icon }) {
    this.getWindow = getWindow;
    this.icon = icon;
    this.store = new UpdateStore(path.join(app.getPath('userData'), 'updater.json'));
    this.mode = core.updateMode({ packaged: app.isPackaged });
    this.status = '';
    this.busy = false;
    this.latest = null;
    this.downloaded = false;
    this.autoUpdater = null;
  }

  start() {
    this.installIpc();
    // 开发运行（npm start）不自动检查；手动「立即检查」仍可用
    if (!app.isPackaged) return;
    setTimeout(() => this.maybeAutoCheck(), 8000);
    app.on('browser-window-focus', () => this.maybeAutoCheck());
  }

  snapshot() {
    return {
      autoCheck: !!this.store.data.autoCheck,
      lastCheck: this.store.data.lastCheck || null,
      version: app.getVersion(),
      latest: this.latest ? this.latest.version : null,
      mode: this.mode,
      status: this.status,
      busy: this.busy,
    };
  }

  setStatus(s) {
    this.status = s;
    const snap = this.snapshot();
    for (const w of BrowserWindow.getAllWindows()) {
      if (!w.isDestroyed() && /\/ui\/settings\.html$/.test(w.webContents.getURL())) w.webContents.send('mio-update:changed', snap);
    }
  }

  installIpc() {
    // 只接受本地设置页（file://…/ui/settings.html）的调用
    const own = (event) => {
      const url = (event.senderFrame && event.senderFrame.url) || '';
      return url.startsWith('file:') && /\/ui\/settings\.html$/.test(url.split(/[?#]/)[0]);
    };
    ipcMain.handle('mio-update:get', (event) => (own(event) ? this.snapshot() : null));
    ipcMain.handle('mio-update:set-auto', (event, on) => {
      if (!own(event)) return null;
      this.store.set({ autoCheck: !!on });
      return this.snapshot();
    });
    ipcMain.handle('mio-update:check', async (event) => {
      if (!own(event)) return null;
      await this.check({ manual: true });
      return this.snapshot();
    });
  }

  maybeAutoCheck() {
    if (this.busy || this.downloaded) return;
    if (!core.shouldAutoCheck(this.store.data)) return;
    this.check({ manual: false }).catch(() => undefined);
  }

  async fetchLatest() {
    const res = await net.fetch(core.LATEST_API, {
      headers: { Accept: 'application/vnd.github+json', 'User-Agent': `Mio-Desktop/${app.getVersion()}` },
      cache: 'no-store',
    });
    if (res.status === 404) return null; // 还没有正式 Release
    if (!res.ok) throw new Error(`GitHub API HTTP ${res.status}`);
    return core.parseRelease(await res.json());
  }

  async check({ manual }) {
    if (this.busy) return;
    if (this.downloaded) return this.promptRestart();
    this.busy = true;
    this.store.set({ lastAttempt: Date.now() });
    this.setStatus('正在检查…');
    let release;
    try {
      release = await this.fetchLatest();
      this.store.set({ lastCheck: Date.now() });
    } catch (e) {
      this.busy = false;
      this.setStatus(`检查失败：${e.message || e}`);
      if (manual) this.message('检查更新失败', String(e.message || e), 'warning');
      return;
    }
    this.busy = false;
    this.latest = release;
    const current = app.getVersion();
    if (!release || !core.isNewer(release.version, current)) {
      this.setStatus(`已是最新版本（${current}）`);
      if (manual) this.message('已是最新版本', `当前版本 ${current}${release ? `，最新发布 ${release.version}` : ''}。`);
      return;
    }
    if (!manual && this.store.data.skipVersion === release.version) {
      this.setStatus(`发现 ${release.version}（已跳过）`);
      return;
    }
    this.setStatus(`发现新版本 ${release.version}`);
    await this.promptUpdate(release, manual);
  }

  async promptUpdate(release, manual) {
    const nsis = this.mode === 'nsis';
    const notes = core.plainNotes(release.notes) || '（无更新说明）';
    const buttons = [nsis ? '下载并安装' : '打开下载页', '稍后'];
    if (!manual) buttons.push('跳过此版本');
    const detail = nsis
      ? notes
      : `${notes}\n\n${core.isPortable() ? '便携版不能自动更新，请下载新的 Mio-Portable 或改用安装版。' : '请从下载页获取新版本。'}`;
    const { response } = await this.showBox({
      type: 'info',
      title: '软件更新',
      message: `发现新版本 Mio ${release.version}（当前 ${app.getVersion()}）`,
      detail,
      buttons,
      defaultId: 0,
      cancelId: 1,
    });
    if (response === 2) {
      this.store.set({ skipVersion: release.version });
      this.setStatus(`已跳过 ${release.version}`);
      return;
    }
    if (response !== 0) return;
    if (!nsis) {
      shell.openExternal(release.url).catch(() => undefined);
      return;
    }
    await this.downloadNsis(release);
  }

  loadAutoUpdater() {
    if (this.autoUpdater) return this.autoUpdater;
    const { autoUpdater } = require('electron-updater');
    autoUpdater.autoDownload = false;
    autoUpdater.autoInstallOnAppQuit = true;
    autoUpdater.allowPrerelease = false;
    autoUpdater.allowDowngrade = false;
    autoUpdater.logger = {
      info: (m) => console.log('[mio-update]', m),
      warn: (m) => console.warn('[mio-update]', m),
      error: (m) => console.error('[mio-update]', m),
      debug: () => undefined,
    };
    autoUpdater.on('download-progress', (p) => {
      const win = this.getWindow();
      if (win && !win.isDestroyed()) win.setProgressBar(Math.max(0, Math.min(1, (p.percent || 0) / 100)));
      this.setStatus(`正在下载 ${Math.round(p.percent || 0)}%`);
    });
    this.autoUpdater = autoUpdater;
    return autoUpdater;
  }

  async downloadNsis(release) {
    const au = this.loadAutoUpdater();
    this.busy = true;
    this.setStatus('正在准备下载…');
    try {
      // electron-updater 自己读 Release 里的 latest.yml（版本、文件名、sha512、blockmap）
      const r = await au.checkForUpdates();
      const info = r && r.updateInfo;
      if (!info || r.isUpdateAvailable === false || !core.isNewer(info.version, app.getVersion())) {
        throw new Error(`Release ${release.version} 里没有可用的 Windows 安装包更新信息（latest.yml）`);
      }
      await au.downloadUpdate();
      this.downloaded = true;
      this.busy = false;
      this.setStatus(`${info.version} 已下载，重启后安装`);
      const win = this.getWindow();
      if (win && !win.isDestroyed()) win.setProgressBar(-1);
      await this.promptRestart();
    } catch (e) {
      this.busy = false;
      const win = this.getWindow();
      if (win && !win.isDestroyed()) win.setProgressBar(-1);
      this.setStatus(`下载失败：${e.message || e}`);
      const { response } = await this.showBox({
        type: 'warning',
        title: '软件更新',
        message: '自动更新失败',
        detail: `${e.message || e}\n\n可以从下载页手动安装新版本。`,
        buttons: ['打开下载页', '关闭'],
        defaultId: 0,
        cancelId: 1,
      });
      if (response === 0) shell.openExternal(release.url).catch(() => undefined);
    }
  }

  async promptRestart() {
    const { response } = await this.showBox({
      type: 'info',
      title: '软件更新',
      message: '新版本已下载',
      detail: '重启 Mio 完成安装（Windows 可能提示「未知发布者」，选择「仍要运行」即可）。也可以下次退出时自动安装。',
      buttons: ['立即重启并安装', '退出时安装'],
      defaultId: 0,
      cancelId: 1,
    });
    if (response === 0) setImmediate(() => this.autoUpdater.quitAndInstall(false, true));
  }

  message(message, detail, type = 'info') {
    return this.showBox({ type, title: '软件更新', message, detail, buttons: ['好'] });
  }

  showBox(opts) {
    const win = BrowserWindow.getFocusedWindow() || this.getWindow();
    return win && !win.isDestroyed() ? dialog.showMessageBox(win, opts) : dialog.showMessageBox(opts);
  }
}

module.exports = { Updater, UpdateStore };
