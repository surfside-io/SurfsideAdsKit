import Foundation
@preconcurrency import WebKit
#if canImport(UIKit)
import UIKit
#endif

private struct PagePayload: Decodable {
    let id: String
    let status: String            // "ok" | "empty" | "timeout"
    let products: [SurfsideProduct]
    let timings: ShellTimings?
    let resources: [ShellResource]?
}

/// One hidden, hosted WKWebView kept alive for a `SurfsideAds` instance. r.js loads
/// once; every fetch inserts its own `<surf-carousel>` (see ``PageHTML``), so WebKit
/// process start, page navigation, r.js and the web SDK's init are paid once instead
/// of per fetch. Concurrent fetches are just several elements on the page.
///
/// Constraints this class exists to hold:
/// - **Identity is page-wide.** The web SDK reads the `surfid.` cookie at init, so a
///   fetch for a different user reloads the whole page first (decided 2026-09-18).
/// - **The page is recycled** after `recycleAfterFetches` fetches or
///   `recycleAfterSeconds`, because the web carousel has no disconnect cleanup and
///   config/geo are frozen at init.
/// - **WebKit can kill the content process** at any time; in-flight fetches are
///   retried once on a fresh page.
/// - Main-thread only, like ``CarouselBridge``.
@available(iOS 14.0, *)
final class CarouselPage: NSObject, WKScriptMessageHandler, WKNavigationDelegate {

    static let channelName = "surfsidePage"
    // `var` so an in-app harness can shrink them; nothing in the package writes them.
    static var recycleAfterFetches = 50
    static var recycleAfterSeconds: TimeInterval = 30 * 60

    private enum State { case cold, loading, ready }

    private final class Pending {
        let id = UUID().uuidString
        let request: AdRequest
        let completion: (Result<[SurfsideProduct], Error>) -> Void
        var timeline = FetchTimeline()
        var retried = false
        init(request: AdRequest, completion: @escaping (Result<[SurfsideProduct], Error>) -> Void) {
            self.request = request
            self.completion = completion
        }
    }

    private let rjsURL: String
    private let baseURL: String
    private let isInspectable: Bool

    private var webView: WKWebView?
    private var state: State = .cold
    /// Identity the current page was loaded with. Double optional: `nil` = no page yet.
    private var pageUserId: String??
    /// Identity of the last page, kept across a background release so foreground
    /// can rebuild the same page. `nil` until a page has existed.
    private var lastUserId: String??
    private var loadedAt = Date.distantPast
    private var loadStarted = Date()
    private var served = 0

    private var queued: [Pending] = []
    private var inFlight: [String: Pending] = [:]
    private var observers: [NSObjectProtocol] = []

    init(rjsURL: String, baseURL: String, isInspectable: Bool) {
        self.rjsURL = rjsURL
        self.baseURL = baseURL
        self.isInspectable = isInspectable
        super.init()
        observeAppLifecycle()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        teardown()
    }

    /// Page state changes, in the same debug log as the fetch timelines.
    private func note(_ event: String) {
        if isInspectable { NSLog("%@", "SurfsideAdsKit page: " + event) }
    }

    /// A page needs a window to live in (an un-hosted WebView's JS is throttled).
    var canServe: Bool { Self.hostWindow() != nil }

    // MARK: Entry points

    /// Load the page ahead of the first fetch. No-op once a page exists.
    func warmUp(userId: String?) {
        guard state == .cold, canServe else { return }
        load(userId: userId, reason: "warm up")
    }

