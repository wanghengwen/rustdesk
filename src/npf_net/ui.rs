//! The UI processes: RustDesk connections over npf made by the service
//! process (`npf-connect` on the main IPC, `call`), npf's state from it
//! (`npf-watch`) for Flutter, and the CM's accept of an npf connection
//! (docs/npf-flutter-api.md). A phone (Android, iOS): the link is in this process
//! (`link::attach`), `call` runs there over an in-memory pipe, and there is
//! no CM.

#[cfg(any(target_os = "android", target_os = "ios"))]
use super::link;
use super::{error_text, is_desktop, needs};
#[cfg(target_os = "ios")]
use super::pipe::{self as ipc, Data};
#[cfg(not(target_os = "ios"))]
use crate::ipc::{self, Data};
use base::message_proto::{message, Message};
use hbb_common::{
    anyhow::anyhow,
    bail,
    bytes::{BufMut, Bytes, BytesMut},
    log,
    msg_stream::{MsgSink, MsgStream},
    tcp::FramedStream,
    tokio::{
        self,
        io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
        sync::{mpsc, Semaphore},
    },
    ResultType, Stream,
};
use serde_json::{json, Value};
use std::{
    any::Any,
    net::{IpAddr, Ipv6Addr, SocketAddr},
    sync::{Arc, Mutex, Once},
    time::Duration,
};

/// the request and the peer's accept (someone may click there first)
const REPLY_WAIT: Duration = Duration::from_secs(90);
const WINDOW: usize = 4 << 20;
/// a phone: the pipe to `call::bridge`
#[cfg(any(target_os = "android", target_os = "ios"))]
const PIPE: usize = 1 << 20;

#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn not_running(_: hbb_common::anyhow::Error) -> hbb_common::anyhow::Error {
    anyhow!(error_text("no_service", None))
}

/// A RustDesk connection to `target` (an npf number or code, as
/// [`parse_target`](super::parse_target) gives it) of the conn type. Errors
/// are translation keys: `npf-` and npf's word (`npf-offline`, ...).
pub async fn connect(target: &str, conn_type: i32) -> ResultType<Stream> {
    if needs(conn_type).is_none() {
        bail!(error_text("unsupported", None));
    }
    let ask = json!({ "target": target, "conn_type": conn_type }).to_string();
    let mut c = open(ask).await?;
    let reply = tokio::time::timeout(REPLY_WAIT, async {
        loop {
            match c.next().await {
                Ok(Some(Data::Config((n, Some(v))))) if n == "npf-connect" => return Ok(v),
                Ok(_) => {}
                Err(e) => return Err(e),
            }
        }
    })
    .await
    .map_err(|_| anyhow!(error_text("timeout", None)))?
    .map_err(|_| anyhow!(error_text("no_service", None)))?;
    let v: Value = serde_json::from_str(&reply)?;
    if let Some(word) = v["error"].as_str() {
        let message = v["message"].as_str().unwrap_or_default();
        log::info!("npf: {target}: {word} {message}");
        bail!(failure(target, word, message));
    }
    let number: u64 = v["number"].as_str().and_then(|n| n.parse().ok()).unwrap_or(0);
    let seg = |s: u32| (number >> s) as u16;
    let ip = Ipv6Addr::new(0xfd6e, 0x7066, 0, 0, seg(48), seg(32), seg(16), seg(0));
    let addr = SocketAddr::new(IpAddr::V6(ip), 0);
    log::info!("npf: connected to {target} (conn type {conn_type})");
    Ok(if is_desktop(conn_type) {
        desktop(c, addr)
    } else {
        bytes(c, addr)
    })
}

/// The service process's main IPC, the request sent on it.
#[cfg(not(any(target_os = "android", target_os = "ios")))]
async fn open(ask: String) -> ResultType<ipc::ConnectionTmpl<impl AsyncRead + AsyncWrite + Unpin + Send + 'static>> {
    let mut c = ipc::connect(1000, "").await.map_err(not_running)?;
    c.send(&Data::Config(("npf-connect".to_owned(), Some(ask)))).await?;
    Ok(c)
}

/// A pipe to `call::bridge` on the link's runtime, which makes the request.
#[cfg(any(target_os = "android", target_os = "ios"))]
async fn open(ask: String) -> ResultType<ipc::ConnectionTmpl<tokio::io::DuplexStream>> {
    let rt = link::attach().ok_or_else(|| anyhow!(error_text("no_npf", None)))?;
    link::settled().await;
    let (here, there) = tokio::io::duplex(PIPE);
    rt.spawn(async move { super::call::bridge(ask, &mut ipc::ConnectionTmpl::new(there)).await });
    Ok(ipc::ConnectionTmpl::new(here))
}

