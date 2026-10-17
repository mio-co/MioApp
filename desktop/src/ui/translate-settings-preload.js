'use strict';
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('mioTranslateSettings', {
  get: () => ipcRenderer.invoke('mio-translate-settings:get'),
  set: (key, value) => ipcRenderer.invoke('mio-translate-settings:set', String(key), value),
  site: (host, on) => ipcRenderer.invoke('mio-translate-settings:site', String(host), !!on),
  setKey: (key) => ipcRenderer.invoke('mio-translate-settings:key', String(key || '')),
  clearCache: () => ipcRenderer.invoke('mio-translate-settings:clear-cache'),
  test: () => ipcRenderer.invoke('mio-translate-settings:test'),
  onChange: (fn) => ipcRenderer.on('mio-translate-settings:changed', (_e, s) => fn(s)),
});
