#!/usr/bin/env node
// 从 ios/App/App/MioUpdateCore.swift 抽出 Mac 更新辅助脚本（MIO_SH_BEGIN/END mac-install 段的 #"""…"""# 原样字符串）。
// 单测（mac-install-script.test.mjs）和 CI 的 Mac 任务（实际跑一遍替换流程）共用。
// 用法：node tools/MioAppTests/js/mac-install-script.mjs > install.sh
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const SWIFT = fileURLToPath(new URL('../../../ios/App/App/MioUpdateCore.swift', import.meta.url));

export function extractMacInstallScript(src = readFileSync(SWIFT, 'utf8')) {
  const begin = src.indexOf('// MIO_SH_BEGIN mac-install');
  const end = src.indexOf('// MIO_SH_END mac-install');
  if (begin < 0 || end < 0) throw new Error('mac-install script markers not found');
  const block = src.slice(begin, end);
  const open = block.indexOf('#"""');
  const close = block.lastIndexOf('"""#');
  const body = block.slice(block.indexOf('\n', open) + 1, close);
  // Swift 多行字符串按结束分隔符的缩进去掉前导空白；最后一行（只有缩进）不属于内容
  const indent = /\n([ \t]*)$/.exec(body)?.[1] ?? '';
  const lines = body.split('\n');
  lines.pop();
  return lines.map((l) => (l.startsWith(indent) ? l.slice(indent.length) : l)).join('\n');
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  process.stdout.write(extractMacInstallScript() + '\n');
}
