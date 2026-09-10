#if canImport(UIKit)
import SwiftUI
import UIKit

/// SwiftUI wrapper around ``SurfsideBannerView`` so SwiftUI hosts can drop in a
/// banner. Load outcomes surface through the optional closures.
///
/// ```swift
/// SurfsideBanner(
///     configuration: .init(accountId: "ec981", siteId: "544fa",
///                          channelId: "00000", locationId: "greengoddess"),
///     zoneId: "6ambm",
///     size: CGSize(width: 8, height: 1),     // the zone's banner ratio (8x1, 4x1, 2x1)
///     onNoFill: { /* hide the row */ }
/// )
/// .frame(width: 320, height: 40)             // 8x1 at 320pt wide
/// ```
@available(iOS 14.0, *)
public struct SurfsideBanner: UIViewRepresentable {

    private let configuration: SurfsideAds.Configuration
    private let zoneId: String
    private let size: CGSize
    private let onLoad: ((CGSize?) -> Void)?
    private let onNoFill: (() -> Void)?
    private let onError: ((SurfsideAdsError) -> Void)?

    /// Creates a banner.
    ///
    /// - Parameters:
    ///   - configuration: Placement identity (see ``SurfsideAds/Configuration``).
    ///   - zoneId: The banner zone to serve.
    ///   - size: The banner size to request and reserve in layout.
    ///   - onLoad: Called when a banner fills, with the rendered size if known.
    ///   - onNoFill: Called when the zone has nothing to serve (hide the slot).
    ///   - onError: Called when the load fails.
    public init(configuration: SurfsideAds.Configuration,
                zoneId: String,
                size: CGSize,
                onLoad: ((CGSize?) -> Void)? = nil,
                onNoFill: (() -> Void)? = nil,
                onError: ((SurfsideAdsError) -> Void)? = nil) {
        self.configuration = configuration
        self.zoneId = zoneId
        self.size = size
        self.onLoad = onLoad
        self.onNoFill = onNoFill
        self.onError = onError
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public func makeUIView(context: Context) -> SurfsideBannerView {
        SurfsideBannerView(configuration: configuration,
                           zoneId: zoneId,
                           size: size,
                           delegate: context.coordinator)
    }

    // Identity is fixed at creation (a banner is one placement); nothing to update.
    public func updateUIView(_ uiView: SurfsideBannerView, context: Context) {}

    /// Bridges the UIKit delegate callbacks back to the SwiftUI closures.
    @available(iOS 14.0, *)
    public final class Coordinator: SurfsideBannerViewDelegate {
        private let parent: SurfsideBanner
        init(_ parent: SurfsideBanner) { self.parent = parent }

        public func surfsideBannerViewDidLoad(_ bannerView: SurfsideBannerView, size: CGSize?) {
            parent.onLoad?(size)
        }
        public func surfsideBannerViewDidReceiveNoFill(_ bannerView: SurfsideBannerView) {
            parent.onNoFill?()
        }
        public func surfsideBannerView(_ bannerView: SurfsideBannerView, didFailWithError error: SurfsideAdsError) {
            parent.onError?(error)
        }
    }
}
#endif
