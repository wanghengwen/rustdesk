//! The link to npf: finding npf and attaching (again and again), the events
//! connection and the copy of npf's state, the idle accept connections and
//! where their streams go, the resources declared, and the functions.

use crate::net::{Conn, Resp, Target, LINE_MAX, REPLY_MAX};
use crate::stream::{Channel, Incoming, MainCtl, MainGuard, MediaRx, Opened, Opener, Service};
use crate::sys::{self, Fake};
use crate::types::*;
use crate::{body_of, valid_name, valid_protos, Error, ErrorKind, Event, Events, Options, Result};
use serde_json::{json, Value};
use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};
use tokio::sync::{mpsc, watch, Notify};
use tokio::task::JoinHandle;

/// idle accept connections kept (A5)
const ACCEPT_IDLE: usize = 2;
/// npf may ask the person here first (60 s)
const ATTACH_TIME: Duration = Duration::from_secs(70);
/// reaching the peer 30 s, its answer 60 s, 5 s to spare
const REQUEST_TIME: Duration = Duration::from_secs(95);
/// a request to this app unanswered (the peer's libnpf counts 60 s)
const ASKED_TIME: Duration = Duration::from_secs(65);
/// applink_call: share/new waits for the platform up to 60 s
const CALL_TIME: Duration = Duration::from_secs(75);
const RETRY_MAX: Duration = Duration::from_secs(30);
/// stopping: the services' end awaited this long
const STOP_TIME: Duration = Duration::from_secs(10);

/// where a service's streams go (the peer's, from the accept connections)
pub(crate) struct Route {
    gen: u64,
    tx: mpsc::UnboundedSender<Opened>,
    ctl: Arc<MainCtl>,
}

#[derive(Default)]
pub(crate) struct Shared {
    stopping: bool,
    /// Some: attached (a hello seen), npf as found
    target: Option<Target>,
    gave_up: Option<Error>,
    down_why: Option<ErrorKind>,
    last_err: String,
    // the copy of npf's state
    info: Option<Info>,
    peers: BTreeMap<u64, Peer>,
    assist: Option<Assist>,
    share: Option<u64>,
    // resources: the list, npf's states, what is to go
    res: Option<Vec<Resource>>,
    res_states: BTreeMap<String, ResourceState>,
    res_full: bool,
    res_up: bool,
    // services
    routes: HashMap<u32, Route>,
    /// streams of a service not known yet while requests of ours await
    /// their answers: npf wrote the answer first, on the main channel's
    /// connection, but that may be read after this one
    early: HashMap<u32, Vec<Opened>>,
    asking: usize,
    /// requests to this app: when they came, their proto
    asked: HashMap<u32, (Instant, String)>,
    /// the accept connections' and the resources' tasks of this attach
    tasks: Vec<JoinHandle<()>>,
    sup: Option<JoinHandle<()>>,
}

pub(crate) struct Inner {
    pub o: Options,
    attach: String,
    pub sh: Mutex<Shared>,
    /// bumped when up, down, stopped, a service gone
    changed: watch::Sender<u64>,
    res_kick: Notify,
    /// ends the wait between attaches ([`Link::retry_now`])
    retry_kick: Notify,
    ev: Mutex<Option<mpsc::UnboundedSender<Event>>>,
}

static GEN: AtomicU64 = AtomicU64::new(1);

impl Inner {
    pub(crate) fn lock(&self) -> MutexGuard<'_, Shared> {
        self.sh.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub(crate) fn fake(&self) -> Fake {
        #[cfg(test)]
        return self.o.fake;
        #[cfg(not(test))]
        Fake::default()
    }

    pub(crate) fn target(&self) -> Option<Target> {
        self.lock().target.clone()
    }

    pub(crate) fn set_err(&self, m: &str) {
        self.lock().last_err = m.to_owned();
    }

    fn emit(&self, e: Event) {
        if let Some(tx) = &*self.ev.lock().unwrap_or_else(|e| e.into_inner()) {
            tx.send(e).ok();
        }
    }

    fn bump(&self) {
        self.changed.send_modify(|n| *n += 1);
    }

    /* ---- finding npf ---- */

