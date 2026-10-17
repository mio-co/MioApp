#!/usr/bin/env node
// 发版清单（软件内更新用）：在 release job 里对 dist/ 里的全部产物生成
//   - SHA256SUMS.txt          sha256sum 格式（"<hex>  <文件名>"），Mac 更新器 / Android 校验用
//   - altstore-source.json    AltStore / SideStore 源（v2 格式），指向本次 Release 的 Mio.ipa
// Android 的签名包 Mio.apk 是发版后本地签名再上传的（keystore 不进 CI），它的 sha256 由
// mioapp-keys/sign-and-upload.sh 另外上传为 Mio.apk.sha256。
//
// 用法：node scripts/release-manifests.mjs --dist dist --tag v0.3.3 [--repo mio-co/MioApp] [--date 2026-10-17T00:00:00Z]
//       [--notes-file notes.md] [--pbxproj ios/App/App.xcodeproj/project.pbxproj] [--plist ios/App/App/Info.plist]
// 纯函数都导出，tools/MioAppTests/js/release-manifests.test.mjs 测。
import { createHash } from 'node:crypto';
import { createReadStream, existsSync, readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import { basename, dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const BUNDLE_ID = 'xyz.mio.app';
export const SUMS_NAME = 'SHA256SUMS.txt';
export const SOURCE_NAME = 'altstore-source.json';
/** 不进 SHA256SUMS 的文件：清单本身 */
const SKIP = new Set([SUMS_NAME]);

export function sha256File(path) {
  return new Promise((ok, fail) => {
    const h = createHash('sha256');
    createReadStream(path).on('data', (d) => h.update(d)).on('error', fail).on('end', () => ok(h.digest('hex')));
  });
}

/** entries: [{ name, sha256 }] → sha256sum 文本（按文件名排序，结尾换行） */
export function formatSha256Sums(entries) {
  const lines = [...entries]
    .sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0))
    .map((e) => {
      if (!/^[0-9a-f]{64}$/.test(e.sha256)) throw new Error(`bad sha256 for ${e.name}`);
      if (/[\r\n]/.test(e.name) || e.name.includes('/')) throw new Error(`bad file name ${e.name}`);
      return `${e.sha256}  ${e.name}`;
    });
  return lines.join('\n') + '\n';
}

/** sha256sum（"hex  name" / "hex *name"）和 BSD（"SHA256 (name) = hex"）格式 → { name: hex } */
export function parseSha256Sums(text) {
  const out = {};
  for (const raw of String(text).split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    let m = /^([0-9a-fA-F]{64}) [ *](.+)$/.exec(line);
    if (m) { out[m[2].trim()] = m[1].toLowerCase(); continue; }
    m = /^SHA256 \((.+)\) = ([0-9a-fA-F]{64})$/.exec(line);
    if (m) out[m[1]] = m[2].toLowerCase();
  }
  return out;
}

/** project.pbxproj → App target 的 MARKETING_VERSION / CURRENT_PROJECT_VERSION / IPHONEOS_DEPLOYMENT_TARGET（取 App target 的值 = 出现次数最多的那个） */
export function readPbxproj(text) {
  const pick = (key) => {
    const counts = new Map();
    for (const m of String(text).matchAll(new RegExp(`\\b${key} = "?([^";]+)"?;`, 'g'))) counts.set(m[1], (counts.get(m[1]) || 0) + 1);
    let best = null;
    for (const [v, n] of counts) if (!best || n > best[1]) best = [v, n];
    return best ? best[0] : null;
  };
  return { marketingVersion: pick('MARKETING_VERSION'), buildVersion: pick('CURRENT_PROJECT_VERSION'), minOSVersion: pick('IPHONEOS_DEPLOYMENT_TARGET') };
}

const xmlUnescape = (s) => s.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&amp;/g, '&');

/** Info.plist（XML）里所有 NS*UsageDescription → { key: 文案 }（AltStore 要求源里列出，和 ipa 不一致会拒绝安装） */
export function readPrivacyDescriptions(plistXml) {
  const out = {};
  for (const m of String(plistXml).matchAll(/<key>(NS[A-Za-z]+UsageDescription)<\/key>\s*<string>([\s\S]*?)<\/string>/g)) out[m[1]] = xmlUnescape(m[2]);
  return out;
}

export function versionFromTag(tag) {
  const m = /^v?(\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?)$/.exec(String(tag || ''));
  if (!m) throw new Error(`tag ${tag} is not vX.Y.Z`);
  return m[1];
}

