'use strict';
// Windows / Electron：共享防沉迷脚本的加载与占位符替换（脚本行为本身在 tools/MioAppTests/js 里用 jsdom 测）
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const yt = require('../src/youtube-focus');
const { SettingsStore } = require('../src/settings-store');

const SHARED = fs.readFileSync(path.join(__dirname, '..', '..', 'shared', 'scripts', 'youtube-focus.js'), 'utf8');

function store() {
  return new SettingsStore(path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'mio-yt-')), 'settings.json'));
}

test('loads the shared script from the repo in dev', () => {
  yt._reset();
  assert.equal(yt.template(), SHARED);
});

test('scriptFor: only YouTube urls, defaults on (60s, Playables hidden)', () => {
  const s = store();
  const js = yt.scriptFor('https://m.youtube.com/', s, SHARED);
  assert.match(js, /Number\('60000'\)/);
  assert.match(js, /'1' !== '0'/);
  assert.doesNotMatch(js, /__MIO_YT_/);
  assert.notEqual(yt.scriptFor('https://www.youtube.com/watch?v=x', s, SHARED), '');
  assert.equal(yt.scriptFor('https://example.com/shorts/x', s, SHARED), '');
  assert.equal(yt.scriptFor('https://youtube.com.evil.example/', s, SHARED), '');
});

test('settings: interval / Playables sub-switch / master switch', () => {
  const s = store();
  s.set('youtubeFocusInterval', 120);
  s.set('youtubeFocusPlayables', false);
  const js = yt.scriptFor('https://www.youtube.com/', s, SHARED);
  assert.match(js, /Number\('120000'\)/);
  assert.match(js, /'0' !== '0'/);
  assert.throws(() => s.set('youtubeFocusInterval', 1));
  assert.throws(() => s.set('youtubeFocusInterval', '60'));
  s.set('youtubeFocus', false);
  assert.equal(yt.scriptFor('https://www.youtube.com/', s, SHARED), '');
});

test('render clamps the interval like iOS / Android', () => {
  assert.match(yt.render(SHARED, 1, true), /Number\('5000'\)/);
  assert.match(yt.render(SHARED, 99999, true), /Number\('3600000'\)/);
  assert.match(yt.render(SHARED, undefined, true), /Number\('60000'\)/);
});

test('electron-builder ships shared/scripts as resources/mio-scripts', () => {
  const pkg = require('../package.json');
  assert.ok(pkg.build.extraResources.some((r) => r.from === '../shared/scripts' && r.to === 'mio-scripts'));
});
