// MioMacApp.swift — 应用委托 + 主菜单（Safari 同款快捷键：⌘T / ⌘W / ⌘L / ⇧⌘T / ⌘R / ⌘+ ⌘- ⌘0 / ⌘[ ⌘] / ⌘1…9 / ⇧⌘[ ⇧⌘]）

import AppKit
import SwiftUI

@MainActor
final class MioMacAppDelegate: NSObject, NSApplicationDelegate {
    private(set) var controllers: [MioMacBrowserWindowController] = []
    private var smoke: MioMacSmoke?
    private(set) var settingsWindow: NSWindow?
    private lazy var settingsModel: MioSettingsModel = makeSettingsModel()

    static let smokeOut = ProcessInfo.processInfo.environment["MIO_SMOKE_OUT"]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MioMacMenu.build(target: self)
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
        if c.restoreSession() == 0 { c.newTab() }
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
        c.onOpenSettings = { [weak self] section in self?.openSettings(section: section) }
        controllers.append(c)
        return c
    }

    var current: MioMacBrowserWindowController? {
        (NSApp.keyWindow?.windowController as? MioMacBrowserWindowController)
            ?? (NSApp.mainWindow?.windowController as? MioMacBrowserWindowController)
            ?? controllers.last
    }

    // MARK: - 设置（SwiftUI，Safari 分区 + Mio 分区；与 iOS 共用 MioSettingsView）

    private func makeSettingsModel() -> MioSettingsModel {
        let m = MioSettingsModel(registry: MioMacWebKit.modules)
        m.platformName = "macOS"
        m.userAgent = MioMacWebKit.desktopUserAgent
        m.containers = { MioMacWebKit.containerState().containers }
        m.createContainer = { name in
            var st = MioMacWebKit.containerState()
            if (try? st.create(name: name)) != nil {
                UserDefaults.standard.set(st.jsonData(), forKey: MioMacWebKit.containersStateKey)
            }
        }
        m.zoomSites = {
            let t = MioZoomCore.SiteTable(json: UserDefaults.standard.string(forKey: MioMacBrowserWindowController.zoomSitesKey))
            return t.sites.keys.sorted().map { (site: $0, level: t.sites[$0] ?? 1.0) }
        }
        m.clearZoomSites = { UserDefaults.standard.removeObject(forKey: MioMacBrowserWindowController.zoomSitesKey) }
        m.onChange = { [weak self] in
            MainActor.assumeIsolated {
                for c in self?.controllers ?? [] { c.reinstallModuleScripts(); c.refreshTabs() }
            }
        }
        return m
    }

    func openSettings(section: MioSettingsSection? = nil) {
        if let s = section { settingsModel.selection = s }
        if settingsWindow == nil {
            let host = NSHostingController(rootView: MioSettingsView(model: settingsModel))
            let w = NSWindow(contentViewController: host)
            w.title = "设置"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.setContentSize(NSSize(width: 780, height: 540))
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showSettings(_ sender: Any?) { openSettings() }

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
    @objc func nextTab(_ sender: Any?) { current?.selectRelative(1) }
    @objc func previousTab(_ sender: Any?) { current?.selectRelative(-1) }
    @objc func selectTabNumber(_ sender: NSMenuItem) { current?.selectNumber(sender.tag) }
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
        @discardableResult
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: title)
            for i in items { m.addItem(i) }
            top.submenu = m
            main.addItem(top)
            return m
        }

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
            item("新建窗口", #selector(MioMacAppDelegate.newWindow(_:)), "n"),
            item("新建标签页", #selector(MioMacAppDelegate.newTab(_:)), "t"),
            item("打开位置…", #selector(MioMacAppDelegate.openLocation(_:)), "l"),
            .separator(),
            item("关闭标签页", #selector(MioMacAppDelegate.closeTab(_:)), "w"),
            item("关闭窗口", #selector(NSWindow.performClose(_:)), "w", [.command, .shift], useTarget: false),
            item("重新打开关闭的标签页", #selector(MioMacAppDelegate.reopenClosedTab(_:)), "t", [.command, .shift]),
        ])
        submenu("编辑", [
            item("撤销", Selector(("undo:")), "z", useTarget: false),
            item("重做", Selector(("redo:")), "z", [.command, .shift], useTarget: false),
            .separator(),
            item("剪切", #selector(NSText.cut(_:)), "x", useTarget: false),
            item("拷贝", #selector(NSText.copy(_:)), "c", useTarget: false),
            item("粘贴", #selector(NSText.paste(_:)), "v", useTarget: false),
            item("全选", #selector(NSText.selectAll(_:)), "a", useTarget: false),
        ])
        // ⌘= 与 ⌘+ 同一个动作（美式键盘上 + 要按 Shift）：隐藏项只响应快捷键
        let zoomInAlt = item("放大", #selector(MioMacAppDelegate.zoomIn(_:)), "=")
        zoomInAlt.isHidden = true
        zoomInAlt.allowsKeyEquivalentWhenHidden = true
        submenu("显示", [
            item("重新载入页面", #selector(MioMacAppDelegate.reload(_:)), "r"),
            .separator(),
            item("实际大小", #selector(MioMacAppDelegate.actualSize(_:)), "0"),
            item("放大", #selector(MioMacAppDelegate.zoomIn(_:)), "+"),
            zoomInAlt,
            item("缩小", #selector(MioMacAppDelegate.zoomOut(_:)), "-"),
            .separator(),
            item("显示 / 隐藏边栏", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control], useTarget: false),
            item("进入全屏幕", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control], useTarget: false),
        ])
        submenu("历史记录", [
            item("后退", #selector(MioMacAppDelegate.goBack(_:)), "["),
            item("前进", #selector(MioMacAppDelegate.goForward(_:)), "]"),
        ])
        var tabItems: [NSMenuItem] = [
            item("最小化", #selector(NSWindow.performMiniaturize(_:)), "m", useTarget: false),
            item("缩放", #selector(NSWindow.performZoom(_:)), "", useTarget: false),
            .separator(),
            item("显示上一个标签页", #selector(MioMacAppDelegate.previousTab(_:)), "{"),
            item("显示下一个标签页", #selector(MioMacAppDelegate.nextTab(_:)), "}"),
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

    /// 冒烟报告：菜单里的快捷键（"⌘t" 形式）
    static func keyEquivalents(_ menu: NSMenu?) -> [String] {
        var out: [String] = []
        for top in menu?.items ?? [] {
            for i in top.submenu?.items ?? [] where !i.keyEquivalent.isEmpty {
                var s = ""
                if i.keyEquivalentModifierMask.contains(.control) { s += "⌃" }
                if i.keyEquivalentModifierMask.contains(.option) { s += "⌥" }
                if i.keyEquivalentModifierMask.contains(.shift) { s += "⇧" }
                if i.keyEquivalentModifierMask.contains(.command) { s += "⌘" }
                out.append(s + i.keyEquivalent)
            }
        }
        return out
    }
}
