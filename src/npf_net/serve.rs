//! The controlled side: npf's requests for `desktop` become RustDesk
//! connections, held to what the request's `can` grants (never to its body:
//! applink.md 6.4).
//!
//! - remote desktop and camera: RustDesk's frames on the main channel
//!   ([`Stream::Msg`] with [`Desk`] its sink), the video of each display and
//!   the audio on media streams of their own; the controlling side may open
//!   its audio (19) and its key frame requests (20);
//! - file transfer, terminal, port forward, RDP: a RustDesk TCP connection
//!   on channel 1, which this side opens (prio 2: after the media).
//!
//! Without `control` the connection only watches: RustDesk's permissions for
//! input and the rest are off from the start (ConnectionMeta) and cannot be
//! switched on in the CM; without `file` no file copy, without `terminal` no
//! terminal. A connection is known by its address: fd6e:7066::/32 ("npf"),
//! a counter and the peer's number.

use super::{
    is_desktop, link, needs, request_keyframe_rate_limited, DISPLAYS, TAG_AUDIO, TAG_AUDIO_BACK,
    TAG_DATA, TAG_KEY, TAG_VIDEO,
};
use crate::server::{create_tcp_connection, ConnectionMeta};
use applink::{Channel, Fec, Media, MediaOpt, MediaStats, Opened, Opener, Request, Role, Service, Slot};
use base::message_proto::{message, Message};
use hbb_common::{
    bail,
    bytes::{Bytes, BytesMut},
    bytes_codec::BytesCodec,
    futures::StreamExt,
    log,
    msg_stream::{MsgSink, MsgStream},
    rendezvous_proto::{control_permissions::Permission, ControlPermissions},
    tcp::FramedStream,
    tokio::{
        self,
        io::{AsyncRead, AsyncWrite, AsyncWriteExt, ReadBuf},
        sync::{mpsc, Notify, Semaphore},
        task::JoinHandle,
    },
    tokio_util::codec::{Encoder, FramedRead},
    ResultType, Stream,
};
use serde_json::{json, Value};
use std::{
    any::Any,
    collections::{BTreeMap, HashSet},
    io,
    net::{IpAddr, Ipv6Addr, SocketAddr},
    pin::Pin,
    sync::{
        atomic::{AtomicBool, AtomicU32, Ordering},
        Arc, Mutex,
    },
    task::{Context, Poll, Waker},
};

/// bytes of RustDesk's messages in flight on a remote desktop's main channel
const WINDOW: usize = 4 << 20;

/// An accepted request, by the address of its RustDesk connection.
struct Grant {
    number: u64,
    name: Option<String>,
    role: Option<Role>,
    temp: bool,
    via: Option<String>,
    can: Vec<String>,
    conn_type: i32,
    /// when it was asked
    asked: i64,
    /// when it was accepted (RustDesk's login)
    since: Option<i64>,
    /// RustDesk's connection id, once it logged in
    conn_id: Option<i32>,
    /// of `can`, what the CM accepted (and switched since); None: all of it
    /// once accepted
    allowed: Option<Vec<String>>,
    /// ends the connection (the UI's 断开)
    cut: Arc<Cut>,
}

impl Grant {
    fn can(&self, cap: &str) -> bool {
        self.can.iter().any(|c| c == cap)
    }

    /// what it may use now: None before it was accepted
    fn allowed(&self) -> Option<Vec<String>> {
        self.since?;
        Some(self.allowed.clone().unwrap_or_else(|| self.can.clone()))
    }
}

static GRANTS: Mutex<BTreeMap<String, Grant>> = Mutex::new(BTreeMap::new());

/// the grant goes with its service
struct Granted(String);

impl Drop for Granted {
    fn drop(&mut self) {
        if let Some(g) = GRANTS.lock().unwrap().remove(&self.0) {
            log::info!("npf: the connection from {} ended", g.number);
        }
    }
}

