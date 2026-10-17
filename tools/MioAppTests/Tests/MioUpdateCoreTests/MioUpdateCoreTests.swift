import Foundation
import XCTest
@testable import MioUpdateCore

/// 软件内更新纯逻辑（ios/App/App/MioUpdateCore.swift）
final class MioUpdateCoreTests: XCTestCase {
    let abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    func testCompareVersions() {
        XCTAssertEqual(MioUpdateCore.compare("0.3.3", "0.3.2"), 1)
        XCTAssertEqual(MioUpdateCore.compare("v0.3.2", "0.3.2"), 0)
        XCTAssertEqual(MioUpdateCore.compare("0.3", "0.3.0"), 0)
        XCTAssertEqual(MioUpdateCore.compare("0.10.0", "0.9.9"), 1)
        XCTAssertEqual(MioUpdateCore.compare("1.0.0", "1.0.0-beta.2"), 1)
        XCTAssertEqual(MioUpdateCore.compare("1.0.0-beta.2", "1.0.0-beta.10"), -1)
        XCTAssertEqual(MioUpdateCore.compare("1.0.0-alpha", "1.0.0-alpha.1"), -1)
        XCTAssertEqual(MioUpdateCore.compare("1.0.0-alpha.beta", "1.0.0-alpha.1"), 1)
        XCTAssertEqual(MioUpdateCore.compare("1.0.0+build.5", "1.0.0"), 0)
        XCTAssertEqual(MioUpdateCore.compare("1.2.3.4", "1.2.3"), 1)
        XCTAssertNil(MioUpdateCore.compare("latest", "1.0.0"))
        XCTAssertNil(MioUpdateCore.compare("", "1.0.0"))
        XCTAssertNil(MioUpdateCore.compare("1..2", "1.0.0"))
        XCTAssertNil(MioUpdateCore.compare("1.0.0-", "1.0.0"))
        XCTAssertTrue(MioUpdateCore.isNewer("v0.3.3", than: "0.3.2"))
        XCTAssertFalse(MioUpdateCore.isNewer("v0.3.2", than: "0.3.2"))
        XCTAssertFalse(MioUpdateCore.isNewer("garbage", than: "0.3.2"))
    }

    private func releaseJSON(prerelease: Bool = false, draft: Bool = false, tag: String = "v0.3.3", html: String = "https://github.com/mio-co/MioApp/releases/tag/v0.3.3") -> Data {
        let j = """
        {"tag_name":"\(tag)","name":"Mio v0.3.3","body":"## 新功能\\n- **更新**","html_url":"\(html)","draft":\(draft),"prerelease":\(prerelease),
         "assets":[
          {"name":"Mio-0.3.3-mac.zip","browser_download_url":"https://github.com/mio-co/MioApp/releases/download/v0.3.3/Mio-0.3.3-mac.zip","size":5205462,"digest":"sha256:\(abc)"},
          {"name":"Mio.ipa","browser_download_url":"https://github.com/mio-co/MioApp/releases/download/v0.3.3/Mio.ipa","size":5254697,"digest":null},
          {"name":"SHA256SUMS.txt","browser_download_url":"https://github.com/mio-co/MioApp/releases/download/v0.3.3/SHA256SUMS.txt","size":800},
          {"name":"evil","browser_download_url":"http://insecure/evil","size":1}
         ]}
        """
        return Data(j.utf8)
    }

    func testParseRelease() throws {
        let r = try XCTUnwrap(MioUpdateCore.parseRelease(releaseJSON()))
        XCTAssertEqual(r.version, "0.3.3")
        XCTAssertEqual(r.tag, "v0.3.3")
        XCTAssertEqual(r.assets.count, 3)
        XCTAssertEqual(r.macZip?.size, 5205462)
        XCTAssertEqual(r.macZip?.digest, "sha256:\(abc)")
        XCTAssertNil(r.ipa?.digest)
        XCTAssertNil(r.asset(named: "evil"))
        XCTAssertEqual(r.page.absoluteString, "https://github.com/mio-co/MioApp/releases/tag/v0.3.3")
        XCTAssertNil(try MioUpdateCore.parseRelease(releaseJSON(prerelease: true)))
        XCTAssertNil(try MioUpdateCore.parseRelease(releaseJSON(draft: true)))
        XCTAssertNil(try MioUpdateCore.parseRelease(releaseJSON(tag: "nightly")))
        XCTAssertEqual(try MioUpdateCore.parseRelease(releaseJSON(html: "https://evil.example/"))?.page, MioUpdateCore.releasesPage)
        XCTAssertThrowsError(try MioUpdateCore.parseRelease(Data("not json".utf8)))
    }

