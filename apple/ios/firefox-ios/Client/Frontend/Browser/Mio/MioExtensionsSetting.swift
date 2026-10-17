// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import SwiftUI
import UIKit

/// Settings → "Mio 扩展" entry. Placeholder page: the module list and their switches come from MioKit
/// (`apple/MioKit`, line C). Until it is linked, the page lists the planned modules read-only.
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
        let controller = UIHostingController(rootView: MioExtensionsPlaceholderView())
        controller.title = MioExtensionsStrings.title
        navigationController?.pushViewController(controller, animated: true)
    }
}

enum MioExtensionsStrings {
    static let title = "Mio 扩展"
    static let subtitle = "广告拦截、YouTube 防沉迷、翻译、用户脚本等"
}

/// Module ids follow the v0.4.0 plan; MioKit owns the real registry and settings keys.
struct MioExtensionsPlaceholderView: View {
    private struct Module: Identifiable {
        let id: String
        let name: String
        let detail: String
    }

    private let modules: [Module] = [
        Module(id: "adblock", name: "广告 / 跟踪拦截", detail: "WKContentRuleList，可导入 EasyList / AdGuard 列表"),
        Module(id: "youtubeFocus", name: "YouTube 防沉迷", detail: "隐藏推荐、Shorts 等"),
        Module(id: "sponsorBlock", name: "SponsorBlock", detail: "跳过视频中的赞助片段"),
        Module(id: "translate", name: "翻译", detail: "整页翻译"),
        Module(id: "webrtc", name: "WebRTC 控制", detail: "防止 IP 泄露"),
        Module(id: "readerDark", name: "阅读 / 强制深色", detail: "阅读模式与网页强制深色"),
        Module(id: "userScripts", name: "用户脚本", detail: "安装自己的脚本插件"),
        Module(id: "containers", name: "容器", detail: "按标签页隔离 Cookie 与登录")
    ]

    var body: some View {
        List {
            Section(footer: Text("开关与子设置由 MioKit 提供，接入后在这里生效。")) {
                ForEach(modules) { module in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(module.name)
                            Text(module.detail).font(.footnote).foregroundColor(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: .constant(false))
                            .labelsHidden()
                            .disabled(true)
                    }
                    .accessibilityIdentifier("MioExtensions.\(module.id)")
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}
