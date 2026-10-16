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
    result.steps.youtube = {
      url: wc.getURL(),
      title: wc.getTitle(),
      blocked: adblock.blockedCount(wc.id),
      page: JSON.parse(
        await wc.executeJavaScript(
          "JSON.stringify({ hidden: document.hidden, visibility: document.visibilityState, hasPlayerResponse: typeof window.ytInitialPlayerResponse === 'object' && window.ytInitialPlayerResponse !== null, adPlacements: window.ytInitialPlayerResponse ? typeof window.ytInitialPlayerResponse.adPlacements : 'n/a', playerAds: window.ytInitialPlayerResponse ? typeof window.ytInitialPlayerResponse.playerAds : 'n/a' })",
        ),
      ),
    };

    // 白名单后同一页面不再拦截
    adblock.resetCount(wc.id);
    browser.open('https://www.speedtest.net/');
    await waitLoad(wc, 45000);
    await wait(4000);
    const blockedOn = adblock.blockedCount(wc.id);
    adblock.settings.addWhitelist('speedtest.net');
    adblock.resetCount(wc.id);
    wc.reload();
    await waitLoad(wc, 45000);
    await wait(4000);
    const blockedOff = adblock.blockedCount(wc.id);
    adblock.settings.removeWhitelist('speedtest.net');
    result.steps.whitelist = { blockedOn, blockedOff };

    const s = result.steps;
    result.ok =
      s.engine.ready &&
      JSON.parse(s.main.bridge).open === 'function' &&
      s.youtube.blocked > 0 &&
      s.youtube.page.hidden === false &&
      blockedOn > 0 &&
      blockedOff === 0;
    clearTimeout(guard);
    finish(result.ok ? 0 : 1);
  } catch (e) {
    result.error = String((e && e.stack) || e);
    clearTimeout(guard);
    finish(1);
  }
}

module.exports = { runSmoke };
