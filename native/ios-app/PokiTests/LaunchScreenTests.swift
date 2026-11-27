import UIKit
import XCTest
@testable import Poki

@MainActor
final class LaunchScreenTests: XCTestCase {
    func testLaunchScreenShowsTheAiloveMarkAndNameOnPhoneAndTablet() throws {
        let storyboard = UIStoryboard(name: "LaunchScreen", bundle: .main)
        let controller = try XCTUnwrap(storyboard.instantiateInitialViewController())
        let view = try XCTUnwrap(controller.view)
        let mark = try XCTUnwrap(view.viewWithTag(1) as? UIImageView)
        let name = try XCTUnwrap(view.viewWithTag(2) as? UILabel)
        XCTAssertNotNil(mark.image)
        XCTAssertEqual(name.text, "ailove")
        for size in [CGSize(width: 320, height: 568), CGSize(width: 1024, height: 768)] {
            view.frame = CGRect(origin: .zero, size: size)
            view.layoutIfNeeded()
            XCTAssertEqual(mark.frame.midX, view.bounds.midX, accuracy: 0.5)
            XCTAssertEqual(name.frame.midX, view.bounds.midX, accuracy: 0.5)
            XCTAssertGreaterThan(name.frame.midY, mark.frame.midY)
            XCTAssertTrue(view.bounds.contains(mark.frame.union(name.frame)))
        }
    }

    func testProtectedUpstreamArtIsAbsentFromTheApplicationBundle() {
        for (resource, ext) in [("PokiBear", "usdz"), ("PokiBear-ready", "png"),
                                ("PokiFace", "png"), ("LaunchBear", "png"),
                                ("ActivityBear-ready", "png"), ("BearOutfit-beanie", "png")] {
            XCTAssertNil(Bundle.main.url(forResource: resource, withExtension: ext), resource)
        }
        XCTAssertNil(UIImage(named: "ActivityBear-ready"))
        XCTAssertNil(UIImage(named: "PokiIcon"))
    }
}
