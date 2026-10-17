// MioContainerUX.swift — 容器的易用入口（照 Safari 描述文件 / 标签组的用法；iPhone 新布局 + iPad / Mac 顶部工具栏共用）
//
// - 新建标签菜单（长按「+」/ 标签按钮）：新建标签页 / 新建无痕标签页 / 在容器中新建 ▸ / 新建容器…
// - 页面菜单：在容器中打开此页、此网站始终用某容器打开（站点规则，容器管理里可查看 / 删除）
// - 标签概览底部容器切换器（MioTabOverviewViewController）
// - 首次创建容器后的一次性引导
// - 无痕标签：容器 id "private" → 不落盘的 WKWebsiteDataStore.nonPersistent()（MioContainerStore.dataStore），会话不保存

import UIKit
import WebKit

enum MioContainerUX {
    static let privateId = MioTabStore.privateContainer
    private static let tipKey = "mio.containers.tipShown"
    private static var tipObserver: NSObjectProtocol?

    static func dotImage(_ color: UIColor, size: CGFloat = 12) -> UIImage? {
        UIImage(systemName: "circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: size))?.withTintColor(color, renderingMode: .alwaysOriginal)
    }

    /// 标签上显示的容器（默认容器 = nil；无痕 = 灰色「无痕」）
    static func badge(for containerID: String) -> MioTabContainers.Info? {
        if containerID == privateId { return .init(id: privateId, name: "无痕", color: .systemGray) }
        guard containerID != MioTabStore.defaultContainer else { return nil }
        return MioTabContainers.info(containerID)
    }

    // MARK: 新建标签菜单

    static func newTabMenuElements(_ tabs: MioTabsViewController, from presenter: UIViewController) -> [UIMenuElement] {
        var items: [UIMenuElement] = [
            UIAction(title: "新建标签页", image: UIImage(systemName: "plus.square.on.square")) { [weak tabs] _ in tabs?.mioNewTab(nil) },
            UIAction(title: "新建无痕标签页", image: UIImage(systemName: "hand.raised.square")) { [weak tabs] _ in tabs?.openPrivateTab() },
        ]
        let containers = MioTabContainers.all
        if MioContainerStore.isSupported {
            var sub: [UIMenuElement] = containers.map { c in
                UIAction(title: c.name, image: dotImage(c.color)) { [weak tabs] _ in tabs?.newTab(containerID: c.id) }
            }
            sub.append(UIAction(title: "新建容器…", image: UIImage(systemName: "plus.circle")) { [weak tabs, weak presenter] _ in
                guard let presenter = presenter else { return }
                createContainer(from: presenter) { id in tabs?.newTab(containerID: id) }
            })
            items.append(UIMenu(title: "在容器中新建", image: UIImage(systemName: "person.2.square.stack"), children: sub))
        }
        return items
    }

    // MARK: 新建容器 / 选容器

    static func createContainer(from vc: UIViewController, then: @escaping (String) -> Void) {
        guard MioContainerStore.isSupported else {
            let a = UIAlertController(title: "容器不可用", message: "容器需要 iOS 17 / macOS 14 或更新的系统。", preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "好", style: .default))
            vc.present(a, animated: true)
            return
        }
        let a = UIAlertController(title: "新建容器", message: "容器里的登录状态、Cookie 和网站数据与其他容器互不相通", preferredStyle: .alert)
        a.addTextField { $0.placeholder = "名称，例如 工作、小号" }
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        a.addAction(UIAlertAction(title: "创建", style: .default) { _ in
            let name = a.textFields?.first?.text ?? ""
            do {
                let c = try MioContainerStore.shared.create(name: name.isEmpty ? "容器 \(MioContainerStore.shared.containers.count)" : name)
                then(c.id)
            } catch {
                let e = UIAlertController(title: "无法创建容器", message: "\(error)", preferredStyle: .alert)
                e.addAction(UIAlertAction(title: "好", style: .default))
                vc.present(e, animated: true)
            }
        })
        vc.present(a, animated: true)
    }

