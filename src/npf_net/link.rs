//! The service process's link to npf: the applink client, its events (npf's
//! requests go to `serve`), npf's state for the UI, and the UI's IPC requests.
//! A phone (Android, iOS): the app's own link to npf in this process (`attach`).

use super::call;
#[cfg(not(any(target_os = "android", target_os = "ios")))]
use super::serve;
#[cfg(not(any(target_os = "android", target_os = "ios")))]
use crate::server::ServerPtr;
#[cfg(not(any(target_os = "android", target_os = "ios")))]
use applink::Resource;
use applink::{Assist, Error, ErrorKind, Event, Info, Link, Options, Peer, ResourceState};
use hbb_common::{log, tokio};
use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    sync::{Mutex, MutexGuard, OnceLock},
    time::Duration,
};

pub const APP: &str = "rustdesk";
pub const PROTO: &str = "rustdesk/1";
pub const RES: &str = "desktop";
#[cfg(not(any(target_os = "android", target_os = "ios")))]
const CAPS: [&str; 4] = ["view", "control", "file", "terminal"];

/// npf's state as the events tell it
#[derive(Default)]
struct State {
    up: bool,
    why: Option<Error>,
    info: Option<Info>,
    peers: BTreeMap<u64, Peer>,
    assist: Option<Assist>,
    quota: Option<(u64, u64)>,
    resource: Option<ResourceState>,
    /// npf's revision of the sharing page's state
    share: Option<u64>,
}

static LINK: OnceLock<Link> = OnceLock::new();
static STATE: Mutex<Option<State>> = Mutex::new(None);
#[cfg(not(any(target_os = "android", target_os = "ios")))]
static SERVER: OnceLock<ServerPtr> = OnceLock::new();

fn with<T>(f: impl FnOnce(&mut State) -> T) -> T {
    let mut g: MutexGuard<'_, Option<State>> = STATE.lock().unwrap();
    f(g.get_or_insert_with(Default::default))
}

/// The client, once started.
pub fn link() -> Option<&'static Link> {
    LINK.get()
}

/// Why npf cannot be used now (the connection to it is down), or None.
pub fn down() -> Option<Error> {
    if link().is_none() {
        return Some(Error::new(ErrorKind::NoNpf));
    }
    with(|st| (!st.up).then(|| st.why.clone().unwrap_or_else(|| Error::new(ErrorKind::NoNpf))))
}

/// RustDesk's server.
#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub fn server() -> Option<&'static ServerPtr> {
    SERVER.get()
}

/// Attaches to npf (in the service process, on its tokio runtime); the
/// client keeps trying while npf is not there.
#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub async fn start(server: ServerPtr) {
    if SERVER.set(server).is_err() {
        return;
    }
    let mut o = Options::new(APP, &[PROTO]);
    // tests: an npf with a data directory of its own
    o.dir = std::env::var_os("RUSTDESK_NPF_DIR").map(Into::into);
    let (l, mut events) = match Link::start(o) {
        Ok(x) => x,
        Err(e) => return log::error!("npf: applink did not start: {e}"),
    };
    if let Err(e) = l.resources_set(&[Resource::new(RES, APP, &CAPS)]) {
        log::error!("npf: resource {RES} not declared: {e}");
    }
    if LINK.set(l).is_err() {
        return;
    }
    log::info!("npf: applink started");
    while let Some(e) = events.recv().await {
        event(e);
    }
}

/* ---- a phone (Android, iOS): npf in this process ---- */

/// The runtime the link and its services run on (a session's own runtime
/// ends with it).
#[cfg(any(target_os = "android", target_os = "ios"))]
fn runtime() -> Option<&'static tokio::runtime::Runtime> {
    static RT: OnceLock<Option<tokio::runtime::Runtime>> = OnceLock::new();
    let build = || {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("npf-link")
            .enable_all()
            .build()
            .map_err(|e| log::error!("npf: no runtime: {e}"))
            .ok()
    };
    RT.get_or_init(build).as_ref()
}

