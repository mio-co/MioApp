// 阅读模式正文提取（www/mio-browser/reader.js）：几个样例 HTML 在 jsdom 里跑，
// 检查正文 / 标题 / 作者 / 图片（懒加载、绝对地址）、噪音（导航 / 侧栏 / 评论 / 广告 / 分享）被去掉、输出只含白名单标签、markdown 转换和阅读视图页面。
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { JSDOM, VirtualConsole } from 'jsdom';

const require = createRequire(import.meta.url);
const READER_PATH = new URL('../../../www/mio-browser/reader.js', import.meta.url);
const MioReader = require(READER_PATH.pathname);
const fixture = (name) => readFileSync(new URL(`./fixtures/reader/${name}`, import.meta.url), 'utf8');

function doc(html, url = 'https://example.com/2026/10/story.html') {
  return new JSDOM(html, { url, virtualConsole: new VirtualConsole() }).window.document;
}

test('news article: metadata, body, noise removed', () => {
  const d = doc(fixture('news.html'));
  assert.equal(MioReader.isProbablyReaderable(d), true);
  const a = MioReader.extract(d);
  assert.ok(a);
  assert.equal(a.title, 'Scientists Find Water on Distant Moon');
  assert.equal(a.byline, 'Lois Lane');
  assert.equal(a.siteName, 'The Daily Planet');
  assert.equal(a.publishedTime, '2026-10-01T08:00:00Z');
  assert.match(a.text, /liquid water beneath the icy crust/);
  assert.match(a.text, /independent confirmation would be needed/);
  assert.match(a.html, /<h2>What comes next<\/h2>/);
  for (const noise of ['Trending', 'BUY NOW', 'First! This is a long comment', 'All rights reserved', 'We use cookies', 'Tweet', 'Related story']) {
    assert.ok(!a.text.includes(noise), `should drop: ${noise}`);
  }
  // 标题不在正文里重复；作者行也不重复
  assert.ok(!/<h1/.test(a.html));
  assert.ok(!a.text.includes('By Lois Lane'));
  // 原页面没被改动（在克隆上操作）
  assert.ok(d.querySelector('.sidebar'));
  assert.ok(d.querySelector('script'));
});

