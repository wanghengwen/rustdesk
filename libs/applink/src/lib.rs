//! applink's client in Rust, on tokio (docs/design/applink.md): an app
//! holds no identity of its own, it talks to the npf process on this
//! machine and uses npf's sessions through it.
//!
//! This is the second implementation of the client side, beside the C
//! library (`client/applink/src`, applink.h); both speak the same wire
//! protocol and keep the same rules (applink.md 3.6): how npf is found and
//! checked, the reconnects and their backoff, requests waiting for npf, the
//! two idle accept connections, resources declared again at each connect,
//! the hello compared with the copy, the stop order.
//!
//! [`Link::start`] attaches (and keeps reattaching) in tasks of the current
//! runtime and gives the [`Events`]. A [`Service`] is one use of a resource:
//! its main channel ([`Channel`], `AsyncRead + AsyncWrite`), an [`Opener`]
//! for further channels and media streams, and the streams the peer opens
//! ([`Incoming`]). Media streams carry frames ([`Media`] sends and never
//! blocks, [`MediaRx`] receives).
//!
//! ```no_run
//! # async fn f() -> applink::Result<()> {
//! use applink::*;
//! let (link, mut events) = Link::start(Options::new("rustdesk", &["rustdesk/1"]))?;
//! link.resources_set(&[Resource::new("desktop", "rustdesk", &["view"])])?;
//! while let Some(ev) = events.recv().await {
//!     if let Event::Request(r) = ev {
//!         let mut s = link.accept(r.service, None, &[]).await?;
//!         tokio::spawn(async move {
//!             let (mut rd, mut wr) = tokio::io::split(s.main);
//!             tokio::io::copy(&mut rd, &mut wr).await.ok(); // an echo
//!         });
//!     }
//! }
//! # Ok(()) }
//! ```

use serde_json::Value;
use std::fmt;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

mod link;
mod net;
mod stream;
mod sys;
#[cfg(all(test, unix))]
mod tests;
mod types;

pub use link::Link;
pub use net::{BoxIo, Io};
#[cfg(unix)]
pub use net::from_fd;
pub use stream::{Channel, Frame, Incoming, Media, MediaRx, Opened, Opener, Service};
pub use types::*;

/// an app's tags: 1..=59 (0 is the main channel)
pub const TAG_MAX: i32 = 59;
/// a request's or an answer's body, bytes of JSON
pub const BODY_MAX: usize = 8192;
/// bytes of one media frame
pub const FRAME_MAX: usize = 4 << 20;

/* ---------------- errors ---------------- */

macro_rules! kinds {
    ($($k:ident = $code:literal, $word:literal;)*) => {
        /// What went wrong: applink.h's error codes.
        #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
        pub enum ErrorKind { $($k),* }

        impl ErrorKind {
            /// applink.h's `APPLINK_E*` value
            pub fn code(self) -> i32 {
                match self { $(ErrorKind::$k => $code),* }
            }
            /// npf's word for it on the wire where there is one ("offline",
            /// "not_found", "forbidden", ...), else applink's own ("no_npf", "auth", ...)
            pub fn word(self) -> &'static str {
                match self { $(ErrorKind::$k => $word),* }
            }
        }
    };
}

kinds! {
    Invalid = -1, "invalid";
    State = -3, "state";
    NotFound = -4, "not_found_handle";
    Busy = -5, "busy";
    TooBig = -6, "too_big";
    Denied = -7, "denied";
    Io = -8, "io";
    NoNpf = -9, "no_npf";
    Auth = -10, "auth";
    Proto = -11, "proto";
    Timeout = -13, "timeout";
    Closed = -14, "closed";
    Conflict = -15, "conflict";
    Replaced = -17, "replaced";
    Offline = -20, "offline";
    NoPeer = -21, "not_found";
    NoPath = -22, "no_path";
    NoRelay = -23, "no_relay";
    Quota = -24, "quota";
    BadCode = -25, "bad_code";
    NoRemote = -26, "remote_access_off";
    Unavailable = -27, "unavailable";
    NotPaired = -28, "not_paired";
    NeedAccount = -29, "need_account";
    NoAccess = -30, "forbidden";
    Unsupported = -31, "unsupported";
    Refused = -32, "refused";
    Limit = -33, "limit";
    Version = -34, "version";
}

