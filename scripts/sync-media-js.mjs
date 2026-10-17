#!/usr/bin/env node
// 把 ios/App/App/MioMediaScripts.swift 里的 YouTube 媒体脚本（MIO_JS_BEGIN youtubeMedia）生成给 Android / Windows 用：
//   android/app/src/main/assets/mio/youtube-media.js
//   desktop/src/inject/youtube-media.js
// 唯一的源在 Swift 文件里；tools/MioAppTests/js/media-sync.test.mjs 检查生成文件没有过期。
// 用法：node scripts/sync-media-js.mjs          生成
//       node scripts/sync-media-js.mjs --check  只检查（过期时退出码 1）
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { extractMediaScript } from '../tools/MioAppTests/js/media-harness.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));
export const TARGETS = ['android/app/src/main/assets/mio/youtube-media.js', 'desktop/src/inject/youtube-media.js'];

export function generated() {
  return '// 生成文件，勿手改：node scripts/sync-media-js.mjs（源：ios/App/App/MioMediaScripts.swift 的 youtubeMedia 段）\n' +
    '// 运行前把脚本里的配置占位符（MIO_MEDIA_CONFIG）替换成配置 JSON。SponsorBlock 数据：sponsor.ajay.app，CC BY-NC-SA 4.0。\n' +
    extractMediaScript('youtubeMedia').replace(/\s*$/, '\n');
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const check = process.argv.includes('--check');
  const want = generated();
  let stale = 0;
  for (const rel of TARGETS) {
    const p = root + rel;
    let have = null;
    try { have = readFileSync(p, 'utf8'); } catch {}
    if (have === want) continue;
    if (check) { console.error(`stale: ${rel}`); stale++; continue; }
    mkdirSync(dirname(p), { recursive: true });
    writeFileSync(p, want);
    console.log(`wrote ${rel}`);
  }
  process.exit(stale ? 1 : 0);
}