/// The end of a connection asked from outside: its reader reads the end.
#[derive(Default)]
struct Cut {
    done: AtomicBool,
    waker: Mutex<Option<Waker>>,
    notify: Notify,
}

impl Cut {
    fn cut(&self) {
        self.done.store(true, Ordering::SeqCst);
        if let Some(w) = self.waker.lock().unwrap().take() {
            w.wake();
        }
        self.notify.notify_waiters();
    }

    fn poll(&self, cx: &mut Context<'_>) -> bool {
        *self.waker.lock().unwrap() = Some(cx.waker().clone());
        self.done.load(Ordering::SeqCst)
    }

    async fn wait(&self) {
        loop {
            let n = self.notify.notified();
            if self.done.load(Ordering::SeqCst) {
                return;
            }
            n.await;
        }
    }
}

/// npf's request for a service (an event).
pub fn request(r: Request) {
    let Some(l) = link::link() else {
        return;
    };
    let conn_type = r.body["conn_type"].as_i64().unwrap_or(0) as i32;
    let why = match needs(conn_type).filter(|_| r.res == link::RES) {
        None => Some("unsupported"),
        Some(need) if !r.can(need) || withheld_in_session(r.peer.number, need) => {
            log::info!("npf: {} asked for conn type {conn_type} without {need}", r.peer.number);
            Some("no_permission")
        }
        _ if link::server().is_none() => Some("unavailable"),
        _ => None,
    };
    tokio::spawn(async move {
        match why {
            Some(why) => {
                l.refuse(r.service, Some(&json!({ "error": why }))).await.ok();
            }
            None => serve(l, r, conn_type).await,
        }
    });
}

async fn serve(l: &'static applink::Link, r: Request, conn_type: i32) {
    let desktop = is_desktop(conn_type);
    let slots: &[Slot] = if desktop {
        &[Slot { tag: TAG_AUDIO_BACK, n: 1 }, Slot { tag: TAG_KEY, n: 1 }]
    } else {
        &[]
    };
    // this device's number, for the caller's list of connections
    let me = l.info().and_then(|i| i.number).map(|n| n.to_string());
    let svc = match l.accept(r.service, Some(&json!({ "number": me })), slots).await {
        Ok(s) => s,
        Err(e) => return log::warn!("npf: the answer to {} failed: {e}", r.peer.number),
    };
    let number = r.peer.number;
    let addr = peer_addr(number);
    let ip = addr.ip().to_string();
    let cut = Arc::new(Cut::default());
    GRANTS.lock().unwrap().insert(
        ip.clone(),
        Grant {
            number,
            name: r.peer.name.clone(),
            role: r.peer.role,
            temp: r.peer.temp,
            via: r.peer.via.clone(),
            can: r.can.clone(),
            conn_type,
            asked: now(),
            since: None,
            conn_id: None,
            allowed: None,
            cut: cut.clone(),
        },
    );
    let granted = Granted(ip);
    log::info!(
        "npf: service {} from {number} ({:?}{}, can {:?}): conn type {conn_type}",
        svc.id,
        r.peer.role,
        if r.peer.temp { ", assist code" } else { "" },
        r.can
    );
    let stream = if desktop {
        Desk::start(svc, addr, cut, granted)
    } else {
        let ch = match svc.open.channel(TAG_DATA, 2).await {
            Ok(ch) => ch,
            Err(e) => return log::warn!("npf: no channel to {number}: {e}"),
        };
        let io = Whole { ch, _main: svc.main, cut, _granted: granted };
        Stream::Tcp(FramedStream::from(io, addr))
    };
    let meta = ConnectionMeta {
        control_permissions: withheld(&r.can),
        controlled_context: None,
    };
    let Some(server) = link::server() else {
        return;
    };
    if let Err(e) = create_tcp_connection(server.clone(), stream, addr, false, meta).await {
        log::warn!("npf: a connection from {number} failed: {e}");
    }
}

