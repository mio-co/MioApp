import XCTest
@testable import MioKit

/// 来源校验 + 桥分发：只有 MioCore 来源（默认 https://mio.300031.xyz，可配置）和 mio:// 内置页能用；其他一律 forbidden
final class MioBridgeOriginTests: XCTestCase {
    let prefs = MioMemoryPrefs()
    let core = MioFrameOrigin(scheme: "https", host: "mio.300031.xyz")

    func testDefaultOriginAllowedOnlyInMainFrame() {
        XCTAssertEqual(MioCoreOrigin.check(origin: core, isMainFrame: true, prefs: prefs), .allowed(.mioCore))
        XCTAssertFalse(MioCoreOrigin.check(origin: core, isMainFrame: false, prefs: prefs).isAllowed, "MioCore 里的 iframe 默认也不行")
        XCTAssertTrue(MioCoreOrigin.check(origin: core, isMainFrame: false, prefs: prefs, allowSubframes: true).isAllowed)
        XCTAssertTrue(MioCoreOrigin.check(origin: MioFrameOrigin(scheme: "HTTPS", host: "MIO.300031.XYZ", port: 443), isMainFrame: true, prefs: prefs).isAllowed,
                      "大小写 / 默认端口规范化")
    }

    func testLookalikeOriginsRejected() {
        let bad: [MioFrameOrigin?] = [
            MioFrameOrigin(scheme: "http", host: "mio.300031.xyz"),            // 降级
            MioFrameOrigin(scheme: "https", host: "evil.mio.300031.xyz"),      // 子域名
            MioFrameOrigin(scheme: "https", host: "mio.300031.xyz.evil.com"),  // 后缀伪装
            MioFrameOrigin(scheme: "https", host: "xmio.300031.xyz"),
            MioFrameOrigin(scheme: "https", host: "300031.xyz"),
            MioFrameOrigin(scheme: "https", host: "mio.300031.xyz", port: 8443),
            MioFrameOrigin(scheme: "https", host: "example.com"),
            MioFrameOrigin(scheme: "file", host: "mio.300031.xyz"),
            MioFrameOrigin(scheme: "mio", host: "evil"),                       // 未知内置页
            nil,                                                               // about:blank / data: / 不透明来源
        ]
        for o in bad {
            XCTAssertFalse(MioCoreOrigin.check(origin: o, isMainFrame: true, prefs: prefs).isAllowed, "\(String(describing: o)) 不应放行")
        }
    }

    func testInternalPages() {
        XCTAssertEqual(MioCoreOrigin.check(origin: MioFrameOrigin(scheme: "mio", host: "home"), isMainFrame: true, prefs: prefs), .allowed(.internalPage))
        XCTAssertFalse(MioCoreOrigin.check(origin: MioFrameOrigin(scheme: "mio", host: "home"), isMainFrame: false, prefs: prefs).isAllowed)
    }

    func testConfiguredOrigin() {
        prefs.set("https://my.mio.example:8443/some/path?x=1", forKey: MioCoreOrigin.originKey)
        let custom = MioFrameOrigin(scheme: "https", host: "my.mio.example", port: 8443)
        XCTAssertTrue(MioCoreOrigin.check(origin: custom, isMainFrame: true, prefs: prefs).isAllowed)
        XCTAssertFalse(MioCoreOrigin.check(origin: core, isMainFrame: true, prefs: prefs).isAllowed, "换了地址后旧地址不再放行")
        // 不合法的配置 → 回退默认值（不会变成「谁都行」）
        prefs.set("http://evil.example", forKey: MioCoreOrigin.originKey)
        XCTAssertEqual(MioCoreOrigin.configured(prefs), core)
        prefs.set("javascript:alert(1)", forKey: MioCoreOrigin.originKey)
        XCTAssertEqual(MioCoreOrigin.configured(prefs), core)
    }

    func testNormalize() {
        XCTAssertEqual(MioCoreOrigin.normalize("mio.example.com"), "https://mio.example.com")
        XCTAssertEqual(MioCoreOrigin.normalize("https://Mio.Example.com:443/x"), "https://mio.example.com")
        XCTAssertEqual(MioCoreOrigin.normalize("http://localhost:8787"), "http://localhost:8787")
        XCTAssertNil(MioCoreOrigin.normalize("http://mio.example.com"))
        XCTAssertNil(MioCoreOrigin.normalize("https://user:pw@mio.example.com"))
        XCTAssertNil(MioCoreOrigin.normalize(""))
    }
}

