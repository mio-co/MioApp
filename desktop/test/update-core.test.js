'use strict';
// 软件内更新纯逻辑（src/update-core.js）
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const c = require('../src/update-core');

test('compareVersions: semver order, v prefix, missing parts, prerelease', () => {
  assert.equal(c.compareVersions('0.3.3', '0.3.2'), 1);
  assert.equal(c.compareVersions('v0.3.2', '0.3.2'), 0);
  assert.equal(c.compareVersions('0.3', '0.3.0'), 0);
  assert.equal(c.compareVersions('0.10.0', '0.9.9'), 1);
  assert.equal(c.compareVersions('1.0.0', '1.0.0-beta.2'), 1);
  assert.equal(c.compareVersions('1.0.0-beta.2', '1.0.0-beta.10'), -1);
  assert.equal(c.compareVersions('1.0.0-alpha', '1.0.0-alpha.1'), -1);
  assert.equal(c.compareVersions('1.0.0-alpha.beta', '1.0.0-alpha.1'), 1);
  assert.equal(c.compareVersions('1.0.0+build.5', '1.0.0'), 0);
  assert.equal(c.compareVersions('1.2.3.4', '1.2.3'), 1);
  assert.equal(c.compareVersions('latest', '1.0.0'), null);
  assert.equal(c.compareVersions('', '1.0.0'), null);
  assert.ok(c.isNewer('v0.3.3', '0.3.2'));
  assert.ok(!c.isNewer('v0.3.2', '0.3.2'));
  assert.ok(!c.isNewer('garbage', '0.3.2'));
});

const RELEASE = {
  tag_name: 'v0.3.3',
  name: 'Mio v0.3.3',
  body: '## 新功能\n- **软件内更新**',
  html_url: 'https://github.com/mio-co/MioApp/releases/tag/v0.3.3',
  draft: false,
  prerelease: false,
  published_at: '2026-10-17T00:00:00Z',
  assets: [
    { name: 'Mio-Setup-0.3.3-x64.exe', browser_download_url: 'https://github.com/x/Mio-Setup-0.3.3-x64.exe', size: 10, digest: 'sha256:' + 'a'.repeat(64) },
    { name: 'SHA256SUMS.txt', browser_download_url: 'https://github.com/x/SHA256SUMS.txt', size: 100 },
    { name: 42 },
  ],
};

test('parseRelease', () => {
  const r = c.parseRelease(JSON.stringify(RELEASE));
  assert.equal(r.version, '0.3.3');
  assert.equal(r.tag, 'v0.3.3');
  assert.equal(r.url, RELEASE.html_url);
  assert.equal(r.assets.length, 2);
  assert.equal(c.findAsset(r, /^Mio-Setup-.*\.exe$/).size, 10);
  assert.equal(c.findAsset(r, 'nope'), null);
  assert.equal(c.parseRelease({ ...RELEASE, prerelease: true }), null);
  assert.equal(c.parseRelease({ ...RELEASE, draft: true }), null);
  assert.equal(c.parseRelease({ ...RELEASE, tag_name: 'nightly' }), null);
  assert.equal(c.parseRelease({ ...RELEASE, html_url: 'https://evil.example/' }).url, c.RELEASES_PAGE);
});

test('parseSha256Sums + expectedSha256 (manifest, digest, mismatch, missing)', () => {
  const h = crypto.createHash('sha256').update('x').digest('hex');
  const sums = c.parseSha256Sums(`${h}  Mio-0.3.3-mac.zip\n${'b'.repeat(64)} *Mio.ipa\n`);
  assert.equal(sums['Mio-0.3.3-mac.zip'], h);
  assert.equal(c.parseSha256Sums(`${h.toUpperCase()}\n`)[''], h);
  assert.equal(c.expectedSha256({ name: 'Mio-0.3.3-mac.zip' }, sums), h);
  assert.equal(c.expectedSha256({ name: 'Mio-0.3.3-mac.zip', digest: 'sha256:' + h }, sums), h);
  assert.equal(c.expectedSha256({ name: 'other', digest: 'sha256:' + h.toUpperCase() }, sums), h);
  assert.throws(() => c.expectedSha256({ name: 'Mio-0.3.3-mac.zip', digest: 'sha256:' + 'c'.repeat(64) }, sums), /不一致/);
  assert.throws(() => c.expectedSha256({ name: 'other' }, sums), /没有/);
  assert.throws(() => c.expectedSha256({ name: 'other', digest: 'md5:abc' }, null), /没有/);
});

test('sha256File / verifySha256', async () => {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), 'mio-upd-'));
  const f = path.join(d, 'f.bin');
  const buf = crypto.randomBytes(3 * 1024 * 1024 + 7);
  fs.writeFileSync(f, buf);
  const h = crypto.createHash('sha256').update(buf).digest('hex');
  assert.equal(await c.sha256File(f), h);
  assert.ok(await c.verifySha256(f, h.toUpperCase()));
  assert.ok(!(await c.verifySha256(f, '0'.repeat(64))));
});

test('shouldAutoCheck: 24h interval, 1h retry backoff, switch, clock skew', () => {
  const H = 3600 * 1000;
  const now = 100 * 24 * H;
  assert.ok(c.shouldAutoCheck({ autoCheck: true, lastCheck: 0, lastAttempt: 0 }, now));
  assert.ok(!c.shouldAutoCheck({ autoCheck: false, lastCheck: 0, lastAttempt: 0 }, now));
  assert.ok(!c.shouldAutoCheck({ autoCheck: true, lastCheck: now - 23 * H, lastAttempt: now - 23 * H }, now));
  assert.ok(c.shouldAutoCheck({ autoCheck: true, lastCheck: now - 25 * H, lastAttempt: now - 2 * H }, now));
  assert.ok(!c.shouldAutoCheck({ autoCheck: true, lastCheck: now - 25 * H, lastAttempt: now - 0.5 * H }, now));
  assert.ok(c.shouldAutoCheck({ autoCheck: true, lastCheck: now + 5 * H, lastAttempt: now + 5 * H }, now));
});

test('updateMode: NSIS only for packaged non-portable Windows', () => {
  assert.equal(c.updateMode({ platform: 'win32', packaged: true, env: {} }), 'nsis');
  assert.equal(c.updateMode({ platform: 'win32', packaged: true, env: { PORTABLE_EXECUTABLE_DIR: 'C:\\x' } }), 'page');
  assert.equal(c.updateMode({ platform: 'win32', packaged: false, env: {} }), 'page');
  assert.equal(c.updateMode({ platform: 'darwin', packaged: true, env: {} }), 'page');
});

test('plainNotes strips markdown / html', () => {
  assert.equal(c.plainNotes('## 新功能\n- **软件内更新** `x`'), '新功能\n- 软件内更新 x');
  assert.equal(c.plainNotes('<h2>A</h2><ul><li>b &amp; c</li></ul>'), 'A\n- b & c');
  assert.equal(c.plainNotes('y'.repeat(20), 5).length, 5);
});