    func fetch(_ request: AdRequest,
               timeout: TimeInterval,
               completion: @escaping (Result<[SurfsideProduct], Error>) -> Void) {
        let pending = Pending(request: request, completion: completion)
        queued.append(pending)
        let id = pending.id
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.resolve(id, .failure(SurfsideAdsError.timeout), outcome: "timeout(native)")
        }
        if state == .cold { load(userId: request.userId, reason: "first fetch") } else { drain() }
    }

    // MARK: Scheduling

    private var needsRecycle: Bool {
        served >= Self.recycleAfterFetches
            || Date().timeIntervalSince(loadedAt) >= Self.recycleAfterSeconds
    }

    /// Inject what the current page can serve. A fetch that needs a different
    /// identity (or a recycled page) waits for in-flight ones, then reloads.
    private func drain() {
        guard state == .ready else { return }
        while let next = queued.first {
            let identityChanged = .some(next.request.userId) != pageUserId
            if identityChanged || needsRecycle {
                if inFlight.isEmpty {
                    load(userId: next.request.userId,
                         reason: identityChanged ? "identity changed" : "recycle after \(served) fetches")
                }
                return
            }
            queued.removeFirst()
            inject(next)
        }
    }

    private func inject(_ pending: Pending) {
        guard let js = PageHTML.fetchCall(id: pending.id, request: pending.request) else {
            finish(pending, .failure(SurfsideAdsError.decodeFailed), outcome: "failed(encode)")
            return
        }
        inFlight[pending.id] = pending
        served += 1
        pending.timeline.mark("injected")
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    private func resolve(_ id: String,
                         _ result: Result<[SurfsideProduct], Error>,
                         outcome: String,
                         shell: ShellTimings? = nil,
                         resources: [ShellResource] = []) {
        let pending = inFlight.removeValue(forKey: id) ?? {
            guard let index = queued.firstIndex(where: { $0.id == id }) else { return nil }
            return queued.remove(at: index)
        }()
        guard let pending = pending else { return }   // already resolved
        finish(pending, result, outcome: outcome, shell: shell, resources: resources)
        drain()
    }

    private func finish(_ pending: Pending,
                        _ result: Result<[SurfsideProduct], Error>,
                        outcome: String,
                        shell: ShellTimings? = nil,
                        resources: [ShellResource] = []) {
        pending.timeline.mark("finished")
        if isInspectable {
            NSLog("%@", pending.timeline.report(kind: "fetch(page)",
                                                zoneId: pending.request.zoneId,
                                                outcome: outcome,
                                                shell: shell,
                                                resources: resources))
        }
        pending.completion(result)
    }

    private func failAll(_ error: SurfsideAdsError, outcome: String) {
        let all = Array(inFlight.values) + queued
        inFlight.removeAll()
        queued.removeAll()
        all.forEach { finish($0, .failure(error), outcome: outcome) }
    }

    // MARK: Page lifecycle

    private func load(userId: String?, reason: String) {
        note("loading (\(reason)), identity \(userId == nil ? "anonymous" : "set"), \(queued.count) queued")
        loadStarted = Date()
        state = .loading
        pageUserId = .some(userId)
        lastUserId = .some(userId)
        CarouselBridge.compileImageSuppression { [weak self] ruleList in
            guard let self = self, self.state == .loading else { return }
            let webView = self.webView ?? self.makeWebView(ruleList: ruleList)
            guard let webView = webView else {
                self.state = .cold
                self.pageUserId = nil
                self.failAll(.loadFailed("no window to host the ad page"), outcome: "failed(no window)")
                return
            }
            self.seedIdentity(userId, on: webView) { [weak self] in
                guard let self = self, self.state == .loading else { return }
                webView.loadHTMLString(PageHTML.page(rjsURL: self.rjsURL),
                                       baseURL: DebugConsole.pageURL(baseURL: self.baseURL,
                                                                    debug: self.isInspectable))
            }
        }
    }

    private func makeWebView(ruleList: WKContentRuleList?) -> WKWebView? {
        guard let host = Self.hostWindow() else { return nil }
        let controller = WKUserContentController()
        controller.add(WeakPageMessageHandler(self), name: Self.channelName)
        // Same suppression as the one-shot bridge: an offscreen render is not a
        // viewable impression, so image pixels stay blocked and the host fires them
        // on real display via recordImpression.
        if let ruleList = ruleList { controller.add(ruleList) }
        DebugConsole.install(on: controller, label: "page", debug: isInspectable)

        let config = WKWebViewConfiguration()
        config.userContentController = controller
        // One isolated jar for the page's lifetime: never the app's shared cookies,
        // but r.js, config and geo stay in its memory cache across fetches.
        config.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: CGRect(x: -4000, y: 0, width: 320, height: 320),
                                configuration: config)
        webView.navigationDelegate = self
        if #available(iOS 16.4, macOS 13.3, *) { webView.isInspectable = isInspectable }
        #if canImport(UIKit)
        // alpha 0, not isHidden: a hidden view can have its rendering suspended.
        webView.alpha = 0
        webView.isUserInteractionEnabled = false
        (host as? UIWindow)?.addSubview(webView)
        #else
        _ = host
        #endif
        self.webView = webView
        return webView
    }

    /// Replace every `surfid.` cookie with ours (or with none, for an anonymous
    /// page), so a cookie left by an earlier identity or written by the web identity
    /// tag can't be the one the web SDK reads.
    private func seedIdentity(_ userId: String?, on webView: WKWebView, then load: @escaping () -> Void) {
        var loaded = false
        let loadOnce = {
            guard !loaded else { return }
            loaded = true
            load()
        }
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let cookie = userId.flatMap { $0.isEmpty ? nil : $0 }
            .flatMap { CarouselBridge.surfidCookie(userId: $0, baseURL: baseURL) }
        store.getAllCookies { cookies in
            let stale = cookies.filter { $0.name.hasPrefix("surfid.") }
            let group = DispatchGroup()
            stale.forEach { group.enter(); store.delete($0) { group.leave() } }
            group.notify(queue: .main) {
                guard let cookie = cookie else { loadOnce(); return }
                store.setCookie(cookie) { loadOnce() }
            }
        }
        // Never block on the cookie store (its completions can stall).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { loadOnce() }
    }

    private func teardown() {
        webView?.stopLoading()
        webView?.configuration.userContentController
            .removeScriptMessageHandler(forName: Self.channelName)
        webView?.navigationDelegate = nil
        #if canImport(UIKit)
        webView?.removeFromSuperview()
        #endif
        webView = nil
        state = .cold
        pageUserId = nil
    }

    /// Drop an idle page; the next fetch or foreground rebuilds it.
    private func releaseIfIdle(_ reason: String) {
        guard inFlight.isEmpty, queued.isEmpty, state != .cold else { return }
        note("released (\(reason))")
        teardown()
    }

    private func observeAppLifecycle() {
        #if canImport(UIKit)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.releaseIfIdle("app entered background")
        })
        observers.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.releaseIfIdle("memory warning")
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            guard let self = self, let userId = self.lastUserId else { return }
            self.warmUp(userId: userId)
        })
        #endif
    }

    static func hostWindow() -> AnyObject? {
        #if canImport(UIKit)
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        return windows.first(where: { $0.isKeyWindow }) ?? windows.first
        #else
        return nil
        #endif
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == Self.channelName,
              let json = message.body as? String,
              let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(PagePayload.self, from: data)
        else { return }   // undecodable: that fetch's native timeout resolves it

        inFlight[payload.id]?.timeline.mark("shellReported")
        let resources = payload.resources ?? []
        switch payload.status {
        case "ok":
            resolve(payload.id, .success(payload.products), outcome: "ok(\(payload.products.count))",
                    shell: payload.timings, resources: resources)
        case "empty":
            resolve(payload.id, .success([]), outcome: "empty",
                    shell: payload.timings, resources: resources)
        default:
            resolve(payload.id, .failure(SurfsideAdsError.timeout), outcome: "timeout",
                    shell: payload.timings, resources: resources)
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard state == .loading else { return }
        state = .ready
        note("ready in \(Int(Date().timeIntervalSince(loadStarted) * 1000)) ms")
        loadedAt = Date()
        served = 0
        drain()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        pageFailed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        pageFailed(error)
    }

    private func pageFailed(_ error: Error) {
        teardown()
        failAll(.loadFailed(error.localizedDescription), outcome: "failed(page load)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // In-flight fetches get one more try on a fresh page; a second death fails them.
        let interrupted = Array(inFlight.values)
        note("web content process ended, \(interrupted.count) in flight")
        inFlight.removeAll()
        teardown()
        for pending in interrupted {
            if pending.retried {
                finish(pending, .failure(SurfsideAdsError.timeout), outcome: "failed(process died twice)")
            } else {
                pending.retried = true
                queued.insert(pending, at: 0)
            }
        }
        if let next = queued.first { load(userId: next.request.userId, reason: "process ended") }
    }

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
}

/// The content controller strongly holds its handlers; going through a weak proxy
/// keeps a long-lived page from retaining itself.
@available(iOS 14.0, *)
private final class WeakPageMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: CarouselPage?
    init(_ target: CarouselPage) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
