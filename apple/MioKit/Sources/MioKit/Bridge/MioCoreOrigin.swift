// MioCoreOrigin.swift — 本机桥的来源校验：只有 MioCore 站点（默认 https://mio.300031.xyz，可配置）和 mio:// 内置页能用。
// 校验看的是「发消息的 frame 的安全来源」（WKFrameInfo.securityOrigin），不是地址栏 URL：
//   - 协议 + 主机 + 端口必须与配置完全一致（不认子域名、不认 http 降级、不认别的端口）
//   - mio:// 只认 MioKit 自己处理的主机（home / offline / about）
//   - 默认只认主框架；MioCore 里嵌的同源 iframe 也行，其他来源的 iframe（广告、第三方）一律拒绝
// 只依赖 Foundation（单测在 Linux 上跑）。

import Foundation

/// frame 的安全来源（WebKit 无关）
public struct MioFrameOrigin: Hashable, CustomStringConvertible {
    public let scheme: String
    public let host: String
    /// 0 = 默认端口
    public let port: Int

    public init(scheme: String, host: String, port: Int = 0) {
        self.scheme = scheme.lowercased()
        self.host = host.lowercased()
        let p = port
        self.port = (p == 443 && scheme.lowercased() == "https") || (p == 80 && scheme.lowercased() == "http") ? 0 : max(p, 0)
    }

    /// 从 URL 取来源（about:blank / data: 等没有主机的返回 nil）
    public init?(url: URL?) {
        guard let url = url, let s = url.scheme?.lowercased(), let h = url.host, !h.isEmpty else { return nil }
        self.init(scheme: s, host: h, port: url.port ?? 0)
    }

    public var description: String { port == 0 ? "\(scheme)://\(host)" : "\(scheme)://\(host):\(port)" }
}

public enum MioCoreOrigin {
    public static let originKey = "mio.core.origin"
    public static let defaultOrigin = "https://mio.300031.xyz"
    /// mio:// 下 MioKit 自己提供的页面
    public static let internalHosts: Set<String> = ["home", "offline", "about"]

    /// 规范化用户填的 MioCore 地址：只要 https（本机调试允许 http://localhost / 127.0.0.1），去掉路径 / 查询 / 用户名密码。不合法 → nil
    public static func normalize(_ input: String?) -> String? {
        guard var s = input?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard let c = URLComponents(string: s), let scheme = c.scheme?.lowercased(), let host = c.host?.lowercased(), !host.isEmpty,
              c.user == nil, c.password == nil else { return nil }
        let isLocal = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && isLocal) else { return nil }
        guard host.range(of: #"^[a-z0-9.\-:\[\]]+$"#, options: .regularExpression) != nil else { return nil }
        let o = MioFrameOrigin(scheme: scheme, host: host, port: c.port ?? 0)
        return o.description
    }

    /// 当前配置的 MioCore 来源（设置不合法时回退默认值）
    public static func configured(_ prefs: MioPrefs) -> MioFrameOrigin {
        let s = normalize(prefs.object(forKey: originKey) as? String) ?? defaultOrigin
        return MioFrameOrigin(url: URL(string: s)) ?? MioFrameOrigin(scheme: "https", host: "mio.300031.xyz")
    }

    public static func originURL(_ prefs: MioPrefs) -> URL { URL(string: configured(prefs).description)! }

    public enum Verdict: Equatable {
        case allowed(Kind)
        case denied(String)
        public enum Kind: Equatable { case mioCore, internalPage }
        public var isAllowed: Bool { if case .allowed = self { return true }; return false }
    }

    /// 来源校验（桥的唯一入口）
    public static func check(origin: MioFrameOrigin?, isMainFrame: Bool, prefs: MioPrefs, allowSubframes: Bool = false) -> Verdict {
        guard let o = origin else { return .denied("opaque origin") }
        if o.scheme == "mio" {
            guard internalHosts.contains(o.host) else { return .denied("unknown mio:// page") }
            guard isMainFrame else { return .denied("subframe") }
            return .allowed(.internalPage)
        }
        let core = configured(prefs)
        guard o == core else { return .denied("origin \(o) not allowed") }
        guard isMainFrame || allowSubframes else { return .denied("subframe") }
        return .allowed(.mioCore)
    }

    /// 地址是不是 MioCore 站点（菜单 / 地址栏显示用）
    public static func isMioCore(_ url: URL?, prefs: MioPrefs) -> Bool {
        guard let o = MioFrameOrigin(url: url) else { return false }
        return o == configured(prefs)
    }
}
