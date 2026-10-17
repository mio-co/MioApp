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
          // v0.3.x 兼容：MioCore 页面里的 window.MioDesktop.browser.open(url)
          if (!window.MioDesktop) {
            window.MioDesktop = { browser: { open: function (u, opts) { return call('openTab', { url: String(u), background: !!(opts && opts.background) }); } } };
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
