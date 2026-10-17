'use strict';
// 软件内更新：纯逻辑（版本比较、GitHub Release 解析、sha256 清单、检查节奏）。不依赖 Electron，test/update-core.test.js 测。
// 与 Android（xyz.mio.app.update.UpdateLogic）、iOS / Mac（MioUpdateCore.swift）同一套规则。
const crypto = require('node:crypto');
const fs = require('node:fs');

const REPO = 'mio-co/MioApp';
const LATEST_API = `https://api.github.com/repos/${REPO}/releases/latest`;
const RELEASES_PAGE = `https://github.com/${REPO}/releases/latest`;
const CHECK_INTERVAL_MS = 24 * 3600 * 1000;
/** 检查失败后至少隔这么久再自动重试（避免每次切回前台都打 API；未认证限额 60 次/小时） */
const RETRY_INTERVAL_MS = 3600 * 1000;

/** "v1.2.3-beta.1+build" → { core: [1,2,3], pre: ['beta', 1] }；不合法返回 null */
function parseVersion(input) {
  const m = /^\s*[vV]?(\d+(?:\.\d+){0,3})(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?\s*$/.exec(String(input == null ? '' : input));
  if (!m) return null;
  const core = m[1].split('.').map((n) => parseInt(n, 10));
  while (core.length < 3) core.push(0);
  const pre = m[2] ? m[2].split('.').map((p) => (/^\d+$/.test(p) ? parseInt(p, 10) : p)) : [];
  return { core, pre };
}

/** semver 比较：a<b → -1，相等 0，a>b → 1；任一不合法返回 null */
function compareVersions(a, b) {
  const x = parseVersion(a);
  const y = parseVersion(b);
  if (!x || !y) return null;
  const n = Math.max(x.core.length, y.core.length);
  for (let i = 0; i < n; i++) {
    const d = (x.core[i] || 0) - (y.core[i] || 0);
    if (d) return d < 0 ? -1 : 1;
  }
  // 有预发布标签的版本 < 正式版
  if (!x.pre.length && !y.pre.length) return 0;
  if (!x.pre.length) return 1;
  if (!y.pre.length) return -1;
  for (let i = 0; i < Math.max(x.pre.length, y.pre.length); i++) {
    const p = x.pre[i];
    const q = y.pre[i];
    if (p === undefined) return -1;
    if (q === undefined) return 1;
    if (p === q) continue;
    const pn = typeof p === 'number';
    const qn = typeof q === 'number';
    if (pn && qn) return p < q ? -1 : 1;
    if (pn) return -1;
    if (qn) return 1;
    return p < q ? -1 : 1;
  }
  return 0;
}

const isNewer = (remote, current) => compareVersions(remote, current) === 1;

/** GitHub releases/latest JSON → 精简结构；不合法 / 草稿 / 预发布返回 null */
function parseRelease(json) {
  const r = typeof json === 'string' ? JSON.parse(json) : json;
  if (!r || typeof r !== 'object' || r.draft || r.prerelease) return null;
  const tag = typeof r.tag_name === 'string' ? r.tag_name : '';
  const v = parseVersion(tag);
  if (!v) return null;
  const version = tag.replace(/^[vV]/, '');
  const assets = Array.isArray(r.assets) ? r.assets.filter((a) => a && typeof a.name === 'string').map((a) => ({
    name: a.name,
    url: typeof a.browser_download_url === 'string' ? a.browser_download_url : '',
    size: Number.isFinite(a.size) ? a.size : 0,
    digest: typeof a.digest === 'string' ? a.digest : null,
  })) : [];
  return {
    tag,
    version,
    name: typeof r.name === 'string' && r.name ? r.name : tag,
    notes: typeof r.body === 'string' ? r.body : '',
    url: typeof r.html_url === 'string' && r.html_url.startsWith('https://github.com/') ? r.html_url : RELEASES_PAGE,
    publishedAt: typeof r.published_at === 'string' ? r.published_at : null,
    assets,
  };
}

const findAsset = (release, test) => (release ? release.assets.find((a) => (typeof test === 'string' ? a.name === test : test.test(a.name))) : undefined) || null;

/** sha256sum / BSD 格式 → { name: hex }（与 scripts/release-manifests.mjs 相同规则） */
function parseSha256Sums(text) {
  const out = {};
  for (const raw of String(text || '').split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    let m = /^([0-9a-fA-F]{64}) [ *](.+)$/.exec(line);
    if (m) { out[m[2].trim()] = m[1].toLowerCase(); continue; }
    m = /^SHA256 \((.+)\) = ([0-9a-fA-F]{64})$/.exec(line);
    if (m) { out[m[1]] = m[2].toLowerCase(); continue; }
    // 单独一行 hex（Mio.apk.sha256 也可能只有哈希）
    if (/^[0-9a-fA-F]{64}$/.test(line)) out[''] = line.toLowerCase();
  }
  return out;
}

/**
 * 某个资产的期望 sha256：清单（SHA256SUMS.txt / <name>.sha256）+ GitHub 资产 digest（"sha256:hex"），
 * 两边都有时必须一致；都没有时抛错（拒绝安装未校验的文件）。
 */
function expectedSha256(asset, sums) {
  const fromSums = sums ? (sums[asset.name] || sums[''] || null) : null;
  const m = asset.digest ? /^sha256:([0-9a-fA-F]{64})$/.exec(asset.digest) : null;
  const fromDigest = m ? m[1].toLowerCase() : null;
  if (fromSums && fromDigest && fromSums !== fromDigest) throw new Error(`${asset.name} 的 SHA-256 清单与 GitHub 记录不一致`);
  const v = fromSums || fromDigest;
  if (!v) throw new Error(`${asset.name} 没有 SHA-256 校验值`);
  return v;
}

function sha256File(path) {
  return new Promise((ok, fail) => {
    const h = crypto.createHash('sha256');
    fs.createReadStream(path).on('data', (d) => h.update(d)).on('error', fail).on('end', () => ok(h.digest('hex')));
  });
}

async function verifySha256(path, expected) {
  const got = await sha256File(path);
  return got === String(expected || '').toLowerCase();
}

/** 是否该自动检查：开关打开、距上次成功检查 ≥ 24h、距上次尝试 ≥ 1h */
function shouldAutoCheck(state, now = Date.now()) {
  if (!state || state.autoCheck === false) return false;
  const last = Number(state.lastCheck) || 0;
  const attempt = Number(state.lastAttempt) || 0;
  if (now - attempt < RETRY_INTERVAL_MS && attempt <= now) return false;
  return now - last >= CHECK_INTERVAL_MS || last > now;
}

/** electron-builder portable 版启动时会设置 PORTABLE_EXECUTABLE_DIR / _FILE */
const isPortable = (env = process.env) => !!(env.PORTABLE_EXECUTABLE_DIR || env.PORTABLE_EXECUTABLE_FILE);

/** 更新方式：nsis = electron-updater 下载安装；page = 只提示并打开下载页 */
function updateMode({ platform = process.platform, packaged = true, env = process.env } = {}) {
  if (platform === 'win32' && packaged && !isPortable(env)) return 'nsis';
  return 'page';
}

/** Markdown / HTML 发布说明 → 对话框里的纯文本 */
function plainNotes(text, maxLen = 1500) {
  let t = String(text || '')
    .replace(/\r\n/g, '\n')
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<\/(p|li|h\d)>/gi, '\n')
    .replace(/<li[^>]*>/gi, '- ')
    .replace(/<[^>]+>/g, '')
    .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&amp;/g, '&')
    .replace(/```[\s\S]*?```/g, '')
    .replace(/^#{1,6}\s*/gm, '')
    .replace(/\*\*([^*]+)\*\*/g, '$1')
    .replace(/`([^`]+)`/g, '$1')
    .replace(/\[([^\]]+)\]\(([^)]+)\)/g, '$1')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
  if (t.length > maxLen) t = t.slice(0, maxLen - 1) + '…';
  return t;
}

module.exports = {
  REPO, LATEST_API, RELEASES_PAGE, CHECK_INTERVAL_MS, RETRY_INTERVAL_MS,
  parseVersion, compareVersions, isNewer, parseRelease, findAsset, parseSha256Sums, expectedSha256,
  sha256File, verifySha256, shouldAutoCheck, isPortable, updateMode, plainNotes,
};