    /// the ways to npf, tried in turn
    fn candidates(&self) -> Vec<Result<Target>> {
        let fixed = |transport, addr: String| {
            vec![Ok(Target {
                transport,
                addr,
                owner: sys::own_owner(),
                pid: 0,
            })]
        };
        if self.o.dial.is_some() {
            return fixed(Transport::InProc, String::new());
        }
        if let Some(p) = &self.o.unix_path {
            return fixed(Transport::Unix, p.to_string_lossy().into_owned());
        }
        if let Some(a) = &self.o.tcp_addr {
            return fixed(Transport::Tcp, a.clone());
        }
        let dirs: Vec<PathBuf> = match &self.o.dir {
            Some(d) => vec![d.clone()],
            None => sys::dirs(),
        };
        dirs.iter().map(|d| self.prepare(d)).collect()
    }

    /// a directory's applink.json, checked: where npf is
    fn prepare(&self, dir: &std::path::Path) -> Result<Target> {
        let (text, owner) = sys::read_npf(dir, self.fake())?;
        let j: Value = serde_json::from_str(&text).map_err(|_| ErrorKind::Proto)?;
        if j["version"].as_i64() != Some(1) {
            return Err(ErrorKind::Proto.into()); // a wire protocol this library does not speak
        }
        let pid = j["pid"].as_u64().unwrap_or(0) as u32;
        let (transport, key) = match sys::NATIVE {
            Transport::Unix => (Transport::Unix, "unix"),
            _ => (Transport::Tcp, "tcp"),
        };
        let addr = j[key].as_str().filter(|a| !a.is_empty()).ok_or(ErrorKind::NoNpf)?;
        Ok(Target {
            transport,
            addr: addr.to_owned(),
            owner,
            pid,
        })
    }

    /* ---- the link's task ---- */

    async fn supervise(self: Arc<Self>) {
        let mut retry = self.o.retry;
        loop {
            let why = self.attach_run(&mut retry).await;
            let give_up = matches!(why.kind, ErrorKind::Auth | ErrorKind::Denied | ErrorKind::Replaced);
            self.down(why, give_up);
            if give_up {
                return;
            }
            tokio::select! {
                _ = tokio::time::sleep(retry) => retry = (retry * 2).min(RETRY_MAX),
                _ = self.retry_kick.notified() => retry = self.o.retry,
            }
        }
    }

    /// one attach, its events until it ends: why
    async fn attach_run(self: &Arc<Self>, retry: &mut Duration) -> Error {
        let (mut auth, mut proto) = (None, false);
        for t in self.candidates() {
            let r = match t {
                Ok(t) => match self.upgrade(&t, "/v1/app/attach", &serde_json::from_str(&self.attach).unwrap_or_default(), Some(ATTACH_TIME)).await {
                    Ok(c) => return self.events(t, c, retry).await,
                    // the person at this npf answered (or nobody did): that is the answer
                    Err(e) if matches!(e.kind, ErrorKind::Denied | ErrorKind::Timeout) => return e,
                    Err(e) => e,
                },
                Err(e) => e,
            };
            // not this one: the next
            if r.kind == ErrorKind::Auth {
                auth.get_or_insert(r);
            } else {
                proto |= r.kind == ErrorKind::Proto;
            }
        }
        // one not verified, or not taking this program: that is the answer
        match auth {
            Some(e) => e,
            None => Error::new(if proto { ErrorKind::Proto } else { ErrorKind::NoNpf }),
        }
    }

