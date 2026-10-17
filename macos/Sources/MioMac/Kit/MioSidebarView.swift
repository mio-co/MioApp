// MioSidebarView.swift — iPad / Mac 的 Safari 式侧边栏（SwiftUI，两端共用）：标签页、容器、MioCore。

import SwiftUI

@MainActor
final class MioSidebarModel: ObservableObject {
    struct Tab: Identifiable, Equatable {
        let id: Int
        let title: String
        let host: String
        let containerName: String?
    }

    @Published var tabs: [Tab] = []
    @Published var activeID: Int?
    @Published var containers: [MioContainer] = []
    var onSelectTab: (Int) -> Void = { _ in }
    var onCloseTab: (Int) -> Void = { _ in }
    var onNewTab: (String?) -> Void = { _ in }
    var onHome: () -> Void = {}
}

struct MioSidebarView: View {
    @ObservedObject var model: MioSidebarModel

    var body: some View {
        List {
            Section(header: Text("标签页")) {
                ForEach(model.tabs) { t in
                    Button { model.onSelectTab(t.id) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "globe")
                            VStack(alignment: .leading, spacing: 1) {
                                Text(t.title).lineLimit(1)
                                Text(t.containerName.map { "\(t.host) · \($0)" } ?? t.host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(t.id == model.activeID ? Color.accentColor.opacity(0.18) : Color.clear)
                    .contextMenu { Button("关闭标签页") { model.onCloseTab(t.id) } }
                }
            }
            Section(header: Text("容器")) {
                ForEach([MioContainerCore.defaultContainer] + model.containers, id: \.id) { c in
                    Button { model.onNewTab(c.id) } label: { Label("新标签页 · \(c.name)", systemImage: "plus.square.on.square") }
                        .buttonStyle(.plain)
                }
            }
            Section(header: Text("MioCore")) {
                Button { model.onHome() } label: { Label("Mio 主页", systemImage: "house") }
                    .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
    }
}