test('lazy images resolved + absolutized; dangerous markup stripped', () => {
  const a = MioReader.extract(doc(fixture('news.html')));
  assert.deepEqual(a.images, ['https://example.com/img/moon.jpg']);
  assert.match(a.html, /<figcaption>The moon's icy surface, as seen by the probe\.<\/figcaption>/);
  assert.match(a.html, /href="https:\/\/example\.com\/journal"/);
  assert.ok(!/onclick|javascript:|<script|<style|class=|style=/i.test(a.html), a.html);
  // 只含白名单标签
  const tags = new Set([...a.html.matchAll(/<([a-z0-9]+)/gi)].map((m) => m[1].toLowerCase()));
  const allowed = new Set(['p', 'a', 'img', 'figure', 'figcaption', 'h2', 'h3', 'strong', 'em', 'div', 'article', 'section', 'br', 'ul', 'ol', 'li', 'blockquote', 'pre', 'code']);
  for (const t of tags) assert.ok(allowed.has(t), `unexpected tag <${t}>`);
});

test('Chinese blog: readerable, code block and list kept, share links dropped', () => {
  const d = doc(fixture('zh-blog.html'), 'https://blog.example.cn/posts/workers-nav/');
  assert.equal(MioReader.isProbablyReaderable(d), true);
  const a = MioReader.extract(d);
  assert.equal(a.title, '用 Cloudflare Workers 搭建个人导航页');
  assert.equal(a.siteName, '小米的博客');
  assert.match(a.html, /<pre><code>npx wrangler d1 create mio\nnpx wrangler deploy<\/code><\/pre>/);
  assert.match(a.html, /<ol><li>安装 wrangler 命令行工具<\/li>/);
  assert.deepEqual(a.images, ['https://cdn.example.com/screenshot.png']);
  for (const noise of ['归档', '关于', '微博', '微信', '© 2026 小米']) assert.ok(!a.text.includes(noise), noise);
  assert.match(a.markdown, /## 部署步骤/);
  assert.match(a.markdown, /1\. 安装 wrangler 命令行工具\n2\. 创建 D1 数据库并执行迁移/);
  assert.match(a.markdown, /```\nnpx wrangler d1 create mio\nnpx wrangler deploy\n```/);
  assert.match(a.markdown, /!\[截图\]\(https:\/\/cdn\.example\.com\/screenshot\.png\)/);
});

test('link-heavy home page is not readerable and yields no article', () => {
  const d = doc(fixture('home.html'));
  assert.equal(MioReader.isProbablyReaderable(d), false);
  assert.equal(MioReader.extract(d), null);
});

test('markdown conversion: inline, links, lists, quotes, tables, escaping', () => {
  const d = doc(`<div id="x"><h2>Title</h2><p>Some <strong>bold</strong>, <em>italic</em>, <code>a_b</code> and <a href="/rel">link</a>. 1*2=2_</p>
    <ul><li>one</li><li>two<ul><li>nested</li></ul></li></ul>
    <blockquote><p>quoted line</p></blockquote>
    <table><tr><th>k</th><th>v</th></tr><tr><td>a|b</td><td>2</td></tr></table>
    <p>line<br>break</p><hr><img src="pic.png" alt="P"></div>`, 'https://site.test/dir/page');
  const md = MioReader.toMarkdown(d.getElementById('x'), 'https://site.test/dir/page');
  assert.match(md, /^## Title/);
  assert.match(md, /Some \*\*bold\*\*, \*italic\*, `a_b` and \[link\]\(https:\/\/site\.test\/rel\)\. 1\\\*2=2\\_/);
  assert.match(md, /- one\n- two\n  - nested/);
  assert.match(md, /> quoted line/);
  assert.match(md, /\| k \| v \|\n\| --- \| --- \|\n\| a\\\|b \| 2 \|/);
  assert.match(md, /line  \nbreak/);
  assert.match(md, /---/);
  assert.match(md, /!\[P\]\(https:\/\/site\.test\/dir\/pic\.png\)/);
});

test('title cleanup strips site suffix, keeps h1 match', () => {
  assert.equal(MioReader._cleanTitle('Hello World | Example News', 'Example News', []), 'Hello World');
  assert.equal(MioReader._cleanTitle('Deep dive - part 2 - Blog', '', ['Deep dive - part 2']), 'Deep dive - part 2');
  assert.equal(MioReader._cleanTitle('Short', '', []), 'Short');
});

test('absolutize rejects javascript:/data: non-image', () => {
  assert.equal(MioReader._absolutize('javascript:alert(1)', 'https://a.test/'), '');
  assert.equal(MioReader._absolutize('data:text/html,<b>', 'https://a.test/'), '');
  assert.equal(MioReader._absolutize('data:image/png;base64,AAA', 'https://a.test/'), 'data:image/png;base64,AAA');
  assert.equal(MioReader._absolutize('../x.png', 'https://a.test/b/c/'), 'https://a.test/b/x.png');
});

test('reader page: escaped metadata, CSP blocks scripts, prefs normalized', () => {
  const html = MioReader.buildPage({
    url: 'https://example.com/a', title: '<script>alert(1)</script> & co', byline: 'A "B"', siteName: 'Ex', html: '<p>Body</p>', textLength: 1500, lang: 'en'
  }, { theme: 'sepia', font: 'serif', fontSize: 21 });
  assert.match(html, /Content-Security-Policy" content="default-src 'none';/);
  assert.ok(!html.includes("script-src"));
  assert.match(html, /data-theme="sepia" data-font="serif" style="--fs:21px"/);
  assert.match(html, /&lt;script&gt;alert\(1\)&lt;\/script&gt; &amp; co/);
  assert.match(html, /A &quot;B&quot; · 约 3 分钟/);
  assert.match(html, /<article><p>Body<\/p><\/article>/);
  assert.deepEqual(MioReader.normalizePrefs({ theme: 'neon', font: 'comic', fontSize: 99 }), { theme: 'light', font: 'sans', fontSize: 18 });
  // 阅读视图实际渲染：主题变量生效
  const dom = new JSDOM(html);
  assert.equal(dom.window.document.documentElement.getAttribute('data-theme'), 'sepia');
  assert.equal(dom.window.document.querySelector('h1.mio-title').textContent, '<script>alert(1)</script> & co');
  assert.equal(dom.window.document.querySelectorAll('script').length, 0);
});

test('applyPrefsScript switches theme without reload', () => {
  const dom = new JSDOM(MioReader.buildPage({ url: 'https://e.test/', title: 't', html: '<p>x</p>' }, {}), { runScripts: 'outside-only' });
  dom.window.eval(MioReader.applyPrefsScript({ theme: 'dark', font: 'mono', fontSize: 24 }));
  const root = dom.window.document.documentElement;
  assert.equal(root.getAttribute('data-theme'), 'dark');
  assert.equal(root.getAttribute('data-font'), 'mono');
  assert.equal(root.style.getPropertyValue('--fs'), '24px');
});

test('no innerHTML assignment / DOMParser in injected source (Trusted Types)', () => {
  const src = readFileSync(READER_PATH, 'utf8');
  assert.ok(!/\.innerHTML\s*=[^=]/.test(src));
  assert.ok(!/outerHTML\s*=[^=]/.test(src));
  assert.ok(!/new DOMParser|\.insertAdjacentHTML\(|document\.write\(/.test(src));
});

test('article split across sibling <section>s (wiki style): lead + all sections kept', () => {
  const a = MioReader.extract(doc(fixture('sections.html'), 'https://wiki.example.org/wiki/Ocean_currents'));
  assert.equal(a.title, 'Ocean currents');
  assert.match(a.text, /are continuous movements of sea water/);
  for (const s of ['Wind drives surface currents', 'Currents move heat', 'Sailors mapped currents']) assert.match(a.text, new RegExp(s));
  for (const noise of ['Random', '[edit]', 'Oceanography', 'license']) assert.ok(!a.text.includes(noise), noise);
  assert.match(a.markdown, /## Causes\n\nWind drives/);
});
