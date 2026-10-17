'use strict';
// 内置浏览器：YouTube 防沉迷（与 iOS / Mac / Android 同一份脚本 shared/scripts/youtube-focus.js）。
// 开发时直接读仓库里的 ../shared/scripts；打包后 electron-builder extraResources 把它放在 resources/mio-scripts。
// 由 browser-frame-preload 在 *.youtube.com 顶层 frame 的 preload 阶段（页面脚本之前）经 webFrame.executeJavaScript 注入主世界。
const fs = require('node:fs');
const path = require('node:path');

const FILE = 'youtube-focus.js';
const DEFAULT_INTERVAL = 60;
const INTERVAL_CHOICES = [30, 60, 120, 300, 600];

function scriptDirs() {
  const dirs = [];
  if (process.resourcesPath) dirs.push(path.join(process.resourcesPath, 'mio-scripts'));
  dirs.push(path.join(__dirname, '..', '..', 'shared', 'scripts'));
  return dirs;
}

let cached = null;
function template(dirs = scriptDirs()) {
  if (cached !== null) return cached;
  for (const d of dirs) {
    try {
      cached = fs.readFileSync(path.join(d, FILE), 'utf8');
      return cached;
    } catch {
      // 下一个位置
    }
  }
  console.error('[youtube-focus] shared script not found in', dirs.join(', '));
  cached = '';
  return cached;
}

function isYouTubeHost(host) {
  const h = String(host || '').toLowerCase();
  return h === 'youtube.com' || h.endsWith('.youtube.com');
}

function isYouTubeUrl(url) {
  try {
    const u = new URL(url);
    return (u.protocol === 'https:' || u.protocol === 'http:') && isYouTubeHost(u.hostname);
  } catch {
    return false;
  }
}

/** 与 MioWebCompat.youtubeFocusScript / Android YouTubeFocus.render 相同：间隔夹在 5…3600 秒 */
function render(tpl, intervalSeconds, hidePlayables) {
  const n = Number(intervalSeconds);
  const s = Math.max(5, Math.min(3600, Number.isFinite(n) ? Math.round(n) : DEFAULT_INTERVAL));
  return tpl.replace('__MIO_YT_INTERVAL_MS__', String(s * 1000)).replace('__MIO_YT_PLAYABLES__', hidePlayables ? '1' : '0');
}

/** 顶层 frame 的 url 是 YouTube 且开关开着 → 注入代码；否则 '' */
function scriptFor(url, settings, tpl = template()) {
  if (!tpl || !settings || !settings.get('youtubeFocus') || !isYouTubeUrl(url)) return '';
  return render(tpl, settings.get('youtubeFocusInterval'), !!settings.get('youtubeFocusPlayables'));
}

module.exports = { scriptFor, render, template, isYouTubeUrl, isYouTubeHost, DEFAULT_INTERVAL, INTERVAL_CHOICES, _reset: () => { cached = null; } };
