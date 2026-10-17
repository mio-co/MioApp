import XCTest
@testable import MioWebCompat

/// 原生 macOS 版（macos/Sources/MioMac）地址栏输入规则
final class MacAddressInputTests: XCTestCase {
    private func r(_ s: String) -> String? { MioMacAddressInput.resolve(s)?.absoluteString }

    private func query(_ s: String) -> String? {
        guard let u = MioMacAddressInput.resolve(s), u.host == "www.google.com", u.path == "/search" else { return nil }
        return URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value
    }

    func testFullURLsKeptAsIs() {
        XCTAssertEqual(r("  https://mio.300031.xyz/mio/nav "), "https://mio.300031.xyz/mio/nav")
        XCTAssertEqual(r("http://example.com/a?b=1"), "http://example.com/a?b=1")
        XCTAssertEqual(r("about:blank"), "about:blank")
    }

    func testDomainsGetHTTPS() {
        XCTAssertEqual(r("example.com"), "https://example.com")
        XCTAssertEqual(r("github.com/mio-co/MioApp?tab=1"), "https://github.com/mio-co/MioApp?tab=1")
        XCTAssertEqual(r("www.youtube.com/watch?v=abc"), "https://www.youtube.com/watch?v=abc")
    }

    func testLocalHostsGetHTTP() {
        XCTAssertEqual(r("localhost:8787/x"), "http://localhost:8787/x")
        XCTAssertEqual(r("192.168.1.1"), "http://192.168.1.1")
    }

    func testEverythingElseSearches() {
        XCTAssertEqual(query("swift tabs"), "swift tabs")
        XCTAssertEqual(query("foo"), "foo")
        XCTAssertEqual(query("a.b"), "a.b")
        XCTAssertEqual(query("1.2.3.999"), "1.2.3.999")
        XCTAssertEqual(query("https://"), "https://")
        XCTAssertNil(MioMacAddressInput.resolve("   "))
    }

    func testHelpers() {
        XCTAssertTrue(MioMacAddressInput.isIPv4("10.0.0.255"))
        XCTAssertFalse(MioMacAddressInput.isIPv4("10.0.0"))
        XCTAssertFalse(MioMacAddressInput.isIPv4("10.0.0.256"))
        XCTAssertTrue(MioMacAddressInput.looksLikeDomain("mio.300031.xyz"))
        XCTAssertFalse(MioMacAddressInput.looksLikeDomain("-a.com"))
        XCTAssertEqual(MioMacAddressInput.hostPart("Example.com:8080/p?q"), "example.com")
        XCTAssertEqual(MioMacAddressInput.displayText(nil), "")
        XCTAssertEqual(MioMacAddressInput.displayText(URL(string: "about:blank")), "")
        XCTAssertEqual(MioMacAddressInput.displayText(URL(string: "https://example.com/")), "https://example.com/")
    }
}
