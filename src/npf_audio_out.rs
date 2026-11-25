//! The device the peer's sound is played on (npf): RustDesk plays on the
//! system's default output; the session toolbar's speaker row names another
//! (the local option `audio-output`, empty for the default). Not on Linux,
//! whose playback is PulseAudio's.
use base::message_proto::AudioFormat;
use cpal::traits::{DeviceTrait, HostTrait};
use hbb_common::{config::LocalConfig, log};
use std::time::{Duration, Instant};

pub const OPTION_AUDIO_OUTPUT: &str = "audio-output";

fn chosen_name() -> String {
    LocalConfig::get_option(OPTION_AUDIO_OUTPUT)
}

/// The output devices' names, for the row's list.
#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub fn names() -> Vec<String> {
    // on a thread of its own, as ui_interface::get_sound_inputs: the caller's
    // may have COM set up another way
    std::thread::spawn(|| {
        let mut out = Vec::new();
        match cpal::default_host().output_devices() {
            Ok(devices) => {
                for device in devices {
                    if let Ok(name) = device.name() {
                        if !out.contains(&name) {
                            out.push(name);
                        }
                    }
                }
            }
            Err(e) => log::warn!("npf audio out: the output devices: {e}"),
        }
        out
    })
    .join()
    .unwrap_or_default()
}

/// The device named by the option; None for the default one (none is named,
/// or it is gone).
pub fn chosen(host: &cpal::Host) -> Option<cpal::Device> {
    let name = chosen_name();
    if name.is_empty() {
        return None;
    }
    let found = host
        .output_devices()
        .ok()?
        .find(|d| d.name().map(|n| n == name).unwrap_or(false));
    if found.is_none() {
        log::warn!("npf audio out: \"{name}\" is gone, playing on the default device");
    }
    found
}

/// Follows the option while a session plays: the audio thread opens its
/// output again with the format it has when another device is named.
#[derive(Default)]
pub struct Watch {
    format: Option<AudioFormat>,
    name: String,
    checked: Option<Instant>,
}

impl Watch {
    /// The peer's format, as the output is opened with it.
    pub fn opened(&mut self, format: &AudioFormat) {
        self.format = Some(format.clone());
        self.name = chosen_name();
        self.checked = Some(Instant::now());
    }

    /// Asked a frame: the format to open the output with again, when another
    /// device was named since. The option is read once a second.
    pub fn changed(&mut self) -> Option<AudioFormat> {
        let now = Instant::now();
        if self
            .checked
            .is_some_and(|at| now.duration_since(at) < Duration::from_secs(1))
        {
            return None;
        }
        self.checked = Some(now);
        let name = chosen_name();
        if name == self.name {
            return None;
        }
        log::info!("npf audio out: \"{}\" -> \"{name}\"", self.name);
        self.name = name;
        self.format.clone()
    }
}
