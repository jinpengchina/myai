import Foundation

/// PokiLauncher (Rust, native/launcher) through its C ABI: gets the runner up over the loopback and
/// keeps it up. Events arrive on a launcher thread as JSON.
final class RustLauncher: RunnerLauncher {
    private var handle: OpaquePointer?
    private var box: Unmanaged<EventBox>?

    final class EventBox {
        let onEvent: @Sendable (RunnerStatus) -> Void
        init(_ onEvent: @escaping @Sendable (RunnerStatus) -> Void) { self.onEvent = onEvent }
    }

    func start(config: LauncherConfig, onEvent: @escaping @Sendable (RunnerStatus) -> Void) throws {
        stop()
        let json = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
        let box = Unmanaged.passRetained(EventBox(onEvent))
        let handle = json.withCString { poki_launcher_new($0, { context, text in
            guard let context, let text else { return }
            let box = Unmanaged<EventBox>.fromOpaque(context).takeUnretainedValue()
            if let status = try? JSONDecoder().decode(RunnerStatus.self, from: Data(String(cString: text).utf8)) { box.onEvent(status) }
        }, box.toOpaque()) }
        guard let handle else { box.release(); throw NSError(domain: "Poki", code: 10, userInfo: [NSLocalizedDescriptionKey: "the launcher did not accept its configuration"]) }
        self.handle = handle; self.box = box
        guard poki_launcher_start(handle) == 0 else { throw NSError(domain: "Poki", code: 11, userInfo: [NSLocalizedDescriptionKey: "the launcher did not start"]) }
    }

    func restart() { if let handle { poki_launcher_restart(handle) } }

    func stop() {
        if let handle { poki_launcher_free(handle) } // stops it, then frees it
        handle = nil
        // An event may still be on its way from a launcher thread; the box outlives it.
        if let box { DispatchQueue.main.asyncAfter(deadline: .now() + 5) { box.release() } }
        box = nil
    }

    deinit { stop() }
}

/// On-device pairing through PokiLauncher (iOS 27): the launcher listens and makes the PIN; the app
/// publishes the Bonjour service it describes, so Settings > Privacy & Security > Developer Mode lists
/// "Pair with Poki".
final class RustPairing: NSObject, DevicePairing, NetServiceDelegate {
    private var handle: OpaquePointer?
    private var box: Unmanaged<RustLauncher.PairBox>?
    private var service: NetService?
    private var attempt: UUID?
    private var publicationEvent: (@Sendable (PairingEvent) -> Void)?
    static let publicationFailure = "Pairing could not appear in Settings. In Settings › Privacy & Security › Local Network, allow myai, then try again on Wi-Fi."

    func start(hostName: String, saveTo: URL, onEvent: @escaping @Sendable (PairingEvent) -> Void) throws {
        cancel()
        let config: [String: String] = ["host_name": hostName, "out_path": saveTo.path, "identity_path": AppFiles.support.appendingPathComponent("pairing-host.key").path]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)
        let attempt = UUID()
        self.attempt = attempt
        publicationEvent = onEvent
        let box = Unmanaged.passRetained(RustLauncher.PairBox { [weak self] value in
            DispatchQueue.main.async {
                guard let event = value["event"] as? String else { return }
                guard let self, self.attempt == attempt else {
                    if event == "paired" { try? FileManager.default.removeItem(at: saveTo) }
                    return
                }
                switch event {
                case "advertise": self.publish(value)
                case "peer_connected": AppLog.shared.add("pairing", "pairing listener accepted a TCP connection")
                case "handshake_accepted": AppLog.shared.add("pairing", "pairing responder sent its handshake reply")
                case "pin": onEvent(.pin(value["pin"] as? String ?? ""))
                case "paired":
                    self.cancel()
                    onEvent(.paired(URL(fileURLWithPath: value["path"] as? String ?? saveTo.path)))
                case "failed":
                    self.cancel()
                    onEvent(.failed(value["detail"] as? String ?? "pairing failed"))
                default: break
                }
            }
        })
        let handle = json.withCString { poki_pair_start($0, { context, text in
            guard let context, let text else { return }
            let box = Unmanaged<RustLauncher.PairBox>.fromOpaque(context).takeUnretainedValue()
            if let value = (try? JSONSerialization.jsonObject(with: Data(String(cString: text).utf8))) as? [String: Any] { box.onEvent(value) }
        }, box.toOpaque()) }
        guard let handle else { cancel(); box.release(); throw NSError(domain: "Poki", code: 12, userInfo: [NSLocalizedDescriptionKey: "pairing did not start"]) }
        self.handle = handle; self.box = box
    }

    func cancel() {
        attempt = nil
        publicationEvent = nil
        if let handle { poki_pair_cancel(handle) }
        handle = nil
        // The box is released after the pairing task is gone; a late callback would use it.
        if let box { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { box.release() } }
        box = nil
        unpublish()
    }

    private func publish(_ value: [String: Any]) {
        unpublish()
        guard let type = value["service_type"] as? String, let instance = value["instance"] as? String, let port = value["port"] as? Int else {
            Task { @MainActor in AppLog.shared.add("pairing", "Bonjour advertisement is missing required fields") }
            publishFailed()
            return
        }
        let service = NetService(domain: "local.", type: type.hasSuffix(".") ? type : type + ".", name: instance, port: Int32(port))
        if let txt = value["txt"] as? [String: Any] {
            service.setTXTRecord(NetService.data(fromTXTRecord: txt.mapValues { Data(String(describing: $0).utf8) }))
        }
        self.service = service
        service.delegate = self
        service.publish()
        let listening = value["listening"] as? String ?? "port \(port)"
        Task { @MainActor in AppLog.shared.add("pairing", "listening on \(listening); Bonjour publication requested") }
    }

    private func unpublish() {
        service?.delegate = nil
        service?.stop()
        service = nil
    }

    private func publishFailed() {
        let notify = publicationEvent
        cancel()
        notify?(.failed(Self.publicationFailure))
    }

    func netServiceDidPublish(_ sender: NetService) {
        guard sender === service else { return }
        publicationEvent?(.advertising)
        Task { @MainActor in AppLog.shared.add("pairing", "Bonjour publication succeeded") }
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        guard sender === service else { return }
        publishFailed()
        let code = errorDict[NetService.errorCode]?.intValue ?? 0
        let domain = errorDict[NetService.errorDomain]?.intValue ?? 0
        Task { @MainActor in AppLog.shared.add("pairing", "Bonjour publication failed (domain \(domain), code \(code))") }
    }
}

extension RustLauncher {
    final class PairBox {
        let onEvent: ([String: Any]) -> Void
        init(_ onEvent: @escaping ([String: Any]) -> Void) { self.onEvent = onEvent }
    }
}
