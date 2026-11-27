import SwiftUI
import UniformTypeIdentifiers

private extension AppModel {
    var firstRunConnectionNeedsCheck: Bool {
        tunnel.connected && (loopback.state == .noAnswer || loopback.state == .off)
    }

    var canOpenPairingSettings: Bool {
        pairingUnderWay && (pairingPublished || pairingPIN != nil)
    }
}

/// Inline content for the active checklist row. Keeping this mounted also keeps the
/// phone verification and pairing handoff alive while the instructions are collapsed.
struct FirstRunConnectionStep: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    let step: SetupStep
    @State private var scanning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch step {
            case .loopback: connection
            case .pairing: pairing
            case .automation, .developerMode: controls
            case .runner:
                Text(verbatim: "Install Poki Runner with the same Apple ID, then trust it in Settings › General › VPN & Device Management.")
                Button("Open Settings") { openSettings(model, for: .runner) }
            case .background: EmptyView()
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .buttonStyle(FirstRunInlineButtonStyle())
        .fixedSize(horizontal: false, vertical: true)
        .task(id: step == .loopback) {
            guard step == .loopback else { return }
            model.loopback.resume()
            await model.connectFirstRunVPN()
        }
        .task(id: step == .automation || step == .developerMode) {
            if step == .automation || step == .developerMode { await model.prepareFirstRunPhone() }
        }
        .task(id: step == .pairing && model.loopback.isWorking) {
            if step == .pairing { model.preparePairingIfNeeded() }
        }
        .task(id: step == .pairing) {
            if step == .pairing { await model.watchForHandedPairing() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, step == .pairing { model.preparePairingIfNeeded() }
        }
        .sheet(isPresented: $scanning) { PairingScannerSheet() }
    }

    @ViewBuilder private var connection: some View {
        if !model.isLocalVPNAvailable {
            Text(verbatim: "Reinstall the signed \(AppBrand.name) app to use its built-in VPN.")
        } else if let failure = model.firstRunVPNFailure {
            Text(verbatim: failure)
        } else if model.firstRunConnectionNeedsCheck {
            Text(verbatim: "The VPN is connected. Check again to reach this iPhone’s services.")
        } else {
            ProgressView(model.tunnel.connected ? "Checking the connection…" : "Connecting to this iPhone…")
                .accessibilityIdentifier("quickSetup.connectionProgress")
        }
    }

    @ViewBuilder private var pairing: some View {
        if model.supportsOnDevicePairing {
            if model.canOpenPairingSettings {
                if let pin = model.pairingPIN {
                    PairingCodeText(pin: pin)
                    Text(verbatim: "Enter this pairing code in Settings.")
                } else {
                    Text(verbatim: "Waiting for the iPhone to request a code.")
                        .accessibilityIdentifier("pairing.awaitingChallenge")
                    Text(verbatim: "In Settings, go to Privacy & Security › Developer Mode and tap Pair with \(AppBrand.name).")
                        .accessibilityIdentifier("pairing.settingsInstructions")
                    Text(verbatim: "If iOS asks for your iPhone passcode, enter it first. The pairing code then appears here and in the Dynamic Island.")
                        .accessibilityIdentifier("pairing.islandHint")
                }
            } else if case .failed(let reason)? = model.pairing {
                if reason == RustPairing.publicationFailure {
                    Text(verbatim: "Allow Local Network access for \(AppBrand.name) in Settings, then try again on Wi-Fi.")
                    Button("Open App Settings") { openSettings(model, for: nil) }
                } else {
                    Text(verbatim: reason)
                }
            } else if model.firstRunPairingNeedsRetry {
                Text(verbatim: "Pairing stopped. You can try again.")
            } else if !model.loopback.isWorking && !model.pairingUnderWay {
                Text(verbatim: "Check the connection to this iPhone before pairing.")
            } else {
                ProgressView("Getting ready to pair…")
                    .accessibilityIdentifier("pairing.waitingForPublication")
                Text(verbatim: "Allow Local Network access if iOS asks.")
            }
            if model.pairingUnderWay {
                Button("Cancel Pairing") { model.cancelPairing() }
                    .accessibilityIdentifier("pairing.cancel")
            }
            DisclosureGroup("Other ways to pair") {
                VStack(alignment: .leading, spacing: 8) {
                    scanButton
                    FirstRunPairingImport()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .tint(.primary)
        } else {
            Text(verbatim: "Pair this iPhone with Poki Setup on your computer, then import the pairing file here.")
            scanButton
        }
        if let note = model.pairingNote {
            Text(verbatim: AppLocalization.language.hasPrefix("en") ? note
                 : "If the pairing file doesn’t finish importing, choose the file for this iPhone and try again.")
        }
    }

    @ViewBuilder private var scanButton: some View {
        if PairingScanner.available {
            Button("Scan Pairing Code") { scanning = true }
        }
    }

    @ViewBuilder private var controls: some View {
        if model.passcodeConfirmationPending {
            Text(verbatim: "iOS may ask for your iPhone passcode the first time you use phone controls after a restart. Enter it in the system prompt.")
        } else if model.checkingFirstRunPhone {
            if case .downloading(let progress) = model.diskImage.state {
                ProgressView("Preparing phone controls…")
                Text(verbatim: progress).font(.footnote)
            } else {
                ProgressView("Checking phone controls…")
            }
        } else if case .failed = model.diskImage.state {
            Text(verbatim: "The developer disk image could not be prepared. Check your internet connection and try again.")
        } else {
            if model.localSessionTrouble != nil {
                Text(verbatim: "The connection to this iPhone’s developer services failed. Keep the iPhone unlocked on Wi-Fi, then check again.")
            }
            if step == .developerMode {
                Text(verbatim: "In Settings › Privacy & Security, turn on Developer Mode. Restart this iPhone and confirm when asked.")
            } else {
                Text(verbatim: "In Settings › Developer, turn on Enable UI Automation, then return here.")
            }
            Button("Check Again") { Task { await model.prepareFirstRunPhone(retry: true) } }
        }
    }
}

/// The current phone action occupies the guide’s single primary-button slot.
struct FirstRunPhoneAction: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var openedControlsSettings = false
    let step: SetupStep

    var body: some View {
        VStack(spacing: 0) {
            switch step {
            case .loopback:
                if model.isLocalVPNAvailable {
                    if model.firstRunVPNFailure != nil {
                        Button("Try Again") { Task { await model.connectFirstRunVPN(retry: true) } }
                            .accessibilityIdentifier("quickSetup.retryVPN")
                    } else if model.firstRunConnectionNeedsCheck {
                        Button("Check Again") { model.loopback.check() }
                            .accessibilityIdentifier("quickSetup.phoneAction")
                    }
                }
            case .pairing:
                if !model.supportsOnDevicePairing {
                    FirstRunPairingImport()
                } else if model.canOpenPairingSettings {
                    Button("Open Settings") { openSettings(model, for: .pairing) }
                        .accessibilityIdentifier("pairing.openSettings")
                } else if model.firstRunPairingNeedsRetry {
                    Button("Try Again") { model.startPairing() }
                        .accessibilityIdentifier("pairing.retry")
                } else if !model.loopback.isWorking && !model.pairingUnderWay {
                    Button("Check Connection") { model.loopback.check() }
                        .accessibilityIdentifier("quickSetup.phoneAction")
                }
            case .automation, .developerMode:
                if model.passcodeConfirmationPending {
                    Button("Continue") { model.continueAfterPasscodeHeadsUp() }
                        .accessibilityIdentifier("quickSetup.phoneAction")
                } else if !model.checkingFirstRunPhone {
                    if case .failed = model.diskImage.state {
                        Button("Try Again") { Task { await model.prepareFirstRunPhone(retry: true) } }
                            .accessibilityIdentifier("quickSetup.phoneAction")
                    } else {
                        Button("Open Settings") {
                            openedControlsSettings = true
                            openSettings(model, for: step)
                        }
                        .accessibilityIdentifier("quickSetup.phoneAction")
                    }
                }
            case .runner:
                Button("Runner Is Installed and Trusted") { model.setup.runnerInstalled = true }
                    .accessibilityIdentifier("quickSetup.phoneAction")
            case .background: EmptyView()
            }
        }
        .buttonStyle(FirstRunPrimaryButtonStyle())
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, openedControlsSettings {
                openedControlsSettings = false
                Task { await model.prepareFirstRunPhone(retry: true) }
            }
        }
    }
}

