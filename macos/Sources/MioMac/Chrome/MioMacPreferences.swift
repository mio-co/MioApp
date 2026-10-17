// MioMacPreferences.swift — Firefox about:preferences 风格的设置窗口（SwiftUI，Mac 专用外观）：
//   左侧大图标分类（常规 · 主页 · 搜索 · 隐私与安全 · Mio 扩展 · 容器 · 用户脚本），左下「关于 Mio」；右侧可滚动内容 + 顶部「在设置中查找」。
//   Mio 扩展页：每个模块一张卡片（总开关 + 子设置），数据全部来自 MioKit 的 MioExtensionSettingsModel（groups / apply / trigger），
//   这里只负责画：toggle → Toggle、choice → Picker、text → TextField / SecureField、stringList → 可增删列表、action → 按钮、info → 文字。
//   容器页 / 用户脚本页：管理界面（新建 / 改名 / 改色 / 删除容器、站点规则；安装 / 启停 / 更新 / 删除用户脚本），风格照 Firefox 桌面。

import SwiftUI
import AppKit
import MioKit

enum MioMacPrefsPane: String, CaseIterable, Identifiable {
    case general, home, search, privacy, extensions, containers, userScripts, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "常规"
        case .home: return "主页"
        case .search: return "搜索"
        case .privacy: return "隐私与安全"
        case .extensions: return "Mio 扩展"
        case .containers: return "容器"
        case .userScripts: return "用户脚本"
        case .about: return "关于 Mio"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .home: return "house"
        case .search: return "magnifyingglass"
        case .privacy: return "lock"
        case .extensions: return "puzzlepiece.extension"
        case .containers: return "square.stack.3d.up"
        case .userScripts: return "curlybraces"
        case .about: return "info.circle"
        }
    }

    /// MioKit 的设置分区 → 本窗口的分类（模块动作「打开设置」跳转用）
    init(section: MioSettingsSection) {
        switch section {
        case .general, .tabs, .websites, .advanced, .autofill: self = .general
        case .search: self = .search
        case .privacy: self = .privacy
        case .containers: self = .containers
        case .extensions: self = .extensions
        case .userScripts: self = .userScripts
        case .mioCore: self = .home
        }
    }
}

/// 设置窗口的数据：Mac 自己的设置（外观、垂直标签、恢复会话、缩放）+ MioKit（Mio 扩展、容器、用户脚本）。
/// 不标 @MainActor：Binding(get:set:) 的闭包在新 SDK 里是 @Sendable，非隔离的 model 最省事（只在主线程用）
final class MioMacSettingsModel: ObservableObject {
    let kit: MioKitContainer
    var ext: MioExtensionSettingsModel { kit.settingsModel }
    var prefs: MioPrefs { kit.prefs }
    var zoomSites: () -> [(site: String, level: Double)] = { [] }
    var clearZoomSites: () -> Void = {}
    var userAgent: String = ""
    var platformName: String = "macOS"
    /// Mac 自己的设置变了（外观 / 垂直标签……）
    var onChange: () -> Void = {}
    /// 按钮行（立即更新规则、检查更新……）的结果文字，key = 行 id
    @Published var status: [String: String] = [:]
    @Published var busy: Set<String> = []

    static let defaultZoomKey = "mio.zoom.default"

    init(kit: MioKitContainer) { self.kit = kit }

    /// MioKit 设置 / 容器 / 用户脚本变了：重画
    func refresh() { objectWillChange.send() }

    func changed() {
        objectWillChange.send()
        onChange()
    }

    // MARK: Mac 设置

    func bool(_ key: String, _ d: Bool) -> Binding<Bool> {
        Binding(get: { self.prefs.bool(key, default: d) }, set: { self.prefs.set($0, forKey: key); self.changed() })
    }

    func int(_ key: String, _ d: Int) -> Binding<Int> {
        Binding(get: { self.prefs.int(key, default: d) }, set: { self.prefs.set($0, forKey: key); self.changed() })
    }

