// 从任意 Swift 文件抽出 MIO_JS_BEGIN/END 段里的 #"""…"""# 原样字符串（与 harness.mjs 的 extractScript 相同规则，可指定文件）
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

export const repoPath = (rel) => fileURLToPath(new URL(`../../../${rel}`, import.meta.url));

export function extractFrom(swiftRel, name) {
  const src = readFileSync(repoPath(swiftRel), 'utf8');
  const begin = src.indexOf(`// MIO_JS_BEGIN ${name}`);
  const end = src.indexOf(`// MIO_JS_END ${name}`);
  if (begin < 0 || end < 0) throw new Error(`script ${name} not found in ${swiftRel}`);
  const block = src.slice(begin, end);
  const open = block.indexOf('#"""');
  const close = block.lastIndexOf('"""#');
  const body = block.slice(block.indexOf('\n', open) + 1, close);
  const indent = /\n([ \t]*)$/.exec(body)?.[1] ?? '';
  return body.split('\n').map((l) => (l.startsWith(indent) ? l.slice(indent.length) : l)).join('\n');
}

/// Swift 里 `static let <name> = "..."` 的单行字符串
export function swiftStringConstant(swiftRel, name) {
  const src = readFileSync(repoPath(swiftRel), 'utf8');
  const m = new RegExp(`static let ${name} = "((?:[^"\\\\]|\\\\.)*)"`).exec(src);
  if (!m) throw new Error(`constant ${name} not found`);
  return m[1];
}
