import Foundation

/// A single Surfside product scraped out of the ads SDK's rendered card.
///
/// This is the flattened, public shape we hand to the integrator. It mirrors the
/// `product` object the SDK staples onto every rendered card (`.productData`),
/// plus the click destination and whether the placement is sponsored.
///
/// Most fields are optional because the SDK emits some of them as the literal
/// string `"null"` / `""` for a given catalog; the JS bridge cleans those to
/// real absences (see `Internal/ShellHTML.swift`), so a `nil` here means "not
/// present" rather than "the string null".
public struct SurfsideProduct: Identifiable, Decodable, Equatable {
    /// Stable catalog id for the product. Always present.
    public let id: String
    /// Display name of the product.
    public let name: String?
    /// List price as the SDK formatted it (a display string, e.g. `"$40.00"`).
    public let price: String?
    /// Sale/override price when the product is discounted.
    public let salePrice: String?
    /// Absolute product image URL (typically an ATS-compliant CDN URL).
    public let image: String?
    /// Brand name, when the catalog provides one.
    public let brandName: String?
    /// Product type or category label from the catalog.
    public let productType: String?
    /// THC content as the catalog reported it (cannabis catalogs).
    public let thc: String?
    /// Strain name (cannabis catalogs).
    public let strain: String?
    /// CBD content as the catalog reported it (cannabis catalogs).
    public let cbd: String?
    /// Where a tap on this product should send the shopper. Pass the product to
    /// ``SurfsideAds/recordClick(_:completion:)`` to fire Surfside's click pixel.
    public let clickthroughURL: String?
    /// Whether this product occupied a paid/sponsored slot.
    public let sponsored: Bool
    /// Catalog-specific extras (variants, sizes, unique keys). Flattened to
    /// string values on the JS side; `nil` when the SDK provided no `ext`.
    public let ext: [String: String]?

    /// Win-notice (nurl) tracker URLs, suppressed during the hidden fetch and
    /// fired on real display via ``SurfsideAds/recordImpression(_:completion:)``.
    /// Pixel-type (`<img>`) trackers only, like ``impressionTrackers``.
    public let winTrackers: [String]?
    /// Impression tracker URLs to fire on real display. Pixel-type (`<img>`)
    /// trackers only; `<script>` trackers fire once at fetch and are omitted
    /// here to avoid double counting (rationale: CarouselBridge's suppression
    /// notes).
    public let impressionTrackers: [String]?
    /// Viewable tracker URLs, captured for a future threshold-gated
    /// `recordViewable`. Not fired by ``SurfsideAds/recordImpression(_:completion:)``.
    public let viewableTrackers: [String]?

    // The JS bridge posts `clickthrough`; everything else matches 1:1.
    enum CodingKeys: String, CodingKey {
        case id, name, price, salePrice, image, brandName, productType
        case thc, strain, cbd
        case clickthroughURL = "clickthrough"
        case sponsored, ext
        case winTrackers, impressionTrackers, viewableTrackers
    }

    /// Memberwise initializer for tests and integrator-side mocking.
    ///
    /// Declaring this in the main type body suppresses the *memberwise* init but
    /// does NOT suppress Swift's synthesized `Decodable` conformance — that only
    /// happens if you hand-write `init(from:)`. So we keep both for free.
    public init(
        id: String,
        name: String? = nil,
        price: String? = nil,
        salePrice: String? = nil,
        image: String? = nil,
        brandName: String? = nil,
        productType: String? = nil,
        thc: String? = nil,
        strain: String? = nil,
        cbd: String? = nil,
        clickthroughURL: String? = nil,
        sponsored: Bool = false,
        ext: [String: String]? = nil,
        winTrackers: [String]? = nil,
        impressionTrackers: [String]? = nil,
        viewableTrackers: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.price = price
        self.salePrice = salePrice
        self.image = image
        self.brandName = brandName
        self.productType = productType
        self.thc = thc
        self.strain = strain
        self.cbd = cbd
        self.clickthroughURL = clickthroughURL
        self.sponsored = sponsored
        self.ext = ext
        self.winTrackers = winTrackers
        self.impressionTrackers = impressionTrackers
        self.viewableTrackers = viewableTrackers
    }
}

public extension SurfsideProduct {
    /// The click destination as a parsed `URL`, if present and valid.
    var clickURL: URL? {
        clickthroughURL.flatMap(URL.init(string:))
    }

    /// The win-notice URLs parsed to `URL`, dropping any that don't parse.
    var winTrackerURLs: [URL] {
        (winTrackers ?? []).compactMap(URL.init(string:))
    }

    /// The impression URLs parsed to `URL`, dropping any that don't parse.
    var impressionTrackerURLs: [URL] {
        (impressionTrackers ?? []).compactMap(URL.init(string:))
    }

    /// The viewable URLs parsed to `URL`, dropping any that don't parse.
    var viewableTrackerURLs: [URL] {
        (viewableTrackers ?? []).compactMap(URL.init(string:))
    }
}
