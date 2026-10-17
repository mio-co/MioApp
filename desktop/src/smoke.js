'use strict';
// CI 冒烟测试：环境变量 MIO_SMOKE_OUT=<json 路径> 时启用。
// 等拦截引擎就绪 → 检查主窗口暴露 window.MioDesktop.browser → 用内置浏览器打开 YouTube 视频页，
// 检查被拦截的请求数、scriptlets 是否生效（ytInitialPlayerResponse.adPlacements 被置为 undefined）、后台播放的 visibility 覆盖 → 写结果并退出
const fs = require('node:fs');
const { app } = require('electron');

function wait(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

function waitLoad(wc, timeout) {
  return new Promise((resolve) => {
    const t = setTimeout(resolve, timeout);
    const done = () => {
      clearTimeout(t);
      resolve();
    };
    if (!wc.isLoading()) return setTimeout(done, 500);
    wc.once('did-stop-loading', done);
  });
}

async function tabsSmoke({ browser, ytWc, wc2, out, getMainWindow }) {
  const path = require('node:path');
  const fs = require('node:fs');
  const { TOOLBAR_HEIGHT } = require('./browser');
  const { hostOf } = require('./util');
  const r = { ok: false };
  try {
    const store = browser.store;
    r.afterTwoOpens = store.size;
    r.distinctWebContents = ytWc !== wc2 && !ytWc.isDestroyed() && !wc2.isDestroyed();
    const second = store.activeId;
    browser.command('selectTab', String(store.tabs[0].id));
    r.switchedToFirst = browser.content.webContents === ytWc;
    // 新建标签页 = 设置里的地址（默认 MioCore 导航；CI 没登录 → Access 登录页）
    browser.command('newTab');
    const nt = browser.content.webContents;
    // 新标签页打开 MioCore 前先同步登录 Cookie（异步），所以等到真正开始加载
    for (let i = 0; i < 60 && !nt.getURL(); i++) await wait(250);
    await waitLoad(nt, 30000);
    r.newTabUrl = nt.getURL();
    r.newTabCount = store.size;
    // 后台标签里也有按 webContents 注入的脚本（YouTube 防沉迷）
    const bg = browser.newTab('https://www.youtube.com/', { activate: false, fromActive: true });
    const bgWc = browser.views.get(bg.id).webContents;
    await waitLoad(bgWc, 45000);
    await wait(4000);
    r.backgroundTabYtFocus = await bgWc.executeJavaScript('!!window.__mioYTFocus').catch((e) => String(e));
    r.activeStillNewTab = browser.content.webContents === nt;
    r.toolbarTop = browser.toolbar.getBounds().y === 0 && browser.content.getBounds().y === TOOLBAR_HEIGHT;
    await wait(600);
    r.stripTabs = await browser.toolbar.webContents.executeJavaScript("document.querySelectorAll('#tabs .tab').length");
    try {
      const dir = path.dirname(out);
      fs.writeFileSync(path.join(dir, 'smoke-toolbar.png'), (await browser.toolbar.webContents.capturePage()).toPNG());
      browser.command('selectTab', String(second));
      await wait(800);
      fs.writeFileSync(path.join(dir, 'smoke-content.png'), (await browser.content.webContents.capturePage()).toPNG());
    } catch (e) {
      r.screenshotError = String(e);
    }
    browser.selectTab(store.tabs.find((t) => browser.views.get(t.id) && browser.views.get(t.id).webContents === nt).id);
    // 关闭当前（新标签页）→ 恢复关闭
    const before = store.size;
    browser.command('closeTab');
    r.afterClose = store.size;
    // webContents.close() 是异步的
    for (let i = 0; i < 20 && !nt.isDestroyed(); i++) await wait(100);
    r.closedDestroyed = nt.isDestroyed();
    browser.command('reopenTab');
    r.afterReopen = store.size;
    r.reopenedHost = hostOf(store.active.url);
    // 收起：窗口隐藏、标签不销毁、主窗口出现角标；再显示
    browser.hide();
    await wait(800);
    r.hiddenVisible = browser.isVisible();
    r.hiddenKeepsTabs = store.size === before && !ytWc.isDestroyed();
    const main = getMainWindow();
    r.badgeShown = !!(main && main.contentView.children.some((v) => v !== main.webContents && v.getVisible && v.getVisible() && v.getBounds().width === 132));
    browser.show();
    await wait(500);
    r.shownAgain = browser.isVisible();
    // 跳转系统浏览器后自动关闭标签页：打开成功才关（这里注入 openExternal 不真的打开浏览器）
    const cae = require('./close-after-external');
    const n0 = store.size;
    const tid = store.activeId;
    await cae.openExternalThenMaybeClose({ url: 'https://example.com/', enabled: true, openExternal: () => Promise.reject(new Error('x')), close: () => browser.closeTab(tid) });
    r.failedOpenKeepsTab = store.size === n0;
    await cae.openExternalThenMaybeClose({ url: 'https://example.com/', enabled: true, openExternal: () => Promise.resolve(), close: () => browser.closeTab(tid) });
    r.openedClosesTab = store.size === n0 - 1;
    r.final = store.size;
    r.saved = store.serialize().tabs.length;
    r.ok =
      r.afterTwoOpens === 2 &&
      r.distinctWebContents &&
      r.switchedToFirst &&
      r.newTabCount === 3 &&
      /^https:\/\/(mio\.300031\.xyz|[a-z0-9.-]+\.cloudflareaccess\.com)\//.test(r.newTabUrl) &&
      r.backgroundTabYtFocus === true &&
      r.activeStillNewTab &&
      r.toolbarTop &&
      r.stripTabs === 4 &&
      r.afterClose === before - 1 &&
      r.closedDestroyed &&
      r.afterReopen === before &&
      r.hiddenVisible === false &&
      r.hiddenKeepsTabs &&
      r.badgeShown &&
      r.shownAgain &&
      r.failedOpenKeepsTab &&
      r.openedClosesTab;
  } catch (e) {
    r.error = String((e && e.stack) || e);
  }
  return r;
}

/** 多标签 × 容器：新建容器标签用该容器会话、锁定继承、站点规则、删除容器关闭其标签 */
async function tabsContainersSmoke({ browser, containers }) {
  const r = { ok: false };
  try {
    const store = browser.store;
    const c = containers.store.create({ name: 'smoke-tabs', color: 'green' });
    const t = browser.newTab('https://example.com/', { activate: true, containerId: c.id });
    const wc = browser.views.get(t.id).webContents;
    r.containerSession = wc.session === containers.sessionFor(c.id) && wc.session !== containers.defaultSession();
    r.mapped = (containers.store.getTab(t.key) || {}).containerId === c.id;
    browser.setTabLocked(t.id, true);
    const child = browser.openFrom(wc, 'https://example.com/?child', false, 'default');
    r.childInherits = !!child && child.containerId === c.id && child.locked === true;
    r.childSession = !!child && browser.views.get(child.id).webContents.session === wc.session;
    containers.store.setSiteRule('example.org', c.id);
    const ruled = browser.newTab('https://www.example.org/', { activate: false });
    r.siteRule = !!ruled && ruled.containerId === c.id;
    await wait(600);
    const strip = await browser.toolbar.webContents
      .executeJavaScript("JSON.stringify([...document.querySelectorAll('#tabs .tab')].map((n) => n.style.getPropertyValue('--container').trim()))")
      .catch(() => '[]');
    r.stripColors = JSON.parse(strip).filter((x) => x && x !== 'transparent').length;
    const n0 = store.size;
    const ids = [t.id, child && child.id, ruled && ruled.id].filter((x) => x != null);
    await containers.removeContainer(c.id);
    r.closedOnRemove = ids.every((id) => !store.get(id)) && store.size === n0 - ids.length;
    r.ok = r.containerSession && r.mapped && r.childInherits && r.childSession && r.siteRule && r.stripColors >= 3 && r.closedOnRemove;
  } catch (e) {
    r.error = String((e && e.stack) || e);
  }
  return r;
}

async function runSmoke({ out, adblock, browser, containers, getMainWindow }) {
  const result = { ok: false, platform: process.platform, version: app.getVersion(), steps: {} };
  const finish = (code) => {
    try {
      fs.writeFileSync(out, JSON.stringify(result, null, 2));
    } catch (e) {
      console.error(e);
    }
    app.exit(code);
  };
  const guard = setTimeout(() => {
    result.error = 'timeout';
    finish(2);
  }, 210000);
  try {
    const t0 = Date.now();
    await adblock.readyPromise;
    result.steps.engine = { ready: !!adblock.engine, ms: Date.now() - t0, snapshot: adblock.snapshot() };

    const main = getMainWindow();
    await waitLoad(main.webContents, 30000);
    result.steps.main = {
      url: main.webContents.getURL(),
      bridge: await main.webContents.executeJavaScript(
        "JSON.stringify({ open: typeof (window.MioDesktop && window.MioDesktop.browser && window.MioDesktop.browser.open), settings: typeof (window.MioDesktop && window.MioDesktop.browser && window.MioDesktop.browser.openSettings), platform: window.MioDesktop && window.MioDesktop.platform })",
      ),
    };

    browser.open('https://www.youtube.com/watch?v=dQw4w9WgXcQ');
    const wc = browser.content.webContents;
    await waitLoad(wc, 45000);
    await wait(6000);
    const ytf = require('./youtube-focus');
    result.steps.youtube = {
      ytFocusScriptBytes: ytf.template().length,
      ytFocusFor: ytf.scriptFor(wc.getURL(), adblock.settings).length,
      resourcesPath: process.resourcesPath,
      url: wc.getURL(),
      title: wc.getTitle(),
      blocked: adblock.blockedCount(wc.id),
      page: JSON.parse(
        await wc.executeJavaScript(
          "JSON.stringify({ media: !!window.__mioMedia, mediaError: window.__mioMediaError || null, sbVideo: window.__mioMedia ? window.__mioMedia.state.videoId : null, hidden: document.hidden, visibility: document.visibilityState, hasPlayerResponse: typeof window.ytInitialPlayerResponse === 'object' && window.ytInitialPlayerResponse !== null, adPlacements: window.ytInitialPlayerResponse ? typeof window.ytInitialPlayerResponse.adPlacements : 'n/a', playerAds: window.ytInitialPlayerResponse ? typeof window.ytInitialPlayerResponse.playerAds : 'n/a', ytFocus: !!window.__mioYTFocus, ytFocusStyle: !!document.getElementById('mio-yt-focus-style'), ytPlayables: document.documentElement.classList.contains('mio-hide-playables') })",
        ),
      ),
    };

    try {
      const media = require('./media');
      result.steps.youtube.mediaScript = { length: media.scriptFor(wc.getURL(), (k) => adblock.settings.get(k)).length, config: media.config((k) => adblock.settings.get(k)) };
    } catch (e) {
      result.steps.youtube.mediaScript = String((e && e.stack) || e);
    }

    // Widevine（只记录）：官方 Electron 不带 Widevine CDM，预期 NotSupportedError
    result.steps.youtube.widevine = await wc
      .executeJavaScript(
        "navigator.requestMediaKeySystemAccess ? Promise.race([navigator.requestMediaKeySystemAccess('com.widevine.alpha', [{ initDataTypes: ['cenc'], videoCapabilities: [{ contentType: 'video/mp4; codecs=\"avc1.42E01E\"' }] }]).then(() => true, (e) => String(e && e.name)), new Promise((r) => setTimeout(() => r('timeout'), 5000))]) : 'no-api'",
      )
      .catch((e) => String(e));

    const ytWc = wc;
    // WebRTC 控制：默认屏蔽（YouTube 页面里 RTCPeerConnection 不存在），放行 example.com 后可用
    const rtc = browser.webrtc;
    result.steps.webrtc = { blocked: await wc.executeJavaScript('typeof RTCPeerConnection'), policy: wc.getWebRTCIPHandlingPolicy() };
    if (rtc) {
      // 多标签：MioCore 打开外链 = 新标签；检查完关掉，后面的标签数不变
      rtc.setAllowed('example.com', true);
      browser.open('https://example.com/');
      const rwc = browser.content.webContents;
      await waitLoad(rwc, 30000);
      await wait(1500);
      result.steps.webrtc.allowed = await rwc.executeJavaScript('typeof RTCPeerConnection');
      result.steps.webrtc.allowedPolicy = rwc.getWebRTCIPHandlingPolicy();
      rtc.setAllowed('example.com', false);
      browser.closeTab();
    }

    // 用户脚本（userscripts.js）：装一个隔离 world 脚本（@grant GM_setValue）+ 一个页面世界脚本（@grant none），
    // 打开 example.com 检查两个都运行、隔离 world 看不到页面变量、GM_setValue 落到主进程存储
    const us = browser.userscripts;
    if (us) {
      const iso = "// ==UserScript==\n// @name Mio smoke isolated\n// @namespace mio.smoke\n// @match https://example.com/*\n// @run-at document-end\n// @grant GM_setValue\n// ==/UserScript==\ndocument.documentElement.setAttribute('data-mio-us-iso', typeof window.__mioUsPage + ':' + typeof GM_setValue + ':' + typeof GM_info);\nGM_setValue('smoke', 42);\n";
      const pg = "// ==UserScript==\n// @name Mio smoke page\n// @namespace mio.smoke\n// @match https://example.com/*\n// @run-at document-start\n// @grant none\n// ==/UserScript==\nwindow.__mioUsPage = 1;\n";
      const { prepare } = require('./userscripts');
      const a = us.store.install(await prepare(iso, null, us.fetch));
      const b = us.store.install(await prepare(pg, null, us.fetch));
      browser.open('https://example.com/');
      const uwc = browser.content.webContents;
      await waitLoad(uwc, 30000);
      await wait(2000);
      const page = JSON.parse(await uwc.executeJavaScript("JSON.stringify({ iso: document.documentElement.getAttribute('data-mio-us-iso'), page: typeof window.__mioUsPage, bridge: typeof window.mioUserScriptNative })"));
      const stored = us.store.values(a.id).smoke;
      us.store.delete(a.id);
      us.store.delete(b.id);
      browser.closeTab();
      result.steps.userscripts = { page, stored, ok: page.iso === 'undefined:function:object' && page.page === 'number' && page.bridge === 'undefined' && stored === '42' };
    }

    // 页面缩放（zoom.js，v0.3.4）：Ctrl+= 后 zoomFactor 变成 1.15、重载后保持、地址栏出现「115%」、Ctrl+0 复位
    {
      browser.open('https://example.com/');
      const zwc = browser.content.webContents;
      await waitLoad(zwc, 30000);
      const z = { before: zwc.getZoomFactor() };
      zwc.sendInputEvent({ type: 'keyDown', keyCode: '=', modifiers: [process.platform === 'darwin' ? 'meta' : 'control'] });
      await wait(500);
      z.afterKey = zwc.getZoomFactor();
      if (Math.abs(z.afterKey - 1.15) > 0.001) browser.command('zoomIn'); // 合成按键没走 before-input-event 时直接发命令
      z.afterIn = zwc.getZoomFactor();
      await wait(400);
      z.badge = await browser.toolbar.webContents.executeJavaScript("(() => { const b = document.getElementById('zoomBadge'); return b && !b.hidden ? b.textContent : ''; })()");
      zwc.reload();
      await waitLoad(zwc, 30000);
      await wait(500);
      z.afterReload = zwc.getZoomFactor();
      browser.command('zoomReset');
      z.afterReset = zwc.getZoomFactor();
      z.stored = browser.zoom.table.size;
      z.ok = Math.abs(z.afterIn - 1.15) < 0.001 && Math.abs(z.afterReload - 1.15) < 0.001 && Math.abs(z.afterReset - 1) < 0.001 && z.badge === '115%' && z.stored === 0;
      browser.closeTab();
      result.steps.zoom = z;
    }

    // 白名单后同一页面不再拦截（MioCore 打开外链 = 新标签：speedtest 在第二个标签里）
    browser.open('https://www.speedtest.net/');
    const wc2 = browser.content.webContents;
    adblock.resetCount(wc2.id);
    await waitLoad(wc2, 45000);
    await wait(4000);
    const blockedOn = adblock.blockedCount(wc2.id);
    adblock.settings.addWhitelist('speedtest.net');
    adblock.resetCount(wc2.id);
    wc2.reload();
    await waitLoad(wc2, 45000);
    await wait(4000);
    const blockedOff = adblock.blockedCount(wc2.id);
    adblock.settings.removeWhitelist('speedtest.net');
    result.steps.whitelist = { blockedOn, blockedOff };

    // 多标签页：两个标签各自一个 webContents、切换、新建（默认 MioCore 导航）、后台标签也有注入脚本、关闭 / 恢复、收起 + 角标
    result.steps.tabs = await tabsSmoke({ browser, ytWc, wc2, out, getMainWindow });

    // 容器（登录状态隔离）：两个容器访问同一个本地测试页互不可见（desktop/src/containers-smoke.js）
    if (containers) result.steps.containers = await require('./containers-smoke').run({ containers, adblock });
    // 多标签 × 容器
    if (containers) result.steps.tabsContainers = await tabsContainersSmoke({ browser, containers });

    const s = result.steps;
    result.ok =
      s.engine.ready &&
      JSON.parse(s.main.bridge).open === 'function' &&
      s.youtube.blocked > 0 &&
      s.youtube.page.hidden === false &&
      s.youtube.page.ytFocus === true &&
      s.youtube.page.ytFocusStyle === true &&
      s.youtube.page.media === true &&
      blockedOn > 0 &&
      blockedOff === 0 &&
      s.webrtc.blocked === 'undefined' &&
      s.webrtc.allowed === 'function' &&
      (!s.userscripts || s.userscripts.ok === true) &&
      s.tabs.ok === true &&
      s.zoom.ok === true &&
      (!containers || (s.containers && s.containers.ok === true)) &&
      (!containers || (s.tabsContainers && s.tabsContainers.ok === true));
    clearTimeout(guard);
    finish(result.ok ? 0 : 1);
  } catch (e) {
    result.error = String((e && e.stack) || e);
    clearTimeout(guard);
    finish(1);
  }
}

module.exports = { runSmoke };
