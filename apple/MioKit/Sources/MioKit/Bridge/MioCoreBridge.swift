// MioCoreBridge.swift — MioCore ↔ App 本机桥（API 定义、版本、权限、分发）。只依赖 Foundation；WebKit 适配见 MioCoreBridgeHandler.swift。
//
// 页面端（只在 MioCore / mio:// 页面里可用，其他网站调用一律被拒）：
//   const r = await window.webkit.messageHandlers.mio.postMessage({ v: 1, id: '1', method: 'ping', params: {} })
//   → { v: 1, id: '1', ok: true, result: { pong: true, api: 1, ... } }
//   → { v: 1, id: '1', ok: false, error: { code: 'forbidden' | 'unsupported_version' | 'unknown_method' | 'not_implemented'
//                                         | 'permission_denied' | 'bad_request' | 'failed', message } }
//   注入的小封装：await window.Mio.call('ping')（MioCoreBridgeHandler.shimScript，只在允许的来源里定义）
//
// 版本规则：v 是整数主版本。App 支持 supportedVersions 里的版本；页面先 ping 拿 api / apiVersions 再决定调用方式。
// 新方法只加不改；改语义必须升 v。

import Foundation

public enum MioBridgePermission: String, CaseIterable, Codable {
    /// ping / getDeviceInfo：允许来源默认有
    case basic
    /// openTab：默认有
    case tabs
    /// saveToMio：默认有
    case save
    /// 相册读取 / 同步（TODO）：必须用户明确允许
    case photos
    /// 控制本机（剪贴板、通知、媒体、远程控制电脑 / 手机）（TODO）：必须用户明确允许
    case deviceControl
    /// 文件选择 / 读写（TODO）：必须用户明确允许
    case files

    /// 不需要询问用户就给允许来源的权限
    public var grantedByDefault: Bool {
        switch self {
        case .basic, .tabs, .save: return true
        case .photos, .deviceControl, .files: return false
        }
    }

    public var title: String {
        switch self {
        case .basic: return "基本信息"
        case .tabs: return "打开标签页"
        case .save: return "保存到 Mio"
        case .photos: return "访问相册"
        case .deviceControl: return "控制本机"
        case .files: return "访问文件"
        }
    }
}

public enum MioBridgeMethod: String, CaseIterable {
    case ping, getDeviceInfo, saveToMio, openTab
    // —— 只定义接口，未实现（返回 not_implemented）——
    case photosList = "photos.list"
    case photosSync = "photos.sync"
    case deviceControl = "device.control"
    case filesPick = "files.pick"

    public var permission: MioBridgePermission {
        switch self {
        case .ping, .getDeviceInfo: return .basic
        case .openTab: return .tabs
        case .saveToMio: return .save
        case .photosList, .photosSync: return .photos
        case .deviceControl: return .deviceControl
        case .filesPick: return .files
        }
    }

    public var implemented: Bool {
        switch self {
        case .ping, .getDeviceInfo, .saveToMio, .openTab: return true
        default: return false
        }
    }

    /// 只有 MioCore 站点能调（mio:// 内置离线页只能用 basic / tabs）
    public var allowedOnInternalPages: Bool { permission == .basic || permission == .tabs }
}

public struct MioBridgeError: Error, Equatable {
    public let code: String
    public let message: String
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
    public static func bad(_ m: String) -> MioBridgeError { .init("bad_request", m) }
}

/// 设备信息（宿主提供）
public struct MioDeviceInfo: Equatable {
    public var platform: String      // ios | ipados | macos
    public var model: String         // iPhone15,2 / Mac14,7 …
    public var osVersion: String
    public var appVersion: String
    public var appBuild: String
    public var locale: String
    public init(platform: String, model: String, osVersion: String, appVersion: String, appBuild: String, locale: String) {
        self.platform = platform; self.model = model; self.osVersion = osVersion; self.appVersion = appVersion; self.appBuild = appBuild; self.locale = locale
    }
}

