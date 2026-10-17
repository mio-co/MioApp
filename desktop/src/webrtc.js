'use strict';
// WebRTC 控制（与 iOS / Android 同一段脚本：inject/webrtc-guard.js，由 scripts/sync-webrtc-guard.mjs 从 MioWebRTCGuard.swift 生成）。
// 内置浏览器每个 frame 的 preload 同步取脚本、在页面脚本之前注入主世界；另外按顶层站点设置
// webContents.setWebRTCIPHandlingPolicy('disable_non_proxied_udp')（即使脚本被绕过，也不走非代理 UDP、不暴露本机 IP）。
// 设置：userData/webrtc.json（总开关默认开；放行列表含子域名）。
const fs = require('node:fs');
const path = require('node:path');
const { EventEmitter } = require('node:events');

const PLACEHOLDER = '__MIO_WEBRTC_CONFIG__';
const PRESETS = [
  ['Google Meet', 'meet.google.com'],
  ['Zoom', 'zoom.us'],
  ['Microsoft Teams', 'teams.microsoft.com'],
  ['Discord', 'discord.com'],
  ['Jitsi Meet', 'meet.jit.si'],
  ['Whereby', 'whereby.com'],
];

/** 用户输入（域名或网址）→ 小写主机名，去掉 www. / 端口 / 末尾的点 */
function normalize(input) {
  let h = String(input || '').trim().toLowerCase();
  const i = h.indexOf('://');
  if (i >= 0) h = h.slice(i + 3);
  h = h.split(/[/?#]/)[0];
  const at = h.lastIndexOf('@');
  if (at >= 0) h = h.slice(at + 1);
  const colon = h.lastIndexOf(':');
  if (colon >= 0 && !h.includes(']')) h = h.slice(0, colon);
  h = h.replace(/\.+$/, '');
  if (h.startsWith('*.')) h = h.slice(2);
  if (h.startsWith('www.')) h = h.slice(4);
  return h;
}

function hostOfUrl(url) {
  try {
    return new URL(url).hostname.toLowerCase();
  } catch {
    return '';
  }
}

/** 覆盖 host 的放行条目（host 本身或其父域） */
function entryFor(host, list) {
  const h = String(host || '').toLowerCase().replace(/\.+$/, '');
  if (!h) return null;
  return list.find((e) => h === e || h.endsWith(`.${e}`)) || null;
}

function buildScript(template, allow) {
  return template.replace(PLACEHOLDER, JSON.stringify({ allow }));
}

function loadTemplate() {
  // 第一行是「自动生成」注释
  return fs.readFileSync(path.join(__dirname, 'inject', 'webrtc-guard.js'), 'utf8');
}

class WebRtcControl extends EventEmitter {
  constructor(file) {
    super();
    this.file = file;
    this.data = { enabled: true, allow: [] };
    try {
      const j = JSON.parse(fs.readFileSync(file, 'utf8'));
      if (typeof j.enabled === 'boolean') this.data.enabled = j.enabled;
      if (Array.isArray(j.allow)) this.data.allow = j.allow.map(normalize).filter(Boolean);
    } catch {
      // 首次启动：默认开
    }
    this.template = null;
  }

  get enabled() {
    return this.data.enabled;
  }

  get allowlist() {
    return [...this.data.allow];
  }

  save() {
    fs.mkdirSync(path.dirname(this.file), { recursive: true });
    const tmp = `${this.file}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(this.data, null, 2));
    fs.renameSync(tmp, this.file);
    this.emit('change');
  }

  setEnabled(on) {
    this.data.enabled = !!on;
    this.save();
  }

  isAllowed(host) {
    return !!entryFor(host, this.data.allow);
  }

  setAllowed(host, allow) {
    if (allow) {
      const h = normalize(host);
      if (!h || this.data.allow.includes(h)) return;
      this.data.allow = [...this.data.allow, h].sort();
    } else {
      const h = String(host || '').toLowerCase();
      const n = normalize(host);
      this.data.allow = this.data.allow.filter((e) => !(h === e || h.endsWith(`.${e}`) || n === e));
    }
    this.save();
  }

  /** 某个 frame 要注入的代码（总开关关 / 顶层或 frame 自身在放行列表 → null） */
  scriptFor(frameUrl, topUrl) {
    if (!this.data.enabled) return null;
    if (this.isAllowed(hostOfUrl(topUrl || frameUrl)) || this.isAllowed(hostOfUrl(frameUrl))) return null;
    if (!this.template) this.template = loadTemplate();
    return buildScript(this.template, this.data.allow);
  }

  policyFor(topUrl) {
    return this.data.enabled && !this.isAllowed(hostOfUrl(topUrl)) ? 'disable_non_proxied_udp' : 'default';
  }

  /** 挂到内置浏览器会话：preload 同步取脚本；会话里每个 webContents 按顶层站点设置 IP 处理策略 */
  attach({ app, ipcMain, browserSession, isBrowserSession }) {
    // 容器（containers.js）：每个容器会话都算内置浏览器
    const isBrowser = isBrowserSession || ((ses) => ses === browserSession);
    ipcMain.on('mio-webrtc:script', (event, url) => {
      let js = null;
      try {
        if (event.sender && isBrowser(event.sender.session)) {
          const f = event.senderFrame;
          const top = f && f.parent === null ? url : (f && f.top ? f.top.url : event.sender.getURL());
          js = this.scriptFor(url, top);
        }
      } catch (e) {
        console.error('[webrtc] script', e);
      }
      event.returnValue = js;
    });
    const apply = (wc, url) => {
      try {
        wc.setWebRTCIPHandlingPolicy(this.policyFor(url));
      } catch {
        // webContents 已销毁
      }
    };
    app.on('web-contents-created', (e, wc) => {
      if (!isBrowser(wc.session)) return;
      apply(wc, wc.getURL());
      wc.on('did-start-navigation', (details) => {
        if (details && details.isMainFrame && !details.isSameDocument) apply(wc, details.url);
      });
    });
    this.on('change', () => {
      const { webContents } = require('electron');
      for (const wc of webContents.getAllWebContents()) if (isBrowser(wc.session)) apply(wc, wc.getURL());
    });
  }

  /** 内置浏览器盾牌菜单里的条目 */
  menuItems(host, reload) {
    const items = [{ type: 'separator' }];
    items.push({ label: '屏蔽 WebRTC（防真实 IP 泄露）', type: 'checkbox', checked: this.enabled, click: () => { this.setEnabled(!this.enabled); reload(); } });
    if (this.enabled) {
      if (host) {
        items.push({ label: `允许 ${host} 使用 WebRTC（网页通话）`, type: 'checkbox', checked: this.isAllowed(host), click: () => { this.setAllowed(host, !this.isAllowed(host)); reload(); } });
      }
      items.push({
        label: '放行网页通话站点',
        submenu: PRESETS.map(([name, h]) => ({ label: `${name}（${h}）`, type: 'checkbox', checked: this.data.allow.includes(h), click: () => this.setAllowed(h, !this.data.allow.includes(h)) })),
      });
    }
    return items;
  }
}

module.exports = { WebRtcControl, normalize, entryFor, buildScript, hostOfUrl, PLACEHOLDER, PRESETS };
