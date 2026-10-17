/*
 * Mio 轻量翻译（内置浏览器注入脚本，自研实现）
 * - 网页翻译：双语对照（段落下方插入淡化译文）/ 仅译文 / 关闭；按站点自动翻译；划词翻译气泡
 * - YouTube 双语字幕：读取播放器 captionTracks，拉 timedtext（json3，含自动生成），按时间轴批量翻译，叠加原文 + 译文两行
 * - 引擎：微软（Bing 网页翻译接口；旧 Edge 令牌端点仍会先试一次）、谷歌（translate_a gtx）、自定义 OpenAI 兼容 API；失败自动回退到免费引擎
 *
 * 注入方式：document-start、页面主世界（YouTube 字幕需要读 ytInitialPlayerResponse / 播放器对象）。
 * 网络请求全部经原生消息桥（iOS WKScriptMessageHandlerWithReply / Android WebMessageListener / Electron preload），
 * 不受页面 CSP / CORS 影响；OpenAI 的 API Key 只在原生侧，脚本里拿不到。
 * 原生把下面 CONFIG_B64 的占位符替换成 base64(JSON 配置)。所有 DOM 都用 DOM API 构建（不用 innerHTML，兼容 Trusted Types）。
 * 单测：tools/MioAppTests/js/translate-*.test.mjs（node --test + jsdom，桥接口全部 mock）。
 */
