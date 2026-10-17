// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

// Mio: Settings → Mio → 容器. Create / rename / color / icon / delete containers, clear one container's data.
// Same container list as the Mac app's 容器 pane (MioKit MioContainerManager, presets 个人 / 工作 / 购物 / 银行).

import Common
@preconcurrency import MioKit
import SwiftUI
import UIKit

final class MioContainersSetting: Setting {
    override var title: NSAttributedString? {
        guard let theme else { return NSAttributedString(string: MioContainersStrings.title) }
        return NSAttributedString(string: MioContainersStrings.title,
                                  attributes: [.foregroundColor: theme.colors.textPrimary])
    }

    override var status: NSAttributedString? {
        guard let theme else { return nil }
        let text = MioContainerUI.isSupported
            ? "\(MioContainerUI.shared.containers.count - 1) 个容器，登录和 Cookie 互相隔离"
            : "需要 iOS 17"
        return NSAttributedString(string: text, attributes: [.foregroundColor: theme.colors.textSecondary])
    }

    override var accessoryType: UITableViewCell.AccessoryType { return .disclosureIndicator }

    override var accessibilityIdentifier: String? { return "Settings.MioContainers" }

    override func onClick(_ navigationController: UINavigationController?) {
        navigationController?.pushViewController(Self.makeController(), animated: true)
    }

    @MainActor
    static func makeController() -> UIViewController {
        let model = MioContainersViewModel()
        let controller = UIHostingController(rootView: MioContainersView(model: model))
        controller.title = MioContainersStrings.title
        model.host = controller
        return controller
    }
}

enum MioContainersStrings {
    static let title = "容器"
    static let footer = "每个容器有自己的一份 Cookie、登录状态、缓存和网站数据（LocalStorage / IndexedDB），互相看不到。"
        + "用法：长按「+」或标签按钮 ›「新建容器标签」；网页里长按链接 ›「在容器中打开」；"
        + "标签页概览里长按标签或页面菜单 ›「在容器中重新打开」。从容器标签里打开的新标签（target=_blank / window.open）留在同一个容器。"
        + "无痕标签不使用容器。"
    static let defaultFooter = "「默认」就是没有容器的普通标签，原来的登录（包括 MioCore 的 Cloudflare Access）都在这里。"
}

@MainActor
final class MioContainersViewModel: ObservableObject {
    @Published private(set) var containers: [MioContainer] = []
    @Published var error: String?
    @Published var toast: String?
    private var observer: NSObjectProtocol?
    /// The hosting controller (Settings' UINavigationController pushes the edit page; SwiftUI NavigationLink would need
    /// its own NavigationView inside UIKit's navigation bar)
    weak var host: UIViewController?

