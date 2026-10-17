// MioKitSupport.swift — 小工具：资源加载、平台、钥匙串、JS 字符串、SHA-256（Linux 上没有 CryptoKit）。

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Security)
import Security
#endif

public enum MioKitInfo {
    public static let version = "0.4.1"

    /// 注入脚本里的 platform 字段（与 v0.3.x 一致：ios / mac）
    public static var platform: String {
        #if os(macOS)
        return "mac"
        #else
        return "ios"
        #endif
    }
}

/// 包内资源（Resources/js、Resources/filters）
public enum MioKitResources {
    public static func text(_ name: String, ext: String, dir: String) -> String? {
        let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: dir)
            ?? Bundle.module.resourceURL?.appendingPathComponent(dir).appendingPathComponent("\(name).\(ext)")
        guard let u = url, let s = try? String(contentsOf: u, encoding: .utf8) else { return nil }
        return s
    }

    /// Resources/js/<name>.js（reader / dark / mio-save / mio-translate）
    public static func script(_ name: String) -> String? { text(name, ext: "js", dir: "js") }

    /// Resources/filters/<name>.txt（内置精简规则）
    public static func filter(_ name: String) -> String? { text(name, ext: "txt", dir: "filters") }
}

enum MioJSString {
    /// Swift 字符串 → JS 字符串字面量（JSON 编码，</script> 安全）
    static func literal(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        let t = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(t.dropFirst().dropLast()).replacingOccurrences(of: "</", with: "<\\/")
    }

    static func json(_ obj: Any) -> String {
        guard JSONSerialization.isValidJSONObject(obj), let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return "null" }
        return String(data: d, encoding: .utf8) ?? "null"
    }
}

// MARK: - 密钥存储（翻译 API Key 等）

public protocol MioSecretStore: AnyObject {
    func secret(_ name: String) -> String?
    func setSecret(_ name: String, _ value: String?)
}

/// 内存实现（单测）
public final class MioMemorySecretStore: MioSecretStore {
    var values: [String: String] = [:]
    public init() {}
    public func secret(_ name: String) -> String? { values[name] }
    public func setSecret(_ name: String, _ value: String?) { values[name] = value }
}

/// 钥匙串（service = xyz.mio.<name 前缀>，与 v0.3.x 翻译一致：service xyz.mio.translate / account openai-api-key）。
/// ad-hoc 签名的 Mac 包可能没有钥匙串权限（errSecMissingEntitlement）→ 退回 UserDefaults（v0.3.x 同样的退路 key）
public final class MioKeychainSecretStore: MioSecretStore {
    public static let shared = MioKeychainSecretStore()
    let fallback: MioPrefs
    public init(fallback: MioPrefs = UserDefaults.standard) { self.fallback = fallback }

    /// 这些名字不退回 UserDefaults（登录 Cookie 不能明文落在 plist 里）：钥匙串不可用就不存
    static let keychainOnlyNames: Set<String> = ["access.cookies"]

    /// name → (service, account, 退路 key)
    static func location(_ name: String) -> (String, String, String) {
        switch name {
        case "translate.openai": return ("xyz.mio.translate", "openai-api-key", "mio.translate.openaiKeyFallback")
        default: return ("xyz.mio.kit", name, "mio.kit.secretFallback." + name)
        }
    }

    public func secret(_ name: String) -> String? {
        let (service, account, fb) = Self.location(name)
        #if canImport(Security)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data, let s = String(data: d, encoding: .utf8), !s.isEmpty { return s }
        #endif
        let v = fallback.string(fb, default: "")
        return v.isEmpty ? nil : v
    }

    public func setSecret(_ name: String, _ value: String?) {
        let (service, account, fb) = Self.location(name)
        #if canImport(Security)
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        if let v = value, !v.isEmpty {
            var add = base
            add[kSecValueData as String] = Data(v.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            if SecItemAdd(add as CFDictionary, nil) == errSecSuccess { fallback.set(nil, forKey: fb); return }
            if !Self.keychainOnlyNames.contains(name) { fallback.set(v, forKey: fb) }
            return
        }
        #else
        if let v = value, !v.isEmpty { if !Self.keychainOnlyNames.contains(name) { fallback.set(v, forKey: fb) }; return }
        #endif
        fallback.set(nil, forKey: fb)
    }
}

// MARK: - SHA-256

public enum MioHash {
    public static func sha256Hex(_ data: Data) -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        return MioSHA256.hash(data).map { String(format: "%02x", $0) }.joined()
        #endif
    }

    public static func sha256(_ data: Data) -> Data {
        #if canImport(CryptoKit)
        return Data(SHA256.hash(data: data))
        #else
        return Data(MioSHA256.hash(data))
        #endif
    }

    /// sha384 / sha512 只在有 CryptoKit 的平台上校验（Linux 返回 nil = 跳过）
    static func digest(_ algo: String, _ data: Data) -> Data? {
        switch algo {
        case "sha256": return sha256(data)
        #if canImport(CryptoKit)
        case "sha384": return Data(SHA384.hash(data: data))
        case "sha512": return Data(SHA512.hash(data: data))
        #endif
        default: return nil
        }
    }
}

/// 纯 Swift SHA-256（FIPS 180-4），只在没有 CryptoKit 时用
enum MioSHA256 {
    static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func hash(_ data: Data) -> [UInt8] {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var msg = [UInt8](data)
        let bitLen = UInt64(msg.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in (0..<8).reversed() { msg.append(UInt8((bitLen >> (UInt64(i) * 8)) & 0xff)) }
        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: msg.count, by: 64) {
            for i in 0..<16 {
                let b = chunk + i * 4
                w[i] = UInt32(msg[b]) << 24 | UInt32(msg[b + 1]) << 16 | UInt32(msg[b + 2]) << 8 | UInt32(msg[b + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        return h.flatMap { v in (0..<4).map { UInt8((v >> (24 - UInt32($0) * 8)) & 0xff) } }
    }

    static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
}

/// 与本机系统 WebKit 对应的 Safari 版本 / 桌面 UA（v0.3.x MioBrowserSettings.safariVersion 的同一份逻辑，不依赖 UIKit）
public enum MioWebKitCompat {
    public static let safariVersion: String = {
        let pv = ProcessInfo.processInfo.operatingSystemVersion
        #if os(macOS)
        let plist = NSDictionary(contentsOfFile: "/System/Library/CoreServices/SystemVersion.plist") as? [String: Any]
        let v = MioWebCompat.macOSVersion(systemVersionPlist: plist, processVersion: (pv.majorVersion, pv.minorVersion))
        return MioWebCompat.safariVersion(macOSMajor: v.major, minor: v.minor)
        #else
        return "\(max(pv.majorVersion, 15)).\(pv.minorVersion)"
        #endif
    }()

    public static var desktopUserAgent: String { MioWebCompat.desktopUserAgent(safariVersion: safariVersion) }
}
