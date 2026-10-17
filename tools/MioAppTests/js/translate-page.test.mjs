// 网页翻译运行时（jsdom + 假原生桥）：双语 / 仅译文 / 关闭、动态内容增量翻译、按站点自动翻译、划词翻译、持久缓存
import test from 'node:test';
import assert from 'node:assert/strict';
import { loadPage, fakeNative, until, tick } from './translate-harness.mjs';

const ARTICLE = `<!doctype html><html lang="en"><head><title>Doc</title></head><body>
<main>
  <h1>Getting started guide</h1>
  <p id="p1">This is the first paragraph of the article.</p>
  <p id="p2">Second paragraph with <a href="#">a link</a> inside it.</p>
  <pre id="code">npm install something</pre>
  <p id="zh">这一段已经是中文了。</p>
  <ul><li id="li">List item text here</li></ul>
</main></body></html>`;

const trs = (doc) => [...doc.querySelectorAll('mio-tr')];

test('双语对照：段落下方插入译文（淡化），跳过 pre 和中文段落；关闭后全部移除', async () => {
  const { document, api, native } = loadPage(ARTICLE);
  assert.equal(api.state().mode, 'off');
  assert.equal(trs(document).length, 0);
  api.setMode('bilingual');
  assert.ok(await until(() => trs(document).length === 4), `got ${trs(document).length}`);
  const p1 = document.getElementById('p1');
  const tr = p1.lastElementChild;
  assert.equal(tr.tagName, 'MIO-TR');
  assert.equal(tr.textContent, '[译]This is the first paragraph of the article.');
  assert.equal(tr.style.opacity, '0.78');
  assert.equal(tr.getAttribute('translate'), 'no');
  assert.equal(document.getElementById('code').querySelector('mio-tr'), null);
  assert.equal(document.getElementById('zh').querySelector('mio-tr'), null);
  // 所有请求都带 token，经原生 fetch（Edge 404 → Bing）
  const urls = native.fetches().map((r) => r.url.split('?')[0]);
  assert.ok(urls.includes('https://www.bing.com/ttranslatev3'));
  assert.ok(native.calls.every((c) => c.t === 'tok'));
  assert.equal(api.state().translated, 4);
  api.setMode('off');
  assert.equal(trs(document).length, 0);
  assert.equal(api.state().mode, 'off');
});

test('仅译文：原文隐藏（font-size 0 / 子元素 display none），切回双语时恢复', async () => {
  const { document, api } = loadPage(ARTICLE);
  api.setMode('translation');
  assert.ok(await until(() => trs(document).length === 4));
  const p2 = document.getElementById('p2');
  assert.match(p2.style.getPropertyValue('font-size'), /^0(px)?$/);
  assert.equal(p2.querySelector('a').style.getPropertyValue('display'), 'none');
  const tr = p2.querySelector('mio-tr');
  assert.notEqual(tr.style.getPropertyValue('font-size'), '');
  assert.equal(tr.style.opacity, '1');
  api.setMode('bilingual');
  assert.equal(p2.style.getPropertyValue('font-size'), '');
  assert.equal(p2.querySelector('a').style.getPropertyValue('display'), '');
  assert.equal(tr.style.opacity, '0.78');
  api.setMode('off');
  assert.equal(p2.style.getPropertyValue('font-size'), '');
});

test('动态内容：新加的段落、文字变化增量翻译（MutationObserver 节流）', async () => {
  const { document, window, api } = loadPage(ARTICLE);
  api.setMode('bilingual');
  assert.ok(await until(() => trs(document).length === 4));
  const p = document.createElement('p');
  p.textContent = 'A paragraph loaded later by the page.';
  document.querySelector('main').appendChild(p);
  assert.ok(await until(() => p.querySelector('mio-tr')), 'new paragraph translated');
  assert.equal(p.querySelector('mio-tr').textContent, '[译]A paragraph loaded later by the page.');
  // 文字被页面改掉：旧译文删除，重新翻译
  const p1 = document.getElementById('p1');
  p1.firstChild.nodeValue = 'Completely new content for paragraph one.';
  assert.ok(await until(() => p1.querySelector('mio-tr') && p1.querySelector('mio-tr').textContent === '[译]Completely new content for paragraph one.'));
  assert.equal(p1.querySelectorAll('mio-tr').length, 1);
  // 我们自己插入的节点不触发重复翻译
  await tick(600);
  assert.equal(trs(document).length, 5);
  void window;
});

test('按站点自动翻译：在列表里的站点打开即翻译；页面 lang 已是目标语言时不自动翻译', async () => {
  const a = loadPage(ARTICLE, { url: 'https://docs.example.com/x', config: { autoSites: ['example.com'] } });
  assert.ok(await until(() => trs(a.document).length === 4));
  assert.equal(a.api.state().mode, 'bilingual');
  assert.equal(a.api.state().auto, true);

  const b = loadPage(ARTICLE.replace('lang="en"', 'lang="zh-CN"'), { url: 'https://example.com/', config: { autoSites: ['example.com'] } });
  await tick(100);
  assert.equal(b.api.state().mode, 'off');

  const c = loadPage(ARTICLE, { url: 'https://other.org/', config: { autoSites: ['example.com'], display: 'translation' } });
  await tick(50);
  assert.equal(c.api.state().mode, 'off');
  c.api.toggle();
  assert.equal(c.api.state().mode, 'translation', 'toggle 用设置里的显示方式');
});

