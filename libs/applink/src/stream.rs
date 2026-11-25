//! A service's streams (applink.md 4): channels are the connection's bytes,
//! media streams frames of `len(4, LE) kind flags frame_no(4, LE)
//! lost_before(4, LE) payload` (len counts from kind; kind 0 a frame, 1 the
//! frames npf dropped here, 2 npf's statistics).

use crate::link::Inner;
use crate::net::{linger, Conn};
use crate::types::{FrameInfo, MediaOpt, MediaStats, Slot};
use crate::{ErrorKind, Result, FRAME_MAX, TAG_MAX};
use bytes::{Buf, Bytes, BytesMut};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::io;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll, Waker};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, ReadBuf};
use tokio::sync::{mpsc, watch};

/// frames waiting to go to npf at most (then dropped up to a key frame)
const MEDIA_QUEUE: usize = FRAME_MAX + (1 << 20);
const HEAD: usize = 14;

/// One use of a resource, from the request (or the answer) until either
/// end closes its main channel.
pub struct Service {
    /// npf's number of it
    pub id: u32,
    /// the protocol version npf picked
    pub proto: String,
    /// the answer's body (the provider app's)
    pub body: Value,
    /// the media streams the requester may open
    pub slots: Vec<Slot>,
    /// the main channel: dropped (or shut down), the service ends
    pub main: Channel,
    /// further channels and media streams of it
    pub open: Opener,
    /// the streams the peer opens
    pub incoming: Incoming,
}

/// A stream the peer opened, by its tag.
pub enum Opened {
    Channel(i32, Channel),
    Media(i32, MediaRx),
}

/// The streams the peer opens in a service (they come through the idle
/// accept connections). A stream not taken (dropped) is closed.
pub struct Incoming(pub(crate) mpsc::UnboundedReceiver<Opened>);

impl Incoming {
    pub async fn recv(&mut self) -> Option<Opened> {
        self.0.recv().await
    }
}

/// a main channel's state the link shares: stopping
#[derive(Default)]
pub(crate) struct MainCtl {
    stop: AtomicBool,
    waker: Mutex<Option<Waker>>,
}

impl MainCtl {
    pub(crate) fn stop(&self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(w) = self.waker.lock().unwrap_or_else(|e| e.into_inner()).take() {
            w.wake();
        }
    }
}

/// a main channel's tie to its route: dropped, the service's streams no longer go to it
pub(crate) struct MainGuard {
    pub inner: Arc<Inner>,
    pub sid: u32,
    pub gen: u64,
    pub ctl: Arc<MainCtl>,
}

impl Drop for MainGuard {
    fn drop(&mut self) {
        self.inner.unregister(self.sid, self.gen);
    }
}

/// A channel: reliable bytes both ways. Shut down or dropped, it ends after
/// what was written (a main channel: its service ends).
pub struct Channel {
    conn: Conn,
    main: Option<MainGuard>,
}

impl Channel {
    pub(crate) fn new(conn: Conn, main: Option<MainGuard>) -> Channel {
        Channel { conn, main }
    }

    fn io(&mut self) -> io::Result<Pin<&mut (dyn crate::Io + 'static)>> {
        match self.conn.io.as_mut() {
            Some(io) => Ok(Pin::new(&mut **io)),
            None => Err(io::ErrorKind::NotConnected.into()),
        }
    }
}

impl AsyncRead for Channel {
    fn poll_read(mut self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &mut ReadBuf<'_>) -> Poll<io::Result<()>> {
        if let Some(g) = &self.main {
            // the link stops: the end, for the app to drop it
            *g.ctl.waker.lock().unwrap_or_else(|e| e.into_inner()) = Some(cx.waker().clone());
            if g.ctl.stop.load(Ordering::SeqCst) {
                return Poll::Ready(Ok(()));
            }
        }
        if !self.conn.buf.is_empty() {
            let n = buf.remaining().min(self.conn.buf.len());
            buf.put_slice(&self.conn.buf[..n]);
            self.conn.buf.advance(n);
            return Poll::Ready(Ok(()));
        }
        self.io()?.poll_read(cx, buf)
    }
}

impl AsyncWrite for Channel {
    fn poll_write(mut self: Pin<&mut Self>, cx: &mut Context<'_>, b: &[u8]) -> Poll<io::Result<usize>> {
        self.io()?.poll_write(cx, b)
    }
    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        self.io()?.poll_flush(cx)
    }
    /// the end of what this side writes (npf then closes the channel; its
    /// bytes still come until npf's end)
    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        self.io()?.poll_shutdown(cx)
    }
}

