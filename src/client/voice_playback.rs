//! Android: while a voice call is on, the peer's sound is played as a call's
//! (oboe, usage VoiceCommunication), not as media (cpal's oboe host opens its
//! streams with oboe's default usage, Media). The phone's echo canceller only
//! hears what is played as a call: played as media, the peer's sound reaches
//! the phone's microphone and goes back to the peer as an echo.
//! Android closes a stream (this one or cpal's) when its sound goes to another
//! device: the call's mode turns the speaker on just after the call starts and
//! off after it ends, a headset is plugged in or out. The stream is opened
//! again on the next frame.

use super::{
    audio_playback::{AudioPlaybackConfig, AudioPlaybackWriter},
    create_audio_resampler, AudioHandler,
};
use base::message_proto::AudioFormat;
use cpal::traits::StreamTrait;
use hbb_common::{anyhow::anyhow, log, ResultType};
use oboe::{AudioOutputCallback, AudioOutputStreamSafe, AudioStream, AudioOutputStream};
use std::{
    cell::RefCell,
    sync::{
        atomic::{AtomicBool, AtomicUsize, Ordering},
        Arc,
    },
};

/// The voice calls going on (a session's call, from its start to its end).
static CALLS: AtomicUsize = AtomicUsize::new(0);

const RATE: u32 = 48_000;

pub(super) fn call_started() {
    CALLS.fetch_add(1, Ordering::AcqRel);
}

pub(super) fn call_ended() {
    let _ = CALLS.fetch_update(Ordering::AcqRel, Ordering::Acquire, |n| n.checked_sub(1));
}

fn in_call() -> bool {
    CALLS.load(Ordering::Acquire) > 0
}

impl AudioHandler {
    /// start_audio's stream as a call's while a call is on; None otherwise.
    pub(super) fn start_voice_audio(&mut self, format0: &AudioFormat) -> Option<ResultType<()>> {
        if !in_call() {
            return None;
        }
        Some(self.open_voice_stream(format0))
    }

    /// The stream rebuilt when a call has started or ended since it was
    /// opened, or when Android closed it.
    pub(super) fn follow_voice_call(&mut self) {
        let lost = self.stream_lost.load(Ordering::Acquire);
        if (self.voice_out == in_call() && !lost) || self.audio_decoder.is_none() {
            return;
        }
        let f = AudioFormat {
            sample_rate: self.sample_rate.0,
            channels: self.channels as _,
            ..Default::default()
        };
        self.handle_format(f);
    }

    fn open_voice_stream(&mut self, format0: &AudioFormat) -> ResultType<()> {
        self.sample_rate = (format0.sample_rate, RATE);
        let resampler = create_audio_resampler(format0.sample_rate, RATE, format0.channels as _)?;
        self.device_channel = 2;
        self.audio_buffer.resize(RATE as _, 2);
        let writer = AudioPlaybackWriter::new(
            AudioPlaybackConfig {
                sample_rate: RATE,
                channels: 2,
            },
            self.audio_buffer.0.clone(),
            self.audio_buffer.3.clone(),
        )?;
        let status = writer.status.clone();
        let stream = oboe::AudioStreamBuilder::default()
            .set_output()
            .set_format::<f32>()
            .set_stereo()
            .set_sample_rate(RATE as _)
            .set_sample_rate_conversion_quality(oboe::SampleRateConversionQuality::Medium)
            .set_usage(oboe::Usage::VoiceCommunication)
            .set_content_type(oboe::ContentType::Speech)
            .set_callback(VoiceOut {
                writer,
                scratch: Vec::new(),
                lost: self.stream_lost.clone(),
            })
            .open_stream()
            .map_err(|e| anyhow!("voice call playback: {e:?}"))?;
        let stream = VoiceStream(RefCell::new(stream));
        stream.play()?;
        self.audio_stream = Some(Box::new(stream));
        self.playback_status = status;
        self.audio_resampler = resampler;
        self.voice_out = true;
        log::info!("audio played as a voice call's ({} Hz from the peer)", format0.sample_rate);
        Ok(())
    }
}

/// cpal's stream error callback: every error is its stream closed
pub(super) fn on_stream_error(
    flag: Arc<AtomicBool>,
) -> impl FnMut(cpal::StreamError) + Send + 'static {
    move |e| lost(&flag, e)
}

fn lost(flag: &AtomicBool, e: impl std::fmt::Debug) {
    if !flag.swap(true, Ordering::AcqRel) {
        log::info!("audio playback closed by Android ({e:?}), to be opened again");
    }
}

struct VoiceOut {
    writer: AudioPlaybackWriter,
    scratch: Vec<f32>,
    lost: Arc<AtomicBool>,
}

impl AudioOutputCallback for VoiceOut {
    type FrameType = (f32, oboe::Stereo);

    fn on_audio_ready(
        &mut self,
        _stream: &mut dyn AudioOutputStreamSafe,
        frames: &mut [(f32, f32)],
    ) -> oboe::DataCallbackResult {
        self.scratch.resize(frames.len() * 2, 0.);
        self.writer.write_output(&mut self.scratch);
        for (f, s) in frames.iter_mut().zip(self.scratch.chunks_exact(2)) {
            *f = (s[0], s[1]);
        }
        oboe::DataCallbackResult::Continue
    }

    fn on_error_after_close(&mut self, _stream: &mut dyn AudioOutputStreamSafe, e: oboe::Error) {
        lost(&self.lost, e);
    }
}

struct VoiceStream(RefCell<oboe::AudioStreamAsync<oboe::Output, VoiceOut>>);

impl StreamTrait for VoiceStream {
    fn play(&self) -> Result<(), cpal::PlayStreamError> {
        self.0.borrow_mut().start().map_err(|e| {
            cpal::PlayStreamError::BackendSpecific {
                err: cpal::BackendSpecificError {
                    description: format!("{e:?}"),
                },
            }
        })
    }

    fn pause(&self) -> Result<(), cpal::PauseStreamError> {
        self.0.borrow_mut().pause().map_err(|e| {
            cpal::PauseStreamError::BackendSpecific {
                err: cpal::BackendSpecificError {
                    description: format!("{e:?}"),
                },
            }
        })
    }
}