    /// the events connection: a hello within the timeout, then lines
    async fn events(self: &Arc<Self>, t: Target, mut c: Conn, retry: &mut Duration) -> Error {
        let mut up = false;
        loop {
            let line = if up {
                c.line(LINE_MAX).await
            } else {
                match tokio::time::timeout(self.o.timeout, c.line(LINE_MAX)).await {
                    Ok(l) => l,
                    Err(_) => return ErrorKind::NoNpf.into(), // no hello
                }
            };
            let Ok(Some(line)) = line else {
                return ErrorKind::NoNpf.into();
            };
            let Ok(v) = serde_json::from_slice::<Value>(&line) else {
                continue; // not ours to understand
            };
            match v["type"].as_str().unwrap_or("") {
                "hello" if !up => {
                    up = true;
                    *retry = self.o.retry;
                    self.up(&t, &v);
                }
                "hello" => self.hello(&v, false),
                _ if !up => {} // nothing before the hello
                "replaced" => return ErrorKind::Replaced.into(),
                "info" => self.info(&v, false),
                "peer" => self.peer(&v),
                "request" => self.request_ev(v),
                "cancel" => {
                    let sid = v["service"].as_u64().unwrap_or(0) as u32;
                    if self.lock().asked.remove(&sid).is_some() {
                        let why = if v["why"] == "timeout" { ErrorKind::Timeout } else { ErrorKind::Closed };
                        self.emit(Event::Cancel { service: sid, why });
                    }
                }
                "assist" => self.assist(&v, false),
                "quota" => {
                    if let (true, Some(used), Some(limit)) = (self.o.want.quota, v["used"].as_u64(), v["limit"].as_u64()) {
                        self.emit(Event::Quota { used, limit });
                    }
                }
                "resource" => {
                    if let (Some(n), Some(st)) = (v["name"].as_str(), v["state"].as_str()) {
                        let st = ResourceState::from_word(st);
                        self.lock().res_states.insert(n.to_owned(), st);
                        self.emit(Event::Resource(n.to_owned(), st));
                    }
                }
                "share" => self.share(&v["rev"], false),
                "open" if self.o.want.open => {
                    let s = |k: &str| v[k].as_str().map(str::to_owned);
                    self.emit(Event::Open { what: s("what"), peer: s("peer") });
                }
                _ => {}
            }
        }
    }

    fn up(self: &Arc<Self>, t: &Target, hello: &Value) {
        {
            let mut sh = self.lock();
            sh.target = Some(t.clone());
            sh.down_why = None;
        }
        self.emit(Event::Up);
        self.hello(hello, true);
        let mut tasks: Vec<JoinHandle<()>> = (0..ACCEPT_IDLE).map(|_| tokio::spawn(self.clone().accept_loop(t.clone()))).collect();
        tasks.push(tokio::spawn(self.clone().res_worker()));
        let mut sh = self.lock();
        sh.res_full = sh.res.is_some();
        sh.tasks = tasks;
        drop(sh);
        self.res_kick.notify_one();
        self.bump(); // requests waiting for npf go now
    }

    fn down(&self, why: Error, give_up: bool) {
        let (report, asked) = {
            let mut sh = self.lock();
            for t in sh.tasks.drain(..) {
                t.abort();
            }
            let was = sh.target.take().is_some();
            sh.early.clear();
            // npf ends this app's services with the attach: their main channels read their end
            for r in sh.routes.values() {
                r.ctl.stop();
            }
            let asked: Vec<u32> = sh.asked.drain().map(|(s, _)| s).collect();
            if give_up {
                sh.gave_up = Some(why.clone());
            }
            let report = was || sh.down_why != Some(why.kind);
            sh.down_why = Some(why.kind);
            (report, asked)
        };
        for s in asked {
            self.emit(Event::Cancel {
                service: s,
                why: ErrorKind::NoNpf,
            });
        }
        if report {
            let mut why = why;
            if why.message.is_none() && matches!(why.kind, ErrorKind::Auth | ErrorKind::Denied) {
                why.message = Some(self.lock().last_err.clone()).filter(|m| !m.is_empty());
            }
            self.emit(Event::Down(why));
        }
        self.bump();
    }

    /* ---- the copy of npf's state (state.c) ---- */

