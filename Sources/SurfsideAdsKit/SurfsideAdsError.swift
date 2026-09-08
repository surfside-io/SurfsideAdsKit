import Foundation

/// Failures a fetch can surface.
///
/// Note the deliberate *absence* of a "no inventory" error: when the bridge runs
/// cleanly but the zone has nothing to serve, a fetch succeeds with an **empty
/// array** rather than throwing. No-fill is a normal outcome for an ad slot, so
/// integrators handle it with `products.isEmpty`, not a `catch`.
public enum SurfsideAdsError: Error, Equatable {
    /// The WebView navigation itself failed (network down, bad shell, etc).
    /// The associated string is the underlying error description.
    case loadFailed(String)
    /// No result arrived before the deadline — usually the ad SDK never mounted
    /// a card (bad IDs / zone / category), or the WebView never ran its JS.
    case timeout
    /// A result arrived but its payload could not be decoded.
    case decodeFailed
}

extension SurfsideAdsError: LocalizedError {
    /// Human-readable description of the failure.
    public var errorDescription: String? {
        switch self {
        case .loadFailed(let reason):
            return "Surfside ads failed to load: \(reason)"
        case .timeout:
            return "Surfside ads request timed out before any products mounted."
        case .decodeFailed:
            return "Surfside ads returned a payload that could not be decoded."
        }
    }
}
