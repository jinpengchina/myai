import SwiftUI
import XCTest
@testable import Poki

/// Launch, migration, and the choice to return to text chat.
@MainActor
final class FirstRunDecisionTests: XCTestCase {
    private var folder: URL!
    private var defaults: UserDefaults!
    private let suite = "FirstRunDecisionTests"

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("FirstRunDecisionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private func launch() { FirstRun.decide(defaults: defaults, sessionsFolder: folder) }
    private var record: String? { defaults.string(forKey: FirstRun.key) }

    func testPairingRemainsOpenUntilItsOwnNavigationRouteIsRemoved() {
        var path = NavigationPath([DetailsRoute.connection])
        XCTAssertFalse(path.containsPairingStep)
        path.append(SetupStep.pairing)
        path.append(SetupStep.loopback)
        XCTAssertTrue(path.containsPairingStep)
        path.removeLast()
        XCTAssertTrue(path.containsPairingStep)
        path.removeLast()
        XCTAssertFalse(path.containsPairingStep)
    }

    func testFreshInstallGetsTheFirstRun() {
        launch()
        XCTAssertEqual(record, "due")
    }

    func testAnUpdateFromAVersionInUseSkipsIt() throws {
        try Data("{}".utf8).write(to: folder.appendingPathComponent("old-1.json"))
        defaults.set(Data([1]), forKey: "setup")
        launch()
        XCTAssertEqual(record, "done")
    }

    func testLeavingHalfwayShowsItAgainNextLaunch() throws {
        launch()
        // What the first run's own steps saved before the app was closed does not count as an earlier version.
        defaults.set(Data([1]), forKey: "setup")
        try Data("{}".utf8).write(to: folder.appendingPathComponent("new-1.json"))
        launch()
        XCTAssertEqual(record, "due")
        FirstRun.finish(defaults: defaults)
        launch()
        XCTAssertEqual(record, "done")
    }

    func testIncompleteUpgradeResumesUntilTheOwnerChoosesTextChat() {
        defaults.set(FirstRun.Record.done.rawValue, forKey: FirstRun.key)
        XCTAssertTrue(FirstRun.resumeIfNeeded(needsSetup: true, defaults: defaults))
        XCTAssertEqual(record, "due")
        XCTAssertTrue(FirstRun.resumeIfNeeded(needsSetup: true, defaults: defaults))
        FirstRun.finish(defaults: defaults)
        XCTAssertFalse(FirstRun.resumeIfNeeded(needsSetup: true, defaults: defaults))
        XCTAssertEqual(record, "done")
    }

    func testWorkingUpgradeGoesStraightToChatAcrossRelaunches() {
        defaults.set(FirstRun.Record.done.rawValue, forKey: FirstRun.key)
        XCTAssertFalse(FirstRun.resumeIfNeeded(needsSetup: false, defaults: defaults))
        XCTAssertFalse(FirstRun.resumeIfNeeded(needsSetup: true, defaults: defaults),
                       "A later transient connection loss must not repeat the first-run migration")
        XCTAssertEqual(record, "done")
    }
}
