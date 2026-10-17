// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

// Mio: in-app CI smoke (simulator only, inert unless the app is launched with MIO_SMOKE=1,
// e.g. `SIMCTL_CHILD_MIO_SMOKE=1 xcrun simctl launch …`). Driven by apple/ios/mio/ci/sim-smoke.sh:
//
//   1. the script writes Documents/mio-smoke/go
//   2. the app runs the checks below and writes Documents/mio-smoke/report.json
//   3. for each screenshot the app writes Documents/mio-smoke/shot-request (the name); the script takes a
//      `simctl io screenshot`, deletes the request; the app also keeps its own drawHierarchy copy (<name>-app.png)
//
// Checks (gate = all true):
//   homeOK    mio://home starts a main-frame navigation to the MioCore origin (https://mio.300031.xyz) and lands on
//             MioCore (true), or on the Cloudflare Access login page ("access-login": CI is not signed in; not a
//             failure as long as the login page gets no ad-block rule lists and Safari's UA)
//   bridgeOK  example.com: window.Mio undefined and the bridge answers forbidden; mio://about: ping → pong
//   blockOK   example.com: Mio ad-block rule lists attached, doubleclick request blocked, same-origin request loads
//   settingsOK  Settings → "Mio 扩展" page (MioExtensionsView) renders with module rows
//   (recorded only) tab overview via the app's own deep link

import Foundation
@preconcurrency import MioKit
import UIKit
import WebKit
import SwiftUI

@MainActor
final class MioSmoke {
    static let isRequested = ProcessInfo.processInfo.environment["MIO_SMOKE"] == "1"
    private static var started = false

    static func startIfRequested() {
        guard isRequested, !started else { return }
        started = true
        Task { @MainActor in await MioSmoke().run() }
    }