/// `npf:KIND[:ARG]` for the request's error word (the UI's texts)
fn failure(target: &str, word: &str, message: &str) -> String {
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    let state: Value = serde_json::from_str(&STATE.lock().unwrap()).unwrap_or_default();
    #[cfg(any(target_os = "android", target_os = "ios"))]
    let state: Value = serde_json::from_str(&link::state_json()).unwrap_or_default();
    let peer = state["peers"]
        .as_array()
        .and_then(|l| l.iter().find(|p| p["number"].as_str() == Some(target)))
        .cloned()
        .unwrap_or_default();
    match word {
        // the peer's own reason (serve.rs): it lacks the feature
        "refused" if message.contains("no_permission") => error_text("no_permission", None),
        "offline" => error_text(word, peer["name"].as_str()),
        "quota" => {
            let limit = state["quota"]["limit"].as_u64().map(|l| format!("{} MiB", l >> 20));
            error_text(word, limit.as_deref())
        }
        "not_found" | "forbidden" | "not_paired"
            if peer["until"].as_i64().map_or(false, |u| u > 0 && u < hbb_common::get_time() / 1000) =>
        {
            error_text("expired", None)
        }
        w => error_text(w, None),
    }
}

/// RustDesk's messages, one an IPC frame: ours with a byte before, 1 for
/// audio (the controlling side's media), 0 for the rest
struct UiSink(Mutex<Option<mpsc::UnboundedSender<Bytes>>>);

impl MsgSink for UiSink {
    fn send(&self, msg: Option<&dyn Any>, bytes: Bytes) -> ResultType<usize> {
        let audio = msg
            .and_then(|m| m.downcast_ref::<Message>())
            .map_or(false, |m| matches!(m.union, Some(message::Union::AudioFrame(_))));
        let mut b = BytesMut::with_capacity(bytes.len() + 1);
        b.put_u8(audio as u8);
        b.extend_from_slice(&bytes);
        let n = b.len();
        match &*self.0.lock().unwrap() {
            Some(tx) if tx.send(b.freeze()).is_ok() => Ok(if audio { 0 } else { n }),
            _ => bail!("npf: the connection is closed"),
        }
    }

    fn close(&self) {
        self.0.lock().unwrap().take();
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

fn desktop<T>(mut c: ipc::ConnectionTmpl<T>, addr: SocketAddr) -> Stream
where
    T: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let (out_tx, mut out_rx) = mpsc::unbounded_channel::<Bytes>();
    let (in_tx, in_rx) = mpsc::unbounded_channel();
    let credit = Arc::new(Semaphore::new(WINDOW));
    let window = credit.clone();
    tokio::spawn(async move {
        loop {
            tokio::select! {
                b = out_rx.recv() => {
                    let Some(b) = b else { break };
                    let n = b.len();
                    let audio = b.first() == Some(&1);
                    if c.send_raw(b).await.is_err() {
                        break;
                    }
                    if !audio {
                        window.add_permits(n);
                    }
                }
                r = c.next_raw() => {
                    let Ok(b) = r else { break };
                    if in_tx.send(b).is_err() {
                        break;
                    }
                }
            }
        }
        // a sender waiting for credit fails
        window.close();
    });
    let sink = Arc::new(UiSink(Mutex::new(Some(out_tx))));
    Stream::Msg(MsgStream::new(sink, in_rx, credit, WINDOW, addr))
}

/// a byte stream: the IPC frames are its bytes
fn bytes<T>(mut c: ipc::ConnectionTmpl<T>, addr: SocketAddr) -> Stream
where
    T: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let (here, there) = tokio::io::duplex(256 << 10);
    let (mut r, mut w) = tokio::io::split(there);
    tokio::spawn(async move {
        let mut buf = vec![0u8; 64 << 10];
        loop {
            tokio::select! {
                b = c.next_raw() => {
                    let Ok(b) = b else { break };
                    if w.write_all(&b).await.is_err() {
                        break;
                    }
                }
                n = r.read(&mut buf) => {
                    let Ok(n) = n.map_err(|_| ()).and_then(|n| if n > 0 { Ok(n) } else { Err(()) }) else { break };
                    if c.send_raw(Bytes::copy_from_slice(&buf[..n])).await.is_err() {
                        break;
                    }
                }
            }
        }
    });
    Stream::Tcp(FramedStream::from(here, addr))
}

/* ---- the state ---- */

static STATE: Mutex<String> = Mutex::new(String::new());

