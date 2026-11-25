//! The client against a fake npf in this process (docs/testcases/unit.md
//! AC-01..AC-12, as far as they apply to this API): a Unix socket (or a TCP
//! port) whose connections the tests answer by hand.

use crate::*;
use bytes::{Buf, BytesMut};
use serde_json::{json, Value};
use std::collections::VecDeque;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::mpsc;

const WAIT: Duration = Duration::from_secs(5);

fn tmpdir() -> PathBuf {
    static N: AtomicUsize = AtomicUsize::new(0);
    let d = std::env::temp_dir().join(format!("alkrs-{}-{}", std::process::id(), N.fetch_add(1, Ordering::Relaxed)));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir(&d).unwrap();
    std::fs::set_permissions(&d, std::fs::Permissions::from_mode(0o700)).unwrap();
    d
}

/// npf's end of a connection
struct Side {
    io: BoxIo,
    buf: BytesMut,
}

impl Side {
    async fn send(&mut self, line: Value) {
        self.io.write_all(format!("{line}\n").as_bytes()).await.unwrap();
    }
    async fn fill(&mut self) -> usize {
        self.buf.reserve(65536);
        tokio::time::timeout(WAIT, self.io.read_buf(&mut self.buf)).await.expect("npf waits").unwrap_or(0)
    }
    async fn bytes(&mut self, n: usize) -> Vec<u8> {
        while self.buf.len() < n {
            assert!(self.fill().await > 0, "the end before {n} bytes");
        }
        self.buf.split_to(n).to_vec()
    }
    /// the client closed it (nothing more came)
    async fn eof(&mut self) -> bool {
        self.buf.clear();
        self.fill().await == 0
    }
    async fn frame(&mut self, kind: u8, flags: u8, no: u32, lost: u32, payload: &[u8]) {
        let mut f = ((payload.len() + 10) as u32).to_le_bytes().to_vec();
        f.extend_from_slice(&[kind, flags]);
        f.extend_from_slice(&no.to_le_bytes());
        f.extend_from_slice(&lost.to_le_bytes());
        f.extend_from_slice(payload);
        self.io.write_all(&f).await.unwrap();
    }
    /// (kind, flags, payload)
    async fn read_frame(&mut self) -> (u8, u8, Vec<u8>) {
        let h = self.bytes(14).await;
        let len = u32::from_le_bytes([h[0], h[1], h[2], h[3]]) as usize;
        (h[4], h[5], self.bytes(len - 10).await)
    }
}

/// a request to npf, not answered yet
struct Req {
    path: String,
    head: String,
    body: Value,
    side: Side,
}

impl Req {
    fn header(&self, k: &str) -> Option<String> {
        self.head.split("\r\n").find_map(|l| {
            let (a, b) = l.split_once(':')?;
            a.eq_ignore_ascii_case(k).then(|| b.trim().to_owned())
        })
    }
    async fn up(mut self) -> Side {
        assert_eq!(self.header("Upgrade").as_deref(), Some("npf-app/1"), "{}", self.path);
        self.side.io.write_all(b"HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: npf-app/1\r\n\r\n").await.unwrap();
        self.side
    }
    async fn reply(mut self, status: u16, v: Value) {
        let b = v.to_string();
        let r = format!("HTTP/1.1 {status} X\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{b}", b.len());
        self.side.io.write_all(r.as_bytes()).await.unwrap();
        self.side.io.shutdown().await.ok();
    }
    async fn raw(mut self, text: &str) {
        self.side.io.write_all(text.as_bytes()).await.unwrap();
        self.side.io.shutdown().await.ok();
    }
}

/// the requests npf got, kept until a test takes them; accept connections
/// go up at once and wait in their own queue
struct Npf {
    dir: PathBuf,
    sock: PathBuf,
    rx: mpsc::UnboundedReceiver<Req>,
    backlog: VecDeque<Req>,
    accepts: mpsc::UnboundedReceiver<Side>,
    /// connections that sent nothing (refused by the client's check)
    silent: std::sync::Arc<AtomicUsize>,
    conns: std::sync::Arc<AtomicUsize>,
    task: tokio::task::JoinHandle<()>,
}

async fn parse(mut io: BoxIo) -> Option<Req> {
    let mut buf = BytesMut::new();
    let end = loop {
        if let Some(i) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            break i;
        }
        buf.reserve(4096);
        if io.read_buf(&mut buf).await.ok()? == 0 {
            return None;
        }
    };
    let head = String::from_utf8_lossy(&buf[..end]).into_owned();
    buf.advance(end + 4);
    let clen: usize = head
        .split("\r\n")
        .find_map(|l| l.strip_prefix("Content-Length: "))
        .and_then(|v| v.parse().ok())
        .unwrap_or(0);
    while buf.len() < clen {
        buf.reserve(clen);
        if io.read_buf(&mut buf).await.ok()? == 0 {
            return None;
        }
    }
    let body = serde_json::from_slice(&buf.split_to(clen)).unwrap_or(Value::Null);
    let path = head.split(' ').nth(1)?.to_owned();
    Some(Req {
        path,
        head,
        body,
        side: Side { io, buf },
    })
}

impl Npf {
    /// npf on a Unix socket in a directory of its own, applink.json written
    async fn start() -> Npf {
        let dir = tmpdir();
        let n = Npf::listen(dir.clone(), dir.join("app.sock"));
        n.write_json(json!({"version": 1, "unix": n.sock.to_str().unwrap(), "pid": std::process::id()}));
        n
    }

    fn listen(dir: PathBuf, sock: PathBuf) -> Npf {
        let _ = std::fs::remove_file(&sock);
        let l = tokio::net::UnixListener::bind(&sock).unwrap();
        let l = std::sync::Arc::new(l);
        Npf::serve(dir, sock, move || {
            let l = l.clone();
            async move { l.accept().await.ok().map(|(s, _)| Box::new(s) as BoxIo) }
        })
    }

    fn serve<F, Fut>(dir: PathBuf, sock: PathBuf, accept: F) -> Npf
    where
        F: Fn() -> Fut + Send + 'static,
        Fut: std::future::Future<Output = Option<BoxIo>> + Send,
    {
        let (tx, rx) = mpsc::unbounded_channel();
        let (atx, accepts) = mpsc::unbounded_channel();
        let silent = std::sync::Arc::new(AtomicUsize::new(0));
        let conns = std::sync::Arc::new(AtomicUsize::new(0));
        let (s2, c2) = (silent.clone(), conns.clone());
        let task = tokio::spawn(async move {
            while let Some(io) = accept().await {
                c2.fetch_add(1, Ordering::SeqCst);
                let (tx, atx, s2) = (tx.clone(), atx.clone(), s2.clone());
                tokio::spawn(async move {
                    match parse(io).await {
                        Some(r) if r.path == "/v1/app/accept" => {
                            atx.send(r.up().await).ok();
                        }
                        Some(r) => {
                            tx.send(r).ok();
                        }
                        None => {
                            s2.fetch_add(1, Ordering::SeqCst);
                        }
                    }
                });
            }
        });
        Npf {
            dir,
            sock,
            rx,
            backlog: VecDeque::new(),
            accepts,
            silent,
            conns,
            task,
        }
    }

