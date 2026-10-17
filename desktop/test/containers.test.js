'use strict';
// 容器（登录状态隔离）：元数据持久化、标签映射 / 锁定继承、站点规则、删除时的清理调用
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const Module = require('node:module');
const core = require('../src/containers-core');
const { ContainerState, inheritContainer, matchSiteRule, normalizeHost, DEFAULT_ID } = core;
const { ContainerStore } = require('../src/containers-store');

const ID1 = '11111111-1111-4111-8111-111111111111';
const ID2 = '22222222-2222-4222-8222-222222222222';
const ID3 = '33333333-3333-4333-8333-333333333333';

function ids(...list) {
  let i = 0;
  return () => list[i++];
}

function tmpFile() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mio-containers-'));
  return path.join(dir, 'containers.json');
}

test('default container always first, cannot be changed or removed', () => {
  const s = new ContainerState(null);
  assert.deepEqual(s.list().map((c) => c.id), [DEFAULT_ID]);
  assert.equal(s.list()[0].isDefault, true);
  assert.throws(() => s.remove(DEFAULT_ID), /默认容器不能删除/);
  assert.throws(() => s.update(DEFAULT_ID, { name: 'x' }), /默认容器不能修改/);
  assert.equal(s.resolve('nope'), DEFAULT_ID);
  assert.equal(s.resolve(undefined), DEFAULT_ID);
});

test('create / rename / recolor; validation; colors rotate', () => {
  const s = new ContainerState(null, { newId: ids(ID1, ID2), now: () => 1000 });
  const a = s.create({ name: '  工作  账号 ' });
  assert.deepEqual(a, { id: ID1, name: '工作 账号', color: 'blue', createdAt: 1000, isDefault: false });
  const b = s.create({ name: '小号', color: 'red' });
  assert.equal(b.color, 'red');
  assert.equal(s.nextColor(), 'turquoise');
  assert.throws(() => s.create({ name: '   ' }), /不能为空/);
  assert.throws(() => s.update(ID1, { color: 'black' }), /无效的颜色/);
  assert.equal(s.update(ID1, { name: '公司', color: 'green' }).name, '公司');
  assert.equal(s.get(ID1).color, 'green');
  assert.equal(s.create({ name: 'x'.repeat(50) }).name.length, core.MAX_NAME);
});

test('max containers', () => {
  const s = new ContainerState(null);
  for (let i = 0; i < core.MAX_CONTAINERS; i++) s.create({ name: `c${i}` });
  assert.equal(s.canCreate(), false);
  assert.throws(() => s.create({ name: 'one more' }), /最多/);
});

test('metadata persists across restarts (ContainerStore, atomic file)', () => {
  const file = tmpFile();
  const st = new ContainerStore(file, { newId: ids(ID1, ID2), now: () => 42 });
  let changes = 0;
  st.on('change', () => changes++);
  st.create({ name: 'A', color: 'pink' });
  st.create({ name: 'B' });
  st.setTab('tab-1', { containerId: ID1, locked: true });
  st.setTab('tab-2', { containerId: ID2 });
  st.setSiteRule('https://www.GitHub.com/login', ID2);
  assert.equal(changes, 5);
  assert.ok(!fs.existsSync(`${file}.tmp`));

  const again = new ContainerStore(file);
  assert.deepEqual(again.list().map((c) => [c.id, c.name, c.color, c.createdAt]), [
    [DEFAULT_ID, '默认', 'gray', 0],
    [ID1, 'A', 'pink', 42],
    [ID2, 'B', 'blue', 42],
  ]);
  assert.deepEqual(again.getTab('tab-1'), { containerId: ID1, locked: true });
  assert.deepEqual(again.getTab('tab-2'), { containerId: ID2, locked: false });
  assert.deepEqual(again.getTab('unknown'), { containerId: DEFAULT_ID, locked: false });
  assert.equal(again.containerForUrl('https://gist.github.com/x'), ID2);
});

