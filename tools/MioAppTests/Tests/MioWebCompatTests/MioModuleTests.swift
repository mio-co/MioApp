import XCTest
@testable import MioWebCompat

/// v0.4.0 模块接口（macos/Sources/MioMac/Kit/MioModule.swift，iOS / macOS 共用）
final class MioModuleTests: XCTestCase {
    final class FakeModule: MioModule {
        let id: String
        let title: String
        let summary = "fake"
        let section: MioSettingsSection
        let key: String?
        let defOn: Bool
        init(_ id: String, section: MioSettingsSection = .modules, key: String? = "default", defOn: Bool = true) {
            self.id = id; self.title = id.uppercased(); self.section = section; self.defOn = defOn
            self.key = key == "default" ? "mio.module.\(id).enabled" : key
        }
        var enabledKey: String? { key }
        var defaultEnabled: Bool { defOn }
        var settings: [MioModuleSetting] { [MioModuleSetting(key: "mio.\(id).x", title: "X", kind: .toggle(default: true))] }
        func scripts(prefs: MioPrefs) -> [MioModuleScript] {
            [MioModuleScript(source: "/*\(id):\(prefs.bool("mio.\(id).x", default: true))*/", mainFrameOnly: false, world: .isolated("mio.\(id)"))]
        }
        func menuItems(page: MioPageContext, prefs: MioPrefs) -> [MioModuleMenuItem] {
            page.host == "example.com" ? [MioModuleMenuItem(moduleID: id, itemID: "go", title: "Go")] : []
        }
        func perform(_ itemID: String, page: MioPageContext, prefs: MioPrefs) -> MioModuleAction {
            itemID == "go" ? .openSettings(section) : .none
        }
    }

    final class MinimalModule: MioModule {
        let id = "minimal"
        let title = "Minimal"
        let summary = ""
        let section = MioSettingsSection.privacy
    }

    func testSectionsFollowSafariThenMio() {
        XCTAssertEqual(MioSettingsSection.safariSections.map { $0.title }, ["通用", "标签页", "自动填充", "搜索", "隐私与安全", "网站设置", "高级"])
        XCTAssertEqual(MioSettingsSection.mioSections.map { $0.title }, ["容器", "用户脚本", "模块", "MioCore"])
        XCTAssertEqual(Set(MioSettingsSection.allCases.map { $0.symbol }).count, MioSettingsSection.allCases.count)
    }

    func testEnableDisableControlsScriptsAndMenus() {
        let prefs = MioMemoryPrefs()
        let r = MioModuleRegistry(prefs: prefs, modules: [FakeModule("a"), FakeModule("b", defOn: false), FakeModule("always", key: nil)])
        XCTAssertEqual(r.scripts().map { $0.moduleID }, ["a", "always"])
        r.setEnabled("b", true)
        XCTAssertEqual(prefs.values["mio.module.b.enabled"] as? Bool, true)
        XCTAssertEqual(r.scripts().map { $0.moduleID }, ["a", "b", "always"])
        r.setEnabled("a", false)
        r.setEnabled("always", false) // 没有开关的模块关不掉
        XCTAssertEqual(r.enabled.map { $0.id }, ["b", "always"])
        let s = r.scripts().first!.script
        XCTAssertEqual(s.world, .isolated("mio.b"))
        XCTAssertEqual(s.injection, .documentStart)
        XCTAssertFalse(s.mainFrameOnly)
    }

    func testSettingsFeedScripts() {
        let prefs = MioMemoryPrefs(["mio.a.x": false])
        let r = MioModuleRegistry(prefs: prefs, modules: [FakeModule("a")])
        XCTAssertEqual(r.scripts().first?.script.source, "/*a:false*/")
        prefs.set(NSNumber(value: true), forKey: "mio.a.x")
        XCTAssertEqual(r.scripts().first?.script.source, "/*a:true*/")
    }

    func testMenuItemsFilteredByPageAndPerform() {
        let r = MioModuleRegistry(prefs: MioMemoryPrefs(), modules: [FakeModule("a", section: .privacy), FakeModule("b")])
        XCTAssertTrue(r.menuItems(page: MioPageContext(url: URL(string: "https://other.org/"))).isEmpty)
        let page = MioPageContext(url: URL(string: "https://EXAMPLE.com/x"))
        let items = r.menuItems(page: page)
        XCTAssertEqual(items.map { $0.id }, ["a.go", "b.go"])
        XCTAssertEqual(r.perform(items[0], page: page), .openSettings(.privacy))
        r.setEnabled("a", false)
        XCTAssertEqual(r.perform(items[0], page: page), .none)
        XCTAssertEqual(r.menuItems(page: page).map { $0.id }, ["b.go"])
    }

    func testRegistryRejectsDuplicatesAndDefaults() {
        let r = MioModuleRegistry(prefs: MioMemoryPrefs(), modules: [FakeModule("a"), FakeModule("a", section: .privacy)])
        XCTAssertEqual(r.modules.count, 1)
        XCTAssertEqual(r.module("a")?.section, .modules)
        XCTAssertTrue(r.register(MinimalModule()))
        let m = r.module("minimal")!
        XCTAssertEqual(m.enabledKey, "mio.module.minimal.enabled")
        XCTAssertTrue(m.isEnabled(r.prefs))
        XCTAssertTrue(m.settings.isEmpty)
        XCTAssertTrue(m.scripts(prefs: r.prefs).isEmpty)
        XCTAssertEqual(r.modules(in: .privacy).map { $0.id }, ["minimal"])
    }

    func testSettingKindEquality() {
        let a = MioModuleSetting(key: "k", title: "t", kind: .choice(options: [(1, "一"), (2, "二")], default: 1))
        let b = MioModuleSetting(key: "k", title: "t", kind: .choice(options: [(1, "一"), (2, "二")], default: 1))
        let c = MioModuleSetting(key: "k", title: "t", kind: .choice(options: [(1, "一")], default: 1))
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertNotEqual(MioModuleSetting(key: "k", title: "t", kind: .toggle(default: true)), MioModuleSetting(key: "k", title: "t", kind: .text(default: "", placeholder: "")))
    }
}
