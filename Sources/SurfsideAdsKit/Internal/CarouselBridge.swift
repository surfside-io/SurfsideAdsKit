import Foundation
@preconcurrency import WebKit
#if canImport(UIKit)
import UIKit
#endif

/// The JSON envelope the JS scraper posts back over the bridge.
///
/// `status` lets us tell "the plumbing ran but there was no inventory" (`empty`)
/// apart from "nothing ever mounted" (`timeout`).
private struct BridgePayload: Decodable {
    let status: String            // "ok" | "empty" | "timeout"
    let expected: Int
    let count: Int
    let products: [SurfsideProduct]
    let message: String?
}

/// Owns one hidden, **one-shot** WKWebView for a single fetch: create → load →
/// scrape → resolve → tear down. A fresh bridge is built per `fetchProducts`.
///
/// Why `NSObject`: `WKScriptMessageHandler` is an Obj-C protocol, so the handler
/// must be an `NSObject` subclass. The bridge is its own handler to stay compact.
///
/// Not actor-isolated on purpose (matches the proven spike): every method here is
/// only ever called on the main thread — `SurfsideAds` starts it there, and both
/// WebKit delegate callbacks (message + navigation) fire on the main thread. This
/// keeps it usable on the iOS 14 floor without `assumeIsolated` (iOS 17+).
@available(iOS 14.0, *)
final class CarouselBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {

    private let request: AdRequest
    private let timeout: TimeInterval
    private let isInspectable: Bool
    /// When true, the WebView is left un-hosted (no window). See `Configuration.headless`.
    private let headless: Bool

    private var webView: WKWebView?
    /// Called exactly once. Guarded by `didFinish` so the message, a nav failure,
    /// and the backstop timer can all race without double-resolving.
    private var completion: ((Result<[SurfsideProduct], Error>) -> Void)?
    private var didFinish = false

    init(request: AdRequest, timeout: TimeInterval, isInspectable: Bool, headless: Bool = false) {
        self.request = request
        self.timeout = timeout
        self.isInspectable = isInspectable
        self.headless = headless
        super.init()
    }

    /// Builds the WebView, registers the channel, kicks off the load, and arms a
    /// Swift-side timeout backstop (in case the WebView never runs its JS at all —
    /// e.g. if a headless, un-hosted WebView doesn't tick its timers on some OS).
    func start(_ completion: @escaping (Result<[SurfsideProduct], Error>) -> Void) {
        self.completion = completion

        // Register the message channel BEFORE loading, so
        // `window.webkit.messageHandlers.surfside` exists when our script runs.
        let controller = WKUserContentController()
        controller.add(self, name: AdRequest.channelName)

        let config = WKWebViewConfiguration()
        config.userContentController = controller

        // Give it a real, non-zero frame. The carousel width is forced in CSS so
        // the card count doesn't depend on this, but a genuine viewport keeps the
        // document's layout/JS behaving like the proven spike.
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 320),
            configuration: config
        )
        webView.navigationDelegate = self
        if #available(iOS 16.4, macOS 13.3, *) {
            // Off by default in the package; opt in via config for debugging only.
            webView.isInspectable = isInspectable
        }
        self.webView = webView

        // WebKit throttles/suspends the web process of a WKWebView that is not
        // in any window, so an un-hosted view never runs the SDK's JS (verified
        // in-app: every fetch hit the Swift backstop timeout). Host it in the
        // key window for the lifetime of the fetch — invisible (alpha 0, like
        // the proven spike; NOT `isHidden`, which can suspend rendering),
        // non-interactive, and parked offscreen. Removed again in `teardown()`.
        // Skipped when `headless` is set (opt-in un-hosted mode — expect timeouts).
        #if canImport(UIKit)
        if !headless, let window = Self.hostWindow() {
            webView.alpha = 0
            webView.isUserInteractionEnabled = false
            webView.frame = CGRect(x: -400, y: 0, width: 320, height: 320)
            window.addSubview(webView)
        }
        #endif

        webView.loadHTMLString(ShellHTML.page(for: request),
                               baseURL: URL(string: request.baseURL))

        // Backstop: the JS has its own 8s ceiling, but if it never runs we'd hang
        // forever. Resolve as .timeout after `timeout` seconds unless already done.
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(.failure(SurfsideAdsError.timeout))
        }
    }

    /// Resolve once, then tear down. Idempotent.
    private func finish(_ result: Result<[SurfsideProduct], Error>) {
        guard !didFinish else { return }
        didFinish = true
        let done = completion
        completion = nil
        teardown()
        done?(result)
    }

    /// Break the retain cycle: the content controller strongly holds its message
    /// handlers, which hold this bridge.
    private func teardown() {
        webView?.stopLoading()
        webView?.configuration.userContentController
            .removeScriptMessageHandler(forName: AdRequest.channelName)
        webView?.navigationDelegate = nil
        #if canImport(UIKit)
        webView?.removeFromSuperview()
        #endif
        webView = nil
    }

    #if canImport(UIKit)
    /// The window to host the hidden WebView in: the key window of a foreground
    /// scene, else any window at all. `nil` (e.g. under XCTest, or before any
    /// window exists) falls back to the old un-hosted behavior.
    private static func hostWindow() -> UIWindow? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        return windows.first(where: { $0.isKeyWindow }) ?? windows.first
    }
    #endif

    // MARK: WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        // Fires on the main thread; we post a JSON *string* from JS (most robust
        // across the bridge), so decode it in `handle`.
        guard message.name == AdRequest.channelName else { return }
        handle(message.body)
    }

    private func handle(_ body: Any) {
        guard
            let json = body as? String,
            let data = json.data(using: .utf8),
            let payload = try? JSONDecoder().decode(BridgePayload.self, from: data)
        else {
            finish(.failure(SurfsideAdsError.decodeFailed))
            return
        }

        switch payload.status {
        case "ok":
            finish(.success(payload.products))
        case "empty":
            // Bridge ran, zone had no fill → normal empty result, not an error.
            finish(.success(payload.products))   // guaranteed empty here
        default:
            finish(.failure(SurfsideAdsError.timeout))
        }
    }

    // MARK: WKNavigationDelegate

    // surfside.io hosts need their server trust accepted explicitly (mirrors the
    // live banner view). Main-frame only — this does not cover <img> pixel loads.
    func webView(_ webView: WKWebView,
                 didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.host.contains("surfside.io"),
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(SurfsideAdsError.loadFailed(error.localizedDescription)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(SurfsideAdsError.loadFailed(error.localizedDescription)))
    }
}
