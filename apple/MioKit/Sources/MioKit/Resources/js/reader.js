/*
 * Mio 阅读模式：正文提取（Readability 风格的自研实现，没有拷贝 Mozilla Readability 的代码）。
 *
 * 用法（内置浏览器在页面的隔离脚本环境里执行，或 node 测试里 require）：
 *   MioReader.isProbablyReaderable(document)          → true / false（地址栏是否显示阅读模式按钮）
 *   MioReader.extract(document, { url })              → { title, byline, siteName, excerpt, lang, dir, publishedTime,
 *                                                         html, markdown, text, textLength, images, url } | null
 *   MioReader.toMarkdown(node, baseURL)               → markdown 字符串（存到 Mio 笔记用）
 *   MioReader.buildPage(article, prefs)               → 阅读视图的完整 HTML（白 / 米 / 深背景、字号、字体）
 *
 * 只读页面：在克隆出来的文档上操作，不改动原页面；不使用 innerHTML 赋值 / DOMParser（Trusted Types 站点会拒绝），
 * 只用 createElement / appendChild 等 DOM API 构建。输出的 HTML 只含白名单标签和属性（链接 / 图片地址已绝对化，
 * javascript: 等协议被丢弃），阅读视图另外用 CSP 禁止脚本。
 */
(function (root) {
  'use strict';

  var ELEMENT = 1, TEXT = 3;

  // 明显不是正文的容器（class / id）；同时命中 POSITIVE 的保留
  var UNLIKELY = /(^|[\s_-])(ad|ads|adv|advert|advertisement|banner|breadcrumbs?|combx|comments?|communit|cookie|disqus|extra|footer|gdpr|header|legends|menu|modal|nav|newsletter|outbrain|pager|pagination|popup|promo|related|recommend(ed|ations?)?|remark|replies|rss|share|sharing|shoutbox|sidebar|skyscraper|social|sponsor(ed)?|editsection|navbox|catlinks|printfooter|subscribe|supplemental|taboola|toolbar|tools|widget|yom-remote)([\s_-]|$)/i;
  var MAYBE = /and|article|body|column|content|main|shadow|story|entry|post|text/i;
  var POSITIVE = /article|body|content|entry|hentry|h-entry|main|page|pagination|post|text|blog|story|prose|rich-?text/i;
  var NEGATIVE = /-ad-|hidden|^hid$|\bhid\b|banner|combx|comment|com-|contact|footer|gdpr|masthead|media-?meta|outbrain|promo|related|scroll|share|shoutbox|sidebar|skyscraper|sponsor|shopping|tags?-?list|tool|widget|subscribe|newsletter|recommend/i;
  var BYLINE = /byline|author|dateline|writtenby|p-author/i;

  // 直接删除（连同内容）
  var DROP_TAGS = { SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, TEMPLATE: 1, IFRAME: 1, FRAME: 1, FRAMESET: 1, OBJECT: 1, EMBED: 1, APPLET: 1,
    FORM: 1, INPUT: 1, BUTTON: 1, SELECT: 1, TEXTAREA: 1, OPTION: 1, LABEL: 1, NAV: 1, ASIDE: 1, FOOTER: 1, DIALOG: 1, MENU: 1,
    CANVAS: 1, SVG: 1, MATH: 1, LINK: 1, META: 1, BASE: 1, HEAD: 1, TITLE: 1, AUDIO: 1, MAP: 1, AREA: 1 };
  // 输出允许的标签（其余标签去壳保留内容）
  var KEEP_TAGS = { P: 1, BR: 1, HR: 1, H1: 1, H2: 1, H3: 1, H4: 1, H5: 1, H6: 1, A: 1, IMG: 1, FIGURE: 1, FIGCAPTION: 1,
    UL: 1, OL: 1, LI: 1, DL: 1, DT: 1, DD: 1, BLOCKQUOTE: 1, PRE: 1, CODE: 1, KBD: 1, SAMP: 1, VAR: 1, EM: 1, I: 1, STRONG: 1, B: 1, U: 1,
    S: 1, DEL: 1, INS: 1, MARK: 1, SMALL: 1, SUB: 1, SUP: 1, Q: 1, CITE: 1, ABBR: 1, TIME: 1, TABLE: 1, THEAD: 1, TBODY: 1, TFOOT: 1,
    TR: 1, TH: 1, TD: 1, CAPTION: 1, DIV: 1, SECTION: 1, ARTICLE: 1, SPAN: 1, VIDEO: 1, SOURCE: 1, PICTURE: 1, DETAILS: 1, SUMMARY: 1, RUBY: 1, RT: 1, RP: 1 };
  var KEEP_ATTRS = {
    A: ['href', 'title'], IMG: ['src', 'srcset', 'alt', 'title', 'width', 'height'], TD: ['colspan', 'rowspan'], TH: ['colspan', 'rowspan', 'scope'],
    OL: ['start', 'type', 'reversed'], LI: ['value'], TIME: ['datetime'], ABBR: ['title'], Q: ['cite'], BLOCKQUOTE: ['cite'],
    VIDEO: ['src', 'poster', 'controls', 'width', 'height'], SOURCE: ['src', 'srcset', 'type', 'media'], PRE: ['lang'], CODE: ['lang'], DETAILS: ['open']
  };
  var BLOCKS = /^(ADDRESS|ARTICLE|ASIDE|BLOCKQUOTE|DETAILS|DIV|DL|FIELDSET|FIGURE|FOOTER|FORM|H[1-6]|HEADER|HR|LI|MAIN|NAV|OL|P|PRE|SECTION|TABLE|UL|IMG|PICTURE|VIDEO)$/;
  var LAZY_SRC = ['data-src', 'data-original', 'data-lazy-src', 'data-lazy', 'data-url', 'data-actualsrc', 'data-original-src', 'data-hi-res-src', 'data-croporisrc'];
  var LAZY_SRCSET = ['data-srcset', 'data-lazy-srcset', 'data-original-srcset'];

  function tag(n) { return n && n.nodeType === ELEMENT ? String(n.tagName).toUpperCase() : ''; }
  function attr(n, name) { return (n && n.getAttribute && n.getAttribute(name)) || ''; }
  function norm(s) { return String(s || '').replace(/\s+/g, ' ').trim(); }
  function textOf(n) { return norm(n.textContent); }
  function each(list, fn) { for (var i = 0; i < list.length; i++) fn(list[i], i); }
  function toArray(list) { var a = []; each(list, function (x) { a.push(x); }); return a; }
  function classAndId(n) { return (attr(n, 'class') + ' ' + attr(n, 'id')).trim(); }
  function remove(n) { if (n && n.parentNode) n.parentNode.removeChild(n); }
  function unwrap(n) {
    var p = n.parentNode; if (!p) return;
    while (n.firstChild) p.insertBefore(n.firstChild, n);
    p.removeChild(n);
  }
  function rename(doc, n, newTag) {
    var r = doc.createElement(newTag);
    while (n.firstChild) r.appendChild(n.firstChild);
    each(toArray(n.attributes || []), function (a) { try { r.setAttribute(a.name, a.value); } catch (e) {} });
    n.parentNode.replaceChild(r, n);
    return r;
  }

  function absolutize(url, base) {
    url = String(url || '').trim();
    if (!url) return '';
    if (/^data:image\//i.test(url)) return url;
    try {
      var u = new URL(url, base || undefined);
      if (u.protocol === 'http:' || u.protocol === 'https:') return u.href;
      if (u.protocol === 'mailto:') return u.href;
    } catch (e) {}
    return '';
  }
  function absolutizeSrcset(srcset, base) {
    return String(srcset || '').split(',').map(function (part) {
      var bits = part.trim().split(/\s+/);
      if (!bits[0]) return '';
      var u = absolutize(bits[0], base);
      return u ? [u].concat(bits.slice(1)).join(' ') : '';
    }).filter(Boolean).join(', ');
  }

  function meta(doc, names) {
    for (var i = 0; i < names.length; i++) {
      var n = names[i];
      var el = doc.querySelector('meta[property="' + n + '"],meta[name="' + n + '"],meta[itemprop="' + n + '"]');
      var c = el && norm(el.getAttribute('content'));
      if (c) return c;
    }
    return '';
  }

  /// JSON-LD 里的 headline / author / datePublished（新闻站常有）
  function jsonLd(doc) {
    var out = {};
    each(doc.querySelectorAll('script[type="application/ld+json"]'), function (s) {
      try {
        var data = JSON.parse(s.textContent);
        var list = Array.isArray(data) ? data : (data && data['@graph']) ? data['@graph'] : [data];
        each(list, function (d) {
          if (!d || typeof d !== 'object') return;
          var t = [].concat(d['@type'] || []).join(' ');
          if (!/Article|BlogPosting|NewsArticle|Report|WebPage/i.test(t)) return;
          if (!out.title && typeof d.headline === 'string') out.title = norm(d.headline);
          var a = d.author;
          if (!out.byline && a) {
            var names = [].concat(a).map(function (x) { return typeof x === 'string' ? x : x && x.name; }).filter(Boolean);
            if (names.length) out.byline = norm(names.join(', '));
          }
          if (!out.published && d.datePublished) out.published = String(d.datePublished);
        });
      } catch (e) {}
    });
    return out;
  }

  /// 标题：og:title / JSON-LD / <title> 去掉「 | 站点名」之类的后缀
  function cleanTitle(raw, siteName, h1s) {
    var t = norm(raw);
    if (!t) return '';
    for (var i = 0; i < h1s.length; i++) {
      if (h1s[i] && h1s[i] === t) return t;
      // <title> = h1 + 站点后缀
      if (h1s[i] && h1s[i].length >= 4 && t.indexOf(h1s[i]) === 0 && /^\s*[|\-–—_»·:｜]/.test(t.slice(h1s[i].length))) return h1s[i];
    }
    var parts = t.split(/\s+[|\-–—_»·:]\s+|\s*[|｜–—_»]\s*/);
    if (parts.length > 1) {
      // 有一段与页面 h1 相同就用它
      for (var j = 0; j < parts.length; j++) for (var k = 0; k < h1s.length; k++) if (norm(parts[j]) === h1s[k]) return h1s[k];
      var filtered = parts.filter(function (p) { return norm(p) && (!siteName || norm(p).toLowerCase() !== siteName.toLowerCase()); });
      var longest = filtered.reduce(function (a, b) { return norm(b).length > norm(a).length ? b : a; }, '');
      if (norm(longest).length >= 6 || filtered.length === 1) return norm(longest);
    }
    return t;
  }

  function linkDensity(n, raw) {
    var len = textOf(n).length;
    if (!len) return 0;
    var linkLen = 0;
    each(n.getElementsByTagName('a'), function (a) {
      var href = attr(a, 'href');
      var coeff = !raw && href && /^#/.test(href) ? 0.3 : 1;
      linkLen += textOf(a).length * coeff;
    });
    return Math.min(1, linkLen / len);
  }

  function classWeight(n) {
    var w = 0;
    var c = attr(n, 'class'), id = attr(n, 'id');
    if (c) { if (NEGATIVE.test(c)) w -= 25; if (POSITIVE.test(c)) w += 25; }
    if (id) { if (NEGATIVE.test(id)) w -= 25; if (POSITIVE.test(id)) w += 25; }
    return w;
  }

  function isHidden(n) {
    if (n.hasAttribute && n.hasAttribute('hidden')) return true;
    var s = attr(n, 'style');
    if (s && /display\s*:\s*none|visibility\s*:\s*hidden/i.test(s)) return true;
    // aria-hidden 的图片 / 图标容器常有用（懒加载占位），只把带文字的 aria-hidden 当隐藏
    if (attr(n, 'aria-hidden') === 'true' && !/fallback-image/.test(attr(n, 'class')) && textOf(n).length > 0 && !n.querySelector('img')) return true;
    return false;
  }

  function isUnlikely(n) {
    var t = tag(n);
    if (t === 'BODY' || t === 'ARTICLE' || t === 'MAIN' || t === 'A' || t === 'TABLE' || t === 'TBODY' || t === 'TR' || t === 'TD' || t === 'PRE' || t === 'CODE') return false;
    var role = attr(n, 'role');
    if (/^(navigation|banner|complementary|contentinfo|dialog|alertdialog|menu|menubar|search)$/.test(role)) return true;
    var m = classAndId(n);
    if (!m) return false;
    if (UNLIKELY.test(m) && !MAYBE.test(m)) {
      // 祖先里有 table / code 时不删（代码 / 表格里的类名会误伤）
      return true;
    }
    return false;
  }

  /// 懒加载图片 / <picture> / <noscript> 里的真图
  function fixImages(doc, rootNode, base) {
    each(toArray(rootNode.querySelectorAll('noscript')), function (ns) {
      var html = ns.textContent || '';
      var m = /<img[^>]+src\s*=\s*["']([^"']+)["']/i.exec(html);
      if (!m) return;
      var prev = ns.previousElementSibling;
      var prevImg = prev && (tag(prev) === 'IMG' ? prev : prev.querySelector && prev.querySelector('img'));
      var img = doc.createElement('img');
      img.setAttribute('src', m[1]);
      var alt = /alt\s*=\s*["']([^"']*)["']/i.exec(html);
      if (alt) img.setAttribute('alt', alt[1]);
      if (prevImg && (!attr(prevImg, 'src') || /^data:|placeholder|blank|spacer|lazy/i.test(attr(prevImg, 'src')))) {
        prevImg.parentNode.replaceChild(img, prevImg);
        remove(ns);
      } else if (!prevImg) {
        ns.parentNode.replaceChild(img, ns);
      }
    });
    each(toArray(rootNode.querySelectorAll('img')), function (img) {
      var src = attr(img, 'src');
      var placeholder = !src || /^data:image\/(gif|svg)/i.test(src) && src.length < 400 || /placeholder|spacer|blank\.(gif|png)|lazy/i.test(src);
      if (placeholder) {
        for (var i = 0; i < LAZY_SRC.length; i++) { var v = attr(img, LAZY_SRC[i]); if (v && !/^data:/.test(v)) { img.setAttribute('src', v); break; } }
      }
      if (!attr(img, 'srcset')) {
        for (var j = 0; j < LAZY_SRCSET.length; j++) { var s = attr(img, LAZY_SRCSET[j]); if (s) { img.setAttribute('srcset', s); break; } }
      }
      // <picture><source srcset> 没有 src 时用 source
      var pic = img.parentNode;
      if (!attr(img, 'src') && tag(pic) === 'PICTURE') {
        var source = pic.querySelector('source[srcset],source[data-srcset]');
        if (source) {
          var ss = attr(source, 'srcset') || attr(source, 'data-srcset');
          img.setAttribute('src', ss.split(',')[0].trim().split(/\s+/)[0]);
          if (!attr(img, 'srcset')) img.setAttribute('srcset', ss);
        }
      }
      if (attr(img, 'src')) img.setAttribute('src', absolutize(attr(img, 'src'), base));
      if (attr(img, 'srcset')) img.setAttribute('srcset', absolutizeSrcset(attr(img, 'srcset'), base));
    });
  }

  /// 第一遍：删明显的非正文；把只包含行内内容的 div 视为段落参与打分
  function prune(doc, body, byline) {
    var all = toArray(body.getElementsByTagName('*'));
    each(all, function (n) {
      if (!n.parentNode) return;
      var t = tag(n);
      if (DROP_TAGS[t]) { remove(n); return; }
      if (t === 'HEADER' && !n.querySelector('h1') ) { remove(n); return; }
      if (isHidden(n)) { remove(n); return; }
      // 类名带 header 的容器里常有导语（MDN 等），里面有像样的段落就留下
      if (isUnlikely(n) && !(/header/i.test(classAndId(n)) && hasRealParagraph(n))) { remove(n); return; }
      // 作者行（已经单独提取，正文里不再重复）
      if (byline && t !== 'BODY' && t !== 'ARTICLE' && t !== 'MAIN' && BYLINE.test(classAndId(n)) && textOf(n).length < 100 && !n.querySelector('p,img')) { remove(n); return; }
    });
  }

  function hasBlockChild(n) {
    for (var c = n.firstChild; c; c = c.nextSibling) if (c.nodeType === ELEMENT && BLOCKS.test(tag(c))) return true;
    return false;
  }

  /// 给候选容器打分，返回得分最高的节点
  function pickTop(doc, body) {
    var scores = new Map();
    var candidates = [];
    function init(n) {
      if (scores.has(n)) return;
      var s = 0;
      switch (tag(n)) {
        case 'DIV': case 'ARTICLE': case 'MAIN': case 'SECTION': s += 5; break;
        case 'PRE': case 'TD': case 'BLOCKQUOTE': s += 3; break;
        case 'ADDRESS': case 'OL': case 'UL': case 'DL': case 'DD': case 'DT': case 'LI': case 'FORM': s -= 3; break;
        case 'H1': case 'H2': case 'H3': case 'H4': case 'H5': case 'H6': case 'TH': s -= 5; break;
      }
      if (tag(n) === 'ARTICLE' || tag(n) === 'MAIN' || attr(n, 'itemprop') === 'articleBody') s += 10;
      s += classWeight(n);
      scores.set(n, s);
      candidates.push(n);
    }
    var paras = toArray(body.querySelectorAll('p,pre,td,blockquote,div,section'));
    each(paras, function (p) {
      var t = tag(p);
      if ((t === 'DIV' || t === 'SECTION' || t === 'TD' || t === 'BLOCKQUOTE') && hasBlockChild(p)) return;
      var text = textOf(p);
      if (text.length < 25) return;
      var parent = p.parentNode, grand = parent && parent.parentNode;
      if (!parent || parent.nodeType !== ELEMENT) return;
      // 中文没有逗号空格分词：中英文逗号都算
      var commas = (text.match(/[,，、;；]/g) || []).length;
      var score = 1 + commas + Math.min(3, Math.floor(text.length / 100));
      var level = 0;
      for (var a = parent; a && a.nodeType === ELEMENT && level < 3; a = a.parentNode, level++) {
        if (tag(a) === 'HTML') break;
        init(a);
        scores.set(a, scores.get(a) + score / (level === 0 ? 1 : level === 1 ? 2 : level * 3));
      }
      void grand;
    });
    var top = null, topScore = 0;
    each(candidates, function (c) {
      var s = scores.get(c) * (1 - linkDensity(c));
      scores.set(c, s);
      if (!top || s > topScore) { top = c; topScore = s; }
    });
    if (!top) return { node: null, score: 0, scores: scores };
    // 正文被切成几个并列的 <section>（维基百科等）：父容器下还有 ≥2 个有分量的兄弟块时，直接取父容器
    var par = top.parentNode;
    if (par && par.nodeType === ELEMENT && tag(par) !== 'BODY' && tag(par) !== 'HTML') {
      var strong = 0;
      for (var c = par.firstChild; c; c = c.nextSibling) {
        if (c !== top && c.nodeType === ELEMENT && (scores.get(c) || 0) >= topScore * 0.15) strong++;
      }
      if (strong >= 2) { top = par; topScore = Math.max(topScore, scores.get(par) || 0); }
    }
    // 顶部候选的父节点分数接近时向上走（正文被拆成几个兄弟块的情况）
    var parent = top.parentNode;
    var hops = 0;
    while (parent && parent.nodeType === ELEMENT && tag(parent) !== 'BODY' && hops < 3) {
      var ps = scores.get(parent);
      if (ps !== undefined && ps >= topScore * 0.75 && textOf(parent).length < textOf(top).length * 3) { top = parent; topScore = Math.max(topScore, ps); }
      parent = parent.parentNode; hops++;
    }
    return { node: top, score: topScore, scores: scores };
  }

  /// 收集与顶部候选同级、看起来也是正文的兄弟块
  function gather(doc, top, scores, topScore) {
    var parent = top.parentNode;
    var container = doc.createElement('div');
    if (!parent || tag(parent) === 'HTML') { container.appendChild(top); return container; }
    var threshold = Math.max(10, topScore * 0.2);
    var topClass = attr(top, 'class');
    var sibs = toArray(parent.childNodes);
    each(sibs, function (s) {
      if (s.nodeType !== ELEMENT) return;
      var append = false;
      if (s === top) append = true;
      else {
        var bonus = topClass && attr(s, 'class') === topClass ? topScore * 0.2 : 0;
        var ss = scores.get(s);
        if (ss !== undefined && ss + bonus >= threshold) append = true;
        else if (tag(s) === 'P' || tag(s) === 'FIGURE' || tag(s) === 'BLOCKQUOTE' || tag(s) === 'PRE') {
          var len = textOf(s).length, ld = linkDensity(s);
          if (len > 80 && ld < 0.25) append = true;
          else if (len > 0 && len <= 80 && ld === 0 && /[.。!?！？]\s*$/.test(textOf(s))) append = true;
          else if (tag(s) === 'FIGURE' && s.querySelector('img')) append = true;
        } else if (textOf(s).length > 80 && linkDensity(s) < 0.25 && classWeight(s) >= 0) {
          // 没参与打分的块（导语、只有一段的 div）：文字多、链接少也算正文
          append = true;
        }
      }
      if (append) container.appendChild(s);
    });
    return container;
  }

  function hasRealParagraph(n) {
    var ps = n.getElementsByTagName('p');
    for (var i = 0; i < ps.length; i++) if (textOf(ps[i]).length > 100 && linkDensity(ps[i]) < 0.3) return true;
    return false;
  }

  /// 输出前清理：去掉残留的导航 / 分享块、空元素，白名单标签和属性
  function sanitize(doc, rootNode, base, title) {
    // 有条件地删除：链接密度高 / 图片少文字少 / 负面类名的块（表格、代码、图片容器除外）
    each(toArray(rootNode.querySelectorAll('div,section,ul,ol,table,p,header')).reverse(), function (n) {
      if (!n.parentNode) return;
      if (n.closest && n.closest('pre,code')) return;
      var t = tag(n);
      var text = textOf(n);
      var imgs = n.getElementsByTagName('img').length;
      var ld = linkDensity(n);
      var weight = classWeight(n);
      if (weight < 0 && text.length < 500 && t !== 'P') { remove(n); return; }
      if (t === 'TABLE') return;
      // 几乎全是链接的短块（分享按钮、标签云）
      if (t !== 'P' && text.length < 100 && imgs === 0 && linkDensity(n, true) > 0.8) { remove(n); return; }
      if (text.length === 0 && imgs === 0 && !n.querySelector('video,br,hr')) { if (t !== 'P' || !n.parentNode) remove(n); else remove(n); return; }
      // 链接列表：紧跟在小标题后面的（「参考链接」「延伸阅读」）保留
      var prevEl = n.previousElementSibling;
      var underHeading = (t === 'UL' || t === 'OL') && prevEl && /^H[2-6]$/.test(tag(prevEl));
      if ((t === 'UL' || t === 'OL' || t === 'DIV' || t === 'SECTION' || t === 'HEADER') && !underHeading && !hasRealParagraph(n) && ld > 0.5 && text.length < 600 && imgs < 2) { remove(n); return; }
      if (t === 'DIV' || t === 'SECTION') {
        var pCount = n.getElementsByTagName('p').length;
        if (imgs > 1 && pCount === 0 && text.length < 50 && !n.querySelector('figcaption')) {
          // 纯图库：保留（文章配图常这样）
          return;
        }
        if (ld > 0.33 && text.length < 200 && imgs === 0 && !hasRealParagraph(n)) remove(n);
      }
    });
    // 和标题重复的第一个 h1 / h2（阅读视图会单独显示标题）
    var firstH = rootNode.querySelector('h1,h2');
    if (firstH && title && norm(firstH.textContent) === norm(title)) remove(firstH);
    // 文章里的 h1 降级为 h2（只保留一个大标题）
    each(toArray(rootNode.getElementsByTagName('h1')), function (h) { rename(doc, h, 'h2'); });

    each(toArray(rootNode.getElementsByTagName('*')), function (n) {
      if (!n.parentNode) return;
      var t = tag(n);
      if (DROP_TAGS[t]) { remove(n); return; }
      if (!KEEP_TAGS[t]) { unwrap(n); return; }
      var keep = KEEP_ATTRS[t] || [];
      each(toArray(n.attributes || []), function (a) {
        if (keep.indexOf(a.name.toLowerCase()) < 0) n.removeAttribute(a.name);
      });
      if (t === 'A') {
        var href = absolutize(attr(n, 'href'), base);
        if (href) n.setAttribute('href', href); else n.removeAttribute('href');
      } else if (t === 'IMG') {
        var src = absolutize(attr(n, 'src'), base);
        if (!src) { remove(n); return; }
        n.setAttribute('src', src);
        if (attr(n, 'srcset')) { var ss = absolutizeSrcset(attr(n, 'srcset'), base); if (ss) n.setAttribute('srcset', ss); else n.removeAttribute('srcset'); }
        // 1×1 跟踪像素
        if (attr(n, 'width') === '1' || attr(n, 'height') === '1') { remove(n); return; }
      } else if (t === 'VIDEO' || t === 'SOURCE') {
        ['src', 'poster'].forEach(function (k) { if (attr(n, k)) { var u = absolutize(attr(n, k), base); if (u) n.setAttribute(k, u); else n.removeAttribute(k); } });
        if (attr(n, 'srcset')) n.setAttribute('srcset', absolutizeSrcset(attr(n, 'srcset'), base));
        if (t === 'VIDEO') n.setAttribute('controls', '');
      }
    });
    // 去掉多层无意义的 div / span 嵌套（只有一个子元素的 div）
    each(toArray(rootNode.querySelectorAll('div,section,article,span')), function (n) {
      if (!n.parentNode) return;
      if (tag(n) === 'SPAN' && !n.attributes.length) { unwrap(n); return; }
      var only = n.children.length === 1 && !norm(Array.prototype.filter.call(n.childNodes, function (c) { return c.nodeType === TEXT; }).map(function (c) { return c.nodeValue; }).join(''));
      if (only) unwrap(n);
    });
  }

  function isProbablyReaderable(doc, opts) {
    opts = opts || {};
    var minContent = opts.minContentLength || 140;
    var minScore = opts.minScore || 20;
    if (!doc || !doc.body) return false;
    var nodes = toArray(doc.querySelectorAll('p, pre, article'));
    var brDivs = doc.querySelectorAll('div > br');
    var seen = new Set(nodes);
    each(brDivs, function (br) { var d = br.parentNode; if (!seen.has(d)) { seen.add(d); nodes.push(d); } });
    var score = 0;
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i];
      if (isHiddenLive(n)) continue;
      var m = classAndId(n);
      if (m && UNLIKELY.test(m) && !MAYBE.test(m)) continue;
      if (n.closest && n.closest('li p, nav, footer, aside')) continue;
      var len = norm(n.textContent).length;
      // 中文信息密度高：1 个汉字按 3 个英文字符计
      var cjk = (n.textContent.match(/[\u3040-\u30ff\u3400-\u9fff\uac00-\ud7af]/g) || []).length;
      len += cjk * 2;
      if (len < minContent) continue;
      score += Math.sqrt(len - minContent);
      if (score > minScore) return true;
    }
    return false;
  }

  function isHiddenLive(n) {
    if (isHidden(n)) return true;
    try {
      var view = n.ownerDocument && n.ownerDocument.defaultView;
      if (view && view.getComputedStyle) {
        var cs = view.getComputedStyle(n);
        if (cs && (cs.display === 'none' || cs.visibility === 'hidden')) return true;
      }
    } catch (e) {}
    return false;
  }

  function extract(doc, opts) {
    opts = opts || {};
    if (!doc || !doc.documentElement) return null;
    var base = opts.url || (doc.baseURI || (doc.location && doc.location.href) || '');
    var ld = jsonLd(doc);
    var siteName = meta(doc, ['og:site_name', 'application-name', 'twitter:site']) .replace(/^@/, '');
    var h1s = toArray(doc.querySelectorAll('h1')).map(textOf).filter(Boolean);
    var rawTitle = meta(doc, ['og:title', 'twitter:title']) || ld.title || (doc.title || '');
    var title = cleanTitle(rawTitle, siteName, h1s) || h1s[0] || '';
    var byline = meta(doc, ['author', 'article:author', 'parsely-author', 'sailthru.author', 'byl', 'dc.creator']) || ld.byline || '';
    if (/^https?:/.test(byline)) byline = '';
    var excerpt = meta(doc, ['og:description', 'description', 'twitter:description']);
    var published = meta(doc, ['article:published_time', 'datePublished', 'pubdate', 'publishdate', 'date']) || ld.published || '';
    var lang = attr(doc.documentElement, 'lang');
    var dir = attr(doc.documentElement, 'dir') || (doc.body && attr(doc.body, 'dir')) || '';

    var clone = doc.documentElement.cloneNode(true);
    var body = clone.querySelector('body') || clone;
    if (!byline) {
      var b = body.querySelector('[rel="author"], [itemprop="author"] [itemprop="name"], [itemprop="author"]');
      if (!b) each(body.querySelectorAll('[class],[id]'), function (n) { if (!b && BYLINE.test(classAndId(n)) && textOf(n).length > 0 && textOf(n).length < 100) b = n; });
      if (b) byline = textOf(b).slice(0, 100);
    }
    fixImages(doc, body, base);
    // 明确的正文容器优先（WordPress / Medium / 新闻站的常见写法）
    prune(doc, body, byline);
    var picked = pickTop(doc, body);
    var top = picked.node;
    if (!top) return null;
    var content = gather(doc, top, picked.scores, picked.score);
    sanitize(doc, content, base, title);
    var text = norm(content.textContent);
    if (text.length < (opts.minTextLength || 200) && !opts.force) return null;
    var images = toArray(content.getElementsByTagName('img')).map(function (i) { return attr(i, 'src'); });
    var html = content.innerHTML;
    return {
      url: base,
      title: title,
      byline: byline,
      siteName: siteName,
      excerpt: excerpt || text.slice(0, 200),
      publishedTime: published,
      lang: lang,
      dir: dir,
      html: html,
      markdown: toMarkdown(content, base),
      text: text,
      textLength: text.length,
      images: images
    };
  }

  // ---------- Markdown ----------

  function mdEscape(s) { return s.replace(/([\\`*_\[\]])/g, '\\$1'); }

  function toMarkdown(node, base) {
    if (!node) return '';
    var out = inline(node, { base: base || '', list: [], pre: false });
    return out.replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n').replace(/\u0001/g, '  ').trim();
  }

  function block(s) { return '\n\n' + s.trim() + '\n\n'; }

  function inline(n, ctx) {
    var s = '';
    for (var c = n.firstChild; c; c = c.nextSibling) s += md(c, ctx);
    return s;
  }

  function md(n, ctx) {
    if (n.nodeType === TEXT) {
      if (ctx.pre) return n.nodeValue;
      var v = n.nodeValue.replace(/\s+/g, ' ');
      return ctx.code ? v : mdEscape(v);
    }
    if (n.nodeType !== ELEMENT) return '';
    var t = tag(n);
    switch (t) {
      case 'H1': case 'H2': case 'H3': case 'H4': case 'H5': case 'H6':
        return block(new Array(+t[1] + 1).join('#') + ' ' + norm(inline(n, ctx)));
      case 'P': case 'DIV': case 'SECTION': case 'ARTICLE': case 'FIGURE': case 'DETAILS': case 'SUMMARY': case 'DL': case 'DD': case 'DT': case 'CAPTION':
        var inner = inline(n, ctx).trim();
        return inner ? block(inner) : '';
      case 'FIGCAPTION':
        var cap = norm(inline(n, ctx));
        return cap ? block('*' + cap + '*') : '';
      case 'BR': return ctx.pre ? '\n' : '\u0001\n';   // 硬换行（两个空格），占位避免被行尾空白清理掉
      case 'HR': return block('---');
      case 'STRONG': case 'B': var bs = inline(n, ctx).trim(); return bs ? '**' + bs + '**' : '';
      case 'EM': case 'I': case 'CITE': var es = inline(n, ctx).trim(); return es ? '*' + es + '*' : '';
      case 'DEL': case 'S': var ds = inline(n, ctx).trim(); return ds ? '~~' + ds + '~~' : '';
      case 'CODE': case 'KBD': case 'SAMP':
        if (ctx.pre) return n.textContent;
        var code = n.textContent.replace(/\s+/g, ' ');
        var fence = code.indexOf('`') >= 0 ? '``' : '`';
        return code ? fence + code + fence : '';
      case 'PRE':
        var lang = attr(n, 'lang') || (n.querySelector('code') && attr(n.querySelector('code'), 'lang')) || '';
        var body = n.textContent.replace(/\n+$/, '');
        return block('```' + lang + '\n' + body + '\n```');
      case 'A':
        var label = norm(inline(n, ctx));
        var href = absolutize(attr(n, 'href'), ctx.base);
        if (!href) return label;
        if (!label) return n.querySelector('img') ? md(n.querySelector('img'), ctx) : '';
        if (/^!\[/.test(label)) return '[' + label + '](' + href + ')';
        return '[' + label + '](' + href.replace(/\)/g, '%29') + ')';
      case 'IMG':
        var src = absolutize(attr(n, 'src'), ctx.base);
        if (!src || /^data:/.test(src)) return '';
        return '![' + mdEscape(norm(attr(n, 'alt'))) + '](' + src.replace(/\)/g, '%29') + ')';
      case 'UL': case 'OL':
        var depth = ctx.list.length;
        var items = [];
        var i = parseInt(attr(n, 'start'), 10) || 1;
        each(toArray(n.children), function (li) {
          if (tag(li) !== 'LI') return;
          var sub = { base: ctx.base, list: ctx.list.concat(t), pre: false };
          var bullet = t === 'OL' ? (i++) + '. ' : '- ';
          var content = inline(li, sub).replace(/\n{2,}/g, '\n').trim();
          var pad = new Array(depth * 2 + 1).join(' ');
          var lines = content.split('\n');
          items.push(pad + bullet + lines[0] + (lines.length > 1 ? '\n' + lines.slice(1).map(function (l) { return /^\s*([-*]|\d+\.)\s/.test(l) ? l : pad + '  ' + l; }).join('\n') : ''));
        });
        return depth ? '\n' + items.join('\n') : block(items.join('\n'));
      case 'BLOCKQUOTE':
        var q = inline(n, ctx).trim().replace(/\n{3,}/g, '\n\n');
        return block(q.split('\n').map(function (l) { return '> ' + l; }).join('\n'));
      case 'TABLE':
        return block(table(n, ctx));
      case 'VIDEO':
        var vs = attr(n, 'src') || (n.querySelector('source') && attr(n.querySelector('source'), 'src'));
        return vs ? block('[视频](' + absolutize(vs, ctx.base) + ')') : '';
      case 'SCRIPT': case 'STYLE': case 'NOSCRIPT': case 'TEMPLATE': return '';
      default:
        return inline(n, ctx);
    }
  }

  function table(n, ctx) {
    var rows = toArray(n.querySelectorAll('tr'));
    if (!rows.length) return '';
    var grid = rows.map(function (r) {
      return toArray(r.children).filter(function (c) { return tag(c) === 'TD' || tag(c) === 'TH'; })
        .map(function (c) { return norm(inline(c, ctx)).replace(/\|/g, '\\|') || ' '; });
    }).filter(function (r) { return r.length; });
    if (!grid.length) return '';
    var cols = Math.max.apply(null, grid.map(function (r) { return r.length; }));
    grid = grid.map(function (r) { while (r.length < cols) r.push(' '); return r; });
    var lines = ['| ' + grid[0].join(' | ') + ' |', '|' + new Array(cols + 1).join(' --- |')];
    grid.slice(1).forEach(function (r) { lines.push('| ' + r.join(' | ') + ' |'); });
    return lines.join('\n');
  }

  // ---------- 阅读视图 ----------

  var THEMES = { light: 1, sepia: 1, dark: 1 };
  var FONTS = { sans: 1, serif: 1, mono: 1 };

  function esc(s) {
    return String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }

  function normalizePrefs(p) {
    p = p || {};
    var size = Math.round(Number(p.fontSize));
    return {
      theme: THEMES[p.theme] ? p.theme : 'light',
      font: FONTS[p.font] ? p.font : 'sans',
      fontSize: isFinite(size) && size >= 12 && size <= 32 ? size : 18
    };
  }

  var READER_CSS = [
    ':root{--fs:18px;--bg:#ffffff;--fg:#1f2328;--muted:#6b7280;--link:#0a66c2;--rule:#e5e7eb;--code:#f3f4f6;color-scheme:light}',
    'html[data-theme=sepia]{--bg:#f6efe1;--fg:#3b2f22;--muted:#7c6a55;--link:#8a4b10;--rule:#e3d6bd;--code:#ede3cf}',
    'html[data-theme=dark]{--bg:#121212;--fg:#e6e6e6;--muted:#9aa0a6;--link:#8ab4f8;--rule:#2c2c2c;--code:#1e1e1e;color-scheme:dark}',
    'html{background:var(--bg);-webkit-text-size-adjust:100%}',
    'body{margin:0;background:var(--bg);color:var(--fg);font:var(--fs)/1.75 -apple-system,BlinkMacSystemFont,"PingFang SC","Hiragino Sans GB","Microsoft YaHei","Segoe UI",Roboto,sans-serif;word-wrap:break-word;overflow-wrap:anywhere}',
    'html[data-font=serif] body{font-family:"Iowan Old Style","Songti SC","Noto Serif CJK SC","Source Han Serif SC",Georgia,"Times New Roman",serif}',
    'html[data-font=mono] body{font-family:ui-monospace,"SF Mono",Menlo,Consolas,monospace;font-size:calc(var(--fs) * .92)}',
    'main{max-width:42em;margin:0 auto;padding:28px 20px 72px}',
    'header.mio-head{margin-bottom:1.6em;border-bottom:1px solid var(--rule);padding-bottom:1em}',
    '.mio-site{color:var(--muted);font-size:.8em;text-transform:none;letter-spacing:.02em}',
    'h1.mio-title{font-size:1.6em;line-height:1.3;margin:.3em 0 .4em}',
    '.mio-meta{color:var(--muted);font-size:.82em}',
    'a{color:var(--link);text-decoration:none}a:hover{text-decoration:underline}',
    'img,video,picture{max-width:100%;height:auto;display:block;margin:1.2em auto;border-radius:4px}',
    'figure{margin:1.4em 0}figcaption{color:var(--muted);font-size:.82em;text-align:center;margin-top:-.6em}',
    'h2,h3,h4,h5,h6{line-height:1.35;margin:1.6em 0 .6em}h2{font-size:1.3em}h3{font-size:1.15em}h4,h5,h6{font-size:1em}',
    'p{margin:0 0 1.1em}',
    'blockquote{margin:1.2em 0;padding:.2em 1em;border-left:3px solid var(--rule);color:var(--muted)}',
    'pre{background:var(--code);padding:.9em 1em;border-radius:6px;overflow:auto;font-size:.85em;line-height:1.5}',
    'code,kbd,samp{font-family:ui-monospace,"SF Mono",Menlo,Consolas,monospace;font-size:.88em;background:var(--code);padding:.1em .3em;border-radius:3px}pre code{background:none;padding:0}',
    'table{border-collapse:collapse;display:block;overflow:auto;margin:1.2em 0;font-size:.9em}td,th{border:1px solid var(--rule);padding:.4em .6em;vertical-align:top}',
    'hr{border:0;border-top:1px solid var(--rule);margin:2em 0}',
    'ul,ol{padding-left:1.6em}li{margin:.3em 0}',
    'footer.mio-foot{margin-top:3em;border-top:1px solid var(--rule);padding-top:1em;color:var(--muted);font-size:.8em;word-break:break-all}'
  ].join('\n');

  function buildPage(article, prefs) {
    var p = normalizePrefs(prefs);
    var a = article || {};
    var host = '';
    try { host = new URL(a.url).host; } catch (e) {}
    var metaBits = [a.byline, a.publishedTime ? String(a.publishedTime).slice(0, 10) : ''].filter(Boolean).map(esc).join(' · ');
    var minutes = a.textLength ? Math.max(1, Math.round(a.textLength / 500)) : 0;
    if (minutes) metaBits += (metaBits ? ' · ' : '') + '约 ' + minutes + ' 分钟';
    return '<!doctype html><html lang="' + esc(a.lang || '') + '"' + (a.dir === 'rtl' ? ' dir="rtl"' : '') +
      ' data-theme="' + p.theme + '" data-font="' + p.font + '" style="--fs:' + p.fontSize + 'px"><head><meta charset="utf-8">' +
      '<meta name="viewport" content="width=device-width,initial-scale=1">' +
      '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; img-src * data: blob:; media-src *; style-src \'unsafe-inline\'; font-src *">' +
      '<meta name="referrer" content="no-referrer-when-downgrade">' +
      '<title>' + esc(a.title || host) + '</title><style>' + READER_CSS + '</style></head><body><main>' +
      '<header class="mio-head"><div class="mio-site">' + esc(a.siteName || host) + '</div>' +
      '<h1 class="mio-title">' + esc(a.title || '') + '</h1>' + (metaBits ? '<div class="mio-meta">' + metaBits + '</div>' : '') + '</header>' +
      '<article>' + (a.html || '') + '</article>' +
      '<footer class="mio-foot">原文：<a href="' + esc(a.url || '') + '">' + esc(a.url || '') + '</a></footer>' +
      '</main></body></html>';
  }

  /// 阅读视图里切换主题 / 字体 / 字号时执行的 JS（原生端拼好后 evaluate；不重新加载页面，保持滚动位置）
  function applyPrefsScript(prefs) {
    var p = normalizePrefs(prefs);
    return '(function(d){d.setAttribute("data-theme",' + JSON.stringify(p.theme) + ');d.setAttribute("data-font",' + JSON.stringify(p.font) +
      ');d.style.setProperty("--fs",' + JSON.stringify(p.fontSize + 'px') + ');return true;})(document.documentElement)';
  }

  var api = {
    version: 1,
    isProbablyReaderable: isProbablyReaderable,
    extract: extract,
    toMarkdown: toMarkdown,
    buildPage: buildPage,
    applyPrefsScript: applyPrefsScript,
    normalizePrefs: normalizePrefs,
    _absolutize: absolutize,
    _cleanTitle: cleanTitle
  };
  root.MioReader = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