/// npf's state (docs/npf-flutter-api.md); the first call starts watching
/// it, and the global event `npf_state` comes whenever it changes.
#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub fn state() -> String {
    static WATCH: Once = Once::new();
    WATCH.call_once(|| {
        std::thread::spawn(watch);
    });
    let s = STATE.lock().unwrap();
    if s.is_empty() {
        no_service()
    } else {
        s.clone()
    }
}

/// a phone: the first call attaches to npf, and watches the state.
#[cfg(any(target_os = "android", target_os = "ios"))]
pub fn state() -> String {
    static WATCH: Once = Once::new();
    WATCH.call_once(|| {
        if let Some(rt) = link::attach() {
            rt.spawn(async {
                loop {
                    set_state(link::state_json());
                    tokio::time::sleep(Duration::from_millis(250)).await;
                }
            });
        }
    });
    link::state_json()
}

/// a phone: a new assist code, from npf in this process.
#[cfg(any(target_os = "android", target_os = "ios"))]
pub fn assist_renew() {
    if let Some(rt) = link::attach() {
        rt.spawn(async {
            let Some(l) = link::link() else { return };
            if let Err(e) = l.assist_renew().await {
                log::warn!("npf: assist code not renewed: {e}");
            }
        });
    }
}

/// a phone: one of npf's requests, made in this process. Blocks (a
/// Flutter worker thread).
#[cfg(any(target_os = "android", target_os = "ios"))]
pub fn call(path: String, body: String) -> String {
    let ask = json!({ "path": path, "body": serde_json::from_str::<Value>(&body).unwrap_or(Value::Null) });
    match link::attach() {
        Some(rt) => rt.block_on(link::npf_call(ask.to_string())).to_string(),
        None => json!({ "error": "no_npf", "message": null }).to_string(),
    }
}

/// the state while the service process is not there
#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn no_service() -> String {
    json!({
        "link": {"up": false, "why": "no_service", "message": null},
        "node": null, "name": null, "online": false, "account": false, "version": null,
        "resource": null,
        "assist": {"code": null, "why": "offline"},
        "quota": null, "peers": [], "incoming": [], "outgoing": [],
    })
    .to_string()
}

fn set_state(s: String) {
    {
        let mut st = STATE.lock().unwrap();
        if *st == s {
            return;
        }
        *st = s;
    }
    #[cfg(feature = "flutter")]
    for ch in crate::flutter::get_global_event_channels() {
        crate::flutter::push_global_event(&ch, json!({ "name": "npf_state" }).to_string());
    }
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
#[tokio::main(flavor = "current_thread")]
async fn watch() {
    loop {
        if let Ok(mut c) = ipc::connect(1000, "").await.map_err(not_running) {
            if c.send(&Data::Config(("npf-watch".to_owned(), None))).await.is_ok() {
                loop {
                    match c.next().await {
                        Ok(Some(Data::Config((n, Some(v))))) if n == "npf-watch" => set_state(v),
                        Ok(_) => {}
                        Err(_) => break,
                    }
                }
            }
        }
        set_state(no_service());
        tokio::time::sleep(Duration::from_secs(2)).await;
    }
}

/// One request to the service process, from a thread of its own (a UI
/// call from Flutter, no runtime there).
#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn tell(name: &'static str, value: Option<String>) {
    #[tokio::main(flavor = "current_thread")]
    async fn send(name: &'static str, value: Option<String>) {
        match ipc::connect(1000, "").await.map_err(not_running) {
            Ok(mut c) => {
                c.send(&Data::Config((name.to_owned(), value))).await.ok();
            }
            Err(e) => log::warn!("npf: {name}: {e}"),
        }
    }
    std::thread::spawn(move || send(name, value));
}

/// A new assist code ("换一个"); it comes with the state.
#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub fn assist_renew() {
    tell("npf-assist-renew", None);
}

/// Ends an incoming npf connection (`incoming[].id`, RustDesk's connection id).
#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub fn disconnect(conn_id: i32) {
    tell("npf-disconnect", Some(conn_id.to_string()));
}

/// One of npf's requests answered with JSON (the sharing page: `share/list`,
/// `share/new`, `share/revoke`, `member/set`, `member/remove`,
/// `resource/set`; npf's applink.md 3.2), `body` a JSON object or "": `{"ok":
/// ANSWER}` or `{"error": WORD, "message"}`. Blocks (a Flutter worker thread).
#[cfg(not(any(target_os = "android", target_os = "ios")))]
#[tokio::main(flavor = "current_thread")]
pub async fn call(path: String, body: String) -> String {
    let ask = json!({ "path": path, "body": serde_json::from_str::<Value>(&body).unwrap_or(Value::Null) });
    let r = async {
        let mut c = ipc::connect(1000, "").await.map_err(not_running)?;
        c.send(&Data::Config(("npf-call".to_owned(), Some(ask.to_string())))).await?;
        loop {
            match c.next_timeout(90_000).await? {
                Some(Data::Config((n, Some(v)))) if n == "npf-call" => return Ok::<_, hbb_common::anyhow::Error>(v),
                _ => {}
            }
        }
    };
    r.await.unwrap_or_else(|e| json!({ "error": "no_service", "message": e.to_string() }).to_string())
}