/// 宿主实现：真正打开标签、保存、弹权限询问
public protocol MioCoreBridgeDelegate: AnyObject {
    func bridgeDeviceInfo() -> MioDeviceInfo
    /// url 已校验为 http(s) / mio://
    func bridgeOpenTab(_ url: URL, background: Bool) -> Bool
    /// kind = bookmark | note | clip；payload 见 mio-save.js。返回 mio-save.js 的结果字典
    func bridgeSaveToMio(kind: String, payload: [String: Any]) async -> [String: Any]
    /// 需要询问用户的权限（photos / deviceControl / files）。返回 true = 允许（并记住）
    func bridgeRequestPermission(_ permission: MioBridgePermission, origin: MioFrameOrigin) async -> Bool
}

/// 权限记录：mio.bridge.grants = { "<origin>": { "<permission>": true/false } }
public final class MioBridgePermissionStore {
    public static let key = "mio.bridge.grants"
    let prefs: MioPrefs
    public init(prefs: MioPrefs) { self.prefs = prefs }

    public func decision(_ p: MioBridgePermission, origin: MioFrameOrigin) -> Bool? {
        (prefs.dictionary(Self.key)[origin.description] as? [String: Any])?[p.rawValue] as? Bool
    }

    public func isGranted(_ p: MioBridgePermission, origin: MioFrameOrigin) -> Bool {
        if let d = decision(p, origin: origin) { return d }
        return p.grantedByDefault
    }

    public func set(_ p: MioBridgePermission, origin: MioFrameOrigin, granted: Bool?) {
        var all = prefs.dictionary(Self.key)
        var o = (all[origin.description] as? [String: Any]) ?? [:]
        o[p.rawValue] = granted
        all[origin.description] = o.isEmpty ? nil : o
        prefs.set(all, forKey: Self.key)
    }

    public func reset() { prefs.set(nil, forKey: Self.key) }
}

public final class MioCoreBridge {
    public static let handlerName = "mio"
    public static let apiVersion = 1
    public static let supportedVersions: [Int] = [1]

    public let prefs: MioPrefs
    public let permissions: MioBridgePermissionStore
    public weak var delegate: MioCoreBridgeDelegate?
    /// 测试 / Debug：允许 MioCore 的同源 iframe
    public var allowSubframes = false

    public init(prefs: MioPrefs, delegate: MioCoreBridgeDelegate? = nil) {
        self.prefs = prefs
        self.permissions = MioBridgePermissionStore(prefs: prefs)
        self.delegate = delegate
    }

