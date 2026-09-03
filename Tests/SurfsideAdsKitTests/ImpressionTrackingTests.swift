import XCTest
@testable import SurfsideAdsKit

/// Asserts the fire-and-forget pixel calls (`recordImpression`, `recordClick`)
/// hit exactly the right URLs, using a stub `URLProtocol` so nothing leaves the
/// process. `recordImpression` must fire win + impression trackers and NOT the
/// viewable ones (those are reserved for a future `recordViewable`).
@available(iOS 14.0, *)
final class ImpressionTrackingTests: XCTestCase {

    override func tearDown() {
        RecordingURLProtocol.reset()
        super.tearDown()
    }

    private func makeAds() -> SurfsideAds {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecordingURLProtocol.self]
        let session = URLSession(configuration: config)
        return SurfsideAds(
            configuration: .init(accountId: "a", siteId: "s", channelId: "c", locationId: "l"),
            urlSession: session
        )
    }

    func testRecordImpressionFiresWinAndImpressionNotViewable() {
        let product = SurfsideProduct(
            id: "p1", sponsored: true,
            winTrackers: ["https://win.test/1"],
            impressionTrackers: ["https://imp.test/1", "https://imp.test/2"],
            viewableTrackers: ["https://view.test/1"]
        )

        let done = expectation(description: "impression fired")
        makeAds().recordImpression(product) { ok in
            XCTAssertTrue(ok)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)

        let hit = RecordingURLProtocol.requestedURLs.map(\.absoluteString).sorted()
        XCTAssertEqual(hit, ["https://imp.test/1", "https://imp.test/2", "https://win.test/1"])
        XCTAssertFalse(hit.contains("https://view.test/1"))
    }

    func testRecordImpressionWithNoTrackersReportsFalseAndFiresNothing() {
        let done = expectation(description: "no-op impression")
        makeAds().recordImpression(SurfsideProduct(id: "p2")) { ok in
            XCTAssertFalse(ok)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertTrue(RecordingURLProtocol.requestedURLs.isEmpty)
    }

    func testRecordClickFiresClickURL() {
        let product = SurfsideProduct(id: "p3", clickthroughURL: "https://click.test/3")

        let done = expectation(description: "click fired")
        makeAds().recordClick(product) { ok in
            XCTAssertTrue(ok)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(RecordingURLProtocol.requestedURLs.map(\.absoluteString),
                       ["https://click.test/3"])
    }
}

/// Succeeds every request with an empty 200 and records the URL it saw.
final class RecordingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var urls: [URL] = []

    static var requestedURLs: [URL] {
        lock.lock(); defer { lock.unlock() }
        return urls
    }

    static func reset() {
        lock.lock(); urls = []; lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let url = request.url {
            Self.lock.lock(); Self.urls.append(url); Self.lock.unlock()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
