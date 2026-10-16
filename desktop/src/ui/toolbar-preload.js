'use strict';
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('mioToolbar', {
  cmd: (name, arg) => ipcRenderer.send('mio-toolbar:cmd', String(name), arg === undefined ? undefined : String(arg)),
  state: () => ipcRenderer.invoke('mio-toolbar:state'),
  onState: (fn) => ipcRenderer.on('mio-toolbar:state', (_e, s) => fn(s)),
  onFocusAddress: (fn) => ipcRenderer.on('mio-toolbar:focus-address', () => fn()),
});
