// WebRTC 控制脚本（ios/App/App/MioWebRTCGuard.swift 的 webrtcGuard）在 jsdom 里跑：
// 屏蔽 RTC* / MediaStreamTrack、getUserMedia 拒绝、放行列表（含子域名 / 顶层站点）、动态 iframe。
import test from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';
import { extractFrom } from './swift-js.mjs';

const TEMPLATE = extractFrom('ios/App/App/MioWebRTCGuard.swift', 'webrtcGuard');
const script = (allow = []) => TEMPLATE.replace('__MIO_WEBRTC_CONFIG__', JSON.stringify({ allow }));

const RTC = ['RTCPeerConnection', 'webkitRTCPeerConnection', 'RTCDataChannel', 'RTCSessionDescription', 'RTCIceCandidate', 'MediaStreamTrack', 'RTCRtpSender', 'RTCFancyNewThing'];

/// jsdom 没有 WebRTC：装上假的构造函数和 mediaDevices（与浏览器一样放在 window 上、可配置）
function stub(w) {
  for (const n of RTC) {
    Object.defineProperty(w, n, { value: function () {}, writable: true, configurable: true, enumerable: false });
  }
  class MediaDevices {
    getUserMedia() { return Promise.resolve('stream'); }
    enumerateDevices() { return Promise.resolve([{ kind: 'videoinput' }]); }
    getDisplayMedia() { return Promise.resolve('screen'); }
  }
  w.MediaDevices = MediaDevices;
  Object.defineProperty(w.navigator, 'mediaDevices', { value: new MediaDevices(), configurable: true });
  w.navigator.webkitGetUserMedia = () => {};
}

function setup(url = 'https://www.example.com/', allow = []) {
  const dom = new JSDOM('<!doctype html><html><head></head><body></body></html>', { url, runScripts: 'outside-only' });
  const w = dom.window;
  stub(w);
  w.eval(script(allow));
  return w;
}

test('开启时 RTC* 接口和 MediaStreamTrack 都是 undefined', () => {
  const w = setup();
  for (const n of RTC) assert.equal(w.eval(`typeof ${n}`), 'undefined', n);
  assert.equal(w.eval('typeof RTCPeerConnection === "undefined"'), true);
  assert.equal(w.eval('"RTCPeerConnection" in window'), false);
  assert.equal(w.__mioRTCGuard, true);
});

test('getUserMedia / getDisplayMedia 拒绝（NotAllowedError），enumerateDevices 为空，旧接口删除', async () => {
  const w = setup();
  await assert.rejects(w.navigator.mediaDevices.getUserMedia({ video: true }), (e) => e.name === 'NotAllowedError');
  await assert.rejects(w.navigator.mediaDevices.getDisplayMedia(), (e) => e.name === 'NotAllowedError');
  assert.equal((await w.navigator.mediaDevices.enumerateDevices()).length, 0);
  // 原型上的也改了（页面另拿 MediaDevices.prototype.getUserMedia 也没用）
  await assert.rejects(w.MediaDevices.prototype.getUserMedia.call(w.navigator.mediaDevices, {}), (e) => e.name === 'NotAllowedError');
  assert.equal(typeof w.navigator.webkitGetUserMedia, 'undefined');
});

test('放行列表：站点本身和子域名不处理，其他站点照常屏蔽', () => {
  const allowed = setup('https://meet.google.com/abc-defg-hij', ['meet.google.com']);
  assert.equal(allowed.eval('typeof RTCPeerConnection'), 'function');
  assert.equal(allowed.__mioRTCGuard, false);
  // 放行站点里的 iframe（顶层站点在放行列表）也不处理
  const f = allowed.document.createElement('iframe');
  allowed.document.body.appendChild(f);
  assert.notEqual(f.contentWindow.__mioRTCGuard, true);
  const sub = setup('https://a.meet.google.com/', ['meet.google.com']);
  assert.equal(sub.eval('typeof RTCPeerConnection'), 'function');
  const parent = setup('https://google.com/', ['meet.google.com']);
  assert.equal(parent.eval('typeof RTCPeerConnection'), 'undefined');
  const lookalike = setup('https://evilmeet.google.com/', ['meet.google.com']);
  assert.equal(lookalike.eval('typeof RTCPeerConnection'), 'undefined');
});

test('动态创建的 iframe：拿 contentWindow / 插入文档时同样屏蔽', () => {
  const dom = new JSDOM('<!doctype html><html><body></body></html>', { url: 'https://www.example.com/', runScripts: 'outside-only' });
  const w = dom.window;
  stub(w);
  // 脚本注入前就存在的 iframe：先拿到原始 contentWindow，装上假接口
  const early = w.document.createElement('iframe');
  w.document.body.appendChild(early);
  const rawGet = Object.getOwnPropertyDescriptor(w.HTMLIFrameElement.prototype, 'contentWindow').get;
  stub(rawGet.call(early));
  w.eval(script());
  // 通过 contentWindow 访问 → 被处理
  assert.equal(early.contentWindow.__mioRTCGuard, true);
  assert.equal(typeof early.contentWindow.RTCPeerConnection, 'undefined');
  // 新建并插入的 iframe（appendChild / append / insertBefore）
  const f1 = w.document.createElement('iframe');
  w.document.body.appendChild(f1);
  assert.equal(rawGet.call(f1).__mioRTCGuard, true);
  const wrap = w.document.createElement('div');
  const f2 = w.document.createElement('iframe');
  wrap.append(f2);
  w.document.body.append(wrap);
  assert.equal(rawGet.call(f2).__mioRTCGuard, true);
  // window.frames[0] 也已处理（插入时就做了，不依赖 contentWindow getter）
  assert.equal(w.frames[1].__mioRTCGuard, true);
});

test('不用 innerHTML、不破坏页面的 DOM 操作', () => {
  const w = setup();
  const d = w.document;
  const ul = d.createElement('ul');
  d.body.appendChild(ul);
  ul.append(d.createElement('li'), 'text');
  ul.insertBefore(d.createElement('li'), ul.firstChild);
  ul.innerHTML = '<li>a</li><iframe></iframe>';
  assert.equal(ul.children.length, 2);
  assert.equal(ul.querySelector('iframe').contentWindow.__mioRTCGuard, true);
  assert.ok(!/innerHTML\s*=/.test(TEMPLATE), 'guard must not assign innerHTML');
});

test('重复注入是幂等的', () => {
  const w = setup();
  w.eval(script());
  assert.equal(w.eval('typeof RTCPeerConnection'), 'undefined');
});
