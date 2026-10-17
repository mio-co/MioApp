'use strict';
// 阅读模式 / 强制深色 / 存到 Mio 的设置（userData/page-tools.json）与纯逻辑（不依赖 electron，node --test 可测）。
// 与 iOS（MioReaderCore.swift）同样的规则：按站点开关（含父域名，越具体越优先）> 全局「所有网站深色」。
const fs = require('node:fs');
const path = require('node:path');
const { EventEmitter } = require('node:events');

const THEMES = ['light', 'sepia', 'dark'];
const FONTS = ['sans', 'serif', 'mono'];
const DEFAULTS = {
  darkGlobal: false,
  darkSites: {},
  darkNativeHosts: [],
  readerTheme: 'light',
  readerFont: 'sans',
  readerFontSize: 18,
  saveCategory: '稍后阅读',
};

function normalizeHost(h) {
  return String(h || '').trim().toLowerCase().replace(/^\.+|\.+$/g, '').replace(/^www\./, '');
}

function matchingSiteKey(host, sites) {
  const h = normalizeHost(host);
  if (!h) return null;
  const parts = h.split('.');
  if (parts.length < 2) return Object.prototype.hasOwnProperty.call(sites, h) ? h : null;
  for (let i = 0; i < parts.length - 1; i++) {
    const key = parts.slice(i).join('.');
    if (Object.prototype.hasOwnProperty.call(sites, key) && typeof sites[key] === 'boolean') return key;
  }
  return null;
}

function isDarkEnabled(host, global, sites) {
  const key = matchingSiteKey(host, sites || {});
  return key ? sites[key] : !!global;
}

/** www/mio-browser 的位置：打包后在 resources/mio-browser（extraResources），开发时在仓库根目录 */
function scriptDirCandidates(resourcesPath, srcDir) {
  const list = [];
  if (resourcesPath) list.push(path.join(resourcesPath, 'mio-browser'));
  list.push(path.join(srcDir, '..', '..', 'www', 'mio-browser'));
  return list;
}

function loadScripts(dirs, readFile = fs.readFileSync) {
  for (const dir of dirs) {
    try {
      return {
        reader: readFile(path.join(dir, 'reader.js'), 'utf8'),
        dark: readFile(path.join(dir, 'dark.js'), 'utf8'),
        save: readFile(path.join(dir, 'mio-save.js'), 'utf8'),
        dir,
      };
    } catch {
      // 下一个候选
    }
  }
  return null;
}

class PageToolsStore extends EventEmitter {
  constructor(file) {
    super();
    this.file = file;
    this.data = JSON.parse(JSON.stringify(DEFAULTS));
    try {
      const j = JSON.parse(fs.readFileSync(file, 'utf8'));
      for (const k of Object.keys(DEFAULTS)) {
        if (!(k in j)) continue;
        const d = DEFAULTS[k];
        if (Array.isArray(d) ? Array.isArray(j[k]) : typeof j[k] === typeof d && j[k] !== null) this.data[k] = j[k];
      }
    } catch {
      // 首次启动
    }
    this.data.darkSites = Object.fromEntries(Object.entries(this.data.darkSites || {}).filter(([, v]) => typeof v === 'boolean'));
  }

  save() {
    if (this.file) {
      fs.mkdirSync(path.dirname(this.file), { recursive: true });
      const tmp = `${this.file}.tmp`;
      fs.writeFileSync(tmp, JSON.stringify(this.data, null, 2));
      fs.renameSync(tmp, this.file);
    }
    this.emit('change');
  }

  get readerPrefs() {
    return {
      theme: THEMES.includes(this.data.readerTheme) ? this.data.readerTheme : 'light',
      font: FONTS.includes(this.data.readerFont) ? this.data.readerFont : 'sans',
      fontSize: Math.min(32, Math.max(12, Math.round(Number(this.data.readerFontSize)) || 18)),
    };
  }

  setReaderPrefs(p) {
    if (p.theme && THEMES.includes(p.theme)) this.data.readerTheme = p.theme;
    if (p.font && FONTS.includes(p.font)) this.data.readerFont = p.font;
    if (p.fontSize !== undefined) this.data.readerFontSize = Math.min(32, Math.max(12, Math.round(Number(p.fontSize)) || 18));
    this.save();
  }

  get saveCategory() {
    const s = String(this.data.saveCategory || '').trim();
    return s || DEFAULTS.saveCategory;
  }

