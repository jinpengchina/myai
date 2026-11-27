import AVFoundation
import SwiftUI

/// What an earlier version of Poki left on this phone. None of it is written by this version before
/// launch has read it, so it tells an update (or a reinstall the Keychain restored) from a fresh install:
/// a saved conversation, or a setting an earlier version stored (setup progress, the relay, the model,
/// approvals, voice).
enum EarlierVersion {
    nonisolated static func leftTraces(defaults: UserDefaults, sessionsFolder: URL) -> Bool {
        let settings = ["setup", "relayAddress", "relayEnabled", "chat.provider", "chat.installationID", "approvals.ask", "wantsOn", "voice.model", WhatsNew.seenVersionKey]
        let conversations = (try? FileManager.default.contentsOfDirectory(at: sessionsFolder, includingPropertiesForKeys: nil))?
            .contains { $0.pathExtension == "json" } ?? false
        return conversations || settings.contains { defaults.object(forKey: $0) != nil }
    }
}

/// The same setup can be resumed from the chat or Settings after the first launch.
enum FirstRun {
    /// Absent until the first launch of a version with the first run decides it, once.
    static let key = "pokiFirstRun"
    enum Record: String { case due, done }

    /// Call at launch before anything this version writes to the defaults.
    nonisolated static func decide(defaults: UserDefaults = .standard, sessionsFolder: URL = SessionStore.defaultFolder) {
        guard defaults.string(forKey: key) == nil else { return }
        let record: Record = EarlierVersion.leftTraces(defaults: defaults, sessionsFolder: sessionsFolder) ? .done : .due
        defaults.set(record.rawValue, forKey: key)
    }

    /// Whether to show it at this launch. Scripted launches (the in-app tests, the screenshot and check
    /// scripts, which all pass `-poki…` arguments) have nobody to go through it; `-pokiScreen welcome` asks
    /// for it.
    static func isDue(defaults: UserDefaults = .standard) -> Bool {
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        if arguments["pokiScreen"] as? String == "welcome" { return true }
        if ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil { return false }
        if arguments.keys.contains(where: { $0.hasPrefix("poki") }) { return false }
        return defaults.string(forKey: key) == Record.due.rawValue
    }

    private static let quickStartKey = "ailoveQuickStartSeen"

    /// An update with unfinished setup gets the new guide once. Explicitly leaving it for the chat
    /// keeps that choice on later launches. A working installation goes straight to its chat.
    static func shouldPresent(needsSetup: @autoclosure () -> Bool, defaults: UserDefaults = .standard) -> Bool {
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        if arguments["pokiScreen"] as? String == "welcome" { return true }
        guard ProcessInfo.processInfo.environment["XCTestBundlePath"] == nil,
              !arguments.keys.contains(where: { $0.hasPrefix("poki") }) else { return false }
        return resumeIfNeeded(needsSetup: needsSetup(), defaults: defaults)
    }

    static func resumeIfNeeded(needsSetup: @autoclosure () -> Bool, defaults: UserDefaults) -> Bool {
        if defaults.string(forKey: key) == Record.due.rawValue { return true }
        guard !defaults.bool(forKey: quickStartKey) else { return false }
        if needsSetup() {
            defaults.set(Record.due.rawValue, forKey: key)
            return true
        }
        defaults.set(true, forKey: quickStartKey)
        return false
    }

    static func finish(defaults: UserDefaults = .standard) {
        defaults.set(Record.done.rawValue, forKey: key)
        defaults.set(true, forKey: quickStartKey)
    }
}

extension NavigationPath {
    /// Check the actual stack, including subpages over pairing, without serializing its heterogeneous routes.
    var containsPairingStep: Bool {
        var remaining = self
        while !remaining.isEmpty {
            let original = remaining
            remaining.removeLast()
            var pairing = remaining
            pairing.append(SetupStep.pairing)
            if pairing == original { return true }
        }
        return false
    }
}

extension EnvironmentValues {
    @Entry var openQuickSetup: () -> Void = {}
}

