import AVFAudio
import PiSwiftAI
import PokiCore
import SwiftUI
import UIKit
import XCTest
@testable import Poki

@MainActor
final class HealthRelayLoopbackTests: XCTestCase {
    private var hostLocalization: HostLocalizationSnapshot!
    private var storage: IsolatedTestStorage!

    override func setUp() async throws {
        hostLocalization = HostLocalizationSnapshot.capture()
        storage = try IsolatedTestStorage(prefix: "health-relay-loopback")
    }

    override func tearDown() async throws {
        hostLocalization.restore()
        hostLocalization.assertUnchanged()
        if let storage {
            self.storage = nil
            try storage.tearDown()
        }
    }

    private func resetIsolatedState() throws {
        try storage.reset()
    }

    private func makeModel(
        imageMounted: @escaping () -> Bool = { false },
        localVPNAvailable: Bool? = nil,
        storage: PokiStorage? = nil
    ) -> AppModel {
        let model = AppModel(
            launcher: FakeLauncher(),
            pairer: FakePairing(),
            automation: FakeAutomation(),
            imageMounted: imageMounted,
            localVPNAvailable: localVPNAvailable,
            storage: storage ?? self.storage.storage
        )
        model.setup.runnerInstalled = true
        model.setup.developerMode = true
        model.setup.uiAutomation = true
        return model
    }

