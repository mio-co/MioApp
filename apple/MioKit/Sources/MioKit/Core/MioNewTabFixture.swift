// MioNewTabFixture.swift — 「链接开新标签」回归用的本地测试页（MioKit 单测 + Mac / iOS 冒烟共用，不联网加载：loadHTMLString + baseURL）。
//
// 页面的安全来源 = baseURL，所以能在本地模拟三种打开者：
//   - 普通网站（https://example.com/…）：target=_blank 链接、window.open、同标签链接
//   - MioCore（https://mio.300031.xyz/mio/nav…）：带 MioCore utils/appShell.ts 同一份逻辑（App 壳里接管站外链接 → window.MioDesktop.browser.open({ url })）
//   - Cloudflare Access 登录页（https://mio-ci.cloudflareaccess.com/cdn-cgi/access/login/…）：弹出身份提供商登录
// 只放测试数据，App 运行时不用。

import Foundation

public enum MioNewTabFixture {
    public static let plainBase = "https://example.com/mio-newtab-smoke"
    public static let mioCoreBase = "https://mio.300031.xyz/mio/nav?mio-newtab-smoke=1"
    public static let accessBase = "https://mio-ci.cloudflareaccess.com/cdn-cgi/access/login/mio.300031.xyz?redirect_url=%2Fmio%2Fnav"

    /// 打开的目标（真实可达的网站，冒烟里新标签要能加载）
    public static let blankTarget = "https://example.org/?mio-newtab=blank"
    public static let openTarget = "https://example.org/?mio-newtab=open"
    public static let sameTabTarget = "https://example.org/?mio-newtab=same"
    public static let modifierTarget = "https://example.org/?mio-newtab=modifier"
    public static let coreTileTarget = "https://example.org/?mio-newtab=core-tile"
    public static let coreOpenTarget = "https://example.org/?mio-newtab=core-open"
    /// MioCore 导航页里指向身份提供商的普通站点卡片（v0.4.0 被吞进当前标签）
    public static let coreIdPTarget = "https://accounts.google.com/?mio-newtab=core-idp"
    /// MioCore 弹出的 Access 页面（会话过期重新登录）：当前标签继续
    public static let coreAccessTarget = "https://mio.300031.xyz/cdn-cgi/access/authorized?mio-newtab=core-access"
    /// Access 登录页弹出的身份提供商登录：当前标签继续
    public static let accessIdPTarget = "https://accounts.google.com/?mio-newtab=access-idp"

    /// MioCore utils/appShell.ts（mio-co/MioCore main 23afe06 installAppLinkHandling）的同一份逻辑；
    /// 另外把原始 window.open 留在 window.__rawOpen（模拟 MioCore 之外的脚本 / 旧版页面直接开窗）
    public static let mioCoreAppShellJS = """
    window.__opened = [];
    function getAppBrowser() { var d = window.MioDesktop && window.MioDesktop.browser; return d && typeof d.open === 'function' ? d : null; }
    function externalHttpUrl(href) {
      if (!href) return null; var u; try { u = new URL(href, location.href); } catch (e) { return null; }
      if (u.protocol !== 'http:' && u.protocol !== 'https:') return null;
      return u.hostname === location.hostname ? null : u.href;
    }
    function openInAppBrowser(href) {
      var b = getAppBrowser(); if (!b) return false; var url = externalHttpUrl(href); if (!url) return false;
      try { var r = b.open({ url: url }); if (r && typeof r.catch === 'function') r.catch(function (e) { window.__opened.push('rejected:' + (e && e.code)); }); }
      catch (e) { return false; }
      return true;
    }
    window.__appShell = !!getAppBrowser();
    if (window.__appShell) {
      document.addEventListener('click', function (event) {
        if (event.defaultPrevented || event.button !== 0) return;
        if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
        var a = event.target && event.target.closest ? event.target.closest('a[href]') : null;
        if (!a || a.hasAttribute('download')) return;
        if (!externalHttpUrl(a.getAttribute('href'))) return;
        if (openInAppBrowser(a.href)) { event.preventDefault(); window.__opened.push('bridge:' + a.href); }
      });
    }
    window.__rawOpen = window.open.bind(window);
    if (window.__appShell) {
      window.open = function (url, target, features) { var h = url === undefined ? '' : String(url); if (h && openInAppBrowser(h)) return null; return window.__rawOpen(url, target, features); };
    }
    """