    /// a hello: all of it replaces the copy; what changed is told (all of it when first)
    fn hello(&self, v: &Value, first: bool) {
        self.info(v, first);
        if v["assist"].is_object() {
            self.assist(&v["assist"], first);
        }
        self.share(&v["share"], first);
        if let Some(list) = v["peers"].as_array() {
            let mut new = BTreeMap::new();
            for p in list.iter().filter(|p| !gone(p)) {
                if let Ok(p) = serde_json::from_value::<Peer>(p.clone()) {
                    if p.number != 0 {
                        new.entry(p.number).or_insert(p);
                    }
                }
            }
            let old = std::mem::replace(&mut self.lock().peers, new.clone());
            if self.o.want.peers {
                for p in new.values().filter(|p| first || old.get(&p.number) != Some(*p)) {
                    self.emit(Event::Peer(p.clone()));
                }
                for (_, mut p) in old.into_iter().filter(|(n, _)| !new.contains_key(n)) {
                    p.gone = true;
                    self.emit(Event::Peer(p));
                }
            }
        }
        // this app's resources: told when they changed in a hello that came
        // again (after the first, the resources' answer tells all of them)
        if let Some(states) = v["resources"].as_object() {
            let mut changed = vec![];
            {
                let mut sh = self.lock();
                let names: Vec<String> = sh.res.iter().flatten().map(|r| r.name.clone()).collect();
                for n in names {
                    let Some(w) = states.get(&n).and_then(Value::as_str) else { continue };
                    let st = ResourceState::from_word(w);
                    if sh.res_states.insert(n.clone(), st).map_or(false, |o| o != st) && !first {
                        changed.push((n, st));
                    }
                }
            }
            for (n, st) in changed {
                self.emit(Event::Resource(n, st));
            }
        }
    }

    fn info(&self, v: &Value, report: bool) {
        let Ok(i) = serde_json::from_value::<Info>(v.clone()) else { return };
        let changed = self.lock().info.replace(i.clone()).as_ref() != Some(&i);
        if changed || report {
            self.emit(Event::Info(i));
        }
    }

    fn assist(&self, v: &Value, report: bool) {
        let Ok(a) = serde_json::from_value::<Assist>(v.clone()) else { return };
        let changed = self.lock().assist.replace(a.clone()).as_ref() != Some(&a);
        if (changed || report) && self.o.want.assist {
            self.emit(Event::Assist(a));
        }
    }

    fn share(&self, rev: &Value, first: bool) {
        let Some(rev) = rev.as_u64().filter(|_| self.o.want.share) else { return };
        let old = self.lock().share.replace(rev);
        if first || old != Some(rev) {
            self.emit(Event::Share(rev));
        }
    }

    fn peer(&self, v: &Value) {
        let Ok(mut p) = serde_json::from_value::<Peer>(v.clone()) else { return };
        if p.number == 0 {
            return;
        }
        let is_gone = gone(v);
        let report = {
            let mut sh = self.lock();
            if is_gone {
                sh.peers.remove(&p.number).map(|mut old| {
                    old.gone = true;
                    old
                })
            } else if sh.peers.get(&p.number) == Some(&p) {
                None
            } else {
                p.gone = false;
                sh.peers.insert(p.number, p.clone());
                Some(p)
            }
        };
        if let Some(p) = report.filter(|_| self.o.want.peers) {
            self.emit(Event::Peer(p));
        }
    }

    fn request_ev(&self, v: Value) {
        if !self.o.want.requests {
            return;
        }
        let Ok(r) = serde_json::from_value::<Request>(v) else { return };
        {
            let mut sh = self.lock();
            if sh.asked.contains_key(&r.service) || sh.routes.contains_key(&r.service) {
                return;
            }
            let now = Instant::now();
            sh.asked.retain(|_, (t, _)| now.duration_since(*t) < ASKED_TIME);
            sh.asked.insert(r.service, (now, r.proto.clone()));
        }
        self.emit(Event::Request(r));
    }

    /* ---- the accept connections (A5) ---- */

    async fn accept_loop(self: Arc<Self>, t: Target) {
        loop {
            if self.accept_one(&t).await.is_err() {
                tokio::time::sleep(Duration::from_secs(1)).await; // not at once again
            }
        }
    }

