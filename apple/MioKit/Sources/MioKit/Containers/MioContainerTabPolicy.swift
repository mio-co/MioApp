// MioContainerTabPolicy.swift — 宿主建标签的 web view 时决定它进哪个容器（纯逻辑，Linux 单测）。
//
// iOS（firefox-ios fork）在 Tab.createWebview 里调用：此时标签可能是
//   - 重启 / 会话恢复回来的（有 tabKey 记录，没有父标签）→ 原容器（MioContainerState.tabs，跟 v0.3.x / Mac 同一份 JSON）
//   - 「新建容器标签」「在容器中打开」「在容器中重新打开」→ 显式指定（pending，优先于父标签）
//   - window.open / target=_blank 弹出的（popup）→ 一定是父标签的容器：WebKit 给的 configuration 已经带着父标签的数据存储，换不了
//   - 网页里长按「在新标签页打开」等从某个标签打开的（有父标签）→ 锁定父容器 > 站点规则（模块开着时）> 父容器
//   - 其他（+ 号新标签、外部打开）→ 默认容器。没有父标签时不套站点规则：恢复回来的默认容器标签没有记录，
//     套规则会把它换进另一个容器（和它的会话 / 登录对不上）
// 无痕标签不进容器（nil）。

import Foundation

public enum MioContainerTabPolicy {
    /// nil = 无痕（不记录、用不落盘的存储）
    public static func decide(state: MioContainerState,
                              record: MioTabContainer?,
                              pending: String?,
                              parent: MioTabContainer?,
                              isPopup: Bool,
                              isPrivate: Bool,
                              url: URL?,
                              siteRulesEnabled: Bool) -> MioTabContainer? {
        if isPrivate { return nil }
        if isPopup {
            // 数据存储由 WebKit 定死 = 父标签的
            return state.child(of: parent)
        }
        if let r = record, state.exists(r.containerId) {
            return MioTabContainer(containerId: r.containerId, locked: r.locked)
        }
        if let p = pending, state.exists(p) {
            // 用户在菜单里明确选的容器优先（「在容器中重新打开」的父标签就是旧标签）
            return MioTabContainer(containerId: p, locked: false)
        }
        if let parent = parent {
            if siteRulesEnabled { return state.containerForNewTab(url: url, opener: parent) }
            return state.child(of: parent)
        }
        return .unassigned
    }
}
