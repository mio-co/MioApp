import XCTest
@testable import MioKit

/// 链接 / 弹窗开在哪（Mac 照 Firefox：普通 target=_blank / window.open 前台，⌘ / 中键后台，⇧ 反转；iOS 前台）
final class MioLinkOpeningTests: XCTestCase {
    typealias L = MioLinkOpening

    func testMiddleButtonMask() {
        XCTAssertTrue(L.isMiddleButton(4))
        XCTAssertFalse(L.isMiddleButton(0), "键盘 / 脚本触发")
        XCTAssertFalse(L.isMiddleButton(1), "左键")
        XCTAssertFalse(L.isMiddleButton(2), "右键")
    }

    func testMacNewWindowRequests() {
        // 普通左键点 target=_blank / window.open（用户手势）→ 前台
        XCTAssertEqual(L.newWindow(platform: .mac, modifiers: [], buttonNumber: 1), .foregroundTab)
        XCTAssertEqual(L.newWindow(platform: .mac, modifiers: [], buttonNumber: 0), .foregroundTab)
        // ⌘ / 中键 → 后台；⇧⌘ / ⇧中键 → 前台
        XCTAssertEqual(L.newWindow(platform: .mac, modifiers: [.command], buttonNumber: 1), .backgroundTab)
        XCTAssertEqual(L.newWindow(platform: .mac, modifiers: [], buttonNumber: 4), .backgroundTab)
        XCTAssertEqual(L.newWindow(platform: .mac, modifiers: [.command, .shift], buttonNumber: 1), .foregroundTab)
        XCTAssertEqual(L.newWindow(platform: .mac, modifiers: [.shift], buttonNumber: 4), .foregroundTab)
        // ⇧ 单独 / ⌥ 不改变
        XCTAssertEqual(L.newWindow(platform: .mac, modifiers: [.shift], buttonNumber: 1), .foregroundTab)
        XCTAssertEqual(L.newWindow(platform: .mac, modifiers: [.option], buttonNumber: 1), .foregroundTab)
    }

    func testMacLinkActivation() {
        // 普通左键点同标签链接：交给 WebKit
        XCTAssertEqual(L.linkActivation(platform: .mac, isLinkActivated: true, isHTTP: true, modifiers: [], buttonNumber: 1), .currentTab)
        // ⌘ / 中键点链接（同标签链接也一样）→ 后台新标签
        XCTAssertEqual(L.linkActivation(platform: .mac, isLinkActivated: true, isHTTP: true, modifiers: [.command], buttonNumber: 1), .backgroundTab)
        XCTAssertEqual(L.linkActivation(platform: .mac, isLinkActivated: true, isHTTP: true, modifiers: [], buttonNumber: 4), .backgroundTab)
        XCTAssertEqual(L.linkActivation(platform: .mac, isLinkActivated: true, isHTTP: true, modifiers: [.command, .shift], buttonNumber: 1), .foregroundTab)
        // 不是点链接（表单提交 / 脚本跳转 / 重载）、不是 http(s)（mailto: / mio://）：不管
        XCTAssertEqual(L.linkActivation(platform: .mac, isLinkActivated: false, isHTTP: true, modifiers: [.command], buttonNumber: 0), .currentTab)
        XCTAssertEqual(L.linkActivation(platform: .mac, isLinkActivated: true, isHTTP: false, modifiers: [.command], buttonNumber: 1), .currentTab)
    }

    func testIOSAlwaysForeground() {
        XCTAssertEqual(L.newWindow(platform: .ios, modifiers: [], buttonNumber: 0), .foregroundTab)
        XCTAssertEqual(L.newWindow(platform: .ios, modifiers: [.command], buttonNumber: 0), .foregroundTab)
        XCTAssertEqual(L.linkActivation(platform: .ios, isLinkActivated: true, isHTTP: true, modifiers: [.command], buttonNumber: 0), .foregroundTab)
        XCTAssertEqual(L.linkActivation(platform: .ios, isLinkActivated: true, isHTTP: true, modifiers: [], buttonNumber: 0), .currentTab)
    }
}