    init() {
        reload()
        observer = NotificationCenter.default.addObserver(forName: .mioContainersDidChange, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    var supported: Bool { MioContainerUI.isSupported }
    var canCreate: Bool { MioContainerUI.shared.manager.state.canCreate }
    var nextColor: String { MioContainerUI.shared.manager.state.nextColor() }

    func reload() {
        containers = supported ? MioContainerUI.shared.containers : []
    }

    func tabCount(_ c: MioContainer) -> Int { MioContainerUI.shared.openTabCount(c.id) }

    @discardableResult
    func run(_ what: String, _ f: () throws -> Void) -> Bool {
        do {
            try f()
            error = nil
            reload()
            return true
        } catch {
            self.error = "\(what)失败：\(error)"
            return false
        }
    }

    func create(name: String, color: String, icon: String) -> Bool {
        run("新建容器") { _ = try MioContainerUI.shared.manager.create(name: name, color: color, icon: icon) }
    }

    func update(_ id: String, name: String? = nil, color: String? = nil, icon: String? = nil) {
        run("修改容器") { _ = try MioContainerUI.shared.manager.update(id, name: name, color: color, icon: icon) }
    }

    /// Closes the container's tabs (MioContainerUI listens for .mioContainerWillRemove) and deletes its data store.
    func remove(_ id: String) {
        run("删除容器") { _ = try MioContainerUI.shared.manager.remove(id) }
    }

    func edit(_ c: MioContainer) {
        let page = UIHostingController(rootView: MioContainerEditView(model: self, containerID: c.id))
        page.title = c.name
        host?.navigationController?.pushViewController(page, animated: true)
    }

    func popEdit() {
        if let host = host, let nav = host.navigationController, nav.viewControllers.contains(host) {
            nav.popToViewController(host, animated: true)
        }
    }

    func clearData(_ c: MioContainer) {
        Task {
            await MioContainerUI.shared.clearData(c.id)
            self.toast = "已清除「\(c.name)」的 Cookie、登录和网站数据"
        }
    }
}

struct MioContainersView: View {
    @ObservedObject var model: MioContainersViewModel
    @State private var showingNew = false

    var body: some View {
        List {
            if !model.supported {
                Section {
                    Text(MioContainerUI.unsupportedNote).foregroundColor(.secondary)
                }
            } else {
                Section {
                    ForEach(model.containers, id: \.id) { c in
                        if c.isDefault {
                            row(c)
                        } else {
                            Button { model.edit(c) } label: {
                                HStack {
                                    row(c)
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundColor(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("MioContainers.row.\(c.name)")
                        }
                    }
                    Button { showingNew = true } label: { Label("新建容器", systemImage: "plus.circle.fill") }
                        .disabled(!model.canCreate)
                        .accessibilityIdentifier("MioContainers.new")
                } header: {
                    Text("容器")
                } footer: {
                    Text(MioContainersStrings.footer + "\n\n" + MioContainersStrings.defaultFooter)
                }
                if let err = model.error {
                    Section { Text(err).foregroundColor(.red) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .sheet(isPresented: $showingNew) {
            MioContainerNewView(model: model, color: model.nextColor) { showingNew = false }
        }
        .alert(isPresented: Binding(get: { model.toast != nil }, set: { if !$0 { model.toast = nil } })) {
            Alert(title: Text(model.toast ?? ""))
        }
        .onAppear { model.reload() }
    }

    private func row(_ c: MioContainer) -> some View {
        HStack(spacing: 12) {
            MioContainerIconView(container: c, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.isDefault ? "默认" : c.name)
                let n = c.isDefault ? 0 : model.tabCount(c)
                Text(c.isDefault ? "无容器的普通标签" : (n > 0 ? "\(n) 个打开的标签" : "没有打开的标签"))
                    .font(.footnote).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Name + color + icon form, shared by 新建 and 编辑.
struct MioContainerStyleForm: View {
    @Binding var name: String
    @Binding var color: String
    @Binding var icon: String

    private let columns = [GridItem(.adaptive(minimum: 40), spacing: 12)]

    var body: some View {
        Section(header: Text("名称")) {
            TextField("容器名称", text: $name)
                .accessibilityIdentifier("MioContainers.name")
        }
        Section(header: Text("颜色")) {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(MioContainerCore.colors, id: \.self) { col in
                    Button { color = col } label: {
                        ZStack {
                            Circle().fill(Color(uiColor: MioContainerUI.uiColor(col))).frame(width: 30, height: 30)
                            if col == color {
                                Circle().stroke(Color.primary, lineWidth: 2).frame(width: 38, height: 38)
                            }
                        }
                        .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(MioContainerCore.colorNames[col] ?? col)
                    .accessibilityAddTraits(col == color ? .isSelected : [])
                }
            }
            .padding(.vertical, 4)
        }
        Section(header: Text("图标")) {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(MioContainerCore.icons, id: \.self) { ic in
                    Button { icon = ic } label: {
                        Image(systemName: MioContainerCore.iconSymbol(ic))
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(ic == icon ? .white : Color(uiColor: MioContainerUI.uiColor(color)))
                            .frame(width: 38, height: 38)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(ic == icon ? Color(uiColor: MioContainerUI.uiColor(color)) : Color(uiColor: .tertiarySystemFill)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(MioContainerCore.iconNames[ic] ?? ic)
                    .accessibilityAddTraits(ic == icon ? .isSelected : [])
                }
            }
            .padding(.vertical, 4)
        }
    }
}

struct MioContainerNewView: View {
    @ObservedObject var model: MioContainersViewModel
    @State private var name = ""
    @State var color: String
    @State private var icon = "fingerprint"
    let done: () -> Void

    init(model: MioContainersViewModel, color: String, done: @escaping () -> Void) {
        self.model = model
        _color = State(initialValue: color)
        self.done = done
    }

    var body: some View {
        NavigationView {
            Form {
                MioContainerStyleForm(name: $name, color: $color, icon: $icon)
                if let err = model.error {
                    Section { Text(err).foregroundColor(.red) }
                }
            }
            .navigationTitle("新建容器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { done() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        if model.create(name: name, color: color, icon: icon) { done() }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

struct MioContainerEditView: View {
    @ObservedObject var model: MioContainersViewModel
    let containerID: String
    @State private var name = ""
    @State private var color = "blue"
    @State private var icon = "circle"
    @State private var loaded = false
    @State private var confirmClear = false
    @State private var confirmDelete = false

    private var container: MioContainer? { model.containers.first { $0.id == containerID } }

    var body: some View {
        Form {
            MioContainerStyleForm(name: $name, color: $color, icon: $icon)
            Section(footer: Text("清除这个容器的 Cookie、登录状态、缓存和网站数据，容器和它的标签保留（标签会重新载入）。")) {
                Button("清除此容器的数据") { confirmClear = true }
                    .accessibilityIdentifier("MioContainers.clear")
            }
            Section(footer: Text("会关掉这个容器里的 \(container.map { model.tabCount($0) } ?? 0) 个标签，并删除它的全部网站数据。")) {
                Button("删除容器") { confirmDelete = true }
                    .foregroundColor(.red)
                    .accessibilityIdentifier("MioContainers.delete")
            }
            if let err = model.error {
                Section { Text(err).foregroundColor(.red) }
            }
        }
        .navigationTitle(container?.name ?? "容器")
        .onAppear {
            guard !loaded, let c = container else { return }
            loaded = true
            name = c.name
            color = c.color
            icon = c.icon
        }
        .onChange(of: color) { value in model.update(containerID, color: value) }
        .onChange(of: icon) { value in model.update(containerID, icon: value) }
        .onDisappear {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if let c = container, !trimmed.isEmpty, trimmed != c.name { model.update(containerID, name: trimmed) }
        }
        .confirmationDialog("清除「\(container?.name ?? "")」的数据？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清除数据", role: .destructive) { if let c = container { model.clearData(c) } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这个容器里的网站都会退出登录。")
        }
        .alert(isPresented: $confirmDelete) {
            Alert(title: Text("删除容器「\(container?.name ?? "")」？"),
                  message: Text("会关掉它的标签，并删除它的 Cookie、登录和网站数据。此操作不能撤销。"),
                  primaryButton: .destructive(Text("删除")) {
                      model.remove(containerID)
                      model.popEdit()
                  },
                  secondaryButton: .cancel(Text("取消")))
        }
    }
}
