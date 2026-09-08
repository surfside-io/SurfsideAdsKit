# Changelog

All notable changes to SurfsideAdsKit. This project follows
[Semantic Versioning](https://semver.org/). Release tags are **bare semver, no `v` prefix**
(`1.0.0`, not `v1.0.0`).

---

## 1.0.0 (unreleased)

First tagged release. Everything below shipped to `main` through PRs #1, #3, #5, and #6
and is released together as 1.0.0.

### Product fetch

- **`SurfsideAds.fetchProducts`**: fetches the sponsored products Surfside serves for a
  zone by running the real ads SDK (`r.js`) in a hidden, one-shot `WKWebView`, and returns
  typed `SurfsideProduct` values for native rendering. Async/await and completion-handler
  variants; no-fill returns an empty array rather than throwing. (#1)
- **Deterministic count**: the placement is sized so the SDK mounts exactly
  `min(maxItems, availableInventory)` products in one pass.
- **Off-screen hosting by default**: the fetch WebView is briefly hosted off-screen in the
  app's window because WebKit throttles un-windowed web content; a `headless` opt-out
  exists for hosts where window attachment is impossible. Also distinguishes genuine
  no-fill from `.timeout` correctly. (#1)

### Measurement

- **Suppress-then-report impressions** (#3): the hidden fetch suppresses the SDK's
  auto-fired win/impression pixels (an off-screen render is not a viewable impression) and
  returns each product's tracker URLs instead. `recordImpression(_:)` fires the win +
  impression pixels when the host displays the product; `recordClick(_:)` fires the click
  pixel on tap. Win trackers are filtered to pixel-type (`<img>`) trackers, matching the
  impression list, so script trackers that fire at fetch never double-count.
- **Viewable trackers** are captured on each product for a future threshold-gated
  `recordViewable`; they are not fired yet.

### Banners

- **`SurfsideBannerView` (UIKit) and `SurfsideBanner` (SwiftUI)** (#3): a visible,
  persistent banner that loads the web ads SDK on screen, measures its rendered creative,
  collapses to zero height on no-fill, and opens tapped clickthroughs in an in-app
  `SFSafariViewController`. Load outcomes surface through `SurfsideBannerViewDelegate`
  (all methods defaulted) or SwiftUI closures.

### Identity

- **Tracked device id on ad requests** (JJRC-259, #6): the resolved first-party device id
  is seeded as the `surfid.` cookie the web ad core already reads, so ad requests key off
  the same identity as tracked events. Device-level and anonymous, not a person-level uid2.
- **Auto-acquire from the tracker** (JJRC-456, #5): when surfside-ios-tracker (2.1.0+) is
  linked into the host app, AdsKit reads its `domainUserId` at fetch time over the
  Objective-C runtime, keeping AdsKit zero-dependency. Resolution order: explicit
  `Configuration.userId` > tracker auto-acquire > anonymous.
