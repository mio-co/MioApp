// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

// Mio: containers (Firefox Multi-Account Containers style) for the firefox-ios fork. Logic lives in MioKit
// (MioContainerManager / MioContainerState: same JSON + rules as the Mac app; MioContainerTabPolicy: which container a new
// web view goes into; MioContainerDataStores: one WKWebsiteDataStore(forIdentifier:) per container).
//
// - Default container = WKWebsiteDataStore.default(), the store every normal Firefox tab already used (existing logins and
//   the Cloudflare Access cookie Keychain backup stay as they are). Private tabs never get a container.
// - Tab → container is recorded by tabUUID in mio.containers.state, so a restored tab (relaunch) comes back in its container.
// - Containers need iOS 17 (WKWebsiteDataStore(forIdentifier:)); below that every entry point is hidden and
//   Settings → 容器 explains why.
//
// Hooks in upstream files (search "Mio:" + "MioContainerUI"):
//   Tab.createWebview / close, BrowserViewController (selected tab → address bar badge),
//   new-tab / tabs-button long press, web link context menu, tab tray peek menu, main menu,
//   TabCell / ExperimentTabCell / TopTabCell (color badge), Settings (Mio → 容器).

import Common
import Foundation
import MenuKit
@preconcurrency import MioKit
import SwiftUI
import UIKit
import WebKit

@MainActor
final class MioContainerUI {
    static let shared = MioContainerUI()

    /// WKWebsiteDataStore(forIdentifier:) — iOS 17+
    static var isSupported: Bool { MioContainerDataStores.isSupported }
    static let unsupportedNote = "容器需要 iOS 17 或更高版本（每个容器一份独立的网站数据存储是 iOS 17 才有的）。"

    let manager: MioContainerManager
    let dataStores: MioContainerDataStores
    /// Container picked in a menu for the tab that is being created right now (consumed by configuration(forTab:)).
    private var pending: String?
    private var observers: [NSObjectProtocol] = []
    private var badgeOwners: [WeakBVC] = []

    private struct WeakBVC { weak var bvc: BrowserViewController? }

