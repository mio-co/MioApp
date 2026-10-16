'use strict';
// 起始地址必须是 https://mio.300031.xyz/mio/nav（安卓 v0.3.0 曾拼成 https://mio.300031.xyzmio/nav）
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const config = require('../src/config');

const EXPECTED = 'https://mio.300031.xyz/mio/nav';

test('desktop START_URL', () => {
  assert.strictEqual(config.START_URL, EXPECTED);
  const u = new URL(config.START_URL);
  assert.strictEqual(u.host, 'mio.300031.xyz');
  assert.strictEqual(u.pathname, '/mio/nav');
});

test('capacitor.config.json server.url + appStartPath (Capacitor Android 直接字符串拼接) = START_URL', () => {
  const cap = JSON.parse(fs.readFileSync(path.join(__dirname, '..', '..', 'capacitor.config.json'), 'utf8'));
  assert.strictEqual(cap.server.url + cap.server.appStartPath, EXPECTED);
  assert.strictEqual(new URL(cap.server.appStartPath, cap.server.url).toString(), EXPECTED);
});

test('Mac (MioShellTheme.home) start URL', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', '..', 'ios', 'App', 'App', 'AppDelegate.swift'), 'utf8');
  const m = src.match(/static let home = URL\(string: "([^"]+)"\)/);
  assert.ok(m, 'MioShellTheme.home not found');
  assert.strictEqual(m[1], EXPECTED);
});