    private let dir: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("mio-smoke", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private var report: [String: Any] = [:]

    private static let bridgeJS = """
    try {
      const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.mio;
      if (!h) { return 'nohandler'; }
      const r = await h.postMessage({v: 1, id: 'ci', method: 'ping', params: {}});
      return JSON.stringify(r);
    } catch (e) { return 'rejected:' + (e && e.message ? e.message : String(e)); }
    """

    private static let blockProbeJS = """
    async function hit(u) {
      try { await fetch(u, { mode: 'no-cors', cache: 'no-store' }); return 'loaded'; }
      catch (e) { return 'blocked:' + (e && e.message ? e.message : String(e)); }
    }
    const ad = await hit('https://securepubads.g.doubleclick.net/tag/js/gpt.js?mio=' + Date.now());
    const control = await hit(location.origin + '/?mio-control=' + Date.now());
    return JSON.stringify({ ad: ad, control: control });
    """

    // MARK: - Run

    private func run() async {
        log("waiting for go file in \(dir.path)")
        let go = dir.appendingPathComponent("go")
        var waited = 0
        while !FileManager.default.fileExists(atPath: go.path) && waited < 1200 {
            try? await Task.sleep(nanoseconds: 500_000_000); waited += 1
        }
        let started = Date()
        let host = MioKitHost.shared

        // Rule lists compile in the background (bundled EasyList-style lists)
        var ruleWait = 0
        while host.blocker.ruleLists.isEmpty && ruleWait < 600 {
            try? await Task.sleep(nanoseconds: 100_000_000); ruleWait += 1
        }
        report["ruleLists"] = host.blocker.ruleLists.keys.sorted()
        report["rulesReadyMs"] = ruleWait * 100

        // 1. mio://home → MioCore
        var home: [String: Any] = [:]
        let firstTab = tabManager()?.selectedTab
        home["launchTabURL"] = orNull(firstTab?.url?.absoluteString)
        home["launchWebViewURL"] = orNull(firstTab?.webView?.url?.absoluteString)
        var homeOK: Any = false
        if let tab = openTab(MioBuild.homeDisplayURL, select: true), let wv = await webView(of: tab) {
            await waitLoad(wv, timeout: 30)
            let navs = host.mainFrameLog(for: wv)
            home["mainFrameNavigations"] = navs
            home["webViewURL"] = orNull(wv.url?.absoluteString)
            home["tabURL"] = orNull(tab.url?.absoluteString)
            home["tabIsMioHome"] = MioBuild.isMioHome(tab.url)
            let coreHost = MioBuild.homeContentURL.host ?? ""
            let reachedCore = navs.contains { URL(string: $0)?.host?.lowercased() == coreHost }
                || wv.url?.host?.lowercased() == coreHost
            let status = MioAccessAuth.homeStatus(landedOn: wv.url, home: host.kit.home)
            home["landing"] = status
            if status == "access-login" {
                // Access login page: no ad-block lists on it, Safari UA (Google sign-in), stays in this tab
                let applied = host.modules(for: wv)?.appliedRuleListIdentifiers ?? []
                let ua = wv.customUserAgent ?? ""
                home["loginRuleLists"] = applied
                home["loginUserAgent"] = ua
                home["loginNavigatorUserAgent"] = await callJS(wv, "return navigator.userAgent")
                home["loginHost"] = orNull(wv.url?.host)
                home["loginTitle"] = orNull(wv.title)
                let accessOK = reachedCore && applied.isEmpty && !ua.contains("FxiOS") && ua.contains("Safari/")
                homeOK = accessOK ? "access-login" : false
                await shot("05-smoke-access-login")
            } else {
                homeOK = reachedCore && status == "ok"
                await shot("05-smoke-mio-home")
            }
        }
        home["ok"] = homeOK
        report["home"] = home

        // 2. bridge + 3. ad-block on example.com
        var bridge: [String: Any] = [:]
        var block: [String: Any] = [:]
        var bridgeOK = false
        var blockOK = false
        if let tab = openTab(URL(string: "https://example.com/?mio-smoke")!, select: true), let wv = await webView(of: tab) {
            await waitLoad(wv, timeout: 40)
            try? await Task.sleep(nanoseconds: 500_000_000)
            bridge["exampleURL"] = orNull(wv.url?.absoluteString)
            let exReply = await callJS(wv, Self.bridgeJS)
            let exWindowMio = await callJS(wv, "return typeof window.Mio")
            bridge["example"] = exReply
            bridge["exampleWindowMio"] = exWindowMio

            let applied = host.modules(for: wv)?.appliedRuleListIdentifiers ?? []
            block["applied"] = applied
            let probeRaw = await callJS(wv, Self.blockProbeJS)
            let probe = ((try? JSONSerialization.jsonObject(with: Data(probeRaw.utf8))) as? [String: Any]) ?? ["raw": probeRaw]
            block["probe"] = probe
            let adBlocked = ((probe["ad"] as? String) ?? "").hasPrefix("blocked")
            blockOK = !applied.isEmpty && adBlocked && (probe["control"] as? String) == "loaded"
            await shot("06-smoke-example")

            if let about = openTab(URL(string: "mio://about")!, select: true), let awv = await webView(of: about) {
                await waitLoad(awv, timeout: 15)
                bridge["aboutURL"] = orNull(awv.url?.absoluteString)
                let aboutReply = await callJS(awv, Self.bridgeJS)
                bridge["about"] = aboutReply
                bridge["aboutWindowMio"] = await callJS(awv, "return typeof window.Mio")
                bridgeOK = exReply.contains("\"ok\":false") && exReply.contains("forbidden")
                    && exWindowMio == "undefined"
                    && aboutReply.contains("\"ok\":true") && aboutReply.contains("pong")
            }
        }
        bridge["ok"] = bridgeOK
        block["ok"] = blockOK
        report["bridge"] = bridge
        report["block"] = block

        // 4. Settings → Mio 扩展
        var settings: [String: Any] = [:]
        let groups = host.kit.settingsModel.groups()
        settings["groups"] = groups.map { $0.title }
        settings["rows"] = groups.reduce(0) { $0 + $1.rows.count }
        var settingsOK = false
        if let presenter = MioKitHost.topViewController() {
            let model = MioExtensionsViewModel(model: host.kit.settingsModel, kit: host.kit)
            let page = UIHostingController(rootView: MioExtensionsView(viewModel: model))
            page.title = MioExtensionsStrings.title
            let nav = UINavigationController(rootViewController: page)
            nav.modalPresentationStyle = .fullScreen
            presenter.present(nav, animated: false)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            settings["presented"] = nav.presentingViewController != nil
            await shot("07-mio-extensions-settings")
            settingsOK = nav.presentingViewController != nil && !groups.isEmpty
            nav.dismiss(animated: false)
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        settings["ok"] = settingsOK
        report["settings"] = settings

        // Back to the first tab so the script's own steps start from the launch state
        if let firstTab, let manager = tabManager() {
            manager.selectTab(firstTab, previous: manager.selectedTab)
        }

        // Tab overview (recorded only): the app's own deep link, same route as mio://deep-link from outside
        if let tray = URL(string: "\(MioBuild.homeScheme)://deep-link?url=/action/show-tab-tray") {
            _ = await UIApplication.shared.open(tray, options: [:])
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await shot("08-tab-tray")
        }

        let homePassed = (homeOK as? Bool) == true || (homeOK as? String) == "access-login"
        let pass = homePassed && bridgeOK && blockOK && settingsOK
        report["homeOK"] = homeOK
        report["bridgeOK"] = bridgeOK
        report["blockOK"] = blockOK
        report["settingsOK"] = settingsOK
        report["pass"] = pass
        report["seconds"] = Int(Date().timeIntervalSince(started))
        write()
        log("MIO_IOS_SMOKE " + (pass ? "PASS" : "FAIL"))
    }

    // MARK: - Helpers

    private func orNull(_ s: String?) -> Any {
        if let s { return s }
        return NSNull()
    }

    private func log(_ s: String) {
        // unbuffered (stdout is a file under simctl launch --stdout, print() would sit in the buffer)
        FileHandle.standardOutput.write(Data("[mio-smoke] \(s)\n".utf8))
    }

    private func write() {
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]
        let data = (try? JSONSerialization.data(withJSONObject: report, options: options)) ?? Data("{}".utf8)
        try? data.write(to: dir.appendingPathComponent("report.json"), options: .atomic)
    }

    private func tabManager() -> TabManager? {
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return nil }
        let managers = appDelegate.windowManager.allWindowTabManagers()
        return managers.first(where: { $0.selectedTab != nil }) ?? managers.first
    }