    /// one idle accept connection, until npf hands it a stream
    async fn accept_one(&self, t: &Target) -> Result<()> {
        let mut c = self.upgrade(t, "/v1/app/accept", &json!({}), Some(self.o.timeout)).await?;
        let line = c.line(REPLY_MAX).await?.ok_or(ErrorKind::Io)?;
        let v: Value = serde_json::from_slice(&line).map_err(|_| ErrorKind::Proto)?;
        let tag = v["tag"].as_i64().filter(|t| (1..=crate::TAG_MAX as i64).contains(t)).ok_or(ErrorKind::Proto)? as i32;
        let sid = v["service"].as_u64().ok_or(ErrorKind::Proto)? as u32;
        let o = match v["kind"].as_str() {
            Some("channel") => Opened::Channel(tag, Channel::new(c, None)),
            Some("media") => Opened::Media(tag, MediaRx::new(c)),
            _ => return Err(ErrorKind::Proto.into()),
        };
        let mut sh = self.lock();
        let o = match sh.routes.get(&sid) {
            Some(r) => match r.tx.send(o) {
                Ok(()) => return Ok(()),
                Err(e) => e.0,
            },
            None => o,
        };
        if sh.asking > 0 {
            sh.early.entry(sid).or_default().push(o);
        }
        Ok(())
    }

    /// a service's streams go to it from now on (those that came first too)
    pub(crate) fn register(self: &Arc<Self>, sid: u32) -> (MainGuard, Incoming) {
        let (tx, rx) = mpsc::unbounded_channel();
        let gen = GEN.fetch_add(1, Ordering::Relaxed);
        let ctl = Arc::new(MainCtl::default());
        let mut sh = self.lock();
        for o in sh.early.remove(&sid).into_iter().flatten() {
            tx.send(o).ok();
        }
        sh.routes.insert(sid, Route { gen, tx, ctl: ctl.clone() });
        drop(sh);
        (
            MainGuard {
                inner: self.clone(),
                sid,
                gen,
                ctl,
            },
            Incoming(rx),
        )
    }

    pub(crate) fn unregister(&self, sid: u32, gen: u64) {
        let mut sh = self.lock();
        if sh.routes.get(&sid).map_or(false, |r| r.gen == gen) {
            sh.routes.remove(&sid);
        }
        drop(sh);
        self.bump();
    }

    /* ---- resources (A17) ---- */

    async fn res_worker(self: Arc<Self>) {
        loop {
            let job = {
                let mut sh = self.lock();
                let list = sh.res.clone().unwrap_or_default();
                if std::mem::take(&mut sh.res_full) {
                    sh.res_up = false;
                    Some((true, json!({ "resources": list }), list))
                } else if std::mem::take(&mut sh.res_up) {
                    let up: serde_json::Map<String, Value> = list.iter().map(|r| (r.name.clone(), r.up.into())).collect();
                    Some((false, json!({ "up": up }), list))
                } else {
                    None
                }
            };
            let Some((full, body, list)) = job else {
                self.res_kick.notified().await;
                continue;
            };
            let r = self.plain("/v1/app/resources", &body, self.o.timeout).await;
            if !full || self.lock().res_full {
                continue; // a newer list: its results are the ones to tell
            }
            let states: Vec<(String, ResourceState)> = list
                .iter()
                .map(|x| {
                    let st = match &r {
                        Ok(v) => ResourceState::from_word(v["states"][&x.name].as_str().unwrap_or("")),
                        Err(e) => ResourceState::Failed(e.kind),
                    };
                    (x.name.clone(), st)
                })
                .collect();
            self.lock().res_states.extend(states.iter().cloned());
            self.emit(Event::Resources(states));
        }
    }

    /* ---- requests ---- */

    /// npf, once it is there (at most `until`), or why not
    async fn wait_up(&self, until: Instant) -> Result<Target> {
        let mut rx = self.changed.subscribe();
        loop {
            {
                let sh = self.lock();
                if sh.stopping {
                    return Err(ErrorKind::State.into());
                }
                if let Some(e) = &sh.gave_up {
                    return Err(e.clone());
                }
                if let Some(t) = &sh.target {
                    return Ok(t.clone());
                }
            }
            match tokio::time::timeout_at(until.into(), rx.changed()).await {
                Ok(Ok(())) => {}
                _ => return Err(ErrorKind::NoNpf.into()),
            }
        }
    }

    /// resolves once the link stops
    async fn stopped(&self) {
        let mut rx = self.changed.subscribe();
        while !self.lock().stopping {
            if rx.changed().await.is_err() {
                return;
            }
        }
    }

