import SwiftUI
import UIKit
import UserNotifications
import XCTest
@testable import Poki

final class SetupSettingsTests: XCTestCase {
    func testSystemSetupStepsOpenSettingsRoot() {
        for step: SetupStep in [.runner, .developerMode, .pairing, .automation] {
            XCTAssertEqual(settingsURL(for: step)?.absoluteString, "App-prefs:", "\(step) must not open Poki's App permissions")
        }
    }

    func testBackgroundPermissionsStillOpenPokiSettings() {
        XCTAssertEqual(settingsURL(for: .background)?.absoluteString, UIApplication.openSettingsURLString)
    }

    func testDefaultDestinationRemainsPokiSettings() {
        XCTAssertEqual(settingsURL(for: nil)?.absoluteString, UIApplication.openSettingsURLString)
    }

    /// R1: Settings › Setup must not repeat the six entries that already live on the Settings home page.
    @MainActor
    func testSetupSettingsPageOmitsSettingsHomeDuplicateEntries() async throws {
        let model = AppModel(launcher: FakeLauncher(), pairer: FakePairing())
        let chat = ChatModel(app: model)
        let elements = try await renderElements(
            NavigationStack { SetupSettingsPage(path: .constant(NavigationPath())) }
                .environment(model)
                .environment(chat),
            waitForLabelContaining: "Guide Me"
        )
        let labels = elements.compactMap(\.accessibilityLabel)
        XCTAssertTrue(labels.contains { $0.contains("Required Steps") }, "Required Steps card must stay on Setup; saw \(labels)")
        XCTAssertTrue(labels.contains { $0.contains("Guide Me") }, "Guide Me must stay on Setup; saw \(labels)")
        for duplicate in ["Accounts", "Screen History", "Memory", "Dictation", "Notifications", "External Connections"] {
            XCTAssertFalse(
                labels.contains { $0.contains(duplicate) },
                "Settings › Setup must not duplicate Settings home entry '\(duplicate)'; saw \(labels)"
            )
        }
        // Settings home's Notifications row requests system authorization first while undetermined,
        // and opens iOS Settings once already decided.
        XCTAssertEqual(NotificationPermissionAction.forStatus(.notDetermined, openSettingsWhenAuthorized: true), .requestAuthorization)
        XCTAssertEqual(NotificationPermissionAction.forStatus(.denied, openSettingsWhenAuthorized: true), .openSystemSettings)
        XCTAssertEqual(NotificationPermissionAction.forStatus(.authorized, openSettingsWhenAuthorized: true), .openSystemSettings)
    }

    @MainActor
    func testOnlyTheBuiltInVPNIsShownInBothConnectionScreens() async throws {
        let storage = try IsolatedTestStorage(prefix: "built-in-onboarding")
        defer { XCTAssertNoThrow(try storage.tearDown()) }
        let model = AppModel(launcher: FakeLauncher(), pairer: FakePairing(),
                             localVPNAvailable: true, storage: storage.storage)
        defer { model.loopback.pause() }
        for guided in [true, false] {
            let elements = try await renderElements(
                NavigationStack { SetupStepPage(step: .loopback, hero: guided).settingsPage() }
                    .environment(model),
                waitForLabelContaining: "Enable Local Connection"
            )
            let labels = elements.compactMap(\.accessibilityLabel)
            XCTAssertTrue(labels.contains("Enable Local Connection"), "Rendered labels: \(labels)")
            #if targetEnvironment(simulator)
            XCTAssertEqual(model.setup.loopback, .builtIn, "Opening the step must start the built-in VPN")
            if case .failed = model.tunnel.state {} else {
                XCTFail("The simulator should report the attempted NE connection, got \(model.tunnel.state)")
            }
            #endif
            for oldEntry in ["Use the Current VPN", "LocalDevVPN", "Shadowrocket", "Pick One App", "Loopback Shortcut"] {
                XCTAssertFalse(labels.contains { $0.contains(oldEntry) }, "Unexpected VPN entry: \(oldEntry)")
            }
        }
    }

    @MainActor
    func testGuideGoesStraightFromTheBuiltInConnectionToPairing() {
        XCTAssertEqual(StartRoute.item(.step(.loopback)).next, .item(.step(.pairing)))
    }