test('corrupt / hostile file → sane defaults, bad entries dropped', () => {
  const file = tmpFile();
  fs.writeFileSync(file, '{not json');
  assert.deepEqual(new ContainerStore(file).list().length, 1);
  const s = ContainerState.parse({
    containers: [
      { id: ID1, name: 'ok', color: 'nope' },
      { id: ID1, name: 'dup' },
      { id: 'default', name: 'hijack' },
      { id: '../../etc', name: 'path' },
      { id: ID2, name: '   ' },
    ],
    tabs: { t1: { containerId: ID1, locked: 1 }, t2: { containerId: ID3, locked: true }, t3: null },
    siteRules: [{ host: 'a.com', containerId: ID3 }, { host: 'b.com', containerId: ID1 }, { host: 'B.com', containerId: ID1 }],
    pendingRemovals: [ID3, ID3, 'x', ID1],
  });
  assert.deepEqual(s.list().map((c) => c.id), [DEFAULT_ID, ID1]);
  assert.equal(s.get(ID1).color, 'blue');
  assert.deepEqual(Object.keys(s.tabs), ['t1']);
  assert.deepEqual(s.siteRules, [{ host: 'b.com', containerId: ID1 }]);
  assert.deepEqual(s.pendingRemovals, [ID3]);
});

test('tab mapping: default+unlocked not stored; lock toggle; retain', () => {
  const s = new ContainerState(null, { newId: ids(ID1) });
  s.create({ name: 'A' });
  s.setTab('x', { containerId: DEFAULT_ID, locked: false });
  assert.deepEqual(s.tabs, {});
  s.setTab('x', { containerId: 'ghost', locked: true });
  assert.deepEqual(s.getTab('x'), { containerId: DEFAULT_ID, locked: true });
  s.setTab('y', { containerId: ID1 });
  assert.deepEqual(s.setTabLocked('y', true), { containerId: ID1, locked: true });
  s.setTab('z', { containerId: ID1 });
  s.retainTabs(['y']);
  assert.deepEqual(Object.keys(s.tabs), ['y']);
  assert.throws(() => s.setTab('', { containerId: ID1 }));
});

test('lock inheritance (pure rule)', () => {
  assert.deepEqual(inheritContainer({ containerId: ID1, locked: true }, ID2), { containerId: ID1, locked: true });
  assert.deepEqual(inheritContainer({ containerId: ID1, locked: false }, ID2), { containerId: ID2, locked: false });
  assert.deepEqual(inheritContainer({ containerId: ID1, locked: false }, null), { containerId: ID1, locked: false });
  assert.deepEqual(inheritContainer(null, ID2), { containerId: ID2, locked: false });
  assert.deepEqual(inheritContainer(null, null), { containerId: DEFAULT_ID, locked: false });
  // 子标签再打开孙标签：锁定一路传下去
  const child = inheritContainer({ containerId: ID1, locked: true }, null);
  assert.deepEqual(inheritContainer(child, ID2), { containerId: ID1, locked: true });
});

test('childOf / containerForNewTab: resolve + priority (locked opener > requested > site rule > opener > default)', () => {
  const s = new ContainerState(null, { newId: ids(ID1, ID2) });
  s.create({ name: 'A' });
  s.create({ name: 'B' });
  s.setSiteRule('github.com', ID2);
  const lockedA = { containerId: ID1, locked: true };
  const openA = { containerId: ID1, locked: false };
  assert.deepEqual(s.childOf(lockedA, ID2), { containerId: ID1, locked: true });
  assert.deepEqual(s.childOf(openA, 'ghost'), { containerId: ID1, locked: false });
  assert.deepEqual(s.childOf({ containerId: 'ghost', locked: true }), { containerId: DEFAULT_ID, locked: false });
  assert.deepEqual(s.containerForNewTab({ url: 'https://github.com', opener: lockedA, requested: ID2 }), { containerId: ID1, locked: true });
  assert.deepEqual(s.containerForNewTab({ url: 'https://github.com', opener: openA, requested: DEFAULT_ID }), { containerId: DEFAULT_ID, locked: false });
  assert.deepEqual(s.containerForNewTab({ url: 'https://api.github.com/x', opener: openA }), { containerId: ID2, locked: false });
  assert.deepEqual(s.containerForNewTab({ url: 'https://example.com', opener: openA }), { containerId: ID1, locked: false });
  assert.deepEqual(s.containerForNewTab({ url: 'https://example.com' }), { containerId: DEFAULT_ID, locked: false });
});