private struct FirstRunInlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .underline()
            .foregroundStyle(.primary)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .padding(.vertical, 3)
    }
}

private struct FirstRunPairingImport: View {
    @Environment(AppModel.self) private var model
    @State private var importing = false
    @State private var failed = false

    var body: some View {
        Button("Import Pairing File") { importing = true }
            .accessibilityIdentifier("pairing.import")
            .fileImporter(isPresented: $importing, allowedContentTypes: [.propertyList, .xml, .data]) { result in
                do { try model.importPairingFile(from: result.get()) }
                catch let error as CocoaError where error.code == .userCancelled { }
                catch { failed = true }
            }
            .alert("Couldn’t import the pairing file", isPresented: $failed) {
                Button("OK") { }
            } message: {
                Text(verbatim: "Choose the pairing file for this iPhone from Poki Setup.")
            }
    }
}

private struct PairingCodeText: View {
    var pin: String
    var body: some View {
        Text(verbatim: pin)
            .font(.system(.largeTitle, design: .rounded).weight(.bold)).monospacedDigit()
            .foregroundStyle(.primary)
            .lineLimit(1).minimumScaleFactor(0.55)
            .accessibilityLabel(Text(verbatim: pin.map(String.init).joined(separator: " ")))
            .accessibilityIdentifier("pairing.code")
    }
}

