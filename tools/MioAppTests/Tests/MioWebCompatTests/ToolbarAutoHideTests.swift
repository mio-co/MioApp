import Foundation
import XCTest
@testable import MioWebCompat

/// 内置浏览器滚动时自动隐藏工具栏的状态机（MioToolbarAutoHide）
final class ToolbarAutoHideTests: XCTestCase {
    /// 长页面：内容 5000，视口 800，隐藏时顶部 inset 22（域名条），底部 inset 49（工具栏）
    private func m(_ y: Double, content: Double = 5000, bottom: Double = 49) -> MioToolbarAutoHide.Metrics {
        .init(offsetY: y, contentHeight: content, viewportHeight: 800, hiddenTopInset: 22, bottomInset: bottom)
    }

    /// 从 from 拖到 to，每步 step，返回途中发生的动作
    private func drag(_ s: inout MioToolbarAutoHide, from: Double, to: Double, step: Double = 4, content: Double = 5000, bottom: Double = 49) -> [MioToolbarAutoHide.Action] {
        s.beginDrag(at: from)
        var actions: [MioToolbarAutoHide.Action] = []
        var y = from
        let dir: Double = to >= from ? 1 : -1
        while (to - y) * dir > 0 {
            y += step * dir
            if (y - to) * dir > 0 { y = to }
            let a = s.scrolled(m(y, content: content, bottom: bottom), userDriven: true)
            if a != .none { actions.append(a) }
        }
        return actions
    }

    func testScrollDownPastThresholdHides() {
        var s = MioToolbarAutoHide(threshold: 16)
        XCTAssertEqual(drag(&s, from: 400, to: 412), [], "12pt < 阈值")
        XCTAssertFalse(s.hidden)
        XCTAssertEqual(drag(&s, from: 412, to: 440), [.hide])
        XCTAssertTrue(s.hidden)
    }

    func testScrollUpPastThresholdShows() {
        var s = MioToolbarAutoHide(threshold: 16)
        _ = drag(&s, from: 400, to: 600)
        XCTAssertTrue(s.hidden)
        XCTAssertEqual(drag(&s, from: 600, to: 590), [], "小幅回拉不显示")
        XCTAssertEqual(drag(&s, from: 590, to: 560), [.show])
        XCTAssertFalse(s.hidden)
    }

    func testDirectionReversalResetsAccumulation() {
        var s = MioToolbarAutoHide(threshold: 16)
        s.beginDrag(at: 400)
        XCTAssertEqual(s.scrolled(m(410), userDriven: true), .none)   // +10
        XCTAssertEqual(s.scrolled(m(402), userDriven: true), .none)   // -8 → 清零
        XCTAssertEqual(s.scrolled(m(412), userDriven: true), .none)   // +10（不是 +20）
        XCTAssertFalse(s.hidden)
        XCTAssertEqual(s.scrolled(m(420), userDriven: true), .hide)   // +18
    }

    func testNeverHidesNearTopAndShowsAtTop() {
        var s = MioToolbarAutoHide(threshold: 16)
        // 顶部（shown 时 offset = -topBar 高度，比如 -96）往下拖 40pt：仍在「顶部区」内，不隐藏
        XCTAssertEqual(drag(&s, from: -96, to: -40), [])
        XCTAssertFalse(s.hidden)
        _ = drag(&s, from: 200, to: 400)
        XCTAssertTrue(s.hidden)
        // 惯性滚回顶部（含点状态栏回顶）：显示
        XCTAssertEqual(s.scrolled(m(-22), userDriven: true), .show)
        // 顶部橡皮筋下拉：保持显示
        XCTAssertEqual(s.scrolled(m(-80), userDriven: true), .none)
        XCTAssertFalse(s.hidden)
    }

    func testProgrammaticScrollsAreIgnored() {
        var s = MioToolbarAutoHide(threshold: 16)
        s.beginDrag(at: 400)
        // 页面 scrollTo / inset 改动引起的 offset 变化
        XCTAssertEqual(s.scrolled(m(900), userDriven: false), .none)
        XCTAssertEqual(s.scrolled(m(1500), userDriven: false), .none)
        XCTAssertFalse(s.hidden)
        // 之后的用户滚动只和最近一次位置比较
        XCTAssertEqual(s.scrolled(m(1504), userDriven: true), .none)
        XCTAssertFalse(s.hidden)
    }

