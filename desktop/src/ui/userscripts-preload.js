'use strict';
const { contextBridge, ipcRenderer } = require('electron');

const call = (name, ...args) => ipcRenderer.invoke(`mio-userscripts-ui:${name}`, ...args);
contextBridge.exposeInMainWorld('mioUserScripts', {
  list: () => call('list'),
  installCode: (code) => call('install-code', String(code || '')),
  installUrl: (url) => call('install-url', String(url || '')),
  installFile: () => call('install-file'),
  enable: (id, on) => call('enable', String(id), !!on),
  remove: (id) => call('delete', String(id)),
  resetConnect: (id) => call('reset-connect', String(id)),
  code: (id) => call('code', String(id)),
  checkUpdate: (id) => call('check-update', String(id)),
  checkAll: () => call('check-all'),
  onChange: (fn) => ipcRenderer.on('mio-userscripts-ui:changed', (_e, list) => fn(list)),
});
