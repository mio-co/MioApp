// MioCoreBridgeHandler.swift — MioCore 本机桥的 WebKit 端：WKScriptMessageHandlerWithReply（页面世界，名字 mio）。
// 任何网页都能看到 window.webkit.messageHandlers.mio（WebKit 不能按来源注册），所以每条消息都用发消息 frame 的
// securityOrigin 做校验（MioCoreOrigin.check）；非 MioCore / mio:// 来源一律回 forbidden，不执行任何方法。
// shimUserScript：document-start 注入 window.Mio.call()（脚本自己也先看来源，只在允许的页面定义；真正的门槛仍是原生校验）
// 以及 v0.3.x 兼容：window.MioDesktop.browser.open(url) → openTab。

#if canImport(WebKit)
import Foundation
import WebKit

@MainActor
public final class MioCoreBridgeHandler: NSObject {
    public let bridge: MioCoreBridge
    private var attached = false

    public init(bridge: MioCoreBridge) { self.bridge = bridge }

    public func attach(to controller: WKUserContentController) {
        guard !attached else { return }
        controller.addScriptMessageHandler(MioBridgeWeakProxy(self), contentWorld: .page, name: MioCoreBridge.handlerName)
        attached = true
    }

    public func detach(from controller: WKUserContentController) {
        guard attached else { return }
        controller.removeScriptMessageHandler(forName: MioCoreBridge.handlerName, contentWorld: .page)
        attached = false
    }

    func handle(_ info: MioWKMessageInfo) async -> [String: Any] {
        await bridge.handle(body: info.body, origin: info.origin, isMainFrame: info.isMainFrame)
    }

    /// window.Mio 封装（只在 MioCore 来源 / mio:// 页面里定义）
    public func shimUserScript() -> WKUserScript {
        WKUserScript(source: Self.shimSource(allowedOrigin: MioCoreOrigin.configured(bridge.prefs).description),
                     injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)
    }

    public static func shimSource(allowedOrigin: String) -> String {
        """
        (function () {
          'use strict';
          var ok = location.protocol === 'mio:' || location.origin === \(MioJSString.literal(allowedOrigin));
          if (!ok || (window.Mio && window.Mio.call)) return;
          var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(MioCoreBridge.handlerName);
          if (!h) return;
          var seq = 0;
          function call(method, params) {
            return h.postMessage({ v: \(MioCoreBridge.apiVersion), id: String(++seq), method: String(method), params: params || {} }).then(function (r) {
              if (r && r.ok) return r.result;
              var e = new Error(r && r.error ? r.error.message : 'failed');
              e.code = r && r.error ? r.error.code : 'failed';
              throw e;
            });
          }
          Object.defineProperty(window, 'Mio', { value: Object.freeze({ api: \(MioCoreBridge.apiVersion), call: call }), configurable: false, writable: false });
          // v0.3.x 兼容：MioCore 页面里的 window.MioDesktop.browser.open(…)（MioCore utils/appShell.ts 接管站外链接点击和 window.open 时调用）。
          // MioCore 传的是对象 { url, mode? }（与 Capacitor MioBrowser 插件 / Electron 壳同一签名），也接受字符串 + { background }。
          // 地址不能解析成 http(s) / mio:// 时同步抛错：MioCore 的 openInAppBrowser 收到异常就不 preventDefault，链接照常走浏览器自己的
          // target=_blank / window.open（新标签），不会出现「点了没反应」。（v0.4.0 把对象 String() 成 "[object Object]"，桥回 bad_request，
          // 而 MioCore 已经 preventDefault —— 导航页的链接全部点不开）
          if (!window.MioDesktop) {
            var openTab = function (u, opts) {
              var o = (u && typeof u === 'object' && !(u instanceof URL)) ? u : (opts || {});
              var raw = (u && typeof u === 'object' && !(u instanceof URL)) ? (u.url || u.href) : u;
              if (raw === undefined || raw === null || raw === '') throw new TypeError('MioDesktop.browser.open: url required');
              var abs;
              try { abs = new URL(String(raw), location.href); } catch (e) { throw new TypeError('MioDesktop.browser.open: bad url'); }
              if (!/^(https?|mio):$/.test(abs.protocol)) throw new TypeError('MioDesktop.browser.open: unsupported scheme ' + abs.protocol);
              return call('openTab', { url: abs.href, background: !!(o && o.background) });
            };
            window.MioDesktop = { browser: { open: openTab } };
          }
        })();
        """
    }
}

final class MioBridgeWeakProxy: NSObject, WKScriptMessageHandlerWithReply {
    weak var target: MioCoreBridgeHandler?
    init(_ t: MioCoreBridgeHandler) { target = t }
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        let info = MioWKMessageInfo(message)
        Task { @MainActor [weak t = self.target] in
            guard let t = t else { replyHandler(nil, "browser closed"); return }
            replyHandler(await t.handle(info), nil)
        }
    }
}

/// mio:// 内置页（mio://home → MioCore 首页，mio://offline，mio://about）
public final class MioSchemeHandler: NSObject, WKURLSchemeHandler {
    let homeModel: () -> MioHomeModel
    public init(kit: MioKitContainer) { let k = kit; homeModel = { k.home } }
    public init(home: @escaping () -> MioHomeModel) { homeModel = home }

    public func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { task.didFailWithError(URLError(.badURL)); return }
        let r = homeModel().response(for: url)
        let resp = HTTPURLResponse(url: url, statusCode: r.statusCode, httpVersion: "HTTP/1.1", headerFields: r.headers)!
        task.didReceive(resp)
        task.didReceive(r.body)
        task.didFinish()
    }

    public func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
#endif
