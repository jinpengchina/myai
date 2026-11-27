import XCTest

final class QuickSetupUITests: XCTestCase {
    func testEarlierIOSKeepsComputerPairingAvailableWithoutOfferingAnOnDeviceCode() throws {
        if #available(iOS 27, *) { throw XCTSkip("Computer pairing is the primary path on iOS 26 and earlier") }
        let app = XCUIApplication()
        app.launchArguments = [
            "-pokiScreen", "setup", "-pokiSetupStep", "3",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        app.launch()
        let fileImport = app.buttons["Import Pairing File"]
        XCTAssertTrue(fileImport.waitForExistence(timeout: 18))
        XCTAssertFalse(app.staticTexts["pairing.code"].exists)
        XCTAssertFalse(app.buttons["pairing.openSettings"].exists)
    }

    func testExistingVoiceCanStartFromChatBeforePhoneControlIsPaired() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-pokiScreen", "chat", "-pokiTalkRehearsal", "1", "-pokiTalkHold", "listening",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        app.launch()
        let voice = app.buttons["composer.main"]
        XCTAssertTrue(voice.waitForExistence(timeout: 18))
        voice.tap()
        let end = app.buttons["composer.talk.end"]
        XCTAssertTrue(end.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["firstRun.finishLater"].exists)
        end.tap()
    }

    func testFirstRunAttemptsConnectionWithoutATapAndLetsTextChatReopenTheGuide() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-pokiScreen", "welcome", "-firstRun.builtInVPNNeedsRetry", "NO",
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
        ]
        app.launch()

        // A simulator cannot start the packet tunnel. Reaching its failure state without a
        // tap verifies that the guide actually attempted the connection on appearance.
        let retry = app.buttons["quickSetup.retryVPN"]
        let textChat = app.buttons["firstRun.finishLater"]
        XCTAssertTrue(retry.waitForExistence(timeout: 18))
        let heading = app.descendants(matching: .any)["firstRun.checklist"].firstMatch
        XCTAssertEqual(heading.label, "Set up ailove")
        let steps = [("vpn", "Built-in VPN"), ("pairing", "Device pairing"), ("voice", "Voice account"),
                     ("controls", "UI Automation"), ("microphone", "Microphone")]
        for (id, title) in steps {
            let row = app.buttons["firstRun.row.\(id)"]
            XCTAssertTrue(row.exists, "Missing checklist row \(title)")
            XCTAssertTrue(row.label.contains(title), row.label)
        }
        app.buttons["firstRun.row.voice"].tap()
        XCTAssertTrue(heading.exists, "Inspecting another step must keep the checklist on screen")
        XCTAssertFalse(app.buttons["firstRun.voice.signIn"].exists, "A pending step must not start an early sign-in")
        XCTAssertFalse(app.buttons["Connect This iPhone"].exists)
        XCTAssertTrue(textChat.isHittable)
        XCTAssertFalse(app.buttons["firstRun.voice.start"].exists)
        textChat.tap()

        let voice = app.buttons["composer.main"]
        XCTAssertTrue(voice.waitForExistence(timeout: 8))
        voice.tap()
        XCTAssertTrue(retry.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["Connect This iPhone"].exists)
        XCTAssertTrue(textChat.isHittable)
    }

    func testReturningAfterUnfinishedConsentWaitsForAnExplicitRetry() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-pokiScreen", "welcome", "-firstRun.builtInVPNNeedsRetry", "YES",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        app.launch()

        let disconnected = app.staticTexts["The built-in VPN is disconnected. Try again to reconnect."]
        XCTAssertTrue(disconnected.waitForExistence(timeout: 18))
        let retry = app.buttons["quickSetup.retryVPN"]
        XCTAssertTrue(retry.isHittable)
        retry.tap()
        let tunnelFailure = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "physical iPhone")).firstMatch
        XCTAssertTrue(tunnelFailure.waitForExistence(timeout: 8))
        XCTAssertFalse(disconnected.exists)
    }
}