test('site rules: normalize, longest match, only real non-default containers', () => {
  assert.equal(normalizeHost('https://WWW.Example.com:8443/a?b'), 'example.com');
  assert.equal(normalizeHost('sub.example.com/path'), 'sub.example.com');
  assert.equal(normalizeHost('localhost'), null);
  assert.equal(normalizeHost('javascript:alert(1)'), null);
  assert.equal(normalizeHost(''), null);
  const rules = [{ host: 'example.com', containerId: 'a' }, { host: 'mail.example.com', containerId: 'b' }];
  assert.equal(matchSiteRule('https://x.mail.example.com/', rules), 'b');
  assert.equal(matchSiteRule('https://example.com/', rules), 'a');
  assert.equal(matchSiteRule('https://www.example.com/', rules), 'a');
  assert.equal(matchSiteRule('https://notexample.com/', rules), null);
  assert.equal(matchSiteRule('file:///etc/passwd', rules), null);
  const s = new ContainerState(null, { newId: ids(ID1) });
  s.create({ name: 'A' });
  assert.throws(() => s.setSiteRule('a.com', DEFAULT_ID));
  assert.throws(() => s.setSiteRule('a.com', ID2));
  assert.throws(() => s.setSiteRule('nope', ID1), /无效的域名/);
  s.setSiteRule('a.com', ID1);
  s.setSiteRule('A.com', ID1);
  assert.equal(s.siteRules.length, 1);
  s.removeSiteRule('https://a.com/');
  assert.equal(s.siteRules.length, 0);
});

test('remove: drops metadata, its tab mappings and site rules; pending until markRemoved', () => {
  const file = tmpFile();
  const st = new ContainerStore(file, { newId: ids(ID1, ID2) });
  st.create({ name: 'A' });
  st.create({ name: 'B' });
  st.setTab('t1', { containerId: ID1, locked: true });
  st.setTab('t2', { containerId: ID1 });
  st.setTab('t3', { containerId: ID2, locked: true });
  st.setSiteRule('a.com', ID1);
  const events = [];
  st.on('removed', (e) => events.push(e));
  const r = st.remove(ID1);
  assert.deepEqual(r.tabKeys.sort(), ['t1', 't2']);
  assert.equal(events.length, 1);
  assert.equal(events[0].container.id, ID1);
  assert.deepEqual(st.getTab('t1'), { containerId: DEFAULT_ID, locked: false });
  assert.deepEqual(st.getTab('t3'), { containerId: ID2, locked: true });
  assert.equal(st.containerForUrl('https://a.com'), null);
  assert.deepEqual(st.pendingRemovals, [ID1]);
  assert.deepEqual(new ContainerStore(file).pendingRemovals, [ID1]);
  st.markRemoved(ID1);
  assert.deepEqual(new ContainerStore(file).pendingRemovals, []);
  assert.throws(() => st.remove(ID1), /不存在/);
});

// ---- ContainerSessions（Electron 部分，用假的 electron 模块测会话配置和删除清理调用）

function loadWithFakeElectron() {
  const calls = [];
  const sessions = new Map();
  const handlers = new Map();
  const fakeSession = (partition) => ({
    partition,
    clearStorageData: async () => calls.push(['clearStorageData', partition]),
    clearCache: async () => calls.push(['clearCache', partition]),
    clearAuthCache: async () => calls.push(['clearAuthCache', partition]),
  });
  const electron = {
    session: {
      fromPartition: (p) => {
        if (!sessions.has(p)) {
          calls.push(['fromPartition', p]);
          sessions.set(p, fakeSession(p));
        }
        return sessions.get(p);
      },
    },
    ipcMain: { handle: (ch, fn) => handlers.set(ch, fn) },
  };
  const origLoad = Module._load;
  Module._load = function (request, parent, isMain) {
    if (request === 'electron') return electron;
    return origLoad.call(this, request, parent, isMain);
  };
  try {
    delete require.cache[require.resolve('../src/containers')];
    const mod = require('../src/containers');
    return { mod, calls, handlers };
  } finally {
    Module._load = origLoad;
  }
}

test('sessions: default = existing partition, others persist:mio-c-<id>, configurators applied to all', () => {
  const { mod, calls } = loadWithFakeElectron();
  const userDataDir = path.dirname(tmpFile());
  const store = new ContainerStore(path.join(userDataDir, 'containers.json'), { newId: ids(ID1) });
  const cs = new mod.ContainerSessions({ store, defaultPartition: 'persist:mio-browser', userDataDir });
  const def = cs.defaultSession();
  assert.equal(def.partition, 'persist:mio-browser');
  const configured = [];
  cs.configure((ses, id) => configured.push([ses.partition, id]));
  assert.deepEqual(configured, [['persist:mio-browser', DEFAULT_ID]]);
  store.create({ name: 'A' });
  const a = cs.sessionFor(ID1);
  assert.equal(a.partition, `persist:mio-c-${ID1}`);
  assert.deepEqual(configured[1], [`persist:mio-c-${ID1}`, ID1]);
  assert.equal(cs.sessionFor(ID1), a);
  assert.equal(configured.length, 2, 'configured once per session');
  assert.equal(cs.sessionFor('ghost'), def, 'unknown container → default session');
  assert.equal(cs.containerIdOfSession(a), ID1);
  assert.equal(cs.isBrowserSession({}), false);
  assert.equal(calls.filter((c) => c[0] === 'fromPartition').length, 2);
});