    private init() {
        let kit = MioKitHost.shared.kit
        manager = kit.containers
        dataStores = MioContainerDataStores(manager: kit.containers, defaultStore: { WKWebsiteDataStore.default() })
        if Self.isSupported { manager.seedPresetsIfNeeded() }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .mioContainerWillRemove, object: nil, queue: .main) { [weak self] note in
            let id = note.userInfo?["containerId"] as? String
            let keys = note.userInfo?["tabKeys"] as? [String] ?? []
            MainActor.assumeIsolated { self?.containerWillRemove(id, tabKeys: keys) }
        })
        observers.append(center.addObserver(forName: .mioContainersDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshBadges() }
        })
    }

    // MARK: - Lookup

    var containers: [MioContainer] { manager.containers }
    var siteRulesEnabled: Bool { MioKitHost.shared.kit.registry.isEnabled(MioKitHost.shared.kit.containersModule.id) }

    /// The tab's container, nil for the default container, private tabs and iOS < 17.
    func container(forTabUUID key: String, isPrivate: Bool = false) -> MioContainer? {
        guard Self.isSupported, !isPrivate else { return nil }
        let id = manager.tab(key).containerId
        guard id != MioContainerCore.defaultId else { return nil }
        return manager.container(id)
    }

    func containerID(forTabUUID key: String) -> String { manager.tab(key).containerId }

    static func uiColor(_ name: String) -> UIColor {
        let hex = MioContainerCore.colorHex[name] ?? 0x8E8E93
        return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                       green: CGFloat((hex >> 8) & 0xFF) / 255,
                       blue: CGFloat(hex & 0xFF) / 255,
                       alpha: 1)
    }

    static func iconImage(_ c: MioContainer, pointSize: CGFloat = 15) -> UIImage? {
        let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        return UIImage(systemName: c.symbol, withConfiguration: config)?
            .withTintColor(uiColor(c.color), renderingMode: .alwaysOriginal)
    }

    static func displayName(_ c: MioContainer) -> String { c.isDefault ? "默认（无容器）" : c.name }

    // MARK: - Web view configuration (Tab.createWebview)

    /// Decides the tab's container and returns the configuration its web view must use.
    /// Popups keep WebKit's configuration (it already carries the parent's data store); container tabs get a copy of the
    /// shared Firefox configuration with the container's data store, so the shared one stays on .default().
    func configuration(forTab tab: Tab, base: WKWebViewConfiguration, isPopup: Bool) -> WKWebViewConfiguration {
        let picked = pending
        pending = nil
        guard Self.isSupported else { return base }
        let key = tab.tabUUID
        let record = manager.state.tabs[key]
        let parent = tab.parent.map { manager.tab($0.tabUUID) }
        guard let decided = MioContainerTabPolicy.decide(state: manager.state, record: record, pending: picked,
                                                         parent: parent, isPopup: isPopup, isPrivate: tab.isPrivate,
                                                         url: tab.url, siteRulesEnabled: siteRulesEnabled)
        else { return base }
        // (default + unlocked without a record = nothing to store)
        if record != decided && !(record == nil && decided == .unassigned) {
            manager.setTab(key, containerId: decided.containerId, locked: decided.locked)
        }
        if isPopup || decided.containerId == MioContainerCore.defaultId { return base }
        guard let copy = base.copy() as? WKWebViewConfiguration else { return base }
        copy.websiteDataStore = dataStores.dataStore(for: decided.containerId)
        return copy
    }

    /// Tab.close: forget the tab's container record.
    func tabDidClose(_ key: String) {
        guard manager.state.tabs[key] != nil else { return }
        manager.removeTab(key)
    }

    // MARK: - Opening tabs

    private func tabManager(for windowUUID: WindowUUID?) -> TabManager? {
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return nil }
        if let windowUUID, let manager = appDelegate.windowManager.tabManager(for: windowUUID) { return manager }
        let managers = appDelegate.windowManager.allWindowTabManagers()
        return managers.first(where: { $0.selectedTab != nil }) ?? managers.first
    }

    /// Adds a normal tab in `containerID` (nil request = the new tab page).
    @discardableResult
    func openTab(_ url: URL?, containerID: String, in tabManager: TabManager, afterTab: Tab?, select: Bool) -> Tab {
        pending = containerID
        let request = url.map { URLRequest(url: $0) }
        let current = tabManager.selectedTab
        let tab = tabManager.addTab(request, afterTab: afterTab, zombie: false, isPrivate: false)
        if pending != nil {
            // web view not created yet (zombie / deferred): record it so createWebview picks the container up
            pending = nil
            manager.setTab(tab.tabUUID, containerId: containerID, locked: false)
        }
        if select { tabManager.selectTab(tab, previous: current) }
        return tab
    }

    /// 「在容器中重新打开」: same URL in another container, the old tab is closed.
    func reopen(_ tab: Tab, in containerID: String, tabManager: TabManager) {
        let url = tab.url
        let reopened = openTab(url, containerID: containerID, in: tabManager, afterTab: tab, select: true)
        if reopened.tabUUID != tab.tabUUID { tabManager.removeTab(tab.tabUUID) }
    }

    private func newContainerTab(_ containerID: String, bvc: BrowserViewController) {
        guard containerID != MioContainerCore.defaultId else {
            bvc.openBlankNewTab(focusLocationField: bvc.newTabSettings == .blankPage, isPrivate: false)
            return
        }
        pending = containerID
        bvc.overlayManager.openNewTab(url: nil, newTabSettings: bvc.newTabSettings)
        bvc.openBlankNewTab(focusLocationField: bvc.newTabSettings == .blankPage, isPrivate: false)
        pending = nil
    }

    // MARK: - Picker

    /// Sheet with every container (default first). `exclude` = the tab's current container.
    func presentPicker(title: String, message: String? = nil, exclude: String? = nil, from presenter: UIViewController?,
                       onPick: @escaping @MainActor @Sendable (String) -> Void) {
        guard Self.isSupported, let presenter = presenter ?? MioKitHost.topViewController() else { return }
        let items = containers.filter { $0.id != exclude }
        let view = MioContainerPickerView(title: title, message: message, containers: items,
                                          tabCounts: tabCounts(),
                                          onPick: { [weak presenter] id in
                                              presenter?.dismiss(animated: true) { onPick(id) }
                                          },
                                          onManage: { [weak self, weak presenter] in
                                              presenter?.dismiss(animated: true) { self?.presentSettings() }
                                          },
                                          onCancel: { [weak presenter] in presenter?.dismiss(animated: true) })
        let host = UIHostingController(rootView: view)
        host.view.accessibilityIdentifier = "Mio.ContainerPicker"
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        presenter.present(host, animated: true)
    }

    private func tabCounts() -> [String: Int] {
        var out: [String: Int] = [:]
        for (_, t) in manager.state.tabs { out[t.containerId, default: 0] += 1 }
        return out
    }

    /// Settings → 容器 (also from the picker's 「管理容器」).
    func presentSettings() {
        guard let top = MioKitHost.topViewController() else { return }
        let controller = MioContainersSetting.makeController()
        let nav = UINavigationController(rootViewController: controller)
        controller.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak nav] _ in
            nav?.dismiss(animated: true)
        })
        top.present(nav, animated: true)
    }

    // MARK: - Entry points

    /// New-tab button / tabs button long press: 「新建容器标签…」
    func newTabLongPressActions(bvc: BrowserViewController) -> [PhotonRowActions] {
        guard Self.isSupported else { return [] }
        let action = SingleActionViewModel(title: "新建容器标签…",
                                           iconString: StandardImageIdentifiers.Large.plus,
                                           iconType: .Image) { [weak bvc] _ in
            guard bvc != nil else { return }
            // The action sheet dismisses itself; present once it is gone.
            Task { @MainActor [weak bvc] in
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard let bvc else { return }
                MioContainerUI.shared.presentPicker(title: "新建容器标签", message: "新标签的 Cookie、登录和缓存只属于所选容器。",
                                                    from: bvc.presentedViewController == nil ? bvc : nil) { [weak bvc] id in
                    guard let bvc else { return }
                    MioContainerUI.shared.newContainerTab(id, bvc: bvc)
                }
            }
        }
        return [action.items]
    }

    /// Web link long press: 「在容器中打开」 submenu, inserted after 「在新的隐私标签页中打开」.
    func linkMenu(adding actions: [UIAction], url: URL, currentTab: Tab, bvc: BrowserViewController) -> [UIMenuElement] {
        var out: [UIMenuElement] = actions
        guard Self.isSupported, !currentTab.isPrivate,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" || scheme == "mio"
        else { return out }
        let current = containerID(forTabUUID: currentTab.tabUUID)
        var children: [UIMenuElement] = []
        for c in containers {
            let title = Self.displayName(c) + (c.id == current ? "（当前）" : "")
            let id = c.id
            let action = UIAction(title: title, image: Self.iconImage(c)) { [weak bvc, weak currentTab] _ in
                guard let bvc, let currentTab else { return }
                let tab = MioContainerUI.shared.openTab(url, containerID: id, in: bvc.tabManager,
                                                        afterTab: currentTab, select: false)
                bvc.showToastBy(isPrivate: false, tab: tab)
            }
            children.append(action)
        }
        let menu = UIMenu(title: "在容器中打开", image: UIImage(systemName: "square.stack.3d.up"), children: children)
        out.insert(menu, at: min(2, out.count))
        return out
    }

    /// Tab tray long press (TabPeek): 「在容器中重新打开」 submenu.
    func tabMenu(adding actions: [UIAction], tabUUID: TabUUID, windowUUID: WindowUUID) -> [UIMenuElement] {
        var out: [UIMenuElement] = actions
        guard Self.isSupported, let tabManager = tabManager(for: windowUUID),
              let tab = tabManager.getTabForUUID(uuid: tabUUID), !tab.isPrivate
        else { return out }
        let current = containerID(forTabUUID: tabUUID)
        var children: [UIMenuElement] = []
        for c in containers where c.id != current {
            let id = c.id
            let action = UIAction(title: Self.displayName(c), image: Self.iconImage(c)) { [weak tab] _ in
                guard let tab, let tabManager = MioContainerUI.shared.tabManager(for: windowUUID) else { return }
                MioContainerUI.shared.reopen(tab, in: id, tabManager: tabManager)
            }
            children.append(action)
        }
        out.append(UIMenu(title: "在容器中重新打开", image: UIImage(systemName: "arrow.uturn.right.square"), children: children))
        return out
    }

    /// Main menu (page menu) row: 「在容器中重新打开…」
    func mainMenuElement(windowUUID: WindowUUID, tabUUID: TabUUID) -> MenuElement? {
        guard Self.isSupported, let tab = tabManager(for: windowUUID)?.getTabForUUID(uuid: tabUUID), !tab.isPrivate else { return nil }
        let current = manager.container(containerID(forTabUUID: tabUUID))
        let suffix = current.map { $0.isDefault ? "" : "（当前：\($0.name)）" } ?? ""
        return MenuElement(
            title: "在容器中重新打开…" + suffix,
            iconName: StandardImageIdentifiers.Large.tabTray,
            iconImage: UIImage(systemName: "square.stack.3d.up"),
            isEnabled: true,
            isActive: false,
            a11yLabel: "在容器中重新打开",
            a11yHint: "",
            a11yId: "MainMenu.Mio.ReopenInContainer",
            action: {
                MioContainerUI.shared.reopenFromMenu(windowUUID: windowUUID, tabUUID: tabUUID)
            }
        )
    }

    private func reopenFromMenu(windowUUID: WindowUUID, tabUUID: TabUUID) {
        // Close the main menu first
        if let top = MioKitHost.topViewController(), top.presentingViewController != nil {
            top.dismiss(animated: true) { [weak self] in self?.presentReopenPicker(windowUUID: windowUUID, tabUUID: tabUUID) }
        } else {
            presentReopenPicker(windowUUID: windowUUID, tabUUID: tabUUID)
        }
    }

    private func presentReopenPicker(windowUUID: WindowUUID, tabUUID: TabUUID) {
        guard let tabManager = tabManager(for: windowUUID), let tab = tabManager.getTabForUUID(uuid: tabUUID) else { return }
        presentPicker(title: "在容器中重新打开", message: tab.url?.host, exclude: containerID(forTabUUID: tabUUID),
                      from: nil) { id in
            guard let tabManager = MioContainerUI.shared.tabManager(for: windowUUID),
                  let tab = tabManager.getTabForUUID(uuid: tabUUID) else { return }
            MioContainerUI.shared.reopen(tab, in: id, tabManager: tabManager)
        }
    }

    // MARK: - Removal / data

    private func containerWillRemove(_ id: String?, tabKeys: [String]) {
        guard let id else { return }
        let keys = Set(tabKeys)
        if let appDelegate = UIApplication.shared.delegate as? AppDelegate {
            for tabManager in appDelegate.windowManager.allWindowTabManagers() {
                for tab in tabManager.tabs where keys.contains(tab.tabUUID) {
                    tabManager.removeTab(tab.tabUUID)
                }
            }
        }
        let stores = dataStores
        Task { @MainActor in
            // Tab.close is asynchronous: give the web views a moment to go away, MioKit retries if still in use
            try? await Task.sleep(nanoseconds: 800_000_000)
            _ = await stores.purge(id)
        }
        refreshBadges()
    }

    /// Clears the container's cookies / logins / cache / storage and reloads its open tabs.
    func clearData(_ id: String) async {
        await dataStores.clearData(id)
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }
        for tabManager in appDelegate.windowManager.allWindowTabManagers() {
            for tab in tabManager.tabs where !tab.isPrivate && containerID(forTabUUID: tab.tabUUID) == id {
                tab.webView?.reload()
            }
        }
    }

    func openTabCount(_ id: String) -> Int { manager.state.tabs(in: id).count }

    // MARK: - Badges

    /// BrowserViewController: selected tab changed → container color line + name next to the address bar.
    func updateAddressBarBadge(bvc: BrowserViewController, tab: Tab?) {
        if !badgeOwners.contains(where: { $0.bvc === bvc }) {
            badgeOwners.removeAll { $0.bvc == nil }
            badgeOwners.append(WeakBVC(bvc: bvc))
        }
        let host = bvc.addressToolbarContainer
        let c = tab.flatMap { container(forTabUUID: $0.tabUUID, isPrivate: $0.isPrivate) }
        let badge = host.subviews.compactMap { $0 as? MioContainerAddressBadge }.first
        guard let c else { badge?.isHidden = true; return }
        let view = badge ?? MioContainerAddressBadge(in: host)
        view.configure(c, contentAbove: bvc.isBottomSearchBar)
        host.bringSubviewToFront(view)
    }

    private func refreshBadges() {
        badgeOwners.removeAll { $0.bvc == nil }
        for owner in badgeOwners {
            guard let bvc = owner.bvc else { continue }
            updateAddressBarBadge(bvc: bvc, tab: bvc.tabManager.selectedTab)
        }
    }

    enum CellStyle { case trayCell, topTab }

    /// Tab tray cell / iPad top tab: color line (+ icon and name in the tray).
    static func decorate(_ host: UIView, tabUUID: TabUUID, isPrivate: Bool, style: CellStyle) {
        let c = shared.container(forTabUUID: tabUUID, isPrivate: isPrivate)
        let badge = host.subviews.compactMap { $0 as? MioContainerTabBadge }.first
        guard let c else { badge?.isHidden = true; return }
        let view = badge ?? MioContainerTabBadge(in: host, style: style)
        view.configure(c)
        host.bringSubviewToFront(view)
    }
}

