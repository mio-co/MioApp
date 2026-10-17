'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { openExternalThenMaybeClose, SETTING_KEY } = require('../src/close-after-external');
const { SettingsStore } = require('../src/settings-store');

test('closes after successful hand-off when enabled', async () => {
  let closed = 0;
  const opened = [];
  const r = await openExternalThenMaybeClose({
    url: 'https://example.com/',
    enabled: true,
    openExternal: async (u) => opened.push(u),
    close: () => closed++,
  });
  assert.deepEqual(r, { opened: true, closed: true });
  assert.deepEqual(opened, ['https://example.com/']);
  assert.equal(closed, 1);
});

test('does not close when disabled', async () => {
  let closed = 0;
  const r = await openExternalThenMaybeClose({ url: 'https://example.com/', enabled: false, openExternal: async () => undefined, close: () => closed++ });
  assert.deepEqual(r, { opened: true, closed: false });
  assert.equal(closed, 0);
});

test('does not close when openExternal rejects', async () => {
  let closed = 0;
  const r = await openExternalThenMaybeClose({
    url: 'https://example.com/',
    enabled: true,
    openExternal: async () => { throw new Error('no handler'); },
    close: () => closed++,
  });
  assert.deepEqual(r, { opened: false, closed: false });
  assert.equal(closed, 0);
});

test('close only after openExternal resolves', async () => {
  const order = [];
  let resolve;
  const p = openExternalThenMaybeClose({
    url: 'https://example.com/',
    enabled: true,
    openExternal: () => new Promise((r) => { resolve = r; order.push('open'); }),
    close: () => order.push('close'),
  });
  await new Promise((r) => setImmediate(r));
  assert.deepEqual(order, ['open']);
  resolve();
  await p;
  assert.deepEqual(order, ['open', 'close']);
});

test('setting defaults off and persists', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mio-closetab-'));
  const file = path.join(dir, 'settings.json');
  const s = new SettingsStore(file);
  assert.equal(s.get(SETTING_KEY), false);
  assert.throws(() => s.set(SETTING_KEY, 'yes'));
  s.set(SETTING_KEY, true);
  assert.equal(new SettingsStore(file).get(SETTING_KEY), true);
});
