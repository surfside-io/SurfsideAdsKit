import Foundation
@preconcurrency import WebKit
#if canImport(UIKit)
import UIKit
#endif

private struct PagePayload: Decodable {
    let id: String
    let status: String            // "ok" | "empty" | "sdkMissing"
    let products: [SurfsideProduct]
    let timings: ShellTimings?
    let resources: [ShellResource]?
}

/// The fetch id alone, for a payload whose products don't decode.
private struct PagePayloadID: Decodable {
    let id: String
}

/// One hidden, hosted WKWebView kept alive for a `SurfsideAds` instance. r.js loads
/// once; every fetch inserts its own `<surf-carousel>` (see ``PageHTML``), so WebKit
/// process start, page navigation, r.js and the web SDK's init are paid once instead
/// of per fetch. Concurrent fetches are just several elements on the page.
///
/// Constraints this class exists to hold:
/// - **Identity is page-wide.** The web SDK reads the `surfid.` cookie at init, so a
///   fetch for a different user gets a new page in a new cookie jar first (decided
///   2026-09-18; the new jar keeps the previous user's cookie out of reach).
/// - **The page is recycled** after `recycleAfterFetches` fetches or
///   `recycleAfterSeconds`, because the web carousel has no disconnect cleanup and
///   config/geo are frozen at init.
/// - **The page can die under us**: WebKit can kill the content process, r.js can
///   fail to load, the host window can go away. In-flight fetches are retried once
///   on a fresh page.
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
    /// Bumped by every load and teardown, so callbacks from a superseded load drop out.
    private var generation = 0
    /// Identity the current page was loaded with. Double optional: `nil` = no page yet.
    private var pageUserId: String??
    /// Identity of the last page, kept across a background release so foreground
    /// can rebuild the same page. `nil` until a page has existed.
    private var lastUserId: String??
    /// The page loaded before its identity cookie was in the jar.
    private var reloadWhenIdle = false
    /// A release asked for while fetches were running.
    private var pendingRelease: String?
    private var backgrounded = false
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
        // The last reference can be dropped on any thread, with fetches still waiting.
        let webView = self.webView
        let stranded = Array(inFlight.values) + queued
        let cleanUp = {
            Self.dismantle(webView)
            stranded.forEach { $0.completion(.failure(SurfsideAdsError.loadFailed("SurfsideAds was released"))) }
        }
        if Thread.isMainThread { cleanUp() } else { DispatchQueue.main.async(execute: cleanUp) }
    }

    /// Page state changes, in the same debug log as the fetch timelines.
    private func note(_ event: String) {
        if isInspectable { NSLog("%@", "SurfsideAdsKit page: " + event) }
    }

    /// A page needs a window to live in (an un-hosted WebView's JS is throttled).
    var canServe: Bool { Self.hostWindow() != nil }

    /// False once the window the page was put in has gone away.
    private var isHosted: Bool {
        #if canImport(UIKit)
        return webView.map { $0.window != nil } ?? true
        #else
        return true
        #endif
    }

    /// `""` and `nil` both mean anonymous.
    private static func identity(_ userId: String?) -> String? {
        userId?.isEmpty == false ? userId : nil
    }

    // MARK: Entry points

    /// Load the page ahead of the first fetch. No-op once a page exists.
    func warmUp(userId: String?) {
        if state != .cold, !isHosted, inFlight.isEmpty, queued.isEmpty { teardown() }
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
        if state == .cold {
            load(userId: request.userId, reason: "first fetch")
        } else if !isHosted {
            rebuild(reason: "host window went away", failure: .loadFailed("the ad page lost its window twice"))
        } else {
            drain()
        }
    }

    // MARK: Scheduling

    private var needsRecycle: Bool {
        served >= Self.recycleAfterFetches
            || Date().timeIntervalSince(loadedAt) >= Self.recycleAfterSeconds
    }

    /// Inject what the current page can serve. A fetch that needs a different
    /// identity (or a fresh page) waits for in-flight ones, then reloads.
    private func drain() {
        guard state == .ready else { return }
        if reloadWhenIdle, inFlight.isEmpty, queued.isEmpty, case .some(let userId) = pageUserId {
            load(userId: userId, reason: "identity cookie landed late", seed: false)
            return
        }
        while let next = queued.first {
            let identityChanged = .some(Self.identity(next.request.userId)) != pageUserId
            if identityChanged || needsRecycle || reloadWhenIdle {
                guard inFlight.isEmpty else { return }
                if identityChanged {
                    teardown()
                    load(userId: next.request.userId, reason: "identity changed")
                } else if reloadWhenIdle {
                    load(userId: next.request.userId, reason: "identity cookie landed late", seed: false)
                } else {
                    load(userId: next.request.userId, reason: "recycle after \(served) fetches")
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
        // A fetch issued in the background rebuilds the page; don't leave it behind.
        if let reason = pendingRelease ?? (backgrounded ? "app is in the background" : nil) {
            releaseIfIdle(reason)
        }
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

    /// `seed: false` reloads on top of a jar that already holds this identity's cookie.
    private func load(userId: String?, reason: String, seed: Bool = true) {
        let userId = Self.identity(userId)
        note("loading (\(reason)), identity \(userId == nil ? "anonymous" : "set"), \(queued.count) queued")
        loadStarted = Date()
        state = .loading
        generation += 1
        let generation = self.generation
        reloadWhenIdle = false
        pageUserId = .some(userId)
        lastUserId = .some(userId)
        CarouselBridge.compileImageSuppression { [weak self] ruleList in
            guard let self = self, generation == self.generation else { return }
            let webView = self.webView ?? self.makeWebView(ruleList: ruleList)
            guard let webView = webView else {
                self.state = .cold
                self.pageUserId = nil
                self.failAll(.loadFailed("no window to host the ad page"), outcome: "failed(no window)")
                return
            }
            let loadPage = { [weak self] in
                guard let self = self, generation == self.generation else { return }
                webView.loadHTMLString(PageHTML.page(rjsURL: self.rjsURL),
                                       baseURL: DebugConsole.pageURL(baseURL: self.baseURL,
                                                                    debug: self.isInspectable))
            }
            guard seed else { loadPage(); return }
            self.seedIdentity(userId, on: webView) { [weak self] late in
                guard let self = self, generation == self.generation else { return }
                guard late else { loadPage(); return }
                // The web SDK read the jar before the cookie was in it.
                self.reloadWhenIdle = true
                self.drain()
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
    /// page), so a cookie written by the web identity tag can't be the one the web
    /// SDK reads. `then(false)` says load now; `then(true)` follows if the jar only
    /// changed after the 0.3s fallback had already said so.
    private func seedIdentity(_ userId: String?, on webView: WKWebView, then: @escaping (_ late: Bool) -> Void) {
        var told = false
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let cookie = userId.flatMap { CarouselBridge.surfidCookie(userId: $0, baseURL: baseURL) }
        store.getAllCookies { cookies in
            let stale = cookies.filter { $0.name.hasPrefix("surfid.") }
            let seeded = {
                let late = told
                told = true
                if !late { then(false) } else if cookie != nil || !stale.isEmpty { then(true) }
            }
            let group = DispatchGroup()
            stale.forEach { group.enter(); store.delete($0) { group.leave() } }
            group.notify(queue: .main) {
                guard let cookie = cookie else { seeded(); return }
                store.setCookie(cookie) { seeded() }
            }
        }
        // Never block on the cookie store (its completions can stall).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard !told else { return }
            told = true
            then(false)
        }
    }

    private func teardown() {
        Self.dismantle(webView)
        webView = nil
        state = .cold
        generation += 1
        pageUserId = nil
        reloadWhenIdle = false
        pendingRelease = nil
    }

    private static func dismantle(_ webView: WKWebView?) {
        webView?.stopLoading()
        webView?.configuration.userContentController
            .removeScriptMessageHandler(forName: channelName)
        webView?.navigationDelegate = nil
        #if canImport(UIKit)
        webView?.removeFromSuperview()
        #endif
    }

    /// In-flight fetches get one more try on a fresh page; a second loss fails them.
    private func rebuild(reason: String, failure: SurfsideAdsError) {
        let interrupted = Array(inFlight.values)
        note("\(reason), \(interrupted.count) in flight")
        inFlight.removeAll()
        teardown()
        for pending in interrupted {
            if pending.retried {
                finish(pending, .failure(failure), outcome: "failed(\(reason), twice)")
            } else {
                pending.retried = true
                queued.insert(pending, at: 0)
            }
        }
        if let next = queued.first { load(userId: next.request.userId, reason: reason) }
    }

    /// Drop the page once nothing is using it; the next fetch or foreground rebuilds it.
    private func releaseIfIdle(_ reason: String) {
        guard state != .cold else { return }
        guard inFlight.isEmpty, queued.isEmpty else {
            pendingRelease = reason
            return
        }
        note("released (\(reason))")
        teardown()
    }

    private func observeAppLifecycle() {
        #if canImport(UIKit)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.backgrounded = true
            self?.releaseIfIdle("app entered background")
        })
        observers.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.releaseIfIdle("memory warning")
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.backgrounded = false
            self.pendingRelease = nil
            guard let userId = self.lastUserId else { return }
            self.warmUp(userId: userId)
        })
        #endif
    }

    static func hostWindow() -> AnyObject? {
        #if canImport(UIKit)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.filter { $0.activationState == .foregroundActive }
        let windows = (active.isEmpty ? scenes : active).flatMap { $0.windows }
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
              let data = json.data(using: .utf8)
        else { return }
        guard let payload = try? JSONDecoder().decode(PagePayload.self, from: data) else {
            // The page has already removed the element, so nothing else will arrive.
            if let id = (try? JSONDecoder().decode(PagePayloadID.self, from: data))?.id {
                resolve(id, .failure(SurfsideAdsError.decodeFailed), outcome: "failed(decode)")
            }
            return
        }

        inFlight[payload.id]?.timeline.mark("shellReported")
        let resources = payload.resources ?? []
        switch payload.status {
        case "ok":
            resolve(payload.id, .success(payload.products), outcome: "ok(\(payload.products.count))",
                    shell: payload.timings, resources: resources)
        case "empty":
            resolve(payload.id, .success([]), outcome: "empty",
                    shell: payload.timings, resources: resources)
        case "sdkMissing":
            // r.js never ran on this page, so no fetch on it can succeed.
            guard inFlight[payload.id] != nil else { return }
            rebuild(reason: "ad SDK missing from the page", failure: .loadFailed("the ad SDK did not load"))
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
        // A navigation we replaced with a newer one, not a failed page.
        let error = error as NSError
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return }
        teardown()
        failAll(.loadFailed(error.localizedDescription), outcome: "failed(page load)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        rebuild(reason: "web content process ended", failure: .loadFailed("the web content process ended twice"))
    }

    func webView(_ webView: WKWebView,
                 didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if CarouselBridge.isSurfsideHost(challenge.protectionSpace.host),
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
