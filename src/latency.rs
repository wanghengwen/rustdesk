//! Where a video frame's time goes, told in the log every few seconds: each
//! stage's average and longest time. The controlled side: convert, encode
//! (with the hand-over to the connections). The controlling side: queue
//! (from the network to the decoder's thread), decode, show (the picture's
//! hand-over to the UI).

use hbb_common::log;
use std::time::{Duration, Instant};

const EVERY: Duration = Duration::from_secs(10);

pub struct Stages<const N: usize> {
    what: String,
    names: [&'static str; N],
    sum: [Duration; N],
    max: [Duration; N],
    frames: u32,
    /// frames not counted in the stages (the controlling side: decoded, not shown)
    skipped: u32,
    since: Instant,
}

impl<const N: usize> Stages<N> {
    pub fn new(what: String, names: [&'static str; N]) -> Self {
        Self {
            what,
            names,
            sum: [Duration::ZERO; N],
            max: [Duration::ZERO; N],
            frames: 0,
            skipped: 0,
            since: Instant::now(),
        }
    }

    /// A frame that went through no stage of its own.
    pub fn skipped(&mut self) {
        self.skipped += 1;
    }

    /// One frame's time in each stage.
    pub fn frame(&mut self, times: [Duration; N]) {
        for (i, t) in times.into_iter().enumerate() {
            self.sum[i] += t;
            self.max[i] = self.max[i].max(t);
        }
        self.frames += 1;
        let dt = self.since.elapsed();
        if dt < EVERY {
            return;
        }
        log::info!("video latency, {}: {}", self.what, self.line(dt));
        *self = Self::new(std::mem::take(&mut self.what), self.names);
    }

    fn line(&self, dt: Duration) -> String {
        let ms = |d: Duration| d.as_secs_f64() * 1000.0;
        let stages: Vec<String> = (0..N)
            .map(|i| {
                let avg = ms(self.sum[i]) / self.frames.max(1) as f64;
                format!("{} {:.1}/{:.1}", self.names[i], avg, ms(self.max[i]))
            })
            .collect();
        let skipped = match self.skipped {
            0 => String::new(),
            n => format!(" (and {n} skipped)"),
        };
        format!(
            "{} frames{skipped} in {:.1} s, ms average/longest: {}",
            self.frames,
            dt.as_secs_f64(),
            stages.join(", ")
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn line() {
        let mut s = Stages::new("display 0".to_owned(), ["decode", "show"]);
        let ms = Duration::from_millis;
        s.frame([ms(4), ms(1)]);
        s.frame([ms(8), ms(2)]);
        assert_eq!(
            s.line(ms(2500)),
            "2 frames in 2.5 s, ms average/longest: decode 6.0/8.0, show 1.5/2.0"
        );
        s.skipped();
        assert!(s.line(ms(2500)).starts_with("2 frames (and 1 skipped) in 2.5 s"));
    }
}
