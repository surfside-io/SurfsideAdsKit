import Foundation

/// The persistent ad page: r.js loaded once, no carousel in the markup. Each fetch
/// inserts its own `<surf-carousel>` through `surfFetch`, which scrapes that one
/// element and removes it again. See ``CarouselPage``.
enum PageHTML {

    static func page(rjsURL: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
          <meta charset="utf-8">
          <style>html, body { margin: 0; padding: 0; }</style>
        </head>
        <body>
          <script src="\(rjsURL)"></script>
          <script>
          \(ShellHTML.productMappingJS)

          // One call per fetch. `attrs` are the <surf-carousel> attributes, `width`
          // the forced carousel width that guarantees maxItems slots (AdRequest).
          function surfFetch(id, attrs, width, expected) {
            var MAX_WAIT_MS = 8000, POLL_MS = 50;
            var started = performance.now();
            var seen = performance.getEntriesByType('resource').length;
            var domId = 'surf-fetch-' + id;

            var el = document.createElement('surf-carousel');
            el.id = domId;
            for (var k in attrs) {
              if (Object.prototype.hasOwnProperty.call(attrs, k)) el.setAttribute(k, attrs[k]);
            }
            el.style.display = 'block';
            el.style.width = width + 'px';
            document.body.appendChild(el);

            function finish(status, products, message) {
              clearInterval(timer);
              var now = performance.now();
              var resources = performance.getEntriesByType('resource').slice(seen).map(function (e) {
                return { name: e.name, startMs: e.startTime - started, durationMs: e.duration };
              });
              window.webkit.messageHandlers.\(CarouselPage.channelName).postMessage(JSON.stringify({
                id: id, status: status, expected: expected, count: products.length,
                products: products, message: message || null,
                timings: { sdkDefinedMs: 0,
                           firstCardMs: status === 'ok' ? now - started : null,
                           postedMs: now - started },
                resources: resources
              }));
              // The web carousel has no disconnect cleanup, so only remove it once
              // its render is over (filled, self-removed, or abandoned at the ceiling).
              var live = document.getElementById(domId);
              if (live) live.remove();
            }

            var timer = setInterval(function () {
              var live = document.getElementById(domId);
              // Same rules as the one-shot shell: gone means the SDK found nothing.
              if (!live) { finish('empty', [], 'carousel removed itself'); return; }
              var products = surfMapCards(live) || [];
              if (products.length > 0) { finish('ok', products); return; }
              if (performance.now() - started >= MAX_WAIT_MS) {
                finish('timeout', [], 'no cards mounted before timeout');
              }
            }, POLL_MS);
          }
          </script>
        </body>
        </html>
        """
    }

    /// The `surfFetch(...)` call for one request. Attributes go through JSON so ids,
    /// categories and keywords can't break out of the script.
    static func fetchCall(id: String, request: AdRequest) -> String? {
        let attrs: [String: String] = [
            "account-id": request.accountId,
            "site-id": request.siteId,
            "channel-id": request.channelId,
            "location-id": request.locationId,
            "zone-id": request.zoneId,
            "category": request.category,
            "keywords": request.keywords,
            "strategy": request.strategy,
            "max-items": String(request.maxItems),
            "card-max-width": String(request.cardWidth),
        ]
        guard
            let attrData = try? JSONSerialization.data(withJSONObject: attrs, options: [.sortedKeys]),
            let attrJSON = String(data: attrData, encoding: .utf8),
            let idData = try? JSONSerialization.data(withJSONObject: [id]),
            let idJSON = String(data: idData, encoding: .utf8)
        else { return nil }
        // idJSON is `["<id>"]`; index it rather than hand-quoting the string.
        return "surfFetch(\(idJSON)[0], \(attrJSON), \(request.carouselWidth), \(request.maxItems));"
    }
}