    fn running(&self) -> Result<Target> {
        let sh = self.lock();
        if sh.stopping {
            return Err(ErrorKind::State.into());
        }
        sh.target.clone().ok_or_else(|| ErrorKind::State.into())
    }
}

/// a device no longer listed, or with no service left for this app
fn gone(p: &Value) -> bool {
    p["gone"] == true || p["services"].as_array().map_or(false, |s| s.is_empty())
}

/// requests of ours awaiting their answers (streams that come first are kept meanwhile)
struct Asking(Arc<Inner>);

impl Asking {
    fn new(i: &Arc<Inner>) -> Asking {
        i.lock().asking += 1;
        Asking(i.clone())
    }
}

impl Drop for Asking {
    fn drop(&mut self) {
        let mut sh = self.0.lock();
        sh.asking -= 1;
        if sh.asking == 0 {
            sh.early.clear();
        }
    }
}

/// The link to npf. Clones are the same link.
#[derive(Clone)]
pub struct Link(pub(crate) Arc<Inner>);

impl Link {
    /// Starts it in tasks of the current tokio runtime (Err State outside
    /// one): it finds npf, attaches, and attaches again after npf went away
    /// until [`Link::stop`].
    pub fn start(o: Options) -> Result<(Link, Events)> {
        if !valid_name(&o.app, 63, true) || !valid_protos(&o.protos) || o.timeout.is_zero() || o.retry.is_zero() {
            return Err(ErrorKind::Invalid.into());
        }
        let rt = tokio::runtime::Handle::try_current().map_err(|_| ErrorKind::State)?;
        let (tx, rx) = mpsc::unbounded_channel();
        let attach = json!({ "events": true, "want": o.want.words(), "protos": o.protos }).to_string();
        let inner = Arc::new(Inner {
            o,
            attach,
            sh: Default::default(),
            changed: watch::channel(0).0,
            res_kick: Notify::new(),
            retry_kick: Notify::new(),
            ev: Mutex::new(Some(tx)),
        });
        let sup = rt.spawn(inner.clone().supervise());
        inner.lock().sup = Some(sup);
        Ok((Link(inner), Events(rx)))
    }

    /// Tries to attach now when it waits to try again (npf came back: an
    /// app in npf's own process knows it before the wait ends); nothing
    /// otherwise.
    pub fn retry_now(&self) {
        self.0.retry_kick.notify_waiters();
    }

    /// This device; None when not attached.
    pub fn info(&self) -> Option<Info> {
        let sh = self.0.lock();
        sh.target.as_ref().and(sh.info.clone())
    }

    /// The devices with services this app may use (State: not attached, or not subscribed).
    pub fn peers(&self) -> Result<Vec<Peer>> {
        let sh = self.0.lock();
        if sh.target.is_none() || !self.0.o.want.peers {
            return Err(ErrorKind::State.into());
        }
        Ok(sh.peers.values().cloned().collect())
    }

    /// The assist code (or why there is none); None when not attached or not subscribed.
    pub fn assist(&self) -> Option<Assist> {
        let sh = self.0.lock();
        sh.target.as_ref().and(sh.assist.clone()).filter(|_| self.0.o.want.assist)
    }

    /// The transport in use; None when not attached.
    pub fn transport(&self) -> Option<Transport> {
        self.0.lock().target.as_ref().map(|t| t.transport)
    }

    /// npf's own words on the last failure seen.
    pub fn last_error(&self) -> Option<String> {
        Some(self.0.lock().last_err.clone()).filter(|m| !m.is_empty())
    }

