'use strict';
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('mioBadge', {
  click: () => ipcRenderer.send('mio-badge:click'),
  state: () => ipcRenderer.invoke('mio-badge:state'),
  onState: (fn) => ipcRenderer.on('mio-badge:state', (_e, s) => fn(s)),
});
