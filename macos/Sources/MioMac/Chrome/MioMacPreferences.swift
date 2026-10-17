// MioMacPreferences.swift — Firefox about:preferences 风格的设置窗口（SwiftUI，Mac 专用外观；数据与绑定沿用共享的 MioSettingsModel）：
//   左侧大图标分类（常规 · 主页 · 搜索 · 隐私与安全 · Mio 扩展 · 容器），左下「关于 Mio」；右侧可滚动内容 + 顶部「在设置中查找」。
//   Mio 扩展页：每个模块一张卡片（开关 + 子设置，按 MioModule 声明自动生成）；还没迁移的扩展显示为「即将推出」占位。

import SwiftUI
import AppKit

enum MioMacPrefsPane: String, CaseIterable, Identifiable {
    case general, home, search, privacy, extensions, containers, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "常规"
        case .home: return "主页"
        case .search: return "搜索"
        case .privacy: return "隐私与安全"
        case .extensions: return "Mio 扩展"
        case .containers: return "容器"
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
        case .about: return "info.circle"
        }
    }

    /// 共享设置分区 → 本窗口的分类（模块菜单「…设置」跳转用）
    init(section: MioSettingsSection) {
        switch section {
        case .general, .tabs, .websites, .advanced, .autofill: self = .general
        case .search: self = .search
        case .privacy: self = .privacy
        case .containers: self = .containers
        case .modules, .userScripts: self = .extensions
        case .mioCore: self = .home
        }
    }
}

/// 还没迁移进 MioKit 的扩展（线路 C 负责逻辑；这里只是设置页 / 扩展面板里的占位）
struct MioMacPlannedExtension: Identifiable {
    let id: String
    let title: String
    let summary: String
    let symbol: String

    static let all: [MioMacPlannedExtension] = [
        .init(id: "adblock", title: "广告与跟踪拦截", summary: "WKContentRuleList 内容规则，可导入 EasyList / AdGuard 列表。", symbol: "shield.lefthalf.filled"),
        .init(id: "sponsorblock", title: "SponsorBlock", summary: "自动跳过 YouTube 视频里的赞助片段。", symbol: "forward.end"),
        .init(id: "translate", title: "翻译", summary: "整页翻译与划词翻译。", symbol: "character.bubble"),
        .init(id: "reader", title: "阅读视图 / 强制深色", summary: "去掉干扰的阅读模式，按站点强制深色。", symbol: "doc.plaintext"),
        .init(id: "userscripts", title: "用户脚本", summary: "安装 .user.js（Tampermonkey 兼容 GM API）。", symbol: "curlybraces"),
    ]
}

@MainActor
final class MioMacPrefsState: ObservableObject {
    @Published var pane: MioMacPrefsPane = .general
    @Published var query = ""
}