    var defaultZoom: Binding<Double> {
        Binding(get: {
            let v = (self.prefs.object(forKey: Self.defaultZoomKey) as? Double) ?? 1.0
            return v > 0 ? MioZoomCore.nearest(v) : 1.0
        }, set: { self.prefs.set($0, forKey: Self.defaultZoomKey); self.changed() })
    }

    // MARK: Mio 扩展（MioExtensionSettingsModel）

    func groups(_ section: MioSettingsSection? = nil) -> [MioSettingsGroup] { ext.groups(in: section) }

    /// 写一行（类型校验在 MioKit）；翻译 API Key 存钥匙串，不进 UserDefaults
    func set(_ row: MioSettingsRow, _ value: MioPrefValue) {
        if row.setting.key == MioTranslateModule.secretName {
            kit.translate.setAPIKey(value.stringValue)
            objectWillChange.send()
            return
        }
        ext.apply(row, value)
        objectWillChange.send()
    }

    func toggle(_ row: MioSettingsRow) -> Binding<Bool> {
        Binding(get: { row.value.boolValue ?? false }, set: { self.set(row, .bool($0)) })
    }

    func choice(_ row: MioSettingsRow) -> Binding<MioPrefValue> {
        Binding(get: { row.value }, set: { self.set(row, $0) })
    }

    func trigger(_ row: MioSettingsRow) {
        busy.insert(row.id)
        Task { @MainActor in
            let r = await self.ext.trigger(row)
            self.status[row.id] = r ?? "完成"
            self.busy.remove(row.id)
        }
    }

    // MARK: 容器

    var containers: [MioContainer] { kit.containers.containers }

    @discardableResult
    func run(_ what: String, _ f: () throws -> Void) -> Bool {
        do {
            try f()
            status["containers"] = nil
            objectWillChange.send()
            return true
        } catch {
            status["containers"] = "\(what)失败：\(error)"
            return false
        }
    }

    // MARK: 用户脚本

    var scripts: [MioUserScript] { kit.userScripts.scripts }
}

@MainActor
final class MioMacPrefsState: ObservableObject {
    @Published var pane: MioMacPrefsPane = .general
    @Published var query = ""
}

struct MioMacPreferencesView: View {
    @ObservedObject var model: MioMacSettingsModel
    @ObservedObject var state: MioMacPrefsState