/// Setup, one step per page (ESP-139 board 03). Steps the phone can check by itself (the loopback,
/// pairing, location and Live Activities) move on when they pass; steps it can't (Poki Runner,
/// Developer Mode, UI Automation) keep a switch the person turns on, and Continue lights up after it.
/// Steps that send the person to Settings put the step and what to tap in the Live Activity.
struct SetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var index: Int
    private let steps = SetupStep.shown

    init(start: Int) { _index = State(initialValue: start) }

    /// The first step not done, where setup opens.
    @MainActor static func firstOpen(_ model: AppModel) -> Int {
        SetupStep.shown.firstIndex { !model.isDone($0) } ?? 0
    }

    private var step: SetupStep { steps[index] }

    var body: some View {
        SitePage {
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(step.pageTitle).site(30, .heavy, line: 36, tracking: -0.02).fixedSize(horizontal: false, vertical: true)
                            Text(step.pageSummary).site(15, line: 21).foregroundStyle(Site.c3).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 24).padding(.top, 28)
                        VStack(alignment: .leading, spacing: 0) { content }.padding(.bottom, 24)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(step)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            mainButton.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8)
                .frame(maxWidth: .infinity)
                .background(Site.page(scheme).ignoresSafeArea(edges: .bottom))
        }
        .onChange(of: checkedByPhone) { was, now in
            if !was, now, step != .loopback { advanceSoon() }
        }
        .onChange(of: model.isDone(.loopback)) { was, now in
            if step == .loopback, !was, now { advanceSoon() }
        }
        .onAppear { model.loopback.resume() }
        .onChange(of: step) { old, _ in
            if old == .pairing, model.pairingUnderWay { model.cancelPairing() }
        }
    }

    /// The current step's own check passed: the pairing took, location and Live Activities are on.
    private var checkedByPhone: Bool { step == .pairing || step == .background ? model.isDone(step) : false }

    private var header: some View {
        HStack(spacing: 12) {
            Button { index == 0 ? dismiss() : withAnimation(.snappy) { index -= 1 } } label: {
                Text(verbatim: "‹").site(17, line: 22).frame(minWidth: 20, minHeight: 32, alignment: .leading).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(index == 0 ? Text("Close") : Text("Back"))
            HStack(spacing: 4) {
                ForEach(steps.indices, id: \.self) { i in
                    Capsule().fill(i <= index ? Color.white : Color.white.opacity(0.28)).frame(height: 4)
                }
            }
            .accessibilityHidden(true)
            Text("\(index + 1) of \(steps.count)").site(13, line: 16).foregroundStyle(Site.c4).monospacedDigit()
        }
        .padding(.horizontal, 20).padding(.top, 8)
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .runner:
            InstructionsCard(lines: [
                "Install **Poki Runner** (poki-runner-unsigned.ipa) with the same tool and Apple ID you used for Poki.",
                "Open **Settings › General › VPN & Device Management**, tap your Apple ID, then tap **Trust**.",
                "Don’t open Poki Runner yourself. Poki starts it when an agent needs this iPhone.",
            ])
            ConfirmCard(step: .runner, title: "Poki Runner is installed and trusted", isOn: binding(\.runnerInstalled))
        case .developerMode:
            InstructionsCard(lines: [
                SetupStep.inProcess ? "Open **Settings › Privacy & Security › Developer Mode**." : "Open **Settings › Privacy & Security › Developer Mode**. It appears once Poki Runner is installed.",
                "Turn on Developer Mode, then tap **Restart**.",
                "After restarting, unlock this iPhone and tap **Turn On**.",
            ])
            ConfirmCard(step: .developerMode, title: "Developer Mode is on", isOn: binding(\.developerMode))
        case .loopback: LoopbackPage()
        case .pairing: PairingPage()
        case .automation:
            InstructionsCard(lines: [
                "Open **Settings › Developer**. It appears once Developer Mode is on.",
                "Turn on **Enable UI Automation**.",
            ])
            ConfirmCard(step: .automation, title: "UI Automation is on", isOn: binding(\.uiAutomation))
        case .background: BackgroundPage()
        }
    }

    private func binding(_ key: WritableKeyPath<SetupState, Bool>) -> Binding<Bool> {
        Binding(get: { model.setup[keyPath: key] }, set: { model.setup[keyPath: key] = $0 })
    }

    @ViewBuilder private var mainButton: some View {
        if index == steps.count - 1 {
            CapsuleButton(title: "Done", height: 54) { dismiss() }
        } else if step != .pairing || model.isDone(.pairing) {
            CapsuleButton(title: "Continue", height: 54, enabled: model.isDone(step)) { advance() }
        }
    }

    private func advanceSoon() {
        let from = index
        Task { try? await Task.sleep(for: .milliseconds(600)); if index == from { advance() } }
    }

    private func advance() {
        guard index < steps.count - 1 else { return }
        withAnimation(.snappy) { index += 1 }
    }
}

extension SetupStep {
    /// The page's title (board 03: title case).
    var pageTitle: String {
        switch self {
        case .runner: AppLocalization.text("Install Poki Runner")
        case .developerMode: AppLocalization.text("Turn On Developer Mode")
        case .loopback: AppLocalization.text("Connect to this iPhone")
        case .pairing: AppLocalization.text("Pair This iPhone")
        case .automation: AppLocalization.text("Allow UI Automation")
        case .background: AppLocalization.text("Keep Poki Running")
        }
    }

