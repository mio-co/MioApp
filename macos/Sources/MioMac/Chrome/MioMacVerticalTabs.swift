// MioMacVerticalTabs.swift — Firefox 新侧边栏的「垂直标签页」（SwiftUI）：
//   固定标签图标网格在顶部、标签列表（悬停高亮、悬停出现关闭按钮、拖动排序）、底部「新建标签页」与容器；
//   插入 / 删除 / 选中都带弹簧动画，「减少动态效果」时直接到位。侧边栏本身的滑入滑出由窗口控制器做（宽度动画）。

import SwiftUI
import AppKit

@MainActor
final class MioMacVerticalTabsModel: ObservableObject {
    struct Tab: Identifiable, Equatable {
        let id: Int
        var title: String
        var host: String
        var pinned: Bool
        var loading: Bool
        var audible: Bool
        var muted: Bool
        var isHome: Bool
        var favicon: NSImage?
        var containerColor: NSColor?

        static func == (a: Tab, b: Tab) -> Bool {
            a.id == b.id && a.title == b.title && a.host == b.host && a.pinned == b.pinned && a.loading == b.loading
                && a.audible == b.audible && a.muted == b.muted && a.isHome == b.isHome && a.favicon === b.favicon && a.containerColor == b.containerColor
        }
    }

    @Published var tabs: [Tab] = []
    @Published var activeID: Int?
    @Published var containers: [MioContainer] = []
    @Published var reduceMotion = MioMotion.reduce
    var onSelect: (Int) -> Void = { _ in }
    var onClose: (Int) -> Void = { _ in }
    var onNewTab: (String?) -> Void = { _ in }
    var onMove: (Int, Int) -> Void = { _, _ in }
    var onHome: () -> Void = {}
    var onToggleMute: (Int) -> Void = { _ in }
}

struct MioMacVerticalTabsView: View {
    @ObservedObject var model: MioMacVerticalTabsModel
    @State private var hovered: Int?

    private var anim: Animation? { model.reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86) }

    var body: some View {
        VStack(spacing: 0) {
            let pinned = model.tabs.filter(\.pinned)
            if !pinned.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 38, maximum: 48), spacing: 6)], spacing: 6) {
                    ForEach(pinned) { t in
                        favicon(t)
                            .frame(width: 38, height: 34)
                            .background(RoundedRectangle(cornerRadius: 6).fill(background(t)))
                            .onTapGesture { model.onSelect(t.id) }
                            .onHover { h in withAnimation(model.reduceMotion ? nil : .easeOut(duration: 0.12)) { hovered = h ? t.id : (hovered == t.id ? nil : hovered) } }
                            .help(t.title)
                            .transition(model.reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                Divider().padding(.horizontal, 8)
            }
            List {
                ForEach(model.tabs.filter { !$0.pinned }) { t in
                    row(t)
                        .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
                        .listRowSeparator(.hidden)
                        .transition(model.reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .leading).combined(with: .opacity), removal: .opacity))
                }
                .onMove { from, to in
                    let unpinned = model.tabs.filter { !$0.pinned }
                    guard let f = from.first, unpinned.indices.contains(f) else { return }
                    let offset = model.tabs.count - unpinned.count
                    model.onMove(unpinned[f].id, offset + (to > f ? to - 1 : to))
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            Divider()
            HStack(spacing: 6) {
                Button { model.onNewTab(nil) } label: {
                    Label("新建标签页", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(MioMacSidebarButtonStyle())
                Menu {
                    ForEach([MioContainerCore.defaultContainer] + model.containers, id: \.id) { c in
                        Button(c.name) { model.onNewTab(c.id) }
                    }
                    Divider()
                    Button("Mio 主页") { model.onHome() }
                } label: { Image(systemName: "square.stack.3d.up") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 28)
                .help("在容器中新建标签页")
            }
            .padding(8)
        }
        .animation(anim, value: model.tabs)
        .animation(anim, value: model.activeID)
        .background(Color(nsColor: MioTheme.frame))
        .accessibilityIdentifier("mio.verticalTabs")
    }

    @ViewBuilder
    private func favicon(_ t: MioMacVerticalTabsModel.Tab) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if t.loading {
                    ProgressView().controlSize(.small)
                } else if t.isHome {
                    Image(systemName: "m.circle.fill").foregroundStyle(Color(nsColor: MioTheme.mio)).font(.system(size: 15, weight: .semibold))
                } else if let f = t.favicon {
                    Image(nsImage: f).resizable().interpolation(.high).frame(width: 16, height: 16)
                } else {
                    Image(systemName: "globe").foregroundStyle(.secondary)
                }
            }
            .frame(width: 16, height: 16)
            if t.audible || t.muted {
                Image(systemName: t.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 7)).foregroundStyle(.secondary).offset(x: 6, y: -5)
            }
        }
    }

    private func background(_ t: MioMacVerticalTabsModel.Tab) -> Color {
        if t.id == model.activeID { return Color(nsColor: MioTheme.selectedTab) }
        if t.id == hovered { return Color(nsColor: MioTheme.hoverTab) }
        return .clear
    }

    private func row(_ t: MioMacVerticalTabsModel.Tab) -> some View {
        HStack(spacing: 8) {
            favicon(t)
            Text(t.title).lineLimit(1).font(.system(size: 12.5, weight: t.id == model.activeID ? .medium : .regular))
            Spacer(minLength: 0)
            if t.audible || t.muted {
                Button { model.onToggleMute(t.id) } label: { Image(systemName: t.muted ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.system(size: 10)) }
                    .buttonStyle(.plain).help(t.muted ? "取消静音" : "静音")
            }
            Button { model.onClose(t.id) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 18, height: 18) }
                .buttonStyle(.plain)
                .opacity(hovered == t.id || t.id == model.activeID ? 1 : 0)
                .help("关闭标签页")
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(background(t))
                .shadow(color: .black.opacity(t.id == model.activeID ? 0.12 : 0), radius: 1.5, y: 0.5)
        )
        .overlay(alignment: .leading) {
            if let c = t.containerColor {
                RoundedRectangle(cornerRadius: 1).fill(Color(nsColor: c)).frame(width: 3, height: 16).padding(.leading, 1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.onSelect(t.id) }
        .onHover { h in withAnimation(model.reduceMotion ? nil : .easeOut(duration: 0.12)) { hovered = h ? t.id : (hovered == t.id ? nil : hovered) } }
        .help(t.host.isEmpty ? t.title : "\(t.title)\n\(t.host)")
    }
}

struct MioMacSidebarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.06)))
            .contentShape(Rectangle())
    }
}
