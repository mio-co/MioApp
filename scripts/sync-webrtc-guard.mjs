// 把 ios/App/App/MioWebRTCGuard.swift 里的 WebRTC 控制脚本（唯一来源）同步到 Android / Windows：
//   node scripts/sync-webrtc-guard.mjs        写入
//   node scripts/sync-webrtc-guard.mjs --check 只检查（CI 单测里也有同样的检查）
import { readFileSync, writeFileSync } from 'node:fs';
import { extractFrom, repoPath } from '../tools/MioAppTests/js/swift-js.mjs';

const HEADER = '// 自动生成：来源 ios/App/App/MioWebRTCGuard.swift（MIO_JS_BEGIN webrtcGuard）。改那里，然后 node scripts/sync-webrtc-guard.mjs\n';
const js = HEADER + extractFrom('ios/App/App/MioWebRTCGuard.swift', 'webrtcGuard') + '\n';
const targets = ['android/app/src/main/assets/mio-webrtc-guard.js', 'desktop/src/inject/webrtc-guard.js'];
let bad = 0;
for (const t of targets) {
  let cur = '';
  try { cur = readFileSync(repoPath(t), 'utf8'); } catch {}
  if (cur === js) continue;
  if (process.argv.includes('--check')) { console.error(`out of date: ${t}`); bad++; } else { writeFileSync(repoPath(t), js); console.log(`wrote ${t}`); }
}
process.exit(bad ? 1 : 0);
