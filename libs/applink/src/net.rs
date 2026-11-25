//! Connections to npf (applink.md 3.2, 3.4): one per request, HTTP/1.1 with
//! most of them upgraded; each checked to reach npf before anything is sent.

use crate::link::Inner;
use crate::sys::{self, Owner};
use crate::{Error, ErrorKind, Result, Transport};
use bytes::{Buf, BytesMut};
use serde_json::Value;
use std::io;
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

/// A byte stream to npf.
pub trait Io: AsyncRead + AsyncWrite + Send + Sync + Unpin + 'static {}
impl<T: AsyncRead + AsyncWrite + Send + Sync + Unpin + 'static> Io for T {}
pub type BoxIo = Box<dyn Io>;

/// A connected descriptor ([`crate::Options::dial`]: `npf_host_app_dial`'s).
#[cfg(unix)]
pub fn from_fd(fd: std::os::unix::io::RawFd) -> io::Result<BoxIo> {
    use std::os::unix::io::FromRawFd;
    let s = unsafe { std::os::unix::net::UnixStream::from_raw_fd(fd) };
    s.set_nonblocking(true)?;
    Ok(Box::new(tokio::net::UnixStream::from_std(s)?))
}

const HEAD_MAX: usize = 8192;
/// a reply's body, a first line
pub(crate) const REPLY_MAX: usize = 65536;
/// an events line (a whole hello), applink_call's reply
pub(crate) const LINE_MAX: usize = 512 << 10;
/// a connection closed here waits that long for npf's end
const LINGER: Duration = Duration::from_secs(5);

/// npf as one candidate describes it.
#[derive(Clone, Debug)]
pub(crate) struct Target {
    pub transport: Transport,
    /// the socket's path or IP:PORT
    pub addr: String,
    pub owner: Owner,
    /// applink.json's pid (0: not given)
    #[allow(dead_code)]
    pub pid: u32,
}

impl Target {
    fn host(&self) -> &str {
        if self.transport == Transport::Tcp {
            &self.addr
        } else {
            "localhost"
        }
    }
}

/// A connection and what was read from it beyond the step under way.
/// Dropped, it ends: what was written still goes, then npf's end is
/// awaited (at most 5 s) so that nothing unread resets it.
pub(crate) struct Conn {
    pub io: Option<BoxIo>,
    pub buf: BytesMut,
}

impl Conn {
    /// more bytes into buf: 0 at the end
    pub async fn fill(&mut self) -> io::Result<usize> {
        let io = self.io.as_mut().ok_or_else(|| io::Error::from(io::ErrorKind::NotConnected))?;
        self.buf.reserve(64 << 10);
        io.read_buf(&mut self.buf).await
    }

    /// one line without its \n; None at the end
    pub async fn line(&mut self, max: usize) -> Result<Option<BytesMut>> {
        loop {
            if let Some(i) = self.buf.iter().position(|b| *b == b'\n') {
                let mut l = self.buf.split_to(i + 1);
                l.truncate(i);
                return Ok(Some(l));
            }
            if self.buf.len() > max {
                return Err(ErrorKind::Proto.into());
            }
            if self.fill().await.map_err(|_| ErrorKind::Io)? == 0 {
                return Ok(None);
            }
        }
    }
}

impl Drop for Conn {
    fn drop(&mut self) {
        if let Some(io) = self.io.take() {
            if let Ok(rt) = tokio::runtime::Handle::try_current() {
                rt.spawn(linger(io));
            }
        }
    }
}

pub(crate) async fn linger<T: AsyncRead + AsyncWrite + Unpin>(mut io: T) {
    let _ = tokio::time::timeout(LINGER, async {
        io.shutdown().await.ok();
        let mut b = [0u8; 4096];
        while matches!(io.read(&mut b).await, Ok(n) if n > 0) {}
    })
    .await;
}

/// npf's response: upgraded, or a status and its JSON
pub(crate) enum Resp {
    Up(Conn),
    Json(u16, Option<Value>),
}

fn find(h: &[u8], what: &[u8]) -> Option<usize> {
    h.windows(what.len()).position(|w| w == what)
}

impl Inner {
    /// a connection to npf, checked to be npf: the Unix socket's peer each
    /// time (cheap), on Windows the TCP listener for the events connection
    pub(crate) async fn connect(&self, t: &Target, events: bool) -> Result<BoxIo> {
        let not_npf = || Error::msg(ErrorKind::Auth, "the other end is not npf of this account");
        let io: BoxIo = match t.transport {
            Transport::InProc => match &self.o.dial {
                Some(d) => d(&self.o.app).map_err(|_| ErrorKind::NoNpf)?,
                None => return Err(ErrorKind::NoNpf.into()),
            },
            #[cfg(unix)]
            Transport::Unix => {
                let s = tokio::time::timeout(self.o.timeout, tokio::net::UnixStream::connect(&t.addr))
                    .await
                    .map_err(|_| ErrorKind::NoNpf)?
                    .map_err(|_| ErrorKind::NoNpf)?;
                if !sys::check_unix(&s, &t.owner, self.fake()) {
                    self.set_err("the other end is not npf of this account");
                    return Err(not_npf());
                }
                Box::new(s)
            }
            #[cfg(not(unix))]
            Transport::Unix => return Err(ErrorKind::NoNpf.into()),
            Transport::Tcp => {
                let s = tokio::time::timeout(self.o.timeout, tokio::net::TcpStream::connect(&t.addr))
                    .await
                    .map_err(|_| ErrorKind::NoNpf)?
                    .map_err(|_| ErrorKind::NoNpf)?;
                s.set_nodelay(true).ok();
                #[cfg(windows)]
                if events {
                    match sys::check_tcp(&s, &t.owner, t.pid, self.fake()) {
                        Some(true) => {}
                        None => return Err(ErrorKind::NoNpf.into()),
                        Some(false) => {
                            self.set_err("the other end is not npf of this account");
                            return Err(not_npf());
                        }
                    }
                }
                #[cfg(not(windows))]
                let _ = (events, &not_npf);
                Box::new(s)
            }
        };
        Ok(io)
    }

