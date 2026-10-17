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
  openTranslate: () => ipcRenderer.invoke('mio-translate-settings:open'),
});

// 软件更新（desktop/src/updater.js）
contextBridge.exposeInMainWorld('mioUpdate', {
  get: () => ipcRenderer.invoke('mio-update:get'),
  setAuto: (on) => ipcRenderer.invoke('mio-update:set-auto', !!on),
  check: () => ipcRenderer.invoke('mio-update:check'),
  onChange: (fn) => ipcRenderer.on('mio-update:changed', (_e, s) => fn(s)),
});

// 容器管理（desktop/src/containers.js）
contextBridge.exposeInMainWorld('mioContainers', {
  get: () => ipcRenderer.invoke('mio-containers:get'),
  create: (name, color) => ipcRenderer.invoke('mio-containers:create', String(name), String(color || '')),
  update: (id, patch) => ipcRenderer.invoke('mio-containers:update', String(id), patch && typeof patch === 'object' ? { name: patch.name, color: patch.color } : {}),
  remove: (id) => ipcRenderer.invoke('mio-containers:remove', String(id)),
  setSiteRule: (host, id) => ipcRenderer.invoke('mio-containers:site-rule-set', String(host), String(id)),
  removeSiteRule: (host) => ipcRenderer.invoke('mio-containers:site-rule-remove', String(host)),
});
