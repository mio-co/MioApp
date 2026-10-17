// MioMacAdblockSmoke.swift — 冒烟里的广告拦截深度检查（MioMacSmoke 调用，结果在 smoke.json 的 "adblock"，门槛 adblockOK）：
//   订阅真实下载 + 编译（内容规则 > 1 万）、测试页请求被拦、## 元素隐藏、真实列表里的 scriptlet（set-constant）生效；
//   adblock.turtlecute.org 打分 + 截图（mac-native-smoke/adblock-*.png，只记录）。
// 用 App 自己的 MioMacKit（同一个 MioContentBlocker / 规则表），在独立 WebView 里跑 MioKit 的 MioAdblockProbe。

import AppKit
import Foundation
@preconcurrency import MioKit
import WebKit

@MainActor
enum MioMacAdblockSmoke {
    static func run(host: MioMacKit, shotsDir: String) async -> [String: Any] {
        let started = Date()
        let ready = await MioAdblockProbe.waitForRules(host.blocker, minContentRules: 10_000, timeout: 300)
        var r: [String: Any] = ["rulesReady": ready, "rulesReadySeconds": Int(Date().timeIntervalSince(started))]
        let (wv, mods, loader) = MioAdblockProbe.standalone(kit: host.kit, blocker: host.blocker)
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 1100, height: 1300), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Mio adblock smoke"
        window.contentView = wv
        window.orderFront(nil)
        defer { window.orderOut(nil); withExtendedLifetime(mods) {} }
        let probe = await MioAdblockProbe.run(blocker: host.blocker, webView: wv) { html, base in
            await MioAdblockProbe.loadHTML(wv, mods, loader, html: html, base: base)
        }
        for (k, v) in probe { r[k] = v }
        save(await MioAdblockProbe.snapshotPNG(wv), shotsDir, "adblock-probe-page.png")
        await MioAdblockProbe.loadURL(wv, mods, loader, url: MioAdblockProbe.scoreSite)
        let score = await MioAdblockProbe.turtlecuteScore(wv, settle: 40)
        r["turtlecute"] = score
        save(await MioAdblockProbe.snapshotPNG(wv), shotsDir, "adblock-turtlecute.png")
        r["seconds"] = Int(Date().timeIntervalSince(started))
        return r
    }

    private static func save(_ png: Data?, _ dir: String, _ name: String) {
        guard let png, !dir.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }
}
