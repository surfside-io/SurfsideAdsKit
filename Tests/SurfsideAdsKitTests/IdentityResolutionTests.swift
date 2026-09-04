import XCTest
@testable import SurfsideAdsKit

/// Locks the identity resolution order added in JJRC-456: explicit
/// `Configuration.userId` override > auto-acquired `domainUserId` from the tracker
/// > nil (anonymous). The reflection path into the tracker (``TrackerIdentityProvider``)
/// can't run in host tests without the tracker linked, so it stays out of scope
/// here; these exercise ``ResolvedIdentity`` against a stub provider.
@available(iOS 14.0, *)
final class IdentityResolutionTests: XCTestCase {

    /// Stub auto source: returns whatever id it was seeded with (or nil).
    private struct StubProvider: IdentityProvider {
        let id: String?
        func domainUserId() -> String? { id }
    }

    private let explicitId = "explicit-11111111-2222-3333"
    private let autoId = "auto-99999999-8888-7777"

    func testExplicitWinsOverAuto() {
        let resolved = ResolvedIdentity.resolve(
            explicit: explicitId,
            provider: StubProvider(id: autoId)
        )
        XCTAssertEqual(resolved, explicitId)
    }

    func testNilExplicitFallsBackToAuto() {
        let resolved = ResolvedIdentity.resolve(
            explicit: nil,
            provider: StubProvider(id: autoId)
        )
        XCTAssertEqual(resolved, autoId)
    }

    func testEmptyExplicitIsTreatedAsUnsetAndFallsBackToAuto() {
        let resolved = ResolvedIdentity.resolve(
            explicit: "",
            provider: StubProvider(id: autoId)
        )
        XCTAssertEqual(resolved, autoId)
    }

    func testBothUnavailableResolvesNil() {
        let resolved = ResolvedIdentity.resolve(
            explicit: nil,
            provider: StubProvider(id: nil)
        )
        XCTAssertNil(resolved)
    }

    func testEmptyAutoIsTreatedAsUnsetAndResolvesNil() {
        let resolved = ResolvedIdentity.resolve(
            explicit: nil,
            provider: StubProvider(id: "")
        )
        XCTAssertNil(resolved)
    }

    /// The default provider reads from the Surfside iOS tracker over the Obj-C
    /// runtime. In the host test bundle the tracker class (`SPSurfsideEvent`) is
    /// not linked, so it must resolve nil cleanly rather than crash: the graceful
    /// fallback that keeps a fetch anonymous when the tracker is absent.
    func testDefaultProviderReturnsNilWhenTrackerAbsent() {
        XCTAssertNil(TrackerIdentityProvider().domainUserId())
    }

    // MARK: Fetch wiring

    private func makeAds(configuredUserId: String?, auto: String?) -> SurfsideAds {
        SurfsideAds(
            configuration: SurfsideAds.Configuration(
                accountId: "acct",
                siteId: "site",
                channelId: "channel",
                locationId: "location",
                userId: configuredUserId
            ),
            identityProvider: StubProvider(id: auto)
        )
    }

    /// The per-fetch request must carry the resolved id, not the raw
    /// `Configuration.userId` (the fetch path can't run in host tests, so the
    /// wiring is locked through the internal request builder).
    func testFetchRequestCarriesResolvedIdentity() {
        let explicit = makeAds(configuredUserId: explicitId, auto: autoId)
            .makeRequest(zoneId: "z", maxItems: 3, strategy: .hybrid)
        XCTAssertEqual(explicit.userId, explicitId)

        let auto = makeAds(configuredUserId: nil, auto: autoId)
            .makeRequest(zoneId: "z", maxItems: 3, strategy: .hybrid)
        XCTAssertEqual(auto.userId, autoId)

        let anonymous = makeAds(configuredUserId: "", auto: nil)
            .makeRequest(zoneId: "z", maxItems: 3, strategy: .hybrid)
        XCTAssertNil(anonymous.userId)
    }
}