    /// 选一个容器（includeNone = 加「不指定」；可新建）
    static func pickContainer(from vc: UIViewController, title: String, message: String? = nil, current: String? = nil, includeNone: Bool = false,
                              sourceView: UIView?, then: @escaping (String?) -> Void) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .actionSheet)
        if includeNone {
            a.addAction(UIAlertAction(title: "不指定（跟随打开方式）" + (current == nil ? " ✓" : ""), style: .default) { _ in then(nil) })
        }
        for c in MioTabContainers.all {
            let act = UIAlertAction(title: c.name + (c.id == current ? " ✓" : ""), style: .default) { _ in then(c.id) }
            a.addAction(act)
        }
        if MioContainerStore.isSupported {
            a.addAction(UIAlertAction(title: "新建容器…", style: .default) { _ in createContainer(from: vc) { then($0) } })
        }
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let pop = a.popoverPresentationController {
            pop.sourceView = sourceView ?? vc.view
            pop.sourceRect = sourceView?.bounds ?? CGRect(x: vc.view.bounds.midX, y: vc.view.bounds.maxY - 60, width: 1, height: 1)
        }
        vc.present(a, animated: true)
    }

    /// 页面菜单「在容器中打开此页」
    static func openPageInContainer(_ b: MioBrowserViewController, sourceView: UIView?) {
        guard let url = b.webView?.url, MioTabStore.isHTTP(url.absoluteString), let tabs = b.tabsController else { return }
        pickContainer(from: b, title: "在容器中打开此页", message: url.host, current: b.containerID, sourceView: sourceView) { id in
            guard let id = id else { return }
            tabs.openTab(url.absoluteString, activate: true, containerID: id)
        }
    }

    /// 页面菜单「此网站始终用某容器打开」（站点规则）
    static func setSiteContainer(_ b: MioBrowserViewController, sourceView: UIView?) {
        guard let host = b.webView?.url?.host else { return }
        let store = MioContainerStore.shared
        let current = store.state.siteRules.first { host == $0.host || host.hasSuffix("." + $0.host) }
        pickContainer(from: b, title: "此网站始终用这个容器打开", message: "\(current?.host ?? host)（含子域名）。可在 设置 › 容器管理 里查看或删除。",
                      current: current?.containerId, includeNone: true, sourceView: sourceView) { id in
            if let id = id {
                _ = try? store.setSiteRule(host, containerId: id)
            } else if let r = current {
                store.removeSiteRule(r.host)
            }
        }
    }

    // MARK: 打开容器（容器管理页）

    static func openContainer(_ id: String, from vc: UIViewController) {
        let open = { MioTabsViewController.open(URL(string: MioTabsSettings.newTabURL) ?? URL(string: "https://mio.300031.xyz/mio/nav")!, from: nil, containerID: id) }
        // 设置页盖在浏览器 / 主界面上：先收起设置
        if let presenting = (vc.navigationController ?? vc).presentingViewController {
            presenting.dismiss(animated: true) { open() }
        } else {
            open()
        }
    }

    // MARK: 一次性引导

    /// 监听容器变化：第一次出现非默认容器时提示三种用法（只提示一次）
    static func installTip() {
        guard tipObserver == nil else { return }
        tipObserver = NotificationCenter.default.addObserver(forName: .mioContainersDidChange, object: nil, queue: .main) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { maybeShowTip() }
        }
    }

    static func maybeShowTip() {
        guard !UserDefaults.standard.bool(forKey: tipKey), MioContainerStore.shared.containers.count > 1,
              let top = MioBrowserViewController.topPresenter(nil), !(top is UIAlertController) else { return }
        UserDefaults.standard.set(true, forKey: tipKey)
        let a = UIAlertController(title: "容器已创建，这样使用", message: """
        ① 长按「+」或标签按钮 → 在容器中新建，或新建无痕标签页
        ② 页面菜单 → 在容器中打开此页 / 此网站始终用某容器打开
        ③ 标签概览底部切换容器，只看该容器的标签，「+」直接在该容器里新建
        容器标签在地址栏左侧显示色点和名称。
        """, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "知道了", style: .default))
        top.present(a, animated: true)
    }
}

extension MioTabsViewController {
    /// 新建无痕标签页（不落盘，关闭 / 退出 App 即清除；不进会话和最近关闭）
    func openPrivateTab(_ url: String? = nil) {
        let target = url.flatMap { MioTabStore.isHTTP($0) ? $0 : nil } ?? MioTabsSettings.newTabURL
        guard let tab = store.add(target, activate: true, containerID: MioTabStore.privateContainer, locked: true) else {
            toast("最多同时打开 \(store.maxTabs) 个标签")
            return
        }
        _ = tab
        showActive()
        toast("无痕标签页：关闭后不留记录")
    }
}