    func testLegacyVPNSelectionMigratesFromPreferencesAndKeychain() throws {
        let legacy = Data(#"{"loopback":"proxy","proxyApp":"shadowrocket","uiAutomation":true,"passcodeNoted":true}"#.utf8)
        for restoreFromKeychain in [false, true] {
            try resetIsolatedState()
            if restoreFromKeychain {
                SetupVault.storeSetup(legacy, storage: storage.storage)
            } else {
                storage.defaults.set(legacy, forKey: "setup")
            }
            let model = AppModel(launcher: FakeLauncher(), pairer: FakePairing(),
                                 localVPNAvailable: true, storage: storage.storage)
            XCTAssertEqual(model.setup.loopback, .builtIn)
            XCTAssertTrue(model.setup.passcodeNoted)
            XCTAssertFalse(model.isDone(.loopback), "Migration must still go through iOS VPN consent")
            for saved in [storage.defaults.data(forKey: "setup"), SetupVault.readSetup(storage: storage.storage)] {
                let data = try XCTUnwrap(saved)
                let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                XCTAssertEqual(fields["loopback"] as? String, "builtIn")
                XCTAssertNil(fields["proxyApp"])
                XCTAssertEqual(fields["passcodeNoted"] as? Bool, true)
            }
        }
    }

    func testSetupRequiresAVerifiedBuiltInConnection() {
        let model = makeModel(localVPNAvailable: true)
        model.setup.loopback = .builtIn
        model.tunnel.simulate(.connected)
        model.loopback.simulate(.checking)
        XCTAssertTrue(SetupItem.step(.loopback).isOpen(model))
        model.loopback.simulate(.noAnswer)
        XCTAssertTrue(SetupItem.step(.loopback).isOpen(model))
        model.loopback.simulate(.working(ms: 9))
        XCTAssertFalse(SetupItem.step(.loopback).isOpen(model))
        model.tunnel.simulate(.off)
        XCTAssertFalse(model.isDone(.loopback), "Disconnecting the owned tunnel must invalidate the probe")
        model.runnerChanged(RunnerStatus(state: "running", code: "local_ddi"))
        XCTAssertFalse(model.setupStepVerified(.loopback), "A cached runner status must not replace the disconnected VPN")
    }

    #if targetEnvironment(simulator)
    func testFirstRunAutomaticallyAttemptsVPNOnceUntilTheOwnerRetries() async {
        let model = makeModel(localVPNAvailable: true)
        XCTAssertEqual(model.firstRunPhoneStep, .loopback)
        XCTAssertNil(model.firstRunVPNFailure)
        await model.connectFirstRunVPN()
        XCTAssertEqual(model.setup.loopback, .builtIn)
        guard case .failed = model.tunnel.state else { return XCTFail("The simulator must receive an actual tunnel start attempt") }
        XCTAssertNotNil(model.firstRunVPNFailure)

        // Dismissing the sheet or reopening the guide may report the tunnel as off again.
        model.tunnel.simulate(.off)
        await model.connectFirstRunVPN()
        XCTAssertEqual(model.tunnel.state, .off)
        XCTAssertNotNil(model.firstRunVPNFailure, "The owner must still be able to retry")

        let reopened = makeModel(localVPNAvailable: true)
        reopened.tunnel.simulate(.off)
        await reopened.connectFirstRunVPN()
        XCTAssertEqual(reopened.setup.loopback, .builtIn)
        XCTAssertEqual(reopened.tunnel.state, .off, "Relaunching must not repeat the consent request")
        XCTAssertNotNil(reopened.firstRunVPNFailure)
        await reopened.connectFirstRunVPN(retry: true)
        guard case .failed = reopened.tunnel.state else { return XCTFail("Retry must start the tunnel again") }
        XCTAssertEqual(reopened.firstRunPhoneStep, .loopback)
    }
    #endif

    func testQuickStartAdvancesFromBuiltInConnectionToPairingAndUsesRunnerEvidence() async throws {
        let model = AppModel(launcher: FakeLauncher(), pairer: FakePairing(), automation: FakeAutomation(),
                             localVPNAvailable: true, storage: storage.storage)
        XCTAssertEqual(model.firstRunPhoneStep, .loopback)
        model.tunnel.simulate(.connected)
        model.loopback.simulate(.noAnswer)
        XCTAssertEqual(model.firstRunPhoneStep, .loopback, "The OS tunnel alone does not prove the phone service is reachable")
        model.simulateWorkingBuiltInVPN(ms: 9)
        await model.connectFirstRunVPN()
        XCTAssertNil(model.firstRunVPNFailure)
        XCTAssertEqual(model.firstRunPhoneStep, .pairing)

        try importFixturePairing(into: model)
        model.runnerChanged(RunnerStatus(state: "launching"))
        XCTAssertEqual(model.firstRunPhoneStep, .automation)
        XCTAssertFalse(model.setup.uiAutomation, "Pairing and Developer Mode cannot confirm UI Automation")
        model.runnerChanged(RunnerStatus(state: "running"))
        XCTAssertEqual(model.firstRunPhoneStep, .automation, "Mounted developer services alone do not prove the app can operate the screen")
        try ModelKeys.saveCustom(address: "http://127.0.0.1:8765/v1", model: "fixture", typedKey: "", storage: storage.storage)
        defer { model.stopSession() }
        let preparation = Task { await model.prepareFirstRunPhone(retry: true) }
        let runnerProbe = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated { model.sessionOn && !model.runnerPaused && model.runner.state == "failed" }
        }, object: nil)
        await fulfillment(of: [runnerProbe], timeout: 6)
        // A simulator has no on-device launcher. Supply its success event only after the initial
        // probe, then wait for the injected automation session to prove the screen is usable.
        model.runnerChanged(RunnerStatus(state: "running"))
        let opened = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated { model.hasOpenInProcessSession }
        }, object: nil)
        await fulfillment(of: [opened], timeout: 6)
        await preparation.value
        XCTAssertNil(model.firstRunPhoneStep)
        XCTAssertFalse(model.setupStepsLeft)
        XCTAssertTrue(model.setupReadyForUse)

        let restored = AppModel(launcher: FakeLauncher(), pairer: FakePairing(), automation: FakeAutomation(),
                                localVPNAvailable: true, storage: storage.storage)
        restored.simulateWorkingBuiltInVPN(ms: 9)
        XCTAssertNil(restored.firstRunPhoneStep, "Reopening the guide must reuse the saved pairing and verified settings")
    }

    func testQuickStartRequiresAVoiceCapableChatGPTAccount() throws {
        let voice = VoiceModel(clearTap: { _, _, _ in .clear }, phoneTool: { _, _, _ in ("", false, nil) },
                               codex: StubSubscriptionVoice(), storage: storage.storage)
        ModelKeys.setSelectedProvider(.chatgpt, in: storage.storage)
        try ChatGPTAccount.save(.init(refresh: "fixture-refresh", access: "fixture-access",
                                      expires: Date().addingTimeInterval(3_600).timeIntervalSince1970 * 1_000,
                                      clientId: "fixture-text-client"), service: storage.keychainService)
        XCTAssertTrue(ChatGPTAccount.isSignedIn(storage: storage.storage))
        XCTAssertFalse(voice.hasChatGPTVoiceAccount)
        XCTAssertFalse(voice.canTalkLive, "Legacy text-only sign-in must still lead to voice setup")

        try storage.seedCodexCredential()
        XCTAssertTrue(voice.hasChatGPTVoiceAccount)
        XCTAssertTrue(voice.canTalkLive)
        ModelKeys.setSelectedProvider(.deepseek, in: storage.storage)
        XCTAssertTrue(voice.hasChatGPTVoiceAccount, "Selecting a different text provider must preserve the option to use the saved voice account")
        XCTAssertFalse(voice.usesChatGPTSubscription)
    }

    func testQuickPairWaitsForPublicationAndCanRetryAfterFailure() async throws {
        let pairer = FakePairing()
        let model = AppModel(launcher: FakeLauncher(), pairer: pairer, automation: FakeAutomation(),
                             systemVersion: .init(majorVersion: 27, minorVersion: 0, patchVersion: 0),
                             localVPNAvailable: true, storage: storage.storage)
        model.simulateWorkingBuiltInVPN(ms: 8)
        model.preparePairingIfNeeded()
        model.preparePairingIfNeeded()
        XCTAssertEqual(pairer.starts, 1)
        defer { model.cancelPairing() }
        let first = try XCTUnwrap(pairer.emit)
        XCTAssertNil(model.pairingPIN)
        XCTAssertFalse(model.pairingPublished)
        first(.failed("fixture publication failure"))
        await waitForPairing("Listener failed") { model.pairing == .failed("fixture publication failure") }
        XCTAssertNil(model.pairingPIN)
        XCTAssertFalse(model.pairingPublished)
        model.preparePairingIfNeeded()
        XCTAssertEqual(pairer.starts, 1, "After a failure only an explicit retry should restart pairing")

        model.startPairing()
        let retry = try XCTUnwrap(pairer.emit)
        first(.pin("888888"))
        first(.advertising)
        retry(.advertising)
        await waitForPairing("Bonjour published") { model.pairingPublished }
        XCTAssertNil(model.pairingPIN, "Publishing the new listener must not show a code from the old listener")
        model.guide(.pairing)
        model.wentToBackground()
        XCTAssertNil(model.pairingPIN, "Leaving for Settings cannot generate a PIN")
        retry(.pin("001462"))
        await waitForPairing("Only the current challenge's PIN is visible in Settings") { model.pairingPIN == "001462" }
        model.becameActive()
        model.preparePairingIfNeeded()
        XCTAssertEqual(pairer.starts, 2)
        XCTAssertEqual(model.pairingPIN, "001462", "Returning to the guide must preserve the active challenge")
        XCTAssertNil(model.pairingPath, "Showing the code does not finish Apple's pairing confirmation")
        model.cancelPairing()
        XCTAssertFalse(model.pairingPublished)
        XCTAssertFalse(model.pairingUnderWay)
        XCTAssertNil(model.pairingPIN)
        model.preparePairingIfNeeded()
        XCTAssertEqual(pairer.starts, 2, "Leaving the page after cancel must not silently start a third listener")
    }

    func testQuickPairReusesAnExistingPairingAndUsesComputerSetupOnEarlierIOS() throws {
        let pairer = FakePairing()
        for major in [26, 27] {
            let model = AppModel(launcher: FakeLauncher(), pairer: pairer, automation: FakeAutomation(),
                                 systemVersion: .init(majorVersion: major, minorVersion: 0, patchVersion: 0),
                                 localVPNAvailable: true, storage: storage.storage)
            model.simulateWorkingBuiltInVPN(ms: 8)
            if major == 27 { try importFixturePairing(into: model) }
            model.preparePairingIfNeeded()
            XCTAssertEqual(pairer.starts, 0)
            XCTAssertNil(model.pairingPIN)
        }
    }

    func testOnlyTheCurrentPairingCompletionFinishesSetupAndClearsTheCode() async throws {
        let pairer = FakePairing()
        let model = AppModel(launcher: FakeLauncher(), pairer: pairer, automation: FakeAutomation(),
                             systemVersion: .init(majorVersion: 27, minorVersion: 0, patchVersion: 0),
                             localVPNAvailable: true, storage: storage.storage)
        model.simulateWorkingBuiltInVPN(ms: 8)
        model.preparePairingIfNeeded()
        let abandoned = try XCTUnwrap(pairer.emit)
        let abandonedURL = try XCTUnwrap(pairer.outputURL)
        model.cancelPairing()
        model.startPairing()
        defer { model.cancelPairing() }
        let current = try XCTUnwrap(pairer.emit)
        let currentURL = try XCTUnwrap(pairer.outputURL)
        XCTAssertNotEqual(abandonedURL, currentURL)
        let sample = try pairingFixtureData()
        try sample.write(to: abandonedURL)
        abandoned(.paired(abandonedURL))
        await waitForPairing("Ignored abandoned result and removed its staging file") {
            !FileManager.default.fileExists(atPath: abandonedURL.path)
        }
        XCTAssertNil(model.pairingPath)

        current(.advertising)
        await waitForPairing("Published listener is ready for Settings") { model.pairingPublished }
        XCTAssertNil(model.pairingPIN)
        current(.pin("012345"))
        await waitForPairing("Settings requested a code") { model.pairingPIN == "012345" }
        XCTAssertNil(model.pairingPath)
        try sample.write(to: currentURL)
        current(.paired(currentURL))
        await waitForPairing("Confirmed the signed pairing record") { model.isDone(.pairing) }
        XCTAssertNil(model.pairingPIN)
        XCTAssertFalse(model.pairingUnderWay)
        XCTAssertFalse(FileManager.default.fileExists(atPath: currentURL.path))
        XCTAssertEqual(try Data(contentsOf: storage.storage.phonePairingFileURL), sample)
        XCTAssertEqual(model.firstRunPhoneStep, .automation)
    }

    func testQuickPairOpensSettingsWithoutACodeAndShowsOnlyTheRequestedCode() async throws {
        AppLocalization.shared.preference = "zh-Hans"
        for appearance in [UIUserInterfaceStyle.light, .dark] {
            let pairer = FakePairing()
            pairer.eventsOnStart = [.advertising]
            let model = AppModel(launcher: FakeLauncher(), pairer: pairer, automation: FakeAutomation(),
                                 systemVersion: .init(majorVersion: 27, minorVersion: 0, patchVersion: 0),
                                 localVPNAvailable: true, storage: storage.storage)
            model.simulateWorkingBuiltInVPN(ms: 8)
            let guide = FirstRunGuide(link: .constant(nil), startVoice: {}, done: {})
            let spokenCode = "0 3 4 6 1 5"
            let waiting = try await renderedLabels(of: guide, model: model, pairingAppearance: appearance,
                                                   waitFor: { $0.contains("Open Settings") })
            for status in ["Connected", "Action needed", "Not connected", "Pending check"] {
                XCTAssertTrue(waiting.contains(status), "Missing checklist status: \(status)")
            }
            XCTAssertTrue(waiting.contains("Waiting for the iPhone to request a code."))
            let hint = try XCTUnwrap(waiting.first { $0.contains("iPhone passcode") })
            let unlock = try XCTUnwrap(hint.range(of: "iPhone passcode"))
            let codeAppears = try XCTUnwrap(hint.range(of: "here and in the Dynamic Island"))
            XCTAssertLessThan(unlock.upperBound, codeAppears.lowerBound)
            XCTAssertFalse(waiting.contains(spokenCode))
            XCTAssertFalse(waiting.contains("Enter this pairing code in Settings."))
            XCTAssertNil(model.pairingPIN)
            XCTAssertEqual(UIApplication.shared.applicationState, .active, "The guide must wait for the owner to open Settings")
            let challenge = try XCTUnwrap(pairer.emit)
            challenge(.pin("034615"))
            let requested = try await renderedLabels(of: guide, model: model, pairingAppearance: appearance,
                                                     waitFor: { $0.contains(spokenCode) })
            XCTAssertTrue(requested.contains("Code ready"))
            XCTAssertTrue(requested.contains("Enter this pairing code in Settings."))
            XCTAssertTrue(requested.contains("Open Settings"))
            XCTAssertEqual(pairer.starts, 1)
            XCTAssertEqual(model.firstRunPhoneStep, .pairing)
            model.cancelPairing()
        }
    }

    func testPairedPhoneKeepsTheChecklistWhileTheVoiceActionChanges() async throws {
        AppLocalization.shared.preference = "en"
        let model = AppModel(launcher: FakeLauncher(), pairer: FakePairing(), automation: FakeAutomation(),
                             localVPNAvailable: true, codex: StubSubscriptionVoice(), storage: storage.storage)
        model.simulateWorkingBuiltInVPN(ms: 9)
        try importFixturePairing(into: model)
        model.setup.developerMode = true
        model.setup.uiAutomation = true
        let guide = FirstRunGuide(link: .constant(nil), startVoice: {}, done: {})
        let withoutVoice = try await renderedLabels(of: guide, model: model,
                                                     waitFor: { $0.contains("Continue with ChatGPT") })
        XCTAssertTrue(withoutVoice.contains { $0.contains("Device pairing") })
        XCTAssertFalse(withoutVoice.contains("Start Voice Control"))

        try storage.seedCodexCredential()
        ModelKeys.setSelectedProvider(.chatgpt, in: storage.storage)
        let microphoneAction = AVAudioApplication.shared.recordPermission == .denied ? "Open Settings" : "Start Voice Control"
        let ready = try await renderedLabels(of: guide, model: model, waitFor: { $0.contains(microphoneAction) })
        XCTAssertTrue(ready.contains { $0.contains("Device pairing") })
        XCTAssertFalse(ready.contains("Continue with ChatGPT"))
        XCTAssertFalse(model.voice.isOn, "Entering the ready screen must wait for the owner to start recording")
    }

    func testExternalRouteNeverFinishesSetupOrStartsATask() async {
        let model = makeModel(localVPNAvailable: true)
        defer { model.loopback.pause(); model.stopSession() }
        ModelKeys.setCustomURL("http://127.0.0.1:9/v1", in: storage.storage)
        ModelKeys.setCustomModel("test-model", in: storage.storage)
        ModelKeys.setSelectedProvider(.custom, in: storage.storage)
        model.setup.loopback = .builtIn
        model.loopback.simulate(.working(ms: 9))
        XCTAssertFalse(model.isDone(.loopback))
        XCTAssertFalse(model.setupStepVerified(.loopback))
        model.startSession(reconnectLocal: false)
        XCTAssertFalse(model.sessionOn)
        XCTAssertNotNil(model.problem)
        XCTAssertFalse(model.problem?.contains("Use the Current VPN") == true)
        let result = await model.runTool("look", arguments: "{}")
        XCTAssertTrue(result.isError)
        XCTAssertFalse(model.sessionOn)
        XCTAssertEqual(model.setup.loopback, .builtIn)
    }

    func testMissingTunnelCannotUseAnExternalRoute() {
        let model = makeModel(localVPNAvailable: false)
        model.setup.loopback = .builtIn
        model.loopback.simulate(.working(ms: 9))
        XCTAssertFalse(model.setupStepVerified(.loopback))
        model.startSession(reconnectLocal: false)
        XCTAssertFalse(model.sessionOn)
    }

    /// 1. Simplified and Traditional Chinese UI must localize `AppModel.noRelay` in
    /// `Issue.current(model)`, `PokiDetailsView` ("需要处理"), and `SetupSettingsPage` without raw English.
    func testChineseUILocalizesNoRelayProblemInIssuesDetailsAndSetup() async throws {
        try resetIsolatedState()
        XCTAssertFalse(ModelKeys.hasUsableKey(in: storage.storage), "test precondition: no usable model key")

        let model = makeModel()
        defer { model.stopSession() }
        model.simulateWorkingBuiltInVPN(ms: 12)
        model.startSession()

        XCTAssertEqual(model.problem, AppModel.noRelay)

        AppLocalization.shared.preference = "zh-Hans"
        let issues = Issue.current(model)
        let problemIssue = try XCTUnwrap(issues.first { $0.id == "problem" })
        XCTAssertEqual(problemIssue.title, "需要处理")
        XCTAssertTrue(problemIssue.text.contains("外部连接"), "expected zh-Hans translation, got: \(problemIssue.text)")
        XCTAssertTrue(problemIssue.text.contains("远程连接服务"), "expected zh-Hans translation, got: \(problemIssue.text)")
        XCTAssertFalse(problemIssue.text.contains("Enter your relay"), "raw English leaked: \(problemIssue.text)")
        XCTAssertFalse(problemIssue.text.contains("External Connections"), "raw English leaked: \(problemIssue.text)")

        let detailsLabels = try await renderedLabels(
            of: PokiDetailsView(openSetup: {}, path: .constant(NavigationPath())),
            model: model,
            waitFor: { $0.contains { $0.contains("需要处理") } }
        )
        XCTAssertTrue(detailsLabels.contains { $0.contains("外部连接") && $0.contains("远程连接服务") },
                      "PokiDetailsView must render localized zh-Hans noRelay: \(detailsLabels)")
        XCTAssertFalse(detailsLabels.contains { $0.contains("Enter your relay") || $0.contains("External Connections") },
                       "PokiDetailsView must not leak English noRelay: \(detailsLabels)")

        let setupLabels = try await renderedLabels(
            of: NavigationStack { SetupSettingsPage(path: .constant(NavigationPath())) },
            model: model,
            waitFor: { $0.contains { $0.contains("外部连接") } }
        )
        XCTAssertTrue(setupLabels.contains { $0.contains("外部连接") && $0.contains("远程连接服务") },
                      "Setup footer must localize noRelay in zh-Hans: \(setupLabels)")
        XCTAssertFalse(setupLabels.contains { $0.contains("Enter your relay") || $0.contains("External Connections") },
                       "Setup footer must not leak English noRelay: \(setupLabels)")

        AppLocalization.shared.preference = "zh-Hant"
        let traditionalIssue = try XCTUnwrap(Issue.current(model).first { $0.id == "problem" })
        XCTAssertTrue(traditionalIssue.text.contains("外部連線"), "expected zh-Hant translation, got: \(traditionalIssue.text)")
        XCTAssertFalse(traditionalIssue.text.contains("Enter your relay"), "raw English leaked: \(traditionalIssue.text)")
    }

    /// 2. Simplified Chinese UI must localize `RelayStatus.offline(why)` across `RelayView`,
    /// `AgentsAndRelayView`, `AgentsView`, and `Issue.current(model)`, and disabling the relay switch
    /// must settle to `.off` (not `.offline("stopped")`) and remove the offline issue.
    func testChineseUILocalizesRelayOfflineStatusAcrossViewsAndDisablingClearsIssue() async throws {
        try resetIsolatedState()
        AppLocalization.shared.preference = "zh-Hans"

        let model = makeModel()
        defer { model.stopSession() }
        model.simulateWorkingBuiltInVPN(ms: 12)
        XCTAssertTrue(model.setRelay("http://127.0.0.1:1"))
        model.startSession()

        let offline = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated { model.relayStatus.isOffline }
        }, object: nil)
        await fulfillment(of: [offline], timeout: 10)

        let leakedTokens = ["Error Domain=", "NSURLErrorDomain", "Could not connect", "Connection refused", "the relay", "stopped"]

        let relayLabels = try await renderedLabels(
            of: NavigationStack { RelayView(back: {}) },
            model: model,
            waitFor: { $0.contains { $0.contains("离线") } }
        )
        let relayJoined = relayLabels.joined(separator: " | ")
        XCTAssertTrue(relayLabels.contains { $0.contains("离线") && $0.contains("无法连接到远程连接服务") },
                      "RelayView must show localized Offline reason: \(relayJoined)")
        for leaked in leakedTokens {
            XCTAssertFalse(relayJoined.contains(leaked), "RelayView leaked raw English '\(leaked)': \(relayJoined)")
        }

        let detailsAgentsLabels = try await renderedLabels(
            of: NavigationStack { AgentsAndRelayView(path: .constant(NavigationPath())) },
            model: model,
            waitFor: { $0.contains { $0.contains("离线") } }
        )
        let detailsAgentsJoined = detailsAgentsLabels.joined(separator: " | ")
        XCTAssertTrue(detailsAgentsLabels.contains { $0.contains("离线") && $0.contains("无法连接到远程连接服务") },
                      "AgentsAndRelayView must show localized Offline reason: \(detailsAgentsJoined)")
        for leaked in leakedTokens {
            XCTAssertFalse(detailsAgentsJoined.contains(leaked), "AgentsAndRelayView leaked raw English '\(leaked)': \(detailsAgentsJoined)")
        }

        let tabAgentsLabels = try await renderedLabels(
            of: AgentsView(path: .constant(NavigationPath()), openSession: { _ in }),
            model: model,
            waitFor: { $0.contains { $0.contains("离线") } }
        )
        let tabAgentsJoined = tabAgentsLabels.joined(separator: " | ")
        XCTAssertTrue(tabAgentsLabels.contains { $0.contains("离线") && $0.contains("无法连接到远程连接服务") },
                      "AgentsView must show localized Offline reason: \(tabAgentsJoined)")
        for leaked in leakedTokens {
            XCTAssertFalse(tabAgentsJoined.contains(leaked), "AgentsView leaked raw English '\(leaked)': \(tabAgentsJoined)")
        }

        let relayIssue = try XCTUnwrap(Issue.current(model).first { $0.id == "relay" })
        XCTAssertEqual(relayIssue.title, "智能体无法连接此 iPhone")
        XCTAssertTrue(relayIssue.text.contains("无法连接到远程连接服务"), relayIssue.text)
        for leaked in leakedTokens {
            XCTAssertFalse(relayIssue.text.contains(leaked), "Issue.current relay text leaked English '\(leaked)': \(relayIssue.text)")
        }

        // Disabling relay while session is on must settle to .off and never re-enter .offline("stopped").
        model.setRelayEnabled(false)
        let turnedOff = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated {
                model.relayStatus == .off && model.log.lines.contains { $0.contains("[relay] turned off") }
            }
        }, object: nil)
        await fulfillment(of: [turnedOff], timeout: 5)

        let disabledRelayLabels = try await renderedLabels(
            of: NavigationStack { RelayView(back: {}) },
            model: model,
            waitFor: { $0.contains { $0.contains("关闭") } }
        )
        XCTAssertEqual(model.relayStatus, .off, "disabling relay must stay .off after core.stop() settles")
        XCTAssertFalse(Issue.current(model).contains { $0.id == "relay" },
                       "disabling relay intentionally must not show an offline issue")
        XCTAssertFalse(disabledRelayLabels.joined(separator: " | ").contains("离线"),
                       "RelayView must show Off instead of Offline when disabled: \(disabledRelayLabels)")
    }

    func testOnlyTheBuiltInTunnelClearsALocalConnectionProblem() {
        let model = makeModel(localVPNAvailable: true)
        defer { model.stopSession() }
        model.setup.loopback = .builtIn
        model.startSession(reconnectLocal: false)
        XCTAssertNotNil(model.problem)
        model.loopback.simulate(.working(ms: 15))
        XCTAssertNotNil(model.problem, "An outside route must not dismiss the owned tunnel's error")
        model.simulateWorkingBuiltInVPN(ms: 10)
        XCTAssertNil(model.problem)

        model.startSession(reconnectLocal: false)
        XCTAssertEqual(model.problem, AppModel.noRelay)
        model.loopback.simulate(.off)
        model.simulateWorkingBuiltInVPN(ms: 11)
        XCTAssertEqual(model.problem, AppModel.noRelay)
    }

    /// 5. All PokiCore `RelayStatus.offline(why)` reasons (including unknown short English words)
    /// and pairing-refusal reasons (via `Issue.localizedProblem` and `Issue.current(model)` /
    /// `PokiDetailsView`) must render cleanly in Chinese with ZERO raw English reason leaks.
    func testAllRelayOfflineAndPairingReasonsNeverLeakRawEnglishInChinese() async throws {
        let relaySamples: [(raw: String, expectedZhHans: String)] = [
            ("stopped", "已停止"),
            ("Poki is shutting down", "Poki 正在关闭"),
            ("connecting to the relay did not finish within 15 s", "连接远程连接服务超时"),
            ("the relay's challenge did not finish within 15 s", "远程连接服务响应超时"),
            ("the relay's ready did not finish within 15 s", "远程连接服务响应超时"),
            ("the relay sent no challenge", "远程连接服务返回了异常响应"),
            ("the relay refused the phone: bad_signature", "远程连接服务认证失败"),
            ("the relay refused the phone: 403", "远程连接服务拒绝了此 iPhone（403）"),
            ("the relay refused the phone: rejected", "远程连接服务拒绝了此 iPhone 的连接"),
            ("the relay refused the phone: unsupported_version", "远程连接服务协议版本不兼容"),
            ("the relay closed the connection: replaced", "连接已被新会话替代"),
            ("the relay closed the connection: timeout", "远程连接服务响应超时"),
            ("the relay closed the connection: overloaded", "远程连接服务暂时繁忙"),
            ("the relay closed the connection: unexpected_eof", "远程连接服务关闭了连接"),
            ("the relay closed the connection: no reason", "远程连接服务关闭了连接"),
            ("Error Domain=NSURLErrorDomain Code=-1009 \"The Internet connection appears to be offline.\"", "无网络连接"),
            ("Error Domain=NSURLErrorDomain Code=-1001 \"The request timed out.\"", "连接超时"),
            ("Error Domain=NSURLErrorDomain Code=-1003 \"A server with the specified hostname could not be found.\"", "找不到远程连接服务地址"),
            ("Error Domain=NSURLErrorDomain Code=-1004 \"Could not connect to the server.\"", "无法连接到远程连接服务"),
            ("Error Domain=NSPOSIXErrorDomain Code=57 \"Socket is not connected\"", "连接已中断"),
            ("Error Domain=NSURLErrorDomain Code=-1200 \"An SSL error has occurred\"", "安全连接失败"),
            ("some unrecognized upstream failure", "连接失败"),
        ]

        AppLocalization.shared.preference = "zh-Hans"
        for sample in relaySamples {
            let reason = Health.relayOfflineReason(sample.raw)
            XCTAssertEqual(reason, sample.expectedZhHans, "raw: \(sample.raw)")
            let statusText = Health.relayStatusText(.offline(sample.raw))
            XCTAssertTrue(statusText.hasPrefix("离线"), "statusText: \(statusText)")
            XCTAssertTrue(statusText.contains(sample.expectedZhHans), "statusText: \(statusText)")
            for leaked in ["Error Domain=", "rejected", "unexpected_eof", "unsupported_version", "overloaded", "timeout"] {
                XCTAssertFalse(statusText.contains(leaked), "raw English '\(leaked)' leaked into: \(statusText)")
            }
        }

        // Pairing refusal via `Issue.localizedProblem` must translate known reasons and drop unknown English.
        let refusedCert = Issue.localizedProblem("The phone refused the pairing (invalid cert). Pair again in Setup.")
        XCTAssertTrue(refusedCert.contains("重新配对") && refusedCert.contains("配对证书已失效或不受信任"), refusedCert)
        XCTAssertFalse(refusedCert.contains("invalid cert") || refusedCert.contains("The phone refused"), refusedCert)

        let refusedUnknown = Issue.localizedProblem("The phone refused the pairing (x509 verify mismatch). Pair again in Setup.")
        XCTAssertTrue(refusedUnknown.contains("重新配对"), refusedUnknown)
        XCTAssertFalse(refusedUnknown.contains("x509") || refusedUnknown.contains("mismatch") || refusedUnknown.contains("The phone refused"), refusedUnknown)

        // Pairing trouble surfaced through `Issue.current(model)` and `PokiDetailsView` must also hide raw English.
        ModelKeys.setCustomURL("http://127.0.0.1:9/v1", in: storage.storage)
        ModelKeys.setCustomModel("fake-model", in: storage.storage)
        ModelKeys.setSelectedProvider(.custom, in: storage.storage)
        let model = makeModel()
        defer { model.stopSession() }
        model.simulateWorkingBuiltInVPN(ms: 12)
        model.startSession()
        model.wakeRunner()
        model.runnerChanged(RunnerStatus(state: "failed", detail: "invalid cert from peer", code: "pairing"))

        let pairingIssue = try XCTUnwrap(Issue.current(model).first { $0.id == "pairing" })
        XCTAssertEqual(pairingIssue.title, "重新配对此 iPhone")
        XCTAssertTrue(pairingIssue.text.contains("配对证书已失效或不受信任"), pairingIssue.text)
        XCTAssertFalse(pairingIssue.text.contains("invalid cert"), "raw English leaked in pairing issue: \(pairingIssue.text)")

        let detailsLabels = try await renderedLabels(
            of: PokiDetailsView(openSetup: {}, path: .constant(NavigationPath())),
            model: model,
            waitFor: { $0.contains { $0.contains("重新配对此 iPhone") } }
        )
        let detailsJoined = detailsLabels.joined(separator: " | ")
        XCTAssertTrue(detailsJoined.contains("配对证书已失效或不受信任"), "PokiDetailsView must localize pairing reason: \(detailsJoined)")
        XCTAssertFalse(detailsJoined.contains("invalid cert"), "PokiDetailsView leaked raw English pairing reason: \(detailsJoined)")

        // Unrecognized English pairing detail must also be summarized cleanly in Chinese without leaking raw text.
        model.runnerChanged(RunnerStatus(state: "failed", detail: "x509 verify mismatch", code: "pairing"))
        let unknownPairingIssue = try XCTUnwrap(Issue.current(model).first { $0.id == "pairing" })
        XCTAssertTrue(unknownPairingIssue.text.contains("重新配对"), unknownPairingIssue.text)
        XCTAssertFalse(unknownPairingIssue.text.contains("x509") || unknownPairingIssue.text.contains("mismatch"),
                       "unrecognized English pairing reason leaked: \(unknownPairingIssue.text)")

        AppLocalization.shared.preference = "zh-Hant"
        XCTAssertEqual(Health.relayOfflineReason("Error Domain=NSURLErrorDomain Code=-1004 \"Could not connect to the server.\""), "無法連線至遠端連線服務")
        XCTAssertEqual(Health.relayOfflineReason("the relay refused the phone: rejected"), "遠端連線服務拒絕了此 iPhone 的連線")
        let refusedCertHant = Issue.localizedProblem("The phone refused the pairing (invalid cert). Pair again in Setup.")
        XCTAssertTrue(refusedCertHant.contains("重新配對") && refusedCertHant.contains("配對憑證已失效或不受信任"), refusedCertHant)
        XCTAssertFalse(refusedCertHant.contains("invalid cert"), refusedCertHant)
    }

    /// 6. Explicit isolated `PokiStorage` instances never inherit or mutate a pre-configured outer
    /// storage's credentials (including the same OpenAI Keychain item and legacy Codex entries),
    /// pairing file, language preferences, or originally absent keys.
    func testIsolatedStoragePreservesPreconfiguredHostCredentialsAndPreferences() throws {
        let outer = storage.storage

        // Seed outer storage like a pre-configured host: OpenAI key, selected provider, relay,
        // localization, pairing.plist, and a legacy Codex Keychain entry.
        try ModelKeys.save("test-host-openai-credential", for: .openai, storage: outer)
        ModelKeys.setSelectedProvider(.openai, in: outer)
        RelayAddress.setSaved(RelayAddress("https://host-relay.example"), in: outer)
        let outerLocalization = AppLocalization(storage: outer)
        outerLocalization.preference = "zh-Hans"
        let hostPairingData = Data("host-pairing-record".utf8)
        try hostPairingData.write(to: outer.pairingFileURL)
        let outerLegacyCodexAccount = "cli|aaaaaaaaaaaaaaaa"
        try storage.seedCodexCredential(
            accessToken: "outer-legacy-codex-token",
            refreshToken: "outer-legacy-refresh",
            account: outerLegacyCodexAccount,
            accessible: kSecAttrAccessibleWhenUnlocked
        )

        // Preconditions on outer storage: existing values present and untouched keys absent.
        XCTAssertTrue(ModelKeys.hasUsableKey(in: outer))
        XCTAssertNil(outer.defaults.object(forKey: ApprovalClassifier.modeKey))
        XCTAssertNil(ModelKeys.key(.anthropic, storage: outer))
        XCTAssertNil(ModelKeys.key(.chatgpt, storage: outer))

        let inner = try IsolatedTestStorage(prefix: "health-relay-inner")
        do {
            defer { try? inner.tearDown() }
            let innerStorage = inner.storage

            // S2: directly read the SAME OpenAI credential item and evaluate hasUsableKey with .openai selected.
            XCTAssertNil(ModelKeys.key(.openai, storage: innerStorage), "inner storage must not read outer OpenAI credential")
            ModelKeys.setSelectedProvider(.openai, in: innerStorage)
            XCTAssertFalse(ModelKeys.hasUsableKey(in: innerStorage), "inner storage with .openai selected must still have no usable key")
            XCTAssertNil(RelayAddress.saved(in: innerStorage), "inner isolated storage must not inherit outer relay address")

            // S2: Codex legacy fixture isolation boundary — outer legacy cli|* item must never migrate into inner storage.
            XCTAssertEqual(CodexAccount.prepareStorage(storage: innerStorage), .empty)
            XCTAssertNil(CodexAccount.readAccessToken(storage: innerStorage))
            let innerLegacyAccount = "cli|bbbbbbbbbbbbbbbb"
            try inner.seedCodexCredential(
                accessToken: "inner-legacy-codex-token",
                refreshToken: "inner-legacy-refresh",
                account: innerLegacyAccount,
                accessible: kSecAttrAccessibleWhenUnlocked
            )
            XCTAssertEqual(CodexAccount.prepareStorage(storage: innerStorage), .migrated)
            XCTAssertEqual(CodexAccount.readAccessToken(storage: innerStorage), "inner-legacy-codex-token")
            XCTAssertNil(try Keychain.read(innerLegacyAccount, service: innerStorage.codexService))

            // P1: SetupState/AppModel pairing.plist isolation — building AppModel must not read or mirror outer/host pairing.plist.
            let model = makeModel(storage: innerStorage)
            defer { model.stopSession() }
            XCTAssertNil(model.pairingPath, "isolated AppModel must not see outer or host pairing.plist")
            XCTAssertNil(try Keychain.read("setup.pairing", storage: innerStorage), "isolated AppModel must not mirror outer or host pairing.plist into Keychain")
            model.simulateWorkingBuiltInVPN(ms: 12)
            model.startSession()
            XCTAssertEqual(model.problem, AppModel.noRelay)

            // P1: Mutate localization and keys that are absent in outer storage inside inner storage.
            let innerLocalization = AppLocalization(storage: innerStorage)
            innerLocalization.preference = "zh-Hant"
            model.approvalMode = .off
            try ModelKeys.save("inner-only-anthropic-key", for: .anthropic, storage: innerStorage)
            XCTAssertEqual(innerStorage.defaults.string(forKey: AppLocalization.key), "zh-Hant")
            XCTAssertEqual(innerStorage.appGroupDefaults.string(forKey: AppLocalization.effectiveKey), "zh-Hant")
        }

        // Verify outer storage's existing values remained completely intact.
        XCTAssertEqual(ModelKeys.key(.openai, storage: outer), "test-host-openai-credential")
        XCTAssertEqual(ModelKeys.selectedProvider(in: outer), .openai)
        XCTAssertEqual(RelayAddress.saved(in: outer)?.origin.absoluteString, "https://host-relay.example")
        XCTAssertTrue(ModelKeys.hasUsableKey(in: outer))
        XCTAssertEqual(outer.defaults.string(forKey: AppLocalization.key), "zh-Hans")
        XCTAssertEqual(outer.appGroupDefaults.string(forKey: AppLocalization.effectiveKey), "zh-Hans")
        XCTAssertEqual(try Data(contentsOf: outer.pairingFileURL), hostPairingData)
        XCTAssertNotNil(try Keychain.read(outerLegacyCodexAccount, service: outer.codexService), "outer legacy Codex entry must remain untouched by inner migration")
        XCTAssertEqual(CodexAccount.prepareStorage(storage: outer), .migrated)
        XCTAssertEqual(CodexAccount.readAccessToken(storage: outer), "outer-legacy-codex-token")

        // Verify outer storage's originally absent keys remained absent.
        XCTAssertNil(outer.defaults.object(forKey: ApprovalClassifier.modeKey))
        XCTAssertNil(ModelKeys.key(.anthropic, storage: outer))
        XCTAssertNil(ModelKeys.key(.chatgpt, storage: outer))

        // Verify real host `.live` localization keys remained untouched (both existing values and missing-key absence).
        hostLocalization.assertUnchanged()
    }

    /// 7. P1 / ST-1 regression: isolated `PokiStorage` instances follow their own approval mode,
    /// sensitivity, model selection, voice account settings, and subscription bridge boundary
    /// regardless of outer or `.live` storage configuration, and never write or mutate `.live`
    /// or outer storage.
    func testIsolatedApprovalAndSubscriptionBoundariesIgnoreOuterAndLiveStorage() async throws {
        // Capture read-only snapshots of real `.live` UserDefaults keys without mutating `.live`.
        let liveKeys = [
            ApprovalClassifier.modeKey,
            ApprovalClassifier.levelKey,
            "chat.provider",
            "chat.model",
            "models.enabled.voice",
            "voice.model",
            "voice.openai.enabled",
            "relayAddress",
            "relayEnabled",
            "wantsOn",
        ]
        var liveSnapshot: [String: Any?] = [:]
        for key in liveKeys {
            liveSnapshot[key] = UserDefaults.standard.object(forKey: key)
        }

        // Configure outer isolated storage with `.off` (Never Ask), `.permissive`, and an OpenAI key.
        let outer = storage.storage
        outer.defaults.set(ApprovalClassifier.Mode.off.rawValue, forKey: ApprovalClassifier.modeKey)
        outer.defaults.set(ApprovalClassifier.Level.permissive.rawValue, forKey: ApprovalClassifier.levelKey)
        try ModelKeys.save("outer-openai-key", for: .openai, storage: outer)
        ModelKeys.setSelectedProvider(.openai, in: outer)

        let inner = try IsolatedTestStorage(prefix: "approval-subscription-inner")
        defer { try? inner.tearDown() }
        let innerStorage = inner.storage

        // 1. ApprovalClassifier route, hasModel, and decide use explicit `storage` rather than `.live` or outer.
        innerStorage.defaults.set(ApprovalClassifier.Mode.confirm.rawValue, forKey: ApprovalClassifier.modeKey)
        innerStorage.defaults.set(ApprovalClassifier.Level.everything.rawValue, forKey: ApprovalClassifier.levelKey)

        let optionalApprovalInner = PendingApproval(
            id: "inner-optional-\(UUID().uuidString)",
            app: "Messages",
            summary: "Tap “Send”",
            reason: #"sending a message ("send")"#,
            expires: Date().addingTimeInterval(60)
        )
        let optionalApprovalOuter = PendingApproval(
            id: "outer-optional-\(UUID().uuidString)",
            app: "Messages",
            summary: "Tap “Send”",
            reason: #"sending a message ("send")"#,
            expires: Date().addingTimeInterval(60)
        )
        XCTAssertEqual(ApprovalClassifier.route(optionalApprovalOuter, voiceOn: false, storage: outer), .allow)
        XCTAssertEqual(ApprovalClassifier.route(optionalApprovalInner, voiceOn: false, storage: innerStorage), .owner)
        XCTAssertTrue(ApprovalClassifier.hasModel(in: outer))
        XCTAssertFalse(ApprovalClassifier.hasModel(in: innerStorage), "isolated storage without a key must not fall back to outer or .live model")

        let noModelVerdict = await ApprovalClassifier.decide(
            optionalApprovalInner,
            level: ApprovalClassifier.Level.saved(in: innerStorage),
            voice: [],
            origin: .chat("inner-test"),
            storage: innerStorage
        )
        XCTAssertFalse(noModelVerdict.allowed)
        XCTAssertEqual(noModelVerdict.reason, "no chat model to ask")

        // 2. End-to-end AppModel + LiveCore optional approval path honors isolated `.confirm` (asks owner).
        InProcessWDA.gate.withLock { $0 = InProcessWDA.OpenGate() }
        let automation = FakeAutomation()
        let transport = SessionScreenTransport(session: automation, screenLabel: { "Call" })
        let innerApp = AppModel(
            launcher: FakeLauncher(),
            pairer: FakePairing(),
            automation: automation,
            transport: transport,
            storage: innerStorage
        )
        defer {
            automation.answer(nil)
            if innerApp.sessionOn { innerApp.stopSession() }
        }
        XCTAssertEqual(innerApp.approvalMode, .confirm)
        XCTAssertEqual(innerApp.classifierLevel, .everything)
        innerApp.simulateWorkingBuiltInVPN(ms: 9)
        XCTAssertTrue(innerApp.setRelay("https://relay.invalid"))
        innerApp.becameActive()
        innerApp.startSession()
        innerApp.wakeRunner()
        for _ in 0..<150 where !["failed", "running"].contains(innerApp.runner.state) {
            try await Task.sleep(for: .milliseconds(20))
        }
        innerApp.runnerChanged(RunnerStatus(state: "running", code: "local_ddi"))
        for _ in 0..<150 where !innerApp.hasOpenInProcessSession {
            try await Task.sleep(for: .milliseconds(20))
        }
        await innerApp.chatTaskBegan()
        let look = await innerApp.runTool("look", arguments: "{}")
        XCTAssertFalse(look.isError, look.text)

        let callTask = Task { await innerApp.runTool("do", arguments: #"{"actions":[{"tap":1}]}"#) }
        for _ in 0..<150 where innerApp.approvals.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        let pending = try XCTUnwrap(innerApp.approvals.first, "Isolated AppModel with .confirm must ask owner for optional Call approval")
        XCTAssertFalse(ApprovalClassifier.requiresOwner(pending), "Call tap must exercise the optional-approval branch")
        innerApp.resolve(pending, approved: false)
        let deniedResult = await callTask.value
        XCTAssertTrue(deniedResult.isError || deniedResult.text.localizedCaseInsensitiveContains("denied") || deniedResult.text.localizedCaseInsensitiveContains("not allow"), deniedResult.text)

        // 3. Switching isolated storage to `.reply` + custom model routes to `.model(reply: true)` without touching outer or `.live`.
        try ModelKeys.saveCustom(address: "http://127.0.0.1:8765/v1", model: "isolated-classifier-model", typedKey: "", storage: innerStorage)
        innerApp.approvalMode = .reply
        innerApp.classifierLevel = .balanced
        XCTAssertTrue(ApprovalClassifier.hasModel(in: innerStorage))
        let replyApproval = PendingApproval(
            id: "inner-reply-\(UUID().uuidString)",
            app: "Messages",
            summary: "Tap “Send”",
            reason: #"sending a message ("send")"#,
            expires: Date().addingTimeInterval(60)
        )
        XCTAssertEqual(ApprovalClassifier.route(replyApproval, voiceOn: true, storage: innerStorage), .model(reply: true))

        // 4. Subscription voice boundary: isolated storage without an injected bridge must not silently fall back to `CodexVoice.shared`.
        try inner.seedCodexCredential(accessToken: "inner-isolated-codex-token")
        ModelKeys.setSelectedProvider(.chatgpt, in: innerStorage)
        XCTAssertFalse(innerApp.voice.usesChatGPTSubscription, "Isolated AppModel without an explicit SubscriptionVoice bridge must not report ChatGPT subscription usable via CodexVoice.shared")
        let injectedVoice = VoiceModel(
            clearTap: { _, _, _ in .clear },
            phoneTool: { _, _, _ in ("", false, nil) },
            codex: StubSubscriptionVoice(),
            storage: innerStorage
        )
        XCTAssertTrue(injectedVoice.usesChatGPTSubscription, "Isolated VoiceModel with an explicit SubscriptionVoice bridge must match its isolated storage sign-in state")

        // 5. ModelCatalog.setVoice without explicit `account:` resolves `VoiceDirect.settingsAccount(in: storage)`.
        let customProvider = CustomProvider(
            name: "Isolated Voice Gateway",
            endpoints: [CustomEndpoint(url: "https://isolated-voice.invalid/v1")],
            model: "isolated-chat",
            liveVoice: true
        )
        CustomProviders.setAll([customProvider], in: innerStorage)
        XCTAssertEqual(VoiceDirect.settingsAccount(in: innerStorage), .custom(customProvider.id))
        ModelCatalog.setVoice("isolated-rt-model", on: true, storage: innerStorage)
        let customVoiceKey = "models.enabled.voice" + VoiceAccount.custom(customProvider.id).storeSuffix
        XCTAssertTrue(ModelCatalog.voiceOn(for: .custom(customProvider.id), storage: innerStorage).contains("isolated-rt-model"))
        XCTAssertNil(outer.defaults.object(forKey: customVoiceKey))
        XCTAssertNil(UserDefaults.standard.object(forKey: customVoiceKey))

        // 6. Verify outer storage and real `.live` storage remained completely unchanged.
        XCTAssertEqual(ApprovalClassifier.mode(in: outer), .off)
        XCTAssertEqual(ApprovalClassifier.Level.saved(in: outer), .permissive)
        XCTAssertEqual(ModelKeys.key(.openai, storage: outer), "outer-openai-key")
        XCTAssertEqual(ModelKeys.selectedProvider(in: outer), .openai)

        for key in liveKeys {
            let expected = liveSnapshot[key] ?? nil
            let actual = UserDefaults.standard.object(forKey: key)
            XCTAssertEqual(actual != nil, expected != nil, "Live UserDefaults presence changed for \(key)")
            if let expectedString = expected as? String {
                XCTAssertEqual(actual as? String, expectedString, "Live UserDefaults string changed for \(key)")
            } else if let expectedBool = expected as? Bool {
                XCTAssertEqual(actual as? Bool, expectedBool, "Live UserDefaults bool changed for \(key)")
            } else if let expectedArray = expected as? [String] {
                XCTAssertEqual(actual as? [String], expectedArray, "Live UserDefaults array changed for \(key)")
            }
        }
        hostLocalization.assertUnchanged()
    }

    @MainActor
    private struct StubSubscriptionVoice: SubscriptionVoice {
        func prepare(onEvent: @escaping (String, [String: Any]) -> Void, onTool: @escaping (String, String) async -> PhoneAnswer) async throws {}
        func start(offer: String) async throws -> String { "stub-sdp" }
        func interruptPhoneTurn() {}
        func stop() {}
    }

    // MARK: - Helpers

    private func waitForPairing(_ description: String, _ condition: @escaping @MainActor () -> Bool) async {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated { condition() }
        }, object: nil)
        ready.expectationDescription = description
        await fulfillment(of: [ready], timeout: 3)
    }

    private func importFixturePairing(into model: AppModel) throws {
        try model.importPairingFile(pairingFixtureData(), how: "test")
    }

    private func pairingFixtureData() throws -> Data {
        let record: [String: Any] = ["identifier": "fixture", "public_key": Data(repeating: 1, count: 32),
                                     "private_key": Data(repeating: 2, count: 32)]
        return try PropertyListSerialization.data(fromPropertyList: record, format: .binary, options: 0)
    }

    private func renderedLabels<Content: View>(
        of view: Content,
        model: AppModel,
        pairingAppearance: UIUserInterfaceStyle? = nil,
        waitFor condition: @escaping ([String]) -> Bool = { !$0.isEmpty }
    ) async throws -> [String] {
        let chat = ChatModel(app: model)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        if let pairingAppearance {
            window.frame = scene.screen.bounds
            window.overrideUserInterfaceStyle = pairingAppearance
        } else {
            window.frame = CGRect(x: 0, y: 0, width: scene.screen.bounds.width, height: 1800)
        }
        window.rootViewController = UIHostingController(
            rootView: view
                .environment(model)
                .environment(chat)
                .environment(\.locale, AppLocalization.locale)
                .environment(\.accessibilityEnabled, true)
        )
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        window.layoutIfNeeded()

        let drawn = expectation(description: "rendered SwiftUI frame")
        let frames = DisplayFrameObserver { drawn.fulfill() }
        let display = CADisplayLink(target: frames, selector: #selector(DisplayFrameObserver.tick))
        display.add(to: .main, forMode: .common)
        await fulfillment(of: [drawn], timeout: 5)
        display.invalidate()

        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated {
                window.layoutIfNeeded()
                return condition(Self.collectLabels(in: window))
            }
        }, object: nil)
        await fulfillment(of: [ready], timeout: 5)
        if let pairingAppearance {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            let stage = model.pairingPIN == nil ? "Waiting for Settings" : "Requested code"
            attachment.name = stage + (pairingAppearance == .dark ? " dark" : " light")
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        return Self.collectLabels(in: window)
    }

    private static func collectLabels(in root: NSObject) -> [String] {
        var labels: [String] = []
        var pending = [root]
        var visited = Set<ObjectIdentifier>()
        while let item = pending.popLast() {
            guard visited.insert(ObjectIdentifier(item)).inserted else { continue }
            if let label = item.accessibilityLabel, !label.isEmpty { labels.append(label) }
            if let value = item.accessibilityValue, !value.isEmpty { labels.append(value) }
            if let view = item as? UIView { pending.append(contentsOf: view.subviews) }
            if let children = item.accessibilityElements { pending.append(contentsOf: children.compactMap { $0 as? NSObject }) }
            let count = item.accessibilityElementCount()
            if count > 0 && count < 1000 {
                for index in 0..<count {
                    if let child = item.accessibilityElement(at: index) as? NSObject { pending.append(child) }
                }
            }
        }
        return labels
    }
}

private final class DisplayFrameObserver: NSObject {
    private var remaining = 2
    private let onDone: () -> Void
    init(onDone: @escaping () -> Void) { self.onDone = onDone }
    @objc func tick() {
        remaining -= 1
        if remaining == 0 { onDone() }
    }
}
