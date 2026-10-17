#!/usr/bin/env node
// 共享注入脚本的单一来源：shared/scripts/*.js
// - Android：app/build.gradle 把 shared/ 加进 assets（APK 里是 assets/scripts/<name>.js），不复制
// - Windows / Electron：开发时直接读 ../shared/scripts，打包时 electron-builder extraResources → resources/mio-scripts
// - iOS / Mac：Swift 里内嵌同一份（MioWebCompat.swift 的 MIO_JS_BEGIN/END 段，WKUserScript 需要字符串常量）。
//   本脚本把共享文件写回 Swift 段；`--check` 只校验一致（CI unit job 跑），不一致时退出 1。
// 用法：node scripts/sync-shared-scripts.mjs [--check]
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const ROOT = fileURLToPath(new URL('..', import.meta.url));
const SWIFT = `${ROOT}ios/App/App/MioWebCompat.swift`;
// 共享文件 → Swift 段名 / 常量名
const MAP = [{ file: 'shared/scripts/youtube-focus.js', block: 'youtubeFocus', constant: 'youtubeFocusScriptTemplate' }];
const INDENT = '    ';

export function renderSwiftBlock(js, constant) {
  if (js.includes('"""#')) throw new Error('script must not contain """#');
  const body = js.replace(/\n$/, '').split('\n').map((l) => (l.length ? INDENT + l : l)).join('\n');
  return `${INDENT}static let ${constant} = #"""\n${body}\n${INDENT}"""#\n`;
}

export function syncSwift(swiftSrc, js, block, constant) {
  const begin = `${INDENT}// MIO_JS_BEGIN ${block}\n`;
  const end = `${INDENT}// MIO_JS_END ${block}`;
  const b = swiftSrc.indexOf(begin);
  const e = swiftSrc.indexOf(end);
  if (b < 0 || e < 0 || e < b) throw new Error(`block ${block} not found in MioWebCompat.swift`);
  return swiftSrc.slice(0, b + begin.length) + renderSwiftBlock(js, constant) + swiftSrc.slice(e);
}

const isMain = process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1];
if (isMain) {
  const check = process.argv.includes('--check');
  let swift = readFileSync(SWIFT, 'utf8');
  const before = swift;
  for (const m of MAP) swift = syncSwift(swift, readFileSync(`${ROOT}${m.file}`, 'utf8'), m.block, m.constant);
  if (swift === before) {
    console.log('shared scripts: MioWebCompat.swift up to date');
  } else if (check) {
    console.error('shared scripts: MioWebCompat.swift is out of sync with shared/scripts — run `node scripts/sync-shared-scripts.mjs`');
    process.exit(1);
  } else {
    writeFileSync(SWIFT, swift);
    console.log('shared scripts: MioWebCompat.swift updated');
  }
}
