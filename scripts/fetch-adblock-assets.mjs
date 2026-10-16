#!/usr/bin/env node
// 构建前准备内置浏览器的拦截资源（iOS / Mac Catalyst 的 AdblockBundle，Android / Electron 也共用这份）：
// - AdGuard 官方过滤列表（filters.adtidy.org，iOS 优化版）→ filter-<id>.txt + manifest.json（ETag / Last-Modified，App 首次更新时可直接 304）
// - @adguard/scriptlets 的 scriptlets.corelibs.json、@adguard/extended-css 的 extended-css.min.js（版本由 package-lock 固定）
// 用法：node scripts/fetch-adblock-assets.mjs [输出目录，默认 ios/App/App/AdblockBundle]
import { createHash } from 'node:crypto';
import { copyFileSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const out = resolve(root, process.argv[2] || 'ios/App/App/AdblockBundle');
const nm = (p) => join(root, 'node_modules', p);
const readJSON = (p) => JSON.parse(readFileSync(p, 'utf8'));
const FILTERS = [2, 11, 3, 101, 118, 224];

mkdirSync(out, { recursive: true });
const manifest = { generatedAt: new Date().toISOString(), lists: {}, scriptlets: {}, extendedCss: {} };

for (const id of FILTERS) {
  const url = `https://filters.adtidy.org/ios/filters/${id}_optimized.txt`;
  let res;
  for (let attempt = 1; attempt <= 3; attempt++) {
    try {
      res = await fetch(url, { headers: { 'Cache-Control': 'no-cache' } });
      if (res.ok) break;
      throw new Error(`HTTP ${res.status}`);
    } catch (e) {
      if (attempt === 3) throw new Error(`${url}: ${e.message}`);
      await new Promise((r) => setTimeout(r, 2000 * attempt));
    }
  }
  const text = await res.text();
  if (text.length < 1000 || /<html/i.test(text.slice(0, 2048))) throw new Error(`${url}: not a filter list`);
  writeFileSync(join(out, `filter-${id}.txt`), text);
  const rules = text.split('\n').filter((l) => l && !l.startsWith('!')).length;
  const version = /^! Version:\s*(.+)$/m.exec(text)?.[1]?.trim();
  manifest.lists[String(id)] = {
    url,
    etag: res.headers.get('etag'),
    lastModified: res.headers.get('last-modified'),
    version,
    rules,
    sha256: createHash('sha256').update(text).digest('hex'),
  };
  console.log(`filter ${id}: ${rules} rules, v${version}, ${text.length} bytes`);
}

const scriptletsPkg = readJSON(nm('@adguard/scriptlets/package.json'));
const corelibs = nm('@adguard/scriptlets/dist/scriptlets.corelibs.json');
copyFileSync(corelibs, join(out, 'scriptlets.corelibs.json'));
const cl = readFileSync(corelibs);
manifest.scriptlets = { version: scriptletsPkg.version, sha256: createHash('sha256').update(cl).digest('base64') };
console.log(`scriptlets ${scriptletsPkg.version}`);

const ecssDir = nm('@adguard/extended-css');
const ecssPkg = readJSON(join(ecssDir, 'package.json'));
copyFileSync(join(ecssDir, 'dist/extended-css.min.js'), join(out, 'extended-css.min.js'));
manifest.extendedCss = { version: ecssPkg.version };
console.log(`extended-css ${ecssPkg.version}`);

writeFileSync(join(out, 'manifest.json'), JSON.stringify(manifest, null, 2));
console.log(`→ ${out}`);
