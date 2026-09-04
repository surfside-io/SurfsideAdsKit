import Foundation
import CoreGraphics

/// The outcome of a banner load, as reported by the shell's watcher script or the
/// Swift-side timeout backstop.
///
/// Note the deliberate split from ``SurfsideAdsError``: `empty` (no-fill) is a
/// **normal** outcome for an ad slot, not an error, exactly as the carousel path
/// treats an empty product array as success. Only `loadFailed` is a genuine
/// failure; `timeout` sits between them (the SDK never mounted anything, usually
/// bad IDs or r.js never loading).
public enum SurfsideBannerStatus: Equatable {
    /// A creative rendered. `size` is the shell-measured rendered size when it
    /// could be read, else `nil` (the host falls back to the requested size).
    case filled(size: CGSize?)
    /// The SDK ran but the zone had no fill. The banner stays empty; collapse it.
    case empty
    /// Nothing mounted before the deadline (r.js never loaded, or bad IDs).
    case timeout
    /// The WebView navigation itself failed. The string is the underlying reason.
    case loadFailed(String)
}

/// The JSON envelope the shell's watcher posts back over the message channel.
/// Only `filled`/`empty`/`timeout` cross the bridge; `loadFailed` is Swift-side.
private struct BannerStatusPayload: Decodable {
    let status: String        // "filled" | "empty" | "timeout"
    let width: Double?
    let height: Double?
}

public extension SurfsideBannerStatus {
    /// Map a raw watcher message (the JSON string posted from JS) to a status.
    ///
    /// Kept pure and outside the UIKit guard so it is host-unit-testable, mirroring
    /// how `ShellHTML`/`AdRequest` stay testable on the Mac host. Returns `nil` when
    /// the payload can't be decoded, so the caller can treat that as a load failure.
    static func parse(message: Any) -> SurfsideBannerStatus? {
        guard
            let json = message as? String,
            let data = json.data(using: .utf8),
            let payload = try? JSONDecoder().decode(BannerStatusPayload.self, from: data)
        else { return nil }

        switch payload.status {
        case "filled":
            // Only trust a positive, non-zero size; anything else falls back native-side.
            if let w = payload.width, let h = payload.height, w > 0, h > 0 {
                return .filled(size: CGSize(width: w, height: h))
            }
            return .filled(size: nil)
        case "empty":
            return .empty
        case "timeout":
            return .timeout
        default:
            return nil
        }
    }
}
