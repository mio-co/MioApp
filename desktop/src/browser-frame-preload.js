'use strict';
// 内置浏览器每个 frame 的 preload（沙箱）：在页面脚本之前同步取 scriptlets 并注入主世界；
// 顶层页面开启「后台播放」时让 document.hidden / visibilityState 恒为可见（切走窗口 / 最小化不暂停）
const { ipcRenderer, webFrame } = require('electron');

let result = null;
try {
  result = ipcRenderer.sendSync('mio-adblock:page-scripts', location.href);
} catch {
  result = null;
}

const parts = [];
if (result && result.background) {
  parts.push(`(function(){try{
    Object.defineProperty(document,'hidden',{configurable:true,get:function(){return false;}});
    Object.defineProperty(document,'visibilityState',{configurable:true,get:function(){return 'visible';}});
    document.addEventListener('visibilitychange',function(e){e.stopImmediatePropagation();},true);
  }catch(e){}})();`);
}
if (result && result.scripts) parts.push(result.scripts);
if (result && result.media) parts.push(result.media);
if (parts.length) {
  // webFrame.executeJavaScript 在主世界执行，不受页面 CSP 限制；preload 阶段调用早于页面自己的脚本
  webFrame.executeJavaScript(parts.join('\n;\n')).catch(() => undefined);
}
// YouTube 防沉迷（共享脚本，只在 *.youtube.com 顶层 frame 有内容）：单独执行，不受前面 scriptlets 运行时异常影响
if (result && result.ytFocus) webFrame.executeJavaScript(result.ytFocus).catch(() => undefined);