    func testParseSha256Sums() {
        let text = "# comment\r\n\(abc.uppercased()) *Mio.apk\r\n\(abc)  Mio-0.3.3-mac.zip\nSHA256 (Mio.ipa) = \(abc)\n\ngarbage\n"
        let sums = MioUpdateCore.parseSha256Sums(text)
        XCTAssertEqual(sums["Mio.apk"], abc)
        XCTAssertEqual(sums["Mio-0.3.3-mac.zip"], abc)
        XCTAssertEqual(sums["Mio.ipa"], abc)
        XCTAssertEqual(sums.count, 3)
        XCTAssertEqual(MioUpdateCore.parseSha256Sums(abc + "\n")[""], abc)
    }

    func testExpectedSha256() throws {
        let r = try XCTUnwrap(MioUpdateCore.parseRelease(releaseJSON()))
        let zip = try XCTUnwrap(r.macZip)
        let ipa = try XCTUnwrap(r.ipa)
        XCTAssertEqual(try MioUpdateCore.expectedSha256(for: zip, sums: ["Mio-0.3.3-mac.zip": abc]), abc)
        XCTAssertEqual(try MioUpdateCore.expectedSha256(for: zip, sums: nil), abc) // 只有 GitHub digest
        XCTAssertEqual(try MioUpdateCore.expectedSha256(for: ipa, sums: ["Mio.ipa": abc]), abc) // 只有清单
        XCTAssertThrowsError(try MioUpdateCore.expectedSha256(for: zip, sums: ["Mio-0.3.3-mac.zip": String(repeating: "0", count: 64)])) {
            XCTAssertEqual($0 as? MioUpdateCore.ChecksumError, .mismatchBetweenSources("Mio-0.3.3-mac.zip"))
        }
        XCTAssertThrowsError(try MioUpdateCore.expectedSha256(for: ipa, sums: nil)) {
            XCTAssertEqual($0 as? MioUpdateCore.ChecksumError, .missing("Mio.ipa"))
        }
        XCTAssertTrue(MioUpdateCore.sha256Matches(abc, abc.uppercased() + " "))
        XCTAssertFalse(MioUpdateCore.sha256Matches("", abc))
    }

