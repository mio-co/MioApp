// MioExtensionSettingsModel.swift — 由模块描述生成设置页的数据模型（「Mio 扩展」一页：每个模块一个开关 + 子设置）。
// 只给数据，不画 UI：iOS（SwiftUI / UIKit）和 Mac（SwiftUI 设置窗口）各自把 rows 画成 Toggle / Picker / TextField / 列表 / 按钮。
//
//   let model = MioExtensionSettingsModel(registry: registry)
//   for group in model.groups() { header(group.title, group.summary); for row in group.rows { draw(row) } }
//   用户改了值 → model.apply(row, .bool(true))（写 prefs + 发 .mioSettingsDidChange）→ 重新取 groups() 刷新（子设置的显示条件会变）

import Foundation

public struct MioSettingsRow: Identifiable, Hashable {
    public enum Role: Hashable {
        /// 模块总开关（key = module.enabledKey）
        case moduleToggle
        /// 子设置
        case setting
    }
    public let moduleID: String
    public let role: Role
    public let setting: MioModuleSetting
    public let value: MioPrefValue
    /// .info 行的文字 / 模块总开关的简介
    public let detail: String?
    public var id: String { moduleID + "|" + setting.key }
}

public struct MioSettingsGroup: Identifiable, Hashable {
    public let moduleID: String
    public let title: String
    public let summary: String
    public let symbol: String
    public let section: MioSettingsSection
    public let enabled: Bool
    public let rows: [MioSettingsRow]
    public var id: String { moduleID }
}

public final class MioExtensionSettingsModel {
    public let registry: MioModuleRegistry
    public init(registry: MioModuleRegistry) { self.registry = registry }

    /// 「Mio 扩展」页：全部模块（section 过滤可选，例如只要 .privacy 里的模块）
    public func groups(in section: MioSettingsSection? = nil) -> [MioSettingsGroup] {
        registry.modules.filter { section == nil || $0.section == section }.map(group(for:))
    }

    public func group(for m: MioModule) -> MioSettingsGroup {
        let prefs = registry.prefs
        let on = m.isEnabled(prefs)
        var rows: [MioSettingsRow] = []
        if let k = m.enabledKey {
            rows.append(MioSettingsRow(moduleID: m.id, role: .moduleToggle,
                                       setting: MioModuleSetting(key: k, title: m.title, kind: .toggle(default: m.defaultEnabled)),
                                       value: .bool(on), detail: m.summary))
        }
        // 模块关掉时只显示总开关（子设置隐藏，与 Firefox / Safari 扩展设置一致）
        if on {
            for s in m.settings where isVisible(s, prefs: prefs) {
                let detail: String? = { if case .info = s.kind { return m.settingStatus(s.key, prefs: prefs) }; return nil }()
                rows.append(MioSettingsRow(moduleID: m.id, role: .setting, setting: s, value: prefs.value(for: s), detail: detail))
            }
        }
        return MioSettingsGroup(moduleID: m.id, title: m.title, summary: m.summary, symbol: m.symbol, section: m.section, enabled: on, rows: rows)
    }

    func isVisible(_ s: MioModuleSetting, prefs: MioPrefs) -> Bool {
        guard let c = s.visibleWhen else { return true }
        let other = registry.modules.flatMap { $0.settings }.first { $0.key == c.key }
        let v: MioPrefValue = other.map { prefs.value(for: $0) } ?? {
            if case .bool = c.equals { return .bool(prefs.bool(c.key, default: false)) }
            return MioPrefValue.none
        }()
        return v == c.equals
    }

    /// 用户改了一行：校验类型后写入。返回 false = 值不合法（选项外 / 类型不对），什么也没写
    @discardableResult
    public func apply(_ row: MioSettingsRow, _ value: MioPrefValue) -> Bool {
        switch (row.setting.kind, value) {
        case (.toggle, .bool): break
        case (.choice(let options, _), _): guard options.contains(where: { $0.value == value }) else { return false }
        case (.text, .string): break
        case (.stringList, .strings(let list)):
            let cleaned = Array(NSOrderedSet(array: list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })) as? [String] ?? []
            registry.set(.strings(cleaned), forKey: row.setting.key)
            return true
        default: return false
        }
        if row.role == .moduleToggle, let b = value.boolValue {
            registry.setEnabled(row.moduleID, b)
        } else {
            registry.set(value, forKey: row.setting.key)
        }
        return true
    }

    /// .action 行被点击
    public func trigger(_ row: MioSettingsRow) async -> String? {
        guard case .action = row.setting.kind else { return nil }
        return await registry.performSettingAction(moduleID: row.moduleID, key: row.setting.key)
    }
}
