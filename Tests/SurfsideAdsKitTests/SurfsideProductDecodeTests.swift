import XCTest
@testable import SurfsideAdsKit

/// These tests cover the pure, host-runnable half of the package: decoding the
/// bridge payload shape into `SurfsideProduct`. The WebView loading path is
/// integration-only (needs a live device + real zone) and is documented in the
/// README's manual test section rather than unit-tested here.
final class SurfsideProductDecodeTests: XCTestCase {

    private func decode(_ json: String) throws -> SurfsideProduct {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(SurfsideProduct.self, from: data)
    }

    func testDecodesFullProduct() throws {
        let product = try decode("""
        {
          "id": "abc123",
          "name": "Blue Dream 3.5g",
          "price": "$40.00",
          "salePrice": "$35.00",
          "image": "https://cdn.example.com/x.jpg",
          "brandName": "Green Goddess",
          "productType": "Flower",
          "thc": "22%",
          "strain": "Hybrid",
          "cbd": "0.1%",
          "clickthrough": "https://click.surfside.io/abc123",
          "sponsored": true,
          "ext": {"size": "3.5g", "sku": "GG-BD-35"}
        }
        """)

        XCTAssertEqual(product.id, "abc123")
        XCTAssertEqual(product.name, "Blue Dream 3.5g")
        XCTAssertEqual(product.salePrice, "$35.00")
        XCTAssertEqual(product.brandName, "Green Goddess")
        XCTAssertTrue(product.sponsored)
        // The `clickthrough` JSON key maps to the public `clickthroughURL`.
        XCTAssertEqual(product.clickthroughURL, "https://click.surfside.io/abc123")
        XCTAssertEqual(product.clickURL?.host, "click.surfside.io")
        XCTAssertEqual(product.ext?["size"], "3.5g")
        XCTAssertEqual(product.ext?["sku"], "GG-BD-35")
    }

    func testDecodesMinimalProductWithNullFieldsAbsent() throws {
        // The JS bridge already turns "null"/"" into JSON null before it reaches
        // Swift, so a minimal payload should decode with nils, not crash.
        let product = try decode("""
        {
          "id": "42",
          "name": null,
          "price": null,
          "salePrice": null,
          "image": null,
          "brandName": null,
          "productType": null,
          "thc": null,
          "strain": null,
          "cbd": null,
          "clickthrough": null,
          "sponsored": false,
          "ext": null
        }
        """)

        XCTAssertEqual(product.id, "42")
        XCTAssertNil(product.name)
        XCTAssertNil(product.clickthroughURL)
        XCTAssertNil(product.clickURL)
        XCTAssertNil(product.ext)
        XCTAssertFalse(product.sponsored)
    }

    func testDecodesArrayEnvelopeProducts() throws {
        // Shape mirrors the envelope the JS scraper posts: a products array.
        struct Envelope: Decodable { let products: [SurfsideProduct] }
        let data = Data("""
        {"status":"ok","expected":2,"count":2,"products":[
          {"id":"1","sponsored":true},
          {"id":"2","sponsored":false}
        ]}
        """.utf8)

        let env = try JSONDecoder().decode(Envelope.self, from: data)
        XCTAssertEqual(env.products.map(\.id), ["1", "2"])
        XCTAssertEqual(env.products.map(\.sponsored), [true, false])
    }

    func testMemberwiseInitDefaults() {
        let p = SurfsideProduct(id: "9")
        XCTAssertEqual(p.id, "9")
        XCTAssertNil(p.name)
        XCTAssertFalse(p.sponsored)
        XCTAssertNil(p.ext)
    }

    func testErrorDescriptions() {
        XCTAssertEqual(SurfsideAdsError.timeout,
                       SurfsideAdsError.timeout)
        XCTAssertNotNil(SurfsideAdsError.loadFailed("boom").errorDescription)
        XCTAssertNotNil(SurfsideAdsError.decodeFailed.errorDescription)
    }
}
