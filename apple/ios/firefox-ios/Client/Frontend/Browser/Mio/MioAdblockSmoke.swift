// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

// Mio: ad-block depth check for the CI simulator smoke (called from MioSmoke; report key "adblock", gate adblockOK).
//   - subscriptions really downloaded + compiled (> 10,000 content rules)
//   - probe page loaded into a REAL tab (Firefox navigation path → MioKitHost.willNavigateMainFrame): ad request blocked,
//     ## generic element hiding applied, a real set-constant scriptlet from the downloaded lists applied
//   - adblock.turtlecute.org score in a real tab + screenshot (recorded only)

import Foundation
@preconcurrency import MioKit
import UIKit
import WebKit

@MainActor
enum MioAdblockSmoke {
    static func run(host: MioKitHost, dir: URL) async -> [String: Any] {
        let started = Date()
        let ready = await MioAdblockProbe.waitForRules(host.blocker, minContentRules: 10_000, timeout: 420)
        var r: [String: Any] = ["rulesReady": ready, "rulesReadySeconds": Int(Date().timeIntervalSince(started))]
        guard let tab = openTab(URL(string: "about:blank")!), let wv = await webView(of: tab) else {
            r["error"] = "no tab"; r["ok"] = false; return r
        }
        let probe = await MioAdblockProbe.run(blocker: host.blocker, webView: wv) { html, base in
            wv.loadHTMLString(html, baseURL: base)
            await waitLoad(wv, timeout: 30)
        }
        for (k, v) in probe { r[k] = v }
        r["appliedInTab"] = host.modules(for: wv)?.appliedRuleListIdentifiers.count ?? 0
        r["preparedHostsInTab"] = host.modules(for: wv)?.adblockPrepared.map { $0.host } ?? []
        await shot("09-adblock-probe", dir: dir)

        if let site = openTab(MioAdblockProbe.scoreSite), let swv = await webView(of: site) {
            await waitLoad(swv, timeout: 60)
            r["turtlecute"] = await MioAdblockProbe.turtlecuteScore(swv, settle: 40)
            await shot("10-adblock-turtlecute", dir: dir)
        }
        r["seconds"] = Int(Date().timeIntervalSince(started))
        return r
    }

    private static func tabManager() -> TabManager? {
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return nil }
        let managers = appDelegate.windowManager.allWindowTabManagers()
        return managers.first(where: { $0.selectedTab != nil }) ?? managers.first
    }

    private static func openTab(_ url: URL) -> Tab? {
        guard let manager = tabManager() else { return nil }
        let current = manager.selectedTab
        let tab = manager.addTab(URLRequest(url: url), afterTab: current, zombie: false, isPrivate: current?.isPrivate ?? false)
        manager.selectTab(tab, previous: current)
        return tab
    }

    private static func webView(of tab: Tab) async -> WKWebView? {
        var waited = 0
        while tab.webView == nil && waited < 50 { try? await Task.sleep(nanoseconds: 100_000_000); waited += 1 }
        return tab.webView
    }

    private static func waitLoad(_ wv: WKWebView, timeout: Int) async {
        try? await Task.sleep(nanoseconds: 800_000_000)
        var waited = 0
        while (wv.isLoading || wv.url == nil) && waited < timeout * 5 { try? await Task.sleep(nanoseconds: 200_000_000); waited += 1 }
        try? await Task.sleep(nanoseconds: 800_000_000)
    }

    /// Same protocol as MioSmoke.shot: ask sim-smoke.sh for a simulator screenshot, keep an in-app render too.
    private static func shot(_ name: String, dir: URL) async {
        let request = dir.appendingPathComponent("shot-request")
        try? Data(name.utf8).write(to: request, options: .atomic)
        var waited = 0
        while FileManager.default.fileExists(atPath: request.path) && waited < 450 { try? await Task.sleep(nanoseconds: 200_000_000); waited += 1 }
        try? FileManager.default.removeItem(at: request)
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows }).first(where: { $0.isKeyWindow }) else { return }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        try? image.pngData()?.write(to: dir.appendingPathComponent("\(name)-app.png"))
    }
}
