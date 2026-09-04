import XCTest
@testable import SurfsideAdsKit

/// Locks the seeded `surfid.` cookie to the exact shape the surfside-ads web core
/// reads. Its `GetSurfUserIdCookie` regex takes the FIRST dotted field as the user
/// id, so if this drifts, iOS ad requests silently stop carrying the tracked
/// identity (JJRC-259; see decisions/002, 003). The regex test mirrors the web
/// reader directly.
@available(iOS 14.0, *)
final class IdentityCookieTests: XCTestCase {

    private let userId = "11111111-2222-3333-4444-555555555555"

    func testCookieNameDomainAndFirstField() throws {
        let cookie = try XCTUnwrap(
            CarouselBridge.surfidCookie(userId: userId, baseURL: "https://internalhost.com")
        )
        XCTAssertTrue(cookie.name.hasPrefix("surfid."), "name was \(cookie.name)")
        XCTAssertEqual(cookie.domain, "internalhost.com")
        XCTAssertEqual(cookie.path, "/")
        // The web reader takes only the first dotted field as the user id.
        XCTAssertEqual(cookie.value.split(separator: ".").first.map(String.init), userId)
    }

    /// The actual read contract: mirror surfside-ads `UserId.ts` regex
    /// (`/surfid.(?<site_hash>[a-z0-9]+)=(?<domain_userid>[^.]+).*/i`) and assert it
    /// recovers our userId from `name=value`.
    func testWebCoreRegexRecoversUserId() throws {
        let cookie = try XCTUnwrap(
            CarouselBridge.surfidCookie(userId: userId, baseURL: "https://internalhost.com")
        )
        let cookieString = "\(cookie.name)=\(cookie.value)"
        let re = try NSRegularExpression(pattern: "surfid\\.[a-z0-9]+=([^.]+)", options: [.caseInsensitive])
        let range = NSRange(cookieString.startIndex..., in: cookieString)
        let match = try XCTUnwrap(re.firstMatch(in: cookieString, range: range))
        let captured = try XCTUnwrap(Range(match.range(at: 1), in: cookieString))
        XCTAssertEqual(String(cookieString[captured]), userId)
    }

    func testSiteHashIsDeterministicAndHex() {
        let a = CarouselBridge.siteHash(for: "internalhost.com")
        XCTAssertEqual(a, CarouselBridge.siteHash(for: "internalhost.com"), "must be stable per host")
        XCTAssertTrue(a.allSatisfy { $0.isHexDigit }, "hex only, was \(a)")
        XCTAssertNotEqual(CarouselBridge.siteHash(for: "other.com"), a)
    }

    func testInvalidBaseURLYieldsNoCookie() {
        // No host → no cookie; the bridge then loads anonymously rather than seeding.
        XCTAssertNil(CarouselBridge.surfidCookie(userId: userId, baseURL: "not a url"))
    }
}
