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
      browser.command('selectTab', String(store.tabs[store.indexOf(bg.id) - 1].id));
    } catch (e) {
      r.screenshotError = String(e);
    }
    browser.selectTab(store.tabs.find((t) => browser.views.get(t.id) && browser.views.get(t.id).webContents === nt).id);
    // 关闭当前（新标签页）→ 恢复关闭
    const before = store.size;
    browser.command('closeTab');
    r.afterClose = store.size;
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

async function runSmoke({ out, adblock, browser, getMainWindow }) {
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
  }, 150000);
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
          "JSON.stringify({ hidden: document.hidden, visibility: document.visibilityState, hasPlayerResponse: typeof window.ytInitialPlayerResponse === 'object' && window.ytInitialPlayerResponse !== null, adPlacements: window.ytInitialPlayerResponse ? typeof window.ytInitialPlayerResponse.adPlacements : 'n/a', playerAds: window.ytInitialPlayerResponse ? typeof window.ytInitialPlayerResponse.playerAds : 'n/a', ytFocus: !!window.__mioYTFocus, ytFocusStyle: !!document.getElementById('mio-yt-focus-style'), ytPlayables: document.documentElement.classList.contains('mio-hide-playables') })",
        ),
      ),
    };

    // 白名单后同一页面不再拦截（MioCore 打开外链 = 新标签：speedtest 在第二个标签里）
    const ytWc = wc;
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

    const s = result.steps;
    result.ok =
      s.engine.ready &&
      JSON.parse(s.main.bridge).open === 'function' &&
      s.youtube.blocked > 0 &&
      s.youtube.page.hidden === false &&
      s.youtube.page.ytFocus === true &&
      s.youtube.page.ytFocusStyle === true &&
      blockedOn > 0 &&
      blockedOff === 0 &&
      s.tabs.ok === true;
    clearTimeout(guard);
    finish(result.ok ? 0 : 1);
  } catch (e) {
    result.error = String((e && e.stack) || e);
    clearTimeout(guard);
    finish(1);
  }
}

module.exports = { runSmoke };