/// fd6e:7066:COUNTER:NUMBER, a new one for each connection
fn peer_addr(number: u64) -> SocketAddr {
    static NEXT: AtomicU32 = AtomicU32::new(0);
    let c = NEXT.fetch_add(1, Ordering::Relaxed).wrapping_add(1);
    let n = number;
    let seg = |s: u32| (n >> s) as u16;
    let ip = Ipv6Addr::new(0xfd6e, 0x7066, (c >> 16) as u16, c as u16, seg(48), seg(32), seg(16), seg(0));
    SocketAddr::new(IpAddr::V6(ip), 0)
}

/// RustDesk's permission names under each of npf's features
fn cap_of(permission: &str) -> Option<&'static str> {
    Some(match permission {
        "keyboard" | "clipboard" | "restart" | "block_input" | "privacy_mode" | "tunnel" => "control",
        "file" | "remote_printer" => "file",
        "terminal" => "terminal",
        _ => return None,
    })
}

/// RustDesk's permissions off for what `can` does not have
fn withheld(can: &[String]) -> Option<ControlPermissions> {
    use Permission::*;
    let has = |c: &str| can.iter().any(|x| x == c);
    let mut off = vec![];
    if !has("control") {
        off.extend([keyboard, clipboard, restart, block_input, privacy_mode, tunnel]);
    }
    if !has("file") {
        off.extend([file, remote_printer]);
    }
    if !has("terminal") {
        off.push(terminal);
    }
    if off.is_empty() {
        return None;
    }
    // two bits each: 1 off (crate::get_control_permission)
    let permissions = off.iter().fold(0u64, |p, x| p | 1 << (2 * *x as u64));
    Some(ControlPermissions {
        permissions,
        ..Default::default()
    })
}

/* ---- for RustDesk's connection (connection.rs) ---- */

/// The connection came over npf.
pub fn is_npf(ip: &str) -> bool {
    GRANTS.lock().unwrap().contains_key(ip)
}

/// It came with the assist code: someone must click to accept, whatever
/// RustDesk's approve mode (applink.md A10).
pub fn must_click(ip: &str) -> bool {
    GRANTS.lock().unwrap().get(ip).map_or(false, |g| g.temp)
}

/// It came from one of my devices (npf's admin: paired with the pairing
/// password, or the same account) or from a member (an invitation of this
/// device's owner that covers this service, for as long as it says: npf let
/// the stream in only because of it): accepted with no password and no
/// click. The assist code alone asks for a click.
pub fn auto_accept(ip: &str) -> bool {
    GRANTS.lock().unwrap().get(ip).map_or(false, |g| g.role.is_some() && !g.temp)
}

/// The name of the device behind an npf connection, as npf knows it (its
/// number when it has none); None for others.
pub fn peer_name(ip: &str) -> Option<String> {
    let g = GRANTS.lock().unwrap();
    let g = g.get(ip)?;
    Some(g.name.clone().filter(|n| !n.trim().is_empty()).unwrap_or_else(|| g.number.to_string()))
}

/// What the CM shows of an npf connection (its client's `npf`,
/// docs/npf-flutter-api.md), RustDesk's connection id noted; None for others.
pub fn cm_info(ip: &str, conn_id: i32, authorized: bool) -> Option<Value> {
    let mut g = GRANTS.lock().unwrap();
    let g = g.get_mut(ip)?;
    g.conn_id = Some(conn_id);
    if authorized {
        g.since.get_or_insert_with(now);
    }
    Some(json!({
        "number": g.number.to_string(),
        "name": g.name,
        "role": g.role.map(Role::word),
        "temp": g.temp,
        // the owner's name for the member and when it paired: not given by applink yet
        "label": null,
        "joined": null,
        "via": g.via,
        "can": g.can,
        "allowed": g.allowed(),
        "asked": g.asked,
        "since": g.since,
        "res": link::RES,
        "conn_type": g.conn_type,
    }))
}

