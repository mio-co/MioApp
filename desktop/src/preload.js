'use strict';
// 主窗口（MioCore 站点）preload：暴露 window.MioDesktop（MioCore 的 src/utils/appShell.ts 检测 MioDesktop.browser）
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('MioDesktop', {
  platform: process.platform,
  shell: 'electron',
  browser: {
    /** @param {{ url: string, mode?: 'auto' | 'inapp' | 'safari' | 'system' }} options */
    open: (options) => ipcRenderer.invoke('mio-desktop:browser-open', options && { url: String(options.url || ''), mode: options.mode ? String(options.mode) : 'auto' }),
    openSettings: () => ipcRenderer.invoke('mio-desktop:browser-settings'),
    getInfo: () => ipcRenderer.invoke('mio-desktop:browser-info'),
  },
});
