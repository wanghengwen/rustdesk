//! ouDesk's controlling side for npf's iOS app without Flutter: its Swift
//! (npf's client/ios/OuDesk, header npf_desk.h there) drives the same sessions
//! Flutter's Dart drives through flutter_ffi, as npf_jni does for Android.
//!
//! - `npf_desk_init(app_dir, home_dir, device_name, device_id)`: once a
//!   process (flutter_ffi::main_init), before the first session.
//! - `npf_desk_open(session_id, peer, password, ctx, event, cursor, frame)`: a
//!   remote desktop session added and started; "" or why not (free it with
//!   `npf_desk_free`). On the session's threads, with `ctx`:
//!     `event(json)`      the events Flutter gets ({"name": ...}), and "close"
//!                        when the session's stream ends: the last call with ctx
//!     `cursor(id, hotx, hoty, width, height, rgba, len)`
//!     `frame(display, bgra, width, height, stride)` each picture, its bytes
//!                        valid during the call only
//!   The callbacks must not call npf_desk_* themselves (they hold the sessions'
//!   lock, so that none runs after "close"): they hand over to another thread.
//! - `npf_desk_call(session_id, method, args_json)`: everything else the page
//!   asks of its session (npf_desk::call), its answer freed with `npf_desk_free`.
//! - A voice call (RustDesk has no microphone on iOS: its audio service is not
//!   built): Swift records, with the system's echo canceller, from
//!   "on_voice_call_started" to "on_voice_call_closed".
//!     `npf_desk_voice_in(session_id, pcm, frames)` 48 kHz mono float, 960
//!                        frames at a time: Opus to the peer
//!     `npf_desk_voice_end(session_id)` the microphone off (the next call's
//!                        frames begin with their format again)
//!     `npf_desk_voice_out(ctx, out)` while a call is on, the peer's sound goes
//!                        to `out(ctx, pcm, frames, rate, channels)` (interleaved
//!                        float, on the audio thread) and not to cpal: played by
//!                        Swift where its echo canceller hears it; null: cpal again
use crate::{
    flutter::{self, UiStream},
    flutter_ffi::{self, EventToUI, SessionID},
};
use hbb_common::log;
use scrap::{ImageFormat, ImageRgb};
use serde_json::Value;
use std::{
    collections::HashMap,
    ffi::{c_char, c_int, c_void, CStr, CString},
    sync::{
        atomic::{AtomicUsize, Ordering},
        Mutex, MutexGuard, OnceLock,
    },
};

pub type EventFn = extern "C" fn(ctx: *mut c_void, json: *const c_char);
pub type CursorFn = extern "C" fn(
    ctx: *mut c_void,
    id: *const c_char,
    hotx: c_int,
    hoty: c_int,
    width: c_int,
    height: c_int,
    rgba: *const u8,
    len: usize,
);
pub type FrameFn = extern "C" fn(
    ctx: *mut c_void,
    display: c_int,
    bgra: *const u8,
    width: c_int,
    height: c_int,
    stride: c_int,
);

#[derive(Clone, Copy)]
struct Sink {
    ctx: usize,
    event: EventFn,
    cursor: CursorFn,
    frame: FrameFn,
}

static SINKS: OnceLock<Mutex<HashMap<SessionID, Sink>>> = OnceLock::new();
static INIT: OnceLock<()> = OnceLock::new();

fn sinks() -> MutexGuard<'static, HashMap<SessionID, Sink>> {
    SINKS
        .get_or_init(Default::default)
        .lock()
        .unwrap_or_else(|e| e.into_inner())
}

fn string(p: *const c_char) -> String {
    if p.is_null() {
        return String::new();
    }
    unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned()
}

fn out(s: &str) -> *mut c_char {
    CString::new(s.replace('\0', ""))
        .map(CString::into_raw)
        .unwrap_or(std::ptr::null_mut())
}

#[no_mangle]
pub extern "C" fn npf_desk_init(
    app_dir: *const c_char,
    home_dir: *const c_char,
    device_name: *const c_char,
    device_id: *const c_char,
) {
    let (app_dir, home_dir) = (string(app_dir), string(home_dir));
    let (name, id) = (string(device_name), string(device_id));
    INIT.get_or_init(|| {
        flutter_ffi::main_device_id(id);
        flutter_ffi::main_device_name(name);
        flutter_ffi::main_set_home_dir(home_dir);
        flutter_ffi::main_init(app_dir, String::new());
    });
}

#[no_mangle]
pub extern "C" fn npf_desk_free(s: *mut c_char) {
    if !s.is_null() {
        drop(unsafe { CString::from_raw(s) });
    }
}

