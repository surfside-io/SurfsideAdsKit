#if canImport(UIKit)
import Foundation
import UIKit
import SafariServices
@preconcurrency import WebKit

/// Delegate callbacks for a ``SurfsideBannerView``'s load outcome. All methods
/// have default no-op implementations, so a host implements only what it needs.
@available(iOS 14.0, *)
public protocol SurfsideBannerViewDelegate: AnyObject {
    /// A creative rendered and the banner is on screen. `size` is the measured
    /// rendered size when the shell could read it, else `nil` (the view is already
    /// sized to the requested dimensions in that case).
    func surfsideBannerViewDidLoad(_ bannerView: SurfsideBannerView, size: CGSize?)
    /// The zone had no fill. The view has collapsed itself to zero height. No-fill
    /// is a normal outcome, not an error.
    func surfsideBannerViewDidReceiveNoFill(_ bannerView: SurfsideBannerView)
    /// The load failed (navigation error, or a timeout with nothing mounted). The
    /// view has collapsed itself to zero height.
    func surfsideBannerView(_ bannerView: SurfsideBannerView, didFailWithError error: SurfsideAdsError)
}

@available(iOS 14.0, *)
public extension SurfsideBannerViewDelegate {
    func surfsideBannerViewDidLoad(_ bannerView: SurfsideBannerView, size: CGSize?) {}
    func surfsideBannerViewDidReceiveNoFill(_ bannerView: SurfsideBannerView) {}
    func surfsideBannerView(_ bannerView: SurfsideBannerView, didFailWithError error: SurfsideAdsError) {}
}

/// A visible, persistent banner ad view.
///
/// Unlike the hidden carousel fetch, this hosts an on-screen `WKWebView` that loads
/// the web ads SDK and shows whatever creative the zone serves. The banner measures
/// itself (its own win/impression pixels firing on screen is a legitimate viewable
/// impression, so nothing is suppressed or scraped). Clickthrough is whatever
/// `<a href>` the bidder baked into the creative: a tap navigates the WebView, which
/// this view intercepts and opens in an in-app `SFSafariViewController`. On no-fill
/// the view collapses to zero height and notifies the delegate.
///
/// ```swift
/// let banner = SurfsideBannerView(
///     configuration: .init(accountId: "ec981", siteId: "544fa",
///                          channelId: "00000", locationId: "greengoddess"),
///     zoneId: "6ambm",
///     size: CGSize(width: 4, height: 1)      // the zone's banner ratio (8x1, 4x1, 2x1)
/// )
/// banner.delegate = self
/// stackView.addArrangedSubview(banner)   // auto-loads once it enters a window
/// ```
@available(iOS 14.0, *)
public final class SurfsideBannerView: UIView, WKScriptMessageHandler, WKNavigationDelegate {

    /// Receives load-outcome callbacks. Weak, set it after init.
    public weak var delegate: SurfsideBannerViewDelegate?

    /// When `true` (default) the banner loads itself the first time it enters a
    /// window. Set `false` to drive loading manually with ``load()``.
    public var autoLoad: Bool = true

    private let request: BannerRequest
    private let requestedSize: CGSize
    private let isInspectable: Bool
    private let timeout: TimeInterval

    private var webView: WKWebView?
    private var hasLoaded = false
    /// The load resolves exactly once. The watcher message, a nav failure, and the
    /// backstop timer can all race; the first one wins.
    private var didResolve = false
    private var renderedSize: CGSize?
    private var collapsed = false

    // MARK: Init

    /// Designated initializer.
    ///
    /// - Parameters:
    ///   - configuration: Placement identity and knobs (the same
    ///     ``SurfsideAds/Configuration`` the fetch path uses).
    ///   - zoneId: The placement/zone id to request.
    ///   - size: The requested banner size. Feeds the bid request and is the
    ///     intrinsic size until (and unless) the shell reports a rendered size.
    ///   - delegate: Optional load-outcome delegate.
    public init(configuration: SurfsideAds.Configuration,
                zoneId: String,
                size: CGSize,
                delegate: SurfsideBannerViewDelegate? = nil) {
        self.requestedSize = size
        self.request = BannerRequest(
            accountId: configuration.accountId,
            siteId: configuration.siteId,
            channelId: configuration.channelId,
            locationId: configuration.locationId,
            zoneId: zoneId,
            category: configuration.category,
            keywords: configuration.keywords,
            width: Int(size.width.rounded()),
            height: Int(size.height.rounded()),
            rjsURL: configuration.rjsURL,
            baseURL: configuration.baseURL
        )
        self.isInspectable = configuration.isInspectable
        self.timeout = configuration.requestTimeout
        self.delegate = delegate
        super.init(frame: CGRect(origin: .zero, size: size))
        clipsToBounds = true
    }

    /// Convenience initializer for the common case: the four placement IDs, a zone,
    /// and a size.
    public convenience init(accountId: String,
                            siteId: String,
                            channelId: String,
                            locationId: String,
                            zoneId: String,
                            width: CGFloat,
                            height: CGFloat) {
        self.init(configuration: SurfsideAds.Configuration(
            accountId: accountId, siteId: siteId,
            channelId: channelId, locationId: locationId),
                  zoneId: zoneId,
                  size: CGSize(width: width, height: height))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SurfsideBannerView must be created in code, not from a nib.")
    }

    deinit {
        // Break the content-controller -> handler edge (the proxy is weak, so this
        // is cleanup, not cycle-breaking).
        webView?.configuration.userContentController
            .removeScriptMessageHandler(forName: BannerRequest.channelName)
    }

