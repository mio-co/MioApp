// MioMacBrowserPanels.swift — 工具栏弹出面板和标签右键菜单（Firefox 桌面版的内容，Mio 化）：
//   - ≡ 应用菜单：新建标签页 / 窗口、书签 ›、历史 ›、扩展和主题、打印、查找、缩放行（− 100% + ⤢）、设置、更多工具 ›、帮助 ›、退出
//     子菜单在面板内左右滑动（Firefox 的 subview 切换）
//   - 🧩 Mio 扩展：「此页面」的模块动作（翻译、阅读、强制深色、保存到 Mio……）+ 每个模块一个开关（MioKit 的 MioExtensionSettingsModel），
//     底部容器 / 用户脚本 / 管理 Mio 扩展
//   - 站点信息（锁）/ 跟踪保护（盾牌）面板
//   - ⌄ 列出所有标签页
//   - 标签右键菜单

import AppKit
import WebKit
import MioKit

extension MioMacBrowserWindowController {
    static let panelWidth: CGFloat = 320

    // MARK: - 应用菜单

    func showAppMenu() {
        navBar.menuButton.isActive = true
        let w = Self.panelWidth
        var stack: MioMacPanelStack!
        let root = MioMacMenuRow.column([
            MioMacMenuRow(symbol: "person.crop.circle", title: "登录 MioCore", detail: "在 Mio 主页登录") { [weak self] in self?.dismissPanel(); self?.newTab(url: MioMacHome.address) },
            nil,
            MioMacMenuRow(symbol: "plus.square.on.square", title: "新建标签页", shortcut: "⌘T") { [weak self] in self?.dismissPanel(); self?.newTabAction(nil) },
            MioMacMenuRow(symbol: "macwindow.badge.plus", title: "新建窗口", shortcut: "⌘N") { [weak self] in self?.dismissPanel(); self?.onNewWindow?() },
            disabled(MioMacMenuRow(symbol: "eyeglasses", title: "新建隐私窗口", detail: "即将推出")),
            nil,
            MioMacMenuRow(symbol: "star", title: "书签", submenu: true) { [weak self] in
                guard let self else { return }
                stack.push(self.bookmarksSubview(width: w, back: { stack.pop() }))
            },
            MioMacMenuRow(symbol: "clock.arrow.circlepath", title: "历史", submenu: true) { [weak self] in
                guard let self else { return }
                stack.push(self.historySubview(width: w, back: { stack.pop() }))
            },
            disabled(MioMacMenuRow(symbol: "arrow.down.circle", title: "下载", detail: "即将推出")),
            MioMacMenuRow(symbol: "key", title: "密码") { [weak self] in
                self?.dismissPanel()
                if let u = URL(string: "x-apple.systempreferences:com.apple.Passwords-Settings.extension") { NSWorkspace.shared.open(u) }
            },
            MioMacMenuRow(symbol: "puzzlepiece.extension", title: "扩展和主题", shortcut: "⇧⌘A") { [weak self] in self?.dismissPanel(); self?.onOpenSettings?(.extensions) },
            nil,
            MioMacMenuRow(symbol: "printer", title: "打印…", shortcut: "⌘P") { [weak self] in self?.dismissPanel(); self?.printPage(nil) },
            MioMacMenuRow(symbol: "magnifyingglass", title: "在页面中查找…", shortcut: "⌘F") { [weak self] in self?.dismissPanel(); self?.showFindBar(nil) },
            translateRow(),
            zoomRow(width: w),
            nil,
            MioMacMenuRow(symbol: "gearshape", title: "设置", shortcut: "⌘,") { [weak self] in self?.dismissPanel(); self?.onOpenSettings?(.general) },
            MioMacMenuRow(symbol: "wrench.and.screwdriver", title: "更多工具", submenu: true) { [weak self] in
                guard let self else { return }
                stack.push(self.moreToolsSubview(width: w, back: { stack.pop() }))
            },
            MioMacMenuRow(symbol: "questionmark.circle", title: "帮助", submenu: true) { [weak self] in
                guard let self else { return }
                stack.push(self.helpSubview(width: w, back: { stack.pop() }))
            },
            nil,
            MioMacMenuRow(symbol: "power", title: "退出", shortcut: "⌘Q") { NSApp.terminate(nil) },
        ], width: w)
        stack = MioMacPanelStack(root: root, width: w)
        stack.setAccessibilityIdentifier("mio.appmenu")
        present(stack, from: navBar.menuButton) { [weak self] in self?.navBar.menuButton.isActive = false }
    }