    var pageSummary: LocalizedStringKey {
        switch self {
        case .runner: "The helper app that taps and types for your agent. Poki starts it; you never open it."
        case .developerMode: SetupStep.inProcess ? "Allows Poki to use this iPhone’s developer services." : "Allows this iPhone to run Poki Runner."
        case .loopback: "Allows Poki to use this iPhone’s developer services."
        case .pairing: "Gives Poki its own key to this iPhone. The key stays on this device."
        case .automation: SetupStep.inProcess ? "Allows Poki to control other apps." : "Allows Poki Runner to control other apps."
        case .background: "Keeps Poki connected in the background and shows its activity on the Lock Screen."
        }
    }
}

/// Opens Settings with the step in the Live Activity.
@MainActor func openSettings(_ model: AppModel, for step: SetupStep?) {
    if let step { model.guide(step) }
    if let url = settingsURL(for: step) { UIApplication.shared.open(url) }
}

func settingsURL(for step: SetupStep?) -> URL? {
    // 系统配置步骤打开设置首页；后台权限等步骤仍打开 Poki 的 App 权限页。
    switch step {
    case .runner?, .developerMode?, .pairing?, .automation?:
        return URL(string: "App-prefs:")
    default:
        return URL(string: UIApplication.openSettingsURLString)
    }
}

private struct InstructionsCard: View {
    var lines: [String]
    var body: some View {
        NumberedLines(lines: lines).padding(16).glassCard()
            .padding(.horizontal, 20).padding(.top, 24)
    }
}

/// Open Settings and the switch for a step the phone can't check.
private struct ConfirmCard: View {
    @Environment(AppModel.self) private var model
    var step: SetupStep
    var title: LocalizedStringKey
    @Binding var isOn: Bool
    var body: some View {
        VStack(spacing: 0) {
            OpenSettingsRow(step: step)
            Toggle(isOn: $isOn) { Text(title).site(17, line: 22).frame(maxWidth: .infinity, alignment: .leading) }
                .toggleStyle(SiteToggleStyle())
                .padding(.vertical, 10).padding(.horizontal, 16)
        }
        .glassCard()
        .padding(.horizontal, 20).padding(.top, 20)
    }
}

private struct OpenSettingsRow: View {
    @Environment(AppModel.self) private var model
    var step: SetupStep
    var divider = true
    var body: some View {
        Button { openSettings(model, for: step) } label: {
            HStack(spacing: 10) {
                Image(systemName: "gear").font(.system(size: 17)).frame(width: 18)
                Text("Open Settings").site(17, line: 22).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 13).padding(.horizontal, 16).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { if divider { Site.edge.frame(height: 1) } }
    }
}

/// A row of plain text actions inside a glass card: "Import Pairing File ›", "Cancel Pairing".
private struct GlassActionRow: View {
    var title: LocalizedStringKey
    var color: Color = Site.text
    var chevron = false
    var divider = true
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).site(17, line: 22).foregroundStyle(color)
                Spacer()
                if chevron { Text(verbatim: "›").site(17, line: 22).foregroundStyle(Site.c4) }
            }
            .padding(.vertical, 13).padding(.horizontal, 16).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { if divider { Site.edge.frame(height: 1) } }
    }
}

private struct SectionCaption: View {
    var text: LocalizedStringKey
    var body: some View {
        Text(text).site(13, line: 16).foregroundStyle(Site.c4)
            .padding(.leading, 36).padding(.trailing, 20).padding(.top, 24).padding(.bottom, 8)
    }
}

/// An icon and a sentence on the blue: a problem, a state.
private struct NoteLine: View {
    var symbol: String
    var color: Color = Site.text
    var text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(color)
            Text(text).site(15, line: 20).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: 3, loopback

/// The embedded VPN and its live check share the same controls in Setup and the first-run guide.
private struct LoopbackPage: View {
    @Environment(AppModel.self) private var model
    @State private var confirmsSwitch = false

    var body: some View {
        if model.isLocalVPNAvailable {
            builtInSection
                .task { await model.connectBuiltInVPN(automatically: true) }
            if model.tunnel.connected || localReady { connectionStatus }
        } else {
            Section {
                Label("The built-in VPN is unavailable in this installation. Reinstall the signed myai app.",
                      systemImage: "exclamationmark.triangle")
            }
        }
    }