    func testBottomBounceDoesNotToggleAndScrollEndAtBottomShows() {
        var s = MioToolbarAutoHide(threshold: 16)
        _ = drag(&s, from: 3000, to: 4100, bottom: 0)
        XCTAssertTrue(s.hidden)
        let maxY = 5000.0 - 800 + 0
        // 橡皮筋：越过底部再弹回，不显示也不累计
        XCTAssertEqual(s.scrolled(m(maxY + 60, bottom: 0), userDriven: true), .none)
        XCTAssertEqual(s.scrolled(m(maxY + 20, bottom: 0), userDriven: true), .none)
        XCTAssertEqual(s.scrolled(m(maxY, bottom: 0), userDriven: true), .none)
        XCTAssertTrue(s.hidden)
        // 停在底部 → 显示
        XCTAssertEqual(s.scrollEnded(m(maxY, bottom: 0)), .show)
        XCTAssertFalse(s.hidden)
    }

    func testScrollEndMidPageKeepsState() {
        var s = MioToolbarAutoHide(threshold: 16)
        _ = drag(&s, from: 1000, to: 1200)
        XCTAssertEqual(s.scrollEnded(m(1200)), .none)
        XCTAssertTrue(s.hidden)
    }

    func testShortPageAlwaysShows() {
        var s = MioToolbarAutoHide(threshold: 16)
        // 内容比视口短
        XCTAssertEqual(drag(&s, from: 0, to: 100, content: 600), [])
        XCTAssertFalse(s.hidden)
    }

    func testForceShow() {
        var s = MioToolbarAutoHide(threshold: 16)
        _ = drag(&s, from: 400, to: 600)
        XCTAssertEqual(s.forceShow(), .show)
        XCTAssertEqual(s.forceShow(), .none)
        XCTAssertFalse(s.hidden)
    }

    func testNoJitterWhenInsetChangeMovesOffset() {
        // 隐藏后 contentInset 变化可能让 offset 跳一下（非用户驱动）；之后继续向下拖不应来回切换
        var s = MioToolbarAutoHide(threshold: 16)
        XCTAssertEqual(drag(&s, from: 1000, to: 1040), [.hide])
        s.resetTracking()
        XCTAssertEqual(s.scrolled(m(1013), userDriven: false), .none)   // inset 改动导致的 -27
        var actions: [MioToolbarAutoHide.Action] = []
        var y = 1013.0
        for _ in 0..<50 { y += 3; let a = s.scrolled(m(y), userDriven: true); if a != .none { actions.append(a) } }
        XCTAssertEqual(actions, [])
        XCTAssertTrue(s.hidden)
    }
}

final class YouTubeFocusScriptTests: XCTestCase {
    func testIntervalIsSubstitutedAndClamped() {
        XCTAssertTrue(MioWebCompat.youtubeFocusScript(intervalSeconds: 60).contains("Number('60000')"))
        XCTAssertTrue(MioWebCompat.youtubeFocusScript(intervalSeconds: 120).contains("Number('120000')"))
        XCTAssertTrue(MioWebCompat.youtubeFocusScript(intervalSeconds: 1).contains("Number('5000')"))
        XCTAssertFalse(MioWebCompat.youtubeFocusScript(intervalSeconds: 60).contains("__MIO_YT_INTERVAL_MS__"))
        XCTAssertTrue(MioWebCompat.youtubeFocusIntervalChoices.contains(MioWebCompat.youtubeFocusDefaultInterval))
    }

    func testPlayablesFlagIsSubstituted() {
        XCTAssertTrue(MioWebCompat.youtubeFocusScript(intervalSeconds: 60).contains("'1' !== '0'"))
        XCTAssertTrue(MioWebCompat.youtubeFocusScript(intervalSeconds: 60, hidePlayables: false).contains("'0' !== '0'"))
        XCTAssertFalse(MioWebCompat.youtubeFocusScript(intervalSeconds: 60).contains("__MIO_YT_PLAYABLES__"))
    }

    func testNoHTMLStringSinks() {
        for bad in ["innerHTML", "outerHTML", "insertAdjacentHTML", "document.write"] {
            XCTAssertFalse(MioWebCompat.youtubeFocusScriptTemplate.contains(bad), bad)
        }
    }

    func testYouTubeHost() {
        XCTAssertTrue(MioWebCompat.isYouTubeHost("www.youtube.com"))
        XCTAssertTrue(MioWebCompat.isYouTubeHost("m.youtube.com"))
        XCTAssertTrue(MioWebCompat.isYouTubeHost("YouTube.com"))
        XCTAssertFalse(MioWebCompat.isYouTubeHost("notyoutube.com"))
        XCTAssertFalse(MioWebCompat.isYouTubeHost("youtube.com.evil.example"))
        XCTAssertFalse(MioWebCompat.isYouTubeHost(nil))
    }
}
