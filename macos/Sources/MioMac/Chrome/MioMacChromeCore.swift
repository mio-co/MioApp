// MioMacChromeCore.swift — Firefox 桌面式浏览器外壳的纯逻辑（只依赖 Foundation；tools/MioAppTests 里有单测，符号链接过去）：
//   - MioTabLayout：横向标签条的宽度 / 位置 / 溢出（Firefox：普通标签 76…225pt 平分，固定标签 36pt 只显示图标，放不下就横向滚动）、
//     拖拽排序的落点、关闭时「宽度锁定」（Firefox 关标签后不立刻放宽，下一个关闭按钮停在鼠标下面，鼠标离开标签条再展开）
//   - MioMacHome：地址栏里当作首页的写法（mio://home / about:home / about:newtab）；首页模型与本机桥在 MioKit
//   - MioURLDisplay：地址栏显示（去掉 https://、域名高亮、站点信息图标的安全状态）
//   - MioSuggest / MioHistoryList / MioBookmarkList：地址栏下拉建议（搜索 / 访问 / 切换到标签页 / 书签 / 历史）

import Foundation

// MARK: - 标签条布局

enum MioTabLayout {
    struct Metrics: Equatable {
        var minWidth: Double = 76     // Firefox --tab-min-width
        var maxWidth: Double = 225    // Firefox 标签最大宽度
        var pinnedWidth: Double = 36  // 固定标签：只有图标
        var spacing: Double = 2
    }

    struct Result: Equatable {
        var xs: [Double]
        var widths: [Double]
        /// 所有标签（含间距）的总宽度
        var contentWidth: Double
        /// 普通标签按最小宽度也放不下 → 横向滚动
        var overflow: Bool
        /// 普通标签的统一宽度
        var tabWidth: Double
    }

    /// pinned[i] = 第 i 个标签是否固定（固定标签必须在前面，调用方保证）。
    /// lockedWidth：关闭标签后的宽度锁定（不放宽，只在放不下时收缩）
    static func layout(pinned: [Bool], available: Double, metrics m: Metrics = Metrics(), lockedWidth: Double? = nil) -> Result {
        let n = pinned.count
        guard n > 0 else { return Result(xs: [], widths: [], contentWidth: 0, overflow: false, tabWidth: m.maxWidth) }
        let pinnedCount = pinned.filter { $0 }.count
        let normalCount = n - pinnedCount
        let gaps = Double(max(0, n - 1)) * m.spacing
        let pinnedTotal = Double(pinnedCount) * m.pinnedWidth
        let room = max(0, available - pinnedTotal - gaps)
        var w = m.maxWidth
        var overflow = false
        if normalCount > 0 {
            let fair = room / Double(normalCount)
            w = min(m.maxWidth, fair)
            if let lock = lockedWidth { w = min(w, max(lock, m.minWidth)) } // 锁定：不放宽，放不下照样收缩
            if w < m.minWidth { w = m.minWidth; overflow = true }
        } else {
            overflow = pinnedTotal + gaps > available
        }
        w = (w * 2).rounded(.down) / 2 // 半点对齐，避免模糊
        var xs: [Double] = []
        var widths: [Double] = []
        var x = 0.0
        for p in pinned {
            let ww = p ? m.pinnedWidth : w
            xs.append(x)
            widths.append(ww)
            x += ww + m.spacing
        }
        let content = max(0, x - m.spacing)
        return Result(xs: xs, widths: widths, contentWidth: content, overflow: overflow, tabWidth: w)
    }

    /// 拖拽排序：被拖标签（原位置 from）中心在 center 时应插入的位置。
    /// mids：所有标签（按当前顺序，含被拖的那个）静止时的中心；allowed：可落入的下标范围（固定标签只能在固定区，普通标签只能在普通区）
    static func dropIndex(center: Double, mids: [Double], from: Int, allowed: ClosedRange<Int>) -> Int {
        guard !mids.isEmpty, mids.indices.contains(from) else { return from }
        var idx = 0
        for (i, m) in mids.enumerated() where i != from && m < center { idx += 1 }
        return max(allowed.lowerBound, min(allowed.upperBound, idx))
    }

    /// 被拖标签移到 to 之后的顺序（只用于预览动画；真正移动由 MioTabStore.move 做）
    static func reordered<T>(_ items: [T], from: Int, to: Int) -> [T] {
        guard items.indices.contains(from) else { return items }
        var a = items
        let x = a.remove(at: from)
        a.insert(x, at: max(0, min(a.count, to)))
        return a
    }