final class FakeBridgeHost: MioCoreBridgeDelegate {
    var opened: [URL] = []
    var saved: [(String, [String: Any])] = []
    var asked: [MioBridgePermission] = []
    var grant = false
    func bridgeDeviceInfo() -> MioDeviceInfo { MioDeviceInfo(platform: "macos", model: "Mac14,7", osVersion: "15.0", appVersion: "0.4.0", appBuild: "10", locale: "zh-Hans") }
    func bridgeOpenTab(_ url: URL, background: Bool) -> Bool { opened.append(url); return true }
    func bridgeSaveToMio(kind: String, payload: [String: Any]) async -> [String: Any] { saved.append((kind, payload)); return ["ok": true, "kind": kind, "id": "n1"] }
    func bridgeRequestPermission(_ permission: MioBridgePermission, origin: MioFrameOrigin) async -> Bool { asked.append(permission); return grant }
}

final class MioBridgeDispatchTests: XCTestCase {
    let prefs = MioMemoryPrefs()
    let host = FakeBridgeHost()
    lazy var bridge: MioCoreBridge = { let b = MioCoreBridge(prefs: prefs); b.delegate = host; return b }()
    let core = MioFrameOrigin(scheme: "https", host: "mio.300031.xyz")
    let evil = MioFrameOrigin(scheme: "https", host: "evil.example")

    func call(_ method: String, _ params: [String: Any] = [:], origin: MioFrameOrigin?, main: Bool = true, v: Int = 1) async -> [String: Any] {
        await bridge.handle(body: ["v": v, "id": "7", "method": method, "params": params], origin: origin, isMainFrame: main)
    }

    func code(_ r: [String: Any]) -> String? { (r["error"] as? [String: Any])?["code"] as? String }

    func testPingAndDeviceInfo() async {
        let r = await call("ping", origin: core)
        XCTAssertEqual(r["ok"] as? Bool, true)
        XCTAssertEqual(r["id"] as? String, "7")
        let res = r["result"] as? [String: Any]
        XCTAssertEqual(res?["api"] as? Int, 1)
        XCTAssertEqual(Set(res?["methods"] as? [String] ?? []), ["ping", "getDeviceInfo", "saveToMio", "openTab"])
        let d = await call("getDeviceInfo", origin: core)
        XCTAssertEqual((d["result"] as? [String: Any])?["model"] as? String, "Mac14,7")
    }

    func testEvilOriginRejectedForEveryMethodWithoutTouchingHost() async {
        for m in MioBridgeMethod.allCases.map({ $0.rawValue }) + ["nope"] {
            let r = await call(m, ["url": "https://example.com", "kind": "bookmark", "payload": ["url": "https://example.com"]], origin: evil)
            XCTAssertEqual(r["ok"] as? Bool, false)
            XCTAssertEqual(code(r), "forbidden", m)
        }
        let sub = await call("openTab", ["url": "https://example.com"], origin: core, main: false)
        XCTAssertEqual(code(sub), "forbidden", "MioCore 的 iframe 也不行")
        let opaque = await call("ping", origin: nil)
        XCTAssertEqual(code(opaque), "forbidden")
        XCTAssertTrue(host.opened.isEmpty)
        XCTAssertTrue(host.saved.isEmpty)
        XCTAssertTrue(host.asked.isEmpty, "被拒的来源连权限询问都不应触发")
    }

    func testVersioningAndUnknownMethod() async {
        let r = await call("ping", origin: core, v: 2)
        XCTAssertEqual(code(r), "unsupported_version")
        let u = await call("rm -rf", origin: core)
        XCTAssertEqual(code(u), "unknown_method")
        let bad = await bridge.handle(body: "hello", origin: core, isMainFrame: true)
        XCTAssertEqual(code(bad), "bad_request")
    }

    func testOpenTabValidatesURL() async {
        let ok = await call("openTab", ["url": "https://example.com/a"], origin: core)
        XCTAssertEqual(ok["ok"] as? Bool, true)
        XCTAssertEqual(host.opened, [URL(string: "https://example.com/a")!])
        for u in ["javascript:alert(1)", "file:///etc/passwd", "mio://evil", "data:text/html,x", ""] {
            let r = await call("openTab", ["url": u], origin: core)
            XCTAssertEqual(code(r), "bad_request", u)
        }
        XCTAssertEqual(host.opened.count, 1)
    }

    func testSaveToMio() async {
        let r = await call("saveToMio", ["kind": "note", "payload": ["url": "https://example.com", "title": "T"]], origin: core)
        XCTAssertEqual(r["ok"] as? Bool, true)
        XCTAssertEqual(host.saved.first?.0, "note")
        let bad = await call("saveToMio", ["kind": "exec", "payload": ["url": "https://example.com"]], origin: core)
        XCTAssertEqual(code(bad), "bad_request")
        // 内置离线页不能保存（只能 basic / tabs）
        let internalPage = await call("saveToMio", ["kind": "note", "payload": ["url": "https://example.com"]], origin: MioFrameOrigin(scheme: "mio", host: "offline"))
        XCTAssertEqual(code(internalPage), "forbidden")
        let internalPing = await call("ping", origin: MioFrameOrigin(scheme: "mio", host: "home"))
        XCTAssertEqual(internalPing["ok"] as? Bool, true)
    }

