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
///     size: CGSize(width: 320, height: 50),
///     onNoFill: { /* hide the row */ }
/// )
/// .frame(width: 320, height: 50)
/// ```
@available(iOS 14.0, *)
public struct SurfsideBanner: UIViewRepresentable {

    private let configuration: SurfsideAds.Configuration
    private let zoneId: String
    private let size: CGSize
    private let onLoad: ((CGSize?) -> Void)?
    private let onNoFill: (() -> Void)?
    private let onError: ((SurfsideAdsError) -> Void)?

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