struct FirstRunGuide: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Binding var link: SetupStep?
    var startVoice: () -> Void
    var done: () -> Void

    @State private var expanded: Row?
    @State private var sheet: AccountSheet?
    @State private var voiceReady = false
    @State private var microphone = AVAudioApplication.shared.recordPermission
    @State private var askingForMicrophone = false

    private enum Row: String, CaseIterable, Identifiable {
        case vpn, pairing, voice, controls, microphone
        var id: String { rawValue }

        var title: String {
            switch self {
            case .vpn: "Built-in VPN"
            case .pairing: "Device pairing"
            case .voice: "Voice account"
            case .controls: "UI Automation"
            case .microphone: "Microphone"
            }
        }

        init?(step: SetupStep) {
            switch step {
            case .loopback: self = .vpn
            case .pairing: self = .pairing
            case .runner, .developerMode, .automation: self = .controls
            case .background: return nil
            }
        }
    }

    private enum AccountSheet: String, Identifiable {
        case chatGPT, other
        var id: String { rawValue }
    }

    var body: some View {
        let step = model.firstRunPhoneStep
        let current = currentRow(for: step)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                heading
                    .padding(.bottom, 8)
                ForEach(Row.allCases) { row in
                    checklistRow(row, current: current, step: step)
                }
            }
            .frame(maxWidth: 480)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.top)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                primaryAction(current: current, step: step)
            }
            .frame(maxWidth: 480)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Color.black)
        }
        .background { Color.black.ignoresSafeArea() }
        .foregroundStyle(Color.white)
        .tint(.white)
        .environment(\.locale, Locale(identifier: "en_US"))
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
        .onAppear(perform: refreshStatus)
        .onReceive(NotificationCenter.default.publisher(for: ModelKeys.changed)) { _ in refreshStatus() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshStatus() }
        }
        .onChange(of: current, initial: true) { _, row in
            expanded = row
        }
        .onChange(of: model.pairingPIN) { _, pin in
            if current == .pairing, pin != nil { expanded = .pairing }
        }
        .onChange(of: link, initial: true) { _, step in
            guard let step else { return }
            link = nil
            if let row = Row(step: step) { expanded = row }
        }
        .sheet(item: $sheet, onDismiss: refreshStatus) { sheet in
            switch sheet {
            case .chatGPT:
                ChatGPTSignIn(startInBrowser: true, onSignedIn: refreshStatus)
            case .other:
                NavigationStack {
                    ModelSettingsView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { self.sheet = nil }
                            }
                        }
                }
            }
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer()
                Button("Set Up Later", action: done)
                    .buttonStyle(.plain)
                    .font(.subheadline)
                    .padding(.vertical, 8)
                    .accessibilityIdentifier("firstRun.finishLater")
            }
            Text("Set up ailove")
                .font(.largeTitle.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("firstRun.checklist")
            let completed = Row.allCases.filter(isComplete).count
            Text("\(completed) of \(Row.allCases.count) complete")
                .font(.subheadline)
        }
    }

    private func checklistRow(_ row: Row, current: Row, step: SetupStep?) -> some View {
        let isExpanded = expanded == row
        let isCurrent = current == row
        let complete = isComplete(row)
        let status = status(for: row, complete: complete)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded = isExpanded ? nil : row
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: complete ? "checkmark.circle.fill" : "circle")
                        .font(.subheadline)
                        .foregroundStyle(Color.white.opacity(complete || isCurrent ? 1 : 0.4))
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            Text(verbatim: row.title).font(.headline).fixedSize()
                            Spacer(minLength: 4)
                            Text(verbatim: status).font(.footnote).fixedSize()
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: row.title).font(.headline)
                            Text(verbatim: status).font(.footnote)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                }
                .frame(minHeight: 48)
                .padding(.horizontal, 14)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: row.title))
            .accessibilityValue(Text(verbatim: status))
            .accessibilityHint(isExpanded ? Text("Collapses the step") : Text("Expands the step"))
            .accessibilityIdentifier("firstRun.row.\(row.rawValue)")

            if isCurrent || isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    Rectangle().fill(Color(white: 0.25)).frame(height: 1).accessibilityHidden(true)
                    details(for: row, current: isCurrent, complete: complete, step: step)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
                // Keep the active step mounted when a user expands a different row.
                .frame(height: isExpanded ? nil : 0, alignment: .top)
                .clipped()
                .opacity(isExpanded ? 1 : 0)
                .accessibilityHidden(!isExpanded)
                .allowsHitTesting(isExpanded)
            }
        }
        .background(Color(white: 0.065), in: RoundedRectangle(cornerRadius: 15))
        .overlay {
            RoundedRectangle(cornerRadius: 15)
                .strokeBorder(Color(white: isCurrent ? 0.48 : 0.25), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func details(for row: Row, current: Bool, complete: Bool, step: SetupStep?) -> some View {
        if current, let step, Row(step: step) == row {
            FirstRunConnectionStep(step: step)
        } else {
            switch row {
            case .vpn:
                Text(complete ? "ailove is connected using its built-in VPN." : "The built-in VPN connects automatically. Tap Allow if iOS asks to add a VPN configuration.")
            case .pairing:
                Text(complete ? "This iPhone is paired with ailove." : "Connect the built-in VPN to start pairing this iPhone.")
            case .voice:
                if complete {
                    Text("Your voice account is ready.")
                } else if current {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Connect your ChatGPT account to use live voice.")
                        Button("Other Voice Accounts") { sheet = .other }
                            .buttonStyle(.plain)
                            .underline()
                            .accessibilityIdentifier("firstRun.voice.other")
                    }
                } else {
                    Text("Pair this iPhone before connecting a voice account.")
                }
            case .controls:
                Text(complete ? "ailove can operate apps on this iPhone." : "ailove checks the system settings for phone control after you connect a voice account.")
            case .microphone:
                if complete {
                    Text("The microphone is ready. Start voice control to give your first command.")
                } else if microphone == .denied {
                    Text("Allow microphone access in Settings, then return here to start voice control.")
                } else {
                    Text("iOS asks for microphone access when you start voice control.")
                }
            }
        }
    }

    @ViewBuilder
    private func primaryAction(current: Row, step: SetupStep?) -> some View {
        if let step, Row(step: step) == current {
            FirstRunPhoneAction(step: step)
        } else if current == .voice {
            Button("Continue with ChatGPT", action: connectChatGPT)
                .buttonStyle(FirstRunPrimaryButtonStyle())
                .accessibilityIdentifier("firstRun.voice.signIn")
        } else if current == .microphone {
            if microphone == .denied {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(FirstRunPrimaryButtonStyle())
                .accessibilityIdentifier("firstRun.microphone.settings")
            } else {
                Button("Start Voice Control", action: requestMicrophoneAndStart)
                    .buttonStyle(FirstRunPrimaryButtonStyle())
                    .disabled(askingForMicrophone)
                    .accessibilityIdentifier("firstRun.voice.start")
            }
        }
    }

    private func currentRow(for step: SetupStep?) -> Row {
        if step == .loopback { return .vpn }
        if step == .pairing { return .pairing }
        if !voiceReady { return .voice }
        if let step, let row = Row(step: step) { return row }
        return .microphone
    }

    private func isComplete(_ row: Row) -> Bool {
        switch row {
        case .vpn: model.setupStepVerified(.loopback)
        case .pairing: model.setupStepVerified(.pairing)
        case .voice: voiceReady
        case .controls:
            model.setupStepVerified(.developerMode) && model.setupStepVerified(.automation)
                && (SetupStep.inProcess || model.setupStepVerified(.runner))
        case .microphone: microphone == .granted
        }
    }

    private func status(for row: Row, complete: Bool) -> String {
        switch row {
        case .vpn:
            if complete { return "Connected" }
            if !model.isLocalVPNAvailable || model.firstRunVPNFailure != nil { return "Action needed" }
            return "Connecting"
        case .pairing:
            if complete { return "Paired" }
            if model.pairingPIN != nil { return "Code ready" }
            if model.pairingPublished || model.firstRunPairingNeedsRetry { return "Action needed" }
            return isComplete(.vpn) ? "Preparing" : "Pending"
        case .voice: return complete ? "Connected" : "Not connected"
        case .controls:
            return complete ? "Ready" : model.checkingFirstRunPhone ? "Checking" : "Pending check"
        case .microphone:
            if complete { return "Allowed" }
            return microphone == .denied ? "Action needed" : "Allow when starting voice"
        }
    }

    private func refreshStatus() {
        voiceReady = model.voice.canTalkLive
        microphone = AVAudioApplication.shared.recordPermission
    }

    private func connectChatGPT() {
        if model.voice.hasChatGPTVoiceAccount {
            ModelKeys.setSelectedProvider(.chatgpt, in: model.storage)
            refreshStatus()
        } else {
            sheet = .chatGPT
        }
    }

    private func requestMicrophoneAndStart() {
        guard !askingForMicrophone else { return }
        askingForMicrophone = true
        Task {
            let allowed = await AVAudioApplication.requestRecordPermission()
            askingForMicrophone = false
            refreshStatus()
            if allowed { startVoice() }
        }
    }
}

struct FirstRunPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .multilineTextAlignment(.center)
            .foregroundStyle(Color.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Color(white: configuration.isPressed ? 0.27 : 0.14),
                        in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white, lineWidth: 1) }
            .opacity(isEnabled ? 1 : 0.5)
    }
}
