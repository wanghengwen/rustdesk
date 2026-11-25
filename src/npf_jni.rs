//! ouDesk's controlling side for npf's Android app without Flutter: its
//! Kotlin (ffi.FFI's desk* functions, npf's client/android/oudesk) drives the
//! same sessions Flutter's Dart drives through flutter_ffi, and hears their
//! events by a listener object instead of a Dart stream.
//!
//! - `deskInit(appDir, homeDir, deviceName, deviceId)`: once a process
//!   (flutter_ffi::main_init), before the first session.
//! - `deskOpen(sessionId, peer, password, listener) -> String`: a remote
//!   desktop session added and started; "" or why not. The listener
//!   (com.luopingtech.npf.DeskEvents) hears, on the session's threads:
//!     `onEvent(String)`   the events Flutter gets as JSON ({"name": ...}), and
//!                         "close" when the session's stream ends
//!     `onCursor(String id, int hotx, int hoty, int width, int height, byte[] rgba)`
//! - `deskCall(sessionId, method, argsJson) -> String`: everything else the
//!   page asks of its session (see `call`).
//!
//! The picture is not an event: it goes to the session's surface
//! (ffi.FFI.setFrameSurface, key: the session id) as with Flutter; frames
//! that reach no surface are dropped.
use crate::{
    flutter::{self, UiStream},
    flutter_ffi::{self, EventToUI, SessionID},
};
use hbb_common::log;
use jni::{
    objects::{GlobalRef, JClass, JObject, JString, JValue},
    sys::jstring,
    JNIEnv, JavaVM,
};
use serde_json::Value;
use std::sync::OnceLock;

static VM: OnceLock<JavaVM> = OnceLock::new();

fn string(env: &mut JNIEnv, s: &JString) -> String {
    if s.is_null() {
        return String::new();
    }
    env.get_string(s).map(|s| s.into()).unwrap_or_default()
}

fn jstr(env: &mut JNIEnv, s: &str) -> jstring {
    env.new_string(s)
        .map(|s| s.into_raw())
        .unwrap_or(std::ptr::null_mut())
}

fn parse_sid(s: &str) -> Option<SessionID> {
    SessionID::parse_str(s).ok()
}

#[no_mangle]
pub extern "system" fn Java_ffi_FFI_deskInit(
    mut env: JNIEnv,
    _class: JClass,
    app_dir: JString,
    home_dir: JString,
    device_name: JString,
    device_id: JString,
) {
    if let Ok(vm) = env.get_java_vm() {
        let _ = VM.set(vm);
    }
    let app_dir = string(&mut env, &app_dir);
    let home_dir = string(&mut env, &home_dir);
    let name = string(&mut env, &device_name);
    let id = string(&mut env, &device_id);
    flutter_ffi::main_device_id(id);
    flutter_ffi::main_device_name(name);
    flutter_ffi::main_set_home_dir(home_dir);
    flutter_ffi::main_init(app_dir, String::new());
}

/// Tells the listener of one event; false when Java is not there.
fn tell(listener: &GlobalRef, sid: &SessionID, event: EventToUI) -> bool {
    let Some(vm) = VM.get() else {
        return false;
    };
    // the session's threads stay attached (they are few, and an attach a
    // frame would cost more); their local references go with the frame
    let Ok(mut env) = vm.attach_current_thread_permanently() else {
        return false;
    };
    let r = env.with_local_frame(8, |env| -> jni::errors::Result<()> {
        match event {
            EventToUI::Event(s) => {
                let s = env.new_string(s)?;
                env.call_method(
                    listener.as_obj(),
                    "onEvent",
                    "(Ljava/lang/String;)V",
                    &[JValue::Object(&s)],
                )?;
            }
            EventToUI::Cursor {
                id,
                hotx,
                hoty,
                width,
                height,
                colors,
            } => {
                let id = env.new_string(id)?;
                let rgba = env.byte_array_from_slice(&colors)?;
                env.call_method(
                    listener.as_obj(),
                    "onCursor",
                    "(Ljava/lang/String;IIII[B)V",
                    &[
                        JValue::Object(&id),
                        JValue::Int(hotx),
                        JValue::Int(hoty),
                        JValue::Int(width),
                        JValue::Int(height),
                        JValue::Object(&rgba),
                    ],
                )?;
            }
            // a frame no surface took: given back, so the next one comes
            EventToUI::Rgba(display) => {
                flutter::session_next_rgba(*sid, display);
            }
            EventToUI::Texture(..) => {}
        }
        Ok(())
    });
    if let Err(e) = r {
        log::error!("npf_jni: the listener failed: {e}");
        if env.exception_check().unwrap_or(false) {
            let _ = env.exception_describe();
            let _ = env.exception_clear();
        }
        return false;
    }
    true
}

#[no_mangle]
pub extern "system" fn Java_ffi_FFI_deskOpen(
    mut env: JNIEnv,
    _class: JClass,
    session_id: JString,
    peer: JString,
    password: JString,
    listener: JObject,
) -> jstring {
    let sid_text = string(&mut env, &session_id);
    let peer = string(&mut env, &peer).trim().to_owned();
    let password = string(&mut env, &password);
    let Some(sid) = parse_sid(&sid_text) else {
        return jstr(&mut env, "bad session id");
    };
    if peer.is_empty() {
        return jstr(&mut env, "no peer");
    }
    if VM.get().is_none() {
        return jstr(&mut env, "deskInit first");
    }
    let listener = match env.new_global_ref(&listener) {
        Ok(l) => l,
        Err(e) => return jstr(&mut env, &format!("no listener: {e}")),
    };
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
        password,
        false,
        None,
        String::new(),
    )
    .0;
    if !added.is_empty() {
        return jstr(&mut env, &added);
    }
    let stream = UiStream::Native(Box::new(move |e| tell(&listener, &sid, e)));
    if let Err(e) = flutter::session_start_(&sid, &peer, stream) {
        flutter_ffi::session_close(sid);
        return jstr(&mut env, &e.to_string());
    }
    jstr(&mut env, "")
}

#[no_mangle]
pub extern "system" fn Java_ffi_FFI_deskCall(
    mut env: JNIEnv,
    _class: JClass,
    session_id: JString,
    method: JString,
    args: JString,
) -> jstring {
    let sid = string(&mut env, &session_id);
    let method = string(&mut env, &method);
    let args = string(&mut env, &args);
    let out = match parse_sid(&sid) {
        Some(sid) => {
            let a: Value = serde_json::from_str(&args).unwrap_or(Value::Null);
            crate::npf_desk::call(sid, &method, &args, &a)
        }
        None => String::new(),
    };
    jstr(&mut env, &out)
}
