import XCTest
@testable import SurfsideAdsKit

final class FetchTimelineTests: XCTestCase {

    func testMarksAreSecondsSinceStartInOrder() {
        var now: TimeInterval = 100
        var timeline = FetchTimeline(clock: { now })
        now = 100.25
        timeline.mark("rulesCompiled")
        now = 101
        timeline.mark("finished")

        XCTAssertEqual(timeline.marks.map(\.stage), ["rulesCompiled", "finished"])
        XCTAssertEqual(timeline.marks[0].at, 0.25, accuracy: 0.0001)
        XCTAssertEqual(timeline.marks[1].at, 1.0, accuracy: 0.0001)
    }

    func testReportShowsDeltasShellMarksAndSortedRequests() {
        var now: TimeInterval = 0
        var timeline = FetchTimeline(clock: { now })
        now = 0.2
        timeline.mark("shellLoaded")
        now = 9.1
        timeline.mark("finished")

        let report = timeline.report(
            zoneId: "3ZG7D",
            outcome: "empty",
            shell: ShellTimings(sdkDefinedMs: 310, firstCardMs: nil, postedMs: 8000),
            resources: [
                ShellResource(name: "https://bid.surfside.io/rtb/bids/surfside", startMs: 600, durationMs: 120),
                ShellResource(name: "https://cdn.surfside.io/ads/2.0.0/r.js", startMs: 20, durationMs: 250),
            ])

        XCTAssertTrue(report.contains("zone=3ZG7D outcome=empty"))
        XCTAssertTrue(report.contains("(+8900)"))
        XCTAssertTrue(report.contains("sdkDefined=310 firstFill=never posted=8000"))
        let rjs = try? XCTUnwrap(report.range(of: "r.js"))
        let bid = try? XCTUnwrap(report.range(of: "rtb/bids"))
        XCTAssertNotNil(rjs)
        XCTAssertNotNil(bid)
        if let rjs = rjs, let bid = bid { XCTAssertTrue(rjs.lowerBound < bid.lowerBound) }
    }

    func testTrimmedDropsQueryAndFragment() {
        XCTAssertEqual(FetchTimeline.trimmed("https://rtb.surfside.io/win?ad_id=1&price=2"),
                       "https://rtb.surfside.io/win")
        XCTAssertEqual(FetchTimeline.trimmed("https://r.surfside.io/a/b/config.json"),
                       "https://r.surfside.io/a/b/config.json")
    }

    func testShellPayloadFieldsAreOptionalForOlderShells() throws {
        let json = #"{"sdkDefinedMs":12.5,"firstCardMs":null}"#.data(using: .utf8)!
        let timings = try JSONDecoder().decode(ShellTimings.self, from: json)
        XCTAssertEqual(timings, ShellTimings(sdkDefinedMs: 12.5, firstCardMs: nil, postedMs: nil))
    }
}
