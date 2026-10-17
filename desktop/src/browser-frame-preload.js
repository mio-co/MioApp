'use strict';
// 内置浏览器每个 frame 的 preload（沙箱）：在页面脚本之前同步取 scriptlets 并注入主世界；
// 顶层页面开启「后台播放」时让 document.hidden / visibilityState 恒为可见（切走窗口 / 最小化不暂停）
const { ipcRenderer, webFrame, contextBridge } = require('electron');

let result = null;
try {
  result = ipcRenderer.sendSync('mio-adblock:page-scripts', location.href);
} catch {
  result = null;
}

const parts = [];
// WebRTC 控制（webrtc.js）：最先注入；站点被放行 / 总开关关闭时为 null
try {
  const rtc = ipcRenderer.sendSync('mio-webrtc:script', location.href);
  if (rtc) parts.push(rtc);
} catch {
  // 主进程没有注册（旧版本）
}
if (result && result.background) {
  parts.push(`(function(){try{
    Object.defineProperty(document,'hidden',{configurable:true,get:function(){return false;}});
    Object.defineProperty(document,'visibilityState',{configurable:true,get:function(){return 'visible';}});
    document.addEventListener('visibilitychange',function(e){e.stopImmediatePropagation();},true);
  }catch(e){}})();`);
}
if (result && result.scripts) parts.push(result.scripts);
// 强制深色（page-tools.js；只给主框架、只在开启的站点返回脚本），排在最前面尽早反色避免闪白
let dark = '';
try {
  dark = ipcRenderer.sendSync('mio-pagetools:dark-script', location.href) || '';
} catch {
  dark = '';
}
if (dark) {
  try {
    contextBridge.exposeInMainWorld('mioDarkReport', (d) => ipcRenderer.send('mio-pagetools:dark-report', { host: String(d && d.host), verdict: String(d && d.verdict) }));
  } catch {
    // ignore
  }
  parts.unshift(dark);
}
if (parts.length) {
  // webFrame.executeJavaScript 在主世界执行，不受页面 CSP 限制；preload 阶段调用早于页面自己的脚本
  webFrame.executeJavaScript(parts.join('\n;\n')).catch(() => undefined);
}
// YouTube 防沉迷（共享脚本，只在 *.youtube.com 顶层 frame 有内容）：单独执行，不受前面 scriptlets 运行时异常影响
if (result && result.ytFocus) webFrame.executeJavaScript(result.ytFocus).catch(() => undefined);
// YouTube 媒体脚本（src/media.js）单独执行：不受拦截脚本里异常的影响；失败原因留在页面里便于冒烟 / 调试
if (result && result.media) {
  webFrame.executeJavaScript(result.media).catch((e) =>
    webFrame.executeJavaScript(`window.__mioMediaError=${JSON.stringify(String((e && e.message) || e))}`).catch(() => undefined),
  );
} else if (result && result.mediaError) {
  webFrame.executeJavaScript(`window.__mioMediaError=${JSON.stringify(result.mediaError)}`).catch(() => undefined);
}
