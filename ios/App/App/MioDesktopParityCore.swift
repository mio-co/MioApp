// MioDesktopParityCore.swift — v0.3.4 Mac / Windows 跟 Safari 对齐的纯逻辑（只依赖 Foundation，tools/MioAppTests 里有单测）。
//   1. 页面缩放：Safari 的缩放档位、⌘+ / ⌘- / ⌘0、按站点（host）记住缩放
//   2. YouTube on Mac：恢复 v0.3.0 的 UA（YouTube 下发 HLS → 原生播放高清，不需要 MSE），其他站点仍是桌面 Safari UA
//   3. 「在 Safari 中看高清」兜底：当前 URL + 播放进度 t=
// Windows（Electron）用 desktop/src/zoom-core.js 的同一套档位与规则。

import Foundation

enum MioZoomCore {
    /// Safari 的缩放档位（View › Zoom In / Zoom Out）
    static let levels: [Double] = [0.5, 0.75, 0.85, 1.0, 1.15, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]
    static let minLevel = 0.5
    static let maxLevel = 3.0

    /// 最接近的档位（存储里有非档位值时归位）
    static func nearest(_ z: Double) -> Double {
        guard z.isFinite else { return 1.0 }
        return levels.min(by: { abs($0 - z) < abs($1 - z) }) ?? 1.0
    }

    /// 放大：下一个更大的档位（已最大时不变）
    static func zoomIn(from z: Double) -> Double {
        levels.first(where: { $0 > z + 0.001 }) ?? maxLevel
    }

    /// 缩小：下一个更小的档位（已最小时不变）
    static func zoomOut(from z: Double) -> Double {
        levels.last(where: { $0 < z - 0.001 }) ?? minLevel
    }

    /// 地址栏小标签：「125%」
    static func label(_ z: Double) -> String { "\(Int((z * 100).rounded()))%" }

    static func isDefault(_ z: Double, default d: Double) -> Bool { abs(z - d) < 0.001 }

    /// 站点键：小写 host，去掉开头的 www.（Safari 也是按网站记，www 与裸域算一个）
    static func siteKey(_ host: String?) -> String? {
        guard var h = host?.lowercased().trimmingCharacters(in: .whitespaces), !h.isEmpty else { return nil }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    static func siteKey(url: URL?) -> String? {
        guard let u = url, let s = u.scheme?.lowercased(), s == "http" || s == "https" else { return nil }
        return siteKey(u.host)
    }

    /// 按站点的缩放表（UserDefaults 里存 JSON 字典）
    struct SiteTable: Equatable {
        private(set) var sites: [String: Double] = [:]
        /// 最多记这么多站点，超出时丢掉最早的（JSON 无序 → 用 order 记先后）
        static let limit = 500
        private(set) var order: [String] = []

        init() {}

        init(json: String?) {
            guard let data = json?.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            if let s = obj["sites"] as? [String: Any] {
                for (k, v) in s { if let d = (v as? NSNumber)?.doubleValue, d >= minLevel, d <= maxLevel { sites[k] = MioZoomCore.nearest(d) } }
            }
            let o = (obj["order"] as? [String]) ?? []
            order = o.filter { sites[$0] != nil }
            for k in sites.keys.sorted() where !order.contains(k) { order.append(k) }
        }

        var json: String {
            let obj: [String: Any] = ["sites": sites, "order": order]
            guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return "{}" }
            return String(data: data, encoding: .utf8) ?? "{}"
        }

        func zoom(for site: String?, default d: Double) -> Double {
            guard let s = site, let z = sites[s] else { return d }
            return z
        }

        /// 设置某站点的缩放；等于默认值时删掉记录（与 Safari 一致：回到默认 = 不再单独记）
        mutating func set(_ z: Double, for site: String?, default d: Double) {
            guard let s = site else { return }
            order.removeAll { $0 == s }
            if MioZoomCore.isDefault(z, default: d) {
                sites[s] = nil
                return
            }
            sites[s] = MioZoomCore.nearest(z)
            order.append(s)
            while order.count > Self.limit { sites[order.removeFirst()] = nil }
        }

        var count: Int { sites.count }
    }
}

enum MioYouTubeCompat {
    /// youtube.com / *.youtube.com / youtube-nocookie.com / *.youtube-nocookie.com / youtu.be
    static func isYouTubeHost(_ host: String?) -> Bool {
        guard let h = host?.lowercased(), !h.isEmpty else { return false }
        for d in ["youtube.com", "youtube-nocookie.com", "youtu.be"] where h == d || h.hasSuffix("." + d) { return true }
        return false
    }

    /// v0.3.0 在 Mac 上实际发出的 UA：Catalyst WKWebView 默认 UA（Macintosh…KHTML, like Gecko）+ 当时的
    /// applicationNameForUserAgent「Version/<major>.0 Mobile/15E148 Safari/604.1」。YouTube 把它当移动版 Safari → 下发 HLS
    /// （streamingData.hlsManifestUrl），原生 HLS 播放可到 720p/1080p，不依赖 Mac Catalyst 缺失的 MSE。
    static func legacyMacUserAgent(osMajor: Int) -> String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(osMajor).0 Mobile/15E148 Safari/604.1"
    }

    /// 视频页（watch / shorts / embed / youtu.be/<id> / live）
    static func videoID(_ url: URL?) -> String? {
        guard let u = url, let host = u.host?.lowercased(), isYouTubeHost(host) else { return nil }
        let comps = URLComponents(url: u, resolvingAgainstBaseURL: false)
        let path = u.path
        if host == "youtu.be" || host.hasSuffix(".youtu.be") {
            let id = path.split(separator: "/").first.map(String.init)
            return id.flatMap { $0.isEmpty ? nil : $0 }
        }
        if path == "/watch" { return comps?.queryItems?.first(where: { $0.name == "v" })?.value.flatMap { $0.isEmpty ? nil : $0 } }
        let parts = path.split(separator: "/").map(String.init)
        if parts.count >= 2, ["embed", "shorts", "live", "v"].contains(parts[0]) { return parts[1].isEmpty ? nil : parts[1] }
        return nil
    }

    static func isVideoPage(_ url: URL?) -> Bool { videoID(url) != nil }

    /// 「在 Safari 中看高清」：https://www.youtube.com/watch?v=<id>&t=<秒>s（保留列表 list=；嵌入页 / 短链 / 手机版都换成桌面 watch 页）
    static func safariHDURL(_ url: URL?, seconds: Double?) -> URL? {
        guard let id = videoID(url) else { return nil }
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "www.youtube.com"
        comps.path = "/watch"
        var items = [URLQueryItem(name: "v", value: id)]
        if let u = url, let list = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "list" })?.value {
            items.append(URLQueryItem(name: "list", value: list))
        }
        if let s = seconds, s.isFinite, s >= 1 { items.append(URLQueryItem(name: "t", value: "\(Int(s))s")) }
        comps.queryItems = items
        return comps.url
    }
}