/// Opens a service's streams: channels (only the answering side) and media
/// streams it sends on (the requesting side: those its answer's slots left).
#[derive(Clone)]
pub struct Opener {
    inner: Arc<Inner>,
    service: u32,
    /// the requester's: what is left of each slot's tag
    slots: Option<Arc<Mutex<HashMap<i32, i32>>>>,
}

impl Opener {
    pub(crate) fn new(inner: &Arc<Inner>, service: u32, slots: Option<&[Slot]>) -> Opener {
        let slots = slots.map(|s| {
            let mut m = HashMap::new();
            for x in s {
                *m.entry(x.tag).or_insert(0) += x.n;
            }
            Arc::new(Mutex::new(m))
        });
        Opener {
            inner: inner.clone(),
            service,
            slots,
        }
    }

    /// A channel: tag 1..=59, prio 0..=3 (Denied on the requesting side).
    pub async fn channel(&self, tag: i32, prio: i32) -> Result<Channel> {
        if !(1..=TAG_MAX).contains(&tag) || !(0..=3).contains(&prio) {
            return Err(ErrorKind::Invalid.into());
        }
        if self.slots.is_some() {
            return Err(ErrorKind::Denied.into()); // only the answering side opens channels
        }
        let t = self.inner.target().ok_or(ErrorKind::State)?;
        let req = json!({ "service": self.service, "tag": tag, "prio": prio });
        let c = self.inner.upgrade(&t, "/v1/app/channel", &req, Some(self.inner.o.timeout)).await?;
        Ok(Channel::new(c, None))
    }

    /// A media stream this side sends on, usable at once: frames sent
    /// before npf took it wait (as later ones do when npf is behind).
    pub fn media(&self, opt: &MediaOpt) -> Result<Media> {
        if !opt.valid() {
            return Err(ErrorKind::Invalid.into());
        }
        let t = self.inner.target().ok_or(ErrorKind::State)?;
        let slot = match &self.slots {
            Some(s) => {
                let mut m = s.lock().unwrap_or_else(|e| e.into_inner());
                match m.get_mut(&opt.tag) {
                    Some(n) if *n > 0 => *n -= 1,
                    _ => return Err(ErrorKind::Denied.into()),
                }
                Some((s.clone(), opt.tag))
            }
            None => None,
        };
        let (tx, rx) = mpsc::unbounded_channel();
        let (stx, srx) = watch::channel(None);
        let queued = Arc::new(AtomicUsize::new(0));
        let inner = self.inner.clone();
        let body = opt.json(self.service);
        let q = queued.clone();
        tokio::spawn(async move {
            let timeout = inner.o.timeout;
            if let Ok(c) = inner.upgrade(&t, "/v1/app/media", &body, Some(timeout)).await {
                drop(inner);
                media_send(c, rx, q, stx).await;
            }
        });
        Ok(Media {
            tx,
            queued,
            skip: AtomicBool::new(false),
            stats: srx,
            slot,
        })
    }
}

/// A media stream this side sends on. Dropped, it ends after the frames queued.
pub struct Media {
    tx: mpsc::UnboundedSender<Vec<u8>>,
    queued: Arc<AtomicUsize>,
    /// a frame was dropped: the others too, up to a key frame
    skip: AtomicBool,
    stats: watch::Receiver<Option<MediaStats>>,
    slot: Option<(Arc<Mutex<HashMap<i32, i32>>>, i32)>,
}

impl Media {
    /// One frame; never waits: one that does not fit the queue is dropped,
    /// then those after it up to a key frame (Ok(false): dropped, time to
    /// ask the encoder for a key frame). Closed: the stream ended.
    pub fn send(&self, key: bool, frame: &[u8]) -> Result<bool> {
        if frame.is_empty() {
            return Err(ErrorKind::Invalid.into());
        }
        if frame.len() > FRAME_MAX {
            return Err(ErrorKind::TooBig.into());
        }
        if self.tx.is_closed() {
            return Err(ErrorKind::Closed.into());
        }
        let n = frame.len() + HEAD;
        let full = self.queued.load(Ordering::Relaxed) + n > MEDIA_QUEUE;
        if full {
            self.skip.store(true, Ordering::Relaxed);
        }
        if self.skip.load(Ordering::Relaxed) && (!key || full) {
            return Ok(false);
        }
        self.skip.store(false, Ordering::Relaxed);
        let mut f = Vec::with_capacity(n);
        f.extend_from_slice(&((frame.len() + 10) as u32).to_le_bytes());
        f.extend_from_slice(&[0, key as u8, 0, 0, 0, 0, 0, 0, 0, 0]);
        f.extend_from_slice(frame);
        self.queued.fetch_add(n, Ordering::Relaxed);
        self.tx.send(f).map(|_| true).map_err(|_| ErrorKind::Closed.into())
    }

