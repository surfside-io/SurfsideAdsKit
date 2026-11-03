import Foundation

/// The ad SDK reads its switches (`surf_debug`, `surf_override_filtering`) from the page URL.
enum PageURL {

    /// `baseURL` with `name=true` added once, and a `/` path so the query attaches to a page.
    static func addingFlag(_ name: String, to baseURL: String) -> URLComponents? {
        guard var components = URLComponents(string: baseURL) else { return nil }
        var items = components.queryItems ?? []
        if !items.contains(where: { $0.name == name }) {
            items.append(URLQueryItem(name: name, value: "true"))
        }
        components.queryItems = items
        if components.path.isEmpty { components.path = "/" }
        return components
    }
}
