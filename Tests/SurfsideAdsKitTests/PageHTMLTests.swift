import XCTest
@testable import SurfsideAdsKit

final class PageHTMLTests: XCTestCase {

    private func request(zoneId: String = "3ZG7D", category: String = "all", maxItems: Int = 4) -> AdRequest {
        AdRequest(
            accountId: "94907", siteId: "a63ef", channelId: "482cf", locationId: "10002",
            zoneId: zoneId, category: category, keywords: "product",
            strategy: "hybrid", maxItems: maxItems,
            rjsURL: "//cdn.surfside.io/ads/2.0.0/r.js", baseURL: "https://internalhost.com",
            userId: nil, cardWidth: 200
        )
    }

    func testPageLoadsRjsOnceAndShipsNoCarousel() {
        let page = PageHTML.page(rjsURL: "//cdn.surfside.io/ads/2.0.0/r.js")
        XCTAssertEqual(page.components(separatedBy: "<script src=").count - 1, 1)
        XCTAssertFalse(page.contains("account-id="), "no carousel markup; elements are created per fetch")
        XCTAssertTrue(page.contains("document.createElement('surf-carousel')"))
        XCTAssertTrue(page.contains("function surfFetch(id, attrs, width, expected)"))
        XCTAssertTrue(page.contains("messageHandlers.\(CarouselPage.channelName)"))
    }

    func testPageUsesTheSameCardMappingAsTheOneShotShell() {
        XCTAssertTrue(PageHTML.page(rjsURL: "//x").contains("function surfMapCards(carousel)"))
        XCTAssertTrue(ShellHTML.page(for: request()).contains("function surfMapCards(carousel)"))
    }

    func testFetchCallCarriesEveryBidAttributeAndTheForcedWidth() throws {
        let r = request(maxItems: 6)
        let call = try XCTUnwrap(PageHTML.fetchCall(id: "abc", request: r))
        for fragment in ["\"account-id\":\"94907\"", "\"site-id\":\"a63ef\"", "\"channel-id\":\"482cf\"",
                         "\"location-id\":\"10002\"", "\"zone-id\":\"3ZG7D\"", "\"strategy\":\"hybrid\"",
                         "\"max-items\":\"6\"", "\"card-max-width\":\"200\""] {
            XCTAssertTrue(call.contains(fragment), fragment)
        }
        XCTAssertTrue(call.hasPrefix("surfFetch([\"abc\"][0], {"))
        XCTAssertTrue(call.hasSuffix(", \(r.carouselWidth), 6);"))
    }

    func testFetchCallEscapesHostSuppliedStrings() throws {
        let hostile = "\"});alert(1);//"
        let call = try XCTUnwrap(PageHTML.fetchCall(id: "x", request: request(category: hostile)))
        // The attributes argument must still be one valid JSON object that round-trips
        // the hostile value, i.e. it never terminated the literal early.
        let start = try XCTUnwrap(call.range(of: "[0], "))
        let end = try XCTUnwrap(call.range(of: "}, ", options: .backwards))
        let json = String(call[start.upperBound..<end.upperBound].dropLast(2))
        let attrs = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String])
        XCTAssertEqual(attrs["category"], hostile)
    }
}