/// Attaches to npf in this process, the first call; its runtime. No
/// resources: a phone is not controlled (applink.md A13; npf's manifest
/// gives this app none there either).
#[cfg(any(target_os = "android", target_os = "ios"))]
pub fn attach() -> Option<&'static tokio::runtime::Runtime> {
    static ONCE: std::sync::Once = std::sync::Once::new();
    let rt = runtime()?;
    ONCE.call_once(|| {
        let _in = rt.enter();
        let mut o = Options::new(APP, &[PROTO]);
        o.dial = Some(std::sync::Arc::new(dial));
        let (l, mut events) = match Link::start(o) {
            Ok(x) => x,
            Err(e) => return log::error!("npf: applink did not start: {e}"),
        };
        if LINK.set(l).is_ok() {
            log::info!("npf: applink started (in this process)");
            rt.spawn(async move {
                while let Some(e) = events.recv().await {
                    event(e);
                }
            });
        }
    });
    Some(rt)
}

/// Waits (at most 5 s) for the link to be up: just started, or npf back
/// after it stopped (asked to try at once, not after its backoff).
#[cfg(any(target_os = "android", target_os = "ios"))]
pub async fn settled() {
    for i in 0..100 {
        let Some(l) = link() else { return };
        if with(|st| st.up) {
            return;
        }
        if i % 20 == 0 {
            l.retry_now();
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

/// A connection to npf for the app: `npf_host_app_dial` of npf's
/// libnpfjni.so (loaded by the app before this library).
#[cfg(target_os = "android")]
fn dial(app: &str) -> std::io::Result<applink::BoxIo> {
    use hbb_common::libc;
    use std::{ffi::c_void, io, os::raw::c_char};
    type Dial = unsafe extern "C" fn(*mut c_void, *const c_char, *mut isize) -> i32;
    static DIAL: OnceLock<usize> = OnceLock::new();
    let f = match DIAL.get() {
        Some(f) => *f,
        None => {
            let f = unsafe {
                let h = libc::dlopen(b"libnpfjni.so\0".as_ptr() as _, libc::RTLD_NOW);
                if h.is_null() {
                    return Err(io::Error::new(io::ErrorKind::NotFound, "libnpfjni.so not loaded"));
                }
                libc::dlsym(h, b"npf_host_app_dial\0".as_ptr() as _)
            };
            if f.is_null() {
                return Err(io::Error::new(io::ErrorKind::NotFound, "no npf_host_app_dial"));
            }
            *DIAL.get_or_init(|| f as usize)
        }
    };
    let f: Dial = unsafe { std::mem::transmute(f) };
    let app = std::ffi::CString::new(app)?;
    let mut sock: isize = -1;
    if unsafe { f(std::ptr::null_mut(), app.as_ptr(), &mut sock) } != 0 {
        return Err(io::Error::new(io::ErrorKind::ConnectionRefused, "npf is not running"));
    }
    applink::from_fd(sock as i32)
}

/// A connection to npf for the app: `npf_host_app_dial` of npf_host,
/// linked into the same app binary as this library (npf's iOS app).
#[cfg(target_os = "ios")]
fn dial(app: &str) -> std::io::Result<applink::BoxIo> {
    use std::{ffi::c_void, io, os::raw::c_char};
    extern "C" {
        fn npf_host_app_dial(unused: *mut c_void, app: *const c_char, sock: *mut isize) -> i32;
    }
    let app = std::ffi::CString::new(app)?;
    let mut sock: isize = -1;
    if unsafe { npf_host_app_dial(std::ptr::null_mut(), app.as_ptr(), &mut sock) } != 0 {
        return Err(io::Error::new(io::ErrorKind::ConnectionRefused, "npf is not running"));
    }
    applink::from_fd(sock as i32)
}

fn event(e: Event) {
    let resource = |name: &str, st: ResourceState| {
        if name == RES {
            if let ResourceState::Failed(e) = st {
                log::warn!("npf: resource {RES}: {}", e.word());
            }
            with(|s| s.resource = Some(st));
        }
    };
    match e {
        Event::Up => {
            log::info!("npf: applink up");
            with(|s| (s.up, s.why) = (true, None));
        }
        Event::Down(e) => {
            log::warn!("npf: applink down: {e}");
            with(|s| {
                (s.up, s.why) = (false, Some(e));
                s.peers.clear();
            });
        }
        Event::Info(i) => with(|s| s.info = Some(i)),
        Event::Peer(p) => with(|s| {
            if p.gone {
                s.peers.remove(&p.number);
            } else {
                s.peers.insert(p.number, p);
            }
        }),
        Event::Assist(a) => with(|s| s.assist = Some(a)),
        Event::Quota { used, limit } => with(|s| s.quota = Some((used, limit))),
        #[cfg(not(any(target_os = "android", target_os = "ios")))]
        Event::Request(r) => serve::request(r),
        // no resources here: none come
        #[cfg(any(target_os = "android", target_os = "ios"))]
        Event::Request(r) => log::warn!("npf: request {} for {}: not served here", r.service, r.res),
        Event::Cancel { .. } => {}
        Event::Resources(v) => v.into_iter().for_each(|(n, st)| resource(&n, st)),
        Event::Resource(n, st) => resource(&n, st),
        Event::Share(rev) => with(|s| s.share = Some(rev)),
        #[cfg(not(any(target_os = "android", target_os = "ios")))]
        Event::Open { what, peer } => open(what.as_deref(), peer.as_deref()),
        // npf's app opens its sessions itself
        #[cfg(any(target_os = "android", target_os = "ios"))]
        Event::Open { .. } => {}
    }
}

/// npf's console asks for a session (or, with neither, the window): its URL
/// to ouDesk's window as a second instance hands it on (Windows: the
/// runner's WM_COPYDATA of uni_links_desktop; elsewhere common.rs
/// handle_url_scheme), so the console needs no browser prompt for the
/// scheme. This is the service's process (or the portable one, the window
/// itself); with no window, ouDesk is started with the URL, as the user of
/// this session.
#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn open(what: Option<&str>, peer: Option<&str>) {
    let path = match (what, peer) {
        (None, None) => String::new(),
        (Some(w), Some(p)) if p.len() < 32 && p.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-') => {
            match w {
                "desktop" => format!("connection/new/{p}"),
                "files" => format!("file-transfer/{p}"),
                "terminal" => format!("terminal/{p}"),
                _ => return log::warn!("npf: open {w}: not known here"),
            }
        }
        _ => return log::warn!("npf: open: {what:?} {peer:?} not understood"),
    };
    let url = format!("{}{path}", crate::get_uri_prefix());
    log::info!("npf: the console opens {url}");
    #[cfg(windows)]
    let peer = peer.map(str::to_owned);
    std::thread::spawn(move || {
        #[cfg(windows)]
        {
            let before = sessions(None);
            if let Some(main) = to_window(&url) {
                to_front(main, peer.as_deref(), &before, 30);
            } else {
                log::info!("npf: no window: starting one");
                if let Err(e) = crate::platform::run_as_user(vec![url.as_str()]) {
                    return log::warn!("npf: open {url}: {e}");
                }
                if let Some(main) = (0..50).find_map(|_| {
                    std::thread::sleep(std::time::Duration::from_millis(200));
                    main_window()
                }) {
                    to_front(main, peer.as_deref(), &before, 100);
                }
            }
        }
        #[cfg(target_os = "macos")]
        mac_open(&url);
        #[cfg(not(any(windows, target_os = "macos")))]
        crate::common::handle_url_scheme(url);
    });
}

/// macOS: the URL to the window process over RustDesk's `_url` IPC (as a
/// second instance hands it on; the session window raises the app itself),
/// else ouDesk started through LaunchServices with it, a new instance of
/// this bundle (the running one may be this agent): in the user's session
/// and in front, as when a browser opens a link.
#[cfg(target_os = "macos")]
fn mac_open(url: &str) {
    if crate::ipc::send_url_scheme(url.to_owned()).is_ok() {
        return;
    }
    log::info!("npf: no window: starting one");
    // .../ouDesk.app/Contents/MacOS/ouDesk
    let app = std::env::current_exe().ok().and_then(|p| p.ancestors().nth(3).map(|a| a.to_owned()));
    let Some(app) = app.filter(|a| a.extension().map_or(false, |e| e == "app")) else {
        return log::warn!("npf: open {url}: not in an app bundle");
    };
    match std::process::Command::new("/usr/bin/open").arg("-n").arg("-a").arg(&app).arg("--args").arg(url).status() {
        Ok(s) if s.success() => {}
        r => log::warn!("npf: open {url}: open -a {app:?}: {r:?}"),
    }
}

/// the URL to the main window, as main.cpp's DispatchToUniLinksDesktop
/// does; the window when it took it
#[cfg(windows)]
fn to_window(url: &str) -> Option<usize> {
    use winapi::um::winuser::{FindWindowW, SendMessageTimeoutW, COPYDATASTRUCT, SMTO_ABORTIFHUNG, WM_COPYDATA, WM_USER};
    let text = std::ffi::CString::new(url).ok()?;
    let hwnd = main_window()? as winapi::shared::windef::HWND;
    unsafe {
        let cds = COPYDATASTRUCT {
            dwData: (WM_USER + 2) as usize, // UNI_LINKS_DESKTOP_MSG_ID
            cbData: text.as_bytes_with_nul().len() as u32,
            lpData: text.as_ptr() as *mut _,
        };
        let mut res = 0;
        let ok = SendMessageTimeoutW(hwnd, WM_COPYDATA, 0, &cds as *const _ as isize, SMTO_ABORTIFHUNG, 3000, &mut res);
        (ok != 0).then_some(hwnd as usize)
    }
}

/// ouDesk's main window (hidden, it takes the URLs)
#[cfg(windows)]
fn main_window() -> Option<usize> {
    let wide = |s: &str| s.encode_utf16().chain(Some(0)).collect::<Vec<u16>>();
    let (class, title) = (wide("FLUTTER_RUNNER_WIN32_WINDOW"), wide(&crate::get_app_name()));
    let h = unsafe { winapi::um::winuser::FindWindowW(class.as_ptr(), title.as_ptr()) };
    (!h.is_null()).then_some(h as usize)
}

/// The session's window to the front. A browser opening a link hands its
/// right to the foreground on (main.cpp's AllowSetForegroundWindow); asked
/// through npf nobody has it, so Windows leaves the new window behind the
/// browser, flashing. This process takes the foreground's input for a moment
/// (or presses Alt, the usual way when that is not enough) and raises it.
/// The window: the peer's session (its title has the number), else one that
/// was not there before (a share code: the title has the number it stands
/// for), else (no peer: the window only) the one in front. Tries that many
/// tenths of a second.
#[cfg(windows)]
fn to_front(main: usize, peer: Option<&str>, before: &[usize], tries: u32) {
    use winapi::shared::windef::HWND;
    use winapi::um::winuser::*;
    let pid = unsafe {
        let mut p = 0;
        GetWindowThreadProcessId(main as HWND, &mut p);
        p
    };
    for _ in 0..tries {
        std::thread::sleep(std::time::Duration::from_millis(100));
        let now = sessions(Some(pid));
        let hit = peer.and_then(|p| now.iter().find(|w| title(**w).contains(p)));
        let fresh = || now.iter().find(|w| !before.contains(w));
        let Some(&h) = hit.or_else(fresh).or(if peer.is_none() { now.first() } else { None }) else { continue };
        unsafe {
            let h = h as HWND;
            let fg = GetForegroundWindow();
            if fg == h {
                return;
            }
            let (me, there) = (winapi::um::processthreadsapi::GetCurrentThreadId(), GetWindowThreadProcessId(fg, std::ptr::null_mut()));
            let attached = there != 0 && there != me && AttachThreadInput(me, there, 1) != 0;
            if IsIconic(h) != 0 {
                ShowWindow(h, SW_RESTORE);
            }
            SetForegroundWindow(h);
            BringWindowToTop(h);
            if attached {
                AttachThreadInput(me, there, 0);
            }
            if GetForegroundWindow() != h {
                keybd_event(VK_MENU as u8, 0, KEYEVENTF_EXTENDEDKEY, 0);
                SetForegroundWindow(h);
                keybd_event(VK_MENU as u8, 0, KEYEVENTF_EXTENDEDKEY | KEYEVENTF_KEYUP, 0);
            }
            log::info!("npf: session window in front: {}", GetForegroundWindow() == h);
        }
        return;
    }
}

/// ouDesk's visible session windows (class RustdeskMultiWindow; of process
/// pid, else of the main window's), the front one first
#[cfg(windows)]
fn sessions(pid: Option<u32>) -> Vec<usize> {
    use winapi::shared::{minwindef::*, windef::HWND};
    use winapi::um::winuser::*;
    let Some(pid) = pid.or_else(|| {
        let mut p = 0;
        main_window().map(|h| unsafe { GetWindowThreadProcessId(h as HWND, &mut p) }).map(|_| p)
    }) else {
        return vec![];
    };
    unsafe extern "system" fn each(h: HWND, l: LPARAM) -> BOOL {
        let (pid, out) = &mut *(l as *mut (u32, Vec<usize>));
        let mut p = 0;
        GetWindowThreadProcessId(h, &mut p);
        let mut b = [0u16; 64];
        let n = GetClassNameW(h, b.as_mut_ptr(), 64) as usize;
        if p == *pid && IsWindowVisible(h) != 0 && String::from_utf16_lossy(&b[..n]) == "RustdeskMultiWindow" {
            out.push(h as usize);
        }
        TRUE
    }
    let mut f = (pid, Vec::new());
    unsafe { EnumWindows(Some(each), &mut f as *mut (u32, Vec<usize>) as LPARAM) };
    f.1
}

#[cfg(windows)]
fn title(h: usize) -> String {
    let mut b = [0u16; 256];
    let n = unsafe { winapi::um::winuser::GetWindowTextW(h as _, b.as_mut_ptr(), 256) } as usize;
    String::from_utf16_lossy(&b[..n])
}

/* ---- the state for the UI ---- */

/// A device's path and round trip ("p2p", 12), when there is a session.
pub fn path_of(number: u64) -> (Option<&'static str>, Option<u32>) {
    with(|st| st.peers.get(&number).map_or((None, None), |p| (p.path.map(|x| x.word()), p.rtt_ms)))
}

/// npf's state as the UI shows it (docs/npf-flutter-api.md).
pub fn state_json() -> String {
    let mut v = with(|st| {
        let info = st.info.as_ref().filter(|_| st.up);
        let assist = match st.assist.as_ref().filter(|_| st.up) {
            Some(Assist { code: Some(code), expires, .. }) => json!({"code": code, "expires": expires}),
            Some(a) => json!({"code": null, "why": a.why.as_deref().unwrap_or("offline")}),
            None => json!({"code": null, "why": "offline"}),
        };
        let resource = st.resource.filter(|_| st.up).map(|r| match r {
            ResourceState::Failed(e) => format!("failed:{}", e.word()),
            r => r.word().to_owned(),
        });
        json!({
            "link": {
                "up": st.up,
                "why": st.why.as_ref().map(|e| e.kind.word()),
                "message": st.why.as_ref().and_then(|e| e.message.clone()),
            },
            "node": info.and_then(|i| i.number).map(|n| n.to_string()),
            "name": info.map(|i| i.name.clone()),
            "online": info.map_or(false, |i| i.online),
            "account": info.map_or(false, |i| i.account),
            "version": info.map(|i| i.version.clone()),
            "resource": resource,
            "assist": assist,
            "quota": st.quota.filter(|_| st.up).map(|(u, l)| json!({"used": u, "limit": l})),
            // changes when the sharing page's state does (npf-call share/list)
            "share_rev": st.share.filter(|_| st.up).map(|r| r.to_string()),
            "peers": st.peers.values().map(peer_json).collect::<Vec<_>>(),
        })
    });
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    {
        v["incoming"] = serve::incoming_json();
    }
    #[cfg(any(target_os = "android", target_os = "ios"))]
    {
        v["incoming"] = json!([]);
    }
    v["outgoing"] = call::outgoing_json();
    v.to_string()
}

fn peer_json(p: &Peer) -> Value {
    let services: Vec<Value> = p
        .services
        .iter()
        .map(|s| {
            json!({
                "res": s.res,
                "title": s.title,
                "svc": s.svc,
                // the version both speak; null: none (an older or newer RustDesk)
                "proto": s.protos.iter().find(|x| *x == PROTO),
                "up": s.up,
                "can": s.can,
            })
        })
        .collect();
    json!({
        "number": p.number.to_string(),
        "name": p.name,
        "mine": p.mine,
        "online": p.online,
        "path": p.path.map(|x| x.word()),
        "rtt_ms": p.rtt_ms,
        "services": services,
        "until": p.until,
    })
}

/* ---- the UI's requests on the main IPC (`npf-*` configs) ---- */

/// One of npf's requests answered with JSON (the sharing page): `{"path",
/// "body"}` in, `{"ok": ANSWER}` or `{"error": WORD, "message", "detail": npf's
/// error object}` out.
pub async fn npf_call(value: String) -> Value {
    let v: Value = serde_json::from_str(&value).unwrap_or_default();
    let r = match (v["path"].as_str(), link()) {
        (Some(path), Some(l)) => l.call(path, Some(&v["body"]).filter(|b| !b.is_null())).await,
        _ => Err(Error::new(ErrorKind::Invalid)),
    };
    match r {
        Ok(a) => json!({ "ok": a }),
        Err(e) => {
            let detail = e.reply.unwrap_or_default();
            let word = detail["error"].as_str().unwrap_or(e.kind.word()).to_owned();
            json!({ "error": word, "message": detail["message"], "detail": detail })
        }
    }
}

/// `npf-state`: the state once; `npf-watch`: the state now and whenever it
/// changes (at most 4 a second) until the UI goes; `npf-assist-renew`;
/// `npf-call` {"path", "body"}: the sharing page's requests;
/// `npf-allow` {"conn_id", "allowed"}: the CM's accept; `npf-disconnect`
/// CONN_ID; `npf-connect` {"target", "conn_type"}: a RustDesk connection
/// over npf, this IPC connection its transport from then on (`call`).
#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub async fn ipc(name: &str, value: Option<String>, stream: &mut crate::ipc::Connection) {
    use crate::ipc::Data;
    let reply = |v: String| Data::Config((name.to_owned(), Some(v)));
    match name {
        "npf-state" => {
            stream.send(&reply(state_json())).await.ok();
        }
        "npf-watch" => {
            let mut last = String::new();
            loop {
                let now = state_json();
                if now != last {
                    if stream.send(&reply(now.clone())).await.is_err() {
                        break;
                    }
                    last = now;
                }
                tokio::select! {
                    r = stream.next() => if r.is_err() { break },
                    _ = tokio::time::sleep(Duration::from_millis(250)) => {}
                }
            }
        }
        "npf-assist-renew" => {
            if let Some(l) = link() {
                if let Err(e) = l.assist_renew().await {
                    log::warn!("npf: assist code not renewed: {e}");
                }
            }
        }
        "npf-connect" => call::bridge(value.unwrap_or_default(), stream).await,
        "npf-allow" => {
            let v: Value = serde_json::from_str(&value.unwrap_or_default()).unwrap_or_default();
            if let (Some(id), Some(allowed)) = (
                v["conn_id"].as_i64(),
                serde_json::from_value::<Vec<String>>(v["allowed"].clone()).ok(),
            ) {
                serve::allow(id as i32, allowed);
            }
        }
        "npf-call" => {
            let r = npf_call(value.unwrap_or_default()).await;
            stream.send(&reply(r.to_string())).await.ok();
        }
        "npf-disconnect" => {
            if let Some(id) = value.and_then(|v| v.parse().ok()) {
                serve::disconnect(id);
            }
        }
        _ => log::debug!("npf: unknown IPC request {name}"),
    }
}