/** Markdown 发布说明 → 纯文本（AltStore 不渲染 Markdown），截断到 maxLen */
export function plainNotes(md, maxLen = 4000) {
  let t = String(md || '')
    .replace(/\r\n/g, '\n')
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

/**
 * AltStore / SideStore 源（https://faq.altstore.io/developers/make-a-source）。
 * downloadURL 用本次 tag 的固定地址；源本身挂在 Release 上，稳定地址 = releases/latest/download/altstore-source.json
 */
export function buildAltStoreSource({ repo, tag, version, buildVersion, minOSVersion, date, ipaSize, notes, privacy }) {
  if (!repo || !tag || !version) throw new Error('repo / tag / version required');
  if (!Number.isInteger(ipaSize) || ipaSize <= 0) throw new Error('ipa size required');
  const base = `https://github.com/${repo}`;
  const raw = `https://raw.githubusercontent.com/${repo}/main`;
  const app = {
    name: 'Mio',
    bundleIdentifier: BUNDLE_ID,
    developerName: 'Mio',
    subtitle: 'MioCore 客户端 + 内置广告拦截浏览器',
    localizedDescription: 'MioCore（mio.300031.xyz）的 iOS / iPadOS 客户端：后台导航页、内置浏览器（AdGuard 规则广告拦截、YouTube 防沉迷、后台播放）。免签名安装包，由 SideStore / AltStore 用你自己的 Apple ID 签名。',
    iconURL: `${raw}/desktop/assets/icon.png`,
    tintColor: '#F0A3BF',
    category: 'utilities',
    screenshots: [],
    versions: [{
      version,
      buildVersion: String(buildVersion || '1'),
      date,
      localizedDescription: plainNotes(notes) || `Mio ${version}`,
      downloadURL: `${base}/releases/download/${encodeURIComponent(tag)}/Mio.ipa`,
      size: ipaSize,
      ...(minOSVersion ? { minOSVersion: String(minOSVersion) } : {}),
    }],
    // 未签名 ipa：没有嵌入任何 entitlements（SideStore 签名时自己加 application-identifier / team-identifier）
    appPermissions: { entitlements: [], privacy: privacy || {} },
  };
  return {
    name: 'Mio',
    identifier: `${BUNDLE_ID}.source`,
    subtitle: 'Mio 官方源（GitHub Releases）',
    description: `Mio 的 SideStore / AltStore 源，每次发版自动更新。源地址：${base}/releases/latest/download/${SOURCE_NAME}`,
    iconURL: `${raw}/desktop/assets/icon.png`,
    website: base,
    sourceURL: `${base}/releases/latest/download/${SOURCE_NAME}`,
    tintColor: '#F0A3BF',
    nsfw: false,
    featuredApps: [BUNDLE_ID],
    apps: [app],
    news: [],
  };
}

/** 生成清单写进 dist；返回 { sums, source }（source 在没有 Mio.ipa 时为 null） */
export async function generate({ dist, tag, repo = 'mio-co/MioApp', date, notes = '', pbxprojText = '', plistText = '' }) {
  const version = versionFromTag(tag);
  const files = readdirSync(dist).filter((n) => !SKIP.has(n) && statSync(join(dist, n)).isFile());
  let source = null;
  if (files.includes('Mio.ipa')) {
    const pbx = readPbxproj(pbxprojText);
    if (pbx.marketingVersion && pbx.marketingVersion !== version) {
      console.warn(`warning: MARKETING_VERSION ${pbx.marketingVersion} != tag version ${version}`);
    }
    source = buildAltStoreSource({
      repo, tag, version,
      buildVersion: pbx.buildVersion,
      minOSVersion: pbx.minOSVersion,
      date: date || new Date().toISOString(),
      ipaSize: statSync(join(dist, 'Mio.ipa')).size,
      notes,
      privacy: readPrivacyDescriptions(plistText),
    });
    writeFileSync(join(dist, SOURCE_NAME), JSON.stringify(source, null, 2) + '\n');
    if (!files.includes(SOURCE_NAME)) files.push(SOURCE_NAME);
  }
  const entries = [];
  for (const name of files) entries.push({ name, sha256: await sha256File(join(dist, name)) });
  const sums = formatSha256Sums(entries);
  writeFileSync(join(dist, SUMS_NAME), sums);
  return { sums, source };
}

function parseArgs(argv) {
  const a = {};
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    if (!k.startsWith('--')) throw new Error(`unexpected ${k}`);
    a[k.slice(2)] = argv[++i];
  }
  return a;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
  const a = parseArgs(process.argv.slice(2));
  if (!a.dist || !a.tag) {
    console.error('usage: release-manifests.mjs --dist <dir> --tag vX.Y.Z [--repo owner/name] [--date ISO] [--notes-file f]');
    process.exit(2);
  }
  const read = (p) => (p && existsSync(p) ? readFileSync(p, 'utf8') : '');
  const r = await generate({
    dist: resolve(a.dist),
    tag: a.tag,
    repo: a.repo || 'mio-co/MioApp',
    date: a.date,
    notes: read(a['notes-file']),
    pbxprojText: read(a.pbxproj || join(root, 'ios/App/App.xcodeproj/project.pbxproj')),
    plistText: read(a.plist || join(root, 'ios/App/App/Info.plist')),
  });
  process.stdout.write(`${SUMS_NAME}:\n${r.sums}`);
  if (r.source) console.log(`${SOURCE_NAME}: ${r.source.apps[0].versions[0].version} (${r.source.apps[0].versions[0].buildVersion}) → ${r.source.apps[0].versions[0].downloadURL}`);
  else console.log(`${SOURCE_NAME}: skipped (no Mio.ipa in ${basename(a.dist)})`);
}
