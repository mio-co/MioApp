// MioUpdateCore.swift — 软件内更新的纯逻辑（只依赖 Foundation，tools/MioAppTests 在 Linux / macOS 上 swift test）
// 规则：
// - 版本比较：semver（v 前缀、缺省段补 0、预发布 < 正式版，+build 忽略）
// - GitHub releases/latest 解析（草稿 / 预发布 / tag 不是版本号 → 忽略）
// - sha256：SHA256SUMS.txt（CI 生成，sha256sum 格式）+ GitHub 资产 digest 交叉校验，都没有就拒绝安装
// - 检查节奏：开关打开、距上次成功检查 ≥ 24 小时、距上次尝试 ≥ 1 小时
// - Mac：更新辅助脚本（App 退出后替换 .app、去 quarantine、重新打开）
// - iOS：SideStore / AltStore 添加源的 deep link

import Foundation

enum MioUpdateCore {
    static let repo = "mio-co/MioApp"
    static let latestAPI = URL(string: "https://api.github.com/repos/mio-co/MioApp/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/mio-co/MioApp/releases/latest")!
    /// AltStore / SideStore 源的稳定地址（每次发版 CI 生成并挂到 Release 上）
    static let altStoreSourceURL = "https://github.com/mio-co/MioApp/releases/latest/download/altstore-source.json"
    static let sumsAsset = "SHA256SUMS.txt"
    static let bundleIdentifier = "xyz.mio.app"
    static let checkInterval: TimeInterval = 24 * 3600
    static let retryInterval: TimeInterval = 3600

    // MARK: - Versions

    struct Version: Equatable {
        var core: [Int]
        var pre: [String]
    }

