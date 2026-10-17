// 自动生成：来源 ios/App/App/MioUserScriptCore.swift（MIO_JS_BEGIN userscriptRuntime）。改那里，然后 node scripts/sync-userscript-runtime.mjs
// MIO_PARAMS GM, GM_info, unsafeWindow, GM_addStyle, GM_getValue, GM_setValue, GM_deleteValue, GM_listValues, GM_xmlhttpRequest, GM_openInTab, GM_setClipboard, GM_registerMenuCommand, GM_unregisterMenuCommand, GM_notification, GM_getResourceText, GM_getResourceURL, GM_addValueChangeListener, GM_removeValueChangeListener, GM_log, GM_addElement
(function (C, main) {
  'use strict';
  var w = window;
  var d = document;
  var isTop;
  try { isTop = w.top === w; } catch (e) { isTop = false; }
  if (C.noframes && !isTop) return;
  if (!/^(https?|file):$/.test(location.protocol)) return;
  var href = String(location.href);
  var noHash = href.split('#')[0];
  function test(rules, url) {
    for (var i = 0; i < (rules || []).length; i++) {
      try { if (new RegExp(rules[i].s, rules[i].i ? 'i' : '').test(url)) return true; } catch (e) {}
    }
    return false;
  }
  var hit = C.matchAll ? /^https?:/i.test(href) : (test(C.match, noHash) || test(C.include, href));
  if (!hit || test(C.exclude, href) || test(C.excludeMatch, noHash)) return;
  var ranKey = '__mioUserScriptRan';
  try {
    var ran = w[ranKey] || (Object.defineProperty(w, ranKey, { value: {}, configurable: false }), w[ranKey]);
    if (ran[C.id]) return;
    ran[C.id] = 1;
  } catch (e) {}

  var label = '[Mio 用户脚本] ' + C.name;
  var handler = null;
  try { handler = C.isolated && w.webkit && w.webkit.messageHandlers && w.webkit.messageHandlers[C.handler] || null; } catch (e) { handler = null; }
  // Android（WebMessageListener，页面世界 + 每脚本 token）/ Windows（Electron 隔离 world 里 contextBridge 暴露的 invoke）
  if (!handler && C.isolated && C.bridge) handler = nativeBridge(C.bridge);
  function nativeBridge(name) {
    var b = null;
    try { b = w[name]; } catch (e) { b = null; }
    if (!b) return null;
    var def = Object.defineProperty, str = JSON.stringify, parse = JSON.parse;
    if (typeof b.invoke === 'function') {
      var inv = b.invoke;
      return { postMessage: function (m) { return inv(m); } };
    }
    if (typeof b.postMessage !== 'function') return null;
    var send = b.postMessage.bind(b);
    var pending = {};
    var n = 0;
    var onMsg = function (ev) {
      var r;
      try { r = parse(ev && ev.data); } catch (e) { return; }
      if (!r || r.sid !== C.id || !pending[r.seq]) return;
      var p = pending[r.seq];
      delete pending[r.seq];
      clearTimeout(p[2]);
      if (r.error) p[1](new Error(String(r.error))); else p[0](r.result);
    };
    if (typeof b.addEventListener === 'function') b.addEventListener('message', onMsg); else b.onmessage = onMsg;
    return {
      postMessage: function (m) {
        return new Promise(function (resolve, reject) {
          var seq = ++n;
          var timer = setTimeout(function () { if (pending[seq]) { delete pending[seq]; reject(new Error('timeout')); } }, 120000);
          pending[seq] = [resolve, reject, timer];
          def(m, 'seq', { value: seq, enumerable: true });
          def(m, 'token', { value: String(C.token || ''), enumerable: true });
          try { send(str(m)); } catch (e) { delete pending[seq]; clearTimeout(timer); reject(e); }
        });
      }
    };
  }
  function post(op, payload) {
    var msg = payload || {};
    msg.op = op;
    msg.id = C.id;
    if (!handler) return Promise.reject(new Error('GM API 不可用（脚本未 @grant 或运行在页面世界）'));
    try { return Promise.resolve(handler.postMessage(msg)); } catch (e) { return Promise.reject(e); }
  }

  // ---- GM_addStyle / GM_addElement（DOM API，不用 innerHTML：兼容 Trusted Types）
  function whenRoot(fn) {
    var r = d.head || d.documentElement;
    if (r) { fn(r); return; }
    var mo = new MutationObserver(function () {
      var x = d.head || d.documentElement;
      if (x) { mo.disconnect(); fn(x); }
    });
    mo.observe(d, { childList: true, subtree: true });
  }
  function addStyle(css) {
    var s = d.createElement('style');
    s.setAttribute('data-mio-userscript', C.id);
    s.textContent = String(css);
    whenRoot(function (r) { r.appendChild(s); });
    return s;
  }
  function addElement(parent, tag, attrs) {
    if (typeof parent === 'string') { attrs = tag; tag = parent; parent = null; }
    var el = d.createElement(String(tag));
    var a = attrs || {};
    Object.keys(a).forEach(function (k) {
      if (k === 'textContent') el.textContent = a[k];
      else el.setAttribute(k, a[k]);
    });
    if (parent) parent.appendChild(el); else whenRoot(function (r) { r.appendChild(el); });
    return el;
  }

  // ---- 存储（原生按脚本隔离持久化；这里是本页的同步缓存）
  var V = C.values || {};
  var listeners = {};
  var nextListener = 1;
  function notify(key, oldV, newV) {
    Object.keys(listeners).forEach(function (k) {
      var l = listeners[k];
      if (l.key === key) { try { l.fn(key, oldV, newV, false); } catch (e) {} }
    });
  }
  function getValue(key, def) {
    key = String(key);
    if (!Object.prototype.hasOwnProperty.call(V, key)) return def;
    try { return JSON.parse(V[key]); } catch (e) { return def; }
  }
  function setValue(key, value) {
    key = String(key);
    if (value === undefined) { deleteValue(key); return; }
    var old = getValue(key);
    var json = JSON.stringify(value);
    if (json === undefined) return;
    V[key] = json;
    post('setValue', { key: key, value: json }).catch(function (e) { console.warn(label, 'GM_setValue', e); });
    notify(key, old, value);
  }
  function deleteValue(key) {
    key = String(key);
    if (!Object.prototype.hasOwnProperty.call(V, key)) return;
    var old = getValue(key);
    delete V[key];
    post('deleteValue', { key: key }).catch(function () {});
    notify(key, old, undefined);
  }
  function listValues() { return Object.keys(V); }
  function addValueChangeListener(key, fn) {
    var id = nextListener++;
    listeners[id] = { key: String(key), fn: fn };
    return id;
  }
  function removeValueChangeListener(id) { delete listeners[id]; }

  // ---- GM_xmlhttpRequest（原生 URLSession 代发）
  var seq = 0;
  function b64encode(u8) {
    var s = '';
    for (var i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000));
    return btoa(s);
  }
  function b64decode(b64) {
    var s = atob(b64 || '');
    var u8 = new Uint8Array(s.length);
    for (var i = 0; i < s.length; i++) u8[i] = s.charCodeAt(i);
    return u8;
  }
  function encodeBody(data, headers) {
    if (data === undefined || data === null) return Promise.resolve(null);
    if (typeof data === 'string') return Promise.resolve({ text: data });
    if (typeof URLSearchParams !== 'undefined' && data instanceof URLSearchParams) {
      if (!hasHeader(headers, 'content-type')) headers['Content-Type'] = 'application/x-www-form-urlencoded;charset=UTF-8';
      return Promise.resolve({ text: data.toString() });
    }
    if (data instanceof ArrayBuffer) return Promise.resolve({ base64: b64encode(new Uint8Array(data)) });
    if (ArrayBuffer.isView(data)) return Promise.resolve({ base64: b64encode(new Uint8Array(data.buffer, data.byteOffset, data.byteLength)) });
    if ((typeof Blob !== 'undefined' && data instanceof Blob) || (typeof FormData !== 'undefined' && data instanceof FormData)) {
      var r = new Response(data);
      var ct = r.headers.get('content-type') || (data.type || '');
      if (ct && !hasHeader(headers, 'content-type')) headers['Content-Type'] = ct;
      return r.arrayBuffer().then(function (ab) { return { base64: b64encode(new Uint8Array(ab)) }; });
    }
    return Promise.resolve({ text: String(data) });
  }
  function hasHeader(h, name) {
    return Object.keys(h).some(function (k) { return k.toLowerCase() === name; });
  }
  function parseHeaders(raw) {
    var out = {};
    String(raw || '').split(/\r?\n/).forEach(function (line) {
      var i = line.indexOf(':');
      if (i > 0) out[line.slice(0, i).trim().toLowerCase()] = line.slice(i + 1).trim();
    });
    return out;
  }
  function xhr(details) {
    details = details || {};
    var reqId = C.id + ':' + (++seq);
    var state = { done: false, aborted: false };
    var headers = {};
    Object.keys(details.headers || {}).forEach(function (k) { headers[k] = String(details.headers[k]); });
    function fire(name, resp) {
      var fn = details[name];
      if (typeof fn === 'function') { try { fn.call(details, resp); } catch (e) { console.error(label, name, e); } }
    }
    function base(extra) {
      var r = { readyState: 4, status: 0, statusText: '', responseHeaders: '', response: null, responseText: '', responseXML: null, finalUrl: url, context: details.context };
      Object.keys(extra || {}).forEach(function (k) { r[k] = extra[k]; });
      return r;
    }
    var url;
    try { url = new URL(String(details.url), location.href).href; } catch (e) { url = String(details.url); }
    var handle = {
      abort: function () {
        if (state.done || state.aborted) return;
        state.aborted = true;
        post('xhrAbort', { reqId: reqId }).catch(function () {});
        var r = base({ error: 'aborted' });
        fire('onabort', r);
        fire('onloadend', r);
      }
    };
    fire('onloadstart', base({ readyState: 1 }));
    encodeBody(details.data, headers).then(function (body) {
      if (state.aborted) return null;
      return post('xhr', {
        reqId: reqId,
        method: String(details.method || 'GET').toUpperCase(),
        url: url,
        headers: headers,
        body: body,
        timeout: Number(details.timeout) || 0,
        anonymous: !!details.anonymous,
        responseType: String(details.responseType || ''),
        overrideMimeType: details.overrideMimeType ? String(details.overrideMimeType) : '',
        user: details.user ? String(details.user) : '',
        password: details.password ? String(details.password) : '',
        userAgent: navigator.userAgent
      });
    }).then(function (res) {
      if (state.aborted || !res) return;
      state.done = true;
      if (res.error) {
        var er = base({ error: res.error, status: 0, statusText: res.error });
        fire(res.timeout ? 'ontimeout' : 'onerror', er);
        fire('onloadend', er);
        return;
      }
      var type = String(details.responseType || '').toLowerCase();
      var text = typeof res.text === 'string' ? res.text : '';
      var hdrs = parseHeaders(res.headers);
      var mime = details.overrideMimeType || hdrs['content-type'] || '';
      var response = text;
      if (type === 'arraybuffer' || type === 'blob') {
        var u8 = b64decode(res.base64);
        response = type === 'blob' ? new Blob([u8], { type: mime }) : u8.buffer;
      } else if (type === 'json') {
        try { response = JSON.parse(text); } catch (e) { response = null; }
      }
      var r = base({ status: res.status, statusText: res.statusText || '', responseHeaders: res.headers || '', finalUrl: res.finalUrl || url, responseText: text, response: response });
      var xml = null;
      var xmlDone = false;
      Object.defineProperty(r, 'responseXML', {
        enumerable: true,
        get: function () {
          if (!xmlDone) {
            xmlDone = true;
            try {
              var t = type === 'document' || /html/i.test(mime) ? 'text/html' : 'text/xml';
              xml = new DOMParser().parseFromString(text, t);
            } catch (e) { xml = null; }
          }
          return xml;
        }
      });
      if (type === 'document') r.response = r.responseXML;
      fire('onreadystatechange', r);
      fire('onprogress', r);
      fire('onload', r);
      fire('onloadend', r);
    }, function (err) {
      if (state.aborted) return;
      state.done = true;
      var r = base({ error: String((err && err.message) || err), statusText: String((err && err.message) || err) });
      fire('onerror', r);
      fire('onloadend', r);
    });
    return handle;
  }
  function xhrPromise(details) {
    var h;
    var p = new Promise(function (resolve, reject) {
      var dd = {};
      Object.keys(details || {}).forEach(function (k) { dd[k] = details[k]; });
      var ol = dd.onload, oe = dd.onerror, ot = dd.ontimeout, oa = dd.onabort;
      dd.onload = function (r) { if (ol) ol(r); resolve(r); };
      dd.onerror = function (r) { if (oe) oe(r); reject(r); };
      dd.ontimeout = function (r) { if (ot) ot(r); reject(r); };
      dd.onabort = function (r) { if (oa) oa(r); reject(r); };
      h = xhr(dd);
    });
    p.abort = function () { if (h) h.abort(); };
    return p;
  }

  // ---- 其他 GM API
  function openInTab(url, opts) {
    var u;
    try { u = new URL(String(url), location.href).href; } catch (e) { u = String(url); }
    var active = true;
    if (typeof opts === 'boolean') active = !opts;
    else if (opts && (opts.active === false || opts.loadInBackground === true)) active = false;
    var tab = { closed: false, onclose: null, close: function () { tab.closed = true; } };
    post('openTab', { url: u, active: active }).catch(function (e) { console.warn(label, 'GM_openInTab', e); });
    return tab;
  }
  function setClipboard(data, info) {
    var type = typeof info === 'string' ? info : (info && (info.type || info.mimetype)) || 'text';
    return post('setClipboard', { data: String(data), type: String(type) }).catch(function (e) { console.warn(label, 'GM_setClipboard', e); });
  }
  var menu = {};
  var nextMenu = 1;
  function syncMenu() {
    if (!isTop) return;
    post('menu', { commands: Object.keys(menu).map(function (k) { return { id: String(k), name: menu[k].name }; }) }).catch(function () {});
  }
  function registerMenuCommand(name, fn) {
    var id = nextMenu++;
    menu[id] = { name: String(name), fn: fn };
    syncMenu();
    return id;
  }
  function unregisterMenuCommand(id) { delete menu[id]; syncMenu(); }
  if (C.isolated && isTop) {
    var runMenu = function (id) { var m = menu[id]; if (m && typeof m.fn === 'function') { try { m.fn(); } catch (e) { console.error(label, e); } } };
    try {
      Object.defineProperty(w, '__mioUserScriptMenu', { configurable: true, value: runMenu });
    } catch (e) {}
    // Android 所有脚本共用页面世界：按脚本 id 分开（原生执行 __mioUserScriptMenus[id](命令)）
    if (C.bridge) {
      try {
        if (!w.__mioUserScriptMenus) Object.defineProperty(w, '__mioUserScriptMenus', { configurable: true, value: {} });
        w.__mioUserScriptMenus[C.id] = runMenu;
      } catch (e) {}
    }
  }
  function notification(details, title, image, onclick) {
    var o = typeof details === 'string' ? { text: details, title: title, image: image, onclick: onclick } : (details || {});
    var box = d.createElement('div');
    box.setAttribute('data-mio-userscript-toast', C.id);
    box.style.cssText = 'position:fixed;z-index:2147483647;left:50%;bottom:24px;transform:translateX(-50%);max-width:86vw;padding:10px 16px;border-radius:12px;background:rgba(30,30,30,.92);color:#fff;font:14px -apple-system,system-ui,sans-serif;box-shadow:0 4px 18px rgba(0,0,0,.3);cursor:pointer';
    var t = d.createElement('b');
    t.textContent = String(o.title || C.name);
    var p = d.createElement('div');
    p.textContent = String(o.text || '');
    box.appendChild(t);
    box.appendChild(p);
    box.addEventListener('click', function () { box.remove(); if (typeof o.onclick === 'function') o.onclick(); });
    whenRoot(function () { (d.body || d.documentElement).appendChild(box); });
    setTimeout(function () { if (box.parentNode) { box.remove(); if (typeof o.ondone === 'function') o.ondone(); } }, Number(o.timeout) || 5000);
  }
  var R = C.resources || {};
  function getResourceText(name) { return Object.prototype.hasOwnProperty.call(R, name) ? R[name] : null; }
  function getResourceURL(name) {
    var t = getResourceText(name);
    if (t === null) return null;
    return 'data:text/plain;charset=utf-8;base64,' + b64encode(new TextEncoder().encode(t));
  }
  function log() { try { console.log.apply(console, [label].concat([].slice.call(arguments))); } catch (e) {} }

  var info = C.info || {};
  var iso = !!C.isolated;
  var gm = {
    info: info,
    addStyle: function (css) { return Promise.resolve(addStyle(css)); },
    addElement: function (a, b, c) { return Promise.resolve(addElement(a, b, c)); },
    getValue: function (k, def) { return Promise.resolve(getValue(k, def)); },
    setValue: function (k, v) { setValue(k, v); return Promise.resolve(); },
    deleteValue: function (k) { deleteValue(k); return Promise.resolve(); },
    listValues: function () { return Promise.resolve(listValues()); },
    xmlHttpRequest: xhrPromise,
    openInTab: function (u, o) { return Promise.resolve(openInTab(u, o)); },
    setClipboard: function (data, i) { return setClipboard(data, i).then(function () {}); },
    registerMenuCommand: function (n, f) { return Promise.resolve(registerMenuCommand(n, f)); },
    unregisterMenuCommand: function (id) { unregisterMenuCommand(id); return Promise.resolve(); },
    notification: function (a, b, c, e) { notification(a, b, c, e); return Promise.resolve(); },
    getResourceText: function (n) { return Promise.resolve(getResourceText(n)); },
    getResourceUrl: function (n) { return Promise.resolve(getResourceURL(n)); },
    log: function () { log.apply(null, arguments); return Promise.resolve(); }
  };
  if (!iso) {
    // @grant none：页面世界，只有 GM_info 和不需要原生的 API
    ['getValue', 'setValue', 'deleteValue', 'listValues', 'xmlHttpRequest', 'openInTab', 'setClipboard'].forEach(function (k) { delete gm[k]; });
  }

  function start() {
    try {
      main.call(w,
        gm, info, w,
        addStyle,
        iso ? getValue : undefined,
        iso ? setValue : undefined,
        iso ? deleteValue : undefined,
        iso ? listValues : undefined,
        iso ? xhr : undefined,
        iso ? openInTab : undefined,
        iso ? setClipboard : undefined,
        registerMenuCommand, unregisterMenuCommand,
        notification, getResourceText, getResourceURL,
        addValueChangeListener, removeValueChangeListener,
        log, addElement);
    } catch (e) {
      console.error(label, e);
    }
  }
  if (C.runAt === 'document-start') {
    start();
  } else if (C.runAt === 'document-end') {
    if (d.readyState === 'loading') d.addEventListener('DOMContentLoaded', start, { once: true }); else start();
  } else {
    var idle = function () { setTimeout(start, 0); };
    if (d.readyState === 'loading') d.addEventListener('DOMContentLoaded', idle, { once: true }); else idle();
  }
})

