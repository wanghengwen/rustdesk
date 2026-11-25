//! `npf-trace` builds (debugging): once a second, each video stream's frames
//! as RustDesk hands them to npf or gets them back, beside libnpf's own
//! AnLiu lines. A stream is known by its service's number and its display
//! (`service << 5 | display`).

use hbb_common::log;
use std::{
    collections::HashMap,
    sync::Mutex,
    time::{Duration, Instant},
};

#[derive(Default)]
struct Count {
    frames: u32,
    keys: u32,
    bytes: u64,
    max: usize,
    /// sending: refused, npf's queue full; receiving: frames lost before
    busy_or_lost: u32,
    /// receiving: dropped here waiting for a key frame
    skipped: u32,
    key_asks: u32,
}

struct Line {
    since: Instant,
    n: Count,
}

static LINES: Mutex<Option<HashMap<(bool, u32), Line>>> = Mutex::new(None);

fn add(out: bool, m: u32, f: impl FnOnce(&mut Count)) -> Option<(Duration, Count)> {
    let mut g = LINES.lock().unwrap();
    let line = g.get_or_insert_with(HashMap::new).entry((out, m)).or_insert_with(|| Line {
        since: Instant::now(),
        n: Count::default(),
    });
    f(&mut line.n);
    let dt = line.since.elapsed();
    if dt < Duration::from_secs(1) {
        return None;
    }
    line.since = Instant::now();
    Some((dt, std::mem::take(&mut line.n)))
}

fn kbps(bytes: u64, dt: Duration) -> u64 {
    bytes * 8 / dt.as_millis().max(1) as u64
}

/// a video frame handed to npf (`busy`: refused, the queue full)
pub fn sent(m: u32, display: i32, key: bool, len: usize, busy: bool, target_kbps: u32) {
    if let Some((dt, n)) = add(true, m, |n| {
        n.frames += 1;
        n.keys += key as u32;
        n.bytes += len as u64;
        n.max = n.max.max(len);
        n.busy_or_lost += busy as u32;
    }) {
        log::info!(
            "npf trace: video out media {} display {display}: {} frames ({} key) in {} ms, {} kbit/s, largest {} B, refused {} | npf target {target_kbps} kbit/s",
            m, n.frames, n.keys, dt.as_millis(), kbps(n.bytes, dt), n.max, n.busy_or_lost
        );
    }
}

/// a video frame from npf: `lost` frames lost before it, `skipped` dropped
/// here (waiting for a key frame), `asked` a key frame asked for
pub fn received(m: u32, key: bool, len: usize, lost: u32, skipped: bool, asked: bool) {
    if let Some((dt, n)) = add(false, m, |n| {
        n.frames += 1;
        n.keys += key as u32;
        n.bytes += len as u64;
        n.max = n.max.max(len);
        n.busy_or_lost += lost;
        n.skipped += skipped as u32;
        n.key_asks += asked as u32;
    }) {
        log::info!(
            "npf trace: video in media {}: {} frames ({} key) in {} ms, {} kbit/s, largest {} B, lost {}, skipped {}, key frames asked {}",
            m, n.frames, n.keys, dt.as_millis(), kbps(n.bytes, dt), n.max, n.busy_or_lost, n.skipped, n.key_asks
        );
    }
}

/// a key frame asked of the encoder (past the rate limit)
pub fn key_asked(display: usize) {
    log::info!("npf trace: key frame asked for display {display}");
}

/// the media stream is gone
pub fn forget(m: u32) {
    if let Some(t) = LINES.lock().unwrap().as_mut() {
        t.remove(&(true, m));
        t.remove(&(false, m));
    }
}
