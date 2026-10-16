// 通行密钥提示脚本（MioWebCompat.passkeyHintScript）：只观察 WebAuthn 失败并通知原生，不改变页面拿到的结果
import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import { extractScript } from './harness.mjs';

const SCRIPT = extractScript('passkeyHint');

function setup(impl) {
  const posted = [];
  const credentials = { get: impl, create: impl };
  const window = { webkit: { messageHandlers: { mioPasskey: { postMessage: (m) => posted.push(m) } } } };
  window.navigator = { credentials };
  const ctx = vm.createContext({ window, location: { hostname: 'example.com' }, Object, String });
  vm.runInContext(SCRIPT, ctx);
  return { credentials, posted };
}

const notAllowed = () => Promise.reject(Object.assign(new Error('denied'), { name: 'NotAllowedError' }));
const tick = () => new Promise((r) => setTimeout(r, 0));

test('WebAuthn get() failure is reported and still rejects for the page', async () => {
  const { credentials, posted } = setup(notAllowed);
  await assert.rejects(credentials.get({ publicKey: {} }), { name: 'NotAllowedError' });
  await tick();
  assert.deepEqual(JSON.parse(JSON.stringify(posted)), [{ method: 'get', error: 'NotAllowedError', host: 'example.com' }]);
});

test('create() failure is reported', async () => {
  const { credentials, posted } = setup(notAllowed);
  await assert.rejects(credentials.create({ publicKey: {} }));
  await tick();
  assert.equal(posted.length, 1);
  assert.equal(posted[0].method, 'create');
});

test('conditional mediation (autofill-style) and password credentials are not reported', async () => {
  const { credentials, posted } = setup(notAllowed);
  await assert.rejects(credentials.get({ publicKey: {}, mediation: 'conditional' }));
  await assert.rejects(credentials.get({ password: true }));
  await tick();
  assert.deepEqual(posted, []);
});

test('success passes through untouched', async () => {
  const cred = { id: 'x' };
  const { credentials, posted } = setup(() => Promise.resolve(cred));
  assert.equal(await credentials.get({ publicKey: {} }), cred);
  await tick();
  assert.deepEqual(posted, []);
});

test('unrelated errors (AbortError) are not reported', async () => {
  const { credentials, posted } = setup(() => Promise.reject(Object.assign(new Error('a'), { name: 'AbortError' })));
  await assert.rejects(credentials.get({ publicKey: {} }));
  await tick();
  assert.deepEqual(posted, []);
});
