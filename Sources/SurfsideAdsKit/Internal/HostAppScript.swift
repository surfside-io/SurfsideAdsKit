import Foundation
@preconcurrency import WebKit

/// Tells the app build of r.js which app it runs in. It reads `window.surfsideApp.bundle`
/// and sends it as `app.bundle`, `app.domain` and `app.name` in an app-only bid request.
enum HostAppScript {

    static func source(bundleId: String?) -> String? {
        guard let bundleId = bundleId, !bundleId.isEmpty,
              let json = try? JSONSerialization.data(withJSONObject: ["bundle": bundleId]),
              let object = String(data: json, encoding: .utf8) else {
            return nil
        }
        return "window.surfsideApp = \(object);"
    }

    static func install(on controller: WKUserContentController,
                        bundleId: String? = Bundle.main.bundleIdentifier) {
        guard let source = source(bundleId: bundleId) else { return }
        controller.addUserScript(WKUserScript(source: source,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true))
    }
}
