import Foundation

/// Entry point for fetching Surfside sponsored product data.
///
/// Construct once with your placement's identity, then call `fetchProducts` per
/// ad slot. Each fetch spins up a hidden, one-shot WebView that runs the Surfside
/// ads SDK, lets it fire its win/impression pixels, scrapes the products, and
/// tears down. You render the returned ``SurfsideProduct`` values natively.
///
/// ```swift
/// let ads = SurfsideAds(accountId: "ec981", siteId: "544fa",
///                       channelId: "00000", locationId: "greengoddess")
///
/// let products = try await ads.fetchProducts(zoneId: "6ambm", maxItems: 4)
/// // ...render products in your own UI...
/// ads.recordClick(products[0])   // when the shopper taps it
/// ```
@available(iOS 14.0, *)
public final class SurfsideAds {

    /// Which inventory the SDK should serve.
    public enum Strategy: String {
        case sponsored, hybrid, recommended
    }

    /// Placement identity plus a few advanced knobs. Most integrators only set
    /// the four IDs and use the defaults for everything else.
    public struct Configuration {
        public var accountId: String
        public var siteId: String
        public var channelId: String
        public var locationId: String

        /// The carousel refuses to render unless BOTH are present (SDK's
        /// `attributesLoaded()` gate). Defaults match the proven spike.
        public var category: String
        public var keywords: String

        /// Pinned r.js bundle. Override only to test against a different build.
        public var rjsURL: String
        /// Fake https origin the shell loads under, so CSP/CORS behave.
        public var baseURL: String

        /// How long a fetch waits before giving up with `.timeout`. The JS has an
        /// 8s internal ceiling, but that clock only starts once r.js has loaded
        /// (a cold CDN fetch can take ~3s), so the Swift-side backstop needs
        /// real headroom above 8s — not just a second or two — or it will beat
        /// the JS's own "empty" verdict and misreport no-fill as a timeout.
        public var requestTimeout: TimeInterval

        /// Allow Safari's Web Inspector to attach to the hidden WebView. Debug
        /// only — leave `false` in shipping builds.
        public var isInspectable: Bool

        /// Run the fetch WebView **un-hosted** (never added to a window) instead of
        /// the default offscreen-in-window mode.
        ///
        /// Default `false` (offscreen-hosted) is the reliable path: WebKit throttles
        /// the web-content process of a WebView that is not in a window, so the SDK's
        /// JS (r.js load, async carousel render, pixels) stalls and fetches time out.
        /// Set `true` only where hosting is impossible or you've verified the
        /// headless path works for your case — expect timeouts otherwise. The view is
        /// invisible either way; this only controls window attachment.
        public var headless: Bool

        public init(
            accountId: String,
            siteId: String,
            channelId: String,
            locationId: String,
            category: String = "all",
            keywords: String = "product",
            rjsURL: String = "//cdn.surfside.io/ads/2.0.0/r.js",
            baseURL: String = "https://internalhost.com",
            requestTimeout: TimeInterval = 15,
            isInspectable: Bool = false,
            headless: Bool = false
        ) {
            self.accountId = accountId
            self.siteId = siteId
            self.channelId = channelId
            self.locationId = locationId
            self.category = category
            self.keywords = keywords
            self.rjsURL = rjsURL
            self.baseURL = baseURL
            self.requestTimeout = requestTimeout
            self.isInspectable = isInspectable
            self.headless = headless
        }
    }

    private let configuration: Configuration
    private let clickSession: URLSession

    /// Keeps in-flight bridges alive until they resolve. Only touched on the main
    /// thread (all fetch work hops there), so a plain array is safe.
    private var activeBridges: [CarouselBridge] = []

    /// Full-control initializer.
    public init(configuration: Configuration, urlSession: URLSession = .shared) {
        self.configuration = configuration
        self.clickSession = urlSession
    }

    /// Convenience initializer for the common case: just the four placement IDs.
    public convenience init(
        accountId: String,
        siteId: String,
        channelId: String,
        locationId: String
    ) {
        self.init(configuration: Configuration(
            accountId: accountId,
            siteId: siteId,
            channelId: channelId,
            locationId: locationId
        ))
    }

    // MARK: - Fetch (async)

    /// Fetch sponsored products for a zone.
    ///
    /// Returns the products the SDK served (up to `maxItems`), or an **empty
    /// array** when the zone had no fill — no-fill is not an error. Throws
    /// ``SurfsideAdsError`` only on real failures (load error, timeout, decode).
    ///
    /// - Parameters:
    ///   - zoneId: The placement/zone id to request.
    ///   - maxItems: Hard ceiling on how many products come back (default 10).
    ///   - strategy: Which inventory to serve (default `.hybrid`).
    public func fetchProducts(
        zoneId: String,
        maxItems: Int = 10,
        strategy: Strategy = .hybrid
    ) async throws -> [SurfsideProduct] {
        try await withCheckedThrowingContinuation { continuation in
            // The continuation is resumed by exactly one completion call (the
            // bridge guarantees single resolution), so no double-resume risk.
            fetchProducts(zoneId: zoneId, maxItems: maxItems, strategy: strategy) { result in
                continuation.resume(with: result)
            }
        }
    }

    // MARK: - Fetch (completion)

    /// Completion-handler variant of ``fetchProducts(zoneId:maxItems:strategy:)``
    /// for callbacks-based call sites. `completion` is always delivered on the
    /// main thread, exactly once.
    public func fetchProducts(
        zoneId: String,
        maxItems: Int = 10,
        strategy: Strategy = .hybrid,
        completion: @escaping (Result<[SurfsideProduct], Error>) -> Void
    ) {
        let request = AdRequest(
            accountId: configuration.accountId,
            siteId: configuration.siteId,
            channelId: configuration.channelId,
            locationId: configuration.locationId,
            zoneId: zoneId,
            category: configuration.category,
            keywords: configuration.keywords,
            strategy: strategy.rawValue,
            maxItems: max(1, maxItems),
            rjsURL: configuration.rjsURL,
            baseURL: configuration.baseURL,
            cardWidth: 200
        )
        let timeout = configuration.requestTimeout
        let inspectable = configuration.isInspectable
        let headless = configuration.headless

        // WKWebView is main-thread-only; build and drive the bridge there.
        runOnMain { [weak self] in
            guard let self = self else { return }
            let bridge = CarouselBridge(request: request,
                                        timeout: timeout,
                                        isInspectable: inspectable,
                                        headless: headless)
            self.activeBridges.append(bridge)
            bridge.start { [weak self, weak bridge] result in
                if let self = self, let bridge = bridge {
                    self.activeBridges.removeAll { $0 === bridge }
                }
                completion(result)   // already on the main thread
            }
        }
    }

    // MARK: - Click tracking

    /// Fire Surfside's click pixel for a product the shopper tapped.
    ///
    /// This is a fire-and-forget GET against the product's click-through URL,
    /// which is what records the click server-side. Navigating the shopper to the
    /// destination is the app's responsibility (use ``SurfsideProduct/clickURL``).
    ///
    /// - Parameter completion: Optional; called with `true` if the request
    ///   completed without a transport error. Delivered on an arbitrary queue.
    public func recordClick(_ product: SurfsideProduct,
                            completion: ((Bool) -> Void)? = nil) {
        guard let url = product.clickURL else {
            completion?(false)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        clickSession.dataTask(with: request) { _, response, error in
            let ok = error == nil
            _ = response
            completion?(ok)
        }.resume()
    }

    // MARK: - Helpers

    /// Run `work` on the main thread without redundantly re-dispatching if we're
    /// already there (keeps the synchronous call path fast in the common case).
    private func runOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}
