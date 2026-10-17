import XCTest
@testable import MioWebCompat

final class CloseAfterExternalTests: XCTestCase {
    private let url = URL(string: "https://example.com/login")!

    private func run(enabled: Bool, openResult: Bool) -> (opened: [URL], closed: Int, report: (Bool, Bool)?) {
        var opened: [URL] = []
        var closed = 0
        var report: (Bool, Bool)?
        MioCloseAfterExternal.handOff(url, enabled: enabled, open: { u, done in
            opened.append(u)
            done(openResult)
        }, close: { closed += 1 }, completion: { report = ($0, $1) })
        return (opened, closed, report)
    }

    func testClosesAfterSuccessfulOpenWhenEnabled() {
        let r = run(enabled: true, openResult: true)
        XCTAssertEqual(r.opened, [url])
        XCTAssertEqual(r.closed, 1)
        XCTAssertEqual(r.report?.0, true)
        XCTAssertEqual(r.report?.1, true)
    }

    func testDoesNotCloseWhenOpenFails() {
        let r = run(enabled: true, openResult: false)
        XCTAssertEqual(r.opened, [url])
        XCTAssertEqual(r.closed, 0)
        XCTAssertEqual(r.report?.0, false)
        XCTAssertEqual(r.report?.1, false)
    }

    func testDoesNotCloseWhenDisabled() {
        let r = run(enabled: false, openResult: true)
        XCTAssertEqual(r.closed, 0)
        XCTAssertEqual(r.report?.1, false)
    }

    func testClosesOnlyInsideOpenCompletion() {
        var pending: ((Bool) -> Void)?
        var closed = 0
        MioCloseAfterExternal.handOff(url, enabled: true, open: { _, done in pending = done }, close: { closed += 1 })
        XCTAssertEqual(closed, 0, "open 还没回调前不能关闭")
        pending?(true)
        XCTAssertEqual(closed, 1)
    }

    func testSettingDefaultsOffAndPersists() {
        let suite = "mio.test.closeAfterExternal.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertFalse(MioCloseAfterExternal.isEnabled(d))
        MioCloseAfterExternal.setEnabled(true, d)
        XCTAssertTrue(MioCloseAfterExternal.isEnabled(d))
        XCTAssertEqual(MioCloseAfterExternal.enabledKey, "mio.closeTab.afterExternal")
    }
}