    func testPermissionModelForFutureMethods() async {
        // 未实现的高权限方法：默认没有权限，也不弹询问
        let r = await call("photos.list", origin: core)
        XCTAssertEqual(code(r), "permission_denied")
        XCTAssertTrue(host.asked.isEmpty)
        // 用户在设置里明确允许后：仍是 not_implemented（接口已定义）
        bridge.permissions.set(.photos, origin: core, granted: true)
        let r2 = await call("photos.list", origin: core)
        XCTAssertEqual(code(r2), "not_implemented")
        // 用户拒绝过的默认权限：直接拒绝
        bridge.permissions.set(.tabs, origin: core, granted: false)
        let r3 = await call("openTab", ["url": "https://example.com"], origin: core)
        XCTAssertEqual(code(r3), "permission_denied")
        XCTAssertTrue(host.opened.isEmpty)
        // 权限按来源记：别的来源（即使将来配置成 MioCore）不继承
        XCTAssertNil(bridge.permissions.decision(.photos, origin: MioFrameOrigin(scheme: "https", host: "other.example")))
        XCTAssertTrue(MioBridgePermission.photos.grantedByDefault == false && MioBridgePermission.deviceControl.grantedByDefault == false)
    }
}

final class MioHomeTests: XCTestCase {
    func testNewTabAndTarget() {
        let prefs = MioMemoryPrefs()
        let home = MioHomeModel(prefs: prefs)
        XCTAssertEqual(home.newTabURL, MioHomeModel.homeURL)
        XCTAssertEqual(home.targetURL.absoluteString, "https://mio.300031.xyz/mio/nav")
        XCTAssertEqual(home.addressBarText(for: URL(string: "mio://home")), "Mio")
        XCTAssertEqual(home.addressBarText(for: URL(string: "https://mio.300031.xyz/mio/nav/")), "Mio")
        XCTAssertNil(home.addressBarText(for: URL(string: "https://example.com")))
        XCTAssertEqual(home.addressBarText(for: URL(string: "mio://about")), "mio://about")
    }

    func testLegacyNewTabMigration() {
        // v0.3.x 默认值 / MioCore 地址 → mio://home；用户自定义的别的网站 → 继续用
        let p1 = MioMemoryPrefs([MioHomeModel.legacyNewTabKey: "https://mio.300031.xyz/mio/nav"])
        XCTAssertEqual(MioHomeModel(prefs: p1).newTabURL, MioHomeModel.homeURL)
        let p2 = MioMemoryPrefs([MioHomeModel.legacyNewTabKey: "https://news.ycombinator.com"])
        XCTAssertEqual(MioHomeModel(prefs: p2).newTabURL.host, "news.ycombinator.com")
        let p3 = MioMemoryPrefs([MioHomeModel.legacyNewTabKey: "https://mio.300031.xyz/other"])
        XCTAssertEqual(MioHomeModel(prefs: p3).newTabURL, MioHomeModel.homeURL)
    }

    func testResponses() {
        let prefs = MioMemoryPrefs([MioCoreOrigin.originKey: "https://my.mio.example", MioHomeModel.homePathKey: "/start"])
        let home = MioHomeModel(prefs: prefs)
        let r = home.response(for: URL(string: "mio://home")!)
        XCTAssertEqual(r.statusCode, 200)
        let html = String(decoding: r.body, as: UTF8.self)
        XCTAssertTrue(html.contains(#"location.replace("https:\/\/my.mio.example\/start")"#) || html.contains(#"location.replace("https://my.mio.example/start")"#), html)
        XCTAssertTrue(r.headers["Content-Security-Policy"]?.contains("default-src 'none'") == true)
        let off = home.response(for: home.offlineURL(failed: URL(string: "https://my.mio.example/start")))
        XCTAssertTrue(String(decoding: off.body, as: UTF8.self).contains("my.mio.example"))
        let evilRetry = home.response(for: URL(string: "mio://offline?url=javascript:alert(1)")!)
        XCTAssertFalse(String(decoding: evilRetry.body, as: UTF8.self).contains("javascript:"), "重试链接只接受 http(s) / mio://")
        XCTAssertEqual(home.response(for: URL(string: "mio://nope")!).statusCode, 404)
        XCTAssertTrue(String(decoding: home.response(for: MioHomeModel.aboutURL).body, as: UTF8.self).contains("Mozilla Public License 2.0"))
        // 路径穿越 / 协议相对 → 回默认路径
        prefs.set("//evil.example", forKey: MioHomeModel.homePathKey)
        XCTAssertEqual(MioHomeModel(prefs: prefs).targetURL.absoluteString, "https://my.mio.example/mio/nav")
    }
}
