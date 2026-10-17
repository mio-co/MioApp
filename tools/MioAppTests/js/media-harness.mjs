// 从 ios/App/App/MioMediaScripts.swift 抽出注入页面的 JS（MIO_JS_BEGIN/END 段里的 #"""…"""# 原样字符串）。
// 与 harness.mjs 的 extractScript 同样的规则，只是换了文件（避免改动共享的 harness.mjs）。
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

export const MEDIA_SWIFT = fileURLToPath(new URL('../../../ios/App/App/MioMediaScripts.swift', import.meta.url));

export function extractMediaScript(name) {
  const src = readFileSync(MEDIA_SWIFT, 'utf8');
  const begin = src.indexOf(`// MIO_JS_BEGIN ${name}`);
  const end = src.indexOf(`// MIO_JS_END ${name}`);
  if (begin < 0 || end < 0) throw new Error(`script ${name} not found`);
  const block = src.slice(begin, end);
  const open = block.indexOf('#"""');
  const close = block.lastIndexOf('"""#');
  const body = block.slice(block.indexOf('\n', open) + 1, close);
  const indent = /\n([ \t]*)$/.exec(body)?.[1] ?? '';
  return body.split('\n').map((l) => (l.startsWith(indent) ? l.slice(indent.length) : l)).join('\n');
}

/// 与 MioMediaScripts.Config.json 相同的键
export function mediaConfig(over = {}) {
  return {
    platform: 'ios', background: true, nowPlaying: true, pip: true, sponsorBlock: true,
    categories: ['sponsor', 'selfpromo', 'interaction'], ...over,
  };
}

export function mediaScript(cfg = mediaConfig()) {
  return extractMediaScript('youtubeMedia').replace('__MIO_MEDIA_CONFIG__', JSON.stringify(cfg));
}
