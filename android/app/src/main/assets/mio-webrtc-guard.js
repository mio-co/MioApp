// 自动生成：来源 ios/App/App/MioWebRTCGuard.swift（MIO_JS_BEGIN webrtcGuard）。改那里，然后 node scripts/sync-webrtc-guard.mjs
(function () {
  'use strict';
  var CFG = __MIO_WEBRTC_CONFIG__;
  var ALLOW = (CFG && CFG.allow) || [];
  var NAMES = ['RTCPeerConnection', 'webkitRTCPeerConnection', 'mozRTCPeerConnection', 'RTCDataChannel',
    'RTCSessionDescription', 'mozRTCSessionDescription', 'RTCIceCandidate', 'mozRTCIceCandidate', 'MediaStreamTrack',
    'RTCRtpSender', 'RTCRtpReceiver', 'RTCRtpTransceiver', 'RTCDtlsTransport', 'RTCIceTransport', 'RTCSctpTransport',
    'RTCPeerConnectionIceEvent', 'RTCPeerConnectionIceErrorEvent', 'RTCDataChannelEvent', 'RTCTrackEvent',
    'RTCCertificate', 'RTCDTMFSender', 'RTCDTMFToneChangeEvent', 'RTCStatsReport', 'RTCError', 'RTCErrorEvent',
    'RTCRtpScriptTransform', 'RTCEncodedAudioFrame', 'RTCEncodedVideoFrame', 'MediaStreamTrackEvent'];
  var RTC_RE = /^(webkit|moz)?RTC[A-Z]/;

  function allowedHost(h) {
    h = String(h || '').toLowerCase().replace(/\.+$/, '');
    if (!h) return false;
    for (var i = 0; i < ALLOW.length; i++) {
      var a = ALLOW[i];
      if (h === a || h.slice(-(a.length + 1)) === '.' + a) return true;
    }
    return false;
  }
  function originHost(o) {
    var m = /^[a-z][a-z0-9+.-]*:\/\/(?:[^@\/]*@)?(\[[^\]]*\]|[^:\/]*)/i.exec(String(o || ''));
    return m ? m[1] : '';
  }
  // 放行：frame 自己的主机，或顶层页面的主机在放行列表里
  function siteAllowed(win) {
    if (!ALLOW.length) return false;
    try { if (allowedHost(win.location.hostname)) return true; } catch (e) {}
    try {
      var ao = win.location.ancestorOrigins;
      if (ao && ao.length) {
        if (allowedHost(originHost(ao[ao.length - 1]))) return true;
        for (var i = 0; i < ao.length; i++) if (allowedHost(originHost(ao[i]))) return true;
      }
    } catch (e) {}
    try { if (win.top !== win && allowedHost(win.top.location.hostname)) return true; } catch (e) {}
    try { if (win.parent !== win && win.location.hostname === '' && allowedHost(originHost(win.document.referrer))) return true; } catch (e) {}
    return false;
  }

  function hide(obj, name) {
    if (!obj) return;
    try { delete obj[name]; } catch (e) {}
    try {
      if (name in obj) Object.defineProperty(obj, name, { value: undefined, writable: true, configurable: true, enumerable: false });
    } catch (e) {}
  }

  function wrapMethod(proto, name, after) {
    if (!proto) return;
    var desc = Object.getOwnPropertyDescriptor(proto, name);
    if (!desc || typeof desc.value !== 'function') return;
    var orig = desc.value;
    var wrapped = function () {
      var r = orig.apply(this, arguments);
      try { after(this, arguments, r); } catch (e) {}
      return r;
    };
    try { Object.defineProperty(wrapped, 'name', { value: name }); } catch (e) {}
    try { Object.defineProperty(proto, name, { value: wrapped, writable: desc.writable, configurable: desc.configurable, enumerable: desc.enumerable }); } catch (e) {}
  }

  function wrapGetter(proto, name, after) {
    if (!proto) return;
    var desc = Object.getOwnPropertyDescriptor(proto, name);
    if (!desc || typeof desc.get !== 'function') return;
    var get = desc.get;
    try {
      Object.defineProperty(proto, name, {
        get: function () { var r = get.call(this); try { after(this, r); } catch (e) {} return r; },
        set: desc.set, configurable: desc.configurable, enumerable: desc.enumerable
      });
    } catch (e) {}
  }

  function wrapSetter(proto, name, after) {
    if (!proto) return;
    var desc = Object.getOwnPropertyDescriptor(proto, name);
    if (!desc || typeof desc.set !== 'function') return;
    var set = desc.set;
    try {
      Object.defineProperty(proto, name, {
        get: desc.get,
        set: function (v) { set.call(this, v); try { after(this); } catch (e) {} },
        configurable: desc.configurable, enumerable: desc.enumerable
      });
    } catch (e) {}
  }

  function guardFramesIn(node) {
    if (!node || node.nodeType !== 1 && node.nodeType !== 11) return;
    var tag = node.nodeType === 1 ? String(node.tagName || '').toUpperCase() : '';
    if (tag === 'IFRAME' || tag === 'FRAME' || tag === 'OBJECT' || tag === 'EMBED') {
      try { guard(node.contentWindow); } catch (e) {}
    }
    if (node.querySelectorAll && (node.firstElementChild || node.nodeType === 11)) {
      var list;
      try { list = node.querySelectorAll('iframe,frame,object,embed'); } catch (e) { list = []; }
      for (var i = 0; i < list.length; i++) { try { guard(list[i].contentWindow); } catch (e) {} }
    }
  }

  function guard(win) {
    if (!win) return;
    try {
      if (win.__mioRTCGuard !== undefined) return;
      Object.defineProperty(win, '__mioRTCGuard', { value: false, writable: true, configurable: false, enumerable: false });
    } catch (e) { return; }
    if (siteAllowed(win)) return;
    try { win.__mioRTCGuard = true; } catch (e) {}

    var names = NAMES.slice();
    try {
      Object.getOwnPropertyNames(win).forEach(function (n) { if (RTC_RE.test(n) && names.indexOf(n) < 0) names.push(n); });
    } catch (e) {}
    names.forEach(function (n) { hide(win, n); });

    // 摄像头 / 麦克风 / 屏幕共享：拒绝；设备列表：空
    var P = win.Promise || Promise;
    var DE = win.DOMException || (typeof DOMException !== 'undefined' ? DOMException : Error);
    var deny = function () { return P.reject(new DE('WebRTC 已被 Mio 屏蔽（可在浏览器设置里放行此网站）', 'NotAllowedError')); };
    var none = function () { return P.resolve([]); };
    var nav = win.navigator;
    var MD = win.MediaDevices && win.MediaDevices.prototype;
    [MD, nav && nav.mediaDevices].forEach(function (o) {
      if (!o) return;
      try { Object.defineProperty(o, 'getUserMedia', { value: deny, writable: true, configurable: true }); } catch (e) {}
      try { Object.defineProperty(o, 'getDisplayMedia', { value: deny, writable: true, configurable: true }); } catch (e) {}
      try { Object.defineProperty(o, 'enumerateDevices', { value: none, writable: true, configurable: true }); } catch (e) {}
    });
    var NP = win.Navigator && win.Navigator.prototype;
    ['getUserMedia', 'webkitGetUserMedia', 'mozGetUserMedia'].forEach(function (n) { hide(NP, n); hide(nav, n); });

    // 子窗口：拿到 contentWindow / contentDocument、插入文档、window.open 时同样处理
    var IF = win.HTMLIFrameElement && win.HTMLIFrameElement.prototype;
    var FR = win.HTMLFrameElement && win.HTMLFrameElement.prototype;
    var OB = win.HTMLObjectElement && win.HTMLObjectElement.prototype;
    [IF, FR, OB].forEach(function (p) {
      wrapGetter(p, 'contentWindow', function (el, cw) { guard(cw); });
      wrapGetter(p, 'contentDocument', function (el, doc) { if (doc) guard(doc.defaultView); });
    });
    var NodeP = win.Node && win.Node.prototype;
    var ElP = win.Element && win.Element.prototype;
    var after = function (self, args) {
      for (var i = 0; i < args.length; i++) guardFramesIn(args[i]);
    };
    ['appendChild', 'insertBefore', 'replaceChild'].forEach(function (n) { wrapMethod(NodeP, n, after); });
    ['append', 'prepend', 'after', 'before', 'replaceWith', 'insertAdjacentElement', 'replaceChildren'].forEach(function (n) { wrapMethod(ElP, n, after); });
    var DF = win.DocumentFragment && win.DocumentFragment.prototype;
    ['append', 'prepend', 'replaceChildren'].forEach(function (n) { wrapMethod(DF, n, after); });
    wrapMethod(ElP, 'insertAdjacentHTML', function (self) { guardFramesIn(self.parentNode || self); });
    wrapSetter(ElP, 'innerHTML', function (self) { guardFramesIn(self); });
    wrapSetter(ElP, 'outerHTML', function () { guardFramesIn(win.document && win.document.documentElement); });
    var DocP = win.Document && win.Document.prototype;
    ['write', 'writeln'].forEach(function (n) { wrapMethod(DocP, n, function (doc) { guardFramesIn(doc.documentElement); }); });
    try {
      var open = win.open;
      if (typeof open === 'function') {
        win.open = function () { var w2 = open.apply(this, arguments); try { guard(w2); } catch (e) {} return w2; };
      }
    } catch (e) {}
    // 兜底：解析器插入的 iframe（不经过上面的方法）
    try {
      var MO = win.MutationObserver;
      if (MO && win.document) {
        new MO(function (records) {
          for (var i = 0; i < records.length; i++) {
            var added = records[i].addedNodes;
            for (var j = 0; j < added.length; j++) guardFramesIn(added[j]);
          }
        }).observe(win.document, { childList: true, subtree: true });
      }
    } catch (e) {}
  }

  guard(window);
})();

