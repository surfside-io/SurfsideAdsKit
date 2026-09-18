import Foundation
@preconcurrency import WebKit

/// Debug-only bridge from the web SDK's console to the native log.
///
/// The web SDK logs its own decisions (config, bid request and response, why a
/// placement rendered nothing) when the page URL carries `surf_debug=true`, but a
/// WKWebView's console never reaches Xcode. With `Configuration.isInspectable` set,
/// the shells load under that flag and every console line is forwarded to `NSLog`.
enum DebugConsole {

    static let channelName = "surfsideConsole"
    /// Card markup and whole bid responses get logged; keep lines readable. Warnings
    /// and errors get more room: a no-bid warning carries the full bid request.
    static let maxLineLength = 600
    static let maxProblemLineLength = 6000

    /// `baseURL` with `surf_debug=true` added when `debug` is set.
    static func pageURL(baseURL: String, debug: Bool) -> URL? {
        guard debug, var components = URLComponents(string: baseURL) else {
            return URL(string: baseURL)
        }
        var items = components.queryItems ?? []
        if !items.contains(where: { $0.name == "surf_debug" }) {
            items.append(URLQueryItem(name: "surf_debug", value: "true"))
        }
        components.queryItems = items
        if components.path.isEmpty { components.path = "/" }
        return components.url
    }

    static let captureJS = """
    (function () {
      function text(v) {
        if (typeof v === 'string') return v;
        if (v instanceof Error) return v.name + ': ' + v.message;
        try { return JSON.stringify(v); } catch (e) { return String(v); }
      }
      ['debug', 'log', 'info', 'warn', 'error'].forEach(function (level) {
        var original = console[level];
        console[level] = function () {
          try {
            // The SDK styles its prefix with %c; drop each %c and the CSS argument
            // it consumes, which mean nothing outside a browser console.
            var args = Array.prototype.slice.call(arguments);
            if (typeof args[0] === 'string' && args[0].indexOf('%c') !== -1) {
              var styles = args[0].split('%c').length - 1;
              args = [args[0].replace(/%c/g, '')].concat(args.slice(1 + styles));
            }
            var line = args.map(text).join(' ');
            window.webkit.messageHandlers.\(channelName).postMessage(level + ' ' + line);
          } catch (e) {}
          if (original) original.apply(console, arguments);
        };
      });
      window.addEventListener('error', function (e) {
        try { window.webkit.messageHandlers.\(channelName).postMessage('error uncaught: ' + e.message); } catch (x) {}
      });
    })();
    """

    /// No-op unless `debug`. `label` says which WebView a line came from.
    static func install(on controller: WKUserContentController, label: String, debug: Bool) {
        guard debug else { return }
        controller.addUserScript(WKUserScript(source: captureJS,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true))
        controller.add(Forwarder(label: label), name: channelName)
    }

    static func format(label: String, message: String) -> String {
        let isProblem = message.hasPrefix("warn ") || message.hasPrefix("error ")
        let limit = isProblem ? maxProblemLineLength : maxLineLength
        let line = message.count > limit
            ? String(message.prefix(limit)) + " …(\(message.count) chars)"
            : message
        return "SurfsideAdsKit console [\(label)] \(line)"
    }

    /// Holds no reference to any view, so the controller retaining it is not a cycle.
    private final class Forwarder: NSObject, WKScriptMessageHandler {
        let label: String
        init(label: String) { self.label = label }
        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let text = message.body as? String else { return }
            NSLog("%@", DebugConsole.format(label: label, message: text))
        }
    }
}
