// AdblockCheck <AdblockBundle 目录> <输出目录>
import AppKit
import WebKit
import FilterEngine

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
let bundleDir = URL(fileURLWithPath: args.count > 1 ? args[1] : "AdblockBundle", isDirectory: true)
let outDir = URL(fileURLWithPath: args.count > 2 ? args[2] : "adblock-check", isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

var report: [String: Any] = [:]
var failures: [String] = []

func log(_ s: String) { print(s) }

let iPhoneUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"

final class Loader: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    let session: MioAdblockSession?
    let window: NSWindow
    var finished: (() -> Void)?
    var blockedNav = 0

    init(adblock: Bool) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        webView.customUserAgent = iPhoneUA
        session = adblock ? MioAdblockSession(configuration: config) : nil
        window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 390, height: 844), styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        session?.webView = webView
        webView.navigationDelegate = self
        window.contentView = webView
        window.orderBack(nil)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, navigationAction.targetFrame?.isMainFrame ?? true {
            session?.prepareMainFrame(url)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        if let url = webView.url { session?.prepareMainFrame(url) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished?(); finished = nil }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { log("  didFail \(error)"); finished?(); finished = nil }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { log("  didFailProvisional \(error)"); finished?(); finished = nil }

    func load(_ url: URL, settle: TimeInterval, probe: String, done: @escaping (Any?) -> Void) {
        var called = false
        let timeout = DispatchWorkItem { [weak self] in
            guard let self = self, !called else { return }
            called = true
            self.evaluate(probe, done)
        }
        finished = {
            DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in
                guard let self = self, !called else { return }
                called = true
                timeout.cancel()
                self.evaluate(probe, done)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: timeout)
        webView.load(URLRequest(url: url))
    }

    func evaluate(_ probe: String, _ done: @escaping (Any?) -> Void) {
        webView.evaluateJavaScript(probe) { value, error in
            if let error = error { log("  probe error \(error)") }
            done(value)
        }
    }

    func snapshot(to url: URL, done: @escaping () -> Void) {
        webView.takeSnapshot(with: nil) { image, _ in
            if let image = image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: url)
            }
            done()
        }
    }
}

let ytProbe = """
(function(){
  var r = window.ytInitialPlayerResponse;
  function n(v){ return v === undefined || v === null ? null : (Array.isArray(v) ? v.length : 'present'); }
  var sel = 'ad-slot-renderer, ytm-promoted-sparkles-web-renderer, ytm-companion-ad-renderer, ytm-promoted-video-renderer, ytd-ad-slot-renderer, #player-ads';
  var els = Array.prototype.slice.call(document.querySelectorAll(sel));
  var visible = els.filter(function(e){ var s = getComputedStyle(e); return s.display !== 'none' && s.visibility !== 'hidden' && e.getBoundingClientRect().height > 0; });
  var res = performance.getEntriesByType('resource').map(function(e){ return e.name; });
  var adRes = res.filter(function(u){ return /doubleclick\\.net|googlesyndication|\\/pagead\\/|\\/api\\/stats\\/ads|ad_break|googleadservices/.test(u); });
  return JSON.stringify({
    title: document.title, url: location.href,
    hasPlayerResponse: !!r,
    playability: r && r.playabilityStatus ? r.playabilityStatus.status : null,
    adPlacements: r ? n(r.adPlacements) : 'no-player-response',
    playerAds: r ? n(r.playerAds) : 'no-player-response',
    adSlots: r ? n(r.adSlots) : 'no-player-response',
    adElements: els.length, adElementsVisible: visible.length,
    mioStyles: document.querySelectorAll('style[data-mio-adblock]').length,
    resources: res.length, adResources: adRes.slice(0, 20), adResourceCount: adRes.length,
    htmlHasAdPlacements: document.documentElement.innerHTML.indexOf('"adPlacements"') >= 0
  });
})()
"""

let toolzProbe = """
(function(){ var t = (document.body && document.body.innerText) || ''; return JSON.stringify({ title: document.title, text: t.slice(0, 1500) }); })()
"""