    private func openTab(_ url: URL, select: Bool) -> Tab? {
        guard let manager = tabManager() else { return nil }
        let current = manager.selectedTab
        let tab = manager.addTab(URLRequest(url: url), afterTab: current, zombie: false,
                                 isPrivate: current?.isPrivate ?? false)
        if select { manager.selectTab(tab, previous: current) }
        return tab
    }

    private func webView(of tab: Tab) async -> WKWebView? {
        var waited = 0
        while tab.webView == nil && waited < 50 {
            try? await Task.sleep(nanoseconds: 100_000_000); waited += 1
        }
        return tab.webView
    }

    private func waitLoad(_ wv: WKWebView, timeout: Int) async {
        // give the navigation a moment to start, then wait until it settles
        try? await Task.sleep(nanoseconds: 800_000_000)
        var waited = 0
        while (wv.isLoading || wv.url == nil) && waited < timeout * 5 {
            try? await Task.sleep(nanoseconds: 200_000_000); waited += 1
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }

    private func callJS(_ wv: WKWebView, _ js: String) async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            wv.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let value):
                    continuation.resume(returning: (value as? String) ?? "\(value)")
                case .failure(let error):
                    continuation.resume(returning: "error:\(error.localizedDescription)")
                }
            }
        }
    }

    /// Ask the smoke script for a simulator screenshot; also keep an in-app render of the key window.
    private func shot(_ name: String) async {
        let request = dir.appendingPathComponent("shot-request")
        try? Data(name.utf8).write(to: request, options: .atomic)
        var waited = 0
        // simctl screenshots can take a minute on CI runners
        while FileManager.default.fileExists(atPath: request.path) && waited < 450 {
            try? await Task.sleep(nanoseconds: 200_000_000); waited += 1
        }
        try? FileManager.default.removeItem(at: request)
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) else { return }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try? image.pngData()?.write(to: dir.appendingPathComponent("\(name)-app.png"))
    }
}