    @MainActor
    func testMissingTunnelShowsAnInstallationIssue() async throws {
        let storage = try IsolatedTestStorage(prefix: "missing-tunnel")
        defer { XCTAssertNoThrow(try storage.tearDown()) }
        let model = AppModel(launcher: FakeLauncher(), pairer: FakePairing(),
                             localVPNAvailable: false, storage: storage.storage)
        defer { model.loopback.pause() }
        let elements = try await renderElements(
            NavigationStack { SetupStepPage(step: .loopback, hero: false).settingsPage() }
                .environment(model),
            waitForLabelContaining: "The built-in VPN is unavailable in this installation."
        )
        let labels = elements.compactMap(\.accessibilityLabel)
        XCTAssertFalse(labels.contains("Use the Current VPN"))
        XCTAssertFalse(labels.contains("Enable Local Connection"))
        XCTAssertFalse(labels.contains { $0.contains("LocalDevVPN") })
    }

    /// R3: Guided manual steps keep only the bottom primary Open Settings button; settings subpages keep the in-card row.
    @MainActor
    func testGuidedManualStepsHideDuplicateOpenSettingsRow() async throws {
        let model = AppModel(launcher: FakeLauncher(), pairer: FakePairing())
        for step: SetupStep in [.developerMode, .automation] {
            let guided = try await renderElements(
                NavigationStack { SetupStepPage(step: step, hero: true).settingsPage() }
                    .environment(model),
                waitForLabelContaining: step == .developerMode ? "Developer Mode Is On" : "UI Automation Is On"
            )
            let guidedOpenButtons = Self.openSettingsButtons(in: guided)
            XCTAssertTrue(guidedOpenButtons.isEmpty, "Guided \(step) must hide the in-card Open Settings row; found \(guidedOpenButtons.count)")

            let subpage = try await renderElements(
                NavigationStack { SetupStepPage(step: step, hero: false).settingsPage() }
                    .environment(model),
                waitForLabelContaining: step == .developerMode ? "Developer Mode Is On" : "UI Automation Is On"
            )
            let subpageOpenButtons = Self.openSettingsButtons(in: subpage)
            XCTAssertEqual(subpageOpenButtons.count, 1, "Settings subpage \(step) must keep its in-card Open Settings row")
        }
    }

    // MARK: - Helpers

    @MainActor
    private static func openSettingsButtons(in elements: [NSObject]) -> [NSObject] {
        elements.filter {
            $0.accessibilityLabel == "Open Settings" && $0.accessibilityTraits.contains(.button)
        }
    }

    @MainActor
    private func renderElements<V: View>(
        _ view: V,
        waitForLabelContaining: String
    ) async throws -> [NSObject] {
        let accessibility = try XCTUnwrap(dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW))
        defer { dlclose(accessibility) }
        let isEnabled = unsafeBitCast(try XCTUnwrap(dlsym(accessibility, "_AXSAutomationEnabled")), to: (@convention(c) () -> Int32).self)
        let setEnabled = unsafeBitCast(try XCTUnwrap(dlsym(accessibility, "_AXSSetAutomationEnabled")), to: (@convention(c) (Int32) -> Void).self)
        let previous = isEnabled()
        setEnabled(1)
        defer { setEnabled(previous) }

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        // Tall frame ensures every List section is materialized in the viewport.
        window.frame = CGRect(x: 0, y: 0, width: scene.screen.bounds.width, height: 2400)
        window.rootViewController = UIHostingController(rootView: view.environment(\.accessibilityEnabled, true))
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer { window.isHidden = true }
        UIAccessibility.post(notification: .screenChanged, argument: window.rootViewController?.view)

        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            Self.all(in: window).contains { $0.accessibilityLabel?.contains(waitForLabelContaining) == true }
        }, object: nil)
        await fulfillment(of: [ready], timeout: 5)
        return Self.all(in: window)
    }

    @MainActor
    private static func all(in root: NSObject) -> [NSObject] {
        var pending = [root], found: [NSObject] = []
        var visited = Set<ObjectIdentifier>()
        while let item = pending.popLast() {
            guard visited.insert(ObjectIdentifier(item)).inserted else { continue }
            found.append(item)
            if let view = item as? UIView { pending.append(contentsOf: view.subviews) }
            if let children = item.accessibilityElements { pending.append(contentsOf: children.compactMap { $0 as? NSObject }) }
            let count = item.accessibilityElementCount()
            if count > 0 && count < 1000 {
                for index in 0..<count {
                    if let child = item.accessibilityElement(at: index) as? NSObject { pending.append(child) }
                }
            }
        }
        return found
    }
}
