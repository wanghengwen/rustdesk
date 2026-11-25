//! The controlling side, in the service process: the UI process's request
//! (`npf-connect` on the main IPC) made with applink, and that IPC
//! connection then the RustDesk connection's transport. Android: the same
//! over an in-memory pipe (`ui::connect`), in this process.
//!
//! On the IPC, after the reply (`{"ok": true, "number"}` or
//! `{"error": WORD, "message"}`), each raw frame is
//!
//! - remote desktop: one RustDesk message; the UI's start with a byte, 0 for
//!   the main channel and 1 for its audio (media 19). Ours are the main
//!   channel's messages and the media's frames (video 10..17, audio 18) as
//!   they come; a lost video frame drops those after it up to the next key
//!   frame, which is asked for on media 20;
//! - the others: the bytes of channel 1, as they come.

use super::{audio_with_loss, is_desktop, link, needs, KeyWait, DISPLAYS, TAG_AUDIO, TAG_AUDIO_BACK, TAG_DATA, TAG_KEY, TAG_VIDEO};
#[cfg(target_os = "ios")]
use super::pipe::{ConnectionTmpl, Data};
#[cfg(not(target_os = "ios"))]
use crate::ipc::{ConnectionTmpl, Data};
use applink::{Error, ErrorKind, Fec, Media, MediaOpt, MediaRx, Opened, Opener, Service};
use base::message_proto::{Message, Misc};
use hbb_common::{
    bytes::BytesMut,
    bytes_codec::BytesCodec,
    futures::StreamExt,
    log,
    tokio::{
        self,
        io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
        sync::{mpsc, Notify},
        task::JoinSet,
    },
    protobuf::Message as _,
    tokio_util::codec::{Encoder, FramedRead},
};
use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    sync::{
        atomic::{AtomicU64, AtomicUsize, Ordering},
        Arc, Mutex,
    },
    time::{Duration, Instant},
};

const CHANNEL_WAIT: Duration = Duration::from_secs(30);
/// bytes for the UI not taken yet above which the channels' readers wait
/// (the rest waits in npf, and the peer stops once its window is full)
const HIGH: usize = 1 << 20;
/// ... and above which video frames are dropped here (a key frame asked for)
const DROP_AT: usize = 4 << 20;

#[derive(Default)]
struct Meter {
    since: Option<Instant>,
    bytes: u64,
    frames: u32,
    lost: u32,
    /// the last full second's
    kbps: Option<u64>,
    loss: Option<f64>,
}

/// a request of the UI's, for the UI's state
struct Call {
    target: String,
    conn_type: i32,
    since: i64,
    number: Mutex<Option<u64>>,
    meter: Mutex<Meter>,
}

static CALLS: Mutex<BTreeMap<u64, Arc<Call>>> = Mutex::new(BTreeMap::new());

impl Call {
    fn metered(&self, len: usize, lost: u32) {
        let mut m = self.meter.lock().unwrap();
        let since = *m.since.get_or_insert_with(Instant::now);
        m.bytes += len as u64;
        m.frames += 1;
        m.lost += lost;
        let dt = since.elapsed();
        if dt >= Duration::from_secs(1) {
            m.kbps = Some(m.bytes * 8 / dt.as_millis().max(1) as u64);
            m.loss = Some(m.lost as f64 / (m.frames + m.lost).max(1) as f64);
            (m.since, m.bytes, m.frames, m.lost) = (Some(Instant::now()), 0, 0, 0);
        }
    }
}

/// What waits for the UI, in order (None: the end), and its bytes.
struct ToUi {
    tx: mpsc::UnboundedSender<Option<BytesMut>>,
    queued: AtomicUsize,
    room: Notify,
}

impl ToUi {
    fn give(&self, b: BytesMut) {
        self.queued.fetch_add(b.len(), Ordering::Relaxed);
        self.tx.send(Some(b)).ok();
    }

    fn len(&self) -> usize {
        self.queued.load(Ordering::Relaxed)
    }

    /// the UI took n bytes
    fn taken(&self, n: usize) {
        if self.queued.fetch_sub(n, Ordering::Relaxed) - n < HIGH {
            self.room.notify_waiters();
        }
    }

    async fn room(&self) {
        loop {
            let n = self.room.notified();
            if self.len() < HIGH {
                return;
            }
            n.await;
        }
    }
}

/// The media streams of our slots, opened when first needed.
struct Ours {
    open: Opener,
    audio: Mutex<Option<Media>>,
    key: Mutex<Option<Media>>,
}

