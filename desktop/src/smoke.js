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

    // WebRTC 控制：默认屏蔽（YouTube 页面里 RTCPeerConnection 不存在），放行 example.com 后可用
    const rtc = browser.webrtc;
    result.steps.webrtc = { blocked: await wc.executeJavaScript('typeof RTCPeerConnection'), policy: wc.getWebRTCIPHandlingPolicy() };
    if (rtc) {
      rtc.setAllowed('example.com', true);
      browser.open('https://example.com/');
      await waitLoad(wc, 30000);
      await wait(1500);
      result.steps.webrtc.allowed = await wc.executeJavaScript('typeof RTCPeerConnection');
      result.steps.webrtc.allowedPolicy = wc.getWebRTCIPHandlingPolicy();
      rtc.setAllowed('example.com', false);
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
      await waitLoad(wc, 30000);
      await wait(2000);
      const page = JSON.parse(await wc.executeJavaScript("JSON.stringify({ iso: document.documentElement.getAttribute('data-mio-us-iso'), page: typeof window.__mioUsPage, bridge: typeof window.mioUserScriptNative })"));
      const stored = us.store.values(a.id).smoke;
      us.store.delete(a.id);
      us.store.delete(b.id);
      result.steps.userscripts = { page, stored, ok: page.iso === 'undefined:function:object' && page.page === 'number' && page.bridge === 'undefined' && stored === '42' };
    }

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

    // 容器（登录状态隔离）：两个容器访问同一个本地测试页互不可见（desktop/src/containers-smoke.js）
    if (containers) result.steps.containers = await require('./containers-smoke').run({ containers, adblock });

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
      (!containers || (s.containers && s.containers.ok === true));
    clearTimeout(guard);
    finish(result.ok ? 0 : 1);
  } catch (e) {
    result.error = String((e && e.stack) || e);
    clearTimeout(guard);
    finish(1);
  }
}

module.exports = { runSmoke };