func runPages(_ adblock: Bool, _ pages: [(String, URL, String, TimeInterval)], _ index: Int, _ results: [String: Any], done: @escaping ([String: Any]) -> Void) {
    guard index < pages.count else { done(results); return }
    let (name, url, probe, settle) = pages[index]
    let loader = Loader(adblock: adblock)
    log("== \(adblock ? "ON " : "OFF") \(name) \(url.absoluteString)")
    let started = Date()
    loader.load(url, settle: settle, probe: probe) { value in
        var r = results
        var parsed: Any = value ?? NSNull()
        if let s = value as? String, let d = s.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) { parsed = obj }
        r[name] = ["result": parsed, "seconds": Date().timeIntervalSince(started)]
        log("   \(value as? String ?? "nil")")
        let png = outDir.appendingPathComponent("\(name)-\(adblock ? "on" : "off").png")
        loader.snapshot(to: png) {
            _ = loader
            runPages(adblock, pages, index + 1, r, done: done)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

MioAdblock.shared.bundleDir = bundleDir
let t0 = Date()
log("Converting + compiling bundled lists from \(bundleDir.path) …")
MioAdblock.shared.start(checkUpdates: false) {
    let snap = MioAdblock.shared.snapshot
    let compileSeconds = Date().timeIntervalSince(t0)
    var lists: [String: Any] = [:]
    for l in MioFilterCatalog.lists {
        guard let m = snap.state.lists[l.key] else { failures.append("list \(l.id) missing"); continue }
        lists[l.name] = ["source": m.sourceRules, "safari": m.safariRules, "advanced": m.advancedRules, "parts": m.parts,
                         "discarded": m.discarded, "version": m.version ?? "", "error": m.error ?? ""]
        log(String(format: "  %-20@ %6d src → %6d safari, %5d adv, %d part(s), %d discarded %@", l.name as NSString, m.sourceRules, m.safariRules, m.advancedRules, m.parts, m.discarded, (m.error ?? "") as NSString))
        if m.error != nil { failures.append("\(l.name): \(m.error!)") }
        if m.parts == 0 { failures.append("\(l.name): not compiled") }
    }
    report["compileSeconds"] = compileSeconds
    report["lists"] = lists
    report["ruleLists"] = snap.ruleListCount
    report["scriptlets"] = MioAdblock.shared.scriptletsVersion ?? "none"
    log("Compiled \(snap.ruleListCount) WKContentRuleLists in \(String(format: "%.1f", compileSeconds))s; scriptlets \(MioAdblock.shared.scriptletsVersion ?? "none")")

    // 高级规则查询
    var lookups: [String: Any] = [:]
    for u in ["https://m.youtube.com/", "https://m.youtube.com/watch?v=dQw4w9WgXcQ", "https://www.youtube.com/watch?v=dQw4w9WgXcQ"] {
        let url = URL(string: u)!
        let t = Date()
        guard let conf = MioAdblock.shared.configuration(for: url) else { failures.append("lookup \(u) nil"); continue }
        let script = MioAdblock.pageScriptForCheck(url)
        let names = conf.scriptlets.map { "\($0.name)(\($0.args.joined(separator: ", ")))" }
        lookups[u] = ["css": conf.css.count, "extendedCss": conf.extendedCss.count, "js": conf.js.count,
                      "scriptlets": names, "scriptBytes": script?.utf8.count ?? 0,
                      "ms": Date().timeIntervalSince(t) * 1000]
        log("  lookup \(u): \(conf.css.count) css, \(conf.extendedCss.count) ext, \(conf.js.count) js, \(conf.scriptlets.count) scriptlets, script \(script?.utf8.count ?? 0) B")
        for n in names { log("     · \(n)") }
        if u.contains("m.youtube.com/watch") {
            let hasPrune = conf.scriptlets.contains { $0.name.contains("json-prune") && $0.args.joined().contains("adPlacements") }
            let hasConst = conf.scriptlets.contains { $0.name == "set-constant" && $0.args.first == "ytInitialPlayerResponse.adPlacements" }
            if !hasPrune { failures.append("m.youtube watch: no json-prune adPlacements") }
            if !hasConst { failures.append("m.youtube watch: no set-constant ytInitialPlayerResponse.adPlacements") }
        }
    }
    report["lookups"] = lookups

    let pages: [(String, URL, String, TimeInterval)] = [
        ("youtube-watch", URL(string: "https://m.youtube.com/watch?v=dQw4w9WgXcQ")!, ytProbe, 8),
        ("youtube-home", URL(string: "https://m.youtube.com/")!, ytProbe, 6),
        ("toolz-adblock", URL(string: "https://d3ward.github.io/toolz/adblock.html")!, toolzProbe, 20),
    ]
    runPages(false, pages, 0, [:]) { off in
        report["pagesOff"] = off
        runPages(true, pages, 0, [:]) { on in
            report["pagesOn"] = on
            report["failures"] = failures
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: outDir.appendingPathComponent("report.json"))
            }
            log(failures.isEmpty ? "ADBLOCK CHECK OK" : "ADBLOCK CHECK FAILURES:\n - " + failures.joined(separator: "\n - "))
            exit(failures.isEmpty ? 0 : 1)
        }
    }
}
app.run()