test('removeContainer: emits removed before clearing, clears cookies/storage/cache/auth, deletes partition dir', async () => {
  const { mod, calls } = loadWithFakeElectron();
  const userDataDir = path.dirname(tmpFile());
  const store = new ContainerStore(path.join(userDataDir, 'containers.json'), { newId: ids(ID1, ID2) });
  const cs = new mod.ContainerSessions({ store, defaultPartition: 'persist:mio-browser', userDataDir });
  store.create({ name: 'A' });
  store.create({ name: 'B' });
  store.setTab('t1', { containerId: ID1, locked: true });
  cs.sessionFor(ID1);
  const dir = cs.storageDirFor(ID1);
  fs.mkdirSync(path.join(dir, 'Local Storage'), { recursive: true });
  fs.writeFileSync(path.join(dir, 'Cookies'), 'x');
  const order = [];
  store.on('removed', (e) => order.push(['removed', e.tabKeys]));
  const r = await cs.removeContainer(ID1);
  const p = `persist:mio-c-${ID1}`;
  assert.deepEqual(calls.filter((c) => c[1] === p && c[0] !== 'fromPartition').map((c) => c[0]), ['clearStorageData', 'clearCache', 'clearAuthCache']);
  assert.deepEqual(order, [['removed', ['t1']]]);
  assert.equal(r.cleared, true);
  assert.equal(r.dirRemoved, true);
  assert.ok(!fs.existsSync(dir));
  assert.deepEqual(store.pendingRemovals, []);
  assert.equal(store.get(ID1), null);
  await assert.rejects(cs.removeContainer(DEFAULT_ID), /默认容器不能删除/);

  // 本次没加载过的容器：不创建会话，直接删目录
  const dir2 = cs.storageDirFor(ID2);
  fs.mkdirSync(dir2, { recursive: true });
  await cs.removeContainer(ID2);
  assert.ok(!calls.some((c) => c[1] === `persist:mio-c-${ID2}`));
  assert.ok(!fs.existsSync(dir2));
});

test('purgePending removes leftover partition dirs at startup', () => {
  const { mod } = loadWithFakeElectron();
  const userDataDir = path.dirname(tmpFile());
  const file = path.join(userDataDir, 'containers.json');
  fs.writeFileSync(file, JSON.stringify({ version: 1, containers: [], pendingRemovals: [ID3] }));
  const store = new ContainerStore(file);
  const cs = new mod.ContainerSessions({ store, defaultPartition: 'persist:mio-browser', userDataDir });
  fs.mkdirSync(path.join(cs.storageDirFor(ID3), 'IndexedDB'), { recursive: true });
  assert.deepEqual(cs.purgePending(), [ID3]);
  assert.ok(!fs.existsSync(cs.storageDirFor(ID3)));
  assert.deepEqual(new ContainerStore(file).pendingRemovals, []);
});

test('IPC rejects other senders; snapshot shape for settings UI', async () => {
  const { mod, handlers } = loadWithFakeElectron();
  const userDataDir = path.dirname(tmpFile());
  const store = new ContainerStore(path.join(userDataDir, 'containers.json'), { newId: ids(ID1) });
  const cs = new mod.ContainerSessions({ store, defaultPartition: 'persist:mio-browser', userDataDir });
  const ok = { sender: 'settings' };
  cs.installIpc((e) => e.sender === 'settings');
  assert.equal(await handlers.get('mio-containers:create')({ sender: 'evil' }, 'X', 'red'), null);
  assert.equal(store.list().length, 1);
  const s = await handlers.get('mio-containers:create')(ok, 'X', 'red');
  assert.deepEqual(s.containers.map((c) => [c.name, c.hex]), [['默认', '#8E8E93'], ['X', '#FF613D']]);
  assert.equal(s.colors.length, 8);
  await handlers.get('mio-containers:update')(ok, ID1, { name: 'Y' });
  assert.equal(store.get(ID1).name, 'Y');
  await handlers.get('mio-containers:site-rule-set')(ok, 'x.com', ID1);
  assert.equal(store.containerForUrl('https://x.com'), ID1);
  await handlers.get('mio-containers:remove')(ok, ID1);
  assert.equal(store.get(ID1), null);
});