impl ErrorKind {
    /// npf's error word and HTTP status (link.c's alk_err_code)
    pub(crate) fn from_npf(word: Option<&str>, status: u16) -> ErrorKind {
        use ErrorKind::*;
        match word.unwrap_or("") {
            "offline" => Offline,
            "not_found" => NoPeer,
            "not_paired" => NotPaired,
            "need_account" => NeedAccount,
            "no_path" => NoPath,
            "no_relay" => NoRelay,
            "quota" => Quota,
            "forbidden" => NoAccess,
            "unsupported" => Unsupported,
            "refused" => Refused,
            "timeout" => Timeout,
            "limit" => Limit,
            "version" => Version,
            "conflict" => Conflict,
            "too_big" => TooBig,
            "bad_code" => BadCode,
            "remote_access_off" => NoRemote,
            "unavailable" => Unavailable,
            "busy" => Busy,
            "denied" => Denied,
            "unknown_app" => Auth,
            "bad_request" => Invalid,
            "not_found_service" => NotFound,
            _ => match status {
                403 => Denied,
                404 => NotFound,
                409 => State,
                429 => Limit,
                _ => Proto,
            },
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Error {
    pub kind: ErrorKind,
    /// npf's words on it for people (also [`Link::last_error`]); for a
    /// refused request, the provider app's answer body
    pub message: Option<String>,
    /// npf's error object (`{"error", "message", ...}`) when it gave one
    pub reply: Option<Value>,
}

impl Error {
    pub fn new(kind: ErrorKind) -> Error {
        Error {
            kind,
            message: None,
            reply: None,
        }
    }

    pub(crate) fn msg(kind: ErrorKind, m: impl Into<String>) -> Error {
        Error {
            kind,
            message: Some(m.into()),
            reply: None,
        }
    }
}

impl From<ErrorKind> for Error {
    fn from(kind: ErrorKind) -> Error {
        Error::new(kind)
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match &self.message {
            Some(m) => write!(f, "{}: {m}", self.kind.word()),
            None => f.write_str(self.kind.word()),
        }
    }
}

impl std::error::Error for Error {}

pub type Result<T> = std::result::Result<T, Error>;

/* ---------------- options ---------------- */

/// npf in this process (iOS, Android's npf app): a connection to npf for
/// the app named, each call one (`npf_host_app_dial`; [`net::from_fd`] makes
/// one of its descriptor). Not checked: npf's own process.
pub type Dial = Arc<dyn Fn(&str) -> std::io::Result<BoxIo> + Send + Sync>;

/// How to start a [`Link`].
#[derive(Clone)]
pub struct Options {
    /// this app's name in npf's manifest ("rustdesk")
    pub app: String,
    /// npf's data directory (applink.json); None: the defaults, tried in turn
    pub dir: Option<PathBuf>,
    /// the protocol versions this app speaks, preferred first ("rustdesk/1")
    pub protos: Vec<String>,
    pub want: Want,
    /// set: the only way to npf
    pub dial: Option<Dial>,
    /// tests: npf's Unix socket instead of applink.json's (npf taken to be this account's)
    pub unix_path: Option<PathBuf>,
    /// tests: "IP:PORT" instead of applink.json's
    pub tcp_addr: Option<String>,
    /// connecting to npf, its answers; a request waits this long for npf
    pub timeout: Duration,
    /// after npf went away: the first wait, doubling up to 30 s
    pub retry: Duration,
    #[cfg(test)]
    pub(crate) fake: sys::Fake,
}

impl Options {
    /// An app subscribed to everything its manifest allows.
    pub fn new(app: &str, protos: &[&str]) -> Options {
        Options {
            app: app.into(),
            dir: None,
            protos: protos.iter().map(|p| (*p).into()).collect(),
            want: Want::ALL,
            dial: None,
            unix_path: None,
            tcp_addr: None,
            timeout: Duration::from_secs(5),
            retry: Duration::from_secs(1),
            #[cfg(test)]
            fake: Default::default(),
        }
    }
}

/* ---------------- events ---------------- */

/// What npf tells (applink.md 3.3), in order.
#[derive(Clone, Debug, PartialEq)]
pub enum Event {
    /// connected to npf (first, before the state below), or not: why
    /// (NoNpf, Proto, Timeout: tried again later; Auth, Denied, Replaced:
    /// given up). A down is told once per reason.
    Up,
    Down(Error),
    /// this device: at each connect and when it changes
    Info(Info),
    /// a device appeared, changed or is gone (`gone`): at each connect all of them
    Peer(Peer),
    /// the assist code changed
    Assist(Assist),
    /// the relay quota: bytes used of limit this month
    Quota { used: u64, limit: u64 },
    /// a peer asks for a service: [`Link::accept`] or [`Link::refuse`] it within 60 s
    Request(Request),
    /// a request not answered is no more: Closed (withdrawn), Timeout, NoNpf
    Cancel { service: u32, why: ErrorKind },
    /// what npf made of [`Link::resources_set`]'s list (after each set and each connect)
    Resources(Vec<(String, ResourceState)>),
    /// one of this app's resources changed state (the admin here)
    Resource(String, ResourceState),
    /// the sharing page's state changed (its revision): ask `share/list` again
    Share(u64),
    /// npf's own UI (its console's buttons) asks this app to open a session:
    /// `what` (desktop, files, terminal) with `peer` (a number or a share
    /// code), or with neither its window (3.3 `open`)
    Open { what: Option<String>, peer: Option<String> },
}

/// The link's events; None once it stopped.
pub struct Events(pub(crate) tokio::sync::mpsc::UnboundedReceiver<Event>);

impl Events {
    pub async fn recv(&mut self) -> Option<Event> {
        self.0.recv().await
    }
}

/* ---------------- local checks ---------------- */

/// 1..=max of a-z 0-9 - _ (and . when dots)
pub(crate) fn valid_name(s: &str, max: usize, dots: bool) -> bool {
    !s.is_empty()
        && s.len() <= max
        && s.bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-' || b == b'_' || (dots && b == b'.'))
}

/// an app's body: a JSON object of at most BODY_MAX bytes ({} when none)
pub(crate) fn body_of(b: Option<&Value>) -> Result<Value> {
    let b = b.cloned().unwrap_or_else(|| Value::Object(Default::default()));
    if !b.is_object() {
        return Err(ErrorKind::Invalid.into());
    }
    if b.to_string().len() > BODY_MAX {
        return Err(ErrorKind::TooBig.into());
    }
    Ok(b)
}

/// "svc/N", at most 4 of one service type
pub(crate) fn valid_protos(p: &[String]) -> bool {
    p.iter().all(|x| match x.split_once('/') {
        Some((svc, v)) => {
            !svc.is_empty()
                && !v.is_empty()
                && x.len() <= 80
                && !x.contains(['"', '\\'])
                && p.iter().filter(|y| y.starts_with(&format!("{svc}/"))).count() <= 4
        }
        None => false,
    })
}
