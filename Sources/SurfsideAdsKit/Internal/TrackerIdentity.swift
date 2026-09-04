import Foundation

/// Supplies the tracked device identity (`domainUserId`) an ad request keys off,
/// brokered from the Surfside iOS tracker when it is linked in the host app.
///
/// Isolated behind a protocol so the resolution rule (explicit override vs
/// auto-acquired vs anonymous) is host-testable against a stub, while the only
/// untestable piece, the Obj-C runtime reach into the tracker, stays in the
/// default ``TrackerIdentityProvider``.
protocol IdentityProvider {
    /// The tracker's resolved anonymous device id, or nil when the tracker is not
    /// linked / holds no id yet. Never throws or crashes; a miss is nil.
    func domainUserId() -> String?
}

/// Resolves the id an ad request should carry: an explicit host override wins,
/// else the tracker's auto-acquired id, else nil (anonymous). Standalone (not
/// carousel-specific) so any Surfside view resolves identity the same way.
enum ResolvedIdentity {

    /// Resolution order: explicit ``SurfsideAds/Configuration/userId`` (if the
    /// host set a non-empty one) > auto-acquired `domainUserId` > nil. An empty
    /// explicit id counts as unset and falls through to auto.
    ///
    /// - Parameters:
    ///   - explicit: the documented host override, `Configuration.userId`.
    ///   - provider: the auto source (tracker reflection by default).
    static func resolve(explicit: String?, provider: IdentityProvider) -> String? {
        if let explicit = explicit, !explicit.isEmpty { return explicit }
        if let auto = provider.domainUserId(), !auto.isEmpty { return auto }
        return nil
    }
}

/// Default ``IdentityProvider``: reads `domainUserId` from the Surfside iOS
/// tracker (`SurfsideTracker`) over the Obj-C runtime, so AdsKit stays
/// zero-dependency (Foundation + WebKit only) and behaves whether or not the
/// tracker is linked into the app.
///
/// The tracker exposes its identity broker as `@objc(SPSurfsideEvent)` with
/// `getResolvedIdentity(trackerNamespace:)`. That bridges to the single Obj-C
/// selector `getResolvedIdentityWithTrackerNamespace:` (a Swift default argument
/// does not emit a separate no-arg selector), so we instantiate `SPSurfsideEvent`
/// and invoke that selector with a nil namespace: the tracker then reads its
/// first registered namespace. `domainUserId` is pulled from the returned
/// `[String: String]`. Any miss (class absent because the tracker is not linked,
/// selector gone, unexpected shape) returns nil cleanly, never a crash.
struct TrackerIdentityProvider: IdentityProvider {

    func domainUserId() -> String? {
        // Class absent => tracker not linked into this app; anonymous fetch.
        guard let trackerClass = NSClassFromString("SPSurfsideEvent") as? NSObject.Type else {
            return nil
        }
        let instance = trackerClass.init()

        let selector = NSSelectorFromString("getResolvedIdentityWithTrackerNamespace:")
        guard instance.responds(to: selector) else { return nil }

        // One object arg (the namespace, nil => tracker uses its first), object
        // return (the identity map). The selector is not copy/new/alloc/init, so
        // the return is unowned; read it synchronously via takeUnretainedValue.
        guard let identity = instance.perform(selector, with: nil)?
                .takeUnretainedValue() as? [String: String] else {
            return nil
        }

        guard let id = identity["domainUserId"], !id.isEmpty else { return nil }
        return id
    }
}