// MARK: - Badge views

/// Address bar: a line in the container color on the edge that faces the web page, plus a small icon + name pill.
final class MioContainerAddressBadge: UIView {
    private let line = UIView()
    private let pill = UIView()
    private let icon = UIImageView()
    private let label = UILabel()
    private var edgeConstraints: [NSLayoutConstraint] = []

    init(in host: UIView) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isUserInteractionEnabled = false
        accessibilityIdentifier = "Mio.ContainerAddressBadge"
        host.addSubview(self)
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: host.leadingAnchor),
            trailingAnchor.constraint(equalTo: host.trailingAnchor),
            topAnchor.constraint(equalTo: host.topAnchor),
            bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        for v in [line, pill] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        pill.layer.cornerRadius = 9
        pill.layer.masksToBounds = true
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.contentMode = .scaleAspectFit
        icon.tintColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        pill.addSubview(icon)
        pill.addSubview(label)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.heightAnchor.constraint(equalToConstant: 3),
            pill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            pill.heightAnchor.constraint(equalToConstant: 18),
            icon.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 7),
            icon.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 11),
            icon.heightAnchor.constraint(equalToConstant: 11),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// contentAbove: address bar at the bottom (web page above it) → line on top, pill above the bar.
    func configure(_ c: MioContainer, contentAbove: Bool) {
        isHidden = false
        let color = MioContainerUI.uiColor(c.color)
        line.backgroundColor = color
        pill.backgroundColor = color
        icon.image = UIImage(systemName: c.symbol)?.withRenderingMode(.alwaysTemplate)
        label.text = c.name
        accessibilityLabel = "容器：\(c.name)"
        NSLayoutConstraint.deactivate(edgeConstraints)
        if contentAbove {
            edgeConstraints = [
                line.topAnchor.constraint(equalTo: topAnchor),
                pill.bottomAnchor.constraint(equalTo: topAnchor, constant: -4),
            ]
        } else {
            edgeConstraints = [
                line.bottomAnchor.constraint(equalTo: bottomAnchor),
                pill.topAnchor.constraint(equalTo: bottomAnchor, constant: 4),
            ]
        }
        NSLayoutConstraint.activate(edgeConstraints)
    }
}

