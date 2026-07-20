// swift-tools-version:5.7
import PackageDescription

// SurfsideAdsKit — a lightweight iOS package that fetches Surfside sponsored
// PRODUCT DATA (not a rendered ad UI) and hands typed products to a native app.
// It runs the Surfside ads JS SDK (`r.js`) inside a hidden, one-shot WKWebView
// purely as a data + tracking handshake layer; the integrator renders natively.
//
// No third-party dependencies on purpose — everything is Foundation + WebKit.
let package = Package(
    name: "SurfsideAdsKit",
    platforms: [
        // iOS 14 baseline: WKWebView + async/await are all available here, and it
        // reaches the widest set of integrators (decision with James 2026-07-20).
        .iOS(.v14),
        // macOS floor is here ONLY so `swift build` / `swift test` run on the Mac
        // host (async continuations need macOS 10.15+, and the decode tests run on
        // the host). The product is iOS-facing; nothing targets macOS at runtime.
        .macOS(.v10_15),
    ],
    products: [
        .library(name: "SurfsideAdsKit", targets: ["SurfsideAdsKit"]),
    ],
    targets: [
        .target(
            name: "SurfsideAdsKit",
            path: "Sources/SurfsideAdsKit"
        ),
        .testTarget(
            name: "SurfsideAdsKitTests",
            dependencies: ["SurfsideAdsKit"],
            path: "Tests/SurfsideAdsKitTests"
        ),
    ]
)
