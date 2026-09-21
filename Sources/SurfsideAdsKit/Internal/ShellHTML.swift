import Foundation

/// Everything needed to render one carousel and scrape it, resolved for a single
/// fetch. Built by ``SurfsideAds`` from its configuration + the per-call args.
struct AdRequest {
    let accountId: String
    let siteId: String
    let channelId: String
    let locationId: String
    let zoneId: String
    let category: String
    let keywords: String
    let strategy: String
    let maxItems: Int

    // r.js CDN bundle and the fake https origin the shell loads under.
    let rjsURL: String
    let baseURL: String

    /// The resolved tracked first-party device id (`domainUserId`): an explicit
    /// `Configuration.userId` override, else auto-acquired from the Surfside iOS
    /// tracker, else nil for an anonymous fetch (resolution in ``ResolvedIdentity``,
    /// JJRC-456). NOT a shell attribute: it is seeded as the `surfid.` cookie the
    /// unchanged web ad core reads (JJRC-259 path 1; see `decisions/002` transport,
    /// `003` why domainUserId and not uid2).
    let userId: String?

    /// Nominal per-card width (px), also set as `card-max-width`. Only feeds the
    /// carousel's internal slot math — it is NOT a layout constraint on the
    /// native side (we never show the card), so it stays fixed and internal.
    let cardWidth: Int

    // --- Deterministic max-items sizing --------------------------------------
    // The carousel mounts `min(maxItems, slotsAvailable)` cards in its FIRST pass,
    // where `slotsAvailable = floor(clientWidth / cardWidth)` and the `.items`
    // track reserves `itemsPadding` px (see ads-sdk-key-mechanics). In the
    // headless bridge there is no real viewport to lean on, so we FORCE a carousel
    // width that provably yields `slotsAvailable >= maxItems`. That makes
    // `maxItems` the true ceiling and guarantees every available product mounts in
    // one pass — no paging, no viewport dependence, no undercount.

    /// Horizontal padding the SDK's `.items` track reserves, in px.
    static let itemsPadding = 74
    /// Spare card slots beyond `maxItems`, so integer rounding (and the padding
    /// subtraction) can never starve us below the requested count.
    static let slotHeadroom = 2

    /// Forced carousel width (px). Derivation of the guarantee, worst case where
    /// the SDK subtracts the full padding before dividing:
    ///   slotsAvailable = floor((carouselWidth - itemsPadding) / cardWidth)
    ///                  = floor((maxItems + slotHeadroom) * cardWidth / cardWidth)
    ///                  = maxItems + slotHeadroom  ( >= maxItems ). ✓
    /// Extra slots never yield extra cards — `maxItems` caps the first pass — so
    /// over-provisioning is free.
    var carouselWidth: Int {
        (maxItems + Self.slotHeadroom) * cardWidth + Self.itemsPadding
    }

    /// The JS message-channel name. Must match the handler registered in Swift.
    static let channelName = "surfside"
}

/// Builds the tiny HTML shell + the scraper JS that runs inside the hidden
/// WebView. Kept as pure string-building so it's trivial to unit-inspect.
enum ShellHTML {

    /// The full page: styled sized carousel + r.js + the scraper.
    ///
    /// Two `<script>`s matter here: `r.js` registers `<surf-carousel>` and renders
    /// it ASYNCHRONOUSLY (bid request + debounce), so the scraper can't run once —
    /// it polls until cards mount or the carousel removes itself, then posts back.
    static func page(for request: AdRequest) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="utf-8">
          <style>
            html, body { margin: 0; padding: 0; }
            /* Custom elements are display:inline by default; make it a sized block
               so its clientWidth is deterministic and drives slotsAvailable. */
            surf-carousel { display: block; width: \(request.carouselWidth)px; }
          </style>
        </head>
        <body>
          <surf-carousel
            account-id="\(request.accountId)"
            site-id="\(request.siteId)"
            channel-id="\(request.channelId)"
            location-id="\(request.locationId)"
            zone-id="\(request.zoneId)"
            category="\(request.category)"
            keywords="\(request.keywords)"
            strategy="\(request.strategy)"
            max-items="\(request.maxItems)"
            card-max-width="\(request.cardWidth)">
          </surf-carousel>

          <script src="\(request.rjsURL)"></script>
          <script>\(scraperJS(for: request))</script>
        </body>
        </html>
        """
    }

    /// Card -> product mapping shared by the one-shot shell and the persistent page:
    /// `surfMapCards(element)` reads each mounted card's `.productData` and flattens
    /// it to our public product shape, or returns null before the carousel renders.
    static let productMappingJS = """
        // Some fields come back as the literal string "null" or "": treat those
        // as absent so Swift sees a real nil instead of the text "null".
        function clean(v) {
          return (v == null || v === 'null' || v === '') ? null : v;
        }

