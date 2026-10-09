import AppKit
import XCTest
import SayoCore
@testable import SayoUI

final class ProviderIconAssetsTests: XCTestCase {
    func testBundledProviderArtworkDecodesAsNonTemplateVectors() throws {
        for provider in ProviderKind.allCases where ProviderIconAssets.resourceName(for: provider) != nil {
            let image = try XCTUnwrap(ProviderIconAssets.image(for: provider), provider.rawValue)
            XCTAssertFalse(image.isTemplate, provider.rawValue)
            XCTAssertEqual(image.size, NSSize(width: 24, height: 24), provider.rawValue)
            XCTAssertTrue(image.representations.contains {
                String(describing: type(of: $0)).contains("SVG")
            }, "Expected native SVG artwork for \(provider.rawValue)")
        }
    }

    func testGenericServicesKeepSystemIconFallback() {
        for provider in [ProviderKind.localModel, .custom, .magpie] {
            XCTAssertNil(ProviderIconAssets.image(for: provider))
        }
    }
}
