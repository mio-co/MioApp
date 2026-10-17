// MioSettingsView.swift — 设置页（SwiftUI，iOS / macOS 共用；只依赖 SwiftUI + 共享核心）。
// 分区照搬 Safari：通用、标签页、自动填充、搜索、隐私与安全、网站设置、高级；Safari 没有的单独一组：容器、用户脚本、模块、MioCore。
// 模块的开关和设置项由 MioModule 声明自动生成；宿主（Mac 设置窗口 / iOS 设置页）只提供数据和回调。

import SwiftUI

// 不标 @MainActor：Binding(get:set:) 的闭包在新 SDK 里是 @Sendable，非隔离的 model 最省事（只在主线程用）
final class MioSettingsModel: ObservableObject {
    let registry: MioModuleRegistry
    @Published var selection: MioSettingsSection? = .general
    var containers: () -> [MioContainer] = { [] }
    var createContainer: (String) -> Void = { _ in }
    var zoomSites: () -> [(site: String, level: Double)] = { [] }
    var clearZoomSites: () -> Void = {}
    var userAgent: String = ""
    var platformName: String = "macOS"
    /// 设置变了（宿主重装注入脚本等）
    var onChange: () -> Void = {}

    static let defaultZoomKey = "mio.zoom.default"

    init(registry: MioModuleRegistry) { self.registry = registry }

    var prefs: MioPrefs { registry.prefs }

    func changed() {
        objectWillChange.send()
        onChange()
    }

    func bool(_ key: String, _ d: Bool) -> Binding<Bool> {
        Binding(get: { self.prefs.bool(key, default: d) }, set: { self.prefs.set($0, forKey: key); self.changed() })
    }

    func int(_ key: String, _ d: Int) -> Binding<Int> {
        Binding(get: { self.prefs.int(key, default: d) }, set: { self.prefs.set($0, forKey: key); self.changed() })
    }

    func string(_ key: String, _ d: String) -> Binding<String> {
        Binding(get: { self.prefs.string(key, default: d) }, set: { self.prefs.set($0, forKey: key); self.changed() })
    }

    func enabled(_ m: MioModule) -> Binding<Bool> {
        Binding(get: { m.isEnabled(self.prefs) }, set: { self.registry.setEnabled(m.id, $0); self.changed() })
    }

    var defaultZoom: Binding<Double> {
        Binding(get: {
            let v = (self.prefs.object(forKey: Self.defaultZoomKey) as? Double) ?? 1.0
            return v > 0 ? MioZoomCore.nearest(v) : 1.0
        }, set: { self.prefs.set($0, forKey: Self.defaultZoomKey); self.changed() })
    }
}

struct MioSettingsView: View {
    @ObservedObject var model: MioSettingsModel
    @State private var newContainerName = ""

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                Section(header: Text("Safari")) {
                    ForEach(MioSettingsSection.safariSections) { s in
                        Label(s.title, systemImage: s.symbol).tag(s as MioSettingsSection?)
                    }
                }
                Section(header: Text("Mio")) {
                    ForEach(MioSettingsSection.mioSections) { s in
                        Label(s.title, systemImage: s.symbol).tag(s as MioSettingsSection?)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            let section = model.selection ?? .general
            Form { content(section) }
                .formStyle(.grouped)
                .navigationTitle(section.title)
        }
    }