        // ext carries catalog extras (variants/sizes/keys). We expose it as a
        // flat string map, so stringify anything non-primitive and clean the rest.
        function flattenExt(ext) {
          if (!ext || typeof ext !== 'object') return null;
          var out = {}, any = false;
          for (var k in ext) {
            if (!Object.prototype.hasOwnProperty.call(ext, k)) continue;
            var v = ext[k];
            if (v == null) continue;
            var s = (typeof v === 'object') ? JSON.stringify(v) : String(v);
            s = clean(s);
            if (s != null) { out[k] = s; any = true; }
          }
          return any ? out : null;
        }

        // Pull tracker URLs out of the built card's trackers object. A tracker
        // is {type:'pixel', url} or {type:'script', src}. When pixelOnly is set
        // we keep only the img pixels, the ones the fetch WebView's image
        // suppression actually blocks, so firing them on display can't double
        // count. Script trackers fire once at fetch (unsuppressed) and are left
        // out of the fire set on purpose.
        function trackerUrls(named, key, pixelOnly) {
          var arr = named && named[key];
          if (!Array.prototype.slice.call(arr || []).length) return [];
          return Array.prototype.slice.call(arr)
            .filter(function (t) { return t && (!pixelOnly || t.type === 'pixel'); })
            .map(function (t) { return t && (t.url || t.src); })
            .filter(function (u) { return typeof u === 'string' && u; });
        }

        function surfMapCards(carousel) {
          var root = carousel && carousel.shadowRoot;
          var items = root && root.querySelector('.items');
          if (!items) return null;
          return Array.prototype.slice.call(items.children)
            .map(function (c) { return c.productData; })
            .filter(function (pd) { return pd && pd.product; })
            .map(function (pd) {
              var p = pd.product;
              var named = (pd.trackers && pd.trackers.namedTrackers) || {};
              return {
                id: String(p.id != null ? p.id : ''),
                name: clean(p.name),
                price: clean(p.price),
                salePrice: clean(p.salePrice),
                image: clean(p.image),
                brandName: clean(p.brandName || p.brand_name),
                productType: clean(p.productType),
                thc: clean(p.thc),
                strain: clean(p.strain),
                cbd: clean(p.cbd),
                clickthrough: clean(pd.clickthrough),
                sponsored: !!pd.sponsored,
                ext: flattenExt(p.ext),
                winTrackers: trackerUrls(named, 'win', true),
                impressionTrackers: trackerUrls(named, 'impression', true),
                viewableTrackers: trackerUrls(named, 'viewable', false)
              };
            });
        }
        """

    /// The injected poller. Reads each mounted card's `.productData`, flattens it
    /// to our public product shape, and posts a JSON envelope over the bridge.
    private static func scraperJS(for request: AdRequest) -> String {
        """
        (function () {
          var EXPECTED = \(request.maxItems);
          var MAX_WAIT_MS = 8000, POLL_MS = 50;
          var waited = 0;
          var sdkDefinedMs = null, firstCardMs = null;

          function sdkDefined() {
            return !!(window.customElements && customElements.get('surf-carousel'));
          }

          // Every request the page made (r.js, config, geo, bid, product feeds),
          // so a fetch that never bids is visible as a missing row.
          function resources() {
            if (!window.performance || !performance.getEntriesByType) return [];
            return performance.getEntriesByType('resource').map(function (e) {
              return { name: e.name, startMs: e.startTime, durationMs: e.duration };
            });
          }

          \(productMappingJS)

          function readProducts() {
            return surfMapCards(document.querySelector('surf-carousel'));
          }

          function send(status, products, message) {
            var arr = products || [];
            window.webkit.messageHandlers.\(AdRequest.channelName).postMessage(JSON.stringify({
              status: status, expected: EXPECTED, count: arr.length,
              products: arr, message: message || null,
              timings: { sdkDefinedMs: sdkDefinedMs, firstCardMs: firstCardMs,
                         postedMs: performance.now() },
              resources: resources()
            }));
          }

          var timer = setInterval(function () {
            waited += POLL_MS;
            var products = readProducts();
            var count = products ? products.length : 0;
            if (sdkDefinedMs === null && sdkDefined()) sdkDefinedMs = performance.now();
            if (firstCardMs === null && count > 0) firstCardMs = performance.now();

            // The SDK awaits the whole first page, then appends every card in one
            // synchronous loop, so the first non-zero count is already final.
            if (count > 0) { clearInterval(timer); send('ok', products); return; }

            // No fill: the SDK removes <surf-carousel> once its first page comes
            // back empty (after the recommender fallback under hybrid), so
            // "SDK ran and the element is gone" is a definite empty.
            if (sdkDefined() && !document.querySelector('surf-carousel')) {
              clearInterval(timer); send('empty', [], 'carousel removed itself'); return;
            }

            if (waited >= MAX_WAIT_MS) {
              clearInterval(timer);
              // Backstop only. r.js registers the custom element, so defined
              // means the SDK ran and served nothing we could see (empty); not
              // defined means r.js never loaded (timeout).
              send(sdkDefined() ? 'empty' : 'timeout', [],
                   'no cards mounted before timeout');
            }
          }, POLL_MS);
        })();
        """
    }
}