    static let restoreKey = "mio.mac.restoreSession"
    static let verticalTabsKey = "mio.mac.verticalTabs"
    static let appearanceKey = "mio.mac.appearance"   // 0 跟随系统 / 1 浅色 / 2 深色

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    TextField("在设置中查找", text: $state.query)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                }
                .padding(.horizontal, 28)
                .padding(.top, 14)
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if state.query.trimmingCharacters(in: .whitespaces).isEmpty {
                            Text(state.pane.title).font(.system(size: 26, weight: .semibold)).padding(.bottom, 2)
                            content(state.pane)
                        } else {
                            searchResults
                        }
                    }
                    .frame(maxWidth: 680, alignment: .leading)
                    .padding(.horizontal, 36)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(state.pane)
                .transition(.opacity)
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(MioMotion.reduce ? nil : .easeOut(duration: 0.15), value: state.pane)
    }

    // MARK: 左侧分类

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(MioMacPrefsPane.allCases.filter { $0 != .about }) { p in categoryButton(p) }
            Spacer()
            categoryButton(.about)
            Link(destination: URL(string: "https://github.com/mio-co/MioApp")!) {
                Label("Mio 支持", systemImage: "questionmark.circle").font(.system(size: 13))
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
        }
        .padding(.top, 40)
        .padding(.bottom, 16)
        .padding(.horizontal, 10)
        .frame(width: 220)
        .background(Color(nsColor: MioTheme.frame).opacity(0.6))
    }

    private func categoryButton(_ p: MioMacPrefsPane) -> some View {
        let selected = state.pane == p && state.query.isEmpty
        return Button {
            state.query = ""
            state.pane = p
        } label: {
            HStack(spacing: 12) {
                Image(systemName: p.symbol).font(.system(size: 17)).frame(width: 22)
                Text(p.title).font(.system(size: 15, weight: selected ? .semibold : .regular))
                Spacer()
            }
            .foregroundStyle(selected ? Color(nsColor: MioTheme.accent) : Color.primary)
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color(nsColor: MioTheme.accent).opacity(0.10) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("mio.prefs.\(p.rawValue)")
    }

    // MARK: 内容

    @ViewBuilder
    private func content(_ p: MioMacPrefsPane) -> some View {
        switch p {
        case .general: general
        case .home: home
        case .search: search
        case .privacy: privacy
        case .extensions: extensions
        case .containers: MioMacContainersPane(model: model)
        case .userScripts: MioMacUserScriptsPane(model: model)
        case .about: about
        }
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 22) {
            group("启动") {
                Toggle("打开 Mio 时恢复上次的窗口和标签页", isOn: model.bool(Self.restoreKey, true))
            }
            group("标签页") {
                Toggle("使用垂直标签页（侧边栏）", isOn: model.bool(Self.verticalTabsKey, false))
                Text("⌃Tab 依次切换标签页 · ⌘⇧T 恢复关闭的标签页 · ⌘点链接在后台新标签页打开 · 拖出标签条成新窗口")
                    .font(.callout).foregroundStyle(.secondary)
            }
            group("语言与外观") {
                Picker("网站外观", selection: model.int(Self.appearanceKey, 0)) {
                    Text("自动").tag(0); Text("浅色").tag(1); Text("深色").tag(2)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
                Text(MioMotion.reduce ? "系统已开启「减少动态效果」：标签与面板动画已关闭。" : "动画跟随系统「辅助功能 › 显示 › 减少动态效果」设置。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            group("缩放") {
                Picker("默认缩放", selection: model.defaultZoom) {
                    ForEach(MioZoomCore.levels, id: \.self) { z in Text(MioZoomCore.label(z)).tag(z) }
                }
                .frame(maxWidth: 260)
                let sites = model.zoomSites()
                if sites.isEmpty {
                    Text("没有单独设置缩放的网站").font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(sites, id: \.site) { s in
                        HStack { Text(s.site); Spacer(); Text(MioZoomCore.label(s.level)).foregroundStyle(.secondary) }
                    }
                    Button("移除所有网站的缩放") { model.clearZoomSites(); model.changed() }
                }
            }
            group("浏览") {
                LabeledContent("User-Agent") { Text(model.userAgent).font(.caption).textSelection(.enabled).lineLimit(3) }
                LabeledContent("网页开发者工具", value: "⌥⌘I / 右键 › 检查元素")
            }
        }
    }

    private var home: some View {
        VStack(alignment: .leading, spacing: 22) {
            group("新窗口和标签页") {
                LabeledContent("主页和新窗口", value: "Mio 主页（mio://home）")
                LabeledContent("新标签页", value: model.kit.home.newTabURL.absoluteString)
                MioMacCommitField(title: "自定义新标签页（留空 = Mio 主页）", placeholder: "https://…",
                                  value: model.prefs.string(MioHomeModel.legacyNewTabKey, default: "")) { v in
                    let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                    model.prefs.set(t.isEmpty ? nil : t, forKey: MioHomeModel.legacyNewTabKey)
                    model.refresh()
                }
                Text("地址栏显示「Mio」，内容是 MioCore 站点（\(model.kit.home.targetURL.absoluteString)）。MioCore 的本机能力只对 MioCore 来源和 Mio 内置页面开放，其他网站拿不到。")
                    .font(.callout).foregroundStyle(.secondary)
                Button("重置 MioCore 本机权限（相册 / 控制本机 / 文件）") { model.kit.bridge.permissions.reset(); model.refresh() }
            }
            moduleCards(model.groups(.mioCore))
        }
    }

    private var search: some View {
        group("默认搜索引擎") {
            Picker("", selection: .constant(0)) { Text("Google").tag(0) }.labelsHidden().frame(maxWidth: 260)
            Text("地址栏里不像网址的文字用默认搜索引擎搜索。更多搜索引擎即将推出。").font(.callout).foregroundStyle(.secondary)
        }
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 22) {
            group("增强型跟踪保护") {
                Text("广告与跟踪拦截用 WebKit 内容规则（WKContentRuleList）：内置精简列表离线可用，可订阅 AdGuard / EasyList 或添加自定义订阅。地址栏的盾牌可对单个网站关闭拦截。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            moduleCards(model.groups(.privacy))
            group("Cookie 和网站数据") {
                Text("每个容器一份独立的 Cookie / 登录 / 缓存。可在地址栏站点信息里清除单个网站的数据。").font(.callout).foregroundStyle(.secondary)
            }
            group("密码") {
                Text("网页登录使用系统「密码」App / iCloud 钥匙串自动填充，Mio 不单独保存密码。").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var extensions: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("拦截、YouTube 防沉迷、SponsorBlock、翻译、阅读 / 深色、WebRTC、用户脚本、容器都是 Mio 扩展：每项一个开关和子设置，改动在重新载入网页后生效。")
                .foregroundStyle(.secondary)
            moduleCards(model.groups())
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: "m.circle.fill").font(.system(size: 44)).foregroundStyle(Color(nsColor: MioTheme.mio))
                VStack(alignment: .leading) {
                    Text("Mio").font(.title2.weight(.semibold))
                    Text("原生 macOS 预览版 · WebKit · \(model.platformName) · MioKit \(MioKitInfo.version)").foregroundStyle(.secondary)
                }
            }
            Text("界面与操作参考 Firefox 桌面版；Mio 不使用 Firefox 名称和标志，不含 Mozilla 账号、遥测或赞助内容。源码以 MPL-2.0 开源。广告拦截规则转换使用 AdGuard SafariConverterLib（GPL-3.0）；SponsorBlock 数据来自 sponsor.ajay.app（CC BY-NC-SA 4.0）。")
                .font(.callout).foregroundStyle(.secondary)
            Link("github.com/mio-co/MioApp", destination: URL(string: "https://github.com/mio-co/MioApp")!)
        }
    }

    // MARK: 查找

    private struct Entry: Identifiable { let id: String; let title: String; let pane: MioMacPrefsPane }

    private var catalog: [Entry] {
        var e: [Entry] = [
            Entry(id: "restore", title: "恢复上次的窗口和标签页", pane: .general),
            Entry(id: "vtabs", title: "垂直标签页", pane: .general),
            Entry(id: "appearance", title: "网站外观 浅色 深色", pane: .general),
            Entry(id: "zoom", title: "默认缩放 网站缩放", pane: .general),
            Entry(id: "ua", title: "User-Agent 开发者工具", pane: .general),
            Entry(id: "home", title: "主页 新标签页 mio://home MioCore", pane: .home),
            Entry(id: "search", title: "默认搜索引擎 Google", pane: .search),
            Entry(id: "etp", title: "跟踪保护 广告拦截 AdGuard EasyList", pane: .privacy),
            Entry(id: "cookies", title: "Cookie 网站数据 密码", pane: .privacy),
            Entry(id: "containers", title: "容器 站点规则", pane: .containers),
            Entry(id: "userscripts", title: "用户脚本 Tampermonkey Greasemonkey .user.js", pane: .userScripts),
        ]
        for g in model.groups() { e.append(Entry(id: "m." + g.moduleID, title: g.title + " " + g.summary, pane: .extensions)) }
        return e
    }

    private var searchResults: some View {
        let q = state.query.lowercased().trimmingCharacters(in: .whitespaces)
        let hits = catalog.filter { $0.title.lowercased().contains(q) }
        return VStack(alignment: .leading, spacing: 10) {
            Text("搜索结果").font(.system(size: 26, weight: .semibold))
            if hits.isEmpty { Text("没有找到「\(state.query)」的设置").foregroundStyle(.secondary) }
            ForEach(hits) { h in
                Button { state.query = ""; state.pane = h.pane } label: {
                    HStack { Text(h.title).lineLimit(1); Spacer(); Text(h.pane.title).foregroundStyle(.secondary) }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: 组件

    private func group<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        MioMacPrefsGroup(title: title, content: c)
    }

    private func moduleCards(_ groups: [MioSettingsGroup]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(groups) { g in MioMacModuleCard(model: model, group: g) }
        }
    }
}

// MARK: - 共用组件

struct MioMacPrefsGroup<C: View>: View {
    let title: String
    let content: C
    init(title: String, @ViewBuilder content: () -> C) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 16, weight: .semibold))
            VStack(alignment: .leading, spacing: 10) { content }
        }
    }
}