    /// This app's resources are exactly these: kept and declared again at
    /// each connect; what became of them comes as [`Event::Resources`].
    /// Checked here (names, sizes, at most 16; Invalid without `want.requests`).
    pub fn resources_set(&self, list: &[Resource]) -> Result<()> {
        if !self.0.o.want.requests || list.len() > 16 {
            return Err(ErrorKind::Invalid.into());
        }
        let mut total = 16;
        for (i, r) in list.iter().enumerate() {
            let len = |s: &Option<String>, max| s.as_ref().map_or(true, |s| s.len() <= max);
            if !valid_name(&r.name, 64, true)
                || !valid_name(&r.svc, 63, true)
                || !len(&r.title, 64)
                || !len(&r.desc, 256)
                || r.caps.len() > 16
                || !r.caps.iter().all(|c| valid_name(c, 15, false) && !c.contains('_'))
                || list[..i].iter().any(|x| x.name == r.name)
            {
                return Err(ErrorKind::Invalid.into());
            }
            let n = serde_json::to_string(r).map_or(usize::MAX, |s| s.len() + 1);
            total += n;
            if n > 4096 || total > 32768 {
                return Err(ErrorKind::TooBig.into());
            }
        }
        let mut sh = self.0.lock();
        if sh.stopping {
            return Err(ErrorKind::State.into());
        }
        sh.res = Some(list.to_vec());
        sh.res_full = sh.target.is_some();
        drop(sh);
        self.0.res_kick.notify_one();
        Ok(())
    }

    /// Only `up` of one of them (npf passes on at most one change a second).
    pub fn resource_up(&self, name: &str, up: bool) -> Result<()> {
        let mut sh = self.0.lock();
        let r = sh.res.iter_mut().flatten().find(|r| r.name == name).ok_or(ErrorKind::NotFound)?;
        r.up = up;
        sh.res_up = sh.target.is_some();
        drop(sh);
        self.0.res_kick.notify_one();
        Ok(())
    }

    /// Asks `peer` (a device number, or a share code: npf pairs with it
    /// first) for a service of its resource `res`. Waits for npf at most the
    /// timeout, then for the peer's answer (at most 95 s). Dropped before
    /// the answer, the request is withdrawn.
    pub async fn request(&self, peer: &str, res: &str, body: Option<&Value>) -> Result<Service> {
        if peer.is_empty() || peer.len() > 64 || !valid_name(res, 64, true) {
            return Err(ErrorKind::Invalid.into());
        }
        let req = json!({ "peer": peer, "res": res, "body": body_of(body)? });
        let i = &self.0;
        let t = i.wait_up(Instant::now() + i.o.timeout).await?;
        let _asking = Asking::new(i);
        let r = tokio::time::timeout(REQUEST_TIME, async {
            let mut c = i.upgrade(&t, "/v1/app/request", &req, None).await?;
            let line = c.line(REPLY_MAX).await?.ok_or_else(|| i.lost(ErrorKind::Io.into()))?;
            let a: Value = serde_json::from_slice(&line).map_err(|_| ErrorKind::Proto)?;
            let sid = a["service"].as_u64().ok_or(ErrorKind::Proto)? as u32;
            let slots: Vec<Slot> = a["slots"]
                .as_array()
                .into_iter()
                .flatten()
                .filter(|s| s["kind"] == "media")
                .filter_map(|s| serde_json::from_value::<Slot>(s.clone()).ok())
                .filter(|s| (1..=crate::TAG_MAX).contains(&s.tag) && (1..=1000).contains(&s.n))
                .collect();
            let (guard, incoming) = i.register(sid);
            Ok(Service {
                id: sid,
                proto: a["proto"].as_str().unwrap_or("").to_owned(),
                body: if a["body"].is_object() { a["body"].clone() } else { json!({}) },
                open: Opener::new(i, sid, Some(&slots)),
                slots,
                main: Channel::new(c, Some(guard)),
                incoming,
            })
        });
        r.await.unwrap_or_else(|_| Err(ErrorKind::Timeout.into()))
    }

    /// Accepts a request ([`Event::Request`]): the service's main channel,
    /// and `slots` the media streams the requester may open.
    pub async fn accept(&self, service: u32, body: Option<&Value>, slots: &[Slot]) -> Result<Service> {
        if slots.len() > crate::TAG_MAX as usize || !slots.iter().all(|s| (1..=crate::TAG_MAX).contains(&s.tag) && (1..=30).contains(&s.n)) {
            return Err(ErrorKind::Invalid.into());
        }
        let body = body_of(body)?;
        let i = &self.0;
        let t = i.running()?;
        let proto = self.take_asked(service)?;
        let sl: Vec<Value> = slots.iter().map(|s| json!({"kind": "media", "tag": s.tag, "n": s.n})).collect();
        let req = json!({ "service": service, "accept": true, "body": body, "slots": sl });
        // registered first: the requester's streams may come before npf's 101 is read
        let (guard, incoming) = i.register(service);
        let c = i.upgrade(&t, "/v1/app/answer", &req, Some(i.o.timeout)).await?;
        Ok(Service {
            id: service,
            proto,
            body,
            slots: slots.to_vec(),
            main: Channel::new(c, Some(guard)),
            open: Opener::new(i, service, None),
            incoming,
        })
    }

