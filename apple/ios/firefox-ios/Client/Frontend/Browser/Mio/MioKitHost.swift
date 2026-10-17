// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

// Mio: glue between the firefox-ios tab machinery and the shared MioKit package (apple/MioKit, README "接入 A").
//
// - one MioKitContainer for the app (settings in UserDefaults.standard, same keys as v0.3.x)
// - mio:// scheme handler (registered in TabConfigurationProvider)
// - per tab web view: MioWebViewModules (module scripts, message channels, MioCore bridge, ad-block rule lists)
// - MioCore native bridge host (MioCoreBridgeDelegate); MioKit only answers the MioCore origin and mio:// pages
//
// Hooks in upstream files (search "Mio:"): Tab.createWebview / close / nightMode / noImageMode,
// BrowserViewController decidePolicyFor (main-frame navigation), ContentBlocker.removeTrackingProtection.

import Foundation
@preconcurrency import MioKit
import UIKit
import WebKit

@MainActor
final class MioKitHost {
    static let shared = MioKitHost()

    let kit: MioKitContainer
    let blocker: MioContentBlocker
    private lazy var saveRunner = MioSaveRunner(kit: kit, dataStore: .default())
    /// Computed once on the main thread; the bridge may ask for it from any thread.
    nonisolated(unsafe) private let deviceInfo: MioDeviceInfo

    private final class Entry {
        let mods: MioWebViewModules
        weak var webView: WKWebView?
        init(mods: MioWebViewModules, webView: WKWebView) { self.mods = mods; self.webView = webView }
    }
    private var entries: [ObjectIdentifier: Entry] = [:]
    /// Main-frame navigations per web view, recorded only for the CI smoke (MioSmoke).
    private var mainFrameNavigations: [ObjectIdentifier: [String]] = [:]
    private var observers: [NSObjectProtocol] = []

