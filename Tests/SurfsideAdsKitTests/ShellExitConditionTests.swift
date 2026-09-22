import XCTest
@testable import SurfsideAdsKit

/// The shells decide when a fetch is over. These pin the exit rules so a future edit
/// can't quietly bring back the 8s wait on a no-fill.
final class ShellExitConditionTests: XCTestCase {

    private var carouselPage: String {
        ShellHTML.page(for: AdRequest(
            accountId: "a", siteId: "s", channelId: "c", locationId: "l",
            zoneId: "z", category: "all", keywords: "product",
            strategy: "hybrid", maxItems: 4,
            rjsURL: "//x", baseURL: "https://x", userId: nil, cardWidth: 200
        ))
    }

    private var bannerPage: String {
        BannerShellHTML.page(for: BannerRequest(
            accountId: "a", siteId: "s", channelId: "c", locationId: "l", zoneId: "z",
            category: "all", keywords: "product", width: 8, height: 1,
            rjsURL: "//x", baseURL: "https://x"
        ))
    }

    func testCarouselReturnsOnFirstCardsWithoutASettleWait() {
        XCTAssertTrue(carouselPage.contains("if (count > 0) { clearInterval(timer); send('ok', products); return; }"))
        XCTAssertFalse(carouselPage.contains("stableTicks"))
    }

    func testCarouselReportsEmptyWhenTheElementRemovesItself() {
        XCTAssertTrue(carouselPage.contains("sdkDefined() && !document.querySelector('surf-carousel')"))
    }

    func testBannerReportsEmptyShortlyAfterTheBidRequestFinishes() {
        XCTAssertTrue(bannerPage.contains("EMPTY_GRACE_MS = 300"))
        XCTAssertTrue(bannerPage.contains("e.name.indexOf('/rtb/bids') !== -1"))
    }

    func testBannerGivesUpAfterAShortGraceWhenOffline() {
        XCTAssertTrue(bannerPage.contains("OFFLINE_GRACE_MS = 1000"))
        XCTAssertTrue(bannerPage.contains("navigator.onLine === false && waited >= OFFLINE_GRACE_MS"))
    }

    func testBothShellsKeepTheCeilingAsABackstop() {
        XCTAssertTrue(carouselPage.contains("MAX_WAIT_MS = 8000"))
        XCTAssertTrue(bannerPage.contains("MAX_WAIT_MS = 8000"))
    }
}
