import XCTest
@testable import SurfsideAdsKit

/// Locks in the headless max-items guarantee: for any requested `maxItems`, the
/// forced carousel width must yield at least that many card slots, so the SDK
/// mounts exactly `min(maxItems, inventory)` in a single pass with no paging.
final class CarouselWidthMathTests: XCTestCase {

    private func request(maxItems: Int, cardWidth: Int = 200) -> AdRequest {
        AdRequest(
            accountId: "a", siteId: "s", channelId: "c", locationId: "l",
            zoneId: "z", category: "all", keywords: "product",
            strategy: "hybrid", maxItems: maxItems,
            rjsURL: "//x", baseURL: "https://x", cardWidth: cardWidth
        )
    }

    /// Mirror of the SDK's slot math, worst case (full padding subtracted first).
    private func slotsAvailable(_ r: AdRequest) -> Int {
        (r.carouselWidth - AdRequest.itemsPadding) / r.cardWidth   // Int division == floor for positives
    }

    func testSlotsMeetOrExceedMaxItemsAcrossRange() {
        for n in [1, 2, 3, 4, 5, 8, 10, 20, 50] {
            let r = request(maxItems: n)
            XCTAssertGreaterThanOrEqual(
                slotsAvailable(r), n,
                "maxItems=\(n): width \(r.carouselWidth) only affords \(slotsAvailable(r)) slots"
            )
        }
    }

    func testHeadroomIsExactlyTheReserve() {
        // The guarantee should be tight-but-safe: exactly maxItems + slotHeadroom.
        let r = request(maxItems: 4)
        XCTAssertEqual(slotsAvailable(r), 4 + AdRequest.slotHeadroom)
    }

    func testGuaranteeHoldsForOtherCardWidths() {
        for cw in [120, 160, 200, 300] {
            let r = request(maxItems: 6, cardWidth: cw)
            XCTAssertGreaterThanOrEqual(slotsAvailable(r), 6)
        }
    }
}