    static func parseVersion(_ s: String) -> Version? {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
        if let plus = t.firstIndex(of: "+") {
            let meta = t[t.index(after: plus)...]
            guard !meta.isEmpty, meta.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else { return nil }
            t = String(t[..<plus])
        }
        var preText: Substring = ""
        if let dash = t.firstIndex(of: "-") {
            preText = t[t.index(after: dash)...]
            guard !preText.isEmpty, preText.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else { return nil }
            t = String(t[..<dash])
        }
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var core: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(p) else { return nil }
            core.append(n)
        }
        while core.count < 3 { core.append(0) }
        let pre = preText.isEmpty ? [] : preText.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        return Version(core: core, pre: pre)
    }

    /// -1 / 0 / 1；任一不合法返回 nil
    static func compare(_ a: String, _ b: String) -> Int? {
        guard let x = parseVersion(a), let y = parseVersion(b) else { return nil }
        for i in 0..<max(x.core.count, y.core.count) {
            let p = i < x.core.count ? x.core[i] : 0
            let q = i < y.core.count ? y.core[i] : 0
            if p != q { return p < q ? -1 : 1 }
        }
        if x.pre.isEmpty && y.pre.isEmpty { return 0 }
        if x.pre.isEmpty { return 1 }
        if y.pre.isEmpty { return -1 }
        for i in 0..<max(x.pre.count, y.pre.count) {
            if i >= x.pre.count { return -1 }
            if i >= y.pre.count { return 1 }
            let p = x.pre[i], q = y.pre[i]
            if p == q { continue }
            let pn = Int(p), qn = Int(q)
            switch (pn, qn) {
            case let (a?, b?): if a != b { return a < b ? -1 : 1 }
            case (_?, nil): return -1
            case (nil, _?): return 1
            default: return p < q ? -1 : 1
            }
        }
        return 0
    }

    static func isNewer(_ remote: String, than current: String) -> Bool { compare(remote, current) == 1 }

    // MARK: - Release

    struct Asset: Equatable {
        var name: String
        var url: URL
        var size: Int
        var digest: String?
    }

    struct Release: Equatable {
        var tag: String
        var version: String
        var name: String
        var notes: String
        var page: URL
        var assets: [Asset]

        func asset(named n: String) -> Asset? { assets.first { $0.name == n } }
        /// Mac Catalyst 包：Mio-<version>-mac.zip
        var macZip: Asset? {
            asset(named: "Mio-\(version)-mac.zip") ?? assets.first { $0.name.hasPrefix("Mio-") && $0.name.hasSuffix("-mac.zip") }
        }
        var ipa: Asset? { asset(named: "Mio.ipa") }
    }

    private struct RawAsset: Decodable {
        let name: String?
        let browser_download_url: String?
        let size: Int?
        let digest: String?
    }

    private struct RawRelease: Decodable {
        let tag_name: String?
        let name: String?
        let body: String?
        let html_url: String?
        let draft: Bool?
        let prerelease: Bool?
        let assets: [RawAsset]?
    }

    static func parseRelease(_ data: Data) throws -> Release? {
        let r = try JSONDecoder().decode(RawRelease.self, from: data)
        if r.draft == true || r.prerelease == true { return nil }
        guard let tag = r.tag_name, parseVersion(tag) != nil else { return nil }
        var version = tag
        if version.hasPrefix("v") || version.hasPrefix("V") { version.removeFirst() }
        let page: URL = {
            if let h = r.html_url, h.hasPrefix("https://github.com/"), let u = URL(string: h) { return u }
            return releasesPage
        }()
        let assets: [Asset] = (r.assets ?? []).compactMap { a in
            guard let n = a.name, let s = a.browser_download_url, s.hasPrefix("https://"), let u = URL(string: s) else { return nil }
            return Asset(name: n, url: u, size: a.size ?? 0, digest: a.digest)
        }
        let name = (r.name?.isEmpty == false ? r.name : nil) ?? tag
        return Release(tag: tag, version: version, name: name, notes: r.body ?? "", page: page, assets: assets)
    }

    // MARK: - SHA-256 manifest

    private static func isHex64(_ s: Substring) -> Bool {
        s.count == 64 && s.allSatisfy { $0.isHexDigit && $0.isASCII }
    }

    /// sha256sum（"hex  name" / "hex *name"）/ BSD（"SHA256 (name) = hex"）→ [name: hex]；只有一行哈希时 key 为 ""
    static func parseSha256Sums(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let sub = Substring(line)
            if sub.count > 66, isHex64(sub.prefix(64)) {
                let rest = sub.dropFirst(64)
                if rest.first == " ", let marker = rest.dropFirst().first, marker == " " || marker == "*" {
                    let name = rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { out[name] = String(sub.prefix(64)).lowercased(); continue }
                }
            }
            if line.hasPrefix("SHA256 ("), let close = line.range(of: ") = ", options: .backwards) {
                let name = String(line[line.index(line.startIndex, offsetBy: 8)..<close.lowerBound])
                let hex = line[close.upperBound...]
                if isHex64(hex) { out[name] = hex.lowercased(); continue }
            }
            if isHex64(sub) { out[""] = line.lowercased() }
        }
        return out
    }

    enum ChecksumError: Error, Equatable, LocalizedError {
        case mismatchBetweenSources(String)
        case missing(String)
        case fileMismatch

        var errorDescription: String? {
            switch self {
            case .mismatchBetweenSources(let n): return "\(n) 的 SHA-256 清单与 GitHub 记录不一致"
            case .missing(let n): return "\(n) 没有 SHA-256 校验值"
            case .fileMismatch: return "下载的文件 SHA-256 校验失败"
            }
        }
    }

    /// 期望的 sha256：清单 + GitHub 资产 digest（"sha256:hex"），两边都有时必须一致
    static func expectedSha256(for asset: Asset, sums: [String: String]?) throws -> String {
        let fromSums = sums?[asset.name]
        var fromDigest: String?
        if let d = asset.digest, d.hasPrefix("sha256:") {
            let hex = d.dropFirst(7)
            if isHex64(hex) { fromDigest = hex.lowercased() }
        }
        if let a = fromSums, let b = fromDigest, a != b { throw ChecksumError.mismatchBetweenSources(asset.name) }
        guard let v = fromSums ?? fromDigest else { throw ChecksumError.missing(asset.name) }
        return v
    }

    static func sha256Matches(_ actual: String, _ expected: String) -> Bool {
        !actual.isEmpty && actual.lowercased() == expected.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// 流式计算文件 sha256（MioSHA256，纯 Swift，Linux 单测与 App 用同一份）
    static func sha256Hex(ofFile url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var sha = MioSHA256()
        while true {
            let chunk = h.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            sha.update(chunk)
        }
        return sha.finalizeHex()
    }

    // MARK: - Schedule

    static func shouldAutoCheck(enabled: Bool, lastCheck: Date?, lastAttempt: Date?, now: Date) -> Bool {
        guard enabled else { return false }
        if let a = lastAttempt, a <= now, now.timeIntervalSince(a) < retryInterval { return false }
        guard let l = lastCheck else { return true }
        return l > now || now.timeIntervalSince(l) >= checkInterval
    }

    // MARK: - Notes

    static func plainNotes(_ md: String, maxLength: Int = 1500) -> String {
        var t = md.replacingOccurrences(of: "\r\n", with: "\n")
        let rules: [(String, String)] = [
            ("```[\\s\\S]*?```", ""),
            ("(?m)^#{1,6}\\s*", ""),
            ("\\*\\*([^*]+)\\*\\*", "$1"),
            ("`([^`]+)`", "$1"),
            ("\\[([^\\]]+)\\]\\(([^)]+)\\)", "$1"),
            ("\\n{3,}", "\n\n"),
        ]
        for (p, r) in rules {
            t = t.replacingOccurrences(of: p, with: r, options: .regularExpression)
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count > maxLength { t = String(t.prefix(maxLength - 1)) + "…" }
        return t
    }

    // MARK: - iOS: SideStore / AltStore

    /// 依次尝试：SideStore、AltStore Classic、AltStore（PAL）添加源；都打不开时 App 打开 Release 页
    static func addSourceDeepLinks(sourceURL: String = altStoreSourceURL) -> [URL] {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":/?&=+#")
        let enc = sourceURL.addingPercentEncoding(withAllowedCharacters: allowed) ?? sourceURL
        return ["sidestore://source?url=", "altstore-classic://source?url=", "altstore://source?url="].compactMap { URL(string: $0 + enc) }
    }

    // MARK: - Mac: install helper

    /// 是否能原地替换：不是 App Translocation（隔离只读路径）、不在 dmg 卷里
    static func canReplaceInPlace(bundlePath: String) -> Bool {
        if bundlePath.contains("/AppTranslocation/") { return false }
        if bundlePath.hasPrefix("/Volumes/") { return false }
        return bundlePath.hasSuffix(".app")
    }

    /// App 退出后执行的辅助脚本（/bin/sh，参数位置传入，不拼接路径，避免注入）：
    ///   $1 = 等待退出的 PID，$2 = 已校验的 zip，$3 = 要替换的 .app，$4 = 工作目录，$5 = 日志，$6 = 期望的 bundle id
    /// 解压 → 检查 bundle id → 去 quarantine → 旧 .app 挪到工作目录 → 新 .app 放到原位置（失败则恢复）→ 重新打开
    /// （环境变量 MIO_UPDATE_NO_RELAUNCH=1 时不重新打开：CI 的 Mac 任务用它实际跑一遍替换流程）
    // MIO_SH_BEGIN mac-install
    static let macInstallScript = #"""
    #!/bin/sh
    PID="$1"; ZIP="$2"; TARGET="$3"; WORK="$4"; LOG="$5"; BUNDLE_ID="$6"
    exec >>"$LOG" 2>&1
    relaunch() { [ -n "$MIO_UPDATE_NO_RELAUNCH" ] || /usr/bin/open "$TARGET"; }
    echo "[$(date)] Mio updater: pid=$PID target=$TARGET"
    i=0
    while kill -0 "$PID" 2>/dev/null; do
      i=$((i+1))
      if [ "$i" -gt 300 ]; then echo "app did not quit in 60s"; exit 1; fi
      sleep 0.2
    done
    rm -rf "$WORK/x"; mkdir -p "$WORK/x"
    if ! /usr/bin/ditto -x -k "$ZIP" "$WORK/x"; then echo "unzip failed"; relaunch; exit 1; fi
    NEW=$(/usr/bin/find "$WORK/x" -maxdepth 2 -type d -name '*.app' | head -n 1)
    if [ -z "$NEW" ] || [ ! -f "$NEW/Contents/Info.plist" ]; then echo "no .app in zip"; relaunch; exit 1; fi
    ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$NEW/Contents/Info.plist" 2>/dev/null)
    if [ "$ID" != "$BUNDLE_ID" ]; then echo "unexpected bundle id '$ID'"; relaunch; exit 1; fi
    /usr/bin/xattr -dr com.apple.quarantine "$NEW" 2>/dev/null
    /usr/bin/codesign --verify --deep --strict "$NEW" 2>&1 || echo "warning: codesign verify failed (ad-hoc build?)"
    rm -rf "$WORK/old.app"
    if ! /bin/mv "$TARGET" "$WORK/old.app"; then echo "cannot move old app"; relaunch; exit 1; fi
    if /bin/mv "$NEW" "$TARGET"; then
      rm -rf "$WORK/old.app"
      echo "installed"
    else
      echo "install failed, restoring"
      /bin/mv "$WORK/old.app" "$TARGET"
      relaunch; exit 1
    fi
    /usr/bin/xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null
    relaunch
    rm -rf "$WORK/x" "$ZIP"
    echo "[$(date)] done"
    """#
    // MIO_SH_END mac-install
}

// MARK: - SHA-256（FIPS 180-4，纯 Swift）

struct MioSHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]
    private var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
    private var buffer: [UInt8] = []
    private var length: UInt64 = 0
    private var w = [UInt32](repeating: 0, count: 64)

    init() { buffer.reserveCapacity(64) }

    mutating func update(_ data: Data) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            update(UnsafeBufferPointer(start: base, count: raw.count))
        }
    }

    mutating func update(_ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { update($0) }
    }

    private mutating func update(_ p: UnsafeBufferPointer<UInt8>) {
        length &+= UInt64(p.count)
        var i = 0
        if !buffer.isEmpty {
            while i < p.count && buffer.count < 64 { buffer.append(p[i]); i += 1 }
            if buffer.count == 64 {
                let block = buffer
                block.withUnsafeBufferPointer { process($0, 0) }
                buffer.removeAll(keepingCapacity: true)
            }
        }
        while i + 64 <= p.count {
            process(p, i)
            i += 64
        }
        while i < p.count { buffer.append(p[i]); i += 1 }
    }

    @inline(__always) private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }

    private mutating func process(_ p: UnsafeBufferPointer<UInt8>, _ o: Int) {
        for t in 0..<16 {
            let j = o + t * 4
            w[t] = UInt32(p[j]) << 24 | UInt32(p[j + 1]) << 16 | UInt32(p[j + 2]) << 8 | UInt32(p[j + 3])
        }
        for t in 16..<64 {
            let s0 = Self.rotr(w[t - 15], 7) ^ Self.rotr(w[t - 15], 18) ^ (w[t - 15] >> 3)
            let s1 = Self.rotr(w[t - 2], 17) ^ Self.rotr(w[t - 2], 19) ^ (w[t - 2] >> 10)
            w[t] = w[t - 16] &+ s0 &+ w[t - 7] &+ s1
        }
        var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
        for t in 0..<64 {
            let S1 = Self.rotr(e, 6) ^ Self.rotr(e, 11) ^ Self.rotr(e, 25)
            let ch = (e & f) ^ (~e & g)
            let t1 = hh &+ S1 &+ ch &+ Self.k[t] &+ w[t]
            let S0 = Self.rotr(a, 2) ^ Self.rotr(a, 13) ^ Self.rotr(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let t2 = S0 &+ maj
            hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
        }
        h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d; h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
    }

    mutating func finalize() -> [UInt8] {
        let bitLength = length &* 8
        var pad: [UInt8] = [0x80]
        let rem = (buffer.count + 1) % 64
        pad += [UInt8](repeating: 0, count: rem <= 56 ? 56 - rem : 120 - rem)
        for i in (0..<8).reversed() { pad.append(UInt8(truncatingIfNeeded: bitLength >> (UInt64(i) * 8))) }
        let saved = length
        update(pad)
        length = saved
        var out: [UInt8] = []
        for v in h { out += [UInt8(v >> 24), UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)] }
        return out
    }

    mutating func finalizeHex() -> String {
        finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func hex(_ data: Data) -> String {
        var s = MioSHA256()
        s.update(data)
        return s.finalizeHex()
    }
}
