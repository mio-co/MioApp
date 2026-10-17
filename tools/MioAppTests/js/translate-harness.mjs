// 翻译脚本（shared/translate/mio-translate.js）测试工具：在 jsdom 里加载、mock 原生桥。CI 不访问真实翻译接口。
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { JSDOM } from 'jsdom';

export const SCRIPT_PATH = fileURLToPath(new URL('../../../shared/translate/mio-translate.js', import.meta.url));
export const SCRIPT = readFileSync(SCRIPT_PATH, 'utf8');

/** 只加载纯函数（不启动运行时） */
export function loadCore() {
  const dom = new JSDOM('<!doctype html><html><body></body></html>', { url: 'https://example.com/', runScripts: 'outside-only' });
  dom.window.__MIO_TRANSLATE_EXPORT__ = true;
  dom.window.eval(SCRIPT);
  return dom.window.__mioTranslateCore;
}

export function encodeConfig(cfg) {
  return Buffer.from(JSON.stringify(cfg), 'utf8').toString('base64');
}

/**
 * 假原生：fetch 由 handler(req) 决定（默认按引擎返回 "[译]原文"），缓存在内存里。
 * 返回 { calls, cache, bridgeObj }，bridgeObj 挂到 window.webkit.messageHandlers.mioTranslate 上
 */
export function fakeNative({ handler, token = 'tok', failCache = false } = {}) {
  const calls = [];
  const cache = new Map();
  const prefs = {};
  const defaultHandler = (req) => {
    if (req.url.startsWith('https://edge.microsoft.com/translate/auth')) return { status: 404, body: '' };
    if (req.url.startsWith('https://www.bing.com/translator')) {
      return { status: 200, picks: [['ABCDEF0123'], ['translator.5023'], [String(Date.now()), 'TOKEN', '3600000']] };
    }
    if (req.url.startsWith('https://www.bing.com/ttranslatev3')) {
      const text = new URLSearchParams(req.body).get('text');
      const out = text.split('\n').map((l) => `[译]${l}`).join('\n');
      return { status: 200, body: JSON.stringify([{ detectedLanguage: { language: 'en' }, translations: [{ text: out, to: 'zh-Hans' }] }]) };
    }
    if (req.url.startsWith('https://translate.googleapis.com/translate_a/t')) {
      const qs = new URLSearchParams(req.body).getAll('q');
      return { status: 200, body: JSON.stringify(qs.map((q) => [`[G]${q}`, 'en'])) };
    }
    return { status: 500, body: 'unexpected ' + req.url };
  };
  const h = handler || defaultHandler;
  const bridgeObj = {
    postMessage(msg) {
      const m = JSON.parse(JSON.stringify(msg));
      calls.push(m);
      if (m.t !== token) return Promise.reject(new Error('bad token'));
      if (m.op === 'fetch') return Promise.resolve().then(() => h(m.req, defaultHandler));
      if (m.op === 'cacheGet') {
        if (failCache) return Promise.reject(new Error('cache down'));
        const values = {};
        for (const k of m.keys) if (cache.has(k)) values[k] = cache.get(k);
        return Promise.resolve({ values });
      }
      if (m.op === 'cachePut') {
        for (const [k, v] of Object.entries(m.entries)) cache.set(k, v);
        return Promise.resolve({ ok: true });
      }
      if (m.op === 'setPref') { prefs[m.key] = m.value; return Promise.resolve({ ok: true }); }
      return Promise.resolve({ error: 'unknown op' });
    },
  };
  return { calls, cache, prefs, bridgeObj, token, fetches: () => calls.filter((c) => c.op === 'fetch').map((c) => c.req) };
}

/** 带运行时的页面：注入配置后的脚本，在 document-start 位置执行 */
export function loadPage(html, { url = 'https://example.com/a', config = {}, native, beforeScript, intersection = false } = {}) {
  const dom = new JSDOM(html, { url, runScripts: 'outside-only', pretendToBeVisual: true });
  const w = dom.window;
  const nat = native || fakeNative();
  w.webkit = { messageHandlers: { mioTranslate: nat.bridgeObj } };
  if (!intersection) delete w.IntersectionObserver;
  if (beforeScript) beforeScript(w);
  const cfg = { v: 1, token: nat.token, target: 'zh-CN', engine: 'microsoft', display: 'bilingual', autoSites: [], selection: true, youtube: true, ytSubs: true, openai: {}, ...config };
  w.eval(SCRIPT.replace('__MIO_TRANSLATE_CONFIG__', encodeConfig(cfg)));
  return { dom, window: w, document: w.document, native: nat, api: w.__mioTranslate };
}

export const tick = (ms = 0) => new Promise((r) => setTimeout(r, ms));

/** 等到 cond() 为真（真实计时器，jsdom 里脚本用 window.setTimeout） */
export async function until(cond, ms = 3000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    if (cond()) return true;
    await tick(15);
  }
  return cond();
}