    /// 让 [x, x+w] 进入可见区 [offset, offset+visible] 需要的新偏移（已可见 → nil）
    static func scrollOffset(revealing x: Double, width w: Double, offset: Double, visible: Double, content: Double, margin: Double = 12) -> Double? {
        guard content > visible else { return offset == 0 ? nil : 0 }
        var o = offset
        if x - margin < o { o = x - margin } else if x + w + margin > o + visible { o = x + w + margin - visible }
        o = max(0, min(content - visible, o))
        return abs(o - offset) < 0.5 ? nil : o
    }

    /// 拖出标签条多远算「拖成新窗口」（Firefox 大约是标签高度）
    static func isDetach(verticalDistance: Double, threshold: Double = 36) -> Bool { verticalDistance > threshold }
}

// MARK: - 首页 mio://home

enum MioMacHome {
    static let address = "mio://home"
    static let displayName = "Mio"

    /// 地址栏里输入这些都当作首页（mio://home 由 MioKit 的 MioSchemeHandler 跳到 MioCore 首页；是否「首页」、桥的来源校验都以 MioKit 为准）
    static func isHomeAddress(_ s: String) -> Bool {
        let l = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["mio://home", "mio://home/", "mio:home", "about:home", "about:newtab", "mio://newtab"].contains(l)
    }
}

// MARK: - 地址栏显示

enum MioURLDisplay {
    enum Security: String, Equatable {
        case home        // Mio 首页
        case secure      // https
        case insecure    // http（Firefox：带斜线的锁）
        case local       // file: / about: / data:
        case none        // 空白新标签
    }

    static func security(_ url: URL?, isHome: Bool) -> Security {
        if isHome { return .home }
        guard let u = url, let s = u.scheme?.lowercased() else { return .none }
        switch s {
        case "https": return .secure
        case "http": return (u.host == "localhost" || u.host == "127.0.0.1") ? .local : .insecure
        case "about": return u.absoluteString == "about:blank" ? .none : .local
        default: return .local
        }
    }

    /// 未聚焦时的显示：https:// 去掉（Firefox trimHttps），http:// 保留；返回 (前缀, 域名, 其余)，域名高亮、其余变灰
    static func parts(_ url: URL?) -> (prefix: String, host: String, rest: String) {
        guard let u = url, let s = u.scheme?.lowercased() else { return ("", "", "") }
        if u.absoluteString == "about:blank" { return ("", "", "") }
        guard s == "http" || s == "https", let host = u.host else { return ("", u.absoluteString, "") }
        let full = u.absoluteString
        let prefix = s == "http" ? "http://" : ""
        var hostPart = host
        if let p = u.port { hostPart += ":\(p)" }
        var rest = ""
        if let r = full.range(of: hostPart, options: [.caseInsensitive]) {
            rest = String(full[r.upperBound...])
            if rest == "/" { rest = "" }
        }
        return (prefix, hostPart, rest)
    }

    static func displayString(_ url: URL?) -> String {
        let p = parts(url)
        return p.prefix + p.host + p.rest
    }

    /// 聚焦编辑时显示完整地址（about:blank → 空）
    static func editingText(_ url: URL?) -> String {
        guard let u = url, u.absoluteString != "about:blank" else { return "" }
        return u.absoluteString
    }
}

// MARK: - 历史 / 书签（地址栏建议用）

struct MioHistoryEntry: Equatable, Codable {
    var url: String
    var title: String
    var visits: Int
    var last: Double
}

struct MioHistoryList: Equatable {
    static let maxEntries = 500
    private(set) var entries: [MioHistoryEntry] = []

    init(entries: [MioHistoryEntry] = []) { self.entries = entries }

    init(json: Data?) {
        if let d = json, let e = try? JSONDecoder().decode([MioHistoryEntry].self, from: d) { entries = e }
    }

    var json: Data { (try? JSONEncoder().encode(entries)) ?? Data("[]".utf8) }

    static func isRecordable(_ url: String) -> Bool {
        let l = url.lowercased()
        return l.hasPrefix("http://") || l.hasPrefix("https://")
    }

    mutating func record(url: String, title: String, at time: Double) {
        guard Self.isRecordable(url) else { return }
        if let i = entries.firstIndex(where: { $0.url == url }) {
            var e = entries.remove(at: i)
            e.visits += 1
            e.last = time
            if !title.isEmpty { e.title = title }
            entries.insert(e, at: 0)
        } else {
            entries.insert(MioHistoryEntry(url: url, title: title, visits: 1, last: time), at: 0)
            if entries.count > Self.maxEntries { entries.removeLast(entries.count - Self.maxEntries) }
        }
    }

