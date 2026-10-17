// 把 ios/App/App/MioUserScriptCore.swift 里的用户脚本运行时（唯一来源，MIO_JS_BEGIN userscriptRuntime）
// 和包装函数参数表（apiParams）同步到 Android / Windows：
//   node scripts/sync-userscript-runtime.mjs         写入
//   node scripts/sync-userscript-runtime.mjs --check 只检查（CI 单测里也有同样的检查）
// 生成文件第 2 行是 `// MIO_PARAMS <apiParams>`，Android（UserScriptCore.java）/ Electron（userscript-core.js）从这里读参数表。
import { readFileSync, writeFileSync } from 'node:fs';
import { extractFrom, swiftStringConstant, repoPath } from '../tools/MioAppTests/js/swift-js.mjs';

const SWIFT = 'ios/App/App/MioUserScriptCore.swift';
export function renderRuntime() {
  return (
    '// 自动生成：来源 ios/App/App/MioUserScriptCore.swift（MIO_JS_BEGIN userscriptRuntime）。改那里，然后 node scripts/sync-userscript-runtime.mjs\n' +
    `// MIO_PARAMS ${swiftStringConstant(SWIFT, 'apiParams')}\n` +
    extractFrom(SWIFT, 'userscriptRuntime') +
    '\n'
  );
}
export const TARGETS = ['android/app/src/main/assets/mio-userscript-runtime.js', 'desktop/src/inject/userscript-runtime.js'];

if (process.argv[1] && process.argv[1].endsWith('sync-userscript-runtime.mjs')) {
  const js = renderRuntime();
  let bad = 0;
  for (const t of TARGETS) {
    let cur = '';
    try { cur = readFileSync(repoPath(t), 'utf8'); } catch {}
    if (cur === js) continue;
    if (process.argv.includes('--check')) { console.error(`out of date: ${t}`); bad++; } else { writeFileSync(repoPath(t), js); console.log(`wrote ${t}`); }
  }
  process.exit(bad ? 1 : 0);
}