/// Tab tray cell (line on top + icon/name pill at the bottom) or iPad top tab (line at the bottom).
final class MioContainerTabBadge: UIView {
    private let line = UIView()
    private let pill = UIView()
    private let icon = UIImageView()
    private let label = UILabel()
    private let style: MioContainerUI.CellStyle

    init(in host: UIView, style: MioContainerUI.CellStyle) {
        self.style = style
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isUserInteractionEnabled = false
        accessibilityIdentifier = "Mio.ContainerTabBadge"
        host.addSubview(self)
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: host.leadingAnchor),
            trailingAnchor.constraint(equalTo: host.trailingAnchor),
            topAnchor.constraint(equalTo: host.topAnchor),
            bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        switch style {
        case .topTab:
            line.layer.cornerRadius = 1.5
            NSLayoutConstraint.activate([
                line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                line.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
                line.heightAnchor.constraint(equalToConstant: 3),
            ])
        case .trayCell:
            pill.translatesAutoresizingMaskIntoConstraints = false
            pill.layer.cornerRadius = 10
            pill.layer.masksToBounds = true
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.contentMode = .scaleAspectFit
            icon.tintColor = .white
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .white
            addSubview(pill)
            pill.addSubview(icon)
            pill.addSubview(label)
            NSLayoutConstraint.activate([
                line.leadingAnchor.constraint(equalTo: leadingAnchor),
                line.trailingAnchor.constraint(equalTo: trailingAnchor),
                line.topAnchor.constraint(equalTo: topAnchor),
                line.heightAnchor.constraint(equalToConstant: 4),
                pill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                pill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
                pill.heightAnchor.constraint(equalToConstant: 20),
                pill.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
                icon.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 7),
                icon.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 11),
                icon.heightAnchor.constraint(equalToConstant: 11),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ c: MioContainer) {
        isHidden = false
        let color = MioContainerUI.uiColor(c.color)
        line.backgroundColor = color
        pill.backgroundColor = color
        icon.image = UIImage(systemName: c.symbol)?.withRenderingMode(.alwaysTemplate)
        label.text = c.name
        accessibilityLabel = "容器：\(c.name)"
    }
}