(function (G) {
  'use strict';
  var CONFIG_B64 = '__MIO_TRANSLATE_CONFIG__';

  // ======================================================================= 语言

  var LANGS = [
    ['zh-CN', '简体中文', 'Simplified Chinese'], ['zh-TW', '繁體中文', 'Traditional Chinese'], ['en', 'English', 'English'],
    ['ja', '日本語', 'Japanese'], ['ko', '한국어', 'Korean'], ['fr', 'Français', 'French'], ['de', 'Deutsch', 'German'],
    ['es', 'Español', 'Spanish'], ['ru', 'Русский', 'Russian'], ['pt', 'Português', 'Portuguese'], ['it', 'Italiano', 'Italian'],
    ['vi', 'Tiếng Việt', 'Vietnamese'], ['th', 'ไทย', 'Thai'], ['id', 'Bahasa Indonesia', 'Indonesian'], ['ar', 'العربية', 'Arabic'],
  ];

  /** 归一化成内部代码：zh-Hans / zh-cn / zh → zh-CN；zh-Hant / zh-TW / zh-HK → zh-TW；其余取主标签（pt-BR → pt） */
  function normLang(code) {
    var c = String(code || '').trim().replace(/_/g, '-').toLowerCase();
    if (!c) return '';
    if (c === 'zh' || c === 'zh-cn' || c === 'zh-hans' || c === 'zh-sg' || c.indexOf('zh-hans') === 0 || c === 'cmn') return 'zh-CN';
    if (c === 'zh-tw' || c === 'zh-hk' || c === 'zh-mo' || c.indexOf('zh-hant') === 0) return 'zh-TW';
    if (c.indexOf('zh') === 0) return 'zh-CN';
    return c.split('-')[0];
  }

  /** 两个语言代码是否算同一种语言（简繁视为同一种：不重复翻译中文段落） */
  function sameLang(a, b) {
    var x = normLang(a), y = normLang(b);
    if (!x || !y) return false;
    if (x.indexOf('zh') === 0 && y.indexOf('zh') === 0) return true;
    return x === y;
  }

  function engineLang(engine, code) {
    var c = normLang(code) || 'zh-CN';
    if (engine === 'microsoft') {
      if (c === 'zh-CN') return 'zh-Hans';
      if (c === 'zh-TW') return 'zh-Hant';
      return c;
    }
    if (engine === 'openai') {
      for (var i = 0; i < LANGS.length; i++) if (LANGS[i][0] === c) return LANGS[i][2];
      return c;
    }
    return c; // google
  }

  function langLabel(code) {
    var c = normLang(code);
    for (var i = 0; i < LANGS.length; i++) if (LANGS[i][0] === c) return LANGS[i][1];
    return c;
  }

  // ======================================================================= 文本 / 语言识别

  var RE_LETTER = /[A-Za-z\u00C0-\u024F\u0370-\u03FF\u0400-\u04FF\u0590-\u05FF\u0600-\u06FF\u0900-\u097F\u0E00-\u0E7F\u1100-\u11FF\u3040-\u30FF\u3400-\u9FFF\uAC00-\uD7AF\uF900-\uFAFF]/;
  var SCRIPTS = {
    han: /[\u3400-\u9FFF\uF900-\uFAFF]/g,
    kana: /[\u3040-\u30FF]/g,
    hangul: /[\uAC00-\uD7AF\u1100-\u11FF]/g,
    cyr: /[\u0400-\u04FF]/g,
    thai: /[\u0E00-\u0E7F]/g,
    arabic: /[\u0600-\u06FF]/g,
    latin: /[A-Za-z\u00C0-\u024F]/g,
  };
  var STOPWORDS = {
    en: 'the and of to in is are was were that this it for on with as be by at from or an have has not you we they but can will would which their there what if about been more',
    fr: 'le la les des et est une un du que qui dans pour pas sur avec ce il elle nous vous sont au aux par plus mais ou cette son ses',
    de: 'der die das und ist nicht ein eine zu mit den von auf für sich des dem im auch es wir sie ich aber oder wird sind zum zur',
    es: 'el la los las que y en un una es por con para del se no al lo como más pero su sus le ya muy',
    pt: 'o os as que e do da em um uma para com não por se na no mais dos das ao foi são seu sua',
    it: 'il lo gli che e un una per con non del della sono nel anche da come ma più questo questa alla',
  };
  var STOP = {};
  Object.keys(STOPWORDS).forEach(function (k) {
    var set = {};
    STOPWORDS[k].split(' ').forEach(function (w) { set[w] = 1; });
    STOP[k] = set;
  });

  function countMatches(re, s) {
    var m = s.match(re);
    return m ? m.length : 0;
  }

  function hasLetters(s) {
    return RE_LETTER.test(String(s || ''));
  }

  /** 粗略判断一段文字的语言（只用于跳过已经是目标语言的段落）：返回 zh / ja / ko / ru / th / ar / en / fr / … / latin / null */
  function guessLang(text) {
    var s = String(text || '');
    var n = {};
    var letters = 0;
    Object.keys(SCRIPTS).forEach(function (k) {
      n[k] = countMatches(SCRIPTS[k], s);
      letters += n[k];
    });
    if (!letters) return null;
    if (n.kana > 0 && (n.kana + n.han) / letters > 0.5 && n.kana / (n.kana + n.han) > 0.08) return 'ja';
    if (n.han / letters > 0.5) return 'zh';
    if (n.hangul / letters > 0.5) return 'ko';
    if (n.cyr / letters > 0.5) return 'ru';
    if (n.thai / letters > 0.5) return 'th';
    if (n.arabic / letters > 0.5) return 'ar';
    if (n.latin / letters < 0.8) return null;
    var words = s.toLowerCase().split(/[^a-z\u00c0-\u024f']+/).filter(Boolean);
    if (!words.length) return 'latin';
    var best = null, bestHits = 0;
    Object.keys(STOP).forEach(function (lang) {
      var hits = 0;
      for (var i = 0; i < words.length; i++) if (STOP[lang][words[i]]) hits++;
      if (hits > bestHits) { best = lang; bestHits = hits; }
    });
    var need = words.length <= 6 ? 1 : 2;
    if (best && bestHits >= need && bestHits / words.length >= 0.12) return best;
    return 'latin';
  }

  /** 段落已经是目标语言（不翻译） */
  function isAlreadyTarget(text, target) {
    var g = guessLang(text);
    if (!g) return true;
    var t = normLang(target);
    if (t.indexOf('zh') === 0) return g === 'zh';
    return g === t;
  }

  function collapse(s) {
    return String(s || '').replace(/[\s\u00a0\u200b]+/g, ' ').trim();
  }

  /** 32 位 FNV-1a ×2（不同种子）→ 缓存键 */
  function hashText(s) {
    var h1 = 0x811c9dc5, h2 = 0x01000193 ^ 0x5bd1e995;
    for (var i = 0; i < s.length; i++) {
      var c = s.charCodeAt(i);
      h1 ^= c; h1 = Math.imul(h1, 0x01000193) >>> 0;
      h2 ^= c; h2 = Math.imul(h2, 0x5bd1e995) >>> 0; h2 ^= h2 >>> 13;
    }
    return (h1 >>> 0).toString(36) + (h2 >>> 0).toString(36) + s.length.toString(36);
  }

  function cacheKey(engine, target, text) {
    return 't1|' + engine + '|' + normLang(target) + '|' + hashText(text);
  }

  // ======================================================================= 批处理 / 缓存

  /**
   * 把 items（字符串）切成批：每批不超过 maxItems 条、总长不超过 maxChars；单条超长时单独成批。
   * 返回下标数组的数组（保持原顺序）。
   */
  function makeBatches(texts, opts) {
    var maxItems = (opts && opts.maxItems) || 50;
    var maxChars = (opts && opts.maxChars) || 4000;
    var sep = (opts && opts.sepLen) || 0;
    var out = [], cur = [], len = 0;
    for (var i = 0; i < texts.length; i++) {
      var l = String(texts[i]).length;
      if (cur.length && (cur.length >= maxItems || len + l + sep > maxChars)) {
        out.push(cur);
        cur = []; len = 0;
      }
      cur.push(i);
      len += l + (cur.length > 1 ? sep : 0);
    }
    if (cur.length) out.push(cur);
    return out;
  }

  /** 简单 LRU（Map 保持插入顺序） */
  function LRU(limit) {
    this.limit = limit || 2000;
    this.map = new Map();
  }
  LRU.prototype.get = function (k) {
    if (!this.map.has(k)) return undefined;
    var v = this.map.get(k);
    this.map.delete(k);
    this.map.set(k, v);
    return v;
  };
  LRU.prototype.set = function (k, v) {
    if (this.map.has(k)) this.map.delete(k);
    this.map.set(k, v);
    while (this.map.size > this.limit) this.map.delete(this.map.keys().next().value);
  };
  LRU.prototype.has = function (k) { return this.map.has(k); };
  Object.defineProperty(LRU.prototype, 'size', { get: function () { return this.map.size; } });

  // ======================================================================= 引擎（请求构造 / 解析是纯函数，网络经原生桥）

  var LIMITS = {
    microsoft: { maxItems: 25, maxChars: 900, sepLen: 1 },
    google: { maxItems: 50, maxChars: 4000 },
    openai: { maxItems: 40, maxChars: 6000 },
  };
  var MS_AUTH = 'https://edge.microsoft.com/translate/auth';
  var MS_API = 'https://api-edge.cognitive.microsofttranslator.com/translate';
  var BING_PAGE = 'https://www.bing.com/translator';
  var BING_API = 'https://www.bing.com/ttranslatev3';
  var GOOGLE_BATCH = 'https://translate.googleapis.com/translate_a/t';
  var GOOGLE_SINGLE = 'https://translate.googleapis.com/translate_a/single';

  function form(obj) {
    return Object.keys(obj).map(function (k) {
      var v = obj[k];
      if (Array.isArray(v)) return v.map(function (x) { return encodeURIComponent(k) + '=' + encodeURIComponent(x); }).join('&');
      return encodeURIComponent(k) + '=' + encodeURIComponent(v);
    }).join('&');
  }

  function EngineError(message, kind) {
    var e = new Error(message);
    e.kind = kind || 'engine';
    return e;
  }

  function parseJSON(body) {
    if (body && typeof body === 'object') return body;
    try { return JSON.parse(String(body)); } catch (e) { throw EngineError('bad json', 'parse'); }
  }

  // ---- 微软：Edge API（令牌端点 2026-07 起返回 404，仍先试一次）
  function msEdgeRequest(texts, to, token) {
    return {
      url: MS_API + '?' + form({ 'api-version': '3.0', to: engineLang('microsoft', to), includeSentenceLength: 'false' }),
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + token },
      body: JSON.stringify(texts.map(function (t) { return { Text: t }; })),
    };
  }

  function parseMsEdge(body, n) {
    var j = parseJSON(body);
    if (!Array.isArray(j) || j.length !== n) throw EngineError('count mismatch', 'parse');
    return j.map(function (r) {
      var tr = r && r.translations && r.translations[0];
      if (!tr || typeof tr.text !== 'string') throw EngineError('bad item', 'parse');
      return { text: tr.text, detected: r.detectedLanguage && r.detectedLanguage.language };
    });
  }

  // ---- 微软：Bing 网页翻译（ttranslatev3），多段用换行拼成一个请求，单请求 ≤ 1000 字
  var BING_PICKS = ['IG:"([0-9A-Fa-f]+)"', 'data-iid="(translator\\.\\d+)"', 'params_AbusePreventionHelper\\s*=\\s*\\[(\\d+),"([^"]+)",(\\d+)'];

  /** 从 /translator 页面摘出的参数（picks[i] = 第 i 个正则的捕获组数组） */
  function bingParamsFromPicks(picks, now) {
    if (!picks || !picks[0] || !picks[2]) return null;
    var ig = picks[0][0], iid = (picks[1] && picks[1][0]) || 'translator.5023';
    var key = picks[2][0], token = picks[2][1], ttl = Number(picks[2][2]) || 3600000;
    if (!ig || !key || !token) return null;
    var issued = Number(key) || now;
    // key 是签发时间（ms）；提前 5 分钟过期
    var exp = Math.min(issued + ttl, now + ttl) - 300000;
    return { ig: ig, iid: iid, key: key, token: token, exp: exp };
  }

  function bingRequest(texts, to, p, count) {
    return {
      url: BING_API + '?' + form({ isVertical: '1', IG: p.ig, IID: p.iid + '.' + (count || 1) }),
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: form({ fromLang: 'auto-detect', to: engineLang('microsoft', to), text: texts.join('\n'), token: p.token, key: p.key }),
    };
  }

  function parseBing(body, n) {
    var j = parseJSON(body);
    if (!Array.isArray(j) || !j[0] || !j[0].translations || !j[0].translations[0]) {
      throw EngineError('bing status ' + (j && j.statusCode), j && j.statusCode === 205 ? 'auth' : 'engine');
    }
    var text = String(j[0].translations[0].text);
    var lines = text.split('\n');
    if (lines.length !== n) throw EngineError('line count mismatch', 'parse');
    var det = j[0].detectedLanguage && j[0].detectedLanguage.language;
    return lines.map(function (l) { return { text: l, detected: det }; });
  }

  // ---- 谷歌：translate_a/t（POST，多个 q 一次翻译）；单条兜底 translate_a/single
  function googleRequest(texts, to) {
    return {
      url: GOOGLE_BATCH + '?' + form({ client: 'gtx', sl: 'auto', tl: engineLang('google', to), format: 'text' }),
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: form({ q: texts }),
    };
  }

  function parseGoogle(body, n) {
    var j = parseJSON(body);
    if (typeof j === 'string') j = [j];
    if (!Array.isArray(j)) throw EngineError('bad google', 'parse');
    // sl=auto：[[译文, 源语言], …]；只有一条时有的版本直接给 [译文, 源语言]
    if (n === 1 && j.length === 2 && typeof j[0] === 'string' && typeof j[1] === 'string' && !Array.isArray(j[0])) j = [j];
    if (j.length !== n) throw EngineError('count mismatch', 'parse');
    return j.map(function (r) {
      if (typeof r === 'string') return { text: r };
      if (Array.isArray(r) && typeof r[0] === 'string') return { text: r[0], detected: typeof r[1] === 'string' ? r[1] : undefined };
      throw EngineError('bad item', 'parse');
    });
  }

  function googleSingleRequest(text, to) {
    return {
      url: GOOGLE_SINGLE + '?' + form({ client: 'gtx', sl: 'auto', tl: engineLang('google', to), dt: 't', q: text }),
      method: 'GET',
    };
  }

  function parseGoogleSingle(body) {
    var j = parseJSON(body);
    if (!Array.isArray(j) || !Array.isArray(j[0])) throw EngineError('bad google single', 'parse');
    var text = j[0].map(function (seg) { return Array.isArray(seg) && typeof seg[0] === 'string' ? seg[0] : ''; }).join('');
    return { text: text, detected: typeof j[2] === 'string' ? j[2] : undefined };
  }

  // ---- OpenAI 兼容：返回 JSON 数组
  function openaiEndpoint(base) {
    var b = String(base || '').trim().replace(/\/+$/, '');
    if (!b) return '';
    if (/\/chat\/completions$/.test(b)) return b;
    return b + '/chat/completions';
  }

  function openaiRequest(texts, to, oc) {
    var lang = engineLang('openai', to);
    var sys = 'You are a translation engine. Translate every string in the user\'s JSON array into ' + lang +
      '. Reply with ONLY a JSON array of strings: same length and order as the input, one translation per item, no explanations.' +
      ' Keep URLs, code, numbers, names and emoji unchanged. Items may be consecutive subtitle lines or paragraphs of one page: use them as context.';
    if (oc && oc.prompt) sys += '\nAdditional instructions: ' + String(oc.prompt);
    return {
      url: openaiEndpoint(oc && oc.base),
      method: 'POST',
      auth: 'openai',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model: (oc && oc.model) || 'gpt-4o-mini',
        temperature: 0.2,
        messages: [{ role: 'system', content: sys }, { role: 'user', content: JSON.stringify(texts) }],
      }),
    };
  }

  function parseOpenAI(body, n) {
    var j = parseJSON(body);
    var content = j && j.choices && j.choices[0] && j.choices[0].message && j.choices[0].message.content;
    if (typeof content !== 'string') throw EngineError((j && j.error && j.error.message) || 'no content', 'engine');
    var s = content.trim().replace(/^```(?:json)?\s*/i, '').replace(/\s*```$/, '');
    var start = s.indexOf('['), end = s.lastIndexOf(']');
    var arr;
    try {
      arr = JSON.parse(start >= 0 && end > start ? s.slice(start, end + 1) : s);
    } catch (e) {
      try {
        var o = JSON.parse(s);
        arr = o && (o.translations || o.result || o.items);
      } catch (e2) { arr = null; }
    }
    if (!Array.isArray(arr) || arr.length !== n) throw EngineError('count mismatch', 'parse');
    return arr.map(function (x) { return { text: String(x == null ? '' : x) }; });
  }

  /** 引擎回退顺序：用户选的 → 微软 → 谷歌（OpenAI 没配置好时跳过） */
  function engineChain(primary, openaiReady) {
    var out = [];
    [primary, 'microsoft', 'google'].forEach(function (e) {
      if (!e || out.indexOf(e) >= 0) return;
      if (e === 'openai' && !openaiReady) return;
      if (!LIMITS[e]) return;
      out.push(e);
    });
    return out;
  }

  /**
   * 翻译服务：translate(texts, target) → Promise<[{text, detected, engine} | null]>
   * deps.http(req) → Promise<{status, body, picks}>（原生 fetch）；deps.cacheGet(keys) / deps.cachePut(entries) 持久缓存；deps.now()
   */
  function createTranslator(cfg, deps) {
    var mem = new LRU(4000);
    var inflight = new Map();
    var now = deps.now || function () { return Date.now(); };
    var oc = cfg.openai || {};
    var openaiReady = !!(oc.ready && oc.base && oc.model);
    var primary = cfg.engine || 'microsoft';
    var state = { bing: null, bingCount: 0, edgeToken: null, edgeAt: 0, edgeDead: false, stats: { requests: 0, failures: 0, fallbacks: 0, cacheHits: 0 } };
    var timeoutFree = cfg.timeoutMs || 12000;
    var timeoutAI = cfg.aiTimeoutMs || 45000;

    function http(req, timeout) {
      state.stats.requests++;
      req.timeoutMs = req.timeoutMs || timeout || timeoutFree;
      return Promise.resolve(deps.http(req)).then(function (r) {
        if (!r) throw EngineError('no response', 'network');
        if (r.error) throw EngineError(String(r.error), 'network');
        return r;
      });
    }

    function bingParams(force) {
      var t = now();
      if (!force && state.bing && state.bing.exp > t) return Promise.resolve(state.bing);
      var fromCache = force ? Promise.resolve({}) : deps.cacheGet(['__bing_params']).catch(function () { return {}; });
      return fromCache.then(function (vals) {
        var c = vals && vals.__bing_params;
        if (c) {
          try {
            var p = JSON.parse(c);
            if (p && p.exp > t) { state.bing = p; return p; }
          } catch (e) { /* ignore */ }
        }
        return http({ url: BING_PAGE, method: 'GET', pick: BING_PICKS }).then(function (r) {
          var p = bingParamsFromPicks(r.picks, now());
          if (!p) throw EngineError('bing params', 'auth');
          state.bing = p;
          state.bingCount = 0;
          var e = {};
          e.__bing_params = JSON.stringify(p);
          deps.cachePut(e).catch(function () {});
          return p;
        });
      });
    }

    function microsoft(texts, to) {
      return edge(texts, to).catch(function (err) {
        if (err && err.kind === 'parse') throw err;
        return bing(texts, to, false);
      });
    }

    function edge(texts, to) {
      if (state.edgeDead) return Promise.reject(EngineError('edge auth retired', 'auth'));
      var t = now();
      var tok = state.edgeToken && t - state.edgeAt < 8 * 60000 ? Promise.resolve(state.edgeToken) :
        deps.cacheGet(['__edge_dead']).catch(function () { return {}; }).then(function (vals) {
          if (vals && vals.__edge_dead && Number(vals.__edge_dead) > t) { state.edgeDead = true; throw EngineError('edge auth retired', 'auth'); }
          return http({ url: MS_AUTH, method: 'GET', timeoutMs: 6000 }).then(function (r) {
            var token = String(r.body || '').trim();
            if (r.status !== 200 || token.split('.').length !== 3) {
              state.edgeDead = true;
              deps.cachePut({ __edge_dead: String(t + 24 * 3600000) }).catch(function () {});
              throw EngineError('edge auth ' + r.status, 'auth');
            }
            state.edgeToken = token;
            state.edgeAt = t;
            return token;
          });
        });
      return tok.then(function (token) {
        return http(msEdgeRequest(texts, to, token)).then(function (r) {
          if (r.status === 401) { state.edgeToken = null; throw EngineError('edge 401', 'auth'); }
          if (r.status !== 200) throw EngineError('edge ' + r.status, 'engine');
          return parseMsEdge(r.body, texts.length);
        });
      });
    }

    function bing(texts, to, retried) {
      return bingParams(retried).then(function (p) {
        state.bingCount++;
        return http(bingRequest(texts, to, p, state.bingCount)).then(function (r) {
          if (r.status !== 200) throw EngineError('bing ' + r.status, r.status === 429 ? 'rate' : 'engine');
          return parseBing(r.body, texts.length);
        });
      }).catch(function (err) {
        if (!retried && err && err.kind === 'auth') return bing(texts, to, true);
        throw err;
      });
    }

    function google(texts, to) {
      return http(googleRequest(texts, to)).then(function (r) {
        if (r.status !== 200) throw EngineError('google ' + r.status, 'engine');
        return parseGoogle(r.body, texts.length);
      }).catch(function (err) {
        if (texts.length > 3) throw err;
        // 少量文本：逐条用 translate_a/single 再试一次
        return Promise.all(texts.map(function (t) {
          return http(googleSingleRequest(t, to)).then(function (r) {
            if (r.status !== 200) throw EngineError('google single ' + r.status, 'engine');
            return parseGoogleSingle(r.body);
          });
        }));
      });
    }

    function openai(texts, to) {
      return http(openaiRequest(texts, to, oc), timeoutAI).then(function (r) {
        if (r.status !== 200) throw EngineError('openai ' + r.status + ' ' + String(r.body || '').slice(0, 120), 'engine');
        return parseOpenAI(r.body, texts.length);
      });
    }

    var ENGINES = { microsoft: microsoft, google: google, openai: openai };

    /** 用 chain[i] 翻译一组文本（按该引擎的批大小切），失败的批交给下一个引擎 */
    function runChain(texts, to, chain, i) {
      if (i >= chain.length) return Promise.reject(EngineError('all engines failed', 'engine'));
      var name = chain[i];
      var batches = makeBatches(texts, LIMITS[name]);
      var out = new Array(texts.length);
      return Promise.all(batches.map(function (idx) {
        var part = idx.map(function (k) { return texts[k]; });
        return ENGINES[name](part, to).then(function (res) {
          idx.forEach(function (k, j) { out[k] = { text: res[j].text, detected: res[j].detected, engine: name }; });
        }, function (err) {
          state.stats.failures++;
          if (i + 1 >= chain.length) throw err;
          state.stats.fallbacks++;
          return runChain(part, to, chain, i + 1).then(function (res) {
            idx.forEach(function (k, j) { out[k] = res[j]; });
          });
        });
      })).then(function () { return out; });
    }

    /** 并发限制：同一时间最多 limit 个任务 */
    var running = 0, waiting = [];
    function limited(fn) {
      return new Promise(function (resolve, reject) {
        var go = function () {
          running++;
          Promise.resolve().then(fn).then(resolve, reject).then(function () {
            running--;
            if (waiting.length) waiting.shift()();
          });
        };
        if (running < (cfg.concurrency || 3)) go(); else waiting.push(go);
      });
    }

    function translate(texts, target) {
      var to = normLang(target || cfg.target || 'zh-CN');
      var keys = texts.map(function (t) { return cacheKey(primary, to, t); });
      var result = new Array(texts.length);
      var missing = [];
      keys.forEach(function (k, i) {
        var v = mem.get(k);
        if (v !== undefined) { result[i] = v; state.stats.cacheHits++; } else missing.push(i);
      });
      if (!missing.length) return Promise.resolve(result);
      var missKeys = [];
      missing.forEach(function (i) { if (missKeys.indexOf(keys[i]) < 0) missKeys.push(keys[i]); });
      return Promise.resolve(deps.cacheGet(missKeys)).catch(function () { return {}; }).then(function (vals) {
        vals = vals || {};
        var todo = [];
        missing.forEach(function (i) {
          var v = vals[keys[i]];
          if (typeof v === 'string') {
            var item;
            try { item = JSON.parse(v); } catch (e) { item = { text: v }; }
            mem.set(keys[i], item);
            result[i] = item;
            state.stats.cacheHits++;
          } else {
            todo.push(i);
          }
        });
        if (!todo.length) return result;
        // 同一文本只请求一次（包括其他调用方正在请求的）
        var uniq = [], uniqKey = {}, waits = [];
        todo.forEach(function (i) {
          var k = keys[i];
          if (inflight.has(k)) { waits.push(inflight.get(k).then(function (v) { result[i] = v; })); return; }
          if (!uniqKey[k]) { uniqKey[k] = []; uniq.push(i); }
          uniqKey[k].push(i);
        });
        var job = !uniq.length ? Promise.resolve() : limited(function () {
          return runChain(uniq.map(function (i) { return texts[i]; }), to, engineChain(primary, openaiReady), 0);
        }).then(function (res) {
          var put = {};
          uniq.forEach(function (i, j) {
            var item = res[j];
            var k = keys[i];
            mem.set(k, item);
            put[k] = JSON.stringify({ text: item.text, detected: item.detected, engine: item.engine });
            uniqKey[k].forEach(function (ii) { result[ii] = item; });
          });
          deps.cachePut(put).catch(function () {});
        });
        uniq.forEach(function (i) {
          var k = keys[i];
          var p = job.then(function () { return result[i]; });
          inflight.set(k, p);
          p.then(function () { inflight.delete(k); }, function () { inflight.delete(k); });
        });
        return Promise.all([job].concat(waits)).then(function () { return result; });
      });
    }

    return { translate: translate, stats: state.stats, _state: state };
  }

  // ======================================================================= 段落选取

  var IGNORE_TAGS = { SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, TEMPLATE: 1, LINK: 1, META: 1, TITLE: 1, HEAD: 1 };
  // 不翻译、也不进入段落（边界）
  var SKIP_BLOCK_TAGS = {
    PRE: 1, TEXTAREA: 1, INPUT: 1, SELECT: 1, OPTION: 1, OPTGROUP: 1, BUTTON: 1, SVG: 1, MATH: 1, CANVAS: 1,
    IFRAME: 1, FRAME: 1, VIDEO: 1, AUDIO: 1, OBJECT: 1, EMBED: 1, PICTURE: 1, MAP: 1, DATALIST: 1,
    'MIO-TR': 1, 'MIO-TR-UI': 1,
  };
  // 行内但不翻译（原样留在段落里）
  var INLINE_KEEP_TAGS = { CODE: 1, KBD: 1, SAMP: 1, VAR: 1, IMG: 1, BR: 1, WBR: 1, TT: 1 };
  var INLINE_TAGS = {
    A: 1, ABBR: 1, B: 1, BDI: 1, BDO: 1, BIG: 1, BR: 1, CITE: 1, CODE: 1, DATA: 1, DFN: 1, DEL: 1, EM: 1, FONT: 1, I: 1, IMG: 1,
    INS: 1, KBD: 1, LABEL: 1, MARK: 1, Q: 1, RP: 1, RT: 1, RUBY: 1, S: 1, SAMP: 1, SMALL: 1, SPAN: 1, STRIKE: 1, STRONG: 1,
    SUB: 1, SUP: 1, TIME: 1, TT: 1, U: 1, VAR: 1, WBR: 1, NOBR: 1, OUTPUT: 1, METER: 1, PROGRESS: 1,
  };
  var BLOCK_TAGS = {
    ADDRESS: 1, ARTICLE: 1, ASIDE: 1, BLOCKQUOTE: 1, BODY: 1, CAPTION: 1, CENTER: 1, DD: 1, DETAILS: 1, DIALOG: 1, DIR: 1, DIV: 1,
    DL: 1, DT: 1, FIELDSET: 1, FIGCAPTION: 1, FIGURE: 1, FOOTER: 1, FORM: 1, H1: 1, H2: 1, H3: 1, H4: 1, H5: 1, H6: 1, HEADER: 1,
    HGROUP: 1, HR: 1, LEGEND: 1, LI: 1, MAIN: 1, MENU: 1, NAV: 1, OL: 1, P: 1, SECTION: 1, SUMMARY: 1, TABLE: 1, TBODY: 1, TD: 1,
    TFOOT: 1, TH: 1, THEAD: 1, TR: 1, UL: 1, HTML: 1,
  };
  var MIN_CHARS = 2;
  var MAX_CHARS = 4500;

  function tagOf(el) { return String(el.tagName || '').toUpperCase(); }

  /** 元素本身不翻译（连同子树） */
  function isSkippedElement(el) {
    var tag = tagOf(el);
    if (SKIP_BLOCK_TAGS[tag]) return true;
    if (el.getAttribute) {
      if (el.getAttribute('translate') === 'no') return true;
      if (el.hasAttribute('data-mio-tr') || el.hasAttribute('data-mio-ui')) return true;
      var ce = el.getAttribute('contenteditable');
      if (ce !== null && ce !== 'false') return true;
      if (el.getAttribute('aria-hidden') === 'true') return true;
      if (el.hasAttribute('hidden')) return true;
      var role = el.getAttribute('role');
      if (role === 'textbox' || role === 'code' || role === 'math') return true;
    }
    var cls = el.classList;
    if (cls && (cls.contains('notranslate') || cls.contains('mio-notranslate'))) return true;
    return false;
  }

  /**
   * 收集 root 子树里的翻译单元：块级元素里连续的行内内容（文字 / 行内元素）算一段；块级子元素是分段边界。
   * 返回 [{ el, nodes, whole, text }]：whole = 这段占满了 el 的全部内容（译文插到 el 末尾）；否则插在 nodes 最后一个之后。
   * opts.target：已经是目标语言的段落跳过
   */
  function collectUnits(root, opts) {
    var target = opts && opts.target;
    var units = [];
    if (!root || root.nodeType !== 1) return units;
    visit(root, true);
    // visit 是后序的（子元素先产出）：按文档顺序排一下，翻译 / 显示从上到下
    units.sort(function (a, b) {
      var x = a.nodes[0], y = b.nodes[0];
      if (x === y || !x.compareDocumentPosition) return 0;
      return x.compareDocumentPosition(y) & 4 ? -1 : 1;
    });
    return units;

    function emit(el, run, whole) {
      if (!run.length) return;
      var text = collapse(run.map(textOf).join(''));
      if (text.length < MIN_CHARS || text.length > MAX_CHARS || !hasLetters(text)) return;
      if (target && isAlreadyTarget(text, target)) return;
      // 只有被跳过的行内元素（如 <code>）时不算
      if (!run.some(function (n) { return n.nodeType === 3 ? hasLetters(n.nodeValue) : !INLINE_KEEP_TAGS[tagOf(n)] && hasLetters(textOf(n)); })) return;
      units.push({ el: el, nodes: run.slice(), whole: whole, text: text });
    }

    function textOf(n) {
      if (n.nodeType === 3) return n.nodeValue;
      if (n.nodeType !== 1) return '';
      var tag = tagOf(n);
      if (IGNORE_TAGS[tag] || tag === 'MIO-TR') return '';
      if (tag === 'BR') return ' ';
      var s = '';
      for (var c = n.firstChild; c; c = c.nextSibling) s += textOf(c);
      return s;
    }

    /** 返回 { blockish }：元素是块级或含块级子孙 */
    function visit(el, isRoot) {
      var tag = tagOf(el);
      var known = BLOCK_TAGS[tag] ? 'block' : INLINE_TAGS[tag] ? 'inline' : 'other';
      var blockish = known === 'block';
      var runs = []; // [{nodes, boundaryAfter}]
      var cur = [];
      var all = 0, inRuns = 0;
      for (var c = el.firstChild; c; c = c.nextSibling) {
        if (c.nodeType === 3) {
          cur.push(c);
          if (/\S/.test(c.nodeValue)) { all++; inRuns++; }
          continue;
        }
        if (c.nodeType !== 1) continue;
        var ctag = tagOf(c);
        if (IGNORE_TAGS[ctag]) continue;
        if (ctag === 'MIO-TR') continue;
        all++;
        if (isSkippedElement(c)) {
          // 被跳过的块（pre / 输入框 / 视频…）是边界；被跳过的行内（translate=no 的 span）留在段落里不翻
          if (SKIP_BLOCK_TAGS[ctag] || BLOCK_TAGS[ctag]) {
            blockish = true;
            if (cur.length) { runs.push(cur); cur = []; }
          } else {
            cur.push(c);
            inRuns++;
          }
          continue;
        }
        if (INLINE_KEEP_TAGS[ctag]) { cur.push(c); inRuns++; continue; }
        var child = visit(c, false);
        if (child.blockish) {
          blockish = true;
          if (cur.length) { runs.push(cur); cur = []; }
        } else {
          cur.push(c);
          inRuns++;
        }
      }
      if (cur.length) runs.push(cur);
      if (blockish || isRoot) {
        var whole = runs.length === 1 && inRuns === all;
        for (var i = 0; i < runs.length; i++) emit(el, trimRun(runs[i]), whole);
      }
      return { blockish: blockish };
    }

    function trimRun(run) {
      var a = 0, b = run.length;
      while (a < b && run[a].nodeType === 3 && !/\S/.test(run[a].nodeValue)) a++;
      while (b > a && run[b - 1].nodeType === 3 && !/\S/.test(run[b - 1].nodeValue)) b--;
      return run.slice(a, b);
    }
  }

  /** 向上找最近的块级祖先（变动后从这里重新收集） */
  function blockAncestor(node, stop) {
    var el = node && node.nodeType === 1 ? node : node && node.parentNode;
    while (el && el !== stop && el.nodeType === 1) {
      var tag = tagOf(el);
      if (BLOCK_TAGS[tag] && tag !== 'HTML') return el;
      el = el.parentNode;
    }
    return stop || null;
  }

  // ======================================================================= YouTube 字幕解析

  /**
   * 解析 timedtext json3 → [{start, end, text}]（ms）。
   * 手动字幕：每个事件一条。自动生成（ASR）：事件是逐词滚动的，按词重新断句（标点 / 停顿 / 长度）。
   */
  function parseJson3(json, opts) {
    var j = typeof json === 'string' ? JSON.parse(json) : json;
    var events = (j && j.events) || [];
    var asr = opts && opts.asr;
    if (asr == null) {
      var offs = 0, segEvents = 0;
      events.forEach(function (e) {
        if (!e.segs) return;
        segEvents++;
        if (e.segs.some(function (s) { return s.tOffsetMs != null; })) offs++;
      });
      asr = segEvents > 4 && offs / segEvents > 0.3;
    }
    if (!asr) {
      var cues = [];
      events.forEach(function (e) {
        if (!e.segs || e.aAppend) return;
        var text = collapse(e.segs.map(function (s) { return s.utf8 || ''; }).join(''));
        if (!text) return;
        var start = Number(e.tStartMs) || 0;
        var dur = Number(e.dDurationMs) || 2000;
        cues.push({ start: start, end: start + dur, text: text });
      });
      cues.sort(function (a, b) { return a.start - b.start; });
      // 重叠时前一条在下一条开始时结束
      for (var i = 0; i + 1 < cues.length; i++) if (cues[i].end > cues[i + 1].start && cues[i + 1].start > cues[i].start) cues[i].end = cues[i + 1].start;
      return mergeDuplicates(cues);
    }
    var words = [];
    events.forEach(function (e) {
      if (!e.segs) return;
      var base = Number(e.tStartMs) || 0;
      e.segs.forEach(function (s) {
        var u = s.utf8 || '';
        if (!u || u === '\n') return;
        words.push({ t: base + (Number(s.tOffsetMs) || 0), text: u, evEnd: base + (Number(e.dDurationMs) || 0) });
      });
    });
    words.sort(function (a, b) { return a.t - b.t; });
    return sentencesFromWords(words, opts);
  }

  function mergeDuplicates(cues) {
    var out = [];
    cues.forEach(function (c) {
      var last = out[out.length - 1];
      if (last && last.text === c.text && c.start - last.end < 50) { last.end = Math.max(last.end, c.end); return; }
      out.push(c);
    });
    return out;
  }

  /** ASR 逐词 → 句子：句末标点、停顿超过 gapMs、长度超过 maxChars、时长超过 maxMs 时断开 */
  function sentencesFromWords(words, opts) {
    var gapMs = (opts && opts.gapMs) || 1200;
    var maxChars = (opts && opts.maxChars) || 110;
    var maxMs = (opts && opts.maxMs) || 6500;
    var out = [];
    var cur = null;
    function flush(endHint) {
      if (!cur) return;
      var text = collapse(cur.text);
      if (text) out.push({ start: cur.start, end: Math.max(cur.last + 400, Math.min(endHint || cur.last + 1600, cur.last + 2500)), text: text });
      cur = null;
    }
    for (var i = 0; i < words.length; i++) {
      var w = words[i];
      if (cur && (w.t - cur.last > gapMs || cur.text.length + w.text.length > maxChars || w.t - cur.start > maxMs)) flush(w.t);
      if (!cur) cur = { start: w.t, last: w.t, text: '' };
      cur.text += w.text;
      cur.last = w.t;
      if (/[.?!。？！…]["'”’)]?\s*$/.test(w.text) && cur.text.length > 12) {
        var next = words[i + 1];
        flush(next ? next.t : w.evEnd);
      }
    }
    flush();
    for (var k = 0; k + 1 < out.length; k++) if (out[k].end > out[k + 1].start) out[k].end = out[k + 1].start;
    return out;
  }

  /** srv3 / srv1 XML（<p t= d=> / <text start= dur=>）→ cues；用简单正则，不依赖 DOMParser */
  function parseTimedXml(xml) {
    var s = String(xml || '');
    var cues = [];
    var re = /<(p|text)\b([^>]*)>([\s\S]*?)<\/\1>/g;
    var m;
    while ((m = re.exec(s))) {
      var attrs = m[2];
      var t = /\bt="(\d+)"/.exec(attrs), d = /\bd="(\d+)"/.exec(attrs);
      var st = /\bstart="([\d.]+)"/.exec(attrs), du = /\bdur="([\d.]+)"/.exec(attrs);
      var start = t ? Number(t[1]) : st ? Math.round(Number(st[1]) * 1000) : NaN;
      var dur = d ? Number(d[1]) : du ? Math.round(Number(du[1]) * 1000) : 2000;
      if (isNaN(start)) continue;
      var text = collapse(decodeEntities(m[3].replace(/<[^>]+>/g, '')));
      if (text) cues.push({ start: start, end: start + dur, text: text });
    }
    cues.sort(function (a, b) { return a.start - b.start; });
    return mergeDuplicates(cues);
  }

  function decodeEntities(s) {
    return s.replace(/&(#x?[0-9a-f]+|amp|lt|gt|quot|apos|#39);/gi, function (all, e) {
      var l = e.toLowerCase();
      if (l === 'amp') return '&';
      if (l === 'lt') return '<';
      if (l === 'gt') return '>';
      if (l === 'quot') return '"';
      if (l === 'apos' || l === '#39') return "'";
      if (l[0] === '#') {
        var n = l[1] === 'x' ? parseInt(l.slice(2), 16) : parseInt(l.slice(1), 10);
        return isNaN(n) ? all : String.fromCodePoint(n);
      }
      return all;
    });
  }

  function parseTimedtext(body, opts) {
    var s = String(body || '').trim();
    if (!s) return [];
    if (s[0] === '{') return parseJson3(s, opts);
    if (s[0] === '<') return parseTimedXml(s);
    return [];
  }

  /** 二分：t 时刻显示的字幕下标（没有 → -1） */
  function cueIndexAt(cues, t) {
    var lo = 0, hi = cues.length - 1, found = -1;
    while (lo <= hi) {
      var mid = (lo + hi) >> 1;
      if (cues[mid].start <= t) { found = mid; lo = mid + 1; } else hi = mid - 1;
    }
    if (found >= 0 && t < cues[found].end) return found;
    return -1;
  }

  /** 字幕切成翻译批（带上下文：一批是连续的若干句） */
  function cueBatches(cues, opts) {
    return makeBatches(cues.map(function (c) { return c.text; }), { maxItems: (opts && opts.maxItems) || 24, maxChars: (opts && opts.maxChars) || 880, sepLen: 1 });
  }

  /**
   * 从 captionTracks 里选要翻译的源字幕：优先人工字幕（与自动字幕同语言的那条），其次自动生成，最后任一人工字幕。
   * 源语言已经是目标语言时返回 null（不需要双语）。
   */
  function pickCaptionTrack(tracks, target) {
    if (!Array.isArray(tracks) || !tracks.length) return null;
    var asr = null, manual = [];
    tracks.forEach(function (t) {
      if (!t || !t.baseUrl) return;
      if (t.kind === 'asr' || /^a\./.test(t.vssId || '')) { if (!asr) asr = t; } else manual.push(t);
    });
    var spoken = asr && asr.languageCode;
    var pick = null;
    if (spoken) pick = manual.filter(function (t) { return sameLang(t.languageCode, spoken) && normLang(t.languageCode) === normLang(spoken); })[0] || null;
    if (!pick && spoken) pick = manual.filter(function (t) { return sameLang(t.languageCode, spoken); })[0] || null;
    if (!pick) pick = asr;
    if (!pick) pick = manual.filter(function (t) { return !sameLang(t.languageCode, target); })[0] || manual[0];
    if (!pick || sameLang(pick.languageCode, target)) return null;
    return pick;
  }

  function videoIdFromUrl(href) {
    try {
      var u = new URL(href);
      if (!/(^|\.)youtube\.com$/i.test(u.hostname) && !/(^|\.)youtube-nocookie\.com$/i.test(u.hostname)) return null;
      if (u.pathname === '/watch') return u.searchParams.get('v');
      var m = /^\/(?:embed|live|v)\/([\w-]{6,})/.exec(u.pathname);
      return m ? m[1] : null;
    } catch (e) {
      return null;
    }
  }

  function hostMatches(host, entry) {
    var h = String(host || '').toLowerCase().replace(/\.$/, '');
    var e = String(entry || '').toLowerCase().replace(/^\*\./, '').replace(/^www\./, '').replace(/\.$/, '');
    if (!h || !e) return false;
    return h === e || h.slice(-(e.length + 1)) === '.' + e;
  }

  function siteAuto(host, list) {
    return (list || []).some(function (e) { return hostMatches(host, e); });
  }

  function decodeConfig(b64) {
    if (!b64 || b64.indexOf('__MIO_') === 0) return null;
    try {
      var bin = (typeof atob === 'function' ? atob : function (x) { return Buffer.from(x, 'base64').toString('binary'); })(b64);
      if (typeof TextDecoder === 'function') {
        var bytes = new Uint8Array(bin.length);
        for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
        return JSON.parse(new TextDecoder('utf-8').decode(bytes));
      }
      return JSON.parse(decodeURIComponent(bin.replace(/[\s\S]/g, function (ch) { return '%' + ('0' + ch.charCodeAt(0).toString(16)).slice(-2); })));
    } catch (e) {
      return null;
    }
  }

  var Core = {
    LANGS: LANGS, LIMITS: LIMITS, normLang: normLang, sameLang: sameLang, engineLang: engineLang, langLabel: langLabel,
    guessLang: guessLang, isAlreadyTarget: isAlreadyTarget, hasLetters: hasLetters, collapse: collapse, hashText: hashText, cacheKey: cacheKey,
    makeBatches: makeBatches, LRU: LRU, engineChain: engineChain, createTranslator: createTranslator,
    msEdgeRequest: msEdgeRequest, parseMsEdge: parseMsEdge, bingParamsFromPicks: bingParamsFromPicks, bingRequest: bingRequest, parseBing: parseBing,
    BING_PICKS: BING_PICKS, googleRequest: googleRequest, parseGoogle: parseGoogle, googleSingleRequest: googleSingleRequest, parseGoogleSingle: parseGoogleSingle,
    openaiEndpoint: openaiEndpoint, openaiRequest: openaiRequest, parseOpenAI: parseOpenAI,
    collectUnits: collectUnits, isSkippedElement: isSkippedElement, blockAncestor: blockAncestor,
    parseJson3: parseJson3, parseTimedXml: parseTimedXml, parseTimedtext: parseTimedtext, cueIndexAt: cueIndexAt, cueBatches: cueBatches,
    sentencesFromWords: sentencesFromWords, pickCaptionTrack: pickCaptionTrack, videoIdFromUrl: videoIdFromUrl,
    hostMatches: hostMatches, siteAuto: siteAuto, decodeConfig: decodeConfig,
  };

  // ======================================================================= 原生桥

  /** 在页面脚本之前抓住原生接口（之后页面改 window 上的东西也影响不到这里） */
  function makeBridge(W, token) {
    var JSONstringify = JSON.stringify, JSONparse = JSON.parse;
    var wk = W.webkit && W.webkit.messageHandlers && W.webkit.messageHandlers.mioTranslate;
    if (wk && typeof wk.postMessage === 'function') {
      var post = wk.postMessage.bind(wk);
      return {
        kind: 'webkit',
        call: function (msg) {
          msg.t = token;
          return Promise.resolve(post(msg)).then(function (r) { return typeof r === 'string' ? JSONparse(r) : r; });
        },
      };
    }
    var an = W.mioTranslateNative;
    if (an && typeof an.postMessage === 'function') {
      var send = an.postMessage.bind(an);
      var pending = new Map();
      var seq = 0;
      var onMsg = function (ev) {
        var r;
        try { r = JSONparse(ev && ev.data); } catch (e) { return; }
        var p = r && pending.get(r.id);
        if (!p) return;
        pending.delete(r.id);
        if (r.error && !r.ok) p.reject(new Error(String(r.error))); else p.resolve(r);
      };
      if (typeof an.addEventListener === 'function') an.addEventListener('message', onMsg); else an.onmessage = onMsg;
      return {
        kind: 'android',
        call: function (msg) {
          return new Promise(function (resolve, reject) {
            var id = ++seq;
            pending.set(id, { resolve: resolve, reject: reject });
            msg.t = token;
            msg.id = id;
            send(JSONstringify(msg));
            setTimeout(function () { if (pending.has(id)) { pending.delete(id); reject(new Error('bridge timeout')); } }, 90000);
          });
        },
      };
    }
    var el = W.__mioTranslateNative;
    if (el && typeof el.request === 'function') {
      var req = el.request;
      return {
        kind: 'electron',
        call: function (msg) {
          msg.t = token;
          return Promise.resolve(req(JSONstringify(msg))).then(function (r) { return typeof r === 'string' ? JSONparse(r) : r; });
        },
      };
    }
    return null;
  }

  // ======================================================================= 页面运行时

  function start(W, cfg, bridge) {
    var D = W.document;
    if (!D || W.__mioTranslate) return W.__mioTranslate;
    var isTop = W.top === W;
    var host = String(W.location && W.location.hostname || '').toLowerCase();
    cfg.target = normLang(cfg.target || 'zh-CN');
    var dark = false;
    try { dark = !!(W.matchMedia && W.matchMedia('(prefers-color-scheme: dark)').matches); } catch (e) { /* ignore */ }

    var call = function (op, extra) {
      var m = extra || {};
      m.op = op;
      return bridge.call(m).then(function (r) {
        if (r && r.error && !r.ok && op !== 'fetch') throw new Error(String(r.error));
        return r;
      });
    };
    var translator = createTranslator(cfg, {
      http: function (req) { return call('fetch', { req: req }); },
      cacheGet: function (keys) { return call('cacheGet', { keys: keys }).then(function (r) { return (r && r.values) || {}; }); },
      cachePut: function (entries) { return call('cachePut', { entries: entries }); },
    });

    var api = {};
    try {
      Object.defineProperty(W, '__mioTranslate', { value: api, configurable: false, enumerable: false, writable: false });
    } catch (e) {
      W.__mioTranslate = api;
    }

    // ------------------------------------------------------------- 网页翻译
    var mode = 'off';
    var started = false;
    var gen = 0;
    var unitsByEl = new WeakMap();
    var allUnits = new Set();
    var queue = [];
    var pumpTimer = 0;
    var io = null;
    var mo = null;
    var dirty = new Set();
    var dirtyTimer = 0;
    var translatedCount = 0;
    var errors = 0;
    var lastError = '';

    function unitStyle(e, inline) {
      var s = e.style;
      s.setProperty('display', inline ? 'inline' : 'block', 'important');
      s.setProperty('opacity', '0.78');
      s.setProperty('margin', inline ? '0 0 0 0.45em' : '0.18em 0 0.32em 0');
      s.setProperty('padding', '0');
      s.setProperty('font-style', 'normal');
      s.setProperty('white-space', 'normal');
      s.setProperty('flex-basis', '100%');
    }

    function makeTr(text, unit) {
      var e = D.createElement('mio-tr');
      e.setAttribute('data-mio-tr', '');
      e.setAttribute('translate', 'no');
      e.setAttribute('lang', cfg.target);
      e.textContent = text;
      unit.inline = unit.text.length <= 24 && !/[.!?。！？:]/.test(unit.text) && !/^H\d$/.test(tagOf(unit.el)) && !unit.whole;
      unitStyle(e, unit.inline);
      return e;
    }

    function placeTr(unit) {
      var tr = unit.tr;
      if (!tr || !unit.el.isConnected) return;
      if (unit.whole) {
        if (tr.parentNode !== unit.el || tr.nextSibling) unit.el.appendChild(tr);
      } else {
        var last = unit.nodes[unit.nodes.length - 1];
        if (last && last.parentNode === unit.el) {
          if (last.nextSibling !== tr) unit.el.insertBefore(tr, last.nextSibling);
        } else {
          unit.el.appendChild(tr);
        }
      }
    }

    function applyModeTo(unit) {
      if (!unit.tr) return;
      var only = mode === 'translation' && unit.whole;
      var el = unit.el;
      if (only && !unit.saved) {
        var cs = W.getComputedStyle ? W.getComputedStyle(el) : null;
        unit.saved = { fs: el.style.getPropertyValue('font-size'), fsp: el.style.getPropertyPriority('font-size'), color: el.style.getPropertyValue('color'), kids: [] };
        unit.tr.style.setProperty('font-size', cs && cs.fontSize ? cs.fontSize : '16px', 'important');
        unit.tr.style.setProperty('opacity', '1');
        unit.tr.style.setProperty('margin', '0');
        unit.tr.style.setProperty('display', 'block', 'important');
        unit.nodes.forEach(function (n) {
          if (n.nodeType === 1) {
            unit.saved.kids.push([n, n.style.getPropertyValue('display'), n.style.getPropertyPriority('display')]);
            n.style.setProperty('display', 'none', 'important');
          }
        });
        el.style.setProperty('font-size', '0', 'important');
      } else if (!only && unit.saved) {
        restore(unit);
        unit.tr.style.removeProperty('font-size');
        unitStyle(unit.tr, !!unit.inline);
      }
    }

    function restore(unit) {
      var s = unit.saved;
      if (!s) return;
      unit.saved = null;
      if (s.fs) unit.el.style.setProperty('font-size', s.fs, s.fsp); else unit.el.style.removeProperty('font-size');
      s.kids.forEach(function (k) {
        if (k[1]) k[0].style.setProperty('display', k[1], k[2]); else k[0].style.removeProperty('display');
      });
    }

    function removeUnit(unit) {
      restore(unit);
      if (unit.tr && unit.tr.parentNode) unit.tr.parentNode.removeChild(unit.tr);
      unit.tr = null;
      unit.state = 'removed';
      allUnits.delete(unit);
    }

    function registerUnits(root) {
      var found = collectUnits(root, { target: cfg.target });
      var byEl = new Map();
      found.forEach(function (u) {
        if (!byEl.has(u.el)) byEl.set(u.el, []);
        byEl.get(u.el).push(u);
      });
      // root 里旧的单元：文本没变的保留，变了的删除
      var stale = [];
      allUnits.forEach(function (u) {
        if (u.el === root || (root.contains && root.contains(u.el))) stale.push(u);
      });
      var keep = new Set();
      byEl.forEach(function (list, el) {
        var prev = unitsByEl.get(el) || [];
        var next = list.map(function (u) {
          var same = null;
          for (var i = 0; i < prev.length; i++) if (prev[i].text === u.text && prev[i].state !== 'removed') { same = prev[i]; break; }
          if (same) {
            same.nodes = u.nodes;
            same.whole = u.whole;
            keep.add(same);
            placeTr(same);
            return same;
          }
          u.state = 'new';
          allUnits.add(u);
          keep.add(u);
          return u;
        });
        unitsByEl.set(el, next);
        if (io) io.observe(el); else next.forEach(enqueue);
      });
      stale.forEach(function (u) { if (!keep.has(u)) removeUnit(u); });
      if (!io) schedulePump();
    }

    function enqueue(u) {
      if (u.state !== 'new') return;
      u.state = 'queued';
      queue.push(u);
      schedulePump();
    }

    function schedulePump() {
      if (pumpTimer) return;
      pumpTimer = W.setTimeout(pump, 60);
    }

    function pump() {
      pumpTimer = 0;
      if (mode === 'off' || !queue.length) return;
      var batch = queue.splice(0, 80);
      var g = gen;
      var texts = batch.map(function (u) { return u.text; });
      translator.translate(texts, cfg.target).then(function (res) {
        if (g !== gen) return;
        batch.forEach(function (u, i) {
          if (u.state === 'removed') return;
          var r = res[i];
          u.state = 'done';
          if (!r || !r.text) return;
          if (r.detected && sameLang(r.detected, cfg.target)) return;
          if (collapse(r.text).toLowerCase() === u.text.toLowerCase()) return;
          if (u.tr) { u.tr.textContent = r.text; } else { u.tr = makeTr(r.text, u); }
          placeTr(u);
          applyModeTo(u);
          translatedCount++;
        });
      }, function (err) {
        if (g !== gen) return;
        errors++;
        lastError = String(err && err.message || err);
        batch.forEach(function (u) { if (u.state === 'queued') u.state = 'new'; });
        // 稍后重试一次（网络抖动）；连续失败就不再自动重试
        if (errors <= 3) W.setTimeout(function () { batch.forEach(enqueue); }, 3000 * errors);
        toast('翻译失败：' + lastError.slice(0, 60));
      });
      if (queue.length) schedulePump();
    }

    function onIntersect(entries) {
      entries.forEach(function (en) {
        if (!en.isIntersecting) return;
        var list = unitsByEl.get(en.target);
        if (io) io.unobserve(en.target);
        if (list) list.forEach(enqueue);
      });
    }

    function onMutations(records) {
      if (mode === 'off') return;
      for (var i = 0; i < records.length; i++) {
        var r = records[i];
        var t = r.target;
        if (ours(t)) continue;
        if (r.type === 'characterData') { dirty.add(blockAncestor(t, D.body)); continue; }
        var added = r.addedNodes;
        var relevant = false;
        for (var k = 0; k < added.length; k++) {
          var n = added[k];
          if (n.nodeType === 1 && (tagOf(n) === 'MIO-TR' || n.hasAttribute('data-mio-ui'))) continue;
          if (n.nodeType === 1 || (n.nodeType === 3 && /\S/.test(n.nodeValue))) { relevant = true; break; }
        }
        if (!relevant && r.removedNodes.length) {
          for (var q = 0; q < r.removedNodes.length; q++) {
            var rn = r.removedNodes[q];
            if (!(rn.nodeType === 1 && tagOf(rn) === 'MIO-TR')) { relevant = true; break; }
          }
        }
        if (relevant) dirty.add(blockAncestor(t, D.body));
      }
      if (dirty.size && !dirtyTimer) dirtyTimer = W.setTimeout(processDirty, 450);
    }

    function ours(n) {
      for (var e = n && (n.nodeType === 1 ? n : n.parentNode), i = 0; e && i < 8; e = e.parentNode, i++) {
        if (e.nodeType === 1 && (tagOf(e) === 'MIO-TR' || tagOf(e) === 'MIO-TR-UI')) return true;
      }
      return false;
    }

    function processDirty() {
      dirtyTimer = 0;
      if (mode === 'off') { dirty.clear(); return; }
      var roots = [];
      dirty.forEach(function (r) { if (r && r.isConnected) roots.push(r); });
      dirty.clear();
      roots = roots.filter(function (r) { return !roots.some(function (o) { return o !== r && o.contains(r); }); });
      roots.forEach(registerUnits);
      // 被整段移除的单元
      allUnits.forEach(function (u) { if (!u.el.isConnected) { allUnits.delete(u); u.state = 'removed'; } });
    }

    function enable(m) {
      mode = m;
      if (!D.body) {
        D.addEventListener('DOMContentLoaded', function () { if (mode !== 'off') enable(mode); }, { once: true });
        return;
      }
      if (!started) {
        started = true;
        gen++;
        errors = 0;
        if (typeof W.IntersectionObserver === 'function') io = new W.IntersectionObserver(onIntersect, { rootMargin: '600px 0px 900px 0px' });
        if (typeof W.MutationObserver === 'function') {
          mo = new W.MutationObserver(onMutations);
          mo.observe(D.body, { childList: true, subtree: true, characterData: true });
        }
        registerUnits(D.body);
      }
      allUnits.forEach(applyModeTo);
    }

    function disable() {
      mode = 'off';
      started = false;
      gen++;
      if (io) { io.disconnect(); io = null; }
      if (mo) { mo.disconnect(); mo = null; }
      if (pumpTimer) { W.clearTimeout(pumpTimer); pumpTimer = 0; }
      if (dirtyTimer) { W.clearTimeout(dirtyTimer); dirtyTimer = 0; }
      queue = [];
      dirty.clear();
      allUnits.forEach(removeUnit);
      allUnits.clear();
      unitsByEl = new WeakMap();
      translatedCount = 0;
    }

    function setMode(m) {
      if (!isTop) return api.state();
      if (m !== 'bilingual' && m !== 'translation') m = 'off';
      if (m === 'off') disable(); else enable(m);
      return api.state();
    }

    // ------------------------------------------------------------- 小提示（翻译失败等）
    var toastEl = null, toastTimer = 0;
    function toast(msg) {
      if (!isTop || !D.documentElement) return;
      if (!toastEl || !toastEl.isConnected) {
        toastEl = D.createElement('mio-tr-ui');
        toastEl.setAttribute('data-mio-ui', '');
        var s = toastEl.style;
        s.cssText = 'all: initial; position: fixed; left: 50%; bottom: calc(env(safe-area-inset-bottom, 0px) + 16px); transform: translateX(-50%);' +
          ' z-index: 2147483647; max-width: calc(100vw - 32px); padding: 8px 14px; border-radius: 10px; font: 13px/1.4 -apple-system, system-ui, sans-serif;' +
          ' background: rgba(28,28,30,0.88); color: #fff; pointer-events: none; transition: opacity .3s; opacity: 0;';
        D.documentElement.appendChild(toastEl);
      }
      toastEl.textContent = msg;
      toastEl.style.opacity = '1';
      if (toastTimer) W.clearTimeout(toastTimer);
      toastTimer = W.setTimeout(function () { if (toastEl) toastEl.style.opacity = '0'; }, 2600);
    }

    // ------------------------------------------------------------- 划词翻译
    var bubble = null, card = null, selTimer = 0, selText = '', selRect = null;

    function uiBox(tag) {
      var e = D.createElement(tag || 'mio-tr-ui');
      e.setAttribute('data-mio-ui', '');
      e.setAttribute('translate', 'no');
      return e;
    }

    function palette() {
      return dark ? { bg: 'rgba(44,44,46,0.97)', fg: '#f2f2f7', sub: '#aeaeb2', line: 'rgba(255,255,255,0.12)', accent: '#f0a3bf' }
        : { bg: 'rgba(255,255,255,0.98)', fg: '#1c1c1e', sub: '#6e6e73', line: 'rgba(0,0,0,0.1)', accent: '#d9578a' };
    }

    function selectionInfo() {
      var sel = W.getSelection && W.getSelection();
      if (!sel || sel.isCollapsed || !sel.rangeCount) return null;
      var text = collapse(sel.toString());
      if (!text || text.length > 3000 || !hasLetters(text)) return null;
      var node = sel.anchorNode;
      var el = node && (node.nodeType === 1 ? node : node.parentNode);
      for (var e = el; e && e.nodeType === 1; e = e.parentNode) {
        if (e.hasAttribute('data-mio-ui')) return null;
        var tag = tagOf(e);
        if (tag === 'INPUT' || tag === 'TEXTAREA') return null;
        var ce = e.getAttribute('contenteditable');
        if (ce !== null && ce !== 'false') return null;
      }
      var rect = null;
      try {
        var range = sel.getRangeAt(0);
        var rects = range.getClientRects();
        rect = rects && rects.length ? rects[rects.length - 1] : range.getBoundingClientRect();
        var all = range.getBoundingClientRect();
        rect = { left: rect.left, right: rect.right, top: all.top, bottom: rect.bottom };
      } catch (e2) { rect = null; }
      return { text: text, rect: rect };
    }

    function hideBubble() {
      if (bubble && bubble.parentNode) bubble.parentNode.removeChild(bubble);
      bubble = null;
    }

    function hideCard() {
      if (card && card.parentNode) card.parentNode.removeChild(card);
      card = null;
    }

    function clampX(x, w) {
      var vw = W.innerWidth || 375;
      return Math.max(8, Math.min(x, vw - w - 8));
    }

    function showBubble(info) {
      selText = info.text;
      selRect = info.rect;
      if (!bubble) {
        bubble = uiBox();
        var p = palette();
        bubble.style.cssText = 'all: initial; position: fixed; z-index: 2147483647; width: 32px; height: 32px; border-radius: 16px;' +
          ' display: flex; align-items: center; justify-content: center; cursor: pointer; -webkit-user-select: none; user-select: none;' +
          ' font: 600 15px/1 -apple-system, system-ui, "PingFang SC", sans-serif; background: ' + p.accent + '; color: #fff;' +
          ' box-shadow: 0 4px 14px rgba(0,0,0,0.25); touch-action: manipulation;';
        bubble.setAttribute('role', 'button');
        bubble.setAttribute('aria-label', '翻译选中的文字');
        bubble.textContent = '译';
        var keep = function (e) { e.preventDefault(); e.stopPropagation(); };
        bubble.addEventListener('pointerdown', keep, true);
        bubble.addEventListener('mousedown', keep, true);
        bubble.addEventListener('touchstart', function (e) { e.stopPropagation(); }, { capture: true, passive: true });
        bubble.addEventListener('click', function (e) {
          e.preventDefault();
          e.stopPropagation();
          translateSelection(selText, selRect);
        }, true);
        D.documentElement.appendChild(bubble);
      }
      var r = selRect || { left: 20, right: 20, top: 80, bottom: 80 };
      var vh = W.innerHeight || 640;
      // 放在选区末尾的下方（iOS 的系统菜单在选区上方）；太靠下就放上方
      var top = r.bottom + 10;
      if (top + 40 > vh) top = Math.max(8, r.top - 42);
      bubble.style.left = clampX(r.right - 16, 32) + 'px';
      bubble.style.top = top + 'px';
    }

    function translateSelection(text, rect) {
      text = collapse(text || selText);
      if (!text) {
        var info = selectionInfo();
        if (!info) return Promise.resolve(null);
        text = info.text; rect = info.rect;
      }
      hideBubble();
      hideCard();
      var p = palette();
      card = uiBox();
      card.style.cssText = 'all: initial; position: fixed; z-index: 2147483647; box-sizing: border-box; width: min(380px, calc(100vw - 16px));' +
        ' max-height: 45vh; overflow: auto; -webkit-overflow-scrolling: touch; padding: 12px 14px 10px; border-radius: 14px;' +
        ' font: 15px/1.5 -apple-system, system-ui, "PingFang SC", sans-serif; background: ' + p.bg + '; color: ' + p.fg + ';' +
        ' box-shadow: 0 12px 40px rgba(0,0,0,0.28), 0 0 0 1px ' + p.line + ';';
      var src = D.createElement('div');
      src.style.cssText = 'all: initial; display: block; font: 13px/1.45 -apple-system, system-ui, sans-serif; color: ' + p.sub + '; margin-bottom: 6px; white-space: pre-wrap; word-break: break-word;';
      src.textContent = text.length > 300 ? text.slice(0, 300) + '…' : text;
      var out = D.createElement('div');
      out.style.cssText = 'all: initial; display: block; font: 16px/1.55 -apple-system, system-ui, "PingFang SC", sans-serif; color: ' + p.fg + '; white-space: pre-wrap; word-break: break-word;';
      out.textContent = '翻译中…';
      var bar = D.createElement('div');
      bar.style.cssText = 'all: initial; display: flex; align-items: center; gap: 12px; margin-top: 8px; padding-top: 6px; border-top: 1px solid ' + p.line + '; font: 12px/1.6 -apple-system, system-ui, sans-serif; color: ' + p.sub + ';';
      var meta = D.createElement('span');
      meta.style.cssText = 'all: initial; flex: 1; font: inherit; color: inherit;';
      meta.textContent = '→ ' + langLabel(cfg.target);
      var copy = D.createElement('span');
      copy.setAttribute('role', 'button');
      copy.style.cssText = 'all: initial; font: inherit; color: ' + p.accent + '; cursor: pointer;';
      copy.textContent = '复制';
      var close = D.createElement('span');
      close.setAttribute('role', 'button');
      close.setAttribute('aria-label', '关闭');
      close.style.cssText = 'all: initial; font: 15px/1 sans-serif; color: ' + p.sub + '; cursor: pointer; padding: 2px 4px;';
      close.textContent = '✕';
      close.addEventListener('click', function (e) { e.stopPropagation(); hideCard(); });
      bar.appendChild(meta);
      bar.appendChild(copy);
      bar.appendChild(close);
      card.appendChild(src);
      card.appendChild(out);
      card.appendChild(bar);
      card.addEventListener('pointerdown', function (e) { e.stopPropagation(); }, true);
      D.documentElement.appendChild(card);
      var r = rect || { left: 20, right: 20, top: 80, bottom: 80 };
      var vh = W.innerHeight || 640;
      var w = Math.min(380, (W.innerWidth || 375) - 16);
      card.style.left = clampX(r.left, w) + 'px';
      var below = r.bottom + 12;
      if (below + 180 > vh && r.top > vh / 2) {
        card.style.bottom = Math.max(8, vh - r.top + 12) + 'px';
      } else {
        card.style.top = Math.min(below, vh - 120) + 'px';
      }
      var mine = card;
      return translator.translate([text], cfg.target).then(function (res) {
        var t = res[0];
        if (card !== mine) return t;
        out.textContent = t && t.text ? t.text : '（没有译文）';
        if (t && t.engine) meta.textContent = '→ ' + langLabel(cfg.target) + ' · ' + ({ microsoft: '微软', google: '谷歌', openai: 'AI' }[t.engine] || t.engine);
        copy.addEventListener('click', function (e) {
          e.stopPropagation();
          try { W.navigator.clipboard.writeText(out.textContent).then(function () { copy.textContent = '已复制'; }, function () {}); } catch (e2) { /* ignore */ }
        });
        return t;
      }, function (err) {
        if (card === mine) out.textContent = '翻译失败：' + String(err && err.message || err);
        return null;
      });
    }

    function onSelectionMaybe() {
      if (selTimer) W.clearTimeout(selTimer);
      selTimer = W.setTimeout(function () {
        selTimer = 0;
        if (!cfg.selection) return;
        var info = selectionInfo();
        if (!info) { hideBubble(); return; }
        showBubble(info);
      }, 280);
    }

    if (isTop) {
      D.addEventListener('selectionchange', onSelectionMaybe);
      D.addEventListener('pointerdown', function (e) {
        if (card && !(e.target && e.target.closest && e.target.closest('[data-mio-ui]'))) hideCard();
      }, true);
      D.addEventListener('keydown', function (e) { if (e.key === 'Escape') { hideCard(); hideBubble(); } }, true);
    }

    // ------------------------------------------------------------- YouTube 双语字幕
    var yt = null;
    if (isTop && cfg.youtube !== false && /(^|\.)youtube\.com$/i.test(host)) yt = startYouTube(W, cfg, translator, call);

    // ------------------------------------------------------------- 对外接口（原生工具栏 / 菜单调用）
    api.setMode = setMode;
    api.toggle = function () { return setMode(mode === 'off' ? (cfg.display || 'bilingual') : 'off'); };
    api.state = function () {
      return { mode: mode, host: host, auto: siteAuto(host, cfg.autoSites), target: cfg.target, engine: cfg.engine, units: allUnits.size, translated: translatedCount, errors: errors, lastError: lastError, youtube: yt ? yt.state() : null, stats: translator.stats };
    };
    api.configure = function (partial) {
      if (!partial || typeof partial !== 'object') return api.state();
      ['selection', 'display', 'autoSites'].forEach(function (k) { if (k in partial) cfg[k] = partial[k]; });
      if ('display' in partial && mode !== 'off') setMode(partial.display === 'translation' ? 'translation' : 'bilingual');
      if (yt && 'ytSubs' in partial) yt.setEnabled(!!partial.ytSubs);
      if (!cfg.selection) { hideBubble(); hideCard(); }
      return api.state();
    };
    api.translateSelection = function () { return translateSelection(); };
    /** 冒烟测试：原生桥往返（缓存读，不访问网络）；network = true 时再真实翻译一句 */
    api.selfTest = function (network) {
      var out = { bridge: false, kind: bridge.kind };
      return call('cacheGet', { keys: ['__mio_selftest'] }).then(function (r) {
        out.bridge = !!(r && r.values && typeof r.values === 'object');
      }, function (e) { out.bridgeError = String(e && e.message || e); }).then(function () {
        if (!network) return out;
        var t0 = Date.now();
        return translator.translate(['Hello world'], cfg.target).then(function (res) {
          out.sample = res[0] && res[0].text;
          out.engine = res[0] && res[0].engine;
          out.ms = Date.now() - t0;
          return out;
        }, function (e) { out.networkError = String(e && e.message || e); return out; });
      });
    };
    api.version = 1;

    // 按站点自动翻译（页面本身声明的语言已经是目标语言时不自动翻译）
    if (isTop && siteAuto(host, cfg.autoSites)) {
      var go = function () {
        var pageLang = D.documentElement && D.documentElement.getAttribute('lang');
        if (pageLang && sameLang(pageLang, cfg.target)) return;
        if (mode === 'off') setMode(cfg.display === 'translation' ? 'translation' : 'bilingual');
      };
      if (D.readyState === 'loading') D.addEventListener('DOMContentLoaded', go, { once: true }); else go();
    }
    return api;
  }

  // ======================================================================= YouTube

  function startYouTube(W, cfg, translator, call) {
    var D = W.document;
    var enabled = cfg.ytSubs !== false;
    var captured = new Map(); // videoId → [{lang, kind, tlang, body, url}]
    var waiters = [];
    var cur = null; // { vid, track, cues, tr: [], requested: Set, ... }
    var overlay = null, lineA = null, lineB = null, toggleBtn = null, styleEl = null, player = null, video = null;
    var lastIdx = -2;
    var rafPending = false;
    var routeTimer = 0;
    var origFetch = W.fetch;

    // ---- 抓播放器自己的 timedtext 请求（2025 起直接请求常常要 pot 参数，拿不到时就靠这个）
    function noteTimedtext(url, body) {
      try {
        var u = new URL(url, W.location.href);
        if (u.pathname.indexOf('/api/timedtext') < 0) return;
        var v = u.searchParams.get('v');
        if (!v || !body) return;
        var list = captured.get(v) || [];
        list.push({ lang: u.searchParams.get('lang') || '', kind: u.searchParams.get('kind') || '', tlang: u.searchParams.get('tlang') || '', body: body, url: u.href });
        if (list.length > 6) list.shift();
        captured.set(v, list);
        var w = waiters;
        waiters = [];
        w.forEach(function (fn) { try { fn(); } catch (e) { /* ignore */ } });
      } catch (e) { /* ignore */ }
    }

    if (typeof origFetch === 'function') {
      var wrapped = function (input, init) {
        var p = origFetch.apply(this, arguments);
        try {
          var url = typeof input === 'string' ? input : input && input.url ? input.url : String(input);
          if (url && url.indexOf('/api/timedtext') >= 0) {
            p.then(function (resp) {
              if (resp && resp.ok) resp.clone().text().then(function (t) { noteTimedtext(url, t); }, function () {});
            }, function () {});
          }
        } catch (e) { /* ignore */ }
        return p;
      };
      try { W.fetch = wrapped; } catch (e) { /* ignore */ }
    }
    var XHR = W.XMLHttpRequest;
    if (XHR && XHR.prototype) {
      var open = XHR.prototype.open, send = XHR.prototype.send;
      XHR.prototype.open = function (method, url) {
        try { this.__mioTT = String(url || '').indexOf('/api/timedtext') >= 0 ? String(url) : null; } catch (e) { /* ignore */ }
        return open.apply(this, arguments);
      };
      XHR.prototype.send = function () {
        if (this.__mioTT) {
          var x = this, url = this.__mioTT;
          x.addEventListener('load', function () {
            try {
              if (x.status === 200 && (x.responseType === '' || x.responseType === 'text')) noteTimedtext(url, x.responseText);
            } catch (e) { /* ignore */ }
          });
        }
        return send.apply(this, arguments);
      };
    }

    function getPlayer() {
      return D.getElementById('movie_player') || D.querySelector('.html5-video-player');
    }

    function playerResponse(vid) {
      var p = getPlayer();
      var pr = null;
      try { if (p && typeof p.getPlayerResponse === 'function') pr = p.getPlayerResponse(); } catch (e) { pr = null; }
      if (!pr || !pr.videoDetails || pr.videoDetails.videoId !== vid) {
        var init = W.ytInitialPlayerResponse;
        if (init && init.videoDetails && init.videoDetails.videoId === vid) pr = init;
      }
      return pr && pr.videoDetails && pr.videoDetails.videoId === vid ? pr : null;
    }

    function ensureStyle() {
      if (styleEl && styleEl.isConnected) return;
      styleEl = D.createElement('style');
      styleEl.setAttribute('data-mio-ui', '');
      styleEl.textContent =
        '.mio-ytsub-on .ytp-caption-window-container, .mio-ytsub-on .caption-window, .mio-ytsub-on .ytp-caption-window-bottom,' +
        ' .mio-ytsub-on .captions-text, .mio-ytsub-on .ytm-captions-container { display: none !important; }\n' +
        '.html5-video-player.ytp-autohide mio-tr-ui[data-mio-yt-toggle] { opacity: 0 !important; }\n';
      (D.head || D.documentElement).appendChild(styleEl);
    }

    function buildOverlay() {
      if (overlay && overlay.isConnected && overlay.parentNode === player) return;
      if (overlay && overlay.parentNode) overlay.parentNode.removeChild(overlay);
      overlay = D.createElement('mio-tr-ui');
      overlay.setAttribute('data-mio-ui', '');
      overlay.setAttribute('translate', 'no');
      overlay.style.cssText = 'all: initial; position: absolute; left: 50%; bottom: 9%; transform: translateX(-50%); z-index: 60;' +
        ' max-width: 88%; display: none; flex-direction: column; align-items: center; text-align: center; pointer-events: none;' +
        ' font-family: -apple-system, "PingFang SC", "Helvetica Neue", "YouTube Noto", Roboto, Arial, sans-serif;';
      lineA = D.createElement('div');
      lineB = D.createElement('div');
      [lineA, lineB].forEach(function (l, i) {
        l.style.cssText = 'all: initial; display: inline-block; box-sizing: border-box; padding: 0.08em 0.4em; margin-top: 0.12em; border-radius: 0.2em;' +
          ' background: rgba(8,8,8,0.72); color: ' + (i ? '#ffe28a' : '#ffffff') + '; font: inherit; font-size: 1em; line-height: 1.35;' +
          ' white-space: pre-wrap; word-break: break-word; text-shadow: 0 0 2px rgba(0,0,0,0.6);';
        overlay.appendChild(l);
      });
      player.appendChild(overlay);
      resize();
    }

    function resize() {
      if (!overlay || !player) return;
      var h = player.clientHeight || 360;
      var fs = Math.max(12, Math.min(30, Math.round(h * 0.042)));
      overlay.style.fontSize = fs + 'px';
      lineB.style.fontSize = Math.round(fs * 1.02) + 'px';
      lineA.style.fontSize = Math.round(fs * 0.9) + 'px';
    }

    function buildToggle() {
      if (toggleBtn && toggleBtn.isConnected) return;
      var right = player.querySelector('.ytp-right-controls');
      toggleBtn = D.createElement('mio-tr-ui');
      toggleBtn.setAttribute('data-mio-ui', '');
      toggleBtn.setAttribute('data-mio-yt-toggle', '');
      toggleBtn.setAttribute('role', 'button');
      toggleBtn.setAttribute('aria-label', '双语字幕');
      toggleBtn.setAttribute('title', '双语字幕（Mio）');
      toggleBtn.textContent = '双语';
      var base = 'all: initial; cursor: pointer; -webkit-user-select: none; user-select: none; font: 600 12px/1 -apple-system, "PingFang SC", Roboto, sans-serif;' +
        ' color: #fff; border-radius: 4px; display: inline-flex; align-items: center; justify-content: center; transition: opacity .25s;';
      if (right) {
        toggleBtn.style.cssText = base + ' height: 100%; padding: 0 8px; vertical-align: top; opacity: 0.9;';
        right.insertBefore(toggleBtn, right.firstChild);
      } else {
        // 手机版：播放器左上角的小按钮
        toggleBtn.style.cssText = base + ' position: absolute; top: 8px; left: 8px; z-index: 61; height: 24px; padding: 0 8px; background: rgba(0,0,0,0.45);';
        player.appendChild(toggleBtn);
      }
      var stop = function (e) { e.stopPropagation(); };
      toggleBtn.addEventListener('pointerdown', stop, true);
      toggleBtn.addEventListener('touchstart', stop, { capture: true, passive: true });
      toggleBtn.addEventListener('click', function (e) {
        e.preventDefault();
        e.stopPropagation();
        setEnabled(!enabled);
        call('setPref', { key: 'ytSubs', value: enabled }).catch(function () {});
      }, true);
      paintToggle();
    }

    function paintToggle() {
      if (!toggleBtn) return;
      toggleBtn.setAttribute('aria-pressed', enabled ? 'true' : 'false');
      toggleBtn.style.textDecoration = enabled ? 'underline' : 'line-through';
      toggleBtn.style.textDecorationColor = enabled ? '#f0a3bf' : 'rgba(255,255,255,0.7)';
      toggleBtn.style.textUnderlineOffset = '3px';
      toggleBtn.style.opacity = enabled ? '0.95' : '0.6';
    }

    function setEnabled(on) {
      enabled = !!on;
      paintToggle();
      if (player) player.classList.toggle('mio-ytsub-on', enabled && !!(cur && cur.cues && cur.cues.length));
      lastIdx = -2;
      render();
    }

    function teardown() {
      if (overlay && overlay.parentNode) overlay.parentNode.removeChild(overlay);
      if (toggleBtn && toggleBtn.parentNode) toggleBtn.parentNode.removeChild(toggleBtn);
      if (player) player.classList.remove('mio-ytsub-on');
      if (video) {
        video.removeEventListener('timeupdate', onTime);
        video.removeEventListener('seeked', onTime);
        video.removeEventListener('play', onPlay);
      }
      overlay = toggleBtn = video = null;
      cur = null;
      lastIdx = -2;
    }

    function waitCaptured(vid, test, ms) {
      return new Promise(function (resolve) {
        var done = false;
        var check = function () {
          if (done) return;
          var list = captured.get(vid) || [];
          for (var i = list.length - 1; i >= 0; i--) {
            if (test(list[i])) { done = true; resolve(list[i]); return; }
          }
          waiters.push(check);
        };
        check();
        W.setTimeout(function () { if (!done) { done = true; resolve(null); } }, ms);
      });
    }

    function matchTrack(track) {
      return function (c) { return !c.tlang && sameLang(c.lang, track.languageCode) && ((track.kind === 'asr') === (c.kind === 'asr')); };
    }

    function loadCues(vid, track) {
      var isAsr = track.kind === 'asr';
      var already = (captured.get(vid) || []).filter(matchTrack(track)).pop();
      var fromCapture = function (c) { return c ? parseTimedtext(c.body, { asr: isAsr }) : []; };
      if (already) return Promise.resolve(fromCapture(already));
      var url = track.baseUrl + (track.baseUrl.indexOf('fmt=') >= 0 ? '' : '&fmt=json3');
      url = url.replace(/([?&])fmt=[^&]*/, '$1fmt=json3');
      var fetcher = typeof origFetch === 'function' ? origFetch.call(W, url, { credentials: 'include' }) : Promise.reject(new Error('no fetch'));
      return fetcher.then(function (r) { return r.ok ? r.text() : ''; }, function () { return ''; }).then(function (body) {
        var cues = body ? parseTimedtext(body, { asr: isAsr }) : [];
        if (cues.length) return cues;
        // 直接请求拿不到（需要 pot）：让播放器自己加载这条字幕，再从它的请求里取
        var p = getPlayer();
        try {
          if (p && typeof p.loadModule === 'function') p.loadModule('captions');
          if (p && typeof p.setOption === 'function') p.setOption('captions', 'track', { languageCode: track.languageCode, kind: track.kind || undefined, vss_id: track.vssId });
        } catch (e) { /* ignore */ }
        return waitCaptured(vid, matchTrack(track), 8000).then(fromCapture);
      });
    }

    function route() {
      if (routeTimer) return;
      routeTimer = W.setTimeout(function () { routeTimer = 0; check(0); }, 50);
    }

    function check(attempt) {
      var vid = videoIdFromUrl(W.location.href);
      if (!vid) { if (cur) teardown(); return; }
      if (cur && cur.vid === vid) return;
      var pr = playerResponse(vid);
      if (!pr) {
        if (attempt < 8) W.setTimeout(function () { check(attempt + 1); }, 400 * (attempt + 1));
        return;
      }
      player = getPlayer();
      if (!player) {
        if (attempt < 8) W.setTimeout(function () { check(attempt + 1); }, 400 * (attempt + 1));
        return;
      }
      if (cur) teardown();
      var tracks = pr.captions && pr.captions.playerCaptionsTracklistRenderer && pr.captions.playerCaptionsTracklistRenderer.captionTracks;
      var track = pickCaptionTrack(tracks, cfg.target);
      if (!track) return; // 没有字幕 / 已经是目标语言：不处理
      var me = { vid: vid, track: track, cues: null, tr: [], requested: new Set(), batches: null };
      cur = me;
      ensureStyle();
      buildOverlay();
      buildToggle();
      bindVideo();
      loadCues(vid, track).then(function (cues) {
        if (cur !== me) return;
        if (!cues.length) { teardown(); return; }
        me.cues = cues;
        me.batches = cueBatches(cues);
        player.classList.toggle('mio-ytsub-on', enabled);
        lastIdx = -2;
        onTime();
      });
    }

    function bindVideo() {
      var v = player && player.querySelector('video');
      if (v === video) return;
      if (video) {
        video.removeEventListener('timeupdate', onTime);
        video.removeEventListener('seeked', onTime);
        video.removeEventListener('play', onPlay);
      }
      video = v;
      if (!video) return;
      video.addEventListener('timeupdate', onTime);
      video.addEventListener('seeked', onTime);
      video.addEventListener('play', onPlay);
    }

    function onPlay() {
      if (rafPending || typeof W.requestAnimationFrame !== 'function') return;
      rafPending = true;
      var last = 0;
      var loop = function (ts) {
        if (!video || video.paused || !cur) { rafPending = false; return; }
        if (ts - last > 120) { last = ts; render(); }
        W.requestAnimationFrame(loop);
      };
      W.requestAnimationFrame(loop);
    }

    /** 当前时间附近（-10s ~ +150s）的批还没翻译就去翻译 */
    function ensureTranslated(t) {
      var me = cur;
      if (!me || !me.batches) return;
      for (var b = 0; b < me.batches.length; b++) {
        var idx = me.batches[b];
        var s = me.cues[idx[0]].start, e = me.cues[idx[idx.length - 1]].end;
        if (e < t - 10000 || s > t + 150000) continue;
        if (me.requested.has(b)) continue;
        me.requested.add(b);
        (function (bi, idxs) {
          translator.translate(idxs.map(function (i) { return me.cues[i].text; }), cfg.target).then(function (res) {
            if (cur !== me) return;
            idxs.forEach(function (i, j) { me.tr[i] = res[j] && res[j].text; });
            lastIdx = -2;
            render();
          }, function () {
            if (cur === me) W.setTimeout(function () { me.requested.delete(bi); }, 5000);
          });
        })(b, idx);
      }
    }

    function onTime() {
      if (!cur || !cur.cues || !video) return;
      var t = video.currentTime * 1000;
      ensureTranslated(t);
      render();
    }

    function render() {
      if (!overlay) return;
      if (!player || overlay.parentNode !== player) { if (player) buildOverlay(); }
      if (!enabled || !cur || !cur.cues || !video) { overlay.style.display = 'none'; return; }
      var i = cueIndexAt(cur.cues, video.currentTime * 1000);
      var key = i + '|' + (i >= 0 && cur.tr[i] ? 1 : 0);
      if (key === lastIdx) return;
      lastIdx = key;
      if (i < 0) { overlay.style.display = 'none'; return; }
      lineA.textContent = cur.cues[i].text;
      var tr = cur.tr[i];
      lineB.textContent = tr || '';
      lineB.style.display = tr ? 'inline-block' : 'none';
      overlay.style.display = 'flex';
    }

    ['pushState', 'replaceState'].forEach(function (k) {
      var orig = W.history && W.history[k];
      if (typeof orig !== 'function') return;
      W.history[k] = function () {
        var r = orig.apply(this, arguments);
        try { route(); } catch (e) { /* ignore */ }
        return r;
      };
    });
    W.addEventListener('popstate', route);
    ['yt-navigate-finish', 'yt-page-data-updated', 'state-navigateend', 'yt-player-updated'].forEach(function (t) { D.addEventListener(t, route); });
    D.addEventListener('DOMContentLoaded', route);
    W.addEventListener('resize', resize);
    D.addEventListener('fullscreenchange', function () { W.setTimeout(resize, 200); });
    D.addEventListener('webkitfullscreenchange', function () { W.setTimeout(resize, 200); });
    route();

    return {
      setEnabled: setEnabled,
      state: function () {
        return { enabled: enabled, video: cur && cur.vid, lang: cur && cur.track && cur.track.languageCode, kind: cur && cur.track && cur.track.kind, cues: cur && cur.cues ? cur.cues.length : 0, translated: cur ? cur.tr.filter(Boolean).length : 0 };
      },
      _captured: captured,
    };
  }

  Core.start = start;
  Core.makeBridge = makeBridge;
  Core.startYouTube = startYouTube;

  // ======================================================================= 入口
  if (G && G.__MIO_TRANSLATE_EXPORT__) G.__mioTranslateCore = Core;
  var config = decodeConfig(CONFIG_B64);
  if (!config || !G || !G.document) return;
  if (G.top !== G) return; // 只在主框架
  var bridge = makeBridge(G, config.token);
  if (!bridge) return;
  try { start(G, config, bridge); } catch (e) { /* 注入脚本出错不影响页面 */ }
})(typeof window !== 'undefined' ? window : globalThis);
