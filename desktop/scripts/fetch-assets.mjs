#!/usr/bin/env node
// 构建前准备 Windows 壳内置浏览器的拦截资源 → assets/adblock/（打包为 extraResources，首次启动离线可用）
// - 与 iOS / Android 同一组 AdGuard 列表（2 Base、11 移动广告、3 跟踪保护、101 EasyList、118 EasyPrivacy、224 中文），
//   取 AdGuard 官方的 uBlock Origin 语法版本（filters.adtidy.org/extension/ublock/…，scriptlets 已转成 ##+js()），Ghostery 引擎直接可用
// - uBO scriptlets 资源 resources.json（Ghostery 引擎注入 ##+js() 用）
// - manifest.json：ETag / Last-Modified / 版本 / sha256，App 首次更新检查时可直接 304
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { copyFileSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import config from '../src/config.js';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const out = resolve(root, process.argv[2] || 'assets/adblock');
mkdirSync(out, { recursive: true });

function download(url, file) {
  const headerFile = `${file}.headers`;
  execFileSync('curl', ['-fsSL', '--retry', '4', '--retry-all-errors', '--retry-delay', '3', '--compressed',
    '-H', 'Cache-Control: no-cache', '-D', headerFile, '-o', file, url], { stdio: 'inherit' });
  const raw = readFileSync(headerFile, 'utf8');
  rmSync(headerFile);
  const last = raw.trim().split(/\r?\n\r?\n/).pop() || '';
  const header = (name) => new RegExp(`^${name}:\\s*(.+)$`, 'im').exec(last)?.[1]?.trim() || null;
  return { etag: header('etag'), lastModified: header('last-modified') };
}

const manifest = { generatedAt: new Date().toISOString(), lists: {}, resources: {} };
for (const list of config.FILTER_LISTS) {
  const file = join(out, `filter-${list.id}.txt`);
  const h = download(list.url, file);
  const text = readFileSync(file, 'utf8');
  if (text.length < 1000 || /<html/i.test(text.slice(0, 2048))) throw new Error(`${list.url}: not a filter list`);
  const version = /^! Version:\s*(.+)$/m.exec(text)?.[1]?.trim() || null;
  const rules = text.split('\n').filter((l) => l.trim() && !l.startsWith('!') && !l.startsWith('[')).length;
  manifest.lists[String(list.id)] = { url: list.url, ...h, version, rules, sha256: createHash('sha256').update(text).digest('hex') };
  console.log(`filter ${list.id} (${list.name}): ${rules} rules, v${version}`);
}

const resFile = join(out, 'resources.json');
const rh = download(config.RESOURCES_URL, resFile);
const res = JSON.parse(readFileSync(resFile, 'utf8'));
if (!Array.isArray(res.scriptlets) || res.scriptlets.length < 20) throw new Error('resources.json: no scriptlets');
manifest.resources = { url: config.RESOURCES_URL, ...rh, scriptlets: res.scriptlets.length, sha256: createHash('sha256').update(readFileSync(resFile)).digest('hex') };
console.log(`resources: ${res.scriptlets.length} scriptlets`);

copyFileSync(join(root, 'filters/mio-youtube.txt'), join(out, 'filter-0.txt'));
writeFileSync(join(out, 'manifest.json'), JSON.stringify(manifest, null, 2));
console.log(`→ ${out}`);