    private init() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.4.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        kit = MioKitContainer(appVersion: version)
        blocker = MioContentBlocker(manager: kit.filters)
        deviceInfo = MioDeviceInfo(
            platform: UIDevice.current.userInterfaceIdiom == .pad ? "ipados" : "ios",
            model: MioKitHost.hardwareModel(),
            osVersion: UIDevice.current.systemVersion,
            appVersion: version,
            appBuild: build,
            locale: Locale.preferredLanguages.first ?? Locale.current.identifier
        )
        kit.bridge.delegate = self
        let blocker = self.blocker
        kit.adblock.recompile = { await blocker.reload() }

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .mioSettingsDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reinstallAll() }
        })
        observers.append(center.addObserver(forName: .mioContentRulesDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reapplyAllContentRules() }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.kit.translate.cache.flush() }
        })
        Task { await blocker.prepare() }
    }

    // MARK: - Web views

    /// Scheme handler for mio:// (mio://home → MioCore home page, mio://offline, mio://about).
    func makeSchemeHandler() -> WKURLSchemeHandler {
        MioSchemeHandler(kit: kit)
    }

    /// Called from Tab.createWebview after Firefox injected its own user scripts.
    func attach(webView: WKWebView) {
        let key = ObjectIdentifier(webView)
        guard entries[key] == nil else { return hostScriptsDidChange(webView: webView) }
        let mods = MioWebViewModules(kit: kit, controller: webView.configuration.userContentController, blocker: blocker)
        entries[key] = Entry(mods: mods, webView: webView)
        mods.webView = webView
        hostScriptsDidChange(webView: webView)
        mods.applyContentRules(topURL: webView.url)
        pruneEntries()
        MioSmoke.startIfRequested()
    }

    /// MioKit modules of a web view (CI smoke).
    func modules(for webView: WKWebView) -> MioWebViewModules? {
        entries[ObjectIdentifier(webView)]?.mods
    }

    /// Main-frame navigations seen for a web view (only recorded when the CI smoke runs).
    func mainFrameLog(for webView: WKWebView) -> [String] {
        mainFrameNavigations[ObjectIdentifier(webView)] ?? []
    }

    /// Firefox re-injected its scripts (UserScriptManager removes every user script first):
    /// keep them as MioKit host scripts and put the Mio module scripts back.
    func hostScriptsDidChange(webView: WKWebView?) {
        guard let webView, let entry = entries[ObjectIdentifier(webView)] else { return }
        // Only Firefox's scripts are in the controller right after UserScriptManager ran.
        entry.mods.hostScripts = webView.configuration.userContentController.userScripts
        entry.mods.install()
    }

    /// Firefox's tracking protection removed every content rule list: add Mio's back.
    func contentRulesWereCleared(webView: WKWebView?) {
        guard let webView, let entry = entries[ObjectIdentifier(webView)] else { return }
        let controller = webView.configuration.userContentController
        for id in entry.mods.appliedRuleListIdentifiers {
            if let list = blocker.ruleLists[id] { controller.add(list) }
        }
    }

    /// Main-frame navigation is about to start (allow-list → attach / detach rule lists, GM value changes).
    func willNavigateMainFrame(webView: WKWebView, to url: URL?) {
        if MioSmoke.isRequested, let url {
            mainFrameNavigations[ObjectIdentifier(webView), default: []].append(url.absoluteString)
        }
        entries[ObjectIdentifier(webView)]?.mods.willNavigateMainFrame(to: url)
    }

    func detach(webView: WKWebView?) {
        guard let webView, let entry = entries.removeValue(forKey: ObjectIdentifier(webView)) else { return }
        entry.mods.detach()
    }

    private func reinstallAll() {
        pruneEntries()
        for entry in entries.values { entry.mods.install() }
    }

    private func reapplyAllContentRules() {
        pruneEntries()
        for entry in entries.values { entry.mods.applyContentRules(topURL: entry.webView?.url) }
    }

    private func pruneEntries() {
        entries = entries.filter { $0.value.webView != nil }
    }

    // MARK: - Bridge (main actor side)

    private func openTab(_ url: URL, background: Bool) {
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }
        let managers = appDelegate.windowManager.allWindowTabManagers()
        guard let tabManager = managers.first(where: { $0.selectedTab != nil }) ?? managers.first else { return }
        let current = tabManager.selectedTab
        let tab = tabManager.addTab(URLRequest(url: url), afterTab: current, zombie: false,
                                    isPrivate: current?.isPrivate ?? false)
        if !background { tabManager.selectTab(tab, previous: current) }
    }

    private func save(kind: String, payloadJSON: String) async -> String {
        let result = await saveRunner.save(kind: kind, payloadJSON: payloadJSON)
        let data = (try? JSONSerialization.data(withJSONObject: result)) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func askPermission(_ permission: String, origin: String) async -> Bool {
        guard let presenter = Self.topViewController() else { return false }
        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(
                title: "允许 \(origin) 使用「\(Self.permissionTitle(permission))」？",
                message: "只有 MioCore 页面能请求本机能力。可以在设置里随时撤销。",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "不允许", style: .cancel) { _ in continuation.resume(returning: false) })
            alert.addAction(UIAlertAction(title: "允许", style: .default) { _ in continuation.resume(returning: true) })
            presenter.present(alert, animated: true)
        }
    }

    private static func permissionTitle(_ raw: String) -> String {
        switch raw {
        case "photos": return "相册"
        case "deviceControl": return "控制本机"
        case "files": return "文件"
        default: return raw
        }
    }

    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    private static func hardwareModel() -> String {
        var info = utsname()
        uname(&info)
        let model = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return model.isEmpty ? UIDevice.current.model : model
    }
}

// MARK: - MioCoreBridgeDelegate (MioKit calls these from any thread)

extension MioKitHost: MioCoreBridgeDelegate {
    nonisolated func bridgeDeviceInfo() -> MioDeviceInfo {
        deviceInfo
    }

    nonisolated func bridgeOpenTab(_ url: URL, background: Bool) -> Bool {
        Task { @MainActor in self.openTab(url, background: background) }
        return true
    }

    nonisolated func bridgeSaveToMio(kind: String, payload: [String: Any]) async -> [String: Any] {
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        let resultJSON = await save(kind: kind, payloadJSON: json)
        let object = try? JSONSerialization.jsonObject(with: Data(resultJSON.utf8))
        return object as? [String: Any] ?? ["ok": false, "code": "server", "message": "没有结果"]
    }

    nonisolated func bridgeRequestPermission(_ permission: MioBridgePermission, origin: MioFrameOrigin) async -> Bool {
        await askPermission(permission.rawValue, origin: origin.description)
    }
}
