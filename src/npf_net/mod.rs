//! RustDesk over npf, through npf's applink interface (docs/design/applink.md
//! 7; the client is npf's Rust crate `client/applink/rust`, on tokio): npf
//! runs on its own on this machine and RustDesk is one of its apps. RustDesk
//! links no part of libnpf and makes no npf session or share code of its own.
//!
//! On a desktop only the service process (`--server`, or the portable
//! program itself) attaches to npf, as `rustdesk` (one events connection per
//! app, applink.md A9). It
//!
//! - declares the resource `desktop` (view, control, file, terminal) and
//!   answers npf's requests: each accepted service is a RustDesk connection,
//!   held to what the request's `can` grants (`serve`);
//! - makes the UI process's requests: the UI asks over RustDesk's main IPC
//!   (`npf-connect`) and that IPC connection then carries the RustDesk
//!   connection (`call`, `ui`);
//! - keeps npf's state (this device, its peers, the assist code, who is
//!   connected both ways) for the UI (`npf-state`, `npf-watch`).
//!
//! One RustDesk connection = one service of `desktop`, the request's body
//! `{"conn_type": N}`. Tags, fixed on both ends:
//!
//! | tag | stream |
//! |---|---|
//! | 0 | main channel: a remote desktop's (or camera's) control connection, RustDesk's frames |
//! | 1 | channel, prio 2: file transfer, terminal, port forward, RDP: the whole RustDesk connection |
//! | 10..17 | media: the video of display 0..7 |
//! | 18 | media: the controlled side's audio |
//! | 19 | media: the controlling side's audio (its slot) |
//! | 20 | media: the controlling side's key frame requests, one byte: the display (its slot) |
//!
//! npf encrypts and authenticates, so these connections skip RustDesk's own
//! key exchange, and those npf knows (my own devices; members the owner
//! invited to this service) are let in with no password and no click. A
//! request with the assist code (`temp`) always asks for a click.
//!
//! A phone (Android, iOS): ouDesk runs inside npf's app, in npf's process,
//! and only controls (applink.md A13). The link dials npf in-process
//! (`npf_host_app_dial`: found in npf's JNI library on Android, linked into
//! the same binary on iOS) on a runtime of its own, declares no resources,
//! and each connection's `call` runs over an in-memory pipe instead of the
//! IPC (`ui`); the controlled side's functions are `mobile`'s stubs.

mod call;
mod link;
#[cfg(target_os = "ios")]
mod pipe;
#[cfg(not(any(target_os = "android", target_os = "ios")))]
mod serve;
#[cfg(all(feature = "npf-trace", not(target_os = "ios")))]
mod trace;
mod ui;

use base::message_proto::{message, video_frame, Message, VideoFrame};
use hbb_common::{
    bytes::BytesMut,
    protobuf::{Enum as _, Message as _},
    rendezvous_proto::ConnType,
};
use std::{
    sync::Mutex,
    time::{Duration, Instant},
};

#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub use link::{ipc, start};
#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub use serve::{auto_accept, cm_info, is_npf, must_click, peer_name, permits, video_kbps};
#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub use ui::{assist_renew, call, cm_allow, connect, disconnect, state};
#[cfg(any(target_os = "android", target_os = "ios"))]
pub use ui::{assist_renew, call, connect, state};

#[cfg(any(target_os = "android", target_os = "ios"))]
pub use mobile::*;

pub const TAG_DATA: i32 = 1;
pub const TAG_VIDEO: i32 = 10;
pub const DISPLAYS: i32 = 8;
pub const TAG_AUDIO: i32 = 18;
pub const TAG_AUDIO_BACK: i32 = 19;
pub const TAG_KEY: i32 = 20;

/// a lost video frame is asked for again this often while its key frame
/// has not come (the key frame itself was lost)
const KEY_AGAIN: Duration = Duration::from_millis(500);