    private var builtInSection: some View {
        Section {
            if case .failed(let message) = model.tunnel.state {
                Label(Issue.localizedProblem(message), systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            switch model.tunnel.state {
            case .connecting:
                LabeledContent("Built-in Connection") { ProgressView() }
                Button("Cancel Connection", role: .destructive) { model.tunnel.disconnect() }
                    .disabled(model.connectionInUse)
            case .connected:
                LabeledContent("Built-in Connection", value: AppLocalization.text(LocalizedStringResource("Connected")))
                Button("Disconnect Local Connection") { model.tunnel.disconnect() }.disabled(connectionLocked)
            case .disconnecting:
                LabeledContent("Built-in Connection") { ProgressView() }
            case .failed, .off, .unavailable:
                Button("Enable Local Connection") {
                    if model.tunnel.anotherVPNIsOn() { confirmsSwitch = true } else { connect() }
                }
                .fontWeight(.semibold)
                .disabled(connectionLocked)
                .accessibilityIdentifier("loopback.enableBuiltIn")
                .confirmationDialog("Enable Local Connection", isPresented: $confirmsSwitch, titleVisibility: .visible) {
                    Button("Enable Local Connection", action: connect)
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Enabling Poki’s local connection may disconnect your current VPN.")
                }
            }
        } footer: {
            Group {
                if model.connectionInUse {
                    Text("Stop Poki and finish pairing before changing the local connection.")
                } else if !model.tunnel.connected {
                    Text("When iOS asks to add the myai VPN configuration, tap Allow.")
                }
            }
            .settingsFooter()
        }
    }

    private var connectionLocked: Bool { model.connectionInUse || model.tunnel.busy }

    private func connect() {
        Task { await model.connectBuiltInVPN() }
    }

    private var localReady: Bool {
        !model.loopback.isWorking && model.localSessionTrouble == nil
            && (model.hasOpenInProcessSession || model.runner.code == "local_ddi" || model.mountedImageStandsIn)
    }

    private var connectionStatus: some View {
        let monitor = model.loopback
        return Section {
            LabeledContent {
                if monitor.state == .checking && !localReady { ProgressView() }
            } label: {
                Label {
                    Text(localReady ? "Local automation ready" : headline(monitor))
                } icon: {
                    if localReady {
                        Image(systemName: "iphone").foregroundStyle(.secondary)
                    } else {
                        Image(systemName: monitor.isWorking ? "checkmark.circle.fill" : monitor.state == .noAnswer ? "exclamationmark.triangle.fill" : "circle.dashed")
                            .foregroundStyle(monitor.isWorking ? Color.green : monitor.state == .noAnswer ? Color.orange : Color.secondary)
                    }
                }
            }
            .accessibilityIdentifier("loopback.check")
        } header: {
            Text("Check").settingsHeader()
        } footer: {
            Group {
                if model.servicesSilent, monitor.isWorking {
                    Text("Reconnect the local connection, then try pairing again.")
                } else if monitor.isWorking {
                    Text("It works. You are done with this step.")
                } else if let trouble = model.localSessionTrouble {
                    Text(verbatim: trouble.text)
                } else if localReady {
                    Text("The network loopback is unavailable.")
                } else if monitor.state != .checking {
                    Text("Reconnect the local connection, then try pairing again.")
                }
            }
            .settingsFooter()
        }
    }

    private func headline(_ monitor: LoopbackMonitor) -> LocalizedStringKey {
        switch monitor.state {
        case .working: "Loopback Is On"
        case .noAnswer: "Tunnel On, No Answer"
        case .checking: "Checking…"
        case .off: "Off"
        }
    }
}

// MARK: 4, pairing

private struct PairingPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var importing = false
    @State private var importError: String?
    @State private var scanning = false

    var body: some View {
        if model.isDone(.pairing) && !model.pairingUnderWay {
            Section {
                Label(model.pairingVerifiedAt.map { AppLocalization.text(LocalizedStringResource("Paired. The phone accepted it at \($0.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(AppLocalization.locale))).")) }
                      ?? AppLocalization.text(LocalizedStringResource("Paired. Checked the next time the runner starts.")), systemImage: "checkmark.seal.fill")
            }
        } else if model.supportsOnDevicePairing {
            onDevicePairing
                .task(id: model.loopback.isWorking) { model.preparePairingIfNeeded() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.preparePairingIfNeeded() }
                }
        } else {
            Section("How To") {
                Label("Pairing on the phone itself needs iOS 27; this iPhone runs iOS \(UIDevice.current.systemVersion). Pair it from a computer instead.", systemImage: "1.circle")
                Label("Open **Poki Setup** on your Mac or PC, connect this iPhone by cable, and tap **Pair**. Tap **Trust** on the iPhone when asked.", systemImage: "2.circle")
                Label("Tap **Scan Pairing Code** in myai to scan the code on your computer, or tap **Import Pairing File** to open a saved file.", systemImage: "3.circle")
            }
        }
        Section {
            if model.supportsOnDevicePairing {
                DisclosureGroup("Other Ways") { imports }
            } else {
                imports
            }
        } footer: {
            if let importError { Text(importError).foregroundStyle(.red) }
            if let note = model.pairingNote { Text(note) }
        }
        .sheet(isPresented: $scanning) { PairingScannerSheet() }
        .task { await model.watchForHandedPairing() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.propertyList, .xml, .data]) { result in
            do { try model.importPairingFile(from: result.get()); importError = nil }
            catch let error as CocoaError where error.code == .userCancelled { }
            catch { importError = AppLocalization.text(LocalizedStringResource("Invalid Pairing File: \(error.localizedDescription)")) }
        }
        Section { diskImage } header: { Text("Developer Disk Image") }
    }