struct MioMacCard<C: View>: View {
    let content: C
    init(@ViewBuilder content: () -> C) { self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))
    }
}

/// 文本框：回车 / 失焦时才提交（不是每个按键都写设置、重装脚本）
struct MioMacCommitField: View {
    let title: String
    let placeholder: String
    var secure = false
    let value: String
    let commit: (String) -> Void
    @State private var text = ""
    @State private var loaded = false
    @FocusState private var focused: Bool

    init(title: String, placeholder: String, secure: Bool = false, value: String, commit: @escaping (String) -> Void) {
        self.title = title; self.placeholder = placeholder; self.secure = secure; self.value = value; self.commit = commit
    }

    var body: some View {
        Group {
            if secure {
                SecureField(title, text: $text, prompt: Text(placeholder))
            } else {
                TextField(title, text: $text, prompt: Text(placeholder))
            }
        }
        .textFieldStyle(.roundedBorder)
        .focused($focused)
        .onAppear { if !loaded { text = value; loaded = true } }
        .onSubmit { if text != value { commit(text) } }
        .onChange(of: focused) { f in if !f && text != value { commit(text) } }
    }
}

/// 一个 Mio 扩展模块：标题 + 简介 + 总开关，打开时显示子设置（由 MioKit 的 MioSettingsRow 生成）
struct MioMacModuleCard: View {
    @ObservedObject var model: MioMacSettingsModel
    let group: MioSettingsGroup

