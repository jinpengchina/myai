//! On-device pairing (iOS 27): Poki plays the "pairable host". It listens on a TCP port, the app
//! advertises `_remotepairing-pairable-host._tcp` with the TXT records below (Bonjour, from Swift),
//! the person picks Poki in Settings and types the PIN Poki shows, and the result is an RPPairing file
//! the launcher then uses over the loopback. This is what StikPair does.

use idevice::{IdeviceError, remote_pairing::{PAIRABLE_HOST_SERVICE_TYPE, PairableHost, PairableHostInfo, RpPairingFile, RpPairingSocket, RpPairingSocketProvider, errors::RemotePairingError}};
use serde::Serialize;
use serde_json::{Value, json};
use std::{fmt, future::Future, path::PathBuf, pin::Pin, sync::atomic::{AtomicBool, Ordering}, time::Duration};
use tokio::net::{TcpListener, TcpStream};

pub struct PairConfig {
    pub host_name: String,
    pub out_path: PathBuf,
    /// Where to keep the host identity (alt_irk) so the phone recognizes Poki later.
    pub identity_path: Option<PathBuf>,
}

/// How long a pairing may wait for the person. On the phone, finding Poki in Settings and typing the
/// PIN took about three minutes; ten leave room for someone who gets lost in Settings. The app keeps
/// itself running with silent audio while it waits, so a pairing the person gave up on must end.
pub const PAIRING_LIMIT: Duration = Duration::from_secs(10 * 60);
const HANDSHAKE_LIMIT: Duration = Duration::from_secs(10);

/// Apply the short deadline to the initial request. The standard responder's
/// first outgoing message is its reply to a valid pair-setup handshake.
struct HandshakeSocket<F> {
    inner: RpPairingSocket<TcpStream>,
    on_handshake: Option<F>,
}

impl<F> fmt::Debug for HandshakeSocket<F> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("HandshakeSocket")
    }
}

type SocketResult<'a, T> = Pin<Box<dyn Future<Output = Result<T, IdeviceError>> + Send + 'a>>;

impl<F: FnOnce() + Send> RpPairingSocketProvider for HandshakeSocket<F> {
    fn recv_plain(&mut self) -> SocketResult<'_, plist::Value> {
        let read = self.inner.recv_plain();
        if self.on_handshake.is_none() { return read; }
        Box::pin(async move {
            tokio::time::timeout(HANDSHAKE_LIMIT, read).await.map_err(|_| IdeviceError::Timeout)?
        })
    }

    fn send_plain(&mut self, value: impl Serialize, seq: usize) -> SocketResult<'_, ()> {
        let write = self.inner.send_plain(value, seq);
        let Some(on_handshake) = self.on_handshake.take() else { return write };
        Box::pin(async move {
            write.await?;
            on_handshake();
            Ok(())
        })
    }

    fn send_encrypted(&mut self, ciphertext: Vec<u8>, seq: usize) -> SocketResult<'_, ()> {
        self.inner.send_encrypted(ciphertext, seq)
    }
    fn serialize_bytes(bytes: &[u8]) -> plist::Value { RpPairingSocket::<TcpStream>::serialize_bytes(bytes) }
    fn deserialize_bytes(value: plist::Value) -> Option<Vec<u8>> { RpPairingSocket::<TcpStream>::deserialize_bytes(value) }
}

/// Runs one pairing: `emit` gets `advertise` (what to publish over Bonjour), `pin`, then `paired` or
/// `failed`. Ends after one pairing, on error, or after `PAIRING_LIMIT`.
pub async fn run(config: PairConfig, emit: impl Fn(Value) + Send + Sync + 'static) {
    let code_requested = AtomicBool::new(false);
    let detail = match tokio::time::timeout(PAIRING_LIMIT, pair(&config, &emit, &code_requested)).await {
        Ok(Ok(())) => return,
        Ok(Err(detail)) => detail,
        Err(_) if !code_requested.load(Ordering::Relaxed) => "Settings did not request a pairing code within 10 minutes. Try again.".into(),
        Err(_) => "Pairing was not finished in Settings within 10 minutes, so Poki stopped waiting. Tap Try again to pair.".into(),
    };
    emit(json!({"event": "failed", "detail": detail}));
}

async fn pair(config: &PairConfig, emit: &(impl Fn(Value) + Send + Sync), code_requested: &AtomicBool) -> Result<(), String> {
    let mut info = PairableHostInfo::generate(&config.host_name, "Mac17,7");
    if let Some(path) = &config.identity_path {
        if let Ok(bytes) = std::fs::read(path) {
            if bytes.len() == 16 {
                info.alt_irk.copy_from_slice(&bytes);
            }
        } else {
            let _ = std::fs::write(path, info.alt_irk);
        }
    }
    let mut file = RpPairingFile::generate(&config.host_name);
    let identifier = file.identifier().to_string();
    // Both IPv6 and IPv4 (a dual-stack socket on "::"): Settings may reach Poki over either.
    let listener = match TcpListener::bind(("::", 0)).await {
        Ok(l) => l,
        Err(_) => TcpListener::bind(("0.0.0.0", 0)).await.map_err(|e| format!("cannot listen for the phone: {e}"))?,
    };
    let port = listener.local_addr().map_err(|e| e.to_string())?.port();
    let txt: serde_json::Map<String, Value> = info.mdns_txt_records(&identifier).into_iter().map(|(k, v)| (k, Value::String(v))).collect();
    emit(json!({
        "event": "advertise",
        "service_type": PAIRABLE_HOST_SERVICE_TYPE.trim_end_matches(".local."),
        "instance": identifier,
        "port": port,
        "listening": listener.local_addr().map(|a| a.to_string()).unwrap_or_default(),
        "txt": txt,
    }));
    let mut reported_connection = false;
    let mut reported_handshake = false;
    loop {
        let (stream, _) = listener.accept().await.map_err(|e| format!("the phone did not connect: {e}"))?;
        if !reported_connection {
            reported_connection = true;
            emit(json!({"event": "peer_connected"}));
        }
        let socket = HandshakeSocket {
            inner: RpPairingSocket::new_device(stream),
            on_handshake: Some(|| {
                if !reported_handshake {
                    reported_handshake = true;
                    emit(json!({"event": "handshake_accepted"}));
                }
            }),
        };
        let mut host = PairableHost::new(socket, info.clone());
        let result = host.accept(&mut file, |pin| {
            // The responder generates this code after it receives pair-setup M1.
            code_requested.store(true, Ordering::Relaxed);
            emit(json!({"event": "pin", "pin": pin}));
            std::future::ready(())
        }).await;
        match result {
            Ok(_) => break,
            Err(_) if !code_requested.load(Ordering::Relaxed) => continue,
            Err(idevice::IdeviceError::RemotePairing(RemotePairingError::SrpAuthFailed)) => {
                return Err("The pairing code could not be verified. Try again for a new code.".into());
            }
            Err(_) => return Err("Pairing ended after Settings requested the code. Try again.".into()),
        }
    }
    let mut bytes = file.to_bytes();
    // Remember the name it was made with, for the requests that send it.
    if let Ok(mut dict) = plist::from_bytes::<plist::Dictionary>(&bytes) {
        dict.insert(crate::remote::SENDING_HOST_KEY.into(), config.host_name.clone().into());
        bytes.clear();
        let _ = plist::to_writer_xml(&mut bytes, &dict);
    }
    std::fs::write(&config.out_path, &bytes).map_err(|e| format!("cannot save the pairing file: {e}"))?;
    emit(json!({"event": "paired", "path": config.out_path.display().to_string()}));
    Ok(())
}
