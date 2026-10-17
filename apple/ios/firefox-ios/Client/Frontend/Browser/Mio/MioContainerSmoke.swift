// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

// Mio: container part of the CI simulator smoke (inert unless MIO_SMOKE=1; driven by apple/ios/mio/ci/sim-smoke.sh).
//
// Phase 1 (called from MioSmoke.run → report.json "containers", gate containersOK):
//   - presets 个人 / 工作 / 购物 / 银行 exist
//   - the same local page (MIO_SMOKE_LOCAL_URL, served by the script on 127.0.0.1) opened in 个人 and 工作 sets a
//     different cookie + localStorage value in each; neither sees the other's, a default-container tab sees neither
//   - each container tab's web view uses WKWebsiteDataStore(forIdentifier: <container id>)
//   - a tab opened from the 个人 tab (link → new tab) is in 个人 and sees 个人's cookie
//   - (recorded only) window.open from the 个人 tab
//   - screenshots: container tab (address bar badge), container picker, Settings → 容器
//   - writes containers-expect.json for phase 2
// Phase 2 (MIO_SMOKE_PHASE=restore, app relaunched by the script; writes restore.json, gate containersRestoreOK):
//   - the 个人 / 工作 tabs come back with the same tabUUID, the same container record and a web view on the
//     container's data store; (recorded only) the 个人 cookie survived the relaunch

import Foundation
@preconcurrency import MioKit
import UIKit
import WebKit

@MainActor
final class MioContainerSmoke {
    static var isRestorePhase: Bool { ProcessInfo.processInfo.environment["MIO_SMOKE_PHASE"] == "restore" }

    private let dir: URL
    private var localURL: URL {
        let raw = ProcessInfo.processInfo.environment["MIO_SMOKE_LOCAL_URL"] ?? "http://127.0.0.1:8765/containers.html"
        return URL(string: raw) ?? URL(string: "http://127.0.0.1:8765/containers.html")!
    }

    init(dir: URL) { self.dir = dir }

    private static let setJS = """
    document.cookie = 'mio_ct=' + v + '; max-age=86400; path=/';
    localStorage.setItem('mio_ct', v);
    return document.cookie + '|' + (localStorage.getItem('mio_ct') || '');
    """
    private static let readJS = "return document.cookie + '|' + (localStorage.getItem('mio_ct') || '');"

    // MARK: - Phase 1

