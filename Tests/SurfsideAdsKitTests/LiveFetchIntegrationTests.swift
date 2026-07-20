import XCTest
@testable import SurfsideAdsKit

/// LIVE integration test — hits a real Surfside zone through the real hidden
/// WebView. It answers the open question the unit tests can't: does an *un-hosted*
/// `WKWebView` (created in the package, never added to a view hierarchy) actually
/// run the ads SDK and tick its JS timers?
///
/// Gated behind `SURFSIDE_LIVE=1` so the normal `swift test` run stays offline and
/// deterministic. Run it against the iOS simulator, where the WebView behaves like
/// it will in a shipping app:
///
///   SURFSIDE_LIVE=1 xcodebuild test \
///     -scheme SurfsideAdsKit \
///     -destination 'platform=iOS Simulator,name=iPhone 16' \
///     -only-testing:SurfsideAdsKitTests/LiveFetchIntegrationTests
///
/// CAVEAT (found 2026-07-20): a SwiftPM *logic-test* bundle has NO host app, so
/// WebKit's networking process can't configure (logs: "Failed to resolve host
/// network app id to config: com.apple.WebKit.Networking") and r.js never loads —
/// the run below times out for that reason, NOT necessarily because the un-hosted
/// WebView is broken. XCTest logic tests are not a faithful venue for this. The
/// real verification is running the package inside an actual app (the sample app
/// or a tiny demo host), where there IS a bundle id — as the proven spike did.
final class LiveFetchIntegrationTests: XCTestCase {

    private var isLive: Bool {
        ProcessInfo.processInfo.environment["SURFSIDE_LIVE"] == "1"
    }

    // Known-good "green goddess" zone from the proven Phase-0 spike.
    private func makeAds() -> SurfsideAds {
        SurfsideAds(configuration: .init(
            accountId: "ec981",
            siteId: "544fa",
            channelId: "00000",
            locationId: "greengoddess",
            requestTimeout: 20,
            isInspectable: true
        ))
    }

    func testHeadlessFetchReturnsProducts() throws {
        try XCTSkipUnless(isLive, "Set SURFSIDE_LIVE=1 to run the live WebView fetch.")

        let ads = makeAds()
        let done = expectation(description: "fetch resolves")
        var received: Result<[SurfsideProduct], Error>?

        ads.fetchProducts(zoneId: "6ambm", maxItems: 3, strategy: .hybrid) { result in
            received = result
            done.fulfill()
        }

        wait(for: [done], timeout: 30)

        switch received {
        case .success(let products):
            // Empty is a valid outcome (no-fill), but it still proves the bridge
            // ran. Log the count so the run is informative either way.
            print("✅ headless fetch resolved with \(products.count) product(s)")
            for p in products {
                print("   • \(p.id) — \(p.name ?? "—") — sponsored=\(p.sponsored)")
            }
            XCTAssertLessThanOrEqual(products.count, 3, "maxItems must cap the result")
        case .failure(let error as SurfsideAdsError) where error == .timeout:
            XCTFail("Headless WebView timed out — the un-hosted WKWebView did not run. "
                    + "Fallback: host it offscreen in the key window during the fetch.")
        case .failure(let error):
            XCTFail("Fetch failed: \(error.localizedDescription)")
        case .none:
            XCTFail("Completion never fired")
        }
    }
}