    /// 普通网站测试页
    public static var plainPage: String {
        """
        <!doctype html><html><head><meta name="viewport" content="width=device-width"><title>Mio new-tab smoke</title></head><body>
        <p><a id="blank" href="\(blankTarget)" target="_blank" rel="noopener noreferrer">target=_blank</a></p>
        <p><a id="modifier" href="\(modifierTarget)" target="_blank">modifier click</a></p>
        <p><a id="same" href="\(sameTabTarget)">same tab</a></p>
        </body></html>
        """
    }

    /// MioCore 导航页（模拟）：站点卡片 = <a target=_blank rel="noopener noreferrer">，搜索 / handleOpenLink = window.open(url, '_blank', 'noopener,noreferrer')
    public static var mioCorePage: String {
        """
        <!doctype html><html><head><meta name="viewport" content="width=device-width"><title>MioCore nav (smoke)</title></head><body>
        <a id="tile" class="nav-tile-hit" href="\(coreTileTarget)" target="_blank" rel="noopener noreferrer">tile</a>
        <a id="idp" class="nav-tile-hit" href="\(coreIdPTarget)" target="_blank" rel="noopener noreferrer">google account</a>
        <script>\(mioCoreAppShellJS)</script>
        </body></html>
        """
    }

    /// Cloudflare Access 登录页（模拟）
    public static var accessPage: String {
        """
        <!doctype html><html><head><meta name="viewport" content="width=device-width"><title>Sign in ・ Cloudflare Access (smoke)</title></head><body>
        <button id="google">Google</button>
        </body></html>
        """
    }

    /// 新标签 / 当前标签的地址是不是打开的那个目标：同主机，且地址里带目标的 mio-newtab 标记
    /// （accounts.google.com 会 302 到 /v3/signin/identifier?continue=<原地址>，标记被编码进 continue 参数）
    public static func landed(_ actual: String?, on expected: String) -> Bool {
        guard let actual, let a = URL(string: actual), let e = URL(string: expected) else { return false }
        if actual.hasPrefix(expected) { return true }
        guard a.host?.lowercased() == e.host?.lowercased() else { return false }
        guard let marker = e.query?.components(separatedBy: "&").first(where: { $0.hasPrefix("mio-newtab=") }) else { return false }
        let value = String(marker.dropFirst("mio-newtab=".count))
        let decoded = actual.removingPercentEncoding ?? actual
        return decoded.contains("mio-newtab=\(value)")
    }

    /// JS（callAsyncJavaScript 体，WebKit 当作用户手势）
    public static func clickJS(_ id: String) -> String {
        "document.getElementById(\(MioJSString.literal(id))).click(); return 'clicked';"
    }

    public static func windowOpenJS(_ url: String, raw: Bool = false) -> String {
        let fn = raw ? "(window.__rawOpen || window.open)" : "window.open"
        return "const w = \(fn)(\(MioJSString.literal(url)), '_blank'); return w ? 'window' : 'null';"
    }

    /// 修饰键 / 中键点击（合成事件：WebKit 从事件里取修饰键 / 按键填 WKNavigationAction）
    public static func modifierClickJS(_ id: String, meta: Bool, shift: Bool = false, button: Int = 0) -> String {
        let type = button == 1 ? "auxclick" : "click"
        return """
        const a = document.getElementById(\(MioJSString.literal(id)));
        a.dispatchEvent(new MouseEvent('\(type)', { bubbles: true, cancelable: true, view: window, metaKey: \(meta), shiftKey: \(shift), button: \(button) }));
        return 'dispatched';
        """
    }
}