/// The CM switches a permission: on only within what `can` granted, and
/// `allowed` follows.
pub fn permits(ip: &str, name: &str, enabled: bool) -> bool {
    let mut g = GRANTS.lock().unwrap();
    let Some(g) = g.get_mut(ip) else {
        return true;
    };
    let cap = match name {
        "keyboard" => Some("control"),
        "file" => Some("file"),
        _ => None,
    };
    if enabled {
        if let Some(c) = cap_of(name).filter(|c| !g.can(c)) {
            log::warn!("npf: {name} for {} refused: no {c}", g.number);
            return false;
        }
    }
    if let (Some(cap), Some(allowed)) = (cap, g.allowed.as_mut()) {
        allowed.retain(|c| c != cap);
        if enabled {
            allowed.push(cap.to_owned());
        }
    }
    true
}

/// The CM accepted connection `conn_id` with these of its `can` (the CM
/// process tells, over the main IPC: `npf-allow`).
pub fn allow(conn_id: i32, allowed: Vec<String>) {
    let mut g = GRANTS.lock().unwrap();
    if let Some(g) = g.values_mut().find(|g| g.conn_id == Some(conn_id)) {
        log::info!("npf: {} accepted with {allowed:?}", g.number);
        g.allowed = Some(allowed.into_iter().filter(|c| g.can.contains(c)).collect());
        g.since.get_or_insert_with(now);
    }
}

/// The peer's remote desktop here was accepted without this feature: its
/// other connections (file transfer, terminal) are refused too while it lasts.
fn withheld_in_session(number: u64, cap: &str) -> bool {
    GRANTS.lock().unwrap().values().any(|g| {
        g.number == number
            && is_desktop(g.conn_type)
            && g.allowed.as_ref().map_or(false, |a| !a.iter().any(|c| c == cap))
    })
}

/// Ends the npf connection `conn_id` (the UI's 断开: `npf-disconnect`).
pub fn disconnect(conn_id: i32) {
    let g = GRANTS.lock().unwrap();
    if let Some(g) = g.values().find(|g| g.conn_id == Some(conn_id)) {
        g.cut.cut();
    }
}

fn now() -> i64 {
    hbb_common::get_time() / 1000
}

/// `incoming` of the UI's state
pub fn incoming_json() -> Value {
    let authed: HashSet<i32> = crate::server::AUTHED_CONNS
        .lock()
        .unwrap()
        .iter()
        .map(|c| c.conn_id)
        .collect();
    let mut g = GRANTS.lock().unwrap();
    let list = g.values_mut().map(|g| {
        let authorized = g.conn_id.map_or(false, |i| authed.contains(&i));
        if authorized {
            g.since.get_or_insert_with(now);
        }
        json!({
            "id": g.conn_id,
            "peer": {
                "number": g.number.to_string(),
                "name": g.name,
                "role": g.role.map(Role::word),
                "temp": g.temp,
                "via": g.via,
            },
            "res": link::RES,
            "conn_type": g.conn_type,
            "can": g.can,
            "allowed": g.allowed(),
            "authorized": authorized,
            "asked": g.asked,
            "since": g.since,
        })
    });
    Value::Array(list.collect())
}

/* ---- the services ---- */

/// The socket of a RustDesk TCP connection on channel 1 (file transfer,
/// terminal, port forward, RDP); the main channel only keeps the service.
/// Dropped, the service ends.
struct Whole {
    ch: Channel,
    _main: Channel,
    cut: Arc<Cut>,
    _granted: Granted,
}

impl AsyncRead for Whole {
    fn poll_read(mut self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &mut ReadBuf<'_>) -> Poll<io::Result<()>> {
        if self.cut.poll(cx) {
            return Poll::Ready(Ok(())); // the end
        }
        Pin::new(&mut self.ch).poll_read(cx, buf)
    }
}

impl AsyncWrite for Whole {
    fn poll_write(mut self: Pin<&mut Self>, cx: &mut Context<'_>, b: &[u8]) -> Poll<io::Result<usize>> {
        Pin::new(&mut self.ch).poll_write(cx, b)
    }
    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.ch).poll_flush(cx)
    }
    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.ch).poll_shutdown(cx)
    }
}