/// at most one key frame a display this often: a key frame is large, and
/// one that overflows the queue must not bring the next at once
const KEY_MIN: Duration = Duration::from_secs(1);

/// On a slow path a key frame takes seconds to go out, and the frames behind
/// it are lost meanwhile: each loss asked for another key frame, so the path
/// carried key frames only and no picture came (2026-11-16, a Mac on a
/// congested Wi-Fi). The next key frame waits twice what the last one took
/// on the path, at most [`KEY_MAX`] (the user 2026-11-16: "最高为5秒钟").
const KEY_MAX: Duration = Duration::from_secs(5);

/// ms the last key frame of each display takes on its path
static KEY_COST_MS: Mutex<Vec<u32>> = Mutex::new(Vec::new());

/// A key frame of `bytes` went out on a path carrying `kbps` of video.
/// (The controlled side's: phones only control.)
#[cfg_attr(any(target_os = "android", target_os = "ios"), allow(dead_code))]
pub(crate) fn key_sent(display: usize, bytes: usize, kbps: u32) {
    if kbps == 0 {
        return; // npf's figures not yet in
    }
    // kbit/s is bit/ms
    let ms = (bytes as u64 * 8 / kbps as u64).min(u32::MAX as u64) as u32;
    let mut cost = KEY_COST_MS.lock().unwrap();
    if cost.len() <= display {
        cost.resize(display + 1, 0);
    }
    cost[display] = ms;
}

fn key_min(display: usize) -> Duration {
    let ms = KEY_COST_MS.lock().unwrap().get(display).copied().unwrap_or(0);
    key_interval(ms)
}

fn key_interval(cost_ms: u32) -> Duration {
    KEY_MIN.max(Duration::from_millis(cost_ms as u64 * 2)).min(KEY_MAX)
}

/// npf is how this RustDesk reaches others and is reached.
pub fn enabled() -> bool {
    cfg!(not(any(target_os = "android", target_os = "ios")))
}

/// The ID typed is for npf: an assist or share code (`XXXX-XXXX-XXXX`), a
/// device number (9 digits with npf's check digit), or anything after
/// `npf:`. What npf's request takes: the code upper case, the number's digits.
pub fn parse_target(id: &str) -> Option<String> {
    const ABC: &str = "23456789ABCDEFGHJKMNPQRSTUVWXYZ";
    let (forced, rest) = match id.trim().strip_prefix("npf:") {
        Some(r) => (true, r.trim()),
        None => (false, id.trim()),
    };
    let code = rest.to_ascii_uppercase();
    let groups: Vec<&str> = code.split('-').collect();
    if groups.len() == 3 && groups.iter().all(|g| g.len() == 4 && g.chars().all(|c| ABC.contains(c))) {
        return Some(code);
    }
    let digits: String = rest.chars().filter(|c| *c != ' ' && *c != '-').collect();
    if is_number(&digits) || (forced && !digits.is_empty() && digits.chars().all(|c| c.is_ascii_digit())) {
        return Some(digits);
    }
    None
}

/// npf's device number: 9 digits, the last Damm's check digit
fn is_number(s: &str) -> bool {
    const DAMM: [[u8; 10]; 10] = [
        [0, 3, 1, 7, 5, 9, 8, 6, 4, 2],
        [7, 0, 9, 2, 1, 5, 4, 8, 6, 3],
        [4, 2, 0, 6, 8, 7, 1, 3, 5, 9],
        [1, 7, 5, 0, 9, 8, 3, 4, 2, 6],
        [6, 1, 2, 3, 0, 4, 5, 9, 7, 8],
        [3, 6, 7, 4, 2, 0, 9, 5, 8, 1],
        [5, 8, 6, 9, 7, 2, 0, 1, 3, 4],
        [8, 9, 4, 5, 3, 6, 2, 0, 1, 7],
        [9, 4, 3, 8, 6, 1, 7, 2, 0, 5],
        [2, 5, 8, 1, 4, 3, 6, 7, 9, 0],
    ];
    s.len() == 9
        && !s.starts_with('0')
        && s.bytes().all(|b| b.is_ascii_digit())
        && s.bytes().fold(0u8, |i, b| DAMM[i as usize][(b - b'0') as usize]) == 0
}

