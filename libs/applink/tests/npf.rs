//! The client against a real npf (tests/integration/applink-rust.sh sets it
//! up: computer P with an owner, C paired with P as its admin, G with no
//! pairing; this test program allowed as rustdesk on all three). Without
//! APPLINK_TEST_P the test passes at once (plain `cargo test`).
//!
//! P declares desktop and answers; C asks for it (request, answer, the main
//! channel both ways, P's video and channel to C's accept connections, C's
//! audio in its slot, closing); G asks with P's assist code (temp, member);
//! the assist code renewed; the sharing page's calls; up toggled at C's
//! sight; P's npf restarted (P attaches again, its desktop declared again, C
//! uses it again); P replaced by a second P; an impostor's socket refused.

use applink::*;
use serde_json::{json, Value};
use std::path::PathBuf;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::time::timeout;

struct App {
    link: Link,
    ev: Events,
    name: &'static str,
}

impl App {
    fn new(name: &'static str, dir: &PathBuf) -> App {
        let mut o = Options::new("rustdesk", &["rustdesk/1"]);
        o.dir = Some(dir.clone());
        let (link, ev) = Link::start(o).expect("start");
        App { link, ev, name }
    }

    /// The first event `f` takes (others dropped), within `secs`.
    async fn wait<T>(&mut self, secs: u64, what: &str, mut f: impl FnMut(Event) -> Option<T>) -> T {
        let name = self.name;
        let ev = &mut self.ev;
        timeout(Duration::from_secs(secs), async {
            loop {
                let e = ev.recv().await.unwrap_or_else(|| panic!("{name}: the events ended"));
                if let Some(t) = f(e) {
                    return t;
                }
            }
        })
        .await
        .unwrap_or_else(|_| panic!("{name}: no {what} in {secs} s"))
    }

    async fn up(&mut self) {
        let name = self.name;
        self.wait(30, "Up", |e| match e {
            Event::Up => Some(()),
            Event::Down(x) if matches!(x.kind, ErrorKind::Auth | ErrorKind::Denied) => {
                panic!("{name}: npf refused this program ({x}): npf applink allow it")
            }
            _ => None,
        })
        .await
    }

    async fn request(&mut self, secs: u64) -> Request {
        self.wait(secs, "a request", |e| match e {
            Event::Request(r) => Some(r),
            _ => None,
        })
        .await
    }
}

fn env(k: &str) -> Option<String> {
    std::env::var(k).ok().filter(|v| !v.is_empty())
}

fn pattern(i: usize) -> u8 {
    (i % 251) as u8
}

fn desktop() -> Resource {
    Resource::new("desktop", "rustdesk", &["view", "control", "file", "terminal"])
}

async fn published(p: &mut App) {
    p.wait(30, "desktop published", |e| match e {
        Event::Resources(v) => {
            assert_eq!(v, vec![("desktop".to_string(), ResourceState::Published)]);
            Some(())
        }
        _ => None,
    })
    .await
}

async fn desktop_seen(c: &mut App, np: u64, up: bool) -> Peer {
    c.wait(30, "P's desktop in a peer event", |e| match e {
        Event::Peer(pe) if pe.number == np && pe.services.iter().any(|s| s.res == "desktop" && s.up == up) => Some(pe),
        _ => None,
    })
    .await
}

/// C asks, P accepts: both ends' services
async fn connect(c: &App, p: &mut App, np: &str, body: Value, slots: &[Slot]) -> (Service, Service, Request) {
    let cl = c.link.clone();
    let np = np.to_owned();
    let asked = tokio::spawn(async move { cl.request(&np, "desktop", Some(&body)).await });
    let r = p.request(40).await;
    let sp = p.link.accept(r.service, Some(&json!({"ok": 1})), slots).await.expect("accept");
    let sc = timeout(Duration::from_secs(20), asked).await.expect("the answer").unwrap().expect("accepted");
    (sc, sp, r)
}