/* ---- the CM ---- */

/// The CM accepts an npf connection with `allowed` of the features its
/// client's `npf.can` lists: without the one its kind needs (view for a
/// remote desktop, file, terminal, control for port forwards) it is closed,
/// without control its input and the rest are switched off, without file its
/// file copy.
#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub fn cm_allow(conn_id: i32, allowed: Vec<String>) {
    use crate::ui_cm_interface as cm;
    let Some(client) = cm::client(conn_id) else {
        return;
    };
    let has = |c: &str| allowed.iter().any(|x| x == c);
    let can: Vec<String> = client
        .npf
        .as_ref()
        .and_then(|v| serde_json::from_value(v["can"].clone()).ok())
        .unwrap_or_default();
    let need = if client.is_file_transfer {
        "file"
    } else if client.is_terminal {
        "terminal"
    } else if !client.port_forward.is_empty() {
        "control"
    } else {
        "view"
    };
    if !has(need) {
        log::info!("npf: connection {conn_id} not accepted: no {need}");
        return cm::close(conn_id);
    }
    let mut off: Vec<&str> = vec![];
    if can.iter().any(|c| c == "control") && !has("control") {
        off.extend(["keyboard", "clipboard", "restart", "block_input", "privacy_mode"]);
    }
    if can.iter().any(|c| c == "file") && !has("file") {
        off.push("file");
    }
    for name in off {
        cm::send(conn_id, Data::SwitchPermission { name: name.to_owned(), enabled: false });
    }
    let allowed: Vec<String> = allowed.into_iter().filter(|c| can.contains(c)).collect();
    tell("npf-allow", Some(json!({ "conn_id": conn_id, "allowed": allowed }).to_string()));
    cm::authorize(conn_id);
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::DuplexStream;

    fn pipe() -> (ipc::ConnectionTmpl<DuplexStream>, ipc::ConnectionTmpl<DuplexStream>) {
        let (a, b) = tokio::io::duplex(1 << 16);
        (ipc::ConnectionTmpl::new(a), ipc::ConnectionTmpl::new(b))
    }

    fn addr() -> SocketAddr {
        SocketAddr::new(IpAddr::V6(Ipv6Addr::LOCALHOST), 0)
    }

    /// a remote desktop over the pipe: frames both ways, ours with the
    /// channel's byte; the end reaches the other side
    #[tokio::test]
    async fn desktop_pipe() {
        let (here, mut far) = pipe();
        let mut s = desktop(here, addr());
        far.send_raw(Bytes::from_static(b"frame")).await.unwrap();
        assert_eq!(&s.next().await.unwrap().unwrap()[..], b"frame");
        s.send_raw(b"msg".to_vec()).await.unwrap();
        assert_eq!(&far.next_raw().await.unwrap()[..], b"\0msg");
        drop(s);
        assert!(far.next_raw().await.is_err());
    }

    /// a byte stream over the pipe: what goes out comes back (an echo)
    #[tokio::test]
    async fn bytes_pipe() {
        let (here, mut far) = pipe();
        let mut s = bytes(here, addr());
        s.send_raw(b"hello".to_vec()).await.unwrap();
        let echo = far.next_raw().await.unwrap();
        far.send_raw(echo.freeze()).await.unwrap();
        assert_eq!(&s.next().await.unwrap().unwrap()[..], b"hello");
    }

    /// `call::bridge` over the pipe (Android's `open`) answers as on the
    /// IPC; no link here: npf is not there
    #[tokio::test]
    async fn bridge_pipe() {
        let (mut here, mut far) = pipe();
        let ask = json!({ "target": "123456786", "conn_type": 0 }).to_string();
        tokio::spawn(async move { super::super::call::bridge(ask, &mut far).await });
        match here.next().await.unwrap() {
            Some(Data::Config((n, Some(v)))) => {
                assert_eq!(n, "npf-connect");
                let v: Value = serde_json::from_str(&v).unwrap();
                assert_eq!(v["error"], "no_npf");
            }
            x => panic!("{x:?}"),
        }
        assert!(here.next().await.is_err());
    }
}
