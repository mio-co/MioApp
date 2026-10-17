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
//   newTabOK  local fixture pages (MioNewTabFixture, loadHTMLString + baseURL to fake the origin): plain-site target=_blank /
//             window.open → new selected tab (window.open returns a window), same-tab link navigates in place; MioCore origin
//             (appShell → MioDesktop.browser.open({url}) → bridge openTab) tile / window.open / identity-provider tile → new
//             selected tab; MioCore popup to its Access page and Access login page popup to Google → stay in the opener tab
//   bridgeOK  example.com: window.Mio undefined and the bridge answers forbidden; mio://about: ping → pong
//   blockOK   example.com: Mio ad-block rule lists attached, doubleclick request blocked, same-origin request loads
//   settingsOK  Settings → "Mio 扩展" page (MioExtensionsView) renders with module rows
//   adblockOK   downloaded subscriptions > 10k rules; probe page in a real tab: ad request blocked, ## hidden, scriptlet applied
//   (recorded only) tab overview via the app's own deep link; tabTrayOK = only normal + private panes (v0.4.1)

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

    // MARK: - Links → new tabs

    private func newTabSmoke() async -> [String: Any] {
        var r: [String: Any] = [:]
        var cases: [String: Any] = [:]
        guard let manager = tabManager(), let base = openTab(URL(string: "about:blank")!, select: true),
              let wv = await webView(of: base) else {
            r["error"] = "no tab"; r["ok"] = false; return r
        }
        await waitLoad(wv, timeout: 10)

        func loadPage(_ html: String, _ baseURL: String) async {
            manager.selectTab(base, previous: manager.selectedTab)
            wv.loadHTMLString(html, baseURL: URL(string: baseURL))
            var waited = 0
            while waited < 75 {
                try? await Task.sleep(nanoseconds: 200_000_000); waited += 1
                if !wv.isLoading, wv.url?.absoluteString == baseURL { break }
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        func tryCase(_ name: String, _ js: String, expectNew: Int, expectURL: String? = nil, expectSameTabHost: String? = nil,
                 expectSameTabAccess: Bool = false, expectReturn: String? = nil) async -> Bool {
            // Firefox throttles popups per tab (2 within 2 s)
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            let before = Set(manager.tabs.map { $0.tabUUID })
            let urlBefore = wv.url?.absoluteString
            let ret = await callJS(wv, js)
            var newTabs: [Tab] = []
            var waited = 0
            while waited < 40 {
                try? await Task.sleep(nanoseconds: 250_000_000); waited += 1
                newTabs = manager.tabs.filter { !before.contains($0.tabUUID) }
                let urlsReady = newTabs.allSatisfy { ($0.webView?.url ?? $0.url).map { $0.scheme == "https" } ?? false }
                if expectNew > 0 && newTabs.count >= expectNew && urlsReady { break }
                if expectNew == 0, let h = expectSameTabHost, wv.url?.host == h, !wv.isLoading { break }
                if expectNew == 0, expectSameTabAccess, MioAccessAuth.isAccessURL(wv.url, prefs: MioKitHost.shared.kit.prefs), !wv.isLoading { break }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            newTabs = manager.tabs.filter { !before.contains($0.tabUUID) }
            let newURLs = newTabs.map { ($0.webView?.url ?? $0.url)?.absoluteString ?? "" }
            let selected = manager.selectedTab
            let foreground = newTabs.first.map { $0.tabUUID == selected?.tabUUID } ?? false
            var ok = newTabs.count == expectNew
            if expectNew > 0 { ok = ok && foreground }
            if let u = expectURL { ok = ok && newURLs.contains(where: { MioNewTabFixture.landed($0, on: u) }) }
            if let h = expectSameTabHost { ok = ok && wv.url?.host == h }
            if expectSameTabAccess { ok = ok && MioAccessAuth.isAccessURL(wv.url, prefs: MioKitHost.shared.kit.prefs) }
            if let e = expectReturn { ok = ok && ret == e }
            cases[name] = ["ok": ok, "newTabs": newTabs.count, "newURLs": newURLs, "foreground": foreground, "returned": ret,
                           "sameTabBefore": orNull(urlBefore), "sameTabAfter": orNull(wv.url?.absoluteString)] as [String: Any]
            if !newTabs.isEmpty { manager.removeTabs(newTabs) }
            manager.selectTab(base, previous: manager.selectedTab)
            try? await Task.sleep(nanoseconds: 500_000_000)
            return ok
        }

        typealias F = MioNewTabFixture
        var gate: [Bool] = []
        await loadPage(F.plainPage, F.plainBase)
        gate.append(await tryCase("plainBlank", F.clickJS("blank"), expectNew: 1, expectURL: F.blankTarget))
        gate.append(await tryCase("plainWindowOpen", F.windowOpenJS(F.openTarget), expectNew: 1, expectURL: F.openTarget, expectReturn: "window"))
        gate.append(await tryCase("plainSameTab", F.clickJS("same"), expectNew: 0, expectSameTabHost: "example.org"))

        await loadPage(F.mioCorePage, F.mioCoreBase)
        let shell = await callJS(wv, "return String(window.__appShell) + '/' + typeof window.MioDesktop")
        cases["mioCoreAppShell"] = shell
        gate.append(shell == "true/object")
        gate.append(await tryCase("mioCoreTile", F.clickJS("tile"), expectNew: 1, expectURL: F.coreTileTarget))
        gate.append(await tryCase("mioCoreWindowOpen", F.windowOpenJS(F.coreOpenTarget), expectNew: 1, expectURL: F.coreOpenTarget))
        gate.append(await tryCase("mioCoreIdPTile", F.clickJS("idp"), expectNew: 1, expectURL: F.coreIdPTarget))
        gate.append(await tryCase("mioCoreRawOpenIdP", F.windowOpenJS(F.coreIdPTarget, raw: true), expectNew: 1, expectURL: F.coreIdPTarget,
                              expectReturn: "window"))
        gate.append(await tryCase("mioCoreRawOpenAccess", F.windowOpenJS(F.coreAccessTarget, raw: true), expectNew: 0,
                              expectSameTabAccess: true))
        cases["mioCoreBridgeLog"] = await callJS(wv, "return (window.__opened || []).join(',')")

        await loadPage(F.accessPage, F.accessBase)
        gate.append(await tryCase("accessIdPPopup", F.windowOpenJS(F.accessIdPTarget), expectNew: 0, expectSameTabHost: "accounts.google.com"))

        manager.removeTabs([base])
        r["cases"] = cases
        r["gate"] = gate
        r["ok"] = !gate.isEmpty && gate.allSatisfy { $0 }
        return r
    }

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
            // mio://home → location.replace(MioCore) → (Access) 302 → login page: wait until the web view has left mio://
            var leave = 0
            while (MioBuild.isMioScheme(wv.url) || wv.isLoading) && leave < 60 {
                try? await Task.sleep(nanoseconds: 500_000_000); leave += 1
            }
            await waitLoad(wv, timeout: 20)
            home["waitedForRedirectMs"] = leave * 500
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

        // 3b. Links open new tabs (v0.4.0 regression: MioCore nav page links did nothing) — local fixture pages
        let newTabReport = await newTabSmoke()
        report["newTab"] = newTabReport
        let newTabOK = (newTabReport["ok"] as? Bool) ?? false

        // 3c. Ad-block depth (MioAdblockSmoke.swift): >10k rules from downloaded subscriptions, request blocked,
        //     ## element hidden, real scriptlet applied in a real tab; adblock.turtlecute.org score + screenshot
        let adblock = await MioAdblockSmoke.run(host: host, dir: dir)
        report["adblock"] = adblock
        let adblockOK = (adblock["ok"] as? Bool) == true

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
            // v0.4.1: the tab overview has only normal + private tabs (no upstream "Synced tabs" pane)
            var tray: [String: Any] = ["found": false]
            if let vc = MioSmoke.find(TabTrayViewController.self, from: MioKitHost.topViewController()) {
                tray["found"] = true
                tray["panels"] = vc.childPanelControllers.count
                tray["remoteTabsPanel"] = vc.childPanelControllers.contains { $0.topViewController is RemoteTabsPanel }
                tray["ok"] = vc.childPanelControllers.count == 2
                    && !vc.childPanelControllers.contains { $0.topViewController is RemoteTabsPanel }
            }
            report["tabTray"] = tray
            report["tabTrayOK"] = (tray["ok"] as? Bool) ?? false
        }

        let homePassed = (homeOK as? Bool) == true || (homeOK as? String) == "access-login"
        let pass = homePassed && bridgeOK && blockOK && settingsOK && newTabOK && adblockOK
        report["adblockOK"] = adblockOK
        report["homeOK"] = homeOK
        report["newTabOK"] = newTabOK
        report["bridgeOK"] = bridgeOK
        report["blockOK"] = blockOK
        report["settingsOK"] = settingsOK
        report["pass"] = pass
        report["seconds"] = Int(Date().timeIntervalSince(started))
        write()
        log("MIO_IOS_SMOKE " + (pass ? "PASS" : "FAIL"))
    }

    // MARK: - Helpers

    /// First view controller of `type` in the presented / child hierarchy starting at `root`.
    private static func find<T: UIViewController>(_ type: T.Type, from root: UIViewController?) -> T? {
        guard let root else { return nil }
        if let hit = root as? T { return hit }
        var next: [UIViewController] = root.children
        if let presented = root.presentedViewController { next.append(presented) }
        if let nav = root as? UINavigationController { next.append(contentsOf: nav.viewControllers) }
        for vc in next { if let hit = find(type, from: vc) { return hit } }
        return nil
    }

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
