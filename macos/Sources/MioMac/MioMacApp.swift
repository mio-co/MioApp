// MioMacApp.swift — 应用委托 + 主菜单（Firefox macOS 菜单结构与快捷键：⌘T ⌘N ⌘W ⇧⌘W ⇧⌘T ⌘L ⌘K ⌘R ⌘F ⌘G ⇧⌘G ⌘D ⌘P
// ⌘+ ⌘- ⌘0 ⌘[ ⌘] ⇧⌘H ⌃⇥ ⌃⇧⇥ ⌥⌘← ⌥⌘→ ⌘1…⌘9 ⌃⌘S ⌃⌘F ⌥⌘I ⇧⌘A ⌘,）

import AppKit
import SwiftUI
import WebKit
import MioKit

@MainActor
final class MioMacAppDelegate: NSObject, NSApplicationDelegate {
    private(set) var controllers: [MioMacBrowserWindowController] = []
    private var smoke: MioMacSmoke?
    private(set) var settingsWindow: NSWindow?
    private(set) lazy var settingsModel: MioMacSettingsModel = makeSettingsModel()
    let prefsState = MioMacPrefsState()

    static let smokeOut = ProcessInfo.processInfo.environment["MIO_SMOKE_OUT"]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MioMacMenu.build(target: self)
        applyAppearance()
        // MioKit 宿主：桥 / 用户脚本打开标签到当前窗口；设置变了刷新窗口和设置页；广告拦截规则（CI 冒烟不查订阅更新，只编译内置列表）
        let host = MioMacKit.shared
        host.currentWindow = { [weak self] in self?.current }
        host.onSettingsChanged = { [weak self] in
            guard let self else { return }
            self.settingsModel.refresh()
            for c in self.controllers { c.refreshTabs(); c.refreshChrome() }
        }
        host.prepare(checkUpdates: Self.smokeOut == nil)
        if let out = Self.smokeOut {
            let c = makeWindow()
            c.newTab(url: "https://example.com/")
            c.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            let s = MioMacSmoke(controller: c, delegate: self, outPath: out)
            smoke = s
            Task { @MainActor in await s.run() }
            return
        }
        let c = makeWindow()
        let restore = UserDefaults.standard.object(forKey: MioMacPreferencesView.restoreKey) as? Bool ?? true
        if !restore || c.restoreSession() == 0 { c.newTab() }
        c.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWindow(nil) }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if Self.smokeOut == nil { current?.saveSession() }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    @discardableResult
    func makeWindow() -> MioMacBrowserWindowController {
        let c = MioMacBrowserWindowController()
        c.onClose = { [weak self] closed in self?.controllers.removeAll { $0 === closed } }
        c.onOpenSettings = { [weak self] pane in self?.openSettings(pane: pane) }
        c.onNewWindow = { [weak self] in self?.newWindow(nil) }
        c.onDetach = { [weak self] from, wv, tab, pinned, point in self?.detached(from: from, webView: wv, tab: tab, pinned: pinned, at: point) }
        controllers.append(c)
        return c
    }

    /// 标签拖出：新窗口出现在松手的位置（淡入 + 微缩放），接收同一个 WKWebView
    func detached(from: MioMacBrowserWindowController, webView: WKWebView, tab: MioTab, pinned: Bool, at point: NSPoint) {
        let size = NSSize(width: max(700, (from.window?.frame.width ?? 1000) * 0.8), height: max(480, (from.window?.frame.height ?? 700) * 0.8))
        let c = makeWindow()
        c.adopt(webView, tab: tab, pinned: pinned)
        guard let w = c.window else { return }
        var f = NSRect(x: point.x - 120, y: point.y - size.height + 20, width: size.width, height: size.height)
        if let vf = (NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main)?.visibleFrame {
            f.origin.x = max(vf.minX, min(vf.maxX - f.width, f.origin.x))
            f.origin.y = max(vf.minY, min(vf.maxY - f.height, f.origin.y))
        }
        w.setFrame(f, display: false)
        if MioMotion.duration(MioMotion.normal) > 0 {
            w.alphaValue = 0
            c.showWindow(nil)
            MioMotion.animate(MioMotion.normal, { w.animator().alphaValue = 1 })
        } else {
            c.showWindow(nil)
        }
        c.positionTrafficLights()
    }

    var current: MioMacBrowserWindowController? {
        (NSApp.keyWindow?.windowController as? MioMacBrowserWindowController)
            ?? (NSApp.mainWindow?.windowController as? MioMacBrowserWindowController)
            ?? controllers.last
    }

    // MARK: - 设置（about:preferences 风格；Mio 扩展的数据来自 MioKit）

    private func makeSettingsModel() -> MioMacSettingsModel {
        let m = MioMacSettingsModel(kit: MioMacKit.shared.kit)
        m.platformName = "macOS"
        m.userAgent = MioMacWebKit.desktopUserAgent
        m.zoomSites = {
            let t = MioZoomCore.SiteTable(json: UserDefaults.standard.string(forKey: MioMacBrowserWindowController.zoomSitesKey))
            return t.sites.keys.sorted().map { (site: $0, level: t.sites[$0] ?? 1.0) }
        }
        m.clearZoomSites = { UserDefaults.standard.removeObject(forKey: MioMacBrowserWindowController.zoomSitesKey) }
        // Mac 自己的设置（外观 / 垂直标签 / 恢复会话 / 缩放）变了；Mio 扩展的设置走 MioKit 的 .mioSettingsDidChange
        m.onChange = { [weak self] in
            MainActor.assumeIsolated {
                self?.applyAppearance()
                for c in self?.controllers ?? [] { c.applyPreferences(); c.refreshTabs(); c.refreshChrome() }
            }
        }
        return m
    }

    func applyAppearance() {
        switch UserDefaults.standard.integer(forKey: MioMacPreferencesView.appearanceKey) {
        case 1: NSApp.appearance = NSAppearance(named: .aqua)
        case 2: NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    func openSettings(pane: MioMacPrefsPane? = nil) {
        if let p = pane { prefsState.query = ""; prefsState.pane = p }
        if settingsWindow == nil {
            let host = NSHostingController(rootView: MioMacPreferencesView(model: settingsModel, state: prefsState))
            let w = NSWindow(contentViewController: host)
            w.title = "设置"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.setContentSize(NSSize(width: 960, height: 660))
            w.isReleasedWhenClosed = false
            w.animationBehavior = .documentWindow
            w.center()
            settingsWindow = w
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showSettings(_ sender: Any?) { openSettings() }
    @objc func showExtensionsSettings(_ sender: Any?) { openSettings(pane: .extensions) }

    // MARK: - 菜单动作（转给当前窗口）

    @objc func newWindow(_ sender: Any?) {
        let c = makeWindow()
        c.newTab()
        c.showWindow(nil)
        c.focusAddressBar()
    }

    @objc func newTab(_ sender: Any?) {
        guard let c = current else { newWindow(sender); return }
        c.newTab()
        c.focusAddressBar()
    }

    @objc func openLocation(_ sender: Any?) {
        guard let c = current else { newWindow(sender); return }
        c.focusAddressBar()
    }

    @objc func closeTab(_ sender: Any?) { current?.closeTab() }
    @objc func reopenClosedTab(_ sender: Any?) { current?.reopenClosedTab() }
    @objc func reload(_ sender: Any?) { current?.reload(sender) }
    @objc func zoomIn(_ sender: Any?) { current?.zoomIn(sender) }
    @objc func zoomOut(_ sender: Any?) { current?.zoomOut(sender) }
    @objc func actualSize(_ sender: Any?) { current?.zoomReset(sender) }
    @objc func goBack(_ sender: Any?) { current?.goBack(sender) }
    @objc func goForward(_ sender: Any?) { current?.goForward(sender) }
    @objc func goHome(_ sender: Any?) { current?.goHome(sender) }
    @objc func nextTab(_ sender: Any?) { current?.selectRelative(1) }
    @objc func previousTab(_ sender: Any?) { current?.selectRelative(-1) }
    @objc func selectTabNumber(_ sender: NSMenuItem) { current?.selectNumber(sender.tag) }
    @objc func findInPage(_ sender: Any?) { current?.showFindBar(sender) }
    @objc func findNext(_ sender: Any?) { current?.findNext(sender) }
    @objc func findPrevious(_ sender: Any?) { current?.findPrevious(sender) }
    @objc func bookmarkPage(_ sender: Any?) { current?.toggleBookmark(sender) }
    @objc func printPage(_ sender: Any?) { current?.printPage(sender) }
    @objc func toggleSidebar(_ sender: Any?) { current?.toggleSidebar(sender) }
    @objc func webInspector(_ sender: Any?) { current?.showWebInspector(sender) }
    @objc func moveTabToNewWindow(_ sender: Any?) { current?.moveTabToNewWindow(sender) }
    @objc func toggleVerticalTabs(_ sender: Any?) {
        let on = !UserDefaults.standard.bool(forKey: MioMacPreferencesView.verticalTabsKey)
        UserDefaults.standard.set(on, forKey: MioMacPreferencesView.verticalTabsKey)
        for c in controllers { c.applyPreferences() }
    }
    @objc func toggleFullScreen(_ sender: Any?) { current?.window?.toggleFullScreen(sender) }
}

@MainActor
enum MioMacMenu {
    static func build(target: AnyObject) -> NSMenu {
        let main = NSMenu(title: "Main")

        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, useTarget: Bool = true) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = useTarget ? target : nil
            return i
        }
        func hidden(_ i: NSMenuItem) -> NSMenuItem {
            i.isHidden = true
            i.allowsKeyEquivalentWhenHidden = true
            return i
        }
        func sub(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: title)
            for i in items { m.addItem(i) }
            top.submenu = m
            return top
        }
        @discardableResult
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let top = sub(title, items)
            main.addItem(top)
            return top.submenu!
        }
        let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        let right = String(UnicodeScalar(NSRightArrowFunctionKey)!)

        submenu("Mio", [
            item("关于 Mio", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), useTarget: false),
            .separator(),
            item("设置…", #selector(MioMacAppDelegate.showSettings(_:)), ","),
            .separator(),
            item("隐藏 Mio", #selector(NSApplication.hide(_:)), "h", useTarget: false),
            item("隐藏其他", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], useTarget: false),
            item("全部显示", #selector(NSApplication.unhideAllApplications(_:)), useTarget: false),
            .separator(),
            item("退出 Mio", #selector(NSApplication.terminate(_:)), "q", useTarget: false),
        ])
        submenu("文件", [
            item("新建标签页", #selector(MioMacAppDelegate.newTab(_:)), "t"),
            item("新建窗口", #selector(MioMacAppDelegate.newWindow(_:)), "n"),
            item("打开位置…", #selector(MioMacAppDelegate.openLocation(_:)), "l"),
            hidden(item("搜索", #selector(MioMacAppDelegate.openLocation(_:)), "k")),
            .separator(),
            item("关闭标签页", #selector(MioMacAppDelegate.closeTab(_:)), "w"),
            item("关闭窗口", #selector(NSWindow.performClose(_:)), "w", [.command, .shift], useTarget: false),
            .separator(),
            item("打印…", #selector(MioMacAppDelegate.printPage(_:)), "p"),
        ])
        submenu("编辑", [
            item("撤销", Selector(("undo:")), "z", useTarget: false),
            item("重做", Selector(("redo:")), "z", [.command, .shift], useTarget: false),
            .separator(),
            item("剪切", #selector(NSText.cut(_:)), "x", useTarget: false),
            item("拷贝", #selector(NSText.copy(_:)), "c", useTarget: false),
            item("粘贴", #selector(NSText.paste(_:)), "v", useTarget: false),
            item("全选", #selector(NSText.selectAll(_:)), "a", useTarget: false),
            .separator(),
            item("在页面中查找…", #selector(MioMacAppDelegate.findInPage(_:)), "f"),
            item("再次查找", #selector(MioMacAppDelegate.findNext(_:)), "g"),
            item("查找上一个", #selector(MioMacAppDelegate.findPrevious(_:)), "g", [.command, .shift]),
        ])
        // ⌘= 与 ⌘+ 同一个动作（美式键盘上 + 要按 Shift）：隐藏项只响应快捷键
        submenu("显示", [
            sub("工具栏", [
                item("垂直标签页", #selector(MioMacAppDelegate.toggleVerticalTabs(_:))),
            ]),
            item("侧边栏", #selector(MioMacAppDelegate.toggleSidebar(_:)), "s", [.command, .control]),
            .separator(),
            sub("缩放", [
                item("放大", #selector(MioMacAppDelegate.zoomIn(_:)), "+"),
                hidden(item("放大", #selector(MioMacAppDelegate.zoomIn(_:)), "=")),
                item("缩小", #selector(MioMacAppDelegate.zoomOut(_:)), "-"),
                .separator(),
                item("重置", #selector(MioMacAppDelegate.actualSize(_:)), "0"),
            ]),
            item("重新载入页面", #selector(MioMacAppDelegate.reload(_:)), "r"),
            .separator(),
            item("进入全屏幕", #selector(MioMacAppDelegate.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        submenu("历史", [
            item("后退", #selector(MioMacAppDelegate.goBack(_:)), "["),
            item("前进", #selector(MioMacAppDelegate.goForward(_:)), "]"),
            item("主页", #selector(MioMacAppDelegate.goHome(_:)), "h", [.command, .shift]),
            .separator(),
            item("恢复关闭的标签页", #selector(MioMacAppDelegate.reopenClosedTab(_:)), "t", [.command, .shift]),
        ])
        submenu("书签", [
            item("为此页加书签", #selector(MioMacAppDelegate.bookmarkPage(_:)), "d"),
        ])
        submenu("工具", [
            item("Mio 扩展", #selector(MioMacAppDelegate.showExtensionsSettings(_:)), "a", [.command, .shift]),
            item("网页开发者工具", #selector(MioMacAppDelegate.webInspector(_:)), "i", [.command, .option]),
        ])
        var tabItems: [NSMenuItem] = [
            item("最小化", #selector(NSWindow.performMiniaturize(_:)), "m", useTarget: false),
            item("缩放", #selector(NSWindow.performZoom(_:)), "", useTarget: false),
            .separator(),
            item("下一个标签页", #selector(MioMacAppDelegate.nextTab(_:)), "\t", .control),
            item("上一个标签页", #selector(MioMacAppDelegate.previousTab(_:)), "\t", [.control, .shift]),
            hidden(item("下一个标签页", #selector(MioMacAppDelegate.nextTab(_:)), right, [.command, .option])),
            hidden(item("上一个标签页", #selector(MioMacAppDelegate.previousTab(_:)), left, [.command, .option])),
            hidden(item("下一个标签页", #selector(MioMacAppDelegate.nextTab(_:)), "}")),
            hidden(item("上一个标签页", #selector(MioMacAppDelegate.previousTab(_:)), "{")),
            item("将标签页移至新窗口", #selector(MioMacAppDelegate.moveTabToNewWindow(_:))),
            .separator(),
        ]
        for n in 1...9 {
            let i = item(n == 9 ? "最后一个标签页" : "标签页 \(n)", #selector(MioMacAppDelegate.selectTabNumber(_:)), "\(n)")
            i.tag = n
            tabItems.append(i)
        }
        let windowMenu = submenu("窗口", tabItems)
        NSApp.windowsMenu = windowMenu
        return main
    }

    /// 冒烟报告：菜单里的快捷键（"⌘t" 形式；子菜单也算；⇥ = Tab，← → = 方向键）
    static func keyEquivalents(_ menu: NSMenu?) -> [String] {
        var out: [String] = []
        func walk(_ m: NSMenu?) {
            for i in m?.items ?? [] {
                if let s = i.submenu { walk(s) }
                guard !i.keyEquivalent.isEmpty else { continue }
                var s = ""
                if i.keyEquivalentModifierMask.contains(.control) { s += "⌃" }
                if i.keyEquivalentModifierMask.contains(.option) { s += "⌥" }
                if i.keyEquivalentModifierMask.contains(.shift) { s += "⇧" }
                if i.keyEquivalentModifierMask.contains(.command) { s += "⌘" }
                var k = i.keyEquivalent
                if k == "\t" { k = "⇥" }
                if k.unicodeScalars.first?.value == UInt32(NSLeftArrowFunctionKey) { k = "←" }
                if k.unicodeScalars.first?.value == UInt32(NSRightArrowFunctionKey) { k = "→" }
                out.append(s + k)
            }
        }
        for top in menu?.items ?? [] { walk(top.submenu) }
        return out
    }
}
