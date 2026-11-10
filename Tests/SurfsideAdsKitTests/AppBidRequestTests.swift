import XCTest
import WebKit
@testable import SurfsideAdsKit

/// JJRC-576: AdsKit loads the app build of r.js, tells it the host app's bundle id, and
/// turns on partner development testing through the page URL.
@available(iOS 14.0, *)
final class AppBidRequestTests: XCTestCase {

    private func makeConfiguration(developmentTesting: Bool = false,
                                   baseURL: String = "https://internalhost.com") -> SurfsideAds.Configuration {
        SurfsideAds.Configuration(accountId: "acct", siteId: "site", channelId: "channel", locationId: "location",
                                  baseURL: baseURL, developmentTesting: developmentTesting)
    }

    func testDefaultsToTheAppBuildOfRjs() {
        XCTAssertEqual(makeConfiguration().rjsURL, "//cdn.surfside.io/ads/2.0.0/app/r.js")
    }

    func testHostAppScriptSetsTheBundleId() {
        XCTAssertEqual(HostAppScript.source(bundleId: "com.example.shop"),
                       #"window.surfsideApp = {"bundle":"com.example.shop"};"#)
    }

    func testHostAppScriptEscapesTheBundleId() {
        XCTAssertEqual(HostAppScript.source(bundleId: #"com.ex"ample</script>"#),
                       #"window.surfsideApp = {"bundle":"com.ex\"ample<\/script>"};"#)
    }

    func testNoHostAppScriptWithoutABundleId() {
        XCTAssertNil(HostAppScript.source(bundleId: nil))
        XCTAssertNil(HostAppScript.source(bundleId: ""))
    }

    func testProductionPageURLHasNoDevelopmentFlag() {
        XCTAssertEqual(makeConfiguration().pageBaseURL, "https://internalhost.com")
    }

    func testDevelopmentTestingAddsTheOverrideToThePageURL() {
        XCTAssertEqual(makeConfiguration(developmentTesting: true).pageBaseURL,
                       "https://internalhost.com/?surf_override_filtering=true")
        XCTAssertEqual(makeConfiguration(developmentTesting: true, baseURL: "https://shop.example/plp?promo=1").pageBaseURL,
                       "https://shop.example/plp?promo=1&surf_override_filtering=true")
    }

    func testDevelopmentTestingReplacesAnExistingOverrideValue() {
        XCTAssertEqual(makeConfiguration(developmentTesting: true,
                                         baseURL: "https://shop.example/?surf_override_filtering=false&a=1").pageBaseURL,
                       "https://shop.example/?a=1&surf_override_filtering=true")
        XCTAssertEqual(makeConfiguration(developmentTesting: true,
                                         baseURL: "https://shop.example/?surf_override_filtering").pageBaseURL,
                       "https://shop.example/?surf_override_filtering=true")
    }

    func testDevelopmentTestingKeepsTheQueryEncodingAndFragment() {
        XCTAssertEqual(makeConfiguration(developmentTesting: true,
                                         baseURL: "https://shop.example/plp?q=b%2Bc#top").pageBaseURL,
                       "https://shop.example/plp?q=b%2Bc&surf_override_filtering=true#top")
    }

    func testHostAppScriptInstallsAtDocumentStart() {
        let controller = WKUserContentController()
        HostAppScript.install(on: controller, bundleId: "com.example.shop")
        XCTAssertEqual(controller.userScripts.count, 1)
        XCTAssertEqual(controller.userScripts.first?.injectionTime, .atDocumentStart)
        XCTAssertEqual(controller.userScripts.first?.source, #"window.surfsideApp = {"bundle":"com.example.shop"};"#)
    }

    func testDevelopmentTestingCombinesWithDebugMode() {
        let pageURL = DebugConsole.pageURL(baseURL: makeConfiguration(developmentTesting: true).pageBaseURL, debug: true)
        XCTAssertEqual(pageURL?.absoluteString,
                       "https://internalhost.com/?surf_override_filtering=true&surf_debug=true")
    }

    func testFetchRequestCarriesThePageURLWithTheDevelopmentFlag() {
        let ads = SurfsideAds(configuration: makeConfiguration(developmentTesting: true))
        XCTAssertEqual(ads.makeRequest(zoneId: "z", maxItems: 3, strategy: .hybrid).baseURL,
                       "https://internalhost.com/?surf_override_filtering=true")
    }
}
