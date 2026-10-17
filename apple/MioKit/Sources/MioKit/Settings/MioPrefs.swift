// MioPrefs.swift — 设置存储。生产环境 = UserDefaults.standard（沿用 v0.3.x 的 key，升级后设置不丢）；单测 = MioMemoryPrefs。
//
// v0.3.x 已有、MioKit 继续使用的 key（不要改名）：
//   mio.adblock.enabled / mio.adblock.allowlist
//   mio.browser.youtubeFocus / mio.browser.youtubeFocusInterval / mio.browser.youtubeFocusPlayables / mio.browser.backgroundPlayback
//   mio.media.sponsorBlock / mio.media.sb.<category> / mio.media.pipButton / mio.media.nowPlaying
//   mio.translate.{target,engine,display,autoSites,selection,youtube,ytSubs,openaiBase,openaiModel,openaiPrompt}
//   mio.webrtc.enabled / mio.webrtc.allowlist
//   mio.reader.{theme,font,fontSize} / mio.dark.{global,sites,nativeHosts} / mio.save.category
//   mio.containers.state / mio.tabs.newTabURL / mio.tabs.session
// v0.4.0 新增（前缀 mio.kit.* / mio.core.* / mio.bridge.* / mio.userscripts.*）见各模块。

import Foundation

public protocol MioPrefs: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: MioPrefs {}

/// 单测 / 预览用的内存存储
public final class MioMemoryPrefs: MioPrefs {
    public private(set) var values: [String: Any] = [:]
    public init(_ v: [String: Any] = [:]) { values = v }
    public func object(forKey key: String) -> Any? { values[key] }
    public func set(_ value: Any?, forKey key: String) {
        if let value = value { values[key] = value } else { values.removeValue(forKey: key) }
    }
}

public extension MioPrefs {
    func bool(_ key: String, default d: Bool) -> Bool {
        if let b = object(forKey: key) as? Bool { return b }
        if let n = object(forKey: key) as? NSNumber { return n.boolValue }
        return d
    }
    func int(_ key: String, default d: Int) -> Int {
        if let i = object(forKey: key) as? Int { return i }
        if let n = object(forKey: key) as? NSNumber { return n.intValue }
        if let s = object(forKey: key) as? String, let i = Int(s) { return i }
        return d
    }
    func string(_ key: String, default d: String) -> String { (object(forKey: key) as? String) ?? d }
    func strings(_ key: String) -> [String] { (object(forKey: key) as? [String]) ?? (object(forKey: key) as? [Any])?.compactMap { $0 as? String } ?? [] }
    func dictionary(_ key: String) -> [String: Any] { (object(forKey: key) as? [String: Any]) ?? [:] }

    /// 读一个声明式设置项的当前值（类型不对 / 没设过 → 默认值）
    func value(for setting: MioModuleSetting) -> MioPrefValue {
        switch setting.kind {
        case .toggle(let d): return .bool(bool(setting.key, default: d))
        case .choice(let options, let d):
            let raw: MioPrefValue?
            switch d {
            case .int: raw = (object(forKey: setting.key) as? Int).map(MioPrefValue.int) ?? (object(forKey: setting.key) as? NSNumber).map { .int($0.intValue) }
            case .string: raw = (object(forKey: setting.key) as? String).map(MioPrefValue.string)
            default: raw = nil
            }
            if let r = raw, options.contains(where: { $0.value == r }) { return r }
            return d
        case .text(let d, _, _): return .string(string(setting.key, default: d))
        case .stringList: return .strings(strings(setting.key))
        case .action, .info: return .none
        }
    }

    func setValue(_ v: MioPrefValue, forKey key: String) {
        switch v {
        case .bool(let b): set(b, forKey: key)
        case .int(let i): set(i, forKey: key)
        case .string(let s): set(s, forKey: key)
        case .strings(let a): set(a, forKey: key)
        case .none: set(nil, forKey: key)
        }
    }
}

/// 设置值（声明式设置项用）
public enum MioPrefValue: Hashable, Codable {
    case none
    case bool(Bool)
    case int(Int)
    case string(String)
    case strings([String])

    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var intValue: Int? { if case .int(let i) = self { return i }; return nil }
    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var stringsValue: [String]? { if case .strings(let s) = self { return s }; return nil }
}

/// 设置变化通知。名字与 v0.3.x 的 .mioBrowserSettingsDidChange 相同：宿主监听它，对所有标签重装模块脚本（下次加载生效）。
public extension Notification.Name {
    static let mioSettingsDidChange = Notification.Name("mio.browser.settingsDidChange")
}