    private var onDevicePairing: some View {
        Section {
            if model.canOpenPairingSettings {
                if let pin = model.pairingPIN {
                    PairingCodeText(pin: pin)
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                    Text("Enter this code in Settings.")
                } else {
                    Text("Waiting for the iPhone to request a code.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("pairing.awaitingChallenge")
                    Text("In Settings, open Privacy & Security › Developer Mode and choose Pair with myai.")
                        .accessibilityIdentifier("pairing.settingsInstructions")
                    Text("If iPhone asks for its passcode, enter the one you use to unlock it. When Settings requests the pairing code, it appears here and in the Dynamic Island.")
                        .accessibilityIdentifier("pairing.islandHint")
                }
                Button("Open Settings", systemImage: "gear") { openSettings(model, for: .pairing) }
                    .accessibilityIdentifier("pairing.openSettings")
            } else if case .failed(let reason)? = model.pairing {
                Text(Issue.localizedProblem(reason)).foregroundStyle(.secondary)
                retry
                if reason == RustPairing.publicationFailure {
                    Button("Open Settings") { openSettings(model, for: nil) }
                }
            } else if model.firstRunPairingNeedsRetry {
                retry
            } else if !model.loopback.isWorking && !model.pairingUnderWay {
                Text("Enable a local connection in Setup and wait for the connection check to pass, then try pairing again.")
                NavigationLink("Connection Settings", value: SetupStep.loopback)
            } else {
                ProgressView("Getting ready to pair…")
                    .accessibilityIdentifier("pairing.waitingForPublication")
                Text("Allow Local Network access if iOS asks.")
            }
            if model.pairingUnderWay {
                Button("Cancel Pairing", role: .cancel) { model.cancelPairing() }
                    .accessibilityIdentifier("pairing.cancel")
            }
        } header: {
            if model.pairingPIN != nil { Text("Pairing Code") }
        }
    }

    private var retry: some View {
        Button("Try Again") { model.startPairing() }
            .accessibilityIdentifier("pairing.retry")
    }

    @ViewBuilder private var imports: some View {
        if PairingScanner.available {
            Button("Scan Pairing Code", systemImage: "qrcode.viewfinder") { scanning = true }
        }
        Button("Import Pairing File", systemImage: "doc.badge.plus") { importing = true }
        if model.supportsOnDevicePairing && model.isDone(.pairing) && !model.pairingUnderWay {
            Button("Pair Again", systemImage: "arrow.triangle.2.circlepath") { model.startPairing() }
        }
    }

    @ViewBuilder private var diskImage: some View {
        switch model.diskImage.state {
        case .ready:
            LabeledContent("Status", value: AppLocalization.text(LocalizedStringResource("Ready")))
        case .downloaded:
            if model.isDone(.pairing) {
                LabeledContent("Status", value: AppLocalization.text(LocalizedStringResource("Downloaded, not available")))
                Text(DiskImageStore.unavailableMessage).font(.footnote).foregroundStyle(.orange)
            } else {
                LabeledContent("Status", value: AppLocalization.text(LocalizedStringResource("Downloaded")))
            }
        case .downloading(let step):
            LabeledContent("Downloading") { HStack { Text(verbatim: "\(step)"); ProgressView() } }
        case .missing:
            if model.diskImage.isChecking {
                LabeledContent("Status") { HStack { Text("Checking…").foregroundStyle(.secondary); ProgressView() } }
            } else {
                Button("Download Developer Disk Image") { Task { await model.diskImage.download() } }
            }
        case .failed(let why):
            Label(why, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            Button("Download Again") { Task { await model.diskImage.download() } }
        }
    }
}

// MARK: 6, background

private struct BackgroundPage: View {
    @Environment(AppModel.self) private var model
    @State private var choosingAlways = false

    var body: some View {
        let background = model.background
        Section {
            Button(action: location) {
                SettingsRow(title: "Location", symbol: "location", value: locationValue,
                            warns: background.allowed && !background.always || background.denied,
                            valueIsAction: background.authorization == .notDetermined,
                            accessory: background.always ? .done : nil)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("background.location")
            Button { if !model.activitiesEnabled { openSettings(model, for: .background) } } label: {
                SettingsRow(title: "Live Activities", symbol: "platter.filled.bottom.iphone",
                            value: model.activitiesEnabled ? nil : AppLocalization.text(LocalizedStringResource("Off")),
                            warns: !model.activitiesEnabled, accessory: model.activitiesEnabled ? .done : nil)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("background.activities")
        } footer: {
            Group {
                Text("Poki never records your location.")
            }
            .settingsFooter()
        }
        .onChange(of: background.authorization) { _, _ in
            if !background.always { choosingAlways = true }
        }
        .alert("Choose Always", isPresented: $choosingAlways) {
            Button("Open Settings") { openSettings(model, for: .background) }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("Poki counts this as set up only with Always, and never records your location.")
        }
    }

    private var locationValue: String? {
        let background = model.background
        if background.always { return nil }
        if background.authorization == .notDetermined { return AppLocalization.text(LocalizedStringResource("Allow")) }
        if background.denied { return AppLocalization.text(LocalizedStringResource("Off")) }
        return AppLocalization.text(LocalizedStringResource("While Using"))
    }

    /// Before iOS asked, the request; after, the popup that sends the owner to Settings.
    private func location() {
        let background = model.background
        if background.always { return }
        if background.authorization == .notDetermined { background.requestPermission() } else { choosingAlways = true }
    }
}

// MARK: Checklist

/// Setup as one checklist: everything Poki needs to run on this iPhone, each with a tick or what is
/// wrong, and a tap opens its fix. It is on the Chats page (the steps still open) and in the Poki tab.
struct SetupChecklist: View {
    @Environment(AppModel.self) private var model
    @Environment(\.pokiDetailsOpen) private var detailsOpen
    @State private var guiding = false

    var body: some View {
        List {
            Section {
                ForEach(SetupStep.shown) { step in
                    NavigationLink(value: step) { SetupStepRow(step: step) }
                }
            } footer: {
                Text(SetupStep.requiredForPhone.allSatisfy(model.setupStepVerified) ? "Everything Poki needs is in place." : "Background location is optional. Phone controls use the verified connection and system permissions.")
            }
            SigningSection()
            Section {
                Button { guiding = true } label: { Label("Setup Guide", systemImage: "list.number") }
            } footer: {
                Text("Walks through every item in order. You can close it at any time and pick up from this list.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(AppLocalization.text("Setup"))
        .onAppear { model.loopback.resume() }
        .sheet(isPresented: $guiding, onDismiss: {
            if model.pairingUnderWay { model.cancelPairing() }
        }) { SetupGuide(start: SetupStep.shown.first { !model.isDone($0) }) }
        .background(EmptyView().sheet(isPresented: Binding(get: { model.signer.needsCodeSheet && !detailsOpen }, set: { model.signer.needsCodeSheet = $0 })) { VerificationCodeSheet() })
    }
}

/// One item: its symbol, its name, and Done or what is wrong.
struct SetupStepRow: View {
    @Environment(AppModel.self) private var model
    var step: SetupStep

    var body: some View {
        let done = model.setupStepVerified(step)
        LabeledContent {
            if step == .loopback && !model.loopback.isWorking && done {
                Text("Local automation ready").foregroundStyle(.secondary)
            } else if step == .loopback && model.loopback.state == .checking && model.setup.loopback != .none {
                Text("Checking…").foregroundStyle(.secondary)
            } else if done {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel(Text("Done"))
            } else {
                Text(problem).foregroundStyle(.orange)
            }
        } label: {
            Label(step.pageTitle, systemImage: step.symbol)
        }
    }

    private var problem: String {
        switch step {
        case .loopback:
            if model.loopback.state == .noAnswer { return AppLocalization.text(LocalizedStringResource("No Answer")) }
            return model.setup.loopback == .none ? AppLocalization.text(LocalizedStringResource("Needed")) : AppLocalization.text(LocalizedStringResource("Off"))
        case .pairing:
            if model.pairingTrouble != nil { return AppLocalization.text(LocalizedStringResource("Pair Again")) }
            if model.diskImage.isChecking { return AppLocalization.text(LocalizedStringResource("Checking…")) }
            if model.pairingPath != nil, !model.diskImage.hasFiles { return AppLocalization.text(LocalizedStringResource("Downloading")) }
            return AppLocalization.text(LocalizedStringResource("Needed"))
        default: return AppLocalization.text(LocalizedStringResource("Needed"))
        }
    }
}

/// One item's page: what it is for, how to do it, and its check or switch.
struct SetupStepPage: View {
    @Environment(AppModel.self) private var model
    var step: SetupStep
    var hero = false

    var body: some View {
        switch step {
        case .runner, .developerMode, .automation: formPage
        default: cardPage
        }
    }

    /// The steps the phone can't check: a native form with the steps, Open Settings and the switch.
    private var formPage: some View {
        Form {
            if hero {
                StartHero(symbol: step.symbol, title: step.rowTitle, line: step.pageSummary, done: model.setupStepVerified(step))
            } else {
                Section {
                    LabeledContent {
                        Text(model.isDone(step) ? "Done" : "Needed").foregroundStyle(model.isDone(step) ? Color.green : Color.orange)
                    } label: {
                        Label(step.pageTitle, systemImage: step.symbol)
                    }
                } footer: {
                    Text(step.pageSummary)
                }
            }
            Section("How To") {
                ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                    Label { Text(LocalizedStringKey(line)) } icon: { Image(systemName: "\(i + 1).circle") }
                }
            }
            Section {
                if !hero {
                    Button("Open Settings", systemImage: "gear") { openSettings(model, for: step) }
                }
                Toggle(confirmTitle, isOn: confirmBinding)
            } footer: {
                Text("iOS doesn’t let Poki check this one, so turn the switch on once it’s done.")
            }
        }
        .navigationTitle(hero ? "" : step.pageTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.loopback.resume() }
    }

    private var lines: [String] {
        switch step {
        case .runner: [
            "Install **Poki Runner** (poki-runner-unsigned.ipa) with the same tool and Apple ID you used for Poki.",
            "Open **Settings › General › VPN & Device Management**, tap your Apple ID, then tap **Trust**.",
            "Don’t open Poki Runner yourself. Poki starts it when an agent needs this iPhone.",
        ]
        case .developerMode: [
            SetupStep.inProcess ? "Open **Settings › Privacy & Security › Developer Mode**." : "Open **Settings › Privacy & Security › Developer Mode**. It appears once Poki Runner is installed.",
            "Turn on Developer Mode, then tap **Restart**.",
            "After restarting, unlock this iPhone and tap **Turn On**.",
        ]
        default: [
            "Open **Settings › Developer**. It appears once Developer Mode is on.",
            "Turn on **Enable UI Automation**.",
        ]
        }
    }

    private var confirmTitle: LocalizedStringKey {
        switch step {
        case .runner: "Poki Runner Is Installed and Trusted"
        case .developerMode: "Developer Mode Is On"
        default: "UI Automation Is On"
        }
    }

    private var confirmBinding: Binding<Bool> {
        switch step {
        case .runner: binding(\.runnerInstalled)
        case .developerMode: binding(\.developerMode)
        default: binding(\.uiAutomation)
        }
    }

    /// Loopback, pairing and background: the same native form, with their live sections.
    private var cardPage: some View {
        Form {
            if hero {
                StartHero(symbol: step.symbol, title: step.rowTitle, line: step.pageSummary, done: model.setupStepVerified(step))
            } else {
                Section {
                    LabeledContent {
                        if step == .loopback && model.loopback.state == .checking && model.setup.loopback != .none {
                            Text("Checking…").foregroundStyle(.secondary)
                        } else {
                            Text(model.setupStepVerified(step) ? "Done" : "Needed").foregroundStyle(model.setupStepVerified(step) ? Color.green : Color.orange)
                        }
                    } label: {
                        Label(step.pageTitle, systemImage: step.symbol)
                    }
                } footer: {
                    Text(step.pageSummary)
                }
            }
            content
        }
        .navigationTitle(hero ? "" : step.pageTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.loopback.resume() }
    }

    private func binding(_ key: WritableKeyPath<SetupState, Bool>) -> Binding<Bool> {
        Binding(get: { model.setup[keyPath: key] }, set: { model.setup[keyPath: key] = $0 })
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .runner:
            InstructionsCard(lines: [
                "Install **Poki Runner** (poki-runner-unsigned.ipa) with the same tool and Apple ID you used for Poki.",
                "Open **Settings › General › VPN & Device Management**, tap your Apple ID, then tap **Trust**.",
                "Don’t open Poki Runner yourself. Poki starts it when an agent needs this iPhone.",
            ])
            ConfirmCard(step: .runner, title: "Poki Runner is installed and trusted", isOn: binding(\.runnerInstalled))
        case .developerMode:
            InstructionsCard(lines: [
                SetupStep.inProcess ? "Open **Settings › Privacy & Security › Developer Mode**." : "Open **Settings › Privacy & Security › Developer Mode**. It appears once Poki Runner is installed.",
                "Turn on Developer Mode, then tap **Restart**.",
                "After restarting, unlock this iPhone and tap **Turn On**.",
            ])
            ConfirmCard(step: .developerMode, title: "Developer Mode is on", isOn: binding(\.developerMode))
        case .loopback: LoopbackPage()
        case .pairing: PairingPage()
        case .automation:
            InstructionsCard(lines: [
                "Open **Settings › Developer**. It appears once Developer Mode is on.",
                "Turn on **Enable UI Automation**.",
            ])
            ConfirmCard(step: .automation, title: "UI Automation is on", isOn: binding(\.uiAutomation))
        case .background: BackgroundPage()
        }
    }
}

/// The setup guidance as a walk through every item, from the first one still open. Close leaves it at
/// any time; the checklist keeps what is done.
struct SetupGuide: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var index: Int

    init(start: SetupStep?) {
        _index = State(initialValue: start.flatMap { SetupStep.shown.firstIndex(of: $0) } ?? 0)
    }

    private var steps: [SetupStep] { SetupStep.shown }

    var body: some View {
        NavigationStack {
            SetupStepPage(step: steps[index])
                .id(steps[index])
                .onChange(of: index) { old, _ in
                    if steps[old] == .pairing, model.pairingUnderWay { model.cancelPairing() }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button("Back", systemImage: "chevron.left") { index -= 1 }.disabled(index == 0)
                        Spacer()
                        Text("\(index + 1) of \(steps.count)").font(.footnote).foregroundStyle(Color(.secondaryLabel))
                        Spacer()
                        if index + 1 < steps.count {
                            Button("Next", systemImage: "chevron.right") { index += 1 }
                        } else {
                            Button("Done") { dismiss() }.bold()
                        }
                    }
                }
        }
    }
}
