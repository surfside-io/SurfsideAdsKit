import XCTest
@testable import SurfsideAdsKit

/// Covers the pure, host-runnable half of the banner path: the shell builder emits
/// a `<surf-banner>` carrying every bid attribute for a given request, plus r.js and
/// the watcher script. The visible-WebView behavior (clickthrough, collapse, sizing)
/// needs a device host and is documented as integration-only, like the fetch path.
final class BannerShellHTMLTests: XCTestCase {

    private func request(width: Int = 320, height: Int = 50) -> BannerRequest {
        BannerRequest(
            accountId: "ec981", siteId: "544fa", channelId: "00000",
            locationId: "greengoddess", zoneId: "6ambm",
            category: "all", keywords: "product",
            width: width, height: height,
            rjsURL: "//cdn.surfside.io/ads/2.0.0/r.js",
            baseURL: "https://internalhost.com"
        )
    }

    func testPageEmitsAllBidAttributes() {
        let html = BannerShellHTML.page(for: request())

        XCTAssertTrue(html.contains("<surf-banner"))
        XCTAssertTrue(html.contains(#"account-id="ec981""#))
        XCTAssertTrue(html.contains(#"site-id="544fa""#))
        XCTAssertTrue(html.contains(#"channel-id="00000""#))
        XCTAssertTrue(html.contains(#"location-id="greengoddess""#))
        XCTAssertTrue(html.contains(#"zone-id="6ambm""#))
        XCTAssertTrue(html.contains(#"category="all""#))
        XCTAssertTrue(html.contains(#"keywords="product""#))
    }

    func testPageEmitsWidthAndHeightAsAttributes() {
        let html = BannerShellHTML.page(for: request(width: 300, height: 250))
        XCTAssertTrue(html.contains(#"width="300""#))
        XCTAssertTrue(html.contains(#"height="250""#))
    }

    func testPageLoadsRjsAndWatcherChannel() {
        let html = BannerShellHTML.page(for: request())
        XCTAssertTrue(html.contains(#"<script src="//cdn.surfside.io/ads/2.0.0/r.js">"#))
        // The watcher must post over the banner channel the Swift handler registers.
        XCTAssertTrue(html.contains("window.webkit.messageHandlers.\(BannerRequest.channelName)"))
        // Empty-vs-timeout split mirrors the carousel scraper.
        XCTAssertTrue(html.contains("customElements.get('surf-banner')"))
    }

    func testChannelNameIsDistinctFromCarousel() {
        // The two shells must not share a channel or their handlers cross-talk.
        XCTAssertNotEqual(BannerRequest.channelName, AdRequest.channelName)
    }
}