    /// Refuses a request; `body` is the requester's error message.
    pub async fn refuse(&self, service: u32, body: Option<&Value>) -> Result<()> {
        let body = body_of(body)?;
        self.0.running()?;
        self.take_asked(service)?;
        let req = json!({ "service": service, "accept": false, "body": body });
        self.0.plain("/v1/app/answer", &req, self.0.o.timeout).await.map(|_| ())
    }

    fn take_asked(&self, service: u32) -> Result<String> {
        match self.0.lock().asked.remove(&service) {
            Some((t, proto)) if t.elapsed() < ASKED_TIME => Ok(proto),
            _ => Err(ErrorKind::NotFound.into()),
        }
    }

    /// A new assist code ("换一个"); it comes as [`Event::Assist`].
    pub async fn assist_renew(&self) -> Result<()> {
        self.0.running()?;
        if !self.0.o.want.assist {
            return Err(ErrorKind::State.into());
        }
        self.0.plain("/v1/app/assist", &json!({"renew": true}), self.0.o.timeout).await.map(|_| ())
    }

    /// One of npf's requests answered with JSON (the sharing page:
    /// `share/list`, `share/new`, `share/revoke`, `member/set`,
    /// `member/remove`, `resource/set`; applink.md 3.2): npf's answer, or
    /// the error with npf's error object in `reply` (404: NotFound).
    pub async fn call(&self, path: &str, body: Option<&Value>) -> Result<Value> {
        let ok = !path.is_empty()
            && path.len() <= 40
            && !path.starts_with('/')
            && !path.ends_with('/')
            && !path.contains("//")
            && path.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b"_-/".contains(&b));
        if !ok {
            return Err(ErrorKind::Invalid.into());
        }
        let body = body.cloned().unwrap_or_else(|| json!({}));
        if body.to_string().len() > REPLY_MAX {
            return Err(ErrorKind::TooBig.into());
        }
        let t = self.0.running()?;
        let (path, body) = (format!("/v1/app/{path}"), body.to_string());
        let r = tokio::select! {
            r = self.0.http(&t, &path, &body, false, Some(CALL_TIME)) => r,
            _ = self.0.stopped() => return Err(ErrorKind::State.into()),
        };
        match r {
            Ok(Resp::Json(200, Some(j))) => Ok(j),
            Ok(Resp::Json(200, None)) | Ok(Resp::Up(_)) => Err(ErrorKind::Proto.into()),
            Ok(Resp::Json(status, j)) => {
                let mut e = self.0.refusal(status, j);
                if status == 404 {
                    e.kind = ErrorKind::NotFound; // no such thing, whatever the word
                }
                Err(e)
            }
            Err(e) => Err(self.0.lost(e)),
        }
    }

    /// Stops: every service's main channel reads its end (written bytes
    /// still go), the events connection closes once they are gone (at most
    /// 10 s), and [`Events`] ends. Calls after it say State.
    pub async fn stop(&self) {
        let i = &self.0;
        let mut rx = i.changed.subscribe();
        {
            let mut sh = i.lock();
            if sh.stopping {
                return;
            }
            sh.stopping = true;
            for t in sh.tasks.drain(..) {
                t.abort();
            }
            for r in sh.routes.values() {
                r.ctl.stop();
            }
        }
        let until = Instant::now() + STOP_TIME;
        while !i.lock().routes.is_empty() {
            if tokio::time::timeout_at(until.into(), rx.changed()).await.is_err() {
                break;
            }
        }
        let sup = {
            let mut sh = i.lock();
            sh.target = None;
            sh.sup.take()
        };
        if let Some(s) = sup {
            s.abort();
        }
        i.ev.lock().unwrap_or_else(|e| e.into_inner()).take();
        i.bump();
    }
}