    fn write_json(&self, v: Value) {
        let f = self.dir.join("applink.json");
        std::fs::write(&f, v.to_string()).unwrap();
        std::fs::set_permissions(&f, std::fs::Permissions::from_mode(0o600)).unwrap();
    }

    fn opts(&self) -> Options {
        let mut o = Options::new("rustdesk", &["rustdesk/1"]);
        o.dir = Some(self.dir.clone());
        o.timeout = Duration::from_millis(1500);
        o.retry = Duration::from_millis(100);
        o
    }

    /// the next request for `path` (others kept for later)
    async fn take(&mut self, path: &str) -> Req {
        if let Some(i) = self.backlog.iter().position(|r| r.path == path) {
            return self.backlog.remove(i).unwrap();
        }
        loop {
            let r = tokio::time::timeout(WAIT, self.rx.recv()).await.unwrap_or_else(|_| panic!("no {path}")).unwrap();
            if r.path == path {
                return r;
            }
            self.backlog.push_back(r);
        }
    }

    /// nothing for `path` within `d`
    async fn none(&mut self, path: &str, d: Duration) {
        let _ = tokio::time::timeout(d, async {
            while let Some(r) = self.rx.recv().await {
                self.backlog.push_back(r);
            }
        })
        .await;
        assert!(!self.backlog.iter().any(|r| r.path == path), "a {path} came");
    }

    async fn accept_conn(&mut self) -> Side {
        tokio::time::timeout(WAIT, self.accepts.recv()).await.expect("an accept connection").unwrap()
    }

    /// attach answered with 101 and this hello
    async fn attach(&mut self, hello: Value) -> (Req, Side) {
        let r = self.take("/v1/app/attach").await;
        let (head, body) = (r.head.clone(), r.body.clone());
        let mut s = r.up().await;
        s.send(hello).await;
        (
            Req {
                path: "/v1/app/attach".into(),
                head,
                body,
                side: Side {
                    io: Box::new(tokio::io::empty()),
                    buf: BytesMut::new(),
                },
            },
            s,
        )
    }
}