    func run() async -> [String: Any] {
        var r: [String: Any] = [:]
        let ui = MioContainerUI.shared
        r["supported"] = MioContainerUI.isSupported
        r["containers"] = ui.containers.map { ["id": $0.id, "name": $0.name, "color": $0.color, "icon": $0.icon] }
        guard MioContainerUI.isSupported, let tm = tabManager() else {
            r["ok"] = false
            r["error"] = "unsupported or no tab manager"
            return r
        }
        let names = ui.containers.map { $0.name }
        let presetsOK = ["默认", "个人", "工作", "购物", "银行"].allSatisfy { names.contains($0) }
        r["presetsOK"] = presetsOK
        guard let personal = ui.containers.first(where: { $0.name == "个人" }),
              let work = ui.containers.first(where: { $0.name == "工作" }) else {
            r["ok"] = false
            return r
        }
        let base = localURL
        r["localURL"] = base.absoluteString

        let tabA = ui.openTab(page(base, "A"), containerID: personal.id, in: tm, afterTab: nil, select: true)
        guard let wvA = await webView(of: tabA) else { r["ok"] = false; r["error"] = "no web view A"; return r }
        await waitLoad(wvA, timeout: 20)
        r["setA"] = await callJS(wvA, Self.setJS, ["v": "A"])

        let tabB = ui.openTab(page(base, "B"), containerID: work.id, in: tm, afterTab: nil, select: true)
        guard let wvB = await webView(of: tabB) else { r["ok"] = false; r["error"] = "no web view B"; return r }
        await waitLoad(wvB, timeout: 20)
        r["setB"] = await callJS(wvB, Self.setJS, ["v": "B"])

        // default container tab (no parent, no picked container)
        let tabD = tm.addTab(URLRequest(url: page(base, "D")), afterTab: nil, zombie: false, isPrivate: false)
        var readD = "none"
        if let wvD = await webView(of: tabD) {
            await waitLoad(wvD, timeout: 20)
            readD = await callJS(wvD, Self.readJS)
        }

        wvA.reload(); wvB.reload()
        await waitLoad(wvA, timeout: 20)
        await waitLoad(wvB, timeout: 20)
        let readA = await callJS(wvA, Self.readJS)
        let readB = await callJS(wvB, Self.readJS)
        r["readA"] = readA
        r["readB"] = readB
        r["readDefault"] = readD
        let isolated = readA.contains("mio_ct=A") && !readA.contains("mio_ct=B") && readA.hasSuffix("|A")
            && readB.contains("mio_ct=B") && !readB.contains("mio_ct=A") && readB.hasSuffix("|B")
            && !readD.contains("mio_ct=") && readD.hasSuffix("|")
        r["isolated"] = isolated

        let idA = MioContainerDataStores.identifier(of: wvA.configuration.websiteDataStore)
        let idB = MioContainerDataStores.identifier(of: wvB.configuration.websiteDataStore)
        let idD = tabD.webView.flatMap { MioContainerDataStores.identifier(of: $0.configuration.websiteDataStore) }
        r["dataStoreA"] = orNull(idA)
        r["dataStoreB"] = orNull(idB)
        r["dataStoreDefault"] = orNull(idD)
        let recordA = ui.containerID(forTabUUID: tabA.tabUUID)
        let recordB = ui.containerID(forTabUUID: tabB.tabUUID)
        let recordD = ui.containerID(forTabUUID: tabD.tabUUID)
        r["recordA"] = recordA
        r["recordB"] = recordB
        r["recordDefault"] = recordD
        let storesOK = idA == personal.id && idB == work.id && idD == nil
            && recordA == personal.id && recordB == work.id && recordD == MioContainerCore.defaultId

        // link → new tab from the 个人 tab: same container
        tm.selectTab(tabA, previous: tm.selectedTab)
        let child = tm.addTab(URLRequest(url: page(base, "child")), afterTab: tabA, zombie: false, isPrivate: false)
        var childOK = false
        if let wvC = await webView(of: child) {
            await waitLoad(wvC, timeout: 20)
            let readC = await callJS(wvC, Self.readJS)
            r["readChild"] = readC
            r["recordChild"] = ui.containerID(forTabUUID: child.tabUUID)
            childOK = ui.containerID(forTabUUID: child.tabUUID) == personal.id && readC.contains("mio_ct=A")
                && MioContainerDataStores.identifier(of: wvC.configuration.websiteDataStore) == personal.id
        }
        r["childInheritsOK"] = childOK
        tm.removeTab(child.tabUUID)
        tm.removeTab(tabD.tabUUID)

        // window.open from 个人 (recorded only: depends on the pop-up blocker setting)
        tm.selectTab(tabA, previous: tm.selectedTab)
        try? await Task.sleep(nanoseconds: 500_000_000)
        let before = Set(tm.tabs.map { $0.tabUUID })
        r["windowOpen"] = await callJS(wvA, "window.open(location.origin + location.pathname + '?c=popup', '_blank'); return 'called';")
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        if let popup = tm.tabs.first(where: { !before.contains($0.tabUUID) }) {
            var info: [String: Any] = ["container": ui.containerID(forTabUUID: popup.tabUUID)]
            if let wvP = popup.webView {
                await waitLoad(wvP, timeout: 10)
                info["read"] = await callJS(wvP, Self.readJS)
                info["dataStore"] = orNull(MioContainerDataStores.identifier(of: wvP.configuration.websiteDataStore))
            }
            info["inherits"] = (info["container"] as? String) == personal.id
            r["popup"] = info
            tm.removeTab(popup.tabUUID)
        } else {
            r["popup"] = "no popup tab (pop-ups blocked)"
        }

        // Screenshots: container tab with the address bar badge, picker, Settings → 容器
        tm.selectTab(tabA, previous: tm.selectedTab)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        await shot("09-container-tab")
        if let presenter = MioKitHost.topViewController() {
            ui.presentPicker(title: "新建容器标签", message: "新标签的 Cookie、登录和缓存只属于所选容器。", from: presenter) { _ in }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await shot("10-container-picker")
            presenter.dismiss(animated: false)
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        if let presenter = MioKitHost.topViewController() {
            let nav = UINavigationController(rootViewController: MioContainersSetting.makeController())
            nav.modalPresentationStyle = .fullScreen
            presenter.present(nav, animated: false)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            r["settingsPresented"] = nav.presentingViewController != nil
            await shot("11-containers-settings")
            nav.dismiss(animated: false)
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        // Expectations for the relaunch phase; make sure Firefox has written its tab session
        let expect: [String: Any] = ["tabA": tabA.tabUUID, "containerA": personal.id,
                                     "tabB": tabB.tabUUID, "containerB": work.id]
        write(expect, "containers-expect.json")
        tm.preserveTabs()
        try? await Task.sleep(nanoseconds: 3_000_000_000)

        let ok = presetsOK && isolated && storesOK && childOK
        r["storesOK"] = storesOK
        r["ok"] = ok
        return r
    }

    // MARK: - Phase 2 (relaunch)

    func runRestore() async {
        log("restore phase: waiting for go-restore")
        let go = dir.appendingPathComponent("go-restore")
        var waited = 0
        while !FileManager.default.fileExists(atPath: go.path) && waited < 600 {
            try? await Task.sleep(nanoseconds: 500_000_000); waited += 1
        }
        var r: [String: Any] = [:]
        let expectData = try? Data(contentsOf: dir.appendingPathComponent("containers-expect.json"))
        let expect = expectData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        r["expect"] = expect
        guard let keyA = expect["tabA"] as? String, let cA = expect["containerA"] as? String,
              let keyB = expect["tabB"] as? String, let cB = expect["containerB"] as? String else {
            r["containersRestoreOK"] = false
            r["error"] = "no containers-expect.json"
            write(r, "restore.json")
            return
        }
        // Wait for session restore
        var tabA: Tab?
        var tabB: Tab?
        for _ in 0..<60 {
            if let tm = tabManager() {
                tabA = tm.getTabForUUID(uuid: keyA)
                tabB = tm.getTabForUUID(uuid: keyB)
            }
            if tabA != nil && tabB != nil { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        let ui = MioContainerUI.shared
        r["tabs"] = tabManager()?.tabs.map { ["id": $0.tabUUID, "url": $0.url?.absoluteString ?? "",
                                              "container": ui.containerID(forTabUUID: $0.tabUUID)] } ?? []
        r["foundA"] = tabA != nil
        r["foundB"] = tabB != nil
        r["recordA"] = ui.containerID(forTabUUID: keyA)
        r["recordB"] = ui.containerID(forTabUUID: keyB)
        var storeOK = false
        if let tm = tabManager(), let tabA {
            tm.selectTab(tabA, previous: tm.selectedTab)
            if let wv = await webView(of: tabA) {
                await waitLoad(wv, timeout: 20)
                let id = MioContainerDataStores.identifier(of: wv.configuration.websiteDataStore)
                r["dataStoreA"] = orNull(id)
                storeOK = id == cA
                let read = await callJS(wv, Self.readJS)
                r["readA"] = read
                r["cookiePersisted"] = read.contains("mio_ct=A")
            }
            try? await Task.sleep(nanoseconds: 800_000_000)
            await shot("12-restored-container-tab")
        }
        let ok = tabA != nil && tabB != nil && ui.containerID(forTabUUID: keyA) == cA
            && ui.containerID(forTabUUID: keyB) == cB && storeOK
        r["containersRestoreOK"] = ok
        write(r, "restore.json")
        log("MIO_IOS_CONTAINERS_RESTORE " + (ok ? "PASS" : "FAIL"))
    }

    // MARK: - Helpers (same protocol as MioSmoke: shot-request file → simctl screenshot)

    private func page(_ base: URL, _ tag: String) -> URL {
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)
        c?.queryItems = [URLQueryItem(name: "c", value: tag)]
        return c?.url ?? base
    }

    private func orNull(_ s: String?) -> Any {
        if let s { return s }
        return NSNull()
    }

    private func log(_ s: String) {
        FileHandle.standardOutput.write(Data("[mio-smoke] \(s)\n".utf8))
    }

    private func write(_ obj: [String: Any], _ name: String) {
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: options)) ?? Data("{}".utf8)
        try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
    }

    private func tabManager() -> TabManager? {
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return nil }
        let managers = appDelegate.windowManager.allWindowTabManagers()
        return managers.first(where: { $0.selectedTab != nil }) ?? managers.first
    }

    private func webView(of tab: Tab) async -> WKWebView? {
        var waited = 0
        while tab.webView == nil && waited < 50 {
            try? await Task.sleep(nanoseconds: 100_000_000); waited += 1
        }
        return tab.webView
    }

    private func waitLoad(_ wv: WKWebView, timeout: Int) async {
        try? await Task.sleep(nanoseconds: 800_000_000)
        var waited = 0
        while (wv.isLoading || wv.url == nil) && waited < timeout * 5 {
            try? await Task.sleep(nanoseconds: 200_000_000); waited += 1
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
    }

    private func callJS(_ wv: WKWebView, _ js: String, _ args: [String: String] = [:]) async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            wv.callAsyncJavaScript(js, arguments: args, in: nil, in: .page) { result in
                switch result {
                case .success(let value):
                    continuation.resume(returning: (value as? String) ?? "\(value)")
                case .failure(let error):
                    continuation.resume(returning: "error:\(error.localizedDescription)")
                }
            }
        }
    }

    private func shot(_ name: String) async {
        let request = dir.appendingPathComponent("shot-request")
        try? Data(name.utf8).write(to: request, options: .atomic)
        var waited = 0
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
