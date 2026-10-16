'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { SettingsStore } = require('../src/settings-store');

test('settings persist, whitelist, site toggle', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mio-settings-'));
  const file = path.join(dir, 'settings.json');
  const s = new SettingsStore(file);
  assert.equal(s.get('adblockEnabled'), true);
  assert.throws(() => s.set('adblockEnabled', 'no'));
  assert.throws(() => s.set('evil', true));
  s.set('preferSystemBrowser', true);
  assert.equal(s.addWhitelist('https://www.example.com/x'), 'example.com');
  assert.ok(s.isWhitelisted('example.com'));
  assert.ok(s.isWhitelisted('a.example.com'));
  assert.ok(!s.isWhitelisted('example.org'));
  s.setSiteEnabled('m.example.com', true); // 启用 → 去掉匹配的白名单条目
  assert.ok(!s.isWhitelisted('example.com'));
  s.setSiteEnabled('news.site.cn', false);
  assert.deepEqual(s.get('whitelist'), ['news.site.cn']);
  const s2 = new SettingsStore(file);
  assert.equal(s2.get('preferSystemBrowser'), true);
  assert.deepEqual(s2.get('whitelist'), ['news.site.cn']);
  fs.writeFileSync(file, '{broken');
  assert.equal(new SettingsStore(file).get('adblockEnabled'), true);
});
