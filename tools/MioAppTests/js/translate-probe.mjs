// 真实翻译接口探测（CI 里 continue-on-error，不阻塞）：用与 App 相同的引擎代码 + Node fetch 发请求，
// 分别强制走微软（Bing / Edge）和谷歌，看免费接口是否还能用。用法：node tools/MioAppTests/js/translate-probe.mjs
import { loadCore } from './translate-harness.mjs';

const C = loadCore();
const UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15';

/** 原生请求桥的最小实现（App 里由 iOS / Mac 原生代发）：支持 GET/POST、headers、body、timeoutMs、pick（正则抽取） */
async function nativeFetch(req) {
  const method = String(req.method || 'GET').toUpperCase();
  const headers = { ...(req.headers || {}) };
  if (!Object.keys(headers).some((k) => k.toLowerCase() === 'user-agent')) headers['user-agent'] = UA;
  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort(), Math.max(1000, Math.min(Number(req.timeoutMs) || 15000, 90000)));
  try {
    const r = await fetch(String(req.url), { method, headers, body: req.body == null ? undefined : String(req.body), signal: ac.signal, redirect: 'follow' });
    const body = await r.text();
    if (Array.isArray(req.pick)) {
      const picks = req.pick.map((p) => { try { const m = new RegExp(p).exec(body); return m ? m.slice(1).map((x) => (x == null ? '' : x)) : null; } catch { return null; } });
      return { status: r.status, picks };
    }
    return { status: r.status, body };
  } catch (e) {
    return { error: ac.signal.aborted ? 'timeout' : String((e && e.message) || e) };
  } finally {
    clearTimeout(timer);
  }
}

function deps(only) {
  const cache = new Map();
  return {
    http: async (req) => {
      if (only === 'google' && !/google/.test(new URL(String(req.url)).hostname)) return { error: 'skipped (probe google only)' };
      return nativeFetch(req);
    },
    cacheGet: async (keys) => Object.fromEntries(keys.filter((k) => cache.has(k)).map((k) => [k, cache.get(k)])),
    cachePut: async (e) => { for (const [k, v] of Object.entries(e)) cache.set(k, v); },
  };
}

const TEXTS = ['Hello world, this is a translation test.', 'The quick brown fox jumps over the lazy dog.', 'Subtitles are translated in batches.'];
let failed = 0;
for (const engine of ['microsoft', 'google']) {
  const t = C.createTranslator({ engine, target: 'zh-CN', concurrency: 1 }, deps(engine));
  const t0 = Date.now();
  try {
    const out = await t.translate(TEXTS, 'zh-CN');
    const used = [...new Set(out.map((x) => x.engine))].join(',');
    const ok = used === engine && out.every((x) => x.text && /[\u4e00-\u9fff]/.test(x.text));
    if (!ok) failed++;
    console.log(`${ok ? 'OK  ' : 'WARN'} ${engine}: used=${used} ${Date.now() - t0}ms fallbacks=${t.stats.fallbacks}`);
    out.forEach((x, i) => console.log(`     ${TEXTS[i]} → ${x.text}`));
  } catch (e) {
    failed++;
    console.log(`FAIL ${engine}: ${e.message} (${Date.now() - t0}ms)`);
  }
}
process.exitCode = failed ? 1 : 0;
