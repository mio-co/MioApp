// 诊断：同一台 macOS 上，原生 AppKit 的 WKWebView（与 Safari 同一个 WebKit）里 MediaSource 是否存在。
// 用来区分「这台机器 / VM 没有 MSE」和「Mac Catalyst（iOS 版 WebKit 配置）没有 MSE」。
// 用法：swift scripts/mac-appkit-mse-probe.swift [url]   输出一行 JSON
import Cocoa
import WebKit

let url = CommandLine.arguments.dropFirst().first ?? "https://example.com/"
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

final class Probe: NSObject, WKNavigationDelegate {
    let wv: WKWebView
    let window: NSWindow
    override init() {
        let c = WKWebViewConfiguration()
        wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: c)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        window.contentView = wv
        wv.navigationDelegate = self
    }
    func start() { wv.load(URLRequest(url: URL(string: url)!)) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let js = """
            JSON.stringify({ ua: navigator.userAgent, mediaSource: typeof window.MediaSource, managedMediaSource: typeof window.ManagedMediaSource,
              vp9: window.MediaSource ? MediaSource.isTypeSupported('video/webm; codecs="vp9"') : null,
              avc1: window.MediaSource ? MediaSource.isTypeSupported('video/mp4; codecs="avc1.640028"') : null })
            """
            webView.evaluateJavaScript(js) { r, e in
                print("APPKIT_MSE_PROBE " + ((r as? String) ?? "error \(String(describing: e))"))
                exit(0)
            }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { print("APPKIT_MSE_PROBE fail \(error)"); exit(0) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { print("APPKIT_MSE_PROBE fail \(error)"); exit(0) }
}

let p = Probe()
p.start()
DispatchQueue.main.asyncAfter(deadline: .now() + 40) { print("APPKIT_MSE_PROBE timeout"); exit(0) }
app.run()