/// Tells the session's Swift of one event; false when it is gone.
fn tell(sid: &SessionID, event: EventToUI) -> bool {
    let mut m = sinks();
    let Some(sink) = m.get(sid).copied() else {
        return false;
    };
    let ctx = sink.ctx as *mut c_void;
    match event {
        EventToUI::Event(s) => {
            let close = s == "close";
            if let Ok(c) = CString::new(s) {
                (sink.event)(ctx, c.as_ptr());
            }
            if close {
                m.remove(sid);
            }
        }
        EventToUI::Cursor {
            id,
            hotx,
            hoty,
            width,
            height,
            colors,
        } => {
            let id = CString::new(id).unwrap_or_default();
            (sink.cursor)(ctx, id.as_ptr(), hotx, hoty, width, height, colors.as_ptr(), colors.len());
        }
        // a frame the hook did not take: given back, so the next one comes
        EventToUI::Rgba(display) => {
            drop(m);
            flutter::session_next_rgba(*sid, display);
        }
        EventToUI::Texture(..) => {}
    }
    true
}

/// The session's picture to its Swift (flutter.rs, on_rgba on iOS); false when
/// it takes no frames (then the soft renderer's way, as for Flutter).
pub fn frame(sid: &SessionID, display: usize, rgb: &ImageRgb) -> bool {
    let m = sinks();
    let Some(sink) = m.get(sid) else {
        return false;
    };
    let (w, h) = (rgb.w, rgb.h);
    let align = rgb.align().max(1);
    let stride = (w * 4 + align - 1) / align * align;
    if !matches!(rgb.fmt(), ImageFormat::ARGB) || w == 0 || h == 0 || rgb.raw.len() < stride * h {
        hbb_common::throttled_log!(
            std::time::Duration::from_secs(60),
            warn,
            "npf_ios: a frame not shown: {:?} {w}x{h}, {} bytes",
            rgb.fmt(),
            rgb.raw.len()
        );
        return true;
    }
    (sink.frame)(
        sink.ctx as *mut c_void,
        display as c_int,
        rgb.raw.as_ptr(),
        w as c_int,
        h as c_int,
        stride as c_int,
    );
    true
}

#[no_mangle]
pub extern "C" fn npf_desk_open(
    session_id: *const c_char,
    peer: *const c_char,
    password: *const c_char,
    ctx: *mut c_void,
    event: EventFn,
    cursor: CursorFn,
    frame: FrameFn,
) -> *mut c_char {
    let Ok(sid) = SessionID::parse_str(&string(session_id)) else {
        return out("bad session id");
    };
    let peer = string(peer).trim().to_owned();
    if peer.is_empty() {
        return out("no peer");
    }
    if INIT.get().is_none() {
        return out("npf_desk_init first");
    }
    let added = flutter_ffi::session_add_sync(
        sid,
        peer.clone(),
        false,
        false,
        false,
        false,
        false,
        String::new(),
        false,
        string(password),
        false,
        None,
        String::new(),
    )
    .0;
    if !added.is_empty() {
        return out(&added);
    }
    sinks().insert(
        sid,
        Sink {
            ctx: ctx as usize,
            event,
            cursor,
            frame,
        },
    );
    let stream = UiStream::Native(Box::new(move |e| tell(&sid, e)));
    if let Err(e) = flutter::session_start_(&sid, &peer, stream) {
        sinks().remove(&sid);
        flutter_ffi::session_close(sid);
        log::error!("npf_ios: {peer} not started: {e}");
        return out(&e.to_string());
    }
    out("")
}

#[no_mangle]
pub extern "C" fn npf_desk_call(
    session_id: *const c_char,
    method: *const c_char,
    args: *const c_char,
) -> *mut c_char {
    let (method, args) = (string(method), string(args));
    let answer = match SessionID::parse_str(&string(session_id)) {
        Ok(sid) => {
            let a: Value = serde_json::from_str(&args).unwrap_or(Value::Null);
            crate::npf_desk::call(sid, &method, &args, &a)
        }
        Err(_) => String::new(),
    };
    out(&answer)
}

/// RustDesk's text in a language (its translations; locale as "zh-Hans-CN")
#[no_mangle]
pub extern "C" fn npf_desk_translate(locale: *const c_char, text: *const c_char) -> *mut c_char {
    out(&crate::client::translate_locale(string(text), &string(locale)))
}

// The voice call

pub type VoiceOutFn = extern "C" fn(
    ctx: *mut c_void,
    pcm: *const f32,
    frames: c_int,
    rate: c_int,
    channels: c_int,
);