struct MioMacPreferencesView: View {
    @ObservedObject var model: MioSettingsModel
    @ObservedObject var state: MioMacPrefsState
    @State private var newContainerName = ""

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
        case .containers: containers
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
                LabeledContent("新标签页", value: "Mio 主页（mio://home）")
                TextField("自定义主页地址（留空 = MioCore 站点）", text: model.string(MioCoreModule.newTabKey, ""), prompt: Text(MioMacHome.defaultLoadURL))
                    .textFieldStyle(.roundedBorder)
                Text("地址栏显示「Mio」。MioCore 的本机能力（相册同步、控制本机等）只对 MioCore 来源开放，其他网站拿不到。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            moduleCards(model.registry.modules(in: .mioCore), planned: [])
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
                Text("广告与跟踪拦截由「Mio 扩展」提供（迁移中）。").foregroundStyle(.secondary)
                Button("打开 Mio 扩展") { state.pane = .extensions }
            }
            moduleCards(model.registry.modules(in: .privacy), planned: [])
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
            Text("拦截、YouTube 防沉迷、WebRTC 等功能都在 Mio 扩展里：每项一个开关，改动在重新载入网页后生效。")
                .foregroundStyle(.secondary)
            moduleCards(model.registry.modules.filter { $0.section == .modules || $0.section == .privacy }, planned: MioMacPlannedExtension.all)
        }
    }

    private var containers: some View {
        group("容器标签页") {
            ForEach([MioContainerCore.defaultContainer] + model.containers(), id: \.id) { c in
                HStack(spacing: 10) {
                    Image(systemName: "circle.fill").foregroundStyle(color(c))
                    Text(c.name)
                    Spacer()
                }
            }
            HStack {
                TextField("新容器名称", text: $newContainerName).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Button("新建") {
                    let n = newContainerName.trimmingCharacters(in: .whitespaces)
                    guard !n.isEmpty else { return }
                    model.createContainer(n)
                    newContainerName = ""
                    model.changed()
                }
            }
            Text("每个容器一份独立的 Cookie / 登录 / 缓存。右键标签 › 在容器中重新打开。").font(.callout).foregroundStyle(.secondary)
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: "m.circle.fill").font(.system(size: 44)).foregroundStyle(Color(nsColor: MioTheme.mio))
                VStack(alignment: .leading) {
                    Text("Mio").font(.title2.weight(.semibold))
                    Text("原生 macOS 预览版 · WebKit · \(model.platformName)").foregroundStyle(.secondary)
                }
            }
            Text("界面与操作参考 Firefox 桌面版；Mio 不使用 Firefox 名称和标志，不含 Mozilla 账号、遥测或赞助内容。源码以 MPL-2.0 开源。")
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
            Entry(id: "home", title: "主页 新标签页 mio://home", pane: .home),
            Entry(id: "search", title: "默认搜索引擎 Google", pane: .search),
            Entry(id: "etp", title: "跟踪保护 广告拦截", pane: .privacy),
            Entry(id: "cookies", title: "Cookie 网站数据 密码", pane: .privacy),
            Entry(id: "containers", title: "容器", pane: .containers),
        ]
        for m in model.registry.modules { e.append(Entry(id: "m." + m.id, title: m.title + " " + m.summary, pane: .extensions)) }
        for p in MioMacPlannedExtension.all { e.append(Entry(id: "p." + p.id, title: p.title + " " + p.summary, pane: .extensions)) }
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
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 16, weight: .semibold))
            VStack(alignment: .leading, spacing: 10) { c() }
        }
    }

    private func moduleCards(_ modules: [MioModule], planned: [MioMacPlannedExtension]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(modules, id: \.id) { m in
                card {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(m.title).font(.system(size: 14, weight: .semibold))
                            Text(m.summary).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if m.enabledKey != nil {
                            Toggle("", isOn: model.enabled(m)).toggleStyle(.switch).labelsHidden()
                        } else {
                            Text("常开").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    if !m.settings.isEmpty && m.isEnabled(model.prefs) {
                        Divider()
                        ForEach(m.settings) { s in settingRow(s) }
                    }
                }
                .accessibilityIdentifier("mio.prefs.module.\(m.id)")
            }
            ForEach(planned) { p in
                card {
                    HStack(alignment: .top) {
                        Image(systemName: p.symbol).font(.system(size: 16)).frame(width: 22).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(p.title).font(.system(size: 14, weight: .semibold))
                            Text(p.summary).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("即将推出").font(.caption.weight(.medium)).padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                        Toggle("", isOn: .constant(false)).toggleStyle(.switch).labelsHidden().disabled(true)
                    }
                }
                .opacity(0.75)
            }
        }
    }

    private func card<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) { c() }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))
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
            .frame(maxWidth: 360)
        case .text(let d, let placeholder):
            TextField(s.title, text: model.string(s.key, d), prompt: Text(placeholder)).textFieldStyle(.roundedBorder)
        }
        if let f = s.footer { Text(f).font(.caption).foregroundStyle(.secondary) }
    }

    private func color(_ c: MioContainer) -> Color {
        guard let hex = MioContainerCore.colorHex[c.color] else { return .gray }
        return Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
