// 发版清单生成（scripts/release-manifests.mjs）：SHA256SUMS.txt + AltStore / SideStore 源
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  buildAltStoreSource, formatSha256Sums, generate, parseSha256Sums, plainNotes,
  readPbxproj, readPrivacyDescriptions, sha256File, versionFromTag,
} from '../../../scripts/release-manifests.mjs';

const ROOT = fileURLToPath(new URL('../../../', import.meta.url));
const sha = (s) => createHash('sha256').update(s).digest('hex');

test('sha256File matches known vectors', async () => {
  const d = mkdtempSync(join(tmpdir(), 'mio-rm-'));
  writeFileSync(join(d, 'abc'), 'abc');
  writeFileSync(join(d, 'empty'), '');
  assert.equal(await sha256File(join(d, 'abc')), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
  assert.equal(await sha256File(join(d, 'empty')), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
});

test('SHA256SUMS format round-trips and is sorted', () => {
  const text = formatSha256Sums([{ name: 'b.zip', sha256: sha('b') }, { name: 'Mio.ipa', sha256: sha('i') }, { name: 'a.exe', sha256: sha('a') }]);
  assert.deepEqual(text.trim().split('\n').map((l) => l.split('  ')[1]), ['Mio.ipa', 'a.exe', 'b.zip']);
  assert.deepEqual(parseSha256Sums(text), { 'Mio.ipa': sha('i'), 'a.exe': sha('a'), 'b.zip': sha('b') });
  assert.throws(() => formatSha256Sums([{ name: 'x', sha256: 'nothex' }]));
  assert.throws(() => formatSha256Sums([{ name: 'a/b', sha256: sha('x') }]));
});

test('parseSha256Sums accepts binary marker, BSD format, CRLF, comments, uppercase', () => {
  const h = sha('x');
  const text = `# comment\r\n${h.toUpperCase()} *Mio.apk\r\nSHA256 (Mio-0.3.3-mac.zip) = ${h}\n\ngarbage line\n`;
  assert.deepEqual(parseSha256Sums(text), { 'Mio.apk': h, 'Mio-0.3.3-mac.zip': h });
});

test('readPbxproj picks App target values from the real project', () => {
  const p = readPbxproj(readFileSync(join(ROOT, 'ios/App/App.xcodeproj/project.pbxproj'), 'utf8'));
  assert.match(p.marketingVersion, /^\d+\.\d+\.\d+$/);
  assert.match(p.buildVersion, /^\d+$/);
  assert.match(p.minOSVersion, /^\d+\.\d+$/);
});

test('readPrivacyDescriptions reads every NS*UsageDescription from the real Info.plist', () => {
  const priv = readPrivacyDescriptions(readFileSync(join(ROOT, 'ios/App/App/Info.plist'), 'utf8'));
  assert.ok(priv.NSCameraUsageDescription);
  assert.ok(Object.keys(priv).every((k) => /^NS\w+UsageDescription$/.test(k)));
  assert.deepEqual(readPrivacyDescriptions('<key>NSFooUsageDescription</key>\n<string>a &amp; b</string>'), { NSFooUsageDescription: 'a & b' });
});

test('versionFromTag', () => {
  assert.equal(versionFromTag('v0.3.3'), '0.3.3');
  assert.equal(versionFromTag('1.2.3-beta.1'), '1.2.3-beta.1');
  assert.throws(() => versionFromTag('main'));
});

test('plainNotes strips markdown and truncates', () => {
  assert.equal(plainNotes('## 新功能\n- **粗体** `code` [链接](https://x)\n\n\n\nend'), '新功能\n- 粗体 code 链接\n\nend');
  assert.equal(plainNotes('x'.repeat(50), 10).length, 10);
});

test('AltStore source has the v2 required shape', () => {
  const s = buildAltStoreSource({ repo: 'mio-co/MioApp', tag: 'v0.3.3', version: '0.3.3', buildVersion: '8', minOSVersion: '15.0', date: '2026-10-17T00:00:00Z', ipaSize: 1234, notes: '# hi', privacy: { NSCameraUsageDescription: 'c' } });
  assert.equal(s.name, 'Mio');
  assert.equal(s.identifier, 'xyz.mio.app.source');
  assert.equal(s.sourceURL, 'https://github.com/mio-co/MioApp/releases/latest/download/altstore-source.json');
  assert.equal(s.apps.length, 1);
  const app = s.apps[0];
  assert.equal(app.bundleIdentifier, 'xyz.mio.app');
  for (const k of ['name', 'developerName', 'localizedDescription', 'iconURL', 'versions', 'appPermissions']) assert.ok(k in app, k);
  // 图标按 tag 固定，且仓库里确实有这个文件
  assert.equal(app.iconURL, 'https://raw.githubusercontent.com/mio-co/MioApp/v0.3.3/assets/icon.png');
  assert.equal(s.iconURL, app.iconURL);
  assert.ok(existsSync(join(ROOT, 'assets/icon.png')));
  const v = app.versions[0];
  assert.deepEqual(
    { version: v.version, buildVersion: v.buildVersion, date: v.date, downloadURL: v.downloadURL, size: v.size, minOSVersion: v.minOSVersion },
    { version: '0.3.3', buildVersion: '8', date: '2026-10-17T00:00:00Z', downloadURL: 'https://github.com/mio-co/MioApp/releases/download/v0.3.3/Mio.ipa', size: 1234, minOSVersion: '15.0' },
  );
  assert.equal(v.localizedDescription, 'hi');
  assert.deepEqual(app.appPermissions, { entitlements: [], privacy: { NSCameraUsageDescription: 'c' } });
  assert.throws(() => buildAltStoreSource({ repo: 'a/b', tag: 'v1.0.0', version: '1.0.0', ipaSize: 0 }));
});

test('generate writes SHA256SUMS.txt (covering altstore-source.json) and the source into dist', async () => {
  const d = mkdtempSync(join(tmpdir(), 'mio-dist-'));
  writeFileSync(join(d, 'Mio.ipa'), 'ipa-bytes');
  writeFileSync(join(d, 'Mio-0.3.3-mac.zip'), 'zip-bytes');
  writeFileSync(join(d, 'Mio-0.3.3-mac.dmg'), 'dmg-bytes');
  writeFileSync(join(d, 'SHA256SUMS.txt'), 'stale');
  const r = await generate({
    dist: d, tag: 'v0.3.3', date: '2026-10-17T00:00:00Z', notes: 'notes',
    pbxprojText: readFileSync(join(ROOT, 'ios/App/App.xcodeproj/project.pbxproj'), 'utf8'),
    plistText: readFileSync(join(ROOT, 'ios/App/App/Info.plist'), 'utf8'),
  });
  const sums = parseSha256Sums(readFileSync(join(d, 'SHA256SUMS.txt'), 'utf8'));
  assert.deepEqual(Object.keys(sums).sort(), ['Mio-0.3.3-mac.dmg', 'Mio-0.3.3-mac.zip', 'Mio.ipa', 'altstore-source.json']);
  assert.equal(sums['Mio-0.3.3-mac.zip'], sha('zip-bytes'));
  assert.equal(sums['altstore-source.json'], sha(readFileSync(join(d, 'altstore-source.json'))));
  const src = JSON.parse(readFileSync(join(d, 'altstore-source.json'), 'utf8'));
  assert.equal(src.apps[0].versions[0].size, 'ipa-bytes'.length);
  assert.equal(r.source.apps[0].versions[0].version, '0.3.3');

  const d2 = mkdtempSync(join(tmpdir(), 'mio-dist-'));
  writeFileSync(join(d2, 'a.exe'), 'a');
  const r2 = await generate({ dist: d2, tag: 'v1.0.0' });
  assert.equal(r2.source, null);
  assert.deepEqual(Object.keys(parseSha256Sums(r2.sums)), ['a.exe']);
});

test('v0.4.x: iOS version info comes from the apple/ios fork (xcconfig + Info.plist)', async () => {
  const { readIOSFork, readXcconfig } = await import('../../../scripts/release-manifests.mjs');
  const fs = await import('node:fs');
  const root = new URL('../../../apple/ios/firefox-ios/', import.meta.url);
  const info = readIOSFork({
    versionXcconfig: fs.readFileSync(new URL('Client/Configuration/version.xcconfig', root), 'utf8'),
    commonXcconfig: fs.readFileSync(new URL('Client/Configuration/Common.xcconfig', root), 'utf8'),
    plistText: fs.readFileSync(new URL('Client/Info.plist', root), 'utf8'),
  });
  // fork version = package.json version (Mac uses package.json); v0.4.1 = build 11
  const pkg = JSON.parse(fs.readFileSync(new URL('../../../package.json', import.meta.url), 'utf8'));
  assert.deepEqual(info, { marketingVersion: pkg.version, buildVersion: '11', minOSVersion: '15.0' });
  assert.equal(readXcconfig('A = 1 // c\nA = 2\nB[sdk=iphoneos*] = x').A, '1');
  assert.equal(readIOSFork({ plistText: '<key>CFBundleVersion</key><string>$(BUILD)</string>' }).buildVersion, null);
});
