'use strict';
// 内置浏览器每个 frame 的 preload（沙箱）：同步取本 frame 匹配的启用用户脚本（userscripts.js），document-start 注入。
// - 有 @grant 的脚本：各自的隔离 world（world id 由主进程给，1100+序号），原生桥 mioUserScriptNative 只暴露在该 world，
//   桥里写死脚本 id → 页面和其他脚本既看不到也冒充不了。
// - @grant none：页面主世界。
// 运行时自己按 @run-at 调度（document-end / idle 等 DOMContentLoaded）。
const { contextBridge, ipcRenderer, webFrame } = require('electron');

if (/^(https?|file):$/.test(location.protocol)) {
  let list = null;
  try {
    list = ipcRenderer.sendSync('mio-userscripts:scripts', location.href);
  } catch {
    list = null;
  }
  if (Array.isArray(list)) {
    for (const s of list) {
      if (!s || typeof s.source !== 'string') continue;
      if (s.isolated) {
        const id = String(s.id);
        try {
          webFrame.setIsolatedWorldInfo(s.world, { name: `Mio 用户脚本 ${id}` });
        } catch {
          // 旧版本没有
        }
        try {
          contextBridge.exposeInIsolatedWorld(s.world, 'mioUserScriptNative', {
            invoke: (msg) => ipcRenderer.invoke('mio-userscripts:op', id, msg),
          });
        } catch {
          // 已暴露（同一文档重复执行）
        }
        webFrame.executeJavaScriptInIsolatedWorld(s.world, [{ code: s.source }]).catch(() => undefined);
      } else {
        webFrame.executeJavaScript(s.source).catch(() => undefined);
      }
    }
  }
}