impl Ours {
    fn send(&self, which: &Mutex<Option<Media>>, tag: i32, data: &[u8]) {
        let mut m = which.lock().unwrap();
        if m.is_none() {
            let mut o = MediaOpt::new(tag);
            o.prio = 0;
            o.max_age_ms = 200;
            o.fec = Fec::Off;
            match self.open.media(&o) {
                Ok(x) => *m = Some(x),
                Err(e) => return log::warn!("npf: media {tag} not opened: {e}"),
            }
        }
        if let Some(x) = &*m {
            x.send(true, data).ok();
        }
    }
}

/// A media stream from the peer: audio as it comes; video up to the UI's
/// room, a lost frame dropping those after it up to the next key frame.
async fn media_in(tag: i32, mut rx: MediaRx, ui: Arc<ToUi>, call: Arc<Call>, ours: Arc<Ours>, _id: u32) {
    let mut wait = KeyWait::default();
    while let Some(f) = rx.recv().await {
        let lost = f.info.lost_before + f.info.skipped_before;
        call.metered(f.data.len(), lost);
        if tag == TAG_AUDIO {
            ui.give(audio_with_loss(&f.data, lost));
            continue;
        }
        // no room for the UI: dropped here, as if lost (a key frame goes)
        if !f.info.key && ui.len() > DROP_AT {
            wait.lost();
        }
        let w = wait.frame(f.info.key, lost);
        #[cfg(feature = "npf-trace")]
        super::trace::received(_id << 5 | (tag - TAG_VIDEO) as u32, f.info.key, f.data.len(), lost, w.is_some(), w == Some(true));
        match w {
            Some(true) => ours.send(&ours.key, TAG_KEY, &[(tag - TAG_VIDEO) as u8]),
            Some(false) => {}
            None => ui.give(BytesMut::from(&f.data[..])),
        }
    }
    #[cfg(feature = "npf-trace")]
    super::trace::forget(_id << 5 | (tag - TAG_VIDEO) as u32);
}

