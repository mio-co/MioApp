// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
@preconcurrency import MioKit
import SwiftUI
import UIKit

/// Settings → "Mio 扩展" entry. The page is generated from MioKit's MioExtensionSettingsModel:
/// one section per module (module switch first, sub-settings only while the module is on).
final class MioExtensionsSetting: Setting {
    override var title: NSAttributedString? {
        guard let theme else { return NSAttributedString(string: MioExtensionsStrings.title) }
        return NSAttributedString(string: MioExtensionsStrings.title,
                                  attributes: [.foregroundColor: theme.colors.textPrimary])
    }

    override var status: NSAttributedString? {
        guard let theme else { return nil }
        return NSAttributedString(string: MioExtensionsStrings.subtitle,
                                  attributes: [.foregroundColor: theme.colors.textSecondary])
    }

    override var accessoryType: UITableViewCell.AccessoryType { return .disclosureIndicator }

    override var accessibilityIdentifier: String? { return "Settings.MioExtensions" }

    override func onClick(_ navigationController: UINavigationController?) {
        let model = MioExtensionsViewModel(model: MioKitHost.shared.kit.settingsModel, kit: MioKitHost.shared.kit)
        let controller = UIHostingController(rootView: MioExtensionsView(viewModel: model))
        controller.title = MioExtensionsStrings.title
        navigationController?.pushViewController(controller, animated: true)
    }
}

enum MioExtensionsStrings {
    static let title = "Mio 扩展"
    static let subtitle = "广告拦截、YouTube 防沉迷、翻译、用户脚本等"
}

@MainActor
final class MioExtensionsViewModel: ObservableObject {
    @Published private(set) var groups: [MioSettingsGroup] = []
    @Published var toast: String?
    private let model: MioExtensionSettingsModel
    private let kit: MioKitContainer

    init(model: MioExtensionSettingsModel, kit: MioKitContainer) {
        self.model = model
        self.kit = kit
        reload()
    }

    func reload() { groups = model.groups() }

    func set(_ row: MioSettingsRow, _ value: MioPrefValue) {
        if case .text(_, _, let secure) = row.setting.kind, secure {
            // Secrets (translate API key) go to the keychain, never to UserDefaults.
            kit.translate.setAPIKey(value.stringValue?.isEmpty == false ? value.stringValue : nil)
            toast = "已保存到钥匙串"
        } else {
            model.apply(row, value)
        }
        reload()
    }

    func trigger(_ row: MioSettingsRow) {
        Task {
            let message = await model.trigger(row)
            self.toast = message ?? "完成"
            self.reload()
        }
    }
}

struct MioExtensionsView: View {
    @ObservedObject var viewModel: MioExtensionsViewModel

    var body: some View {
        List {
            ForEach(viewModel.groups) { group in
                Section(header: Label(group.title, systemImage: group.symbol),
                        footer: footer(for: group)) {
                    ForEach(group.rows) { row in
                        MioSettingRowView(row: row, viewModel: viewModel)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .alert(isPresented: Binding(get: { viewModel.toast != nil }, set: { if !$0 { viewModel.toast = nil } })) {
            Alert(title: Text(viewModel.toast ?? ""))
        }
        .onAppear { viewModel.reload() }
    }

    private func footer(for group: MioSettingsGroup) -> some View {
        let notes = group.rows.compactMap { $0.setting.footer }
        return Text(notes.isEmpty ? group.summary : notes.joined(separator: "\n"))
    }
}

struct MioSettingRowView: View {
    let row: MioSettingsRow
    @ObservedObject var viewModel: MioExtensionsViewModel
    @State private var text = ""
    @State private var newItem = ""

    var body: some View {
        content.accessibilityIdentifier("MioExtensions.\(row.id)")
    }

    @ViewBuilder
    private var content: some View {
        switch row.setting.kind {
        case .toggle:
            Toggle(isOn: Binding(get: { row.value.boolValue ?? false },
                                 set: { viewModel.set(row, .bool($0)) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.setting.title).fontWeight(row.role == .moduleToggle ? .semibold : .regular)
                    if row.role == .moduleToggle, let detail = row.detail {
                        Text(detail).font(.footnote).foregroundColor(.secondary)
                    }
                }
            }
        case .choice(let options, _):
            Picker(row.setting.title, selection: Binding(
                get: { options.firstIndex { $0.value == row.value } ?? 0 },
                set: { index in if options.indices.contains(index) { viewModel.set(row, options[index].value) } }
            )) {
                ForEach(options.indices, id: \.self) { index in Text(options[index].label).tag(index) }
            }
        case .text(_, let placeholder, let secure):
            VStack(alignment: .leading, spacing: 4) {
                Text(row.setting.title).font(.footnote).foregroundColor(.secondary)
                Group {
                    if secure {
                        SecureField(placeholder, text: $text)
                    } else {
                        TextField(placeholder, text: $text)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { viewModel.set(row, .string(text)) }
                .onAppear { text = secure ? "" : (row.value.stringValue ?? "") }
            }
        case .stringList(let placeholder):
            let list = row.value.stringsValue ?? []
            VStack(alignment: .leading, spacing: 6) {
                Text(row.setting.title).font(.footnote).foregroundColor(.secondary)
                ForEach(list, id: \.self) { item in
                    HStack {
                        Text(item).lineLimit(1)
                        Spacer()
                        Button(role: .destructive) {
                            viewModel.set(row, .strings(list.filter { $0 != item }))
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField(placeholder, text: $newItem)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("添加") {
                        viewModel.set(row, .strings(list + [newItem]))
                        newItem = ""
                    }
                    .buttonStyle(.borderless)
                    .disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        case .action(let title):
            Button(title) { viewModel.trigger(row) }
        case .info:
            VStack(alignment: .leading, spacing: 2) {
                Text(row.setting.title)
                if let detail = row.detail {
                    Text(detail).font(.footnote).foregroundColor(.secondary)
                }
            }
        }
    }
}
