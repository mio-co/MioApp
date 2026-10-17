'use strict';
// YouTube 媒体脚本（与 iOS / Android 同一份 JS：src/inject/youtube-media.js，由 scripts/sync-media-js.mjs 从 MioMediaScripts.swift 生成）：
// SponsorBlock 自动跳过 + 撤销 + 进度条标记、MediaSession 元数据（Windows 媒体浮窗 / 媒体键）、画中画按钮（Chromium requestPictureInPicture）。
// 后台播放沿用 browser-frame-preload.js 的可见性伪造 + backgroundThrottling: false。
// Widevine：本应用用的是官方 Electron（不是 castlabs ECS），不带 Widevine CDM，Spotify 网页播放器无法播放 DRM 内容。
const fs = require('node:fs');
const path = require('node:path');

const CATEGORIES = ['sponsor', 'selfpromo', 'interaction', 'intro', 'outro'];
const DEFAULT_CATEGORIES = 'sponsor,selfpromo,interaction';
const PLACEHOLDER = '__MIO_MEDIA_CONFIG__';

let template = null;
function loadTemplate() {
  if (template === null) {
    try {
      template = fs.readFileSync(path.join(__dirname, 'inject', 'youtube-media.js'), 'utf8');
    } catch {
      template = '';
    }
  }
  return template;
}

function isYouTubeUrl(url) {
  try {
    const u = new URL(url);
    return u.protocol === 'https:' && /(^|\.)youtube\.com$/i.test(u.hostname);
  } catch {
    return false;
  }
}

/** 'sponsor, intro,bogus' → ['sponsor', 'intro']（按固定顺序、去重） */
function parseCategories(s) {
  const set = new Set(String(s || '').split(',').map((x) => x.trim()).filter(Boolean));
  return CATEGORIES.filter((c) => set.has(c));
}

function config(get) {
  return {
    platform: 'desktop',
    background: !!get('backgroundPlayback'),
    nowPlaying: true,
    pip: true,
    sponsorBlock: get('sponsorBlock') !== false,
    categories: parseCategories(get('sponsorBlockCategories') ?? DEFAULT_CATEGORIES),
  };
}

/** 顶层 YouTube 页面要注入的脚本（其它页面 / iframe 返回 ''）。get = settings.get */
function scriptFor(url, get, isTop = true, tpl = loadTemplate()) {
  if (!isTop || !tpl || !isYouTubeUrl(url)) return '';
  const i = tpl.indexOf(PLACEHOLDER);
  if (i < 0) return '';
  return tpl.slice(0, i) + JSON.stringify(config(get)) + tpl.slice(i + PLACEHOLDER.length);
}

module.exports = { scriptFor, parseCategories, config, isYouTubeUrl, CATEGORIES, DEFAULT_CATEGORIES };