    /// npf's statistics of it, once a second (changed() fails once the stream ended)
    pub fn stats(&self) -> watch::Receiver<Option<MediaStats>> {
        self.stats.clone()
    }
}

impl Drop for Media {
    fn drop(&mut self) {
        if let Some((s, tag)) = &self.slot {
            *s.lock().unwrap_or_else(|e| e.into_inner()).entry(*tag).or_insert(0) += 1;
        }
    }
}

/// the sending stream's connection: our frames out, npf's statistics in
async fn media_send(mut c: Conn, mut rx: mpsc::UnboundedReceiver<Vec<u8>>, queued: Arc<AtomicUsize>, stats: watch::Sender<Option<MediaStats>>) {
    let Some(io) = c.io.take() else { return };
    let mut buf = std::mem::take(&mut c.buf);
    let (mut r, mut w) = tokio::io::split(io);
    'run: loop {
        loop {
            match take_frame(&mut buf) {
                Ok(Some(f)) if f.kind == 2 => {
                    if let Ok(st) = serde_json::from_slice::<MediaStats>(&f.data) {
                        stats.send_replace(Some(st));
                    }
                }
                Ok(Some(_)) => {}
                Ok(None) => break,
                Err(()) => break 'run,
            }
        }
        tokio::select! {
            f = rx.recv() => {
                let Some(f) = f else { break };
                if w.write_all(&f).await.is_err() {
                    break 'run;
                }
                queued.fetch_sub(f.len(), Ordering::Relaxed);
            }
            n = r.read_buf(&mut buf) => {
                if !matches!(n, Ok(n) if n > 0) {
                    break;
                }
            }
        }
    }
    drop(rx);
    linger(r.unsplit(w)).await;
}

struct RawFrame {
    kind: u8,
    flags: u8,
    frame_no: u32,
    lost_before: u32,
    data: Bytes,
}

/// one whole frame off the front; Err: not a frame (the stream cannot go on)
fn take_frame(buf: &mut BytesMut) -> std::result::Result<Option<RawFrame>, ()> {
    if buf.len() < 4 {
        return Ok(None);
    }
    let len = u32::from_le_bytes([buf[0], buf[1], buf[2], buf[3]]) as usize;
    if !(10..=FRAME_MAX + 10).contains(&len) {
        return Err(());
    }
    if buf.len() < 4 + len {
        return Ok(None);
    }
    let mut f = buf.split_to(4 + len);
    let le = |p: &[u8]| u32::from_le_bytes([p[0], p[1], p[2], p[3]]);
    let (kind, flags, frame_no, lost_before) = (f[4], f[5], le(&f[6..]), le(&f[10..]));
    f.advance(HEAD);
    Ok(Some(RawFrame {
        kind,
        flags,
        frame_no,
        lost_before,
        data: f.freeze(),
    }))
}

/// One media frame received.
#[derive(Clone, Debug)]
pub struct Frame {
    pub data: Bytes,
    pub info: FrameInfo,
}

/// A media stream the peer sends on. Dropped, it is closed.
pub struct MediaRx {
    conn: Conn,
    skipped: u32,
}

impl MediaRx {
    pub(crate) fn new(conn: Conn) -> MediaRx {
        MediaRx { conn, skipped: 0 }
    }

    /// The next frame; None at the end.
    pub async fn recv(&mut self) -> Option<Frame> {
        loop {
            match take_frame(&mut self.conn.buf) {
                Err(()) => return None,
                Ok(Some(f)) if f.kind == 0 => {
                    let info = FrameInfo {
                        frame_no: f.frame_no,
                        key: f.flags & 1 != 0,
                        lost_before: f.lost_before,
                        skipped_before: std::mem::take(&mut self.skipped),
                    };
                    return Some(Frame { data: f.data, info });
                }
                // npf could not write them here: in the next frame's skipped_before
                Ok(Some(f)) if f.kind == 1 => self.skipped += f.lost_before,
                Ok(Some(_)) => {} // newer than this library
                Ok(None) => {
                    if !matches!(self.conn.fill().await, Ok(n) if n > 0) {
                        return None;
                    }
                }
            }
        }
    }
}