    func testSHA256Vectors() {
        XCTAssertEqual(MioSHA256.hex(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(MioSHA256.hex(Data("abc".utf8)), abc)
        XCTAssertEqual(MioSHA256.hex(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        // 55 / 56 / 64 字节：填充边界
        XCTAssertEqual(MioSHA256.hex(Data(repeating: 0x61, count: 55)), "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318")
        XCTAssertEqual(MioSHA256.hex(Data(repeating: 0x61, count: 56)), "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a")
        XCTAssertEqual(MioSHA256.hex(Data(repeating: 0x61, count: 64)), "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb")
        // 一百万个 'a'
        XCTAssertEqual(MioSHA256.hex(Data(repeating: 0x61, count: 1_000_000)), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    func testSHA256StreamingMatchesOneShot() throws {
        var bytes = [UInt8](repeating: 0, count: 300_007)
        var x: UInt32 = 2463534242
        for i in bytes.indices { x ^= x << 13; x ^= x >> 17; x ^= x << 5; bytes[i] = UInt8(truncatingIfNeeded: x) }
        let one = MioSHA256.hex(Data(bytes))
        var s = MioSHA256()
        var i = 0
        for n in [1, 63, 64, 65, 1000, 4096, 7] {
            s.update(Array(bytes[i..<(i + n)]))
            i += n
        }
        s.update(Array(bytes[i...]))
        XCTAssertEqual(s.finalizeHex(), one)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mio-sha-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try MioUpdateCore.sha256Hex(ofFile: url), one)
    }

    func testShouldAutoCheck() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let h: TimeInterval = 3600
        XCTAssertTrue(MioUpdateCore.shouldAutoCheck(enabled: true, lastCheck: nil, lastAttempt: nil, now: now))
        XCTAssertFalse(MioUpdateCore.shouldAutoCheck(enabled: false, lastCheck: nil, lastAttempt: nil, now: now))
        XCTAssertFalse(MioUpdateCore.shouldAutoCheck(enabled: true, lastCheck: now - 23 * h, lastAttempt: now - 23 * h, now: now))
        XCTAssertTrue(MioUpdateCore.shouldAutoCheck(enabled: true, lastCheck: now - 25 * h, lastAttempt: now - 2 * h, now: now))
        XCTAssertFalse(MioUpdateCore.shouldAutoCheck(enabled: true, lastCheck: now - 25 * h, lastAttempt: now - 0.5 * h, now: now))
        XCTAssertTrue(MioUpdateCore.shouldAutoCheck(enabled: true, lastCheck: now + 5 * h, lastAttempt: now + 5 * h, now: now))
    }

    func testPlainNotes() {
        XCTAssertEqual(MioUpdateCore.plainNotes("## 新功能\n- **更新** `x` [链接](https://x)\n\n\n\nend"), "新功能\n- 更新 x 链接\n\nend")
        XCTAssertEqual(MioUpdateCore.plainNotes(String(repeating: "y", count: 20), maxLength: 5).count, 5)
    }

    func testDeepLinks() {
        let links = MioUpdateCore.addSourceDeepLinks()
        XCTAssertEqual(links.map { $0.scheme }, ["sidestore", "altstore-classic", "altstore"])
        let enc = "https%3A%2F%2Fgithub.com%2Fmio-co%2FMioApp%2Freleases%2Flatest%2Fdownload%2Faltstore-source.json"
        XCTAssertEqual(links[0].absoluteString, "sidestore://source?url=\(enc)")
        XCTAssertEqual(URLComponents(url: links[0], resolvingAgainstBaseURL: false)?.queryItems?.first?.value, MioUpdateCore.altStoreSourceURL)
    }

    func testCanReplaceInPlace() {
        XCTAssertTrue(MioUpdateCore.canReplaceInPlace(bundlePath: "/Applications/Mio.app"))
        XCTAssertTrue(MioUpdateCore.canReplaceInPlace(bundlePath: "/Users/a/Applications/Mio.app"))
        XCTAssertFalse(MioUpdateCore.canReplaceInPlace(bundlePath: "/private/var/folders/x/T/AppTranslocation/ABC/d/Mio.app"))
        XCTAssertFalse(MioUpdateCore.canReplaceInPlace(bundlePath: "/Volumes/Mio 0.3.3/Mio.app"))
        XCTAssertFalse(MioUpdateCore.canReplaceInPlace(bundlePath: "/usr/local/bin/mio"))
    }

    func testMacInstallScriptUsesPositionalArgs() {
        let s = MioUpdateCore.macInstallScript
        XCTAssertTrue(s.hasPrefix("#!/bin/sh\n"))
        XCTAssertTrue(s.contains(#"PID="$1"; ZIP="$2"; TARGET="$3"; WORK="$4"; LOG="$5"; BUNDLE_ID="$6""#))
        XCTAssertTrue(s.contains(#"/bin/mv "$WORK/old.app" "$TARGET""#))
    }

    /// v0.4.0（iOS = firefox-ios fork、Mac = 原生 AppKit）发版后，已装的 v0.3.3 / v0.3.4（Capacitor iOS、Mac Catalyst）更新器
    /// 用同一份 MioUpdateCore（v0.3.3 → v0.3.4 只改了注释）：能发现新版本、找到 Mac zip / ipa、拿到校验值
    func testV040ReleaseIsFoundByV03xUpdaters() throws {
        let zipSha = String(repeating: "a", count: 64), dmgSha = String(repeating: "b", count: 64), ipaSha = String(repeating: "c", count: 64)
        let json = """
        {"tag_name":"v0.4.0","name":"Mio 0.4.0","body":"Apple-only","html_url":"https://github.com/mio-co/MioApp/releases/tag/v0.4.0",
         "draft":false,"prerelease":false,"assets":[
          {"name":"Mio.ipa","browser_download_url":"https://github.com/mio-co/MioApp/releases/download/v0.4.0/Mio.ipa","size":90000000,"digest":"sha256:\(ipaSha)"},
          {"name":"Mio-0.4.0-mac.zip","browser_download_url":"https://github.com/mio-co/MioApp/releases/download/v0.4.0/Mio-0.4.0-mac.zip","size":9000000,"digest":"sha256:\(zipSha)"},
          {"name":"Mio-0.4.0-mac.dmg","browser_download_url":"https://github.com/mio-co/MioApp/releases/download/v0.4.0/Mio-0.4.0-mac.dmg","size":9500000,"digest":"sha256:\(dmgSha)"},
          {"name":"SHA256SUMS.txt","browser_download_url":"https://github.com/mio-co/MioApp/releases/download/v0.4.0/SHA256SUMS.txt","size":300},
          {"name":"altstore-source.json","browser_download_url":"https://github.com/mio-co/MioApp/releases/download/v0.4.0/altstore-source.json","size":2000}
        ]}
        """
        let r = try XCTUnwrap(MioUpdateCore.parseRelease(Data(json.utf8)))
        XCTAssertEqual(r.version, "0.4.0")
        XCTAssertTrue(MioUpdateCore.isNewer(r.version, than: "0.3.3"))
        XCTAssertTrue(MioUpdateCore.isNewer(r.version, than: "0.3.4"))
        XCTAssertEqual(r.macZip?.name, "Mio-0.4.0-mac.zip", "Catalyst 更新器只认 zip，不能挑到 dmg")
        XCTAssertEqual(r.ipa?.name, "Mio.ipa")
        let sums = MioUpdateCore.parseSha256Sums("\(ipaSha)  Mio.ipa\n\(zipSha)  Mio-0.4.0-mac.zip\n\(dmgSha)  Mio-0.4.0-mac.dmg\n")
        XCTAssertEqual(try MioUpdateCore.expectedSha256(for: XCTUnwrap(r.macZip), sums: sums), zipSha)
        XCTAssertEqual(MioUpdateCore.bundleIdentifier, "xyz.mio.app", "Mac 原生版必须沿用 xyz.mio.app，否则安装脚本拒绝替换")
    }
}