/// A remote desktop's sending side: VideoFrame and AudioFrame on media
/// streams, the rest of RustDesk's messages on the main channel (its writer
/// task gives the credit back as they go).
pub struct Desk {
    /// npf's number of the service
    #[allow(dead_code)]
    id: u32,
    open: Opener,
    /// to the main channel's writer
    out: Mutex<Option<mpsc::UnboundedSender<Bytes>>>,
    /// the media streams opened (at their first frame): video 0..8, audio 8
    media: Mutex<[Option<Media>; 9]>,
    /// what the session's congestion control leaves for video, kbit/s
    rate_kbps: Arc<AtomicU32>,
    tasks: Mutex<Vec<JoinHandle<()>>>,
}

impl Desk {
    /// RustDesk's stream over the service: the main channel's reader (with
    /// the controlling side's audio and key frame requests) and writer.
    fn start(svc: Service, addr: SocketAddr, cut: Arc<Cut>, granted: Granted) -> Stream {
        let Service { id, main, open, mut incoming, .. } = svc;
        let (rd, mut wr) = tokio::io::split(main);
        let (rtx, rrx) = mpsc::unbounded_channel();
        let (wtx, mut wrx) = mpsc::unbounded_channel::<Bytes>();
        let credit = Arc::new(Semaphore::new(WINDOW));
        let c2 = credit.clone();
        let writer = tokio::spawn(async move {
            while let Some(b) = wrx.recv().await {
                if wr.write_all(&b).await.is_err() {
                    break;
                }
                c2.add_permits(b.len());
            }
            // a sender waiting for credit fails on its next send
            c2.close();
        });
        // the controlling side's media: they end with the service
        let weak = rtx.downgrade();
        let peer_media = tokio::spawn(async move {
            while let Some(o) = incoming.recv().await {
                let Opened::Media(tag, mut m) = o else { continue };
                let weak = weak.clone();
                tokio::spawn(async move {
                    while let Some(f) = m.recv().await {
                        if tag == TAG_KEY {
                            if let Some(d) = f.data.first().filter(|d| (**d as i32) < DISPLAYS) {
                                request_keyframe_rate_limited(*d as usize);
                            }
                        } else if let Some(tx) = weak.upgrade().filter(|_| tag == TAG_AUDIO_BACK) {
                            tx.send(super::audio_with_loss(&f.data, f.info.lost_before)).ok();
                        }
                    }
                });
            }
        });
        let reader = tokio::spawn(async move {
            let _granted = granted;
            let mut frames = FramedRead::new(rd, BytesCodec::new());
            loop {
                tokio::select! {
                    f = frames.next() => match f {
                        Some(Ok(f)) => { rtx.send(f).ok(); }
                        _ => break, // the end for RustDesk's reader, after what came
                    },
                    _ = cut.wait() => break,
                }
            }
        });
        let desk = Arc::new(Desk {
            id,
            open,
            out: Mutex::new(Some(wtx)),
            media: Default::default(),
            rate_kbps: Default::default(),
            tasks: Mutex::new(vec![writer, peer_media, reader]),
        });
        Stream::Msg(MsgStream::new(desk, rrx, credit, WINDOW, addr))
    }

    /// kbit/s the video may use on this connection's path (npf's target
    /// rate, less the audio); None before npf's first figures.
    pub fn video_kbps(&self) -> Option<u32> {
        Some(self.rate_kbps.load(Ordering::Relaxed)).filter(|r| *r > 0)
    }