    /// 「翻译页面」：Mio 扩展的翻译模块（关掉或当前页不能翻译时变灰）
    private func translateRow() -> MioMacMenuRow {
        let item = pageMenuItems.first { $0.moduleID == host.kit.translate.id && $0.itemID == "translate" }
        let r = MioMacMenuRow(symbol: "character.bubble", title: "翻译页面…", detail: item == nil ? "Mio 扩展 · 翻译" : nil) { [weak self] in
            self?.dismissPanel()
            if let item { self?.runModuleItem(item) }
        }
        r.isEnabled = item != nil
        return r
    }

    private func disabled(_ r: MioMacMenuRow) -> MioMacMenuRow {
        r.isEnabled = false
        return r
    }

    private func zoomRow(width: CGFloat) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView(image: MioTheme.symbol("plus.magnifyingglass", 14) ?? NSImage())
        icon.contentTintColor = MioTheme.text
        let label = NSTextField(labelWithString: "缩放")
        label.font = .systemFont(ofSize: 13)
        label.textColor = MioTheme.text
        let minus = MioMacToolbarButton(symbol: "minus", size: 12, label: "缩小 (⌘-)", weight: .semibold)
        let plus = MioMacToolbarButton(symbol: "plus", size: 12, label: "放大 (⌘+)", weight: .semibold)
        let reset = MioMacToolbarButton(symbol: "circle", size: 1, label: "重置缩放 (⌘0)")
        let full = MioMacToolbarButton(symbol: "arrow.up.left.and.arrow.down.right", size: 12, label: "全屏 (⌃⌘F)")
        let z = activeWebView.map { Double($0.pageZoom) } ?? defaultZoom
        reset.setTitle(MioZoomCore.label(z))
        reset.titleLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        minus.onClick = { [weak self] in self?.zoomOut(nil); reset.setTitle(MioZoomCore.label(Double(self?.activeWebView?.pageZoom ?? 1))) }
        plus.onClick = { [weak self] in self?.zoomIn(nil); reset.setTitle(MioZoomCore.label(Double(self?.activeWebView?.pageZoom ?? 1))) }
        reset.onClick = { [weak self] in self?.zoomReset(nil); reset.setTitle(MioZoomCore.label(Double(self?.activeWebView?.pageZoom ?? 1))) }
        full.onClick = { [weak self] in self?.dismissPanel(); self?.window?.toggleFullScreen(nil) }
        for b in [minus, reset, plus, full] {
            b.layer?.borderWidth = 0
            b.translatesAutoresizingMaskIntoConstraints = false
        }
        for x in [icon, label, minus, reset, plus, full] as [NSView] { x.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(x) }
        var cons: [NSLayoutConstraint] = [
            v.heightAnchor.constraint(equalToConstant: 36),
            icon.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            full.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -6),
            plus.trailingAnchor.constraint(equalTo: full.leadingAnchor, constant: -10),
            reset.trailingAnchor.constraint(equalTo: plus.leadingAnchor, constant: -2),
            minus.trailingAnchor.constraint(equalTo: reset.leadingAnchor, constant: -2),
            reset.widthAnchor.constraint(equalToConstant: 52),
        ]
        for b in [minus, reset, plus, full] {
            cons.append(b.centerYAnchor.constraint(equalTo: v.centerYAnchor))
            cons.append(b.heightAnchor.constraint(equalToConstant: 28))
        }
        for b in [minus, plus, full] { cons.append(b.widthAnchor.constraint(equalToConstant: 28)) }
        NSLayoutConstraint.activate(cons)
        return v
    }

    private func bookmarksSubview(width: CGFloat, back: @escaping () -> Void) -> NSView {
        let data = MioMacBrowserData.shared
        let starred = data.bookmarks.contains(activeWebView?.url?.absoluteString)
        var rows: [NSView?] = [
            MioMacMenuRow(symbol: starred ? "star.fill" : "star", title: starred ? "编辑此书签" : "为当前标签页添加书签", shortcut: "⌘D") { [weak self] in
                self?.dismissPanel(); self?.toggleBookmark(nil)
            },
            nil,
        ]
        if data.bookmarks.items.isEmpty { rows.append(MioMacMenuRow.note("还没有书签。点地址栏右侧的 ☆ 添加。")) }
        for b in data.bookmarks.items.prefix(15) {
            rows.append(MioMacMenuRow(symbol: "globe", title: b.title, detail: MioTabStore.displayHost(b.url)) { [weak self] in
                self?.dismissPanel(); self?.navigate(self?.activeWebView, to: b.url)
            })
        }
        return MioMacMenuRow.column(rows, width: width, header: "书签", onBack: back)
    }

    private func historySubview(width: CGFloat, back: @escaping () -> Void) -> NSView {
        var rows: [NSView?] = [
            MioMacMenuRow(symbol: "arrow.uturn.backward", title: "恢复关闭的标签页", shortcut: "⇧⌘T") { [weak self] in self?.dismissPanel(); self?.reopenClosedTab() },
            MioMacMenuRow(symbol: "trash", title: "清除最近的历史记录…") { [weak self] in
                self?.dismissPanel()
                let a = NSAlert()
                a.messageText = "清除全部历史记录？"
                a.informativeText = "只清除 Mio 记录的浏览历史（地址栏建议用），不影响 Cookie 和登录。"
                a.addButton(withTitle: "清除")
                a.addButton(withTitle: "取消")
                if a.runModal() == .alertFirstButtonReturn { MioMacBrowserData.shared.clearHistory() }
            },
            nil,
        ]
        let closed = store.closed.suffix(5).reversed()
        if !closed.isEmpty {
            rows.append(MioMacMenuRow.note("最近关闭的标签页"))
            for c in closed {
                rows.append(MioMacMenuRow(symbol: "xmark.square", title: c.title.isEmpty ? c.url : c.title, detail: MioTabStore.displayHost(c.url)) { [weak self] in
                    self?.dismissPanel(); self?.newTab(url: c.url, containerID: c.containerID)
                })
            }
            rows.append(nil)
        }
        rows.append(MioMacMenuRow.note("最近浏览"))
        for h in MioMacBrowserData.shared.history.entries.prefix(10) {
            rows.append(MioMacMenuRow(symbol: "clock", title: h.title.isEmpty ? h.url : h.title, detail: MioTabStore.displayHost(h.url)) { [weak self] in
                self?.dismissPanel(); self?.navigate(self?.activeWebView, to: h.url)
            })
        }
        return MioMacMenuRow.column(rows, width: width, header: "历史", onBack: back)
    }

    private func moreToolsSubview(width: CGFloat, back: @escaping () -> Void) -> NSView {
        MioMacMenuRow.column([
            MioMacMenuRow(symbol: "hammer", title: "网页开发者工具", shortcut: "⌥⌘I") { [weak self] in self?.dismissPanel(); self?.showWebInspector(nil) },
            MioMacMenuRow(symbol: "macwindow.on.rectangle", title: "将标签页移至新窗口") { [weak self] in self?.dismissPanel(); self?.moveTabToNewWindow(nil) },
            MioMacMenuRow(symbol: "safari", title: "用 Safari 打开") { [weak self] in self?.dismissPanel(); self?.openInSafari(nil) },
            disabled(MioMacMenuRow(symbol: "chart.bar", title: "任务管理器", detail: "即将推出")),
        ], width: width, header: "更多工具", onBack: back)
    }

    private func helpSubview(width: CGFloat, back: @escaping () -> Void) -> NSView {
        MioMacMenuRow.column([
            MioMacMenuRow(symbol: "info.circle", title: "关于 Mio") { [weak self] in self?.dismissPanel(); self?.onOpenSettings?(.about) },
            MioMacMenuRow(symbol: "book", title: "Mio 帮助") { [weak self] in self?.dismissPanel(); self?.newTab(url: "https://github.com/mio-co/MioApp#readme") },
            MioMacMenuRow(symbol: "exclamationmark.bubble", title: "报告问题…") { [weak self] in self?.dismissPanel(); self?.newTab(url: "https://github.com/mio-co/MioApp/issues") },
            MioMacMenuRow(symbol: "keyboard", title: "键盘快捷键", detail: "⌘T ⌘W ⌃⇥ ⇧⌘T ⌘L ⌘F") {},
        ], width: width, header: "帮助", onBack: back)
    }

    // MARK: - Mio 扩展

    func showExtensionsPanel() {
        navBar.extensionsButton.isActive = true
        let w = Self.panelWidth + 40
        var rows: [NSView?] = []
        // 此页面：模块菜单项（翻译此页、阅读视图、强制深色、在此网站关闭拦截 / 允许 WebRTC、保存到 Mio、容器……）
        let items = pageMenuItems.filter { !($0.moduleID == host.kit.mioCore.id && $0.itemID == "home") }
        if !items.isEmpty {
            rows.append(MioMacMenuRow.note("此页面"))
            for item in items.prefix(12) {
                let r = MioMacMenuRow(symbol: item.symbol ?? "puzzlepiece", title: item.title, detail: item.checked == true ? "✓" : nil) { [weak self] in
                    self?.dismissPanel()
                    self?.runModuleItem(item)
                }
                r.setAccessibilityIdentifier("mio.ext.item.\(item.id)")
                rows.append(r)
            }
            rows.append(nil)
        }
        // 每个模块的总开关（数据来自 MioKit 的设置模型：改动写 prefs → .mioSettingsDidChange → 所有标签重装脚本 / 重挂规则）
        let model = host.kit.settingsModel
        for g in model.groups() {
            guard let toggleRow = g.rows.first(where: { $0.role == .moduleToggle }) else { continue }
            let r = MioMacMenuRow(symbol: g.symbol, title: g.title, toggle: g.enabled)
            r.toolTip = g.summary
            r.onToggle = { [weak self] on in
                model.apply(toggleRow, .bool(on))
                self?.extensionsChanged(g.title, on: on)
            }
            r.setAccessibilityIdentifier("mio.ext.\(g.moduleID)")
            rows.append(r)
        }
        rows.append(nil)
        rows.append(MioMacMenuRow(symbol: "square.stack.3d.up", title: "容器", submenu: true) { [weak self] in self?.dismissPanel(); self?.onOpenSettings?(.containers) })
        rows.append(MioMacMenuRow(symbol: "curlybraces", title: "用户脚本", submenu: true, detail: "\(host.kit.userScripts.scripts.count) 个") { [weak self] in
            self?.dismissPanel(); self?.onOpenSettings?(.userScripts)
        })
        rows.append(MioMacMenuRow(symbol: "gearshape", title: "管理 Mio 扩展…") { [weak self] in self?.dismissPanel(); self?.onOpenSettings?(.extensions) })
        let col = MioMacMenuRow.column(rows, width: w, header: "Mio 扩展")
        col.setAccessibilityIdentifier("mio.extensionsPanel")
        present(col, from: navBar.extensionsButton) { [weak self] in self?.navBar.extensionsButton.isActive = false }
    }

    private func extensionsChanged(_ title: String, on: Bool) {
        refreshChrome()
        toast.show("「\(title)」已\(on ? "打开" : "关闭")，重新载入网页后生效", button: "重新载入", in: webContainer) { [weak self] in self?.activeWebView?.reload() }
    }

    // MARK: - 站点信息 / 跟踪保护

    func showIdentityPanel() {
        let url = activeWebView?.url
        let home = isHome(url)
        let hostName = home ? "Mio" : (url?.host ?? "新标签页")
        let sec = MioURLDisplay.security(url, isHome: home)
        var rows: [NSView?] = []
        switch sec {
        case .home: rows.append(MioMacMenuRow(symbol: "m.circle.fill", title: "Mio 首页（mio://home）", detail: "MioCore"))
        case .secure: rows.append(MioMacMenuRow(symbol: "lock.fill", title: "连接安全", detail: "HTTPS"))
        case .insecure: rows.append(MioMacMenuRow(symbol: "lock.slash", title: "连接不安全", detail: "HTTP"))
        default: rows.append(MioMacMenuRow(symbol: "info.circle", title: "本地页面"))
        }
        if let t = activeTabID.flatMap({ store.tab($0) }), t.containerID != MioContainerCore.defaultId,
           let c = host.kit.containers.container(t.containerID) {
            rows.append(MioMacMenuRow(symbol: "square.stack.3d.up", title: "容器", detail: c.name))
        }
        let z = activeWebView.map { Double($0.pageZoom) } ?? 1
        rows.append(MioMacMenuRow(symbol: "plus.magnifyingglass", title: "此网站的缩放", detail: MioZoomCore.label(z)))
        if home {
            rows.append(MioMacMenuRow.note("MioCore 的本机能力（相册同步、控制本机……）只对 MioCore 来源开放，其他网站拿不到。"))
        }
        if !home, let h = url?.host {
            rows.append(nil)
            rows.append(MioMacMenuRow(symbol: "trash", title: "清除 Cookie 和网站数据…") { [weak self] in
                self?.dismissPanel()
                self?.clearSiteData(host: h)
            })
        }
        let col = MioMacMenuRow.column(rows, width: Self.panelWidth, header: hostName)
        present(col, from: navBar.urlBar.identityButton, alignment: .leading, onClose: nil)
    }

    /// 跟踪保护（盾牌）：广告 / 跟踪拦截的状态 + 「在此网站关闭拦截」
    func showShieldPanel() {
        let kit = host.kit
        let on = kit.registry.isEnabled(kit.adblock.id)
        let applied = host.modules(for: activeWebView)?.appliedRuleListIdentifiers.count ?? 0
        var rows: [NSView?] = []
        let state = !on ? "已关闭" : (applied > 0 ? "已开启" : "此网站已关闭")
        rows.append(MioMacMenuRow(symbol: on && applied > 0 ? "shield.lefthalf.filled" : "shield.slash", title: "广告与跟踪拦截", detail: state))
        if on, let item = pageMenuItems.first(where: { $0.moduleID == kit.adblock.id }) {
            let r = MioMacMenuRow(symbol: "shield.slash", title: "在此网站关闭拦截", toggle: item.checked == true)
            r.onToggle = { [weak self] _ in
                self?.dismissPanel()
                self?.runModuleItem(item)
            }
            r.setAccessibilityIdentifier("mio.shield.allow")
            rows.append(r)
        }
        rows.append(MioMacMenuRow.note(on ? "\(kit.filters.statusText())。此页挂了 \(applied) 份规则。" : "在 Mio 扩展里打开「广告 / 跟踪拦截」。"))
        rows.append(nil)
        rows.append(MioMacMenuRow(symbol: "puzzlepiece.extension", title: "Mio 扩展…") { [weak self] in self?.dismissPanel(); self?.onOpenSettings?(.extensions) })
        rows.append(MioMacMenuRow(symbol: "gearshape", title: "隐私与安全设置") { [weak self] in self?.dismissPanel(); self?.onOpenSettings?(.privacy) })
        let col = MioMacMenuRow.column(rows, width: Self.panelWidth + 20, header: "跟踪保护")
        present(col, from: navBar.urlBar.shieldButton, alignment: .leading, onClose: nil)
    }

    private func clearSiteData(host: String) {
        guard let wv = activeWebView else { return }
        let a = NSAlert()
        a.messageText = "清除 \(host) 的 Cookie 和网站数据？"
        a.informativeText = "会退出此网站的登录（只影响当前容器）。"
        a.addButton(withTitle: "清除")
        a.addButton(withTitle: "取消")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let store = wv.configuration.websiteDataStore
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let base = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        store.fetchDataRecords(ofTypes: types) { records in
            let hit = records.filter { $0.displayName == base || base.hasSuffix("." + $0.displayName) || $0.displayName.hasSuffix(base) }
            store.removeData(ofTypes: types, for: hit) {
                MainActor.assumeIsolated { _ = wv.reload() }
            }
        }
    }

    // MARK: - 列出所有标签页

    func showAllTabsPanel(from anchor: NSView) {
        tabBar.listAllButton.isActive = true
        var rows: [NSView?] = []
        for t in store.tabs {
            let r = MioMacMenuRow(symbol: nil, title: title(for: t), detail: pinned.contains(t.id) ? "已固定" : nil,
                                  iconImage: tabIcon(t)) { [weak self] in self?.dismissPanel(); self?.select(t.id) }
            r.isSelected = t.id == store.activeID
            rows.append(r)
        }
        rows.append(nil)
        rows.append(MioMacMenuRow(symbol: "arrow.uturn.backward", title: "恢复关闭的标签页", shortcut: "⇧⌘T") { [weak self] in self?.dismissPanel(); self?.reopenClosedTab() })
        let col = MioMacMenuRow.column(rows, width: Self.panelWidth + 40, header: "所有标签页（\(store.count)）")
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        let colSize = col.fittingSize
        col.translatesAutoresizingMaskIntoConstraints = true
        col.frame = NSRect(origin: .zero, size: colSize)
        scroll.documentView = col
        let h = min(col.fittingSize.height, 520)
        let wrap = NSView(frame: NSRect(x: 0, y: 0, width: col.fittingSize.width, height: h))
        scroll.frame = wrap.bounds
        scroll.autoresizingMask = [.width, .height]
        wrap.addSubview(scroll)
        wrap.setFrameSize(NSSize(width: col.fittingSize.width, height: h))
        let sized = MioMacFixedSizeView(size: wrap.frame.size)
        sized.addSubview(wrap)
        present(sized, from: anchor) { [weak self] in self?.tabBar.listAllButton.isActive = false }
    }

    private func tabIcon(_ t: MioTab) -> NSImage? {
        if isHome(URL(string: t.url)) { return MioTheme.symbol("m.circle.fill", 14, weight: .semibold)?.withSymbolConfiguration(.init(paletteColors: [MioTheme.mio])) }
        return favicons[t.id] ?? MioTheme.symbol("globe", 13)
    }

    // MARK: - 标签右键菜单

    func tabContextMenu(_ id: Int) -> NSMenu? {
        guard let t = store.tab(id) else { return nil }
        let m = NSMenu(title: "标签页")
        func add(_ title: String, _ key: String = "", enabled: Bool = true, _ action: @escaping () -> Void) {
            let i = MioMacClosureMenuItem(title: title, keyEquivalent: key, action: action)
            i.isEnabled = enabled
            m.addItem(i)
        }
        add("在右侧新建标签页") { [weak self] in _ = self?.store.select(id); self?.newTab(fromActive: true); self?.focusAddressBar() }
        m.addItem(.separator())
        add("重新载入标签页") { [weak self] in self?.webViews[id]?.reload() }
        add(muted.contains(id) ? "取消静音标签页" : "静音标签页") { [weak self] in self?.toggleMute(id) }
        add(pinned.contains(id) ? "取消固定标签页" : "固定标签页") { [weak self] in self?.togglePin(id) }
        add("复制标签页") { [weak self] in self?.duplicateTab(id) }
        add(isBookmarked(t) ? "移除书签" : "为标签页添加书签…") { [weak self] in
            guard let self, let wv = self.webViews[id], let u = wv.url?.absoluteString else { return }
            MioMacBrowserData.shared.toggleBookmark(url: u, title: wv.title ?? "")
            self.refreshChrome()
        }
        let move = NSMenuItem(title: "移动标签页", action: nil, keyEquivalent: "")
        let moveSub = NSMenu()
        let mi1 = MioMacClosureMenuItem(title: "移至开头") { [weak self] in self?.moveTab(id, to: 0) }
        let mi2 = MioMacClosureMenuItem(title: "移至末尾") { [weak self] in self?.moveTab(id, to: (self?.store.count ?? 1) - 1) }
        let mi3 = MioMacClosureMenuItem(title: "移至新窗口") { [weak self] in
            guard let self, let w = self.window else { return }
            self.detachTab(id, at: NSPoint(x: w.frame.midX + 40, y: w.frame.midY - 40))
        }
        mi3.isEnabled = store.count > 1
        for i in [mi1, mi2, mi3] { moveSub.addItem(i) }
        move.submenu = moveSub
        m.addItem(move)
        let reopen = NSMenuItem(title: "在容器中重新打开", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for c in host.kit.containers.containers where c.id != t.containerID {
            let it = MioMacClosureMenuItem(title: c.name) { [weak self] in self?.reopenInContainer(id, containerID: c.id) }
            if let color = MioMacWebKit.colorFor(container: c) {
                it.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?.withSymbolConfiguration(.init(paletteColors: [color]))
            }
            it.isEnabled = !t.locked
            sub.addItem(it)
        }
        reopen.submenu = sub
        m.addItem(reopen)
        m.addItem(.separator())
        add("关闭标签页", "w") { [weak self] in self?.closeTab(id) }
        let idx = store.index(of: id) ?? 0
        add("关闭右侧标签页", enabled: idx < store.count - 1) { [weak self] in self?.closeTabsToRight(id) }
        add("关闭其他标签页", enabled: store.count > 1) { [weak self] in self?.closeOtherTabs(id) }
        m.addItem(.separator())
        add("恢复关闭的标签页", enabled: store.hasClosed) { [weak self] in self?.reopenClosedTab() }
        return m
    }

    private func isBookmarked(_ t: MioTab) -> Bool { MioMacBrowserData.shared.bookmarks.contains(webViews[t.id]?.url?.absoluteString ?? t.url) }

    // MARK: - 面板公共

    func present(_ content: NSView, from anchor: NSView, alignment: MioMacPopupPanel.Alignment = .trailing, onClose: (() -> Void)?) {
        let p = MioMacPopupPanel(content: content)
        p.onClose = onClose
        p.show(below: anchor, alignment: alignment)
    }

    func dismissPanel() { MioMacPopupPanel.current?.dismiss(animated: true) }
}

/// 固定尺寸的容器（fittingSize = 给定尺寸）：滚动列表放进弹出面板用
@MainActor
final class MioMacFixedSizeView: NSView {
    let size: NSSize
    init(size: NSSize) {
        self.size = size
        super.init(frame: NSRect(origin: .zero, size: size))
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    override var fittingSize: NSSize { size }
    override var intrinsicContentSize: NSSize { size }
}

/// 闭包菜单项（右键菜单用）
@MainActor
final class MioMacClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String = "", action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire(_:)), keyEquivalent: keyEquivalent)
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func fire(_ sender: Any?) { handler() }
}