/// The voice calls going on (io_loop: from the peer's yes to the call's end).
static CALLS: AtomicUsize = AtomicUsize::new(0);
static VOICE_OUT: Mutex<Option<(usize, VoiceOutFn)>> = Mutex::new(None);
/// each calling session's encoder, made with its first frame
static ENCODERS: OnceLock<Mutex<HashMap<SessionID, magnum_opus::Encoder>>> = OnceLock::new();

const VOICE_RATE: u32 = 48_000;
/// 20 ms
const VOICE_FRAMES: usize = 960;

pub(crate) fn call_started() {
    CALLS.fetch_add(1, Ordering::AcqRel);
}

pub(crate) fn call_ended() {
    let _ = CALLS.fetch_update(Ordering::AcqRel, Ordering::Acquire, |n| n.checked_sub(1));
}

/// The peer's sound is Swift's: a call is on and Swift plays it.
pub(crate) fn voice_playing() -> bool {
    CALLS.load(Ordering::Acquire) > 0
        && VOICE_OUT.lock().unwrap_or_else(|e| e.into_inner()).is_some()
}

/// The peer's sound decoded (interleaved), to Swift.
pub(crate) fn voice_out(pcm: &[f32], rate: u32, channels: u16) {
    let out = *VOICE_OUT.lock().unwrap_or_else(|e| e.into_inner());
    if let Some((ctx, f)) = out {
        let frames = pcm.len() / channels.max(1) as usize;
        f(ctx as *mut c_void, pcm.as_ptr(), frames as c_int, rate as c_int, channels as c_int);
    }
}

#[no_mangle]
pub extern "C" fn npf_desk_voice_out(ctx: *mut c_void, out: Option<VoiceOutFn>) {
    *VOICE_OUT.lock().unwrap_or_else(|e| e.into_inner()) = out.map(|f| (ctx as usize, f));
}

fn encoders() -> MutexGuard<'static, HashMap<SessionID, magnum_opus::Encoder>> {
    ENCODERS
        .get_or_init(Default::default)
        .lock()
        .unwrap_or_else(|e| e.into_inner())
}

fn send_voice(sid: &SessionID, msg: base::message_proto::Message) {
    use crate::client::{Data, Interface};
    if let Some(s) = flutter::sessions::get_session_by_session_id(sid) {
        s.send(Data::Message(msg));
    }
}

#[no_mangle]
pub extern "C" fn npf_desk_voice_in(session_id: *const c_char, pcm: *const f32, frames: c_int) {
    use base::message_proto::{AudioFormat, AudioFrame, Message, Misc};
    if pcm.is_null() || frames as usize != VOICE_FRAMES {
        return;
    }
    let Ok(sid) = SessionID::parse_str(&string(session_id)) else {
        return;
    };
    let data = unsafe { std::slice::from_raw_parts(pcm, VOICE_FRAMES) };
    let mut m = encoders();
    if !m.contains_key(&sid) {
        // as RustDesk's audio service: Audio (with FEC) over npf, LowDelay otherwise
        let npf = crate::npf_net::enabled();
        let app = if npf {
            magnum_opus::Application::Audio
        } else {
            magnum_opus::Application::LowDelay
        };
        let mut e = match magnum_opus::Encoder::new(VOICE_RATE, magnum_opus::Channels::Mono, app) {
            Ok(e) => e,
            Err(e) => {
                log::error!("npf_ios: no voice encoder: {e:?}");
                return;
            }
        };
        if npf {
            e.set_inband_fec(true).ok();
            e.set_packet_loss_perc(10).ok();
        }
        m.insert(sid, e);
        let mut misc = Misc::new();
        misc.set_audio_format(AudioFormat {
            sample_rate: VOICE_RATE,
            channels: 1,
            ..Default::default()
        });
        let mut msg = Message::new();
        msg.set_misc(misc);
        send_voice(&sid, msg);
    }
    let Some(e) = m.get_mut(&sid) else {
        return;
    };
    match e.encode_vec_float(data, VOICE_FRAMES * 6) {
        Ok(bytes) => {
            drop(m);
            let mut msg = Message::new();
            msg.set_audio_frame(AudioFrame {
                data: bytes.into(),
                ..Default::default()
            });
            send_voice(&sid, msg);
        }
        Err(err) => hbb_common::throttled_log!(
            std::time::Duration::from_secs(60),
            warn,
            "npf_ios: a voice frame not encoded: {err:?}"
        ),
    }
}

#[no_mangle]
pub extern "C" fn npf_desk_voice_end(session_id: *const c_char) {
    if let Ok(sid) = SessionID::parse_str(&string(session_id)) {
        encoders().remove(&sid);
    }
}