/// A conn type's stream: a remote desktop's (main channel and media) or a
/// byte stream on channel 1 (everything else).
pub fn is_desktop(conn_type: i32) -> bool {
    conn_type == ConnType::DEFAULT_CONN as i32 || conn_type == ConnType::VIEW_CAMERA as i32
}

/// What the request's `can` must have for the conn type (applink.md 7:
/// port forwards and RDP need control, whoever may control this computer
/// could open them anyway), or None: not over npf.
pub fn needs(conn_type: i32) -> Option<&'static str> {
    use ConnType::*;
    Some(match ConnType::from_i32(conn_type)? {
        DEFAULT_CONN | VIEW_CAMERA => "view",
        FILE_TRANSFER => "file",
        TERMINAL => "terminal",
        PORT_FORWARD | RDP => "control",
    })
}

/// The message a failed connection shows: `npf:KIND[:ARG]`, the UI's texts
/// (flutter/lib/npf, docs/npf-flutter-api.md). applink's words go to the
/// UI's kinds; the others stay as they are (`npf:no_npf`, `npf:no_path`).
pub fn error_text(word: &str, arg: Option<&str>) -> String {
    let kind = match word {
        "refused" => "rejected",
        "not_found" | "forbidden" | "not_paired" | "no_permission" => "not_shared",
        "no_relay" => "need_login",
        w => w,
    };
    match arg {
        Some(a) => format!("npf:{kind}:{a}"),
        None => format!("npf:{kind}"),
    }
}

/// The frame starts afresh: a key frame (or a raw picture).
pub fn is_key(vf: &VideoFrame) -> bool {
    use video_frame::Union::*;
    match &vf.union {
        Some(Vp9s(f)) | Some(H264s(f)) | Some(H265s(f)) | Some(Vp8s(f)) | Some(Av1s(f)) => {
            f.frames.iter().any(|x| x.key)
        }
        // raw pictures stand alone
        _ => true,
    }
}

/// A key frame for the display, at most one asked for every [`KEY_MIN`] (more on a slow path, [`key_sent`]): a
/// lost frame is reported by every receiver and again while its key frame is
/// on the way.
pub fn request_keyframe_rate_limited(display: usize) {
    static LAST: Mutex<Vec<Option<Instant>>> = Mutex::new(Vec::new());
    let mut last = LAST.lock().unwrap();
    if last.len() <= display {
        last.resize(display + 1, None);
    }
    if last[display].map_or(false, |t| t.elapsed() < key_min(display)) {
        return;
    }
    last[display] = Some(Instant::now());
    drop(last);
    #[cfg(all(feature = "npf-trace", not(any(target_os = "android", target_os = "ios"))))]
    trace::key_asked(display);
    #[cfg(not(target_os = "ios"))]
    crate::server::video_service::request_keyframe(display);
}

/// The audio frame with the loss before it written in (Opus FEC rebuilds
/// the lost frame from it).
pub fn audio_with_loss(frame: &[u8], lost: u32) -> BytesMut {
    if lost == 0 {
        return BytesMut::from(frame);
    }
    match Message::parse_from_bytes(frame) {
        Ok(mut msg) => {
            if let Some(message::Union::AudioFrame(a)) = &mut msg.union {
                a.lost_before = lost;
            }
            msg.write_to_bytes()
                .map(|v| BytesMut::from(&v[..]))
                .unwrap_or_else(|_| BytesMut::from(frame))
        }
        Err(_) => BytesMut::from(frame),
    }
}