    var body: some View {
        MioMacCard {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: group.symbol).font(.system(size: 16)).frame(width: 22)
                    .foregroundStyle(group.enabled ? Color(nsColor: MioTheme.accent) : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.title).font(.system(size: 14, weight: .semibold))
                    Text(group.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if let t = group.rows.first(where: { $0.role == .moduleToggle }) {
                    Toggle("", isOn: model.toggle(t)).toggleStyle(.switch).labelsHidden()
                        .accessibilityIdentifier("mio.prefs.toggle.\(group.moduleID)")
                } else {
                    Text("常开").font(.callout).foregroundStyle(.secondary)
                }
            }
            let rows = group.rows.filter { $0.role == .setting }
            if !rows.isEmpty {
                Divider()
                ForEach(rows) { r in MioMacSettingRowView(model: model, row: r) }
            }
        }
        .accessibilityIdentifier("mio.prefs.module.\(group.moduleID)")
    }
}

struct MioMacSettingRowView: View {
    @ObservedObject var model: MioMacSettingsModel
    let row: MioSettingsRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch row.setting.kind {
            case .toggle:
                Toggle(row.setting.title, isOn: model.toggle(row))
            case .choice(let options, _):
                Picker(row.setting.title, selection: model.choice(row)) {
                    ForEach(options, id: \.self) { o in Text(o.label).tag(o.value) }
                }
                .frame(maxWidth: 380)
            case .text(_, let placeholder, let secure):
                LabeledContent(row.setting.title) {
                    MioMacCommitField(title: row.setting.title, placeholder: placeholder, secure: secure,
                                      value: secure ? "" : (row.value.stringValue ?? "")) { v in model.set(row, .string(v)) }
                        .labelsHidden()
                        .frame(maxWidth: 340)
                }
            case .stringList(let placeholder):
                MioMacStringListEditor(title: row.setting.title, placeholder: placeholder, items: row.value.stringsValue ?? []) { list in
                    model.set(row, .strings(list))
                }
            case .action(let title):
                HStack(spacing: 10) {
                    Button(title) { model.trigger(row) }.disabled(model.busy.contains(row.id))
                    if model.busy.contains(row.id) { ProgressView().controlSize(.small) }
                    if let s = model.status[row.id] { Text(s).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
                }
            case .info:
                LabeledContent(row.setting.title) { Text(row.detail ?? "").foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
            }
            if let f = row.setting.footer { Text(f).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// 字符串列表（站点白名单、自定义订阅）：每行一个 − 按钮，底部输入框 + 添加
struct MioMacStringListEditor: View {
    let title: String
    let placeholder: String
    let items: [String]
    let commit: ([String]) -> Void
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            if items.isEmpty {
                Text("（空）").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(items, id: \.self) { item in
                HStack {
                    Text(item).font(.system(.body, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { commit(items.filter { $0 != item }) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.04)))
            }
            HStack {
                TextField(placeholder, text: $draft).textFieldStyle(.roundedBorder).onSubmit(add)
                Button("添加", action: add).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func add() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        commit(items + [t])
        draft = ""
    }
}

func mioContainerColor(_ c: MioContainer) -> Color { mioContainerColor(name: c.color) }

func mioContainerColor(name: String) -> Color {
    guard let hex = MioContainerCore.colorHex[name] else { return .gray }
    return Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
}

// MARK: - 容器管理（Firefox Multi-Account Containers 的设置页样子）

struct MioMacContainersPane: View {
    @ObservedObject var model: MioMacSettingsModel
    @State private var newName = ""
    @State private var newColor = "blue"
    @State private var ruleHost = ""
    @State private var ruleContainer = MioContainerCore.defaultId

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(model.groups(.containers)) { g in MioMacModuleCard(model: model, group: g) }
            MioMacPrefsGroup(title: "容器标签页") {
                ForEach(model.containers, id: \.id) { c in MioMacContainerRow(model: model, container: c) }
                HStack(spacing: 8) {
                    colorMenu(selection: newColor) { newColor = $0 }
                    TextField("新容器名称", text: $newName).textFieldStyle(.roundedBorder).frame(maxWidth: 240).onSubmit(create)
                    Button("新建容器", action: create).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let err = model.status["containers"] { Text(err).font(.callout).foregroundStyle(.red) }
                Text("每个容器一份独立的 Cookie / 登录 / 缓存（WKWebsiteDataStore）。右键标签 › 在容器中重新打开；侧边栏底部可新建容器标签。删除容器会关掉它的标签并删除它的网站数据。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            MioMacPrefsGroup(title: "总在此容器打开的网站") {
                let rules = model.kit.containers.siteRules
                if rules.isEmpty { Text("没有站点规则。在网页上打开 Mio 扩展 › 「总在…打开此网站」，或在下面添加。").font(.callout).foregroundStyle(.secondary) }
                ForEach(rules, id: \.host) { r in
                    HStack(spacing: 8) {
                        Image(systemName: "circle.fill").foregroundStyle(mioContainerColor(name: model.kit.containers.container(r.containerId)?.color ?? "gray")).font(.system(size: 9))
                        Text(r.host).font(.system(.body, design: .monospaced))
                        Spacer()
                        Text(model.kit.containers.container(r.containerId)?.name ?? r.containerId).foregroundStyle(.secondary)
                        Button { model.kit.containers.removeSiteRule(r.host); model.refresh() } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
                HStack(spacing: 8) {
                    TextField("example.com", text: $ruleHost).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                    Picker("", selection: $ruleContainer) {
                        ForEach(model.containers, id: \.id) { c in Text(c.name).tag(c.id) }
                    }
                    .labelsHidden().frame(maxWidth: 160)
                    Button("添加规则") {
                        let h = ruleHost
                        if model.run("添加规则", { _ = try model.kit.containers.setSiteRule(h, containerId: ruleContainer) }) { ruleHost = "" }
                    }
                    .disabled(ruleHost.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func create() {
        let n = newName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        let color = newColor
        if model.run("新建容器", { _ = try model.kit.containers.create(name: n, color: color) }) { newName = "" }
    }

    func colorMenu(selection: String, _ pick: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(MioContainerCore.colors, id: \.self) { col in
                Button { pick(col) } label: { Label(MioContainerCore.colorNames[col] ?? col, systemImage: col == selection ? "checkmark.circle.fill" : "circle.fill") }
            }
        } label: {
            Image(systemName: "circle.fill").foregroundStyle(mioContainerColor(name: selection))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

struct MioMacContainerRow: View {
    @ObservedObject var model: MioMacSettingsModel
    let container: MioContainer

    var body: some View {
        HStack(spacing: 10) {
            if container.isDefault {
                Image(systemName: "circle.fill").foregroundStyle(mioContainerColor(container)).font(.system(size: 12))
                Text(container.name)
                Text("默认").font(.caption).foregroundStyle(.secondary)
                Spacer()
            } else {
                Menu {
                    ForEach(MioContainerCore.colors, id: \.self) { col in
                        Button(MioContainerCore.colorNames[col] ?? col) {
                            let id = container.id
                            model.run("改颜色") { _ = try model.kit.containers.update(id, color: col) }
                        }
                    }
                } label: {
                    Image(systemName: "circle.fill").foregroundStyle(mioContainerColor(container))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                MioMacCommitField(title: "名称", placeholder: "容器名称", value: container.name) { v in
                    let id = container.id
                    model.run("改名") { _ = try model.kit.containers.update(id, name: v) }
                }
                .frame(maxWidth: 240)
                Spacer()
                Button(role: .destructive) { remove() } label: { Label("删除", systemImage: "trash") }.buttonStyle(.borderless)
            }
        }
        .accessibilityIdentifier("mio.prefs.container.\(container.id)")
    }

    private func remove() {
        let a = NSAlert()
        a.messageText = "删除容器「\(container.name)」？"
        a.informativeText = "会关掉这个容器里的标签，并删除它的 Cookie、登录和网站数据。"
        a.addButton(withTitle: "删除")
        a.addButton(withTitle: "取消")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let id = container.id
        model.run("删除容器") { _ = try model.kit.containers.remove(id) }
    }
}

// MARK: - 用户脚本管理（Firefox about:addons 的卡片列表样子）

struct MioMacUserScriptsPane: View {
    @ObservedObject var model: MioMacSettingsModel
    @State private var url = ""
    @State private var code = ""
    @State private var showEditor = false
    @State private var message: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(model.groups(.userScripts)) { g in MioMacModuleCard(model: model, group: g) }
            MioMacPrefsGroup(title: "已安装的脚本（\(model.scripts.count)）") {
                if model.scripts.isEmpty {
                    Text("还没有用户脚本。打开任意 .user.js 链接（例如 Greasy Fork 的「安装此脚本」）会提示安装，也可以在下面粘贴地址或代码。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(model.scripts) { s in MioMacUserScriptRow(model: model, script: s) { message = $0 } }
                HStack {
                    Button("检查全部更新") {
                        working = true
                        Task { @MainActor in
                            let r = await MioUserScriptInstaller.updateAll(model.kit.userScripts)
                            working = false
                            var parts: [String] = []
                            if !r.updated.isEmpty { parts.append("已更新：" + r.updated.joined(separator: "、")) }
                            if !r.failed.isEmpty { parts.append("失败：" + r.failed.joined(separator: "、")) }
                            message = parts.isEmpty ? "都是最新版本" : parts.joined(separator: "；")
                            model.refresh()
                        }
                    }
                    .disabled(model.scripts.isEmpty || working)
                    if working { ProgressView().controlSize(.small) }
                }
            }
            MioMacPrefsGroup(title: "安装用户脚本") {
                HStack {
                    TextField("https://…/script.user.js", text: $url).textFieldStyle(.roundedBorder).onSubmit(installURL)
                    Button("从网址安装", action: installURL).disabled(url.trimmingCharacters(in: .whitespaces).isEmpty || working)
                }
                DisclosureGroup("粘贴代码新建", isExpanded: $showEditor) {
                    TextEditor(text: $code)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 160)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.15)))
                    Button("安装") { install(code: code) }.disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
                }
                if let m = message { Text(m).font(.callout).foregroundStyle(.secondary) }
                Text("兼容 Greasemonkey / Tampermonkey：@match @include @exclude @run-at @grant @require @resource @connect；GM_getValue / setValue / xmlhttpRequest / addStyle / openInTab / setClipboard / registerMenuCommand / notification。有 @grant 的脚本在自己的独立环境里运行。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func installURL() {
        guard let u = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)), u.scheme?.hasPrefix("http") == true else {
            message = "请输入 http(s) 地址"
            return
        }
        working = true
        Task { @MainActor in
            do {
                let pkg = try await MioUserScriptInstaller.prepare(url: u)
                _ = model.kit.userScripts.install(pkg)
                message = "已安装「\(pkg.meta.name)」"
                url = ""
            } catch { message = "安装失败：\(error)" }
            working = false
            model.refresh()
        }
    }

    private func install(code: String) {
        working = true
        Task { @MainActor in
            do {
                let pkg = try await MioUserScriptInstaller.prepare(code: code, sourceURL: nil)
                _ = model.kit.userScripts.install(pkg)
                message = "已安装「\(pkg.meta.name)」"
                self.code = ""
                showEditor = false
            } catch { message = "安装失败：\(error)" }
            working = false
            model.refresh()
        }
    }
}

struct MioMacUserScriptRow: View {
    @ObservedObject var model: MioMacSettingsModel
    let script: MioUserScript
    let report: (String) -> Void
    @State private var checking = false

    var body: some View {
        MioMacCard {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "curlybraces.square").font(.system(size: 18)).frame(width: 24)
                    .foregroundStyle(script.enabled ? Color(nsColor: MioTheme.accent) : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(script.meta.name).font(.system(size: 14, weight: .semibold))
                        if !script.meta.version.isEmpty { Text(script.meta.version).font(.caption).foregroundStyle(.secondary) }
                        if script.isolated { Text("独立环境").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Color.primary.opacity(0.07))) }
                    }
                    if !script.meta.description.isEmpty { Text(script.meta.description).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
                    let sites = (script.meta.matches + script.meta.includes)
                    if !sites.isEmpty {
                        Text(sites.prefix(3).joined(separator: "  ") + (sites.count > 3 ? "  …" : ""))
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer()
                Toggle("", isOn: Binding(get: { script.enabled }, set: { on in model.kit.userScripts.setEnabled(script.id, on); model.refresh() }))
                    .toggleStyle(.switch).labelsHidden()
            }
            HStack(spacing: 14) {
                Button("检查更新") { checkUpdate() }.buttonStyle(.link).disabled(checking)
                if checking { ProgressView().controlSize(.small) }
                if let src = script.sourceURL, let u = URL(string: src) { Link("来源", destination: u).font(.callout) }
                Spacer()
                Button(role: .destructive) { remove() } label: { Label("删除", systemImage: "trash") }.buttonStyle(.borderless)
            }
        }
        .accessibilityIdentifier("mio.prefs.userscript.\(script.id)")
    }

    private func checkUpdate() {
        checking = true
        let s = script
        Task { @MainActor in
            do {
                if let pkg = try await MioUserScriptInstaller.checkUpdate(s) {
                    _ = model.kit.userScripts.install(pkg)
                    report("「\(s.meta.name)」已更新到 \(pkg.meta.version)")
                } else {
                    report("「\(s.meta.name)」已是最新版本")
                }
            } catch { report("检查更新失败：\(error)") }
            checking = false
            model.refresh()
        }
    }

    private func remove() {
        let a = NSAlert()
        a.messageText = "删除用户脚本「\(script.meta.name)」？"
        a.informativeText = "脚本和它保存的数据（GM_setValue）都会删除。"
        a.addButton(withTitle: "删除")
        a.addButton(withTitle: "取消")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        model.kit.userScripts.delete(script.id)
        model.refresh()
    }
}