impl Drop for Npf {
    fn drop(&mut self) {
        self.task.abort();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn hello() -> Value {
    json!({
        "type": "hello", "node": "123456789", "name": "pc", "online": true, "account": true, "version": "0.9",
        "assist": {"code": "12345678901234", "expires": 1000},
        "peers": [
            {"number": "111", "name": "a", "mine": true, "online": true, "path": "p2p", "rtt_ms": 10,
             "services": [{"res": "desktop", "svc": "rustdesk", "proto": ["rustdesk/1"], "up": true, "can": ["view"]}]},
            {"number": "222", "name": null, "online": false, "path": "a_path_not_known", "until": null,
             "services": [{"res": "desktop", "svc": "rustdesk", "proto": ["rustdesk/1"], "up": true, "can": []}]}
        ],
        "share": 3
    })
}

async fn ev(e: &mut Events) -> Event {
    tokio::time::timeout(WAIT, e.recv()).await.expect("an event").expect("events go on")
}

/// no event within d
async fn quiet(e: &mut Events, d: Duration) {
    if let Ok(x) = tokio::time::timeout(d, e.recv()).await {
        panic!("unexpected {x:?}");
    }
}

async fn up(npf: &mut Npf, o: Options) -> (Link, Events, Side) {
    let (l, mut e) = Link::start(o).unwrap();
    let (_, s) = npf.attach(hello()).await;
    assert_eq!(ev(&mut e).await, Event::Up);
    // info, two peers, assist, share
    for _ in 0..5 {
        ev(&mut e).await;
    }
    (l, e, s)
}

fn down_kind(e: Event) -> ErrorKind {
    match e {
        Event::Down(x) => x.kind,
        x => panic!("not a down: {x:?}"),
    }
}

/* ---------------- AC-01 ---------------- */

#[test]
fn ac01_outside_runtime() {
    let o = Options::new("rustdesk", &["rustdesk/1"]);
    assert_eq!(Link::start(o).err().map(|e| e.kind), Some(ErrorKind::State));
}

#[tokio::test]
async fn ac01_checks() {
    let mut o = Options::new("", &["rustdesk/1"]);
    assert_eq!(Link::start(o.clone()).err().map(|e| e.kind), Some(ErrorKind::Invalid));
    o.app = "rustdesk".into();
    o.protos = (1..=5).map(|i| format!("rustdesk/{i}")).collect();
    assert_eq!(Link::start(o.clone()).err().map(|e| e.kind), Some(ErrorKind::Invalid));
    o.protos = vec!["rustdesk".into()];
    assert_eq!(Link::start(o.clone()).err().map(|e| e.kind), Some(ErrorKind::Invalid));

    let mut npf = Npf::start().await;
    let mut o = npf.opts();
    o.want.requests = false;
    let (l, _e) = Link::start(o).unwrap();
    // before attached
    assert_eq!(l.peers().err().map(|e| e.kind), Some(ErrorKind::State));
    assert!(l.info().is_none() && l.assist().is_none() && l.transport().is_none());
    assert_eq!(l.accept(1, None, &[]).await.err().map(|e| e.kind), Some(ErrorKind::State));
    assert_eq!(l.call("share/list", None).await.err().map(|e| e.kind), Some(ErrorKind::State));
    assert_eq!(l.assist_renew().await.err().map(|e| e.kind), Some(ErrorKind::State));
    assert_eq!(l.resources_set(&[]).err().map(|e| e.kind), Some(ErrorKind::Invalid));
    assert_eq!(l.resource_up("x", true).err().map(|e| e.kind), Some(ErrorKind::NotFound));
    let _s = npf.attach(hello()).await;
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert_eq!(l.accept(99, None, &[]).await.err().map(|e| e.kind), Some(ErrorKind::NotFound));
    l.stop().await;
    assert_eq!(l.request("111", "desktop", None).await.err().map(|e| e.kind), Some(ErrorKind::State));
    assert_eq!(l.call("share/list", None).await.err().map(|e| e.kind), Some(ErrorKind::State));
    assert!(l.info().is_none());
}

/* ---------------- AC-02 ---------------- */

#[tokio::test]
async fn ac02_no_npf_then_npf() {
    let mut npf = Npf::start().await;
    let json = std::fs::read_to_string(npf.dir.join("applink.json")).unwrap();
    std::fs::remove_file(npf.dir.join("applink.json")).unwrap();
    let (l, mut e) = Link::start(npf.opts()).unwrap();
    let t0 = std::time::Instant::now();
    let r = l.request("111", "desktop", None).await;
    assert_eq!(r.err().map(|e| e.kind), Some(ErrorKind::NoNpf));
    assert!(t0.elapsed() >= Duration::from_millis(1400), "waited the timeout");
    assert_eq!(down_kind(ev(&mut e).await), ErrorKind::NoNpf);
    quiet(&mut e, Duration::from_millis(600)).await; // once, though tried again
    std::fs::write(npf.dir.join("applink.json"), json).unwrap();
    std::fs::set_permissions(npf.dir.join("applink.json"), std::fs::Permissions::from_mode(0o600)).unwrap();
    let _s = npf.attach(hello()).await;
    assert_eq!(ev(&mut e).await, Event::Up);
    assert_eq!(l.transport(), Some(Transport::Unix));
}

/// retry_now ends the wait between attaches (npf came back in this process)
#[tokio::test]
async fn ac02_retry_now() {
    let mut npf = Npf::start().await;
    let json = std::fs::read_to_string(npf.dir.join("applink.json")).unwrap();
    std::fs::remove_file(npf.dir.join("applink.json")).unwrap();
    let mut o = npf.opts();
    o.retry = Duration::from_secs(20); // longer than WAIT
    let (l, mut e) = Link::start(o).unwrap();
    assert_eq!(down_kind(ev(&mut e).await), ErrorKind::NoNpf);
    std::fs::write(npf.dir.join("applink.json"), json).unwrap();
    std::fs::set_permissions(npf.dir.join("applink.json"), std::fs::Permissions::from_mode(0o600)).unwrap();
    l.retry_now();
    let _s = npf.attach(hello()).await;
    assert_eq!(ev(&mut e).await, Event::Up);
}

/* ---------------- AC-03 ---------------- */

/// the link gives up with `kind` and npf got nothing
async fn refused(npf: &Npf, o: Options, kind: ErrorKind) {
    let (l, mut e) = Link::start(o).unwrap();
    assert_eq!(down_kind(ev(&mut e).await), kind);
    quiet(&mut e, Duration::from_millis(400)).await;
    assert_eq!(l.request("1", "desktop", None).await.err().map(|e| e.kind), Some(kind));
    let _ = npf;
}

#[tokio::test]
async fn ac03_checks() {
    let mut npf = Npf::start().await;
    let f = npf.dir.join("applink.json");
    let mode = |p: &PathBuf, m| std::fs::set_permissions(p, std::fs::Permissions::from_mode(m)).unwrap();

    mode(&f, 0o666);
    refused(&npf, npf.opts(), ErrorKind::Auth).await;
    mode(&f, 0o600);
    mode(&npf.dir, 0o777);
    refused(&npf, npf.opts(), ErrorKind::Auth).await;
    mode(&npf.dir, 0o700);
    let mut o = npf.opts();
    o.fake.file = Some(4242);
    refused(&npf, o, ErrorKind::Auth).await;
    assert_eq!(npf.conns.load(Ordering::SeqCst), 0, "nothing connected");
    // a link in applink.json's place
    let real = npf.dir.join("real.json");
    std::fs::rename(&f, &real).unwrap();
    std::os::unix::fs::symlink(&real, &f).unwrap();
    refused(&npf, npf.opts(), ErrorKind::Auth).await;
    std::fs::remove_file(&f).unwrap();
    std::fs::rename(&real, &f).unwrap();

    // the socket's peer another account: connected, nothing sent
    let mut o = npf.opts();
    o.fake.peer = Some(4242);
    refused(&npf, o, ErrorKind::Auth).await;
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert!(npf.silent.load(Ordering::SeqCst) >= 1);
    npf.none("/v1/app/attach", Duration::from_millis(100)).await;

    // a protocol this library does not speak: tried again later
    let json = std::fs::read_to_string(&f).unwrap();
    npf.write_json(json!({"version": 2, "unix": npf.sock.to_str().unwrap()}));
    let (l, mut e) = Link::start(npf.opts()).unwrap();
    assert_eq!(down_kind(ev(&mut e).await), ErrorKind::Proto);
    l.stop().await;
    std::fs::write(&f, &json).unwrap();

    // npf does not know this app / the person said no: given up, npf's words kept
    for (word, kind) in [("unknown_app", ErrorKind::Auth), ("denied", ErrorKind::Denied)] {
        let (l, mut e) = Link::start(npf.opts()).unwrap();
        npf.take("/v1/app/attach").await.reply(403, json!({"error": word, "message": "no such app"})).await;
        match ev(&mut e).await {
            Event::Down(x) => {
                assert_eq!(x.kind, kind);
                assert_eq!(x.message.as_deref(), Some("no such app"));
            }
            x => panic!("{x:?}"),
        }
        assert_eq!(l.last_error().as_deref(), Some("no such app"));
        npf.none("/v1/app/attach", Duration::from_millis(400)).await;
        l.stop().await;
    }
}

/* ---------------- AC-04 ---------------- */

#[tokio::test]
async fn ac04_events() {
    let mut npf = Npf::start().await;
    let (l, mut e) = Link::start(npf.opts()).unwrap();
    let (a, mut s) = npf.attach(hello()).await;
    assert_eq!(a.header("Host").as_deref(), Some("localhost"));
    assert_eq!(a.header("Npf-App").as_deref(), Some("rustdesk"));
    assert_eq!(a.header("Connection").as_deref(), Some("Upgrade"));
    assert_eq!(a.body, json!({"events": true, "want": ["peer", "assist", "quota", "request", "share", "open"], "protos": ["rustdesk/1"]}));
    assert_eq!(ev(&mut e).await, Event::Up);
    match ev(&mut e).await {
        Event::Info(i) => assert_eq!((i.number, i.name.as_str(), i.online, i.account), (Some(123456789), "pc", true, true)),
        x => panic!("{x:?}"),
    }
    let mut seen = vec![];
    for _ in 0..4 {
        seen.push(ev(&mut e).await);
    }
    assert!(seen.iter().any(|x| matches!(x, Event::Peer(p) if p.number == 111 && p.path == Some(Path::P2p) && p.rtt_ms == Some(10))));
    assert!(seen.iter().any(|x| matches!(x, Event::Peer(p) if p.number == 222 && !p.online && p.name.is_empty() && p.path.is_none())));
    assert!(seen.iter().any(|x| matches!(x, Event::Assist(a) if a.code.as_deref() == Some("12345678901234"))));
    assert!(seen.contains(&Event::Share(3)));
    assert_eq!(l.info().and_then(|i| i.number), Some(123456789));
    assert_eq!(l.peers().unwrap().len(), 2);
    assert_eq!(l.peers().unwrap()[0].services[0].protos, vec!["rustdesk/1".to_string()]);
    assert!(l.assist().is_some());

    // a hello again: 111 changed, 222 gone, 333 new; only those told
    let mut h = hello();
    h["peers"] = json!([
        {"number": "111", "name": "a2", "mine": true, "online": true, "path": "relay",
         "services": [{"res": "desktop", "svc": "rustdesk", "proto": ["rustdesk/1"], "up": true, "can": ["view"]}]},
        {"number": 333, "name": "c", "online": true,
         "services": [{"res": "desktop", "svc": "rustdesk", "proto": ["rustdesk/1"], "up": false, "can": []}]}
    ]);
    s.send(h).await;
    let mut seen = vec![];
    for _ in 0..3 {
        match ev(&mut e).await {
            Event::Peer(p) => seen.push((p.number, p.gone)),
            x => panic!("{x:?}"),
        }
    }
    seen.sort();
    assert_eq!(seen, vec![(111, false), (222, true), (333, false)]);
    quiet(&mut e, Duration::from_millis(200)).await;

    // a peer event the same as the copy; one whose services are empty
    s.send(json!({"type": "peer", "number": "333", "name": "c", "online": true,
        "services": [{"res": "desktop", "svc": "rustdesk", "proto": ["rustdesk/1"], "up": false, "can": []}]})).await;
    s.send(json!({"type": "peer", "number": "333", "services": []})).await;
    match ev(&mut e).await {
        Event::Peer(p) => assert!(p.number == 333 && p.gone && p.name == "c"),
        x => panic!("{x:?}"),
    }
    assert_eq!(l.peers().unwrap().len(), 1);
    s.send(json!({"type": "quota", "used": 5, "limit": 100})).await;
    assert_eq!(ev(&mut e).await, Event::Quota { used: 5, limit: 100 });
    s.send(json!({"type": "assist", "code": null, "why": "no_owner"})).await;
    assert!(matches!(ev(&mut e).await, Event::Assist(a) if a.code.is_none() && a.why.as_deref() == Some("no_owner")));
    s.send(json!({"type": "something_new", "x": 1})).await;
    s.send(json!({"type": "info", "node": 123456789, "name": "pc2", "online": false, "account": true, "version": "0.9"})).await;
    assert!(matches!(ev(&mut e).await, Event::Info(i) if i.name == "pc2" && !i.online));
    assert_eq!(l.info().map(|i| i.name), Some("pc2".into()));
}

/* ---------------- AC-05 ---------------- */

#[tokio::test]
async fn ac05_requester() {
    let mut npf = Npf::start().await;
    let (l, e) = Link::start(npf.opts()).unwrap();
    // asked before the link is up: it goes once npf is there
    let l2 = l.clone();
    let req = tokio::spawn(async move { l2.request("111", "desktop", Some(&json!({ "a" : 1 }))).await });
    tokio::time::sleep(Duration::from_millis(200)).await;
    let (_, _ev) = npf.attach(hello()).await;
    let r = npf.take("/v1/app/request").await;
    assert_eq!(r.body, json!({"peer": "111", "res": "desktop", "body": {"a": 1}}));
    let mut m = r.up().await;
    m.send(json!({"service": 9, "proto": "rustdesk/1", "body": {"number": "5"}, "slots": [{"kind": "media", "tag": 19, "n": 1}, {"kind": "x", "tag": 3, "n": 1}]})).await;
    m.io.write_all(b"early bytes").await.unwrap();
    let mut s = req.await.unwrap().unwrap();
    assert_eq!((s.id, s.proto.as_str(), &s.body), (9, "rustdesk/1", &json!({"number": "5"})));
    assert_eq!(s.slots, vec![Slot { tag: 19, n: 1 }]);
    let mut b = [0u8; 11];
    s.main.read_exact(&mut b).await.unwrap();
    assert_eq!(&b, b"early bytes");
    s.main.write_all(b"to the peer").await.unwrap();
    assert_eq!(m.bytes(11).await, b"to the peer");

    // media: within the slots; beyond them, and channels, Denied
    assert_eq!(s.open.channel(1, 2).await.err().map(|e| e.kind), Some(ErrorKind::Denied));
    let md = s.open.media(&MediaOpt::new(19)).unwrap();
    assert_eq!(s.open.media(&MediaOpt::new(19)).err().map(|e| e.kind), Some(ErrorKind::Denied));
    assert_eq!(s.open.media(&MediaOpt::new(10)).err().map(|e| e.kind), Some(ErrorKind::Denied));
    md.send(true, b"audio").unwrap();
    let mr = npf.take("/v1/app/media").await;
    assert_eq!((mr.body["service"].clone(), mr.body["tag"].clone()), (json!(9), json!(19)));
    let mut ms = mr.up().await;
    assert_eq!(ms.read_frame().await, (0, 1, b"audio".to_vec()));
    drop(md); // the slot is free again
    let md = s.open.media(&MediaOpt::new(19)).unwrap();
    drop(md);
    assert!(ms.eof().await);

    // the peer closes the main channel: its end here
    drop(m);
    let mut rest = vec![];
    assert_eq!(s.main.read_to_end(&mut rest).await.unwrap(), 0);

    // withdrawn before the answer: npf sees the connection end
    let l2 = l.clone();
    let req = tokio::spawn(async move { l2.request("111", "desktop", None).await });
    let mut w = npf.take("/v1/app/request").await.up().await;
    req.abort();
    assert!(w.eof().await);
    drop(e);
}

/* ---------------- AC-06 ---------------- */

#[tokio::test]
async fn ac06_errors() {
    let mut npf = Npf::start().await;
    let (l, _e, _s) = { let o = npf.opts(); up(&mut npf, o) }.await;
    let words = [
        ("forbidden", ErrorKind::NoAccess),
        ("offline", ErrorKind::Offline),
        ("not_found", ErrorKind::NoPeer),
        ("not_paired", ErrorKind::NotPaired),
        ("need_account", ErrorKind::NeedAccount),
        ("no_path", ErrorKind::NoPath),
        ("no_relay", ErrorKind::NoRelay),
        ("quota", ErrorKind::Quota),
        ("bad_code", ErrorKind::BadCode),
        ("remote_access_off", ErrorKind::NoRemote),
        ("unavailable", ErrorKind::Unavailable),
        ("unsupported", ErrorKind::Unsupported),
        ("refused", ErrorKind::Refused),
        ("timeout", ErrorKind::Timeout),
        ("limit", ErrorKind::Limit),
        ("version", ErrorKind::Version),
        ("busy", ErrorKind::Busy),
        ("denied", ErrorKind::Denied),
        ("whatever", ErrorKind::Denied),
    ];
    for (w, k) in words {
        let l2 = l.clone();
        let r = tokio::spawn(async move { l2.request("111", "desktop", None).await });
        npf.take("/v1/app/request").await.reply(403, json!({"error": w, "message": format!("m {w}"), "body": {"why": 1}})).await;
        let err = r.await.unwrap().err().unwrap();
        assert_eq!(err.kind, k, "{w}");
        assert_eq!(err.message, Some(format!("m {w}")));
        assert_eq!(err.reply.as_ref().map(|j| j["body"].clone()), Some(json!({"why": 1})));
        assert_eq!(l.last_error(), Some(format!("m {w}")));
    }
    let l2 = l.clone();
    let r = tokio::spawn(async move { l2.request("111", "desktop", None).await });
    npf.take("/v1/app/request").await.raw("HTTP/1.1 500 X\r\nContent-Length: 4\r\n\r\noops").await;
    assert_eq!(r.await.unwrap().err().map(|e| e.kind), Some(ErrorKind::Proto));

    // checked here, nothing sent
    let big = json!({ "x": "y".repeat(8200) });
    assert_eq!(l.request("111", "desktop", Some(&big)).await.err().map(|e| e.kind), Some(ErrorKind::TooBig));
    assert_eq!(l.request("111", "desktop", Some(&json!([1]))).await.err().map(|e| e.kind), Some(ErrorKind::Invalid));
    assert_eq!(l.request("111", "Desk top", None).await.err().map(|e| e.kind), Some(ErrorKind::Invalid));
    assert_eq!(l.request("", "desktop", None).await.err().map(|e| e.kind), Some(ErrorKind::Invalid));
    npf.none("/v1/app/request", Duration::from_millis(200)).await;
}

/* ---------------- AC-07 ---------------- */

#[tokio::test]
async fn ac07_provider() {
    let mut npf = Npf::start().await;
    let (l, mut e, mut s) = { let o = npf.opts(); up(&mut npf, o) }.await;
    let mut a1 = npf.accept_conn().await;
    let mut a2 = npf.accept_conn().await;
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(npf.accepts.try_recv().is_err(), "two accept connections, no more");

    s.send(json!({"type": "request", "service": 7, "res": "desktop", "proto": "rustdesk/1",
        "peer": {"number": "111", "name": "a", "role": "admin", "temp": false},
        "can": ["view", "control"], "body": {"x": 1}})).await;
    let r = match ev(&mut e).await {
        Event::Request(r) => r,
        x => panic!("{x:?}"),
    };
    assert_eq!((r.service, r.res.as_str(), r.proto.as_str(), r.peer.number, r.peer.role), (7, "desktop", "rustdesk/1", 111, Some(Role::Admin)));
    assert!(r.can("control") && !r.can("file"));
    assert_eq!(r.body, json!({"x": 1}));

    let l2 = l.clone();
    let acc = tokio::spawn(async move { l2.accept(7, Some(&json!({"number": "1"})), &[Slot { tag: 19, n: 2 }]).await });
    let ar = npf.take("/v1/app/answer").await;
    assert_eq!(ar.body, json!({"service": 7, "accept": true, "body": {"number": "1"}, "slots": [{"kind": "media", "tag": 19, "n": 2}]}));
    // the requester's channel comes before npf's 101 is read
    a1.send(json!({"service": 7, "kind": "media", "tag": 19})).await;
    let mut m = ar.up().await;
    let mut svc = acc.await.unwrap().unwrap();
    assert_eq!(svc.proto, "rustdesk/1");
    m.io.write_all(b"ping").await.unwrap();
    let mut b = [0u8; 4];
    svc.main.read_exact(&mut b).await.unwrap();
    svc.main.write_all(b"pong").await.unwrap();
    assert_eq!(m.bytes(4).await, b"pong");

    // frames on the peer's media stream: 100 bytes, a skip, 3 MB in pieces, stats, a kind not known
    let mut rx = match tokio::time::timeout(WAIT, svc.incoming.recv()).await.unwrap().unwrap() {
        Opened::Media(19, rx) => rx,
        _ => panic!("not the media stream"),
    };
    let _a3 = npf.accept_conn().await; // the one taken is made up for
    a1.frame(0, 1, 1, 0, &[7u8; 100]).await;
    a1.frame(1, 0, 0, 3, &[]).await;
    a1.frame(2, 0, 0, 0, b"{}").await;
    a1.frame(9, 0, 0, 0, b"new").await;
    let big: Vec<u8> = (0..3 << 20).map(|i| i as u8).collect();
    let mut f = ((big.len() + 10) as u32).to_le_bytes().to_vec();
    f.extend_from_slice(&[0, 0]);
    f.extend_from_slice(&5u32.to_le_bytes());
    f.extend_from_slice(&2u32.to_le_bytes());
    f.extend_from_slice(&big);
    let w = tokio::spawn(async move {
        for c in f.chunks(100_000) {
            a1.io.write_all(c).await.unwrap();
            tokio::task::yield_now().await;
        }
        a1
    });
    let f1 = rx.recv().await.unwrap();
    assert_eq!((f1.data.len(), f1.info.frame_no, f1.info.key, f1.info.skipped_before), (100, 1, true, 0));
    let f2 = rx.recv().await.unwrap();
    assert_eq!((f2.info.frame_no, f2.info.key, f2.info.lost_before, f2.info.skipped_before), (5, false, 2, 3));
    assert!(f2.data[..] == big[..]);
    let _a1 = w.await.unwrap();

    // a channel the peer opened, and one of ours
    a2.send(json!({"service": 7, "kind": "channel", "tag": 3})).await;
    a2.io.write_all(b"chan").await.unwrap();
    let mut ch = match tokio::time::timeout(WAIT, svc.incoming.recv()).await.unwrap().unwrap() {
        Opened::Channel(3, c) => c,
        _ => panic!("not the channel"),
    };
    ch.read_exact(&mut b).await.unwrap();
    assert_eq!(&b, b"chan");
    let o2 = svc.open.clone();
    let oc = tokio::spawn(async move { o2.channel(1, 2).await });
    let cr = npf.take("/v1/app/channel").await;
    assert_eq!(cr.body, json!({"service": 7, "tag": 1, "prio": 2}));
    let mut cs = cr.up().await;
    let mut och = oc.await.unwrap().unwrap();
    och.write_all(b"data").await.unwrap();
    assert_eq!(cs.bytes(4).await, b"data");

    // our media stream: frames sent before npf took it, checks, npf's stats
    let md = svc.open.media(&MediaOpt::new(10)).unwrap();
    md.send(true, b"k1").unwrap();
    md.send(false, b"d2").unwrap();
    assert_eq!(md.send(false, b"").err().map(|e| e.kind), Some(ErrorKind::Invalid));
    assert_eq!(md.send(false, &vec![0; FRAME_MAX + 1]).err().map(|e| e.kind), Some(ErrorKind::TooBig));
    let mr = npf.take("/v1/app/media").await;
    assert_eq!(mr.body["tag"], 10);
    assert_eq!(mr.body["fec"], -1);
    let mut ms = mr.up().await;
    assert_eq!(ms.read_frame().await, (0, 1, b"k1".to_vec()));
    assert_eq!(ms.read_frame().await, (0, 0, b"d2".to_vec()));
    let mut st = md.stats();
    ms.frame(2, 0, 0, 0, br#"{"target_rate": 125000, "srtt_ms": 20, "frames_dropped": 2, "capacity_short": 1}"#).await;
    tokio::time::timeout(WAIT, st.changed()).await.unwrap().unwrap();
    let x = st.borrow().clone().unwrap();
    assert_eq!((x.target_rate, x.srtt_ms, x.frames_dropped, x.capacity_short), (125000, 20, 2, true));

    // the queue full (npf not there yet): dropped, then up to a key frame
    let md2 = svc.open.media(&MediaOpt::new(11)).unwrap();
    let big = vec![5u8; 4 << 20];
    assert_eq!(md2.send(true, &big).ok(), Some(true));
    assert_eq!(md2.send(false, &vec![6u8; 3 << 19]).ok(), Some(false));
    assert_eq!(md2.send(false, b"after").ok(), Some(false));
    assert_eq!(md2.send(true, b"key").ok(), Some(true));
    let mut ms2 = npf.take("/v1/app/media").await.up().await;
    assert_eq!(ms2.read_frame().await, (0, 1, big));
    assert_eq!(ms2.read_frame().await, (0, 1, b"key".to_vec()));
    drop(md2);
    assert!(ms2.eof().await);

    // a second request withdrawn
    s.send(json!({"type": "request", "service": 8, "res": "desktop", "proto": "rustdesk/1",
        "peer": {"number": "111"}, "can": [], "body": {}})).await;
    assert!(matches!(ev(&mut e).await, Event::Request(r) if r.service == 8));
    s.send(json!({"type": "cancel", "service": 8, "why": "closed"})).await;
    assert_eq!(ev(&mut e).await, Event::Cancel { service: 8, why: ErrorKind::Closed });
    assert_eq!(l.accept(8, None, &[]).await.err().map(|e| e.kind), Some(ErrorKind::NotFound));

    // the peer closes the main channel: its end here
    drop(m);
    let mut rest = vec![];
    svc.main.read_to_end(&mut rest).await.unwrap();
    // dropped here: npf sees the end of our streams
    drop(svc);
    drop(md);
    assert!(ms.eof().await);
}

#[tokio::test]
async fn ac07_refuse() {
    let mut npf = Npf::start().await;
    let (l, mut e, mut s) = { let o = npf.opts(); up(&mut npf, o) }.await;
    s.send(json!({"type": "request", "service": 4, "res": "desktop", "proto": "rustdesk/1",
        "peer": {"number": "111"}, "can": [], "body": {}})).await;
    assert!(matches!(ev(&mut e).await, Event::Request(_)));
    let l2 = l.clone();
    let r = tokio::spawn(async move { l2.refuse(4, Some(&json!({"error": "no_permission"}))).await });
    let a = npf.take("/v1/app/answer").await;
    assert_eq!(a.body, json!({"service": 4, "accept": false, "body": {"error": "no_permission"}}));
    a.reply(200, json!({})).await;
    r.await.unwrap().unwrap();
}

/* ---------------- AC-08 ---------------- */

#[tokio::test]
async fn ac08_resources() {
    let mut npf = Npf::start().await;
    let (l, mut e) = Link::start(npf.opts()).unwrap();
    let r = |n: &str| Resource::new(n, "rustdesk", &["view", "control"]);
    let inv = |x: Result<()>| x.err().map(|e| e.kind);
    assert_eq!(inv(l.resources_set(&[r("a"), r("a")])), Some(ErrorKind::Invalid));
    assert_eq!(inv(l.resources_set(&[r("A b")])), Some(ErrorKind::Invalid));
    assert_eq!(inv(l.resources_set(&[Resource::new("a", "rustdesk", &["has_under"])])), Some(ErrorKind::Invalid));
    assert_eq!(inv(l.resources_set(&[Resource::new("a", "rustdesk", &["sixteen-letters1"])])), Some(ErrorKind::Invalid));
    assert_eq!(inv(l.resources_set(&(0..17).map(|i| r(&format!("r{i}"))).collect::<Vec<_>>())), Some(ErrorKind::Invalid));
    let big: Vec<Resource> = (0..16)
        .map(|i| {
            let mut x = r(&format!("r{i}"));
            x.title = Some("\u{1}".repeat(64));
            x.desc = Some("\u{1}".repeat(256)); // 6 bytes each in JSON
            x.caps = (0..16).map(|c| format!("cap-number-{c:04}")).collect();
            x
        })
        .collect();
    assert_eq!(inv(l.resources_set(&big)), Some(ErrorKind::TooBig));

    let mut desk = r("desktop");
    desk.title = Some("This PC".into());
    l.resources_set(&[desk.clone()]).unwrap();
    let mut h = hello();
    h["resources"] = json!({"desktop": "published"});
    let (_, mut s) = npf.attach(h).await;
    let q = npf.take("/v1/app/resources").await;
    assert_eq!(q.body, json!({"resources": [{"name": "desktop", "title": "This PC", "svc": "rustdesk", "caps": ["view", "control"], "up": true}]}));
    q.reply(200, json!({"states": {"desktop": "admin_only"}})).await;
    let mut got = None;
    for _ in 0..8 {
        if let Event::Resources(v) = ev(&mut e).await {
            got = Some(v);
            break;
        }
    }
    assert_eq!(got, Some(vec![("desktop".to_string(), ResourceState::AdminOnly)]));

    l.resource_up("desktop", false).unwrap();
    let q = npf.take("/v1/app/resources").await;
    assert_eq!(q.body, json!({"up": {"desktop": false}}));
    q.reply(200, json!({})).await;
    s.send(json!({"type": "resource", "name": "desktop", "state": "off"})).await;
    assert_eq!(ev(&mut e).await, Event::Resource("desktop".into(), ResourceState::Off));
    // a hello again: only what changed
    let mut h = hello();
    h["resources"] = json!({"desktop": "off"});
    s.send(h.clone()).await;
    quiet(&mut e, Duration::from_millis(200)).await;
    h["resources"] = json!({"desktop": "published"});
    s.send(h).await;
    assert_eq!(ev(&mut e).await, Event::Resource("desktop".into(), ResourceState::Published));

    // npf again: the whole list, with up as changed; npf refuses it
    drop(s);
    assert!(matches!(ev(&mut e).await, Event::Down(_)));
    let _s = npf.attach(hello()).await;
    let q = npf.take("/v1/app/resources").await;
    assert_eq!(q.body["resources"][0]["up"], false);
    q.reply(403, json!({"error": "denied", "message": "no"})).await;
    loop {
        if let Event::Resources(v) = ev(&mut e).await {
            assert_eq!(v, vec![("desktop".to_string(), ResourceState::Failed(ErrorKind::Denied))]);
            break;
        }
    }
}

/* ---------------- AC-09 ---------------- */

#[tokio::test]
async fn ac09_reconnect_replaced() {
    let mut npf = Npf::start().await;
    let (l, mut e, mut s) = { let o = npf.opts(); up(&mut npf, o) }.await;
    s.send(json!({"type": "request", "service": 5, "res": "desktop", "proto": "rustdesk/1",
        "peer": {"number": "111"}, "can": [], "body": {}})).await;
    assert!(matches!(ev(&mut e).await, Event::Request(_)));
    let l2 = l.clone();
    let acc = tokio::spawn(async move { l2.accept(5, None, &[]).await });
    let _m = npf.take("/v1/app/answer").await.up().await;
    let mut svc = acc.await.unwrap().unwrap();
    // a second request not answered yet
    s.send(json!({"type": "request", "service": 6, "res": "desktop", "proto": "rustdesk/1",
        "peer": {"number": "111"}, "can": [], "body": {}})).await;
    assert!(matches!(ev(&mut e).await, Event::Request(_)));

    // npf closes the events connection: the service ends, then down
    drop(s);
    assert_eq!(ev(&mut e).await, Event::Cancel { service: 6, why: ErrorKind::NoNpf });
    assert_eq!(down_kind(ev(&mut e).await), ErrorKind::NoNpf);
    let mut rest = vec![];
    assert_eq!(tokio::time::timeout(WAIT, svc.main.read_to_end(&mut rest)).await.unwrap().unwrap(), 0);
    // again after the backoff; all devices told again
    let (_, mut s) = npf.attach(hello()).await;
    assert_eq!(ev(&mut e).await, Event::Up);
    let mut peers = 0;
    for _ in 0..5 {
        peers += matches!(ev(&mut e).await, Event::Peer(_)) as i32;
    }
    assert_eq!(peers, 2);

    s.send(json!({"type": "replaced"})).await;
    assert_eq!(down_kind(ev(&mut e).await), ErrorKind::Replaced);
    npf.none("/v1/app/attach", Duration::from_millis(500)).await;
    assert_eq!(l.request("111", "desktop", None).await.err().map(|e| e.kind), Some(ErrorKind::Replaced));
}

/* ---------------- AC-10 ---------------- */

#[tokio::test]
async fn ac10_stop() {
    let mut npf = Npf::start().await;
    let (l, mut e, mut s) = { let o = npf.opts(); up(&mut npf, o) }.await;
    let l2 = l.clone();
    let req = tokio::spawn(async move { l2.request("111", "desktop", None).await });
    let mut m = npf.take("/v1/app/request").await.up().await;
    m.send(json!({"service": 3, "proto": "rustdesk/1", "body": {}, "slots": []})).await;
    let svc = req.await.unwrap().unwrap();
    let (mut rd, mut wr) = tokio::io::split(svc.main);
    // the app's service: writes what it has, ends when its main channel reads the end
    let app = tokio::spawn(async move {
        wr.write_all(&vec![1u8; 1 << 20]).await.unwrap();
        let mut rest = vec![];
        rd.read_to_end(&mut rest).await.unwrap();
        drop(rd.unsplit(wr));
    });
    let l2 = l.clone();
    let stop = tokio::spawn(async move { l2.stop().await });
    assert_eq!(m.bytes(1 << 20).await.len(), 1 << 20);
    app.await.unwrap();
    assert!(m.eof().await, "the main channel closed");
    stop.await.unwrap();
    assert!(s.eof().await, "then the events connection");
    assert!(tokio::time::timeout(WAIT, e.recv()).await.unwrap().is_none(), "the events end");
    assert_eq!(l.resources_set(&[]).err().map(|e| e.kind), Some(ErrorKind::State));
}

/* ---------------- AC-11 ---------------- */

#[tokio::test]
async fn ac11_transports() {
    // the defaults
    // each place under the product's name, then under the one before it
    let system: &[&str] = if cfg!(target_os = "macos") {
        &["/etc/oulink", "/etc/npf", "/Library/ouLink/data", "/Library/NPF/data"]
    } else {
        &["/etc/oulink", "/etc/npf"]
    };
    let paths = |v: &[&str]| v.iter().chain(system).map(PathBuf::from).collect::<Vec<_>>();
    assert_eq!(sys::dirs_of(Some("/home/u".into())), paths(&["/home/u/.config/oulink", "/home/u/.config/npf"]));
    assert_eq!(sys::dirs_of(None), paths(&[]));

    // unix_path
    let mut npf = Npf::start().await;
    let mut o = Options::new("rustdesk", &["rustdesk/1"]);
    o.unix_path = Some(npf.sock.clone());
    o.timeout = Duration::from_millis(1500);
    let (l, mut e) = Link::start(o).unwrap();
    let _s = npf.attach(hello()).await;
    assert_eq!(ev(&mut e).await, Event::Up);
    assert_eq!(l.transport(), Some(Transport::Unix));
    l.stop().await;

    // applink.json with only tcp: not this platform's way
    npf.write_json(json!({"version": 1, "tcp": "127.0.0.1:1"}));
    let (l, mut e) = Link::start(npf.opts()).unwrap();
    assert_eq!(down_kind(ev(&mut e).await), ErrorKind::NoNpf);
    npf.none("/v1/app/attach", Duration::from_millis(200)).await;
    l.stop().await;

    // tcp_addr: Host is the address
    let tl = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = tl.local_addr().unwrap().to_string();
    let tl = std::sync::Arc::new(tl);
    let mut tnpf = Npf::serve(tmpdir(), PathBuf::new(), move || {
        let tl = tl.clone();
        async move { tl.accept().await.ok().map(|(s, _)| Box::new(s) as BoxIo) }
    });
    let mut o = Options::new("rustdesk", &["rustdesk/1"]);
    o.tcp_addr = Some(addr.clone());
    let (l, mut e) = Link::start(o).unwrap();
    let (a, _s) = tnpf.attach(hello()).await;
    assert_eq!(a.header("Host"), Some(addr));
    assert_eq!(ev(&mut e).await, Event::Up);
    assert_eq!(l.transport(), Some(Transport::Tcp));
    l.stop().await;

    // dial: npf in this process, not checked
    let (dtx, drx) = mpsc::unbounded_channel::<BoxIo>();
    let dial: Dial = std::sync::Arc::new(move |app: &str| {
        assert_eq!(app, "rustdesk");
        let (a, b) = tokio::io::duplex(1 << 16);
        dtx.send(Box::new(b)).ok();
        Ok(Box::new(a) as BoxIo)
    });
    let drx = std::sync::Arc::new(tokio::sync::Mutex::new(drx));
    let mut dnpf = Npf::serve(tmpdir(), PathBuf::new(), move || {
        let drx = drx.clone();
        async move { drx.lock().await.recv().await }
    });
    let mut o = Options::new("rustdesk", &["rustdesk/1"]);
    o.dial = Some(dial);
    o.fake.peer = Some(4242);
    o.fake.file = Some(4242);
    let (l, mut e) = Link::start(o).unwrap();
    let (a, _s) = dnpf.attach(hello()).await;
    assert_eq!(a.header("Host").as_deref(), Some("localhost"));
    assert_eq!(ev(&mut e).await, Event::Up);
    assert_eq!(l.transport(), Some(Transport::InProc));
    l.stop().await;
}

/* ---------------- AC-12 ---------------- */

#[tokio::test]
async fn ac12_call_share() {
    let mut npf = Npf::start().await;
    let (l, mut e) = Link::start(npf.opts()).unwrap();
    assert_eq!(l.call("share/list", None).await.err().map(|e| e.kind), Some(ErrorKind::State));
    let (a, mut s) = npf.attach(hello()).await;
    assert!(a.body["want"].as_array().unwrap().contains(&json!("share")));
    assert_eq!(ev(&mut e).await, Event::Up);
    let mut share = 0;
    for _ in 0..5 {
        share += (ev(&mut e).await == Event::Share(3)) as i32;
    }
    assert_eq!(share, 1);
    for p in ["/share/list", "share/list/", "share//list", "Share/list", &"a".repeat(41)] {
        assert_eq!(l.call(p, None).await.err().map(|e| e.kind), Some(ErrorKind::Invalid), "{p}");
    }
    let big = json!({ "x": "y".repeat(65536) });
    assert_eq!(l.call("share/new", Some(&big)).await.err().map(|e| e.kind), Some(ErrorKind::TooBig));
    npf.none("/v1/app/share/new", Duration::from_millis(100)).await;

    for (status, reply, kind) in [
        (200, json!({"shares": []}), None),
        (404, json!({"error": "not_found", "message": "no such share"}), Some(ErrorKind::NotFound)),
        (400, json!({"error": "bad_request"}), Some(ErrorKind::Invalid)),
        (403, json!({"error": "forbidden"}), Some(ErrorKind::NoAccess)),
        (403, json!({"x": 1}), Some(ErrorKind::Denied)),
    ] {
        let l2 = l.clone();
        let c = tokio::spawn(async move { l2.call("share/list", None).await });
        let q = npf.take("/v1/app/share/list").await;
        assert_eq!(q.body, json!({}));
        assert!(q.header("Upgrade").is_none());
        q.reply(status, reply.clone()).await;
        match (c.await.unwrap(), kind) {
            (Ok(v), None) => assert_eq!(v, reply),
            (Err(x), Some(k)) => {
                assert_eq!(x.kind, k);
                assert_eq!(x.reply, Some(reply));
            }
            (r, k) => panic!("{status}: {r:?} {k:?}"),
        }
    }

    // share events: the same revision once
    s.send(json!({"type": "share", "rev": 4})).await;
    s.send(json!({"type": "share", "rev": 4})).await;
    assert_eq!(ev(&mut e).await, Event::Share(4));
    let mut h = hello();
    h["share"] = json!(5);
    s.send(h).await;
    assert_eq!(ev(&mut e).await, Event::Share(5));
    quiet(&mut e, Duration::from_millis(200)).await;

    // open: npf's console asks for a session, or the window
    s.send(json!({"type": "open", "what": "desktop", "peer": "123456786"})).await;
    assert_eq!(ev(&mut e).await, Event::Open { what: Some("desktop".into()), peer: Some("123456786".into()) });
    s.send(json!({"type": "open"})).await;
    assert_eq!(ev(&mut e).await, Event::Open { what: None, peer: None });

    // npf goes away while a call waits: NoNpf
    let l2 = l.clone();
    let c = tokio::spawn(async move { l2.call("share/new", Some(&json!({"res": "desktop"}))).await });
    let q = npf.take("/v1/app/share/new").await;
    drop(q);
    drop(s);
    assert_eq!(c.await.unwrap().err().map(|e| e.kind), Some(ErrorKind::NoNpf));
    assert_eq!(down_kind(ev(&mut e).await), ErrorKind::NoNpf);
    // again: the revision told again
    let (_, _s) = npf.attach(hello()).await;
    let mut share = 0;
    for _ in 0..6 {
        share += (ev(&mut e).await == Event::Share(3)) as i32;
    }
    assert_eq!(share, 1);
    // stopping while a call waits: State
    let l2 = l.clone();
    let c = tokio::spawn(async move { l2.call("share/new", None).await });
    let _q = npf.take("/v1/app/share/new").await;
    l.stop().await;
    assert_eq!(c.await.unwrap().err().map(|e| e.kind), Some(ErrorKind::State));
}