    /// one frame on media stream i (opened at its first): Ok(false) dropped
    fn frame(&self, i: usize, key: bool, bytes: &[u8]) -> ResultType<bool> {
        let mut media = self.media.lock().unwrap();
        if media[i].is_none() {
            let audio = i == DISPLAYS as usize;
            let tag = if audio { TAG_AUDIO } else { TAG_VIDEO + i as i32 };
            let mut o = MediaOpt::new(tag);
            if audio {
                // ahead of everything, never late: Opus in-band FEC instead of npf's
                o.prio = 0;
                o.max_age_ms = 200;
                o.fec = Fec::Off;
            } else {
                // a frame still waiting after max_age is dropped with those that
                // depend on it, up to the next key frame (asked for in stats);
                // npf keeps a frame that has started going out, and a waiting
                // key frame until a newer one (libnpf's AnLiu patch 0001)
                o.prio = 1;
                o.drop_until_key = true;
                o.fec = Fec::Auto;
            }
            let m = self.open.media(&o)?;
            if !audio {
                self.tasks.lock().unwrap().push(tokio::spawn(stats(m.stats(), i, self.rate_kbps.clone())));
            }
            media[i] = Some(m);
        }
        match media[i].as_ref().map(|m| m.send(key, bytes)) {
            Some(Ok(sent)) => Ok(sent),
            Some(Err(e)) => bail!("npf: {e}"),
            None => Ok(false),
        }
    }
}

/// npf's figures for a video stream, once a second
async fn stats(mut rx: tokio::sync::watch::Receiver<Option<MediaStats>>, display: usize, rate: Arc<AtomicU32>) {
    let mut seen = 0;
    while rx.changed().await.is_ok() {
        let Some(st) = rx.borrow_and_update().clone() else { continue };
        if st.frames_dropped > seen {
            request_keyframe_rate_limited(display);
        }
        seen = st.frames_dropped;
        // 90% of the target rate, 64 kbit/s of it for the audio
        let kbps = (st.target_rate as u64 * 8 / 1000 * 9 / 10).saturating_sub(64);
        rate.store(kbps.clamp(100, u32::MAX as u64) as u32, Ordering::Relaxed);
    }
}

impl MsgSink for Desk {
    fn send(&self, msg: Option<&dyn Any>, bytes: Bytes) -> ResultType<usize> {
        if let Some(m) = msg.and_then(|m| m.downcast_ref::<Message>()) {
            match &m.union {
                Some(message::Union::VideoFrame(vf)) if (0..DISPLAYS).contains(&vf.display) => {
                    let d = vf.display as usize;
                    let key = super::is_key(vf);
                    let sent = self.frame(d, key, &bytes)?;
                    if sent && key {
                        super::key_sent(d, bytes.len(), self.rate_kbps.load(Ordering::Relaxed));
                    }
                    if !sent {
                        // the queue is full: this frame is lost, so is what depends on it
                        request_keyframe_rate_limited(d);
                    }
                    #[cfg(feature = "npf-trace")]
                    super::trace::sent(self.id << 5 | d as u32, d as i32, super::is_key(vf), bytes.len(), !sent, self.rate_kbps.load(Ordering::Relaxed));
                    return Ok(0);
                }
                Some(message::Union::AudioFrame(_)) => {
                    self.frame(DISPLAYS as usize, true, &bytes)?;
                    return Ok(0);
                }
                _ => {}
            }
        }
        let mut frame = BytesMut::with_capacity(bytes.len() + 4);
        BytesCodec::new().encode(bytes, &mut frame)?;
        let n = frame.len();
        match &*self.out.lock().unwrap() {
            Some(tx) if tx.send(frame.freeze()).is_ok() => Ok(n),
            _ => bail!("npf: the connection is closed"),
        }
    }

    /// RustDesk's connection is over: the service ends (after what was written)
    fn close(&self) {
        self.out.lock().unwrap().take();
        for (i, t) in self.tasks.lock().unwrap().drain(..).enumerate() {
            if i != 0 {
                t.abort(); // not the writer: it ends with what is queued
            }
        }
        *self.media.lock().unwrap() = Default::default();
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

/// kbit/s an npf connection's path leaves for its video; None for other
/// connections or before npf's first figures.
pub fn video_kbps(stream: &Stream) -> Option<u32> {
    stream.msg_sink()?.as_any().downcast_ref::<Desk>()?.video_kbps()
}
