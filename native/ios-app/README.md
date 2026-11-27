# Poki for iPhone

One app for everything a user does on the phone: setup (Developer Mode, on-device pairing, UI
Automation, the loopback, the first-session passcode), starting and stopping a session, the Live
Activity with Approve/Deny for sensitive actions, the MCP address for each client (text, QR, copy),
and a Debug tab (the former Poki Probe). Native SwiftUI with Liquid Glass.

Poki automates the phone in its own process: it opens the XCTest automation session itself
(`Poki/Native/InProcess.m`, answered to PokiCore by `Poki/Runtime/InProcessWDA.swift`), so Poki is
the only app to install. The older Runner path (WebDriverAgent as a second bundle, built by
`.github/workflows/ios-runner.yml`; `docs/single-bundle.md` is the earlier study) stays in the code
and is chosen per launch with `-automationPath runner`, or in General › Testing Options, which also
has the in-process probes and the Background Hold experiment (752 had them in Diagnostics).

A third path, **Native services**, is the default from iOS 27; earlier iOS versions default to the
XCTest session above, and Testing Options (Settings › Advanced) switches between the two. It uses the
paired accessibility, screenshot and HID services shared with the Mac/Linux bridge, without opening an
XCTest session or showing its automation banner. Those services stream the screen and take touches
only from iOS 27 (#1 on iOS 18.6.2 and #18 on iOS 26.6 could not tap). The normal PokiCore control
and approval logic is unchanged. Its state, screenshot and input lanes remain connected independently
while active; the Diagnostics path comparison records tap, type, swipe and parallel tree/screenshot timings against
the in-process path. Changing paths takes effect on the next app launch.

## iPhone Duo Split View

On an unfolded Duo in landscape, ask Poki in chat to work across two apps, such as dragging an
image from Safari into Notes. Poki checks whether the request benefits from Split View, opens the
two apps, and works with both visible while it runs in the background.

For a pair of apps that's already open, you can also use the **Send Task to Poki** action in
Shortcuts with **Use Split View** turned on. Both ways use Poki's usual approvals and leave the two
apps open when the task finishes.

## Layout

| Path | What |
|---|---|
| `Poki/App` | App entry (Chat and Voice pages), status words and issues, all steps, the app model (on/off, runner sleep and wake, events, approvals, pairing, setup steps) |
| `Poki/Setup` | Setup, one guided page with live checks |
| `Poki/Loopback` | Built-in VPN configuration and status, live developer-service checks |
| `Poki/Activity` | Live Activity controller (state, steps, thumbnail in the App Group) |
| `Poki/Connect` | Relay identity (Ed25519 key, label, connector secrets in the keychain), MCP address with QR |
| `Poki/Runtime` | PokiCore and PokiLauncher glue, background keep-alive (location, then silent audio) |
| `Poki/Voice` | Talk to Poki: an OpenAI Realtime session over WebRTC, the calls it asks for, test runs |
| `Poki/Debug` | 10.7.0.1 checks, the background hold test, the Live Activity preview |
| `Shared` | Live Activity attributes and views, the Approve/Deny/Stop App Intents (app and widget) |
| `PokiWidgets` | The Live Activity widget |
| `PokiTunnel` | Local-only IPv4 TCP packet tunnel; no server, DNS or internet default route |

PokiCore (Swift, `native/ios/PokiCore`) and PokiLauncher (Rust with a C ABI, `native/launcher`) are described in `docs/ios-core.md`. Poki has no default relay: the person deploys their own (`deploy/cf-relay/DEPLOY.md`) and enters its address in the Connect tab.

## Build

See the [local build and signing instructions](../../README.md#build-for-your-iphone)
for the supported ailove developer preview.

Use Xcode 27.1 or later to build and test on iPhone Duo. The iOS 27.1 SDK lets the app extend to the
edges of the unfolded display. In Split View, Poki sizes its chat and conversations drawer to the
space assigned by the system. The iOS deployment target remains unchanged.

A build made with an earlier SDK is letterboxed on both of the Duo's displays. Poki's own screen is
then the letterbox while the picture it takes is the whole panel, so every screen read is refused
(`duo_needs_ios_27_1_sdk_build`, before that `screenshot_does_not_match_active_display`, #419). The
ailove iPhone Duo builds therefore require the iOS 27.1 SDK or later.

`native/ios-app/scripts/app-tests.sh SIMULATOR_UDID` builds `PokiTests` and runs it inside Poki on a booted simulator (the in-process transport's clipboard and session answers).

### Notification permission before UI and Live Activity tests

A new simulator has no notification decision for Poki. Tests that start a session can request
permission asynchronously, leaving the system alert above later tests, even after the test app
exits. While that alert is present, Poki is inactive: a foreground-only Live Activity must not
start, and accessibility reads describe the alert instead of the preview or browser header.
An absent activity or missing localized text in this state is not a completed product check.

Use this preparation whenever the simulator is new or its notification permission was reset:

1. Record the simulator UUID and use that explicit UUID for every command; do not select a physical
   iPhone or rely on a default device. Build and install the test host, then run the session-starting
   tests with the normal runner above.
2. If a notification alert interrupts the run, preserve its screenshot and the failed log. Stop the
   test command and terminate its host with `xcrun simctl terminate SIMULATOR_UDID APP_BUNDLE_ID`.
   Read the actual bundle ID from the built app's `Info.plist`; do not guess it. The notification
   alert can remain above the simulator's Home Screen after termination.
3. On that simulator, answer the notification alert with **Don't Allow**. Denial is sufficient for
   the layout and activity-lifecycle checks; those checks do not require permission to post
   notifications. With Poki MCP, use `handle_alert` with the simulator's explicit `device` UUID and
   the observed button label. Do not answer unrelated alerts or change a real phone's permissions.
4. Confirm the alert is gone, then restart the affected tests in a fresh Poki process on the same
   simulator. Preserve the new result separately from the interrupted run. For screen-reading
   tests, check that the captured application is Poki and the expected preview or browser header
   is visible; for activity tests, Poki must be active before an activity can be created.
5. Delete only the temporary simulator after collecting logs, screenshots and XML. Repeat this
   preparation when creating another simulator; a decision on one simulator does not apply to
   another. `simctl privacy grant all` does not grant notification permission.

This procedure was checked on iOS 27.0: with the alert present the Split View stop test failed
while Poki was inactive, and the language test captured the permission alert; after denying
notifications, the unchanged 20 chat tests and the language-preview test passed. The navigation
font test is separate: English uses Geist scaled by `UIFontMetrics`, while Chinese uses the system
font. Its expected sizes must follow the chosen font rather than assume both scaling curves match.

`-pokiScreen home|setup|connect|debug|activity|steps|status|connector|details|model|voice|session|hands|rules|health|memory|appearance|voiceSettings|conversations|updates|language` opens that screen at launch (the app opens on the chat; home is the chat with the conversations drawer open, details Settings, hands and setup its Connection page, rules and health the Approvals and Advanced pages, connect the Agents page, memory, appearance, voiceSettings (Dictation & Mute), conversations (Archived Conversations) updates (Signing & Updates) and language (Language) their pages, debug Diagnostics under Advanced, steps the Activity Log, session an outside agent's session); `-pokiChat empty|working|approval|handoff|approved|failed` shows the sample chat scenes (the greeting, a task under way, a step waiting for approval, a hand-over, a finished task, a failed one) and `-pokiVoice ready|listening|working` the voice faces; `-pokiSetupStep N` opens setup at step N, `-pokiSettingsEnd YES` opens Settings scrolled to its end, and `-pokiSample B|C` fills the status, history and Live Activity with sample steps and an approval, and `-pokiSample PIN` shows a sample pairing code, for screenshots only; on a simulator `-pokiLoopback cellular` forces the cellular-only loopback hint, `-pokiLoopback working` a loopback that answers, and `-pokiSigningDays 1` a signing that ends in a day, and `-pokiAppleID name@example.com` signs in that Apple Account on Signing & Updates without contacting Apple (`-pokiAppleName`, `-pokiAppleTeams 0|1|2` and `-pokiAppleState code|reauth|expired|error` shape it).

Poki ships English, Simplified Chinese and Traditional Chinese. Settings › Language lets the owner follow the effective iOS app language or choose a Poki UI language. See [iOS UI language](../../docs/ios-localization.md) for scope and verification. The app's screens use the String Catalog `Shared/Localizable.xcstrings`, the Live Activity its own table `Shared/LiveActivity.xcstrings` (see `Shared/ActivityWords.swift`), and the permission prompts `Poki/InfoPlist.xcstrings`. Poki's own status words stay in English inside the app (the code compares them and the agent reads them) and are looked up where they reach the screen; the launcher's fix sentences have entries too. Steps an agent reports, logs and diagnostics output stay as they come. Add `-AppleLanguages '(zh-Hans)'` to a launch to see Chinese without changing the simulator's language.

## How it runs

- Poki stays on once turned on, and turns on again at launch. With the default in-process path,
  opening Poki, focusing the message field, starting dictation, choosing a shortcut, sending a
  message, and an agent connecting only prepare dependencies. They do not open an automation
  session. Pure chat and sandbox-browser tasks leave Automation Mode off; the read-only `status`
  tool also leaves it off. The first phone step opens the session and waits for it before reading
  or acting. Poki shows Preparing during this wait, then continues the same step without a model
  retry. Session timing events record submission, the open request, readiness and successful reads.
- Once opened, the session stays open while a task works, including pauses between its phone steps.
  Poki stands by when the task ends, when Poki comes to the front, or when a step hands the screen
  to the owner. An outside agent's task ends when its MCP session ends and no other agent is at work.
  The idle timeout, 60 s by default, also puts Poki on standby when an outside agent goes quiet.
  `AppModel.idleSessionPolicy` selects the standby behavior by iOS version. On iOS 18 to 26, Poki
  turns Automation Mode off and keeps the session for the next phone step. If the pause fails,
  Poki closes the session instead. On iOS 27 and later, standby closes the session as before.
  Stop, Turn Off, and an update close the session on every version, even if a pause is still in
  progress. An update waits for that close before it continues. A later phone step opens a new
  session after a close, or resumes a kept session and checks that it can still read. If a resume
  fails, Poki closes the session and tries a new one, except when opening was refused or iOS's
  passcode prompt timed out. Nothing is tapped or typed while Poki itself is in front.
  There is no Hide Banner When Idle setting.
- A new session is ready only once it has answered with an element tree. One that cannot read is
  closed, the step fails with the reason (`session_unreadable`), nothing is sent to it, and the next
  phone step opens a new session. An app that is slow to answer is not a session failure.
  Same-process close/reopen and the actual system banner must be checked on the physical release
  candidate; simulator tests do not establish either device behavior.
- If the first phone step needs the boot's first automation, Poki asks the owner before opening
  iOS's passcode screen. Only an open that iOS has held in its own allow-automation call for 3 s is treated as waiting for the passcode (a session that is slow to open or to read is not):
  the Live Activity shows Passcode for automation, Poki asks the owner, and the agent reads that only
  the owner can enter it. If opening fails, the call reports the reason and a later phone request
  may retry. A cancelled or missed passcode prompt is not opened again until the owner turns Poki
  on again. Opens go through one gate: one at a time, with no first automation from the background.
- Nothing listens on a port: PokiCore's requests are answered inside Poki.
- First-run setup starts the built-in VPN automatically. During an active session, the built-in
  connection retries after a failure or drop at intervals of 1, 2, 4, 8, 16, 30, 30 and 30 seconds.
  Recovery stops when the owner disconnects, another VPN takes over, or the app detects another VPN
  before retrying. Detection relies on system network information and can miss VPNs that set no proxy.
- Runner path only (`-automationPath runner`): the runner, and with it the banner, starts only when
  an agent asks, and stops after the idle time (default 60 s), from Stop on the Live Activity or in
  Poki, or when Poki is closed. Only Poki starts the runner; opened by hand, Poki Runner starts no
  test (PokiRunnerHost, `native/ios-runner/host`) and sends the person to Poki. While it runs, its
  HTTP and MJPEG listeners bind to `127.0.0.1`, so only software on the phone can reach it; PokiCore
  remains the approval boundary (`native/ios-runner/README.md`).
- The Live Activity starts from the foreground, because iOS does not allow it from the background:
  when Poki turns on, when pairing starts, and when a setup step opens Settings.

## Voice

Voice (the waveform beside the chat input) uses OpenAI's Live API (`gpt-live-1.1`) over WebRTC.
The microphone and speaker use audio tracks. The `oai-events` data channel carries captions and delegated tool calls.
Poki can connect with the OpenAI key in its Accounts settings. The Mac voice bridge
(`bin/voice-bridge.mjs`) can also exchange the WebRTC offer on the phone's behalf and keep its OpenAI key on the Mac.

1. Create an API key at platform.openai.com (API keys). Live sessions are billed by duration.
   Backend model usage is billed separately.
2. Keep it in the keychain, and read it from there, so it never lands in your shell history:

   ```sh
   security add-generic-password -a "$USER" -s openai-api-key -w    # asks for the key
   export OPENAI_API_KEY="$(security find-generic-password -s openai-api-key -w)"
   ```

3. Start Poki MCP first (`npm start`, see [docs/install.md](../../docs/install.md)); the bridge stops at
   once with "Local Poki MCP is not running" without it. Then, with the same state directory:

   ```sh
   POKI_MCP_STATE_DIR=... node bin/voice-bridge.mjs --device <iPhone id>
   ```

The bridge listens on every network interface (`--host 0.0.0.0`), because the phone reaches it over
the local network, in plain HTTP. Anyone who learns its address, which carries the secret, can open
sessions on your OpenAI key and move the phone through your Mac. Run it only on a network you trust,
and pass `--host <this Mac's LAN address>` to keep it off other interfaces (for example a VPN).

Enter `http://<Mac>:47830/voice/<secret>` in Voice (the secret is in `voice-bridge.json` in the
state directory). By default, Poki runs phone tools on the phone. With `--mac-tools`, the bridge
runs `open_settings`, `read_screen`, `open_app`, `tap_text`, and `go_home` through the Mac's Poki MCP.
`get_ios_version` is answered on the phone in both modes.

With the default HTTP bridge, Live voice reads visible text and numbered screen elements.
Screenshot descriptions are available with a direct OpenAI connection or an HTTPS bridge URL
with a trusted certificate. Screenshot requests to the bridge do not follow redirects.

- Each function call runs once, keyed by its `call_id`, in the app and again in the bridge.
- `tap_text` is held by Poki's approvals, like an agent's `do`: the bridge first says what it would tap
  and in which app, without tapping; the phone checks that with PokiCore's rules (payments, deleting,
  sending messages, calls) and, when they ask for it, waits up to two minutes for Allow (in the Dynamic Island, on the Live
  Activity or from the notification). Only then does the bridge tap that element, matched exactly, in that app.
- A dropped connection never repeats a confirmed request or a phone step that already started. A call outlives the session that asked for it; the next session is told how it ended instead of asking for it again. When Poki Anytime captures opening speech and the connection fails or drops before the server confirms all of it, only unconfirmed or strictly unsent audio stays on this iPhone until you run Poki Anytime again to transcribe it on-device and submit it as text (End on the Live Activity cancels it). If a phone action or reply already started without a server audio position, Poki avoids resending the prefix and posts a note asking you to check whether the rest went through.
- Tap the waveform in chat to open a continuous conversation. The app keeps listening during silence and when the phone brings the target app to the foreground. Follow-up instructions can refine the running task. Explicit stop requests cancel the pending phone work. The Live Activity reports the current step and has an End control.
- Shortcuts and one-shot voice entries keep their existing background idle timeout. Explicit End, an iOS audio interruption, or a lost voice connection closes a continuous call. Reopen it with the waveform.
  A conversation never waits for the server for ever: when it owes something (the end of the person's
  speech, an answer, the end of the audio) and the server says nothing for 60 s, or 30 s after Poki went
  to the background, it ends. A step that is running is not counted; its result starts a new wait.
- An `ailove://voice` link, from a web page or another app, only opens Voice: a link never
  changes the bridge and never turns on the microphone. The person enters the address and taps Talk
  to Poki.
- Development builds only: the launch argument `-pokiVoiceLink "poki://voice?bridge=<address>&test=1-20"`
  runs recorded utterances from a bridge started with `--test-dir`, silently: the speech goes over
  the data channel instead of the microphone, and Poki's voice is muted. Release builds have no test
  runs.

## Signing and entitlements

Fill in the ignored local signing configuration and generate the project as described in the
[iPhone build instructions](../../README.md#build-for-your-iphone). The app and tunnel extension
require the Network Extensions entitlement with `packet-tunnel-provider`. The app and widget share
an App Group derived from the chosen bundle ID. Sign all three targets with matching profiles from
your developer team.

## Built-in local connection

First-run setup starts the embedded VPN as soon as it opens. If iOS asks to add the configuration, tap **Allow**. Setup advances automatically once the phone's services answer through ailove's tunnel. If permission is declined, the setup page offers **Try Again**. Upgrading migrates an existing external VPN preference to the built-in provider.

The tunnel routes local IPv4 TCP traffic for `10.7.0.1/32`. The phone keeps its normal internet and DNS routing. iOS may switch away from another active VPN when it starts ailove's tunnel. Validate the packet tunnel on a physical iPhone.

## iPad, iPhone Duo: Poki beside the app it drives

Poki builds for iPhone and iPad (every orientation on iPad; the iPhone Duo's inner display is
regular width, laid out like an iPad). The point of the larger screens is Poki, or any agent chat,
beside the app being driven: on the Duo's inner display in landscape iOS 27.1 puts two apps side by
side (a fixed 50/50 Split View, with app pairs); on iPadOS 26 apps are resizable windows, with
Stage Manager. The in-process path keys on the driven app's frame, not on either layout: with
several apps on screen Poki's own process is never the front app, and when the front app's frame
is smaller than the screen (its half of the Duo, its window on the iPad) that frame is the viewport
(`PKInProcess.viewport`): the element tree's frames and the screenshot are relative to it,
`/wda/screen` reports its size, and touches are moved back onto the screen. An app that fills the
screen has no viewport. Not yet checked in the gym on an iPad simulator with two windows.

### Two apps beside each other with Poki in the background

On a Duo running the in-process automation path, open two different apps using iOS Split View, or
restore an existing app pair. Start Poki's automation before moving it to the background. An agent
can read one of the visible apps with `look {"pane":"left"}` or `look {"pane":"right"}`. Actions use
the most recent pane read, including its screenshot, element numbers and keyboard focus. Read the
other pane before targeting it. `look {"pane":"auto"}` returns to normal control, and finishing a
task leaves both windows in place. A layout change needs a fresh pane read.

Some Duo windows report local frames on both sides. In that case Poki checks visible labels against
the full display on the device before using either crop. If the keyboard obscures the text, Poki
can use the still-visible parts of the previously verified windows to recheck their positions.
It refuses input when it cannot establish which app is on each side. Two windows from the same
app are currently unsupported.

## Pairing by iOS version, and the pairing file's life

On iOS 27 and later (`SetupStep.onDevicePairing`), tap **Open Settings** when the pairing host is
ready, then choose **Privacy & Security → Developer Mode → Pair with ailove**. The app generates the
code when Settings begins the pairing exchange. The code appears on the pairing page and in the
Dynamic Island. Enter it in the active Settings prompt. On earlier iOS versions, pair from a computer with
Poki Setup (or pymobiledevice3, jitterbugpair, StikPair), then send the file to the phone.
Poki takes a pairing file three ways besides Import Pairing File:

- A file opened with Poki from AirDrop or Files (`CFBundleDocumentTypes`: property lists and
  `.mobiledevicepairing`).
- `poki://pairing?url=http://<computer on the LAN>:<port>/<file>&sha256=<hex>`: Poki fetches the
  file over the local network and checks the digest; Poki Setup shows this link as a code for the
  Camera. `poki://pairing?data=<base64url>` carries a small file in the link itself.
- `poki://setup?relay=<origin>` sets the relay address Poki Setup configured.

The pairing file and the setup state are mirrored into the Keychain (`SetupVault`,
`ThisDeviceOnly`). An update keeps the container anyway; a delete-and-reinstall, or a sideloading
tool that could not keep the container, gets both back on the first launch as long as the same team
signs the app, so the owner is not sent through setup again.

## Device test checklist

Install and launch
- [ ] Install `Poki-unsigned.ipa`. Runner path only: also install the runner IPA with the same signing, and open Poki Runner by hand: no passcode prompt, no automation banner; it opens Poki (or shows Open Poki).
- [ ] Launch Poki: the Setup tab shows a badge with the steps left, and no Install Poki Runner step.

Setup
- [ ] Each step opens in turn; Open Settings starts a Live Activity with the step number and what to tap.
- [ ] Loopback: the status changes within 3 s when ailove’s built-in VPN connects or disconnects.
- [ ] Pairing: the code shows in the Live Activity and in Poki; the step ticks.
- [ ] Let Poki stay on: Allow location shows iOS's prompt; Live Activities show as on.

Turned on
- [ ] Turn on or bring Poki to the foreground: no automation banner. Focus the field, start dictation, choose a shortcut, and complete a pure-chat or sandbox-browser task: still no banner.
- [ ] Connect an agent and call `status`: no banner or automation passcode prompt. Its first phone step shows Preparing, opens the session, and reads the screen successfully; steps show on the Lock Screen and in the chat.
- [ ] After a phone task ends, and separately after an outside agent reaches the idle timeout, the banner disappears. On iOS 18 to 26, the next phone task in the same app launch resumes the kept session and reads successfully without another passcode prompt. On iOS 27 and later, the next task opens a new session and reads successfully. Check both behaviors on physical phones; simulator tests do not establish them. If a pause fails, the log reports a close instead, and the banner must still disappear.
- [ ] No banner flicker during a run; a slow swipe or drag does not reopen the session.
- [ ] Runner path only: no banner until an agent's first call starts the runner; opening Poki Runner while in use shows "Poki is using this iPhone"; Stop on the Live Activity or in Poki takes the banner away within seconds and the next call starts it again; after the idle time with no calls, the banner goes away by itself.
- [ ] Ten minutes in the background: the location pill shows and agents still reach the phone.
- [ ] Close Poki from the app switcher: the banner goes away within seconds.
- [ ] A sensitive action shows Approve/Deny in the Live Activity; Approve asks for Face ID.

Connect
- [ ] Add a connector: the sheet shows the URL, a QR that scans to the same URL, and Copy works.
- [ ] Revoke by swiping: the connector disappears and the relay answers 404 for it.
