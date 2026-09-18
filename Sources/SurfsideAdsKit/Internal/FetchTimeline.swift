import Foundation

/// What the scraper measured inside the WebView, in ms since the shell page's
/// navigation start (`performance.now()`). All optional: an older or failed shell
/// simply reports none.
struct ShellTimings: Decodable, Equatable {
    /// First poll that saw `customElements.get('surf-carousel')`, i.e. r.js ran.
    let sdkDefinedMs: Double?
    /// First poll that saw at least one mounted card.
    let firstCardMs: Double?
    /// When the scraper posted its result.
    let postedMs: Double?
}

/// One network request the shell page made, from the Resource Timing API.
struct ShellResource: Decodable, Equatable {
    let name: String
    let startMs: Double
    let durationMs: Double
}

/// Stage timestamps for one carousel fetch, in seconds since `start()`.
/// Diagnostic only; rendered to the log when `Configuration.isInspectable` is set.
struct FetchTimeline {

    private let clock: () -> TimeInterval
    private let origin: TimeInterval
    private(set) var marks: [(stage: String, at: TimeInterval)] = []

    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
        self.origin = clock()
    }

    mutating func mark(_ stage: String) {
        marks.append((stage, clock() - origin))
    }

    /// Multi-line report: native stages with the delta from the previous stage,
    /// then the shell's own marks and the requests it made (query strings dropped).
    func report(zoneId: String,
                outcome: String,
                shell: ShellTimings?,
                resources: [ShellResource]) -> String {
        var lines = ["SurfsideAdsKit fetch zone=\(zoneId) outcome=\(outcome)"]
        var previous: TimeInterval = 0
        for mark in marks {
            let stage = mark.stage.padding(toLength: 16, withPad: " ", startingAt: 0)
            lines.append("  " + stage + String(format: " %7.0f ms  (+%.0f)",
                                               mark.at * 1000,
                                               (mark.at - previous) * 1000))
            previous = mark.at
        }
        if let shell = shell {
            lines.append("  shell (ms since page start): "
                + "sdkDefined=\(Self.ms(shell.sdkDefinedMs)) "
                + "firstCard=\(Self.ms(shell.firstCardMs)) "
                + "posted=\(Self.ms(shell.postedMs))")
        }
        for resource in resources.sorted(by: { $0.startMs < $1.startMs }) {
            lines.append(String(format: "  net %6.0f ms +%5.0f  ",
                                resource.startMs,
                                resource.durationMs) + Self.trimmed(resource.name))
        }
        return lines.joined(separator: "\n")
    }

    private static func ms(_ value: Double?) -> String {
        value.map { String(format: "%.0f", $0) } ?? "never"
    }

    /// Host + path only: tracker and bid URLs carry ids in their query strings.
    static func trimmed(_ url: String) -> String {
        guard let cut = url.firstIndex(where: { $0 == "?" || $0 == "#" }) else { return url }
        return String(url[..<cut])
    }
}