    // MARK: Loading

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        // A visible banner is always in a window, and WebKit only reliably ticks a
        // WebView's JS timers when it is hosted (same lesson as the fetch bridge),
        // so first window-entry is the natural auto-load trigger.
        if window != nil, autoLoad, !hasLoaded { load() }
    }

    /// Build the WebView and load the banner shell. Idempotent: the first call wins
    /// and later calls are no-ops (use a fresh view to reload).
    public func load() {
        guard !hasLoaded else { return }
        hasLoaded = true

        // Register the channel with a WEAK proxy: the content controller strongly
        // holds its handlers, so adding `self` directly would retain-cycle the view.
        let controller = WKUserContentController()
        controller.add(WeakScriptMessageHandler(self), name: BannerRequest.channelName)

        let config = WKWebViewConfiguration()
        config.userContentController = controller

        let webView = WKWebView(frame: bounds, configuration: config)
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        if #available(iOS 16.4, *) {
            webView.isInspectable = isInspectable
        }
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        self.webView = webView

        // Backstop: if the watcher never runs (r.js stalls, JS never ticks) resolve
        // as .timeout so the view can't hang half-loaded.
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.resolve(.timeout)
        }

        webView.loadHTMLString(BannerShellHTML.page(for: request),
                               baseURL: URL(string: request.baseURL))
    }

    // MARK: Sizing

    public override var intrinsicContentSize: CGSize {
        if collapsed { return CGSize(width: requestedSize.width, height: 0) }
        return renderedSize ?? requestedSize
    }

    // MARK: Resolution

    /// Apply a load outcome exactly once: size to a filled creative, or collapse.
    private func resolve(_ status: SurfsideBannerStatus) {
        guard !didResolve else { return }
        didResolve = true

        switch status {
        case .filled(let size):
            let measured = size.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }
            renderedSize = measured ?? requestedSize
            collapsed = false
            invalidateIntrinsicContentSize()
            delegate?.surfsideBannerViewDidLoad(self, size: measured)
        case .empty:
            collapse()
            delegate?.surfsideBannerViewDidReceiveNoFill(self)
        case .timeout:
            collapse()
            delegate?.surfsideBannerView(self, didFailWithError: .timeout)
        case .loadFailed(let reason):
            collapse()
            delegate?.surfsideBannerView(self, didFailWithError: .loadFailed(reason))
        }
    }

    /// Zero the height and hide the WebView. Height collapses via
    /// ``intrinsicContentSize`` for Auto Layout hosts; `isHidden` covers hosts that
    /// pin an explicit height.
    private func collapse() {
        collapsed = true
        renderedSize = nil
        isHidden = true
        webView?.stopLoading()
        invalidateIntrinsicContentSize()
    }

    // MARK: WKScriptMessageHandler

    public func userContentController(_ userContentController: WKUserContentController,
                                      didReceive message: WKScriptMessage) {
        guard message.name == BannerRequest.channelName else { return }
        // A malformed payload can't be trusted as fill; ignore it and let the
        // backstop time out rather than flashing an unsized WebView.
        guard let status = SurfsideBannerStatus.parse(message: message.body) else { return }
        resolve(status)
    }

    // MARK: WKNavigationDelegate

    public func webView(_ webView: WKWebView,
                        decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        let scheme = url.scheme?.lowercased()
        let isExternalHTTP = (scheme == "http" || scheme == "https")
        // The creative's baked-in <a href> is the only clickthrough; a tap is a
        // link-activated main-frame nav, and target="_blank" gives a nil targetFrame.
        // Intercept those to Safari, but let the initial shell load, r.js, and
        // subresource loads (navigationType .other, real main frame) proceed.
        let userInitiated = navigationAction.navigationType == .linkActivated
        let opensNewFrame = navigationAction.targetFrame == nil

        if isExternalHTTP, userInitiated || opensNewFrame {
            decisionHandler(.cancel)
            openExternally(url)
            return
        }
        decisionHandler(.allow)
    }

    // surfside.io hosts need their server trust accepted explicitly (mirrors the
    // fetch bridge). Main-frame only.
    public func webView(_ webView: WKWebView,
                        didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.host.contains("surfside.io"),
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        // Guarded by didResolve: a load failure after a filled render (e.g. a
        // cancelled clickthrough nav) can't collapse an already-shown banner.
        resolve(.loadFailed(error.localizedDescription))
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        resolve(.loadFailed(error.localizedDescription))
    }

    // MARK: Clickthrough

    /// Open a tapped clickthrough in an in-app Safari sheet, falling back to the
    /// system browser if no view controller is available to present from.
    private func openExternally(_ url: URL) {
        guard let presenter = topmostViewController() else {
            UIApplication.shared.open(url)
            return
        }
        let safari = SFSafariViewController(url: url)
        presenter.present(safari, animated: true)
    }

    /// Nearest view controller up the responder chain, then its top-most presented
    /// controller (so a sheet presents on whatever is already frontmost).
    private func topmostViewController() -> UIViewController? {
        var responder: UIResponder? = self
        var owner: UIViewController?
        while let next = responder {
            if let vc = next as? UIViewController { owner = vc; break }
            responder = next.next
        }
        var top = owner ?? window?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}

/// Forwards script messages to a weakly-held handler, so the content controller's
/// strong reference to its handlers doesn't retain-cycle the owning view.
@available(iOS 14.0, *)
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
#endif