/// the main channel's bytes back where they came from, until its end
fn echo(s: Channel) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let (mut rd, mut wr) = tokio::io::split(s);
        tokio::io::copy(&mut rd, &mut wr).await.ok();
    })
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn against_npf() {
    let Some(p_dir) = env("APPLINK_TEST_P") else {
        eprintln!("APPLINK_TEST_P not set: skipped (tests/integration/applink-rust.sh runs this)");
        return;
    };
    let p_dir = PathBuf::from(p_dir);
    let c_dir = PathBuf::from(env("APPLINK_TEST_C").expect("APPLINK_TEST_C"));
    let g_dir = PathBuf::from(env("APPLINK_TEST_G").expect("APPLINK_TEST_G"));
    let np = env("APPLINK_TEST_NP").expect("APPLINK_TEST_NP");
    let np_n: u64 = np.parse().unwrap();

    // ---- P declares desktop; its assist code ----
    let mut p = App::new("P", &p_dir);
    p.link.resources_set(&[desktop()]).unwrap();
    p.up().await;
    assert_eq!(p.link.transport(), Some(Transport::Unix));
    published(&mut p).await;
    let code1 = p
        .wait(30, "assist code", |e| match e {
            Event::Assist(Assist { code: Some(c), expires, .. }) => {
                assert!(expires.unwrap_or(0) > 0);
                Some(c)
            }
            _ => None,
        })
        .await;
    assert_eq!(code1.len(), 14, "{code1}");
    assert_eq!(p.link.assist().and_then(|a| a.code), Some(code1.clone()));
    assert_eq!(p.link.info().and_then(|i| i.number), Some(np_n));
    println!("PASS P: attached, desktop published, assist code {}-…", &code1[..4]);

    // ---- C sees P's desktop ----
    let mut c = App::new("C", &c_dir);
    c.up().await;
    let pe = desktop_seen(&mut c, np_n, true).await;
    let s = pe.services.iter().find(|s| s.res == "desktop").unwrap();
    assert!(pe.mine, "C is P's admin");
    assert_eq!(s.svc, "rustdesk");
    assert_eq!(s.protos, ["rustdesk/1"]);
    assert_eq!(s.can, ["view", "control", "file", "terminal"]);
    assert!(c.link.peers().unwrap().iter().any(|x| x.number == np_n));
    println!("PASS C: P's desktop (svc, protos, can, mine)");

    // ---- request -> request event -> answer ----
    let (sc, sp, req) = connect(&c, &mut p, &np, json!({"conn_type": 0}), &[Slot { tag: 19, n: 1 }]).await;
    assert_eq!(req.res, "desktop");
    assert_eq!(req.peer.role, Some(Role::Admin));
    assert!(!req.peer.temp);
    assert_eq!(req.proto, "rustdesk/1");
    assert!(req.can("view") && req.can("control"));
    assert_eq!(req.body, json!({"conn_type": 0}));
    assert_eq!(sc.proto, "rustdesk/1");
    assert_eq!(sc.body, json!({"ok": 1}));
    assert_eq!(sc.slots, [Slot { tag: 19, n: 1 }]);
    println!("PASS request: role admin, proto, can, body; the answer with its body and slots");

    // ---- the main channel: 4 MB from C, echoed by P ----
    let Service { main: p_main, open: p_open, incoming: mut p_in, .. } = sp;
    let p_echo = echo(p_main);
    let Service { main: c_main, open: c_open, incoming: mut c_in, .. } = sc;
    let (mut c_rd, mut c_wr) = tokio::io::split(c_main);
    const TOTAL: usize = 4 << 20;
    let data: Vec<u8> = (0..TOTAL).map(pattern).collect();
    let w = tokio::spawn(async move {
        c_wr.write_all(&data).await.unwrap();
        c_wr
    });
    let mut got = vec![0u8; TOTAL];
    timeout(Duration::from_secs(60), c_rd.read_exact(&mut got)).await.expect("the echo stalled").unwrap();
    assert!(got.iter().enumerate().all(|(i, b)| *b == pattern(i)), "the echo changed");
    let c_wr = w.await.unwrap();
    println!("PASS the main channel: {TOTAL} bytes there and back, intact");

    // ---- P's video (tag 10) and a channel (tag 1) to C's accept connections ----
    let mut o = MediaOpt::new(10);
    o.drop_until_key = true;
    let vid = p_open.media(&o).unwrap();
    let mut ch1 = p_open.channel(1, 2).await.unwrap();
    ch1.write_all(b"bulk hello").await.unwrap();
    for i in 0..30u32 {
        let mut f = vec![(i % 256) as u8; 1000 + i as usize * 100];
        f[0] = i as u8;
        vid.send(i % 10 == 0, &f).unwrap();
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let (mut cvid, mut cch) = (None, None);
    while cvid.is_none() || cch.is_none() {
        match timeout(Duration::from_secs(20), c_in.recv()).await.expect("P's streams").unwrap() {
            Opened::Media(tag, m) => {
                assert_eq!(tag, 10);
                cvid = Some(m);
            }
            Opened::Channel(tag, ch) => {
                assert_eq!(tag, 1);
                cch = Some(ch);
            }
        }
    }
    let (mut cvid, mut cch) = (cvid.unwrap(), cch.unwrap());
    for i in 0..30usize {
        let f = timeout(Duration::from_secs(20), cvid.recv()).await.expect("a frame").expect("frames go on");
        assert_eq!(f.info.frame_no, i as u32);
        assert_eq!(f.info.key, i % 10 == 0);
        assert_eq!((f.data.len(), f.data[0]), (1000 + i * 100, i as u8));
    }
    let mut bulk = [0u8; 10];
    timeout(Duration::from_secs(10), cch.read_exact(&mut bulk)).await.unwrap().unwrap();
    assert_eq!(&bulk, b"bulk hello");
    let mut st = vid.stats();
    timeout(Duration::from_secs(10), st.changed()).await.expect("media stats").unwrap();
    assert!(st.borrow().as_ref().map_or(false, |s| s.target_rate > 0));
    println!("PASS the answerer's video and channel to the requester's accept connections (frames, key flags, bytes); stats");

    // ---- C's audio in its slot (tag 19) ----
    let aud = c_open.media(&MediaOpt::new(19)).unwrap();
    assert_eq!(c_open.media(&MediaOpt::new(19)).err().map(|e| e.kind), Some(ErrorKind::Denied));
    for i in 0..5u8 {
        aud.send(true, &[i; 200]).unwrap();
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let mut paud = match timeout(Duration::from_secs(20), p_in.recv()).await.expect("C's audio").unwrap() {
        Opened::Media(19, m) => m,
        _ => panic!("not the audio"),
    };
    for i in 0..5u8 {
        let f = timeout(Duration::from_secs(20), paud.recv()).await.expect("an audio frame").unwrap();
        assert_eq!(&f.data[..], &[i; 200]);
    }
    println!("PASS the requester's media in its slot");

    // ---- C closes: P's end ----
    drop((aud, cvid, cch));
    drop(c_rd.unsplit(c_wr));
    timeout(Duration::from_secs(20), p_echo).await.expect("P's service ended").unwrap();
    assert!(timeout(Duration::from_secs(20), paud.recv()).await.expect("P's audio ended").is_none());
    drop((vid, ch1, p_open, c_open));
    println!("PASS closed by the requester: the provider's main channel reads its end");

    // ---- a refusal; a resource P lacks ----
    let cl = c.link.clone();
    let npc = np.clone();
    let asked = tokio::spawn(async move { cl.request(&npc, "desktop", Some(&json!({"conn_type": 1}))).await });
    let r = p.request(40).await;
    p.link.refuse(r.service, Some(&json!({"error": "no_permission"}))).await.unwrap();
    let e = asked.await.unwrap().err().expect("refused");
    assert_eq!(e.kind, ErrorKind::Refused);
    assert!(e.message.as_deref().unwrap_or("").contains("no_permission"), "the refusal's body: {e:?}");
    let e2 = c.link.request(&np, "nosuch", None).await.err().expect("no such resource");
    assert!(matches!(e2.kind, ErrorKind::NoAccess | ErrorKind::Denied), "{e2:?}");
    println!("PASS refused ({}, the body passed on), a resource P lacks ({})", e.kind.word(), e2.kind.word());

    // ---- G with the assist code: temp, member ----
    let mut g = App::new("G", &g_dir);
    g.up().await;
    let gl = g.link.clone();
    let code = code1.clone();
    let asked = tokio::spawn(async move { gl.request(&code, "desktop", Some(&json!({"conn_type": 0}))).await });
    let rg = p.request(60).await;
    assert!(rg.peer.temp, "G came with the assist code");
    assert_eq!(rg.peer.role, Some(Role::Member));
    let spg = p.link.accept(rg.service, None, &[]).await.unwrap();
    let ge = echo(spg.main);
    let mut sg = timeout(Duration::from_secs(20), asked).await.unwrap().unwrap().expect("accepted");
    sg.main.write_all(b"ping").await.unwrap();
    let mut b = [0u8; 4];
    timeout(Duration::from_secs(10), sg.main.read_exact(&mut b)).await.unwrap().unwrap();
    assert_eq!(&b, b"ping");
    drop(sg);
    timeout(Duration::from_secs(20), ge).await.expect("G's service ended at P").unwrap();
    println!("PASS the assist code as the peer: npf pairs, the request is temp from a member");

    // ---- renew the assist code ----
    p.link.assist_renew().await.unwrap();
    let code2 = p
        .wait(30, "a new assist code", |e| match e {
            Event::Assist(Assist { code: Some(c), .. }) if c != code1 => Some(c),
            _ => None,
        })
        .await;
    println!("PASS assist renew: a new code {}-…", &code2[..4]);

    // ---- the sharing page: call and the share event ----
    let list = p.link.call("share/list", None).await.expect("share/list");
    assert!(list["resources"].as_array().map_or(false, |r| r.iter().any(|x| x["res"] == "desktop" || x["name"] == "desktop")), "share/list: {list}");
    let made = p
        .link
        .call("share/new", Some(&json!({"scope": [{"res": "desktop", "can": ["view"]}], "label": "rust"})))
        .await
        .expect("share/new");
    let locator = made["locator"].as_str().expect("share/new's locator").to_owned();
    p.wait(20, "the share event", |e| matches!(e, Event::Share(_)).then_some(())).await;
    let list = p.link.call("share/list", None).await.unwrap();
    assert!(list.to_string().contains(&locator), "the new code listed: {list}");
    p.link.call("share/revoke", Some(&json!({ "locator": locator }))).await.expect("share/revoke");
    let bad = p.link.call("share/revoke", Some(&json!({"locator": "2222"}))).await;
    assert!(bad.as_ref().map_or_else(|e| e.reply.is_some(), |_| false), "revoking an unknown code: {bad:?}");
    let none = p.link.call("no/such", None).await.err().map(|e| e.kind);
    assert_eq!(none, Some(ErrorKind::NotFound));
    println!("PASS call: share/list, share/new (the share event), share/revoke, an error, 404");

    // ---- resource up ----
    p.link.resource_up("desktop", false).unwrap();
    desktop_seen(&mut c, np_n, false).await;
    p.link.resource_up("desktop", true).unwrap();
    desktop_seen(&mut c, np_n, true).await;
    println!("PASS resource_up: the peer sees it down and up");

    // ---- P's npf restarted: P again, desktop declared again, C uses it ----
    if let Some(cmd) = env("APPLINK_TEST_RESTART_P") {
        p.link.resource_up("desktop", false).unwrap();
        desktop_seen(&mut c, np_n, false).await;
        let st = tokio::process::Command::new("sh").arg("-c").arg(&cmd).status().await.unwrap();
        assert!(st.success(), "restarting P's npf");
        p.wait(30, "P down", |e| match e {
            Event::Down(x) => {
                assert_eq!(x.kind, ErrorKind::NoNpf);
                Some(())
            }
            _ => None,
        })
        .await;
        p.up().await;
        // declared again as last set (down), then up
        published(&mut p).await;
        desktop_seen(&mut c, np_n, false).await;
        p.link.resource_up("desktop", true).unwrap();
        desktop_seen(&mut c, np_n, true).await;
        let (mut sc, sp, _) = connect(&c, &mut p, &np, json!({}), &[]).await;
        let pe = echo(sp.main);
        sc.main.write_all(b"again").await.unwrap();
        let mut b = [0u8; 5];
        timeout(Duration::from_secs(10), sc.main.read_exact(&mut b)).await.unwrap().unwrap();
        assert_eq!(&b, b"again");
        drop(sc);
        timeout(Duration::from_secs(20), pe).await.unwrap().unwrap();
        println!("PASS P's npf restarted: down (no_npf), up again, desktop declared again with its up, a service again");
    }

    // ---- a second P: the first is replaced ----
    let mut p2 = App::new("P2", &p_dir);
    p2.up().await;
    p.wait(20, "P replaced", |e| match e {
        Event::Down(x) => {
            assert_eq!(x.kind, ErrorKind::Replaced);
            Some(())
        }
        _ => None,
    })
    .await;
    let e = p.link.request(&np, "desktop", None).await.err().map(|e| e.kind);
    assert_eq!(e, Some(ErrorKind::Replaced));
    println!("PASS replaced: the first P down for good (replaced), the second up");

    // ---- an impostor's socket: another account's ----
    if let Some(dir) = env("APPLINK_TEST_IMPOSTOR") {
        let mut x = App::new("X", &PathBuf::from(dir));
        let e = x
            .wait(20, "a down", |e| match e {
                Event::Down(x) => Some(x),
                _ => None,
            })
            .await;
        assert_eq!(e.kind, ErrorKind::Auth, "{e:?}");
        assert!(x.link.last_error().is_some());
        x.link.stop().await;
        println!("PASS the socket's peer another account: auth, nothing sent");
    }

    for a in [&p, &p2, &c, &g] {
        timeout(Duration::from_secs(15), a.link.stop()).await.expect("stop");
    }
    println!("PASS stopped");
}
