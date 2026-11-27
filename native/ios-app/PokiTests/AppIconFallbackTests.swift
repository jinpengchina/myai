import UIKit
import XCTest
@testable import Poki

/// Installed and alternate-edition icons remain available without a bundled icon collection.
@MainActor
final class AppIconFallbackTests: XCTestCase {
    private func picture(_ color: UIColor?) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: 60, height: 60), format: format).image { context in
            if let color { color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 60, height: 60)) }
        }
    }

    func testAnEmptyInstalledIconCanUseThePlaceholder() {
        let store = AppIconStore(installed: { _, _ in self.picture(nil) })
        XCTAssertNil(store.icon("org.ailove.missing-fixture"))
        XCTAssertNil(AppIconStore.carried("taobao"))
    }

    func testAnInstalledIconStillComesFirst() {
        let red = picture(.red)
        XCTAssertTrue(AppIconStore(installed: { id, _ in id == "com.taobao.taobao4iphone" ? red : nil }).icon("淘宝") === red)
    }

    func testAnotherEditionOfAnAppCountsAsInstalled() {
        let red = picture(.red)
        let store = AppIconStore(installed: { id, _ in id == "com.bilibili.inter" ? red : nil })
        XCTAssertTrue(store.icon("哔哩哔哩") === red)
        XCTAssertTrue(store.icon("bilibili") === red)
    }
}
