import XCTest
import CoreGraphics
@testable import SurfsideAdsKit

/// The watcher posts a JSON status string; these lock in the JSON -> status mapping
/// the banner view relies on. Pure and host-runnable, mirroring the product decode
/// tests, since the mapping is where a shell/native contract mismatch would bite.
final class BannerStatusParsingTests: XCTestCase {

    func testFilledWithSize() {
        let status = SurfsideBannerStatus.parse(message:
            #"{"status":"filled","width":300,"height":250}"#)
        XCTAssertEqual(status, .filled(size: CGSize(width: 300, height: 250)))
    }

    func testFilledWithMissingSizeYieldsNilSize() {
        // A filled render the shell couldn't measure still counts as filled; the
        // view falls back to the requested size.
        XCTAssertEqual(SurfsideBannerStatus.parse(message: #"{"status":"filled"}"#),
                       .filled(size: nil))
    }

    func testFilledWithZeroSizeYieldsNilSize() {
        // A zero rect is not a trustworthy size; treat it as unmeasured.
        XCTAssertEqual(
            SurfsideBannerStatus.parse(message: #"{"status":"filled","width":0,"height":0}"#),
            .filled(size: nil))
    }

    func testEmpty() {
        XCTAssertEqual(SurfsideBannerStatus.parse(message: #"{"status":"empty"}"#), .empty)
    }

    func testTimeout() {
        XCTAssertEqual(SurfsideBannerStatus.parse(message: #"{"status":"timeout"}"#), .timeout)
    }

    func testUnknownStatusIsNil() {
        XCTAssertNil(SurfsideBannerStatus.parse(message: #"{"status":"weird"}"#))
    }

    func testNonJSONMessageIsNil() {
        XCTAssertNil(SurfsideBannerStatus.parse(message: "not json"))
    }

    func testNonStringBodyIsNil() {
        // The bridge posts a JSON string; a non-string body is a contract break.
        XCTAssertNil(SurfsideBannerStatus.parse(message: 42))
    }
}