// MARK: - Picker view

struct MioContainerPickerView: View {
    let title: String
    let message: String?
    let containers: [MioContainer]
    let tabCounts: [String: Int]
    let onPick: @MainActor @Sendable (String) -> Void
    let onManage: @MainActor @Sendable () -> Void
    let onCancel: @MainActor @Sendable () -> Void

    var body: some View {
        NavigationView {
            List {
                Section {
                    ForEach(containers, id: \.id) { c in
                        Button { onPick(c.id) } label: {
                            HStack(spacing: 12) {
                                MioContainerIconView(container: c, size: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(MioContainerUI.displayName(c)).foregroundColor(.primary)
                                    if let n = tabCounts[c.id], n > 0, !c.isDefault {
                                        Text("\(n) 个标签").font(.footnote).foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                            }
                        }
                        .accessibilityIdentifier("Mio.ContainerPicker.\(c.isDefault ? "default" : c.name)")
                    }
                } footer: {
                    Text(message ?? "")
                }
                Section {
                    Button { onManage() } label: { Label("管理容器", systemImage: "gearshape") }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { onCancel() } }
            }
        }
        .navigationViewStyle(.stack)
    }
}

struct MioContainerIconView: View {
    let container: MioContainer
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Color(uiColor: MioContainerUI.uiColor(container.color)))
            Image(systemName: container.symbol)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundColor(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
