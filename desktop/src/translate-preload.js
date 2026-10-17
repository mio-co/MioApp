'use strict';
// 内置浏览器每个 frame 的 preload（沙箱）：只在主框架、http(s) 页面里注入翻译脚本（页面主世界，document-start）。
// 脚本经 window.__mioTranslateNative.request(json) 调主进程（带每次启动随机生成的 token；主进程校验 token 和来源会话）。
const { contextBridge, ipcRenderer, webFrame } = require('electron');

if (process.isMainFrame && /^https?:$/.test(location.protocol)) {
  let script = null;
  try {
    script = ipcRenderer.sendSync('mio-translate:script', location.href);
  } catch {
    script = null;
  }
  if (script) {
    try {
      contextBridge.exposeInMainWorld('__mioTranslateNative', {
        request: (json) => ipcRenderer.invoke('mio-translate:request', String(json)),
      });
    } catch {
      // 已经暴露过（同一文档重复执行）
    }
    webFrame.executeJavaScript(script).catch(() => undefined);
  }
}
