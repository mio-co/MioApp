'use strict';
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('mioSettings', {
  get: () => ipcRenderer.invoke('mio-settings:get'),
  set: (key, value) => ipcRenderer.invoke('mio-settings:set', String(key), value),
  addWhitelist: (input) => ipcRenderer.invoke('mio-settings:whitelist-add', String(input)),
  removeWhitelist: (host) => ipcRenderer.invoke('mio-settings:whitelist-remove', String(host)),
  setSite: (host, enabled) => ipcRenderer.invoke('mio-settings:site', String(host), !!enabled),
  updateNow: () => ipcRenderer.invoke('mio-settings:update-now'),
  clearData: () => ipcRenderer.invoke('mio-settings:clear-data'),
  onChange: (fn) => ipcRenderer.on('mio-settings:changed', (_e, s) => fn(s)),
});

// 软件更新（desktop/src/updater.js）
contextBridge.exposeInMainWorld('mioUpdate', {
  get: () => ipcRenderer.invoke('mio-update:get'),
  setAuto: (on) => ipcRenderer.invoke('mio-update:set-auto', !!on),
  check: () => ipcRenderer.invoke('mio-update:check'),
  onChange: (fn) => ipcRenderer.on('mio-update:changed', (_e, s) => fn(s)),
});
