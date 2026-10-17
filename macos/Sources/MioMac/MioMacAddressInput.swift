// MioMacAddressInput.swift — 地址栏输入 → URL（只依赖 Foundation；tools/MioAppTests 里有单测，符号链接过去）。
// 规则与 iOS 内置浏览器一致：完整 http(s) 地址原样打开；像域名 / IP / localhost 的补 scheme；其他文字用 Google 搜索。

import Foundation

enum MioMacAddressInput {
    static let searchBase = "https://www.google.com/search"

    /// 用户在地址栏按回车后的目标地址；空输入返回 nil
    static func resolve(_ raw: String) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let lower = s.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            if let u = URL(string: s), let h = u.host, !h.isEmpty { return u }
            return search(s)
        }
        if lower == "about:blank" { return URL(string: "about:blank") }
        if !s.contains(" "), let host = hostPart(s) {
            if host == "localhost" || isIPv4(host) { return URL(string: "http://" + s) }
            if looksLikeDomain(host) { return URL(string: "https://" + s) }
        }
        return search(s)
    }

    static func search(_ q: String) -> URL? {
        var c = URLComponents(string: searchBase)
        c?.queryItems = [URLQueryItem(name: "q", value: q)]
        return c?.url
    }

    /// "example.com:8080/path?x" → "example.com"
    static func hostPart(_ s: String) -> String? {
        let beforePath = s.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? s
        let beforeQuery = beforePath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? beforePath
        let host = beforeQuery.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? beforeQuery
        let h = host.lowercased()
        return h.isEmpty ? nil : h
    }

    static func isIPv4(_ h: String) -> Bool {
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { p in
            guard !p.isEmpty, p.count <= 3, p.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(p) else { return false }
            return n <= 255
        }
    }

    /// 至少两段、每段是字母数字或连字符、最后一段（顶级域）至少两个字母
    static func looksLikeDomain(_ h: String) -> Bool {
        let labels = h.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        for l in labels {
            guard !l.isEmpty, l.count <= 63, !l.hasPrefix("-"), !l.hasSuffix("-") else { return false }
            guard l.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" }) else { return false }
        }
        guard let tld = labels.last, tld.count >= 2, tld.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }) else { return false }
        return true
    }

    /// 地址栏显示：http(s) 显示完整地址；about:blank 显示空
    static func displayText(_ url: URL?) -> String {
        guard let u = url else { return "" }
        if u.absoluteString == "about:blank" { return "" }
        return u.absoluteString
    }
}