/// A received video stream: a lost frame breaks those after it up to the
/// next key frame, which are dropped here while one is asked for.
#[derive(Default)]
pub struct KeyWait {
    need: bool,
    asked: Option<Instant>,
}

impl KeyWait {
    /// Some(ask): the frame is dropped, and when `ask` a key frame is to be
    /// asked for now.
    pub fn frame(&mut self, key: bool, lost_before: u32) -> Option<bool> {
        if key {
            *self = Self::default();
            return None;
        }
        self.need |= lost_before > 0;
        if !self.need {
            return None;
        }
        let ask = self.asked.map_or(true, |t| t.elapsed() >= KEY_AGAIN);
        if ask {
            self.asked = Some(Instant::now());
        }
        Some(ask)
    }

    /// this frame was dropped here (no room): the next ones wait for a key frame
    pub fn lost(&mut self) {
        self.need = true;
    }
}

#[cfg(any(target_os = "android", target_os = "ios"))]
mod mobile {
    use hbb_common::Stream;

    #[cfg(target_os = "android")]
    pub async fn start(_server: crate::server::ServerPtr) {}
    pub fn video_kbps(_stream: &Stream) -> Option<u32> {
        None
    }
    pub fn is_npf(_ip: &str) -> bool {
        false
    }
    pub fn must_click(_ip: &str) -> bool {
        false
    }
    pub fn auto_accept(_ip: &str) -> bool {
        false
    }
    pub fn cm_info(_ip: &str, _conn_id: i32, _authorized: bool) -> Option<serde_json::Value> {
        None
    }
    pub fn permits(_ip: &str, _name: &str, _enabled: bool) -> bool {
        true
    }
    pub fn disconnect(_conn_id: i32) {}
    pub fn cm_allow(conn_id: i32, _allowed: Vec<String>) {
        #[cfg(not(target_os = "ios"))]
        crate::ui_cm_interface::authorize(conn_id);
        let _ = conn_id;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn targets() {
        assert_eq!(parse_target("k7q2-abcd-efgh"), Some("K7Q2-ABCD-EFGH".into()));
        assert_eq!(parse_target("npf:K7Q2-ABCD-EFGH"), Some("K7Q2-ABCD-EFGH".into()));
        assert_eq!(parse_target("123456786"), Some("123456786".into()));
        assert_eq!(parse_target("123 456 786"), Some("123456786".into()));
        assert_eq!(parse_target("npf:12"), Some("12".into()));
        // a wrong check digit: a RustDesk ID
        assert_eq!(parse_target("123456787"), None);
        for bad in ["K7Q2ABCDEFGH", "K7Q2-ABCD-EFG", "K7Q0-ABCD-EFGH", "K7QI-ABCD-EFGH", "1.2.3.4", "abc"] {
            assert_eq!(parse_target(bad), None, "{bad}");
        }
    }

    #[test]
    fn key_interval_follows_the_path() {
        // a fast path: the floor
        assert_eq!(key_interval(0), KEY_MIN);
        assert_eq!(key_interval(300), KEY_MIN);
        // 50 KB at 200 kbit/s: 2 s on the path, the next no sooner than 4 s
        key_sent(3, 50_000, 200);
        assert_eq!(key_min(3), Duration::from_millis(4000));
        // no figures yet: what was known stays
        key_sent(3, 10, 0);
        assert_eq!(key_min(3), Duration::from_millis(4000));
        // a very slow path: at most KEY_MAX
        key_sent(3, 500_000, 100);
        assert_eq!(key_min(3), KEY_MAX);
        assert_eq!(key_min(9), KEY_MIN);
    }

    #[test]
    fn key_wait() {
        let mut k = KeyWait::default();
        assert_eq!(k.frame(false, 0), None);
        assert_eq!(k.frame(false, 1), Some(true));
        assert_eq!(k.frame(false, 0), Some(false));
        assert_eq!(k.frame(true, 0), None);
        assert_eq!(k.frame(false, 0), None);
    }
}