    @ViewBuilder
    private func content(_ section: MioSettingsSection) -> some View {
        switch section {
        case .general:
            Section {
                TextField("主页 / 新标签页", text: model.string(MioCoreModule.newTabKey, MioTabStore.defaultNewTabURL), prompt: Text("https://…"))
                Picker("网页缩放", selection: model.defaultZoom) {
                    ForEach(MioZoomCore.levels, id: \.self) { z in Text(MioZoomCore.label(z)).tag(z) }
                }
            } footer: { Text("主页默认是 Mio 导航（MioCore 模块）。") }
        case .tabs:
            Section {
                LabeledContent("标签布局", value: model.platformName == "iOS" ? "底部地址栏（Safari iPhone 式）" : "独立标签条 + 侧边栏")
                LabeledContent("⌘点链接", value: "在后台新标签页打开")
            } footer: { Text("更多标签选项（关闭旧标签、标签组）在 v0.4.0 迁移。") }
        case .autofill:
            Section {
                LabeledContent("密码与通行密钥", value: "系统「密码」/ iCloud 钥匙串")
            } footer: { Text("WKWebView 使用系统自动填充；Mio 不单独保存密码。") }
        case .search:
            Section {
                LabeledContent("搜索引擎", value: "Google")
            } footer: { Text("地址栏里不像网址的文字用搜索引擎搜索。") }
        case .privacy:
            moduleSections(model.registry.modules(in: .privacy))
            Section {
                LabeledContent("网站数据", value: "按容器隔离")
            }
        case .websites:
            let sites = model.zoomSites()
            Section {
                if sites.isEmpty { Text("没有单独设置缩放的网站").foregroundStyle(.secondary) }
                ForEach(sites, id: \.site) { s in LabeledContent(s.site, value: MioZoomCore.label(s.level)) }
                if !sites.isEmpty { Button("全部移除") { model.clearZoomSites(); model.changed() } }
            } header: { Text("网页缩放") }
        case .advanced:
            Section {
                LabeledContent("User-Agent") { Text(model.userAgent).font(.caption).textSelection(.enabled) }
                LabeledContent("网页检查器", value: "已开启（右键 › 检查元素）")
            }
        case .containers:
            Section {
                ForEach([MioContainerCore.defaultContainer] + model.containers(), id: \.id) { c in
                    Label(c.name, systemImage: "circle.fill").foregroundStyle(color(c))
                }
                HStack {
                    TextField("新容器名称", text: $newContainerName)
                    Button("新建") {
                        let n = newContainerName.trimmingCharacters(in: .whitespaces)
                        guard !n.isEmpty else { return }
                        model.createContainer(n)
                        newContainerName = ""
                        model.changed()
                    }
                }
            } footer: { Text("每个容器一份独立的 Cookie / 登录 / 缓存。") }
        case .userScripts:
            Section {
                LabeledContent("用户脚本", value: "Tampermonkey 兼容（@match / GM API）")
            } footer: { Text("用户脚本是用户自装的插件，与内置模块走同一个注入通道；管理界面在 v0.4.0 迁移。") }
        case .modules:
            moduleSections(model.registry.modules.filter { $0.section == .modules })
            Section(header: Text("其他分区里的模块")) {
                ForEach(model.registry.modules.filter { $0.section != .modules }, id: \.id) { m in
                    LabeledContent(m.title, value: m.section.title)
                }
            }
        case .mioCore:
            moduleSections(model.registry.modules(in: .mioCore))
            Section {
                LabeledContent("登录 / 同步", value: "规划中")
                LabeledContent("保存到 MioCore", value: "规划中（mio-save.js）")
            }
        }
    }

    @ViewBuilder
    private func moduleSections(_ modules: [MioModule]) -> some View {
        ForEach(modules, id: \.id) { m in
            Section {
                if m.enabledKey != nil { Toggle(m.title, isOn: model.enabled(m)) }
                ForEach(m.settings) { s in settingRow(s) }
            } header: { Text(m.title) } footer: { Text(m.summary) }
        }
    }

    @ViewBuilder
    private func settingRow(_ s: MioModuleSetting) -> some View {
        switch s.kind {
        case .toggle(let d):
            Toggle(s.title, isOn: model.bool(s.key, d))
        case .choice(let options, let d):
            Picker(s.title, selection: model.int(s.key, d)) {
                ForEach(options, id: \.value) { o in Text(o.label).tag(o.value) }
            }
        case .text(let d, let placeholder):
            TextField(s.title, text: model.string(s.key, d), prompt: Text(placeholder))
        }
        if let f = s.footer { Text(f).font(.caption).foregroundStyle(.secondary) }
    }

    private func color(_ c: MioContainer) -> Color {
        guard let hex = MioContainerCore.colorHex[c.color] else { return .gray }
        return Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
