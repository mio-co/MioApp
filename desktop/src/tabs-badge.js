'use strict';
// 浏览器收起后主窗口右下角的「N 个标签」角标（悬浮的本地小页面，不改 MioCore 页面）：点一下回到浏览器。
// 浏览器窗口隐藏且还有标签时显示；浏览器可见 / 没有标签时隐藏。
const path = require('node:path');
const { WebContentsView, ipcMain, nativeTheme } = require('electron');

const W = 132;
const H = 40;
const MARGIN = 18;

class TabsBadge {
  constructor({ browser, getMainWindow }) {
    this.browser = browser;
    this.getMainWindow = getMainWindow;
    this.view = null;
    this.win = null;
    browser.on('change', () => this.update());
    ipcMain.on('mio-badge:click', (event) => {
      if (this.view && event.sender === this.view.webContents) this.browser.show();
    });
    ipcMain.handle('mio-badge:state', (event) => (this.view && event.sender === this.view.webContents ? this.state() : null));
  }

  state() {
    return { count: this.browser.store.size, dark: nativeTheme.shouldUseDarkColors };
  }

  attach() {
    const win = this.getMainWindow();
    if (!win || win.isDestroyed()) return null;
    if (this.win === win && this.view) return this.view;
    this.win = win;
    const view = new WebContentsView({
      webPreferences: {
        preload: path.join(__dirname, 'ui', 'badge-preload.js'),
        partition: 'mio-ui',
        contextIsolation: true,
        sandbox: true,
        nodeIntegration: false,
      },
    });
    view.setBackgroundColor('#00000000');
    view.webContents.loadFile(path.join(__dirname, 'ui', 'badge.html'));
    win.contentView.addChildView(view);
    this.view = view;
    const place = () => {
      if (win.isDestroyed()) return;
      const { width, height } = win.getContentBounds();
      view.setBounds({ x: Math.max(0, width - W - MARGIN), y: Math.max(0, height - H - MARGIN), width: W, height: H });
    };
    place();
    win.on('resize', place);
    win.on('closed', () => {
      this.view = null;
      this.win = null;
    });
    return view;
  }

  update() {
    const show = this.browser.store.size > 0 && !this.browser.isVisible();
    const view = show ? this.attach() : this.view;
    if (!view) return;
    view.setVisible(show);
    if (show && !view.webContents.isDestroyed()) view.webContents.send('mio-badge:state', this.state());
  }
}

module.exports = { TabsBadge };
