'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { WebRtcControl, normalize, entryFor } = require('../src/webrtc');

test('normalize / entryFor', () => {
  assert.equal(normalize(' https://www.Meet.Google.com/abc?x '), 'meet.google.com');
  assert.equal(normalize('user@zoom.us:443'), 'zoom.us');
  assert.equal(entryFor('a.meet.google.com', ['meet.google.com']), 'meet.google.com');
  assert.equal(entryFor('evilmeet.google.com', ['meet.google.com']), null);
  assert.equal(entryFor('', ['x.com']), null);
});

test('默认开；放行站点（顶层或 frame 自身）不注入；策略 disable_non_proxied_udp', () => {
  const file = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'mio-rtc-')), 'webrtc.json');
  const c = new WebRtcControl(file);
  assert.equal(c.enabled, true);
  const js = c.scriptFor('https://www.example.com/', 'https://www.example.com/');
  assert.ok(js && js.includes('var CFG = {"allow":[]};'));
  assert.equal(c.policyFor('https://www.example.com/'), 'disable_non_proxied_udp');
  c.setAllowed('https://meet.google.com/x', true);
  assert.equal(c.scriptFor('https://meet.google.com/x', 'https://meet.google.com/x'), null);
  assert.equal(c.scriptFor('https://ads.example/x', 'https://meet.google.com/'), null);
  assert.equal(c.scriptFor('https://meet.google.com/embed', 'https://other.org/'), null);
  assert.ok(c.scriptFor('https://other.org/', 'https://other.org/').includes('"allow":["meet.google.com"]'));
  assert.equal(c.policyFor('https://a.meet.google.com/'), 'default');
  // 持久化
  const c2 = new WebRtcControl(file);
  assert.deepEqual(c2.allowlist, ['meet.google.com']);
  c2.setAllowed('a.meet.google.com', false);
  assert.deepEqual(c2.allowlist, []);
  c2.setEnabled(false);
  assert.equal(new WebRtcControl(file).scriptFor('https://x.org/', 'https://x.org/'), null);
  assert.equal(new WebRtcControl(file).policyFor('https://x.org/'), 'default');
});
