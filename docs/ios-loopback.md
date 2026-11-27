# Local developer connection

myai reaches this iPhone’s local services through its embedded packet tunnel. Entering the connection step starts the tunnel and lets iOS present its VPN configuration prompt. A device previously set up with an external VPN uses the same built-in flow on upgrade.

## Design

`LoopbackTunnel` reads its provider identifier from the embedded extension. It creates, starts and stops the matching configuration. Setup verifies the local service through myai’s own connected provider. The remote agent relay is configured separately.

The extension calls `LoopbackNetworkSettings.make()` and passes packets through
`LoopbackPacket.reflect(Data) -> Data?`. These are production interfaces in the small `PokiLoopback`
package, also exercised directly on macOS. `PokiTunnel` owns the serial packet read/write lifetime.
PokiCore and the Rust launcher retain their existing interfaces.

The route contract is:

- Interface `10.7.0.2/32`; sole included destination `10.7.0.1/32`; default route excluded.
- IPv4 TCP only, including dynamic developer-service ports. No DNS, IPv6 or proxy settings.
- Validate header lengths, total length, endpoint addresses and TCP header length. Drop fragments.
  TCP uses the tunnel's MTU of 1500; fragmented packets are outside this interface's contract.
- Swap source and destination addresses, preserving ports, TCP payload and checksums. Exchanging
  addresses preserves the IPv4 and TCP one's-complement checksum sums.
- No packet contents are logged, stored or sent to an external server. Packet-write failure stops
  the tunnel rather than reporting a working connection.

Saving a configuration and VPN Connected indicate tunnel status only. The setup step passes only
when RemotePairing (`49152`, or the port its Bonjour record names once iOS has moved it) or
lockdown (`62078`) accepts a TCP connection through `10.7.0.1`.

## Signing and distribution

`native/ios-app/myai.yml` includes the packet-tunnel target. Both myai and the extension require `com.apple.developer.networking.networkextension = [packet-tunnel-provider]` in matching provisioning profiles. The app and widget share the same registered App Group. See the [build and signing instructions](../README.md#build-for-your-iphone).

## Setup

On the connection page, approve the iOS VPN configuration when prompted. If another VPN is active, iOS may switch to myai’s tunnel. After a failed attempt, the connection page offers a retry.

### Cellular connections and automation

Internet access, the local developer connection, and an automation session are separate.
A VPN reporting Connected does not prove that either developer port accepts a connection.
A TCP connection does not prove that RemotePairing, its dynamic tunnel listener, or RSD works.

The current product code uses the in-process XCTest session by default. Its launcher first opens
the local developer connection, then checks the developer image. If TCP connect fails or the peer
closes the connection during the opening handshake, and the image is already mounted on the phone, the launcher reports `running` with code
`local_ddi` instead of waiting for the network. The status keeps the connection error (refused, no
route, or timed out), and the app writes it to its activity log. One refusal waits instead: while
the app looks for a moved RemotePairing port in Bonjour (on Wi-Fi, three looks at most), the
launcher reports `waiting_network` with code `pairing_port`; once the looks end without a port, the
next attempt hands over as above. The app passes the launcher the
file it checks for the mounted image (`ddi_marker`). The app then opens its own XCTest session, which
needs no loopback. Automation counts as ready only after that session opens. The hand-over does not
check the pairing, so it does not update the pairing state. The signer still needs the loopback.
If the local open fails, Home says that the session did not open, with its code, and the launcher
tries the normal path once when the loopback answers again.
That return also checks the pairing and lets the signer retry, as before.

These steps still need the loopback, so on cellular they show "This step needs Wi-Fi. Connect and
try again.":

- Preparing a renewal or an update.
- Installing a prepared build.
- Mounting the developer image for the first time after the phone restarts.

How the image is mounted depends on iOS. From 26.4 it is a Cryptex1 cryptex installed through
cryptexd. Before 26.4 (17.4 to 26.3) there is no such install, and iOS 18.7.7 closed the cryptexd
connection ("device socket io failed (BrokenPipe)", issue 124). There Poki downloads the
personalized image and mounts it through the image mounter, the route StikDebug and pymobiledevice3
use. The launcher (`ddi::method_for`), the app (`DeveloperDiskImage.Kind`) and Poki Setup
(`device::ddi::Kind`) pick by the same rule.

The preserved `dev/esp-409-preserve-030` branch has a different design. It includes
`AutomationChooser`, native services, and its own mounted-image fallback. Those features are not
present in the current product code.

The local fallback adapts [PR #91](https://github.com/JosssphZhou/poki/pull/91) by Zeno6898.
[Its field report](https://github.com/JosssphZhou/poki/issues/35#issuecomment-6735040996) shows a
configured iPhone using cellular with no working loopback. That report covers an older build, so
the integrated build needs its own device check. [PR #84](https://github.com/JosssphZhou/poki/pull/84)
retains an automation session through idle and adds owner pause and resume. It needs a prepared
session and does not make an unavailable developer endpoint reachable. When integrating #84, keep
first-open passcode consent and explicit owner pause behavior. Do not use automation readiness as
proof that pairing or renewal is ready.

[Earlier Shadowrocket measurements](https://github.com/JosssphZhou/poki/issues/35#issuecomment-6705290849)
stopped at TCP connect on cellular. They also found a route to 10.7.0.1 after switching networks.
The reported localhost rejection is a different connection, so it does not establish the exact
server-side cause on the reflected address. Neither those results nor this app's path monitor
establish a universal iOS ban on cellular loopback.

For a failed local connection, connect to Wi-Fi, reconnect the selected local connection, and
retry. Test Wi-Fi enabled without an associated network separately; enabling the radio alone is
not a verified workaround. [SideStore's JIT guide](https://docs.sidestore.io/docs/advanced/jit)
describes starting a VPN, using Airplane Mode, and returning to cellular. That is an upstream
workaround, not verified Poki support. It can interrupt internet access needed for a relay or
Apple signing. The earlier Shadowrocket test did not succeed with cellular temporarily disabled.

## Acceptance

Run `swift test --package-path native/ios/PokiLoopback`. The three tests protect distinct contracts:
TCP conversation reflection, rejection of out-of-scope/malformed packets, and actual SDK network
settings that leave DNS/IPv6/default internet routing alone. No alternate packet implementation or
test-only production export is used. The packet and route tests failed against the new feature's
empty scaffold, not against the original branch, which had no such module. The rejection test is a
new data-protection test, not an existing-branch regression test.

Unsigned device builds and Simulator screenshots can establish packaging and UI behavior only.
Before claiming this works on an iPhone, complete section 1 and then sections 2–6 of
`device-test-checklist.md` on the designated, locked test device. Include first consent, live service
access, denied consent, restart, background/lock survival, Wi-Fi/cellular recovery, switching from a previous VPN configuration and stopping the tunnel. Simulator VPN startup must report that a physical iPhone is required.

The standalone launcher binds the runner's HTTP and MJPEG listeners to `127.0.0.1`; the loopback
tunnel remains limited to the developer-service routes above and does not expose port 8100.