  isDarkEnabled(host) {
    return isDarkEnabled(host, this.data.darkGlobal, this.data.darkSites);
  }

  setDarkGlobal(on) {
    this.data.darkGlobal = !!on;
    this.save();
  }

  /** 当前站点开关：和全局一致时去掉站点设置（跟随全局），否则记为例外；写在实际生效的那一级 */
  setSiteDark(host, on) {
    const h = normalizeHost(host);
    if (!h) return;
    const sites = { ...this.data.darkSites };
    const key = matchingSiteKey(h, sites) || h;
    if (on === !!this.data.darkGlobal) delete sites[key];
    else sites[key] = !!on;
    if (isDarkEnabled(h, this.data.darkGlobal, sites) !== !!on) sites[key] = !!on;
    this.data.darkSites = sites;
    this.save();
  }

  needsDarkScript() {
    return !!this.data.darkGlobal || Object.values(this.data.darkSites).some((v) => v === true);
  }

  darkConfig() {
    return { global: !!this.data.darkGlobal, sites: { ...this.data.darkSites }, nativeHosts: [...this.data.darkNativeHosts] };
  }

  /** dark.js 上报：网站自带深色就记住（最多 300 个），下次不先反色 */
  reportDark(host, verdict) {
    const h = normalizeHost(host);
    if (!h) return false;
    const before = this.data.darkNativeHosts;
    let list = before.filter((x) => x !== h);
    if (verdict === 'native') list.unshift(h);
    list = list.slice(0, 300);
    if (list.length === before.length && list.every((x, i) => x === before[i])) return false;
    this.data.darkNativeHosts = list;
    this.save();
    return true;
  }
}

/** 主框架 document-start 注入的深色脚本（不需要时返回空串） */
function darkInjection(store, darkSource) {
  if (!darkSource || !store.needsDarkScript()) return '';
  return `${darkSource}\n;try{MioDark.install(document,window,${JSON.stringify(store.darkConfig())});}catch(e){}\n`;
}

/** 内置浏览器页面里执行：提取正文 + 选中文字 + 阅读视图 HTML */
function extractCode(readerSource, prefs, force) {
  return `(function(){if(typeof globalThis.MioReader==='undefined'){\n${readerSource}\n}
var sel='';try{sel=String(window.getSelection?window.getSelection():'').trim();}catch(e){}
var a=null;try{a=MioReader.extract(document,{url:location.href,force:${force ? 'true' : 'false'}});}catch(e){a=null;}
var out={url:location.href,title:document.title||'',selection:sel.slice(0,20000)};
if(a){out.article={title:a.title,byline:a.byline,siteName:a.siteName,excerpt:a.excerpt,markdown:a.markdown,textLength:a.textLength,url:a.url};out.page=MioReader.buildPage(a,${JSON.stringify(prefs)});}
return out;})()`;
}

function readerableCode(readerSource) {
  return `(function(){if(typeof globalThis.MioReader==='undefined'){\n${readerSource}\n}return MioReader.isProbablyReaderable(document);})()`;
}

/** 主窗口（MioCore 同源）里执行：返回 Promise<MioSave 结果> */
function saveCode(saveSource, kind, payload, opts) {
  return `(function(){if(typeof globalThis.MioSave==='undefined'){\n${saveSource}\n}return MioSave.run(${JSON.stringify(kind)},${JSON.stringify(payload)},${JSON.stringify(opts)});})()`;
}

function saveMessage(r) {
  if (!r) return { ok: false, text: '保存失败：没有返回结果' };
  if (r.ok) {
    if (r.kind === 'bookmark') return { ok: true, text: r.duplicate ? `导航里已有这个网页${r.category ? `「${r.category}」` : ''}` : `已存到导航${r.category ? `「${r.category}」` : ''}` };
    if (r.kind === 'note') return { ok: true, text: '已新建笔记' };
    if (r.kind === 'clip') return { ok: true, text: '已推到云剪贴板，可在另一台设备继续' };
    return { ok: true, text: '已保存' };
  }
  return { ok: false, text: r.message || '未知错误' };
}

module.exports = {
  DEFAULTS,
  normalizeHost,
  matchingSiteKey,
  isDarkEnabled,
  scriptDirCandidates,
  loadScripts,
  PageToolsStore,
  darkInjection,
  extractCode,
  readerableCode,
  saveCode,
  saveMessage,
};