    /// POST path with body; `head`: npf's response head within that long
    pub(crate) async fn http(&self, t: &Target, path: &str, body: &str, upgrade: bool, head: Option<Duration>) -> Result<Resp> {
        let io = self.connect(t, path == "/v1/app/attach").await?;
        let mut c = Conn {
            io: Some(io),
            buf: BytesMut::new(),
        };
        let req = format!(
            "POST {path} HTTP/1.1\r\nHost: {}\r\nNpf-App: {}\r\n{}Content-Type: application/json\r\nContent-Length: {}\r\n\r\n{body}",
            t.host(),
            self.o.app,
            if upgrade { "Connection: Upgrade\r\nUpgrade: npf-app/1\r\n" } else { "" },
            body.len()
        );
        let exchange = async {
            if let Some(io) = c.io.as_mut() {
                io.write_all(req.as_bytes()).await.map_err(|_| ErrorKind::Io)?;
            }
            response(&mut c, is_call(path)).await
        };
        let r = match head {
            Some(d) => tokio::time::timeout(d, exchange).await.map_err(|_| ErrorKind::Timeout)?,
            None => exchange.await,
        };
        r.map(|(status, j)| {
            if status == 101 {
                Resp::Up(c)
            } else {
                drop(c.io.take());
                Resp::Json(status, j)
            }
        })
    }

    /// an upgrade, or the error npf answered
    pub(crate) async fn upgrade(&self, t: &Target, path: &str, body: &Value, head: Option<Duration>) -> Result<Conn> {
        match self.http(t, path, &body.to_string(), true, head).await {
            Ok(Resp::Up(c)) => Ok(c),
            Ok(Resp::Json(status, j)) => Err(self.refusal(status, j)),
            Err(e) => Err(self.lost(e)),
        }
    }

    /// a request without upgrade: npf's JSON on 200, else the error
    pub(crate) async fn plain(&self, path: &str, body: &Value, wait: Duration) -> Result<Value> {
        let t = self.target().ok_or(ErrorKind::State)?;
        match self.http(&t, path, &body.to_string(), false, Some(wait)).await {
            Ok(Resp::Json(200, Some(j))) => Ok(j),
            Ok(Resp::Json(status, j)) if status != 200 => Err(self.refusal(status, j)),
            Ok(_) => Err(ErrorKind::Proto.into()),
            Err(e) => Err(self.lost(e)),
        }
    }

    /// the end came early: the connection to npf broke, npf went away
    pub(crate) fn lost(&self, e: Error) -> Error {
        if e.kind == ErrorKind::Io {
            ErrorKind::NoNpf.into()
        } else {
            e
        }
    }

    /// a response other than 101 (and npf's words for people)
    pub(crate) fn refusal(&self, status: u16, j: Option<Value>) -> Error {
        let Some(j) = j else {
            return ErrorKind::Proto.into();
        };
        let message = j["message"].as_str().map(str::to_owned);
        if let Some(m) = &message {
            self.set_err(m);
        }
        Error {
            kind: ErrorKind::from_npf(j["error"].as_str(), status),
            message,
            reply: Some(j),
        }
    }
}

fn is_call(path: &str) -> bool {
    !matches!(
        path,
        "/v1/app/request" | "/v1/app/answer" | "/v1/app/channel" | "/v1/app/media" | "/v1/app/accept" | "/v1/app/resources" | "/v1/app/assist"
    )
}

/// the response's head; a body (not after 101) to its Content-Length or the end
async fn response(c: &mut Conn, big: bool) -> Result<(u16, Option<Value>)> {
    let end = loop {
        if let Some(i) = find(&c.buf, b"\r\n\r\n") {
            break i;
        }
        if c.buf.len() > HEAD_MAX {
            return Err(ErrorKind::Proto.into());
        }
        if c.fill().await.map_err(|_| ErrorKind::Io)? == 0 {
            return Err(ErrorKind::Io.into());
        }
    };
    let head = String::from_utf8_lossy(&c.buf[..end]).into_owned();
    c.buf.advance(end + 4);
    let status: u16 = head
        .strip_prefix("HTTP/1.")
        .and_then(|r| r.get(2..5))
        .and_then(|s| s.parse().ok())
        .filter(|s| *s >= 100)
        .ok_or(ErrorKind::Proto)?;
    if status == 101 {
        return Ok((101, None));
    }
    let clen = head.split("\r\n").skip(1).find_map(|l| {
        let (k, v) = l.split_once(':')?;
        k.trim().eq_ignore_ascii_case("content-length").then(|| v.trim().parse::<usize>().ok())?
    });
    let max = if big { LINE_MAX } else { REPLY_MAX };
    if clen.map_or(false, |n| n > max) {
        return Err(ErrorKind::Proto.into());
    }
    while clen.map_or(true, |n| c.buf.len() < n) && c.buf.len() <= max {
        match c.fill().await {
            Ok(0) | Err(_) if clen.is_none() => break,
            Ok(0) | Err(_) => return Err(ErrorKind::Io.into()),
            Ok(_) => {}
        }
    }
    let body = &c.buf[..clen.unwrap_or(c.buf.len()).min(c.buf.len())];
    Ok((status, serde_json::from_slice::<Value>(body).ok().filter(Value::is_object)))
}