    mutating func clear() { entries = [] }
}

struct MioBookmark: Equatable, Codable {
    var url: String
    var title: String
}

struct MioBookmarkList: Equatable {
    private(set) var items: [MioBookmark] = []

    init(items: [MioBookmark] = []) { self.items = items }

    init(json: Data?) {
        if let d = json, let e = try? JSONDecoder().decode([MioBookmark].self, from: d) { items = e }
    }

    var json: Data { (try? JSONEncoder().encode(items)) ?? Data("[]".utf8) }

    func contains(_ url: String?) -> Bool {
        guard let u = url, !u.isEmpty else { return false }
        return items.contains { $0.url == u }
    }

    /// 星标：加入 / 移除；返回加入后是否已收藏
    @discardableResult
    mutating func toggle(url: String, title: String) -> Bool {
        guard MioHistoryList.isRecordable(url) else { return false }
        if let i = items.firstIndex(where: { $0.url == url }) { items.remove(at: i); return false }
        items.insert(MioBookmark(url: url, title: title.isEmpty ? url : title), at: 0)
        return true
    }
}

// MARK: - 地址栏建议

struct MioSuggestion: Equatable {
    enum Kind: String, Equatable { case search, visit, switchTab, bookmark, history }
    var kind: Kind
    var title: String
    var url: String
    var tabID: Int? = nil
}

enum MioSuggest {
    struct OpenTab: Equatable { var id: Int; var title: String; var url: String }

    static func matches(_ tokens: [String], title: String, url: String) -> Bool {
        let t = title.lowercased()
        let u = url.lowercased()
        return tokens.allSatisfy { t.contains($0) || u.contains($0) }
    }

    /// Firefox 顺序：第一条是「回车会做什么」（访问网址 / 用搜索引擎搜索），然后 切换到标签页、书签、历史；同一网址只出现一次
    static func build(query raw: String, resolved: URL?, isSearch: Bool, engine: String = "Google",
                      tabs: [OpenTab], bookmarks: [MioBookmark], history: [MioHistoryEntry],
                      activeTabID: Int? = nil, limit: Int = 8) -> [MioSuggestion] {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var out: [MioSuggestion] = []
        var seen = Set<String>()
        if let r = resolved {
            if isSearch {
                out.append(MioSuggestion(kind: .search, title: q, url: r.absoluteString))
            } else {
                out.append(MioSuggestion(kind: .visit, title: MioURLDisplay.displayString(r), url: r.absoluteString))
                seen.insert(r.absoluteString)
            }
        }
        let tokens = q.lowercased().split(whereSeparator: { $0 == " " }).map(String.init)
        for t in tabs where t.id != activeTabID && matches(tokens, title: t.title, url: t.url) && !seen.contains(t.url) {
            out.append(MioSuggestion(kind: .switchTab, title: t.title.isEmpty ? t.url : t.title, url: t.url, tabID: t.id))
            seen.insert(t.url)
        }
        for b in bookmarks where matches(tokens, title: b.title, url: b.url) && !seen.contains(b.url) {
            out.append(MioSuggestion(kind: .bookmark, title: b.title, url: b.url))
            seen.insert(b.url)
        }
        let hist = history.filter { matches(tokens, title: $0.title, url: $0.url) }
            .sorted { ($0.visits, $0.last) > ($1.visits, $1.last) }
        for h in hist where !seen.contains(h.url) {
            out.append(MioSuggestion(kind: .history, title: h.title.isEmpty ? h.url : h.title, url: h.url))
            seen.insert(h.url)
        }
        if isSearch == false, resolved != nil, out.count < limit, let s = searchURL(q, engine: engine) {
            out.append(MioSuggestion(kind: .search, title: q, url: s)) // 像网址的输入也给一条「搜索」
        }
        return Array(out.prefix(limit))
    }

    static func searchURL(_ q: String, engine: String) -> String? {
        var c = URLComponents(string: "https://www.google.com/search")
        c?.queryItems = [URLQueryItem(name: "q", value: q)]
        return c?.url?.absoluteString
    }

    /// 键盘上下移动选中项（-1 = 没有选中，回到输入框）
    static func move(selection: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return -1 }
        var s = selection + delta
        if s < -1 { s = count - 1 }
        if s >= count { s = -1 }
        return s
    }
}
