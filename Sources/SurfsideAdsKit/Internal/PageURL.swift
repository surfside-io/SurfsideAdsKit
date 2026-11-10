import Foundation

/// The ad SDK reads its switches (`surf_debug`, `surf_override_filtering`) from the page URL.
enum PageURL {

    /// `baseURL` with `name=true` as the only value of `name`, and a `/` path so the query
    /// attaches to a page. The rest of the query keeps its original encoding.
    static func addingFlag(_ name: String, to baseURL: String) -> URLComponents? {
        guard var components = URLComponents(string: baseURL) else { return nil }
        let kept = (components.percentEncodedQuery ?? "")
            .split(separator: "&")
            .filter { $0.split(separator: "=", maxSplits: 1).first.map(String.init) != name }
            .map(String.init)
        components.percentEncodedQuery = (kept + ["\(name)=true"]).joined(separator: "&")
        if components.path.isEmpty { components.path = "/" }
        return components
    }
}
