import Foundation

/// Everything needed to render one banner, resolved for a single load. Built by
/// ``SurfsideBannerView`` from a ``SurfsideAds/Configuration`` plus the per-call
/// zone and requested size. Mirrors `AdRequest`.
struct BannerRequest {
    let accountId: String
    let siteId: String
    let channelId: String
    let locationId: String
    let zoneId: String
    let category: String
    let keywords: String

    /// Requested banner dimensions (px). These feed the SDK's **bid request**, they
    /// are NOT applied as a CSS size: the served creative sets its own aspect ratio
    /// (`RenderBanner` reads the bid w/h into `style.aspectRatio`). So they scope the
    /// demand, and the native wrapper sizes to what actually renders.
    let width: Int
    let height: Int

    // r.js CDN bundle and the fake https origin the shell loads under.
    let rjsURL: String
    let baseURL: String

    /// The JS message-channel name. Must match the handler registered in Swift.
    /// Distinct from the carousel's so the two shells can never cross-talk.
    static let channelName = "surfsideBanner"
}

/// Builds the tiny HTML shell + the watcher JS for a visible banner WebView. Kept
/// as pure string-building (like `ShellHTML`) so it's trivial to unit-inspect on
/// the host without a device.
///
/// The banner is the OPPOSITE of the carousel fetch: it is on-screen and
/// persistent, so we do NOT scrape or suppress pixels. A filled render populates
/// `<surf-banner>`'s shadow root (creative + the SDK's own appended win `<img>`),
/// which is a legitimate viewable impression. The watcher's only job is to tell
/// native whether a creative rendered (and at what size) so the wrapper can size
/// itself, or collapse on no-fill.
enum BannerShellHTML {

    /// The full page: `<surf-banner>` with the bid attributes + r.js + the watcher.
    static func page(for request: BannerRequest) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>
            html, body { margin: 0; padding: 0; }
            /* Custom elements are display:inline by default; make it a block so the
               creative lays out and getBoundingClientRect reports a real size. */
            surf-banner { display: block; }
          </style>
        </head>
        <body>
          <surf-banner
            account-id="\(request.accountId)"
            site-id="\(request.siteId)"
            channel-id="\(request.channelId)"
            location-id="\(request.locationId)"
            zone-id="\(request.zoneId)"
            category="\(request.category)"
            keywords="\(request.keywords)"
            width="\(request.width)"
            height="\(request.height)">
          </surf-banner>

          <script src="\(request.rjsURL)"></script>
          <script>\(watcherJS())</script>
        </body>
        </html>
        """
    }

    /// The injected watcher. Polls the banner's shadow root: once it has rendered
    /// content it posts `filled` with the measured size; if nothing renders before
    /// the internal ceiling it posts `empty` (SDK ran, no fill) or `timeout` (r.js
    /// never loaded), the same split the carousel scraper uses.
    private static func watcherJS() -> String {
        """
        (function () {
          var MAX_WAIT_MS = 8000, POLL_MS = 200;
          var waited = 0, sent = false;

          function post(obj) {
            try {
              window.webkit.messageHandlers.\(BannerRequest.channelName).postMessage(JSON.stringify(obj));
            } catch (e) {}
          }

          // A filled render populates the shadow root (the creative, plus the win
          // <img> the SDK appends). No shadow child means render() returned early.
          function filledSize() {
            var el = document.querySelector('surf-banner');
            var root = el && el.shadowRoot;
            if (!root || !root.firstElementChild) return null;
            var rect = el.getBoundingClientRect();
            return { w: Math.round(rect.width), h: Math.round(rect.height) };
          }

          var timer = setInterval(function () {
            waited += POLL_MS;
            if (!sent) {
              var size = filledSize();
              if (size) {
                sent = true; clearInterval(timer);
                post({ status: 'filled', width: size.w, height: size.h });
                return;
              }
            }
            if (waited >= MAX_WAIT_MS) {
              clearInterval(timer);
              if (sent) return;
              // Element defined => the SDK executed and served nothing (empty);
              // not defined => r.js never loaded (timeout).
              var sdkRan = !!(window.customElements &&
                              customElements.get('surf-banner'));
              post({ status: sdkRan ? 'empty' : 'timeout' });
            }
          }, POLL_MS);
        })();
        """
    }
}