test('持久缓存：第二次打开同一页面不再请求翻译接口', async () => {
  const native = fakeNative();
  const one = loadPage(ARTICLE, { native });
  one.api.setMode('bilingual');
  assert.ok(await until(() => trs(one.document).length === 4));
  const before = native.fetches().filter((r) => r.url.includes('ttranslatev3')).length;
  const two = loadPage(ARTICLE, { native });
  two.api.setMode('bilingual');
  assert.ok(await until(() => trs(two.document).length === 4));
  assert.equal(native.fetches().filter((r) => r.url.includes('ttranslatev3')).length, before);
  assert.equal(native.fetches().filter((r) => r.url.startsWith('https://www.bing.com/translator')).length, 1, 'Bing 参数也缓存了');
});

test('桥 token 不对时原生拒绝（页面脚本伪造的消息无效）', async () => {
  const native = fakeNative({ token: 'right' });
  const { api, document } = loadPage(ARTICLE, { native, config: { token: 'wrong' } });
  api.setMode('bilingual');
  await tick(300);
  assert.equal(trs(document).length, 0);
  assert.ok(api.state().errors >= 1);
});

test('翻译失败显示提示，不影响页面', async () => {
  const native = fakeNative({ handler: () => ({ status: 503, body: '' }) });
  const { api, document } = loadPage(ARTICLE, { native });
  api.setMode('bilingual');
  assert.ok(await until(() => api.state().errors >= 1));
  const toast = document.querySelector('mio-tr-ui');
  assert.ok(toast && /翻译失败/.test(toast.textContent));
  assert.equal(trs(document).length, 0);
});

test('划词翻译：选中文字后出现「译」气泡，点它弹出译文卡片', async () => {
  const { document, window, native } = loadPage(ARTICLE);
  const p1 = document.getElementById('p1');
  const range = document.createRange();
  range.selectNodeContents(p1);
  window.getSelection().removeAllRanges();
  window.getSelection().addRange(range);
  document.dispatchEvent(new window.Event('selectionchange'));
  assert.ok(await until(() => document.querySelector('mio-tr-ui[role="button"]')));
  const bubble = document.querySelector('mio-tr-ui[role="button"]');
  assert.equal(bubble.textContent, '译');
  bubble.dispatchEvent(new window.MouseEvent('click', { bubbles: true, cancelable: true }));
  assert.ok(await until(() => [...document.querySelectorAll('mio-tr-ui')].some((e) => e.textContent.includes('[译]This is the first paragraph'))));
  assert.ok(native.fetches().some((r) => r.url.includes('ttranslatev3')));
  // 点卡片外面关闭
  document.body.dispatchEvent(new window.Event('pointerdown', { bubbles: true }));
  await tick(10);
  assert.ok(![...document.querySelectorAll('mio-tr-ui')].some((e) => e.textContent.includes('[译]This is the first paragraph')));
});

test('划词翻译：输入框里的选区 / 关掉开关时不出现气泡', async () => {
  const html = '<!doctype html><html><body><div contenteditable="true" id="ed">Editable words here</div></body></html>';
  const { document, window } = loadPage(html);
  const range = document.createRange();
  range.selectNodeContents(document.getElementById('ed'));
  window.getSelection().addRange(range);
  document.dispatchEvent(new window.Event('selectionchange'));
  await tick(400);
  assert.equal(document.querySelector('mio-tr-ui[role="button"]'), null);

  const off = loadPage(ARTICLE, { config: { selection: false } });
  const r2 = off.document.createRange();
  r2.selectNodeContents(off.document.getElementById('p1'));
  off.window.getSelection().addRange(r2);
  off.document.dispatchEvent(new off.window.Event('selectionchange'));
  await tick(400);
  assert.equal(off.document.querySelector('mio-tr-ui[role="button"]'), null);
});

test('configure：运行中切换显示方式 / 关闭划词', async () => {
  const { document, api } = loadPage(ARTICLE);
  api.setMode('bilingual');
  assert.ok(await until(() => trs(document).length === 4));
  api.configure({ display: 'translation' });
  assert.equal(api.state().mode, 'translation');
  assert.match(document.getElementById('p1').style.getPropertyValue('font-size'), /^0(px)?$/);
  api.configure({ selection: false });
  assert.equal(api.state().mode, 'translation');
});

test('没有原生桥（普通浏览器 / 测试页面）时脚本什么都不做', () => {
  const { window } = loadPage(ARTICLE, { beforeScript: (w) => { delete w.webkit; } });
  assert.equal(window.__mioTranslate, undefined);
});

test('selfTest：桥往返（冒烟测试用）', async () => {
  const { api } = loadPage(ARTICLE);
  const r = await api.selfTest(false);
  assert.equal(r.bridge, true);
  assert.equal(r.kind, 'webkit');
  const n = await api.selfTest(true);
  assert.equal(n.sample, '[译]Hello world');
  assert.equal(n.engine, 'microsoft');
});