/// `npf-connect`: the request, then the IPC connection carries it.
pub async fn bridge<T: AsyncRead + AsyncWrite + Unpin>(value: String, stream: &mut ConnectionTmpl<T>) {
    let v: Value = serde_json::from_str(&value).unwrap_or_default();
    let target = v["target"].as_str().unwrap_or_default().to_owned();
    let conn_type = v["conn_type"].as_i64().unwrap_or(0) as i32;
    let fail = |e: &Error| {
        let v = json!({ "error": e.kind.word(), "message": e.message });
        Data::Config(("npf-connect".to_owned(), Some(v.to_string())))
    };
    if let Some(e) = link::down() {
        stream.send(&fail(&e)).await.ok();
        return;
    }
    if needs(conn_type).is_none() || target.is_empty() {
        stream.send(&fail(&Error::new(ErrorKind::Unsupported))).await.ok();
        return;
    }
    let Some(l) = link::link() else {
        return;
    };
    let desktop = is_desktop(conn_type);
    let call = Arc::new(Call {
        target: target.clone(),
        conn_type,
        since: hbb_common::get_time() / 1000,
        number: Mutex::new(target.parse().ok()),
        meter: Default::default(),
    });
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let key = NEXT.fetch_add(1, Ordering::Relaxed);
    CALLS.lock().unwrap().insert(key, call.clone());
    struct Listed(u64);
    impl Drop for Listed {
        fn drop(&mut self) {
            CALLS.lock().unwrap().remove(&self.0);
        }
    }
    let _listed = Listed(key);

    // npf waits for the peer's answer (someone may have to accept there)
    let svc = match l.request(&target, link::RES, Some(&json!({ "conn_type": conn_type }))).await {
        Ok(s) => s,
        Err(e) => {
            log::info!("npf: {target} refused: {e}");
            stream.send(&fail(&e)).await.ok();
            return;
        }
    };
    let number = svc.body["number"].as_str().and_then(|n| n.parse::<u64>().ok());
    if number.is_some() {
        *call.number.lock().unwrap() = number;
    }
    let Service { id, main, open, mut incoming, .. } = svc;
    log::info!("npf: service {id} with {target} (conn type {conn_type})");
    // the stream the UI's bytes go on; the main channel kept meanwhile
    let (ch, _main) = if desktop {
        (main, None)
    } else {
        let one = async {
            loop {
                match incoming.recv().await? {
                    Opened::Channel(TAG_DATA, c) => return Some(c),
                    _ => continue,
                }
            }
        };
        match tokio::time::timeout(CHANNEL_WAIT, one).await {
            Ok(Some(c)) => (c, Some(main)),
            _ => {
                stream.send(&fail(&Error::new(ErrorKind::Timeout))).await.ok();
                return;
            }
        }
    };

    let (tx, mut rx) = mpsc::unbounded_channel();
    let ui = Arc::new(ToUi { tx, queued: AtomicUsize::new(0), room: Notify::new() });
    let ours = Arc::new(Ours { open, audio: Default::default(), key: Default::default() });
    let (rd, mut wr) = tokio::io::split(ch);
    let (wtx, mut wrx) = mpsc::channel::<BytesMut>(16);
    // dropped at the end: every task stops, the service ends
    let mut tasks = JoinSet::new();
    tasks.spawn(async move {
        while let Some(b) = wrx.recv().await {
            if wr.write_all(&b).await.is_err() {
                break;
            }
        }
    });
    let u = ui.clone();
    tasks.spawn(async move {
        if desktop {
            let mut frames = FramedRead::new(rd, BytesCodec::new());
            while let Some(Ok(f)) = frames.next().await {
                u.room().await;
                u.give(f);
            }
        } else {
            let mut rd = rd;
            loop {
                u.room().await;
                let mut b = BytesMut::with_capacity(64 << 10);
                match rd.read_buf(&mut b).await {
                    Ok(n) if n > 0 => u.give(b),
                    _ => break,
                }
            }
        }
        u.tx.send(None).ok(); // the end, after what came
    });
    if desktop {
        let (u, c, o) = (ui.clone(), call.clone(), ours.clone());
        tasks.spawn(async move {
            let mut media = JoinSet::new();
            loop {
                tokio::select! {
                    s = incoming.recv() => match s {
                        Some(Opened::Media(tag, m)) if (TAG_VIDEO..TAG_VIDEO + DISPLAYS).contains(&tag) || tag == TAG_AUDIO => {
                            media.spawn(media_in(tag, m, u.clone(), c.clone(), o.clone(), id));
                        }
                        Some(_) => {}
                        None => break,
                    },
                    Some(_) = media.join_next() => {}
                }
            }
            while media.join_next().await.is_some() {}
        });
    }

    let ok = json!({ "ok": true, "number": number.map(|n| n.to_string()) }).to_string();
    if stream.send(&Data::Config(("npf-connect".to_owned(), Some(ok)))).await.is_err() {
        return;
    }
    let mut ended = false; // by the peer's side
    loop {
        tokio::select! {
            b = rx.recv() => {
                let Some(Some(b)) = b else {
                    ended = true;
                    break;
                };
                let n = b.len();
                if stream.send_raw(b.freeze()).await.is_err() {
                    break;
                }
                ui.taken(n);
            }
            r = async { let p = wtx.reserve().await.ok()?; stream.next_raw().await.ok().map(|b| (p, b)) } => {
                let Some((permit, mut b)) = r else { break };
                if !desktop {
                    permit.send(b);
                } else if b.first() == Some(&1) {
                    ours.send(&ours.audio, TAG_AUDIO_BACK, &b[1..]);
                } else {
                    let msg = b.split_off(1.min(b.len())).freeze();
                    let mut frame = BytesMut::with_capacity(msg.len() + 4);
                    if BytesCodec::new().encode(msg, &mut frame).is_err() {
                        break;
                    }
                    permit.send(frame);
                }
            }
        }
    }
    if ended && desktop {
        closed_there(stream, number).await;
    }
    log::info!("npf: service {id} with {target} over");
}

/// The service ended while npf still reaches the peer: ended there on
/// purpose (npf's disconnect, or the peer's ouDesk), so the session must
/// not reconnect; RustDesk's own disconnect says so with this close reason
/// (check_if_retry). A lost path is not told: the session retries.
async fn closed_there<T: AsyncRead + AsyncWrite + Unpin>(stream: &mut ConnectionTmpl<T>, number: Option<u64>) {
    tokio::time::sleep(Duration::from_millis(500)).await; // npf's state catches up
    if !number.map_or(false, |n| link::path_of(n).0.is_some()) {
        return;
    }
    let mut misc = Misc::new();
    misc.set_close_reason("Closed manually by the peer".to_owned());
    let mut msg = Message::new();
    msg.set_misc(misc);
    if let Ok(b) = msg.write_to_bytes() {
        stream.send_raw(b.into()).await.ok();
    }
}

/// `outgoing` of the UI's state
pub fn outgoing_json() -> Value {
    let calls: Vec<Arc<Call>> = CALLS.lock().unwrap().values().cloned().collect();
    let list = calls.iter().map(|c| {
        let number = *c.number.lock().unwrap();
        let (path, rtt) = number.map_or((None, None), link::path_of);
        let m = c.meter.lock().unwrap();
        json!({
            "id": c.target,
            "peer": number.map(|n| n.to_string()),
            "res": link::RES,
            "conn_type": c.conn_type,
            "since": c.since,
            "path": path,
            "rtt_ms": rtt,
            "kbps": m.kbps,
            "loss": m.loss,
        })
    });
    Value::Array(list.collect())
}
