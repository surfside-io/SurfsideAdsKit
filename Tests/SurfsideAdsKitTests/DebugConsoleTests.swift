import XCTest
@testable import SurfsideAdsKit

final class DebugConsoleTests: XCTestCase {

    func testShippingBuildsLoadUnderThePlainBaseURL() {
        XCTAssertEqual(DebugConsole.pageURL(baseURL: "https://internalhost.com", debug: false)?.absoluteString,
                       "https://internalhost.com")
    }

    func testDebugAddsTheWebSDKFlagAndKeepsExistingQuery() {
        XCTAssertEqual(DebugConsole.pageURL(baseURL: "https://internalhost.com", debug: true)?.absoluteString,
                       "https://internalhost.com/?surf_debug=true")
        XCTAssertEqual(DebugConsole.pageURL(baseURL: "https://shop.example/plp?promo=summer", debug: true)?.absoluteString,
                       "https://shop.example/plp?promo=summer&surf_debug=true")
        XCTAssertEqual(DebugConsole.pageURL(baseURL: "https://x.example/?surf_debug=true", debug: true)?.absoluteString,
                       "https://x.example/?surf_debug=true")
    }

    func testLongConsoleLinesAreTruncated() {
        let line = DebugConsole.format(label: "page", message: String(repeating: "a", count: 5000))
        XCTAssertLessThan(line.count, DebugConsole.maxLineLength + 80)
        XCTAssertTrue(line.hasPrefix("SurfsideAdsKit console [page] "))
        XCTAssertTrue(line.hasSuffix("(5000 chars)"))
    }

    func testWarningsKeepEnoughRoomForABidRequest() {
        let message = "warn " + String(repeating: "a", count: 5000)
        XCTAssertTrue(DebugConsole.format(label: "page", message: message).hasSuffix(String(repeating: "a", count: 50)))
    }
}
