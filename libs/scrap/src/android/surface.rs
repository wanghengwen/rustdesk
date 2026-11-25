//! The client's video surfaces: the Surface of a Flutter Texture
//! (MainActivity), so that frames reach the screen without Flutter decoding
//! an image per frame. H.264/H.265 on the device's MediaCodec render into it
//! themselves (hwcodec); other frames are copied in as RGBA (`render`). One
//! surface per session (its key: the Flutter session id, as the app gives
//! it), used by the session's video threads (`use_key`).
//!
//! A Surface takes one producer: once a frame is copied in, MediaCodec could
//! no longer connect, so from then on its decoders return their frames.

use crate::{ImageFormat, ImageRgb};
use jni::{
    objects::{GlobalRef, JClass, JObject, JString},
    JNIEnv,
};
use std::{
    cell::RefCell,
    collections::HashMap,
    os::raw::c_void,
    ptr::null_mut,
    sync::{Mutex, MutexGuard},
};

#[repr(C)]
struct WindowBuffer {
    width: i32,
    height: i32,
    stride: i32, // in pixels
    format: i32,
    bits: *mut c_void,
    reserved: [u32; 6],
}

const WINDOW_FORMAT_RGBA_8888: i32 = 1;

#[link(name = "android")]
extern "C" {
    fn ANativeWindow_fromSurface(
        env: *mut jni::sys::JNIEnv,
        surface: jni::sys::jobject,
    ) -> *mut c_void;
    fn ANativeWindow_release(window: *mut c_void);
    fn ANativeWindow_setBuffersGeometry(window: *mut c_void, w: i32, h: i32, format: i32) -> i32;
    fn ANativeWindow_lock(window: *mut c_void, buf: *mut WindowBuffer, dirty: *mut c_void) -> i32;
    fn ANativeWindow_unlockAndPost(window: *mut c_void) -> i32;
}

struct Surface {
    surface: GlobalRef, // what MediaCodec decoders take (hwcodec holds a raw copy)
    window: *mut c_void,
    size: (usize, usize),
    copied: bool, // a frame was copied in: MediaCodec can no longer connect
}

// the window is used under SURFACE's lock only
unsafe impl Send for Surface {}

impl Drop for Surface {
    fn drop(&mut self) {
        unsafe { ANativeWindow_release(self.window) };
    }
}

lazy_static::lazy_static! {
    static ref SURFACES: Mutex<HashMap<String, Surface>> = Default::default();
}

thread_local! {
    static KEY: RefCell<String> = RefCell::new(String::new());
}

fn surfaces() -> MutexGuard<'static, HashMap<String, Surface>> {
    SURFACES.lock().unwrap_or_else(|e| e.into_inner())
}

/// The calling thread's frames are the session `key`'s (a video thread).
pub fn use_key(key: String) {
    KEY.with(|k| *k.borrow_mut() = key);
}

/// For the calling thread's MediaCodec decoders: its session's surface (a
/// ref that keeps it), none once a frame was copied in.
pub fn codec_surface() -> Option<GlobalRef> {
    KEY.with(|k| {
        let lock = surfaces();
        let s = lock.get(k.borrow().as_str())?;
        (!s.copied).then(|| s.surface.clone())
    })
}

/// MainActivity: the session `key`'s video surface, or null when it goes.
/// Decoders that render into the old one close till their next key frame.
#[no_mangle]
pub extern "system" fn Java_ffi_FFI_setFrameSurface(
    mut env: JNIEnv,
    _class: JClass,
    key: JString,
    s: JObject,
) {
    let Ok(key) = env.get_string(&key).map(String::from) else {
        log::error!("video surface: no key");
        return;
    };
    let mut lock = surfaces();
    lock.remove(&key);
    if s.is_null() {
        log::info!("video surface off: {key}");
        return;
    }
    let Ok(global) = env.new_global_ref(&s) else {
        log::error!("video surface: no global ref");
        return;
    };
    let window = unsafe { ANativeWindow_fromSurface(env.get_raw(), s.as_raw()) };
    if window.is_null() {
        log::error!("video surface: no native window");
        return;
    }
    log::info!("video surface on: {key}");
    lock.insert(
        key,
        Surface {
            surface: global,
            window,
            size: (0, 0),
            copied: false,
        },
    );
}

/// Copies a frame (ABGR: bytes R, G, B, A) into the calling thread's session's
/// video surface; false if there is none or it would not take the frame.
pub fn render(rgb: &ImageRgb) -> bool {
    let key = KEY.with(|k| k.borrow().clone());
    let mut lock = surfaces();
    let Some(s) = lock.get_mut(&key) else {
        return false;
    };
    let (w, h) = (rgb.w, rgb.h);
    let src_stride = (w * 4 + rgb.align().max(1) - 1) & !(rgb.align().max(1) - 1);
    if !matches!(rgb.fmt(), ImageFormat::ABGR) || w == 0 || h == 0 || rgb.raw.len() < src_stride * h
    {
        return false;
    }
    s.copied = true; // its decoders let go of it (codec_surface)
    unsafe {
        if s.size != (w, h) {
            if ANativeWindow_setBuffersGeometry(s.window, w as _, h as _, WINDOW_FORMAT_RGBA_8888)
                != 0
            {
                return false;
            }
            s.size = (w, h);
        }
        let mut buf: WindowBuffer = std::mem::zeroed();
        if ANativeWindow_lock(s.window, &mut buf, null_mut()) != 0 {
            return false;
        }
        let ok = buf.width as usize == w && buf.height as usize == h && buf.stride as usize >= w;
        if ok {
            let dst = buf.bits as *mut u8;
            for y in 0..h {
                std::ptr::copy_nonoverlapping(
                    rgb.raw.as_ptr().add(y * src_stride),
                    dst.add(y * buf.stride as usize * 4),
                    w * 4,
                );
            }
        }
        ANativeWindow_unlockAndPost(s.window);
        ok
    }
}