    /// 处理一条消息，返回要回给页面的 JSON 字典（永远不抛；错误也装在字典里）
    public func handle(body: Any, origin: MioFrameOrigin?, isMainFrame: Bool) async -> [String: Any] {
        let dict = body as? [String: Any]
        let id = (dict?["id"] as? String) ?? (dict?["id"] as? NSNumber)?.stringValue
        let v = (dict?["v"] as? Int) ?? (dict?["v"] as? NSNumber)?.intValue ?? Self.apiVersion
        func fail(_ e: MioBridgeError) -> [String: Any] {
            var r: [String: Any] = ["v": v, "ok": false, "error": ["code": e.code, "message": e.message]]
            if let id = id { r["id"] = id }
            return r
        }
        // 1) 来源：先于一切（被拒的来源连方法列表都拿不到）
        let verdict = MioCoreOrigin.check(origin: origin, isMainFrame: isMainFrame, prefs: prefs, allowSubframes: allowSubframes)
        guard case .allowed(let kind) = verdict else {
            if case .denied(let why) = verdict { return fail(.init("forbidden", why)) }
            return fail(.init("forbidden", "denied"))
        }
        guard let d = dict, let methodName = d["method"] as? String else { return fail(.bad("expected {v, id, method, params}")) }
        // 2) 版本
        guard Self.supportedVersions.contains(v) else { return fail(.init("unsupported_version", "api v\(v) not supported; supported: \(Self.supportedVersions)")) }
        // 3) 方法
        guard let method = MioBridgeMethod(rawValue: methodName) else { return fail(.init("unknown_method", methodName)) }
        if kind == .internalPage && !method.allowedOnInternalPages { return fail(.init("forbidden", "\(methodName) only for MioCore")) }
        // 4) 权限
        let o = origin! // allowed ⇒ non-nil
        if !permissions.isGranted(method.permission, origin: o) {
            if permissions.decision(method.permission, origin: o) == false {
                return fail(.init("permission_denied", method.permission.rawValue))
            }
            guard method.implemented, let del = delegate else { return fail(.init("permission_denied", method.permission.rawValue)) }
            let ok = await del.bridgeRequestPermission(method.permission, origin: o)
            permissions.set(method.permission, origin: o, granted: ok)
            if !ok { return fail(.init("permission_denied", method.permission.rawValue)) }
        }
        guard method.implemented else { return fail(.init("not_implemented", "\(methodName) is defined but not implemented yet")) }
        // 5) 执行
        let params = d["params"] as? [String: Any] ?? [:]
        do {
            let result = try await run(method, params: params)
            var r: [String: Any] = ["v": v, "ok": true, "result": result]
            if let id = id { r["id"] = id }
            return r
        } catch let e as MioBridgeError {
            return fail(e)
        } catch {
            return fail(.init("failed", String(describing: error)))
        }
    }

    func run(_ m: MioBridgeMethod, params: [String: Any]) async throws -> Any {
        switch m {
        case .ping:
            return ["pong": true, "api": Self.apiVersion, "apiVersions": Self.supportedVersions,
                    "methods": MioBridgeMethod.allCases.filter { $0.implemented }.map { $0.rawValue }] as [String: Any]
        case .getDeviceInfo:
            guard let info = delegate?.bridgeDeviceInfo() else { throw MioBridgeError("failed", "no host") }
            return ["platform": info.platform, "model": info.model, "osVersion": info.osVersion, "appVersion": info.appVersion,
                    "appBuild": info.appBuild, "locale": info.locale, "api": Self.apiVersion, "apiVersions": Self.supportedVersions,
                    "permissions": MioBridgePermission.allCases.map { $0.rawValue }] as [String: Any]
        case .openTab:
            guard let s = params["url"] as? String, let url = Self.openableURL(s) else { throw MioBridgeError.bad("url must be http(s) or mio://") }
            let background = params["background"] as? Bool ?? false
            guard let del = delegate, del.bridgeOpenTab(url, background: background) else { throw MioBridgeError("failed", "could not open tab") }
            return ["opened": true]
        case .saveToMio:
            let kind = params["kind"] as? String ?? "bookmark"
            guard ["bookmark", "note", "clip"].contains(kind) else { throw MioBridgeError.bad("kind must be bookmark | note | clip") }
            guard let payload = params["payload"] as? [String: Any], let u = payload["url"] as? String, Self.openableURL(u) != nil else {
                throw MioBridgeError.bad("payload.url required")
            }
            guard let del = delegate else { throw MioBridgeError("failed", "no host") }
            return await del.bridgeSaveToMio(kind: kind, payload: payload)
        default:
            throw MioBridgeError("not_implemented", m.rawValue)
        }
    }

    /// openTab / saveToMio 接受的地址：http(s)，或 MioKit 的 mio:// 页面
    public static func openableURL(_ s: String) -> URL? {
        guard s.count <= 8192, let u = URL(string: s), let sc = u.scheme?.lowercased() else { return nil }
        if sc == "http" || sc == "https" { return (u.host?.isEmpty == false) ? u : nil }
        if sc == "mio" { return MioCoreOrigin.internalHosts.contains(u.host?.lowercased() ?? "") ? u : nil }
        return nil
    }
}
