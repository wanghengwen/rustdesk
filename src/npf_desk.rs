//! The session methods npf's apps without Flutter call (Android: npf_jni,
//! iOS: npf_ios), by Flutter's names without `session_`.
use crate::flutter_ffi::{self, SessionID};
use hbb_common::log;
use serde_json::Value;

fn s(a: &Value, k: &str) -> String {
    match a.get(k) {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Null) | None => String::new(),
        Some(v) => v.to_string(),
    }
}

fn b(a: &Value, k: &str) -> bool {
    match a.get(k) {
        Some(Value::Bool(b)) => *b,
        Some(Value::String(s)) => s == "Y" || s == "true",
        Some(Value::Number(n)) => n.as_i64().unwrap_or(0) != 0,
        _ => false,
    }
}

fn i(a: &Value, k: &str) -> i64 {
    match a.get(k) {
        Some(Value::Number(n)) => n.as_i64().unwrap_or(0),
        Some(Value::String(s)) => s.parse().unwrap_or(0),
        _ => 0,
    }
}

fn yes(v: bool) -> String {
    if v { "Y" } else { "" }.to_owned()
}

/// The session's methods the page uses (Flutter's names, without
/// `session_`), answered as text ("" when there is nothing to say).
pub fn call(sid: SessionID, method: &str, raw: &str, a: &Value) -> String {
    use flutter_ffi as f;
    match method {
        "close" => f::session_close(sid),
        "reconnect" => f::session_reconnect(sid, b(a, "force_relay")),
        "login" => f::session_login(sid, String::new(), String::new(), s(a, "password"), b(a, "remember")),
        "send2fa" => f::session_send2fa(sid, s(a, "code"), b(a, "trust")),
        "get_remember" => return yes(f::session_get_remember(sid) == Some(true)),
        "set_common" => f::session_set_common(sid, s(a, "key"), s(a, "value")),
        "npf_background" => f::session_npf_background(sid, b(a, "on")),
        "refresh" => f::session_refresh(sid, i(a, "display") as usize),
        "switch_display" => f::session_switch_display(false, sid, vec![i(a, "display") as i32]),
        "get_image_quality" => return f::session_get_image_quality(sid).unwrap_or_default(),
        "set_image_quality" => f::session_set_image_quality(sid, s(a, "value")),
        "get_custom_image_quality" => {
            return serde_json::to_string(&f::session_get_custom_image_quality(sid).unwrap_or_default())
                .unwrap_or_default()
        }
        "set_custom_image_quality" => f::session_set_custom_image_quality(sid, i(a, "value") as i32),
        "set_custom_fps" => f::session_set_custom_fps(sid, i(a, "fps") as i32),
        "get_toggle_option" => return yes(f::session_get_toggle_option(sid, s(a, "name")) == Some(true)),
        "toggle_option" => f::session_toggle_option(sid, s(a, "name")),
        "get_option" => return f::session_get_peer_option(sid, s(a, "name")),
        "set_option" => f::session_peer_option(sid, s(a, "name"), s(a, "value")),
        "ctrl_alt_del" => f::session_ctrl_alt_del(sid),
        "lock_screen" => f::session_lock_screen(sid),
        "input_os_password" => f::session_input_os_password(sid, s(a, "value")),
        "input_key" => f::session_input_key(
            sid,
            s(a, "name"),
            b(a, "down"),
            b(a, "press"),
            b(a, "alt"),
            b(a, "ctrl"),
            b(a, "shift"),
            b(a, "command"),
        ),
        "input_string" => f::session_input_string(sid, s(a, "value")),
        // the message as Flutter's (JSON of strings): passed on as it is
        "send_mouse" => f::session_send_mouse(sid, raw.to_owned()),
        "send_pointer" => f::session_send_pointer(sid, raw.to_owned()),
        "request_voice_call" => f::session_request_voice_call(sid),
        "close_voice_call" => f::session_close_voice_call(sid),
        "waiting_for_image_shown" => f::session_on_waiting_for_image_dialog_show(sid),
        "record_screen" => f::session_record_screen(sid, b(a, "start")),
        // an Android peer's volume and power keys (RustDesk's tapHidKey): a USB HID usage, down or up
        "hid_key" => {
            f::session_handle_flutter_key_event(sid, "flutter_key".to_owned(), i(a, "usage") as i32, 0, b(a, "down"))
        }
        "restart_remote_device" => f::session_restart_remote_device(sid),
        "toggle_privacy_mode" => f::session_toggle_privacy_mode(sid, s(a, "impl_key"), b(a, "on")),
        "toggle_virtual_display" => f::session_toggle_virtual_display(sid, i(a, "index") as i32, b(a, "on")),
        "change_resolution" => {
            f::session_change_resolution(sid, i(a, "display") as i32, i(a, "width") as i32, i(a, "height") as i32)
        }
        // {"vp8":bool,"av1":bool,"h264":bool,"h265":bool}: what both sides can do besides VP9
        "alternative_codecs" => return f::session_alternative_codecs(sid),
        // after set_option codec-preference (or the i444 toggle): told to the peer
        "change_prefer_codec" => f::session_change_prefer_codec(sid),
        _ => log::warn!("npf_desk: no method {method}"),
    }
    String::new()
}
