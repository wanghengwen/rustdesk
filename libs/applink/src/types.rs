//! What npf says and what the functions take: npf's JSON (applink.md 3.2,
//! 3.3) read straight into these types, and written back out as it came
//! (they pass on to a UI as they are).

use serde::{Deserialize, Deserializer, Serialize};
use serde_json::Value;

/// A device number: npf writes them as strings ("599890970"), a number is taken too.
pub(crate) fn number<'de, D: Deserializer<'de>>(d: D) -> Result<u64, D::Error> {
    Ok(match Value::deserialize(d)? {
        Value::Number(n) => n.as_u64().unwrap_or(0),
        Value::String(s) => s.parse().unwrap_or(0),
        _ => 0,
    })
}

fn opt_number<'de, D: Deserializer<'de>>(d: D) -> Result<Option<u64>, D::Error> {
    Ok(Some(number(d)?).filter(|n| *n != 0))
}

/// a string, null as ""
fn text<'de, D: Deserializer<'de>>(d: D) -> Result<String, D::Error> {
    Ok(Option::<String>::deserialize(d)?.unwrap_or_default())
}

/// npf's word for the path; None without a session, or a word not known here
fn path<'de, D: Deserializer<'de>>(d: D) -> Result<Option<Path>, D::Error> {
    Ok(Option::<Value>::deserialize(d)?.and_then(|v| serde_json::from_value(v).ok()))
}

/// true / false, or 1 / 0
fn flag<'de, D: Deserializer<'de>>(d: D) -> Result<bool, D::Error> {
    Ok(match Value::deserialize(d)? {
        Value::Bool(b) => b,
        Value::Number(n) => n.as_u64() == Some(1),
        _ => false,
    })
}

/// This device, as npf tells it (`hello`, `info`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Info {
    /// None before it has one
    #[serde(rename = "node", deserialize_with = "opt_number")]
    pub number: Option<u64>,
    #[serde(deserialize_with = "text")]
    pub name: String,
    /// logged in to the platform
    pub online: bool,
    /// bound to an account (it may use a relay)
    pub account: bool,
    /// npf's version
    #[serde(deserialize_with = "text")]
    pub version: String,
}

/// The path of the session with a peer.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Path {
    P2p,
    Relay,
    WsRelay,
}

impl Path {
    /// npf's word: "p2p", "relay", "ws_relay"
    pub fn word(self) -> &'static str {
        match self {
            Path::P2p => "p2p",
            Path::Relay => "relay",
            Path::WsRelay => "ws_relay",
        }
    }
}

/// A resource a peer offers this app.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct ServiceInfo {
    /// its id: what [`crate::Link::request`] asks for
    pub res: String,
    /// its owner's name for it; None: localize `res`
    pub title: Option<String>,
    /// the service type ("rustdesk")
    pub svc: String,
    /// the versions its provider speaks, preferred first
    #[serde(rename = "proto")]
    pub protos: Vec<String>,
    /// the peer's app is running
    pub up: bool,
    /// what this device was granted (its admin: everything)
    pub can: Vec<String>,
}

/// A device with services this app may use (`hello`'s `peers`, `peer`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Peer {
    #[serde(deserialize_with = "number")]
    pub number: u64,
    /// the peer's own word (cleaned by npf), for showing
    #[serde(deserialize_with = "text")]
    pub name: String,
    /// this device is its admin; else it was shared with this device
    pub mine: bool,
    pub online: bool,
    /// None without a session
    #[serde(deserialize_with = "path")]
    pub path: Option<Path>,
    pub rtt_ms: Option<u32>,
    pub services: Vec<ServiceInfo>,
    /// this device is that one's member until then (Unix time); None: for good
    pub until: Option<i64>,
    /// no longer listed (the rest may be empty)
    pub gone: bool,
}

/// The assist code, or why there is none: npf's own object
/// (`{"code", "expires"}` or `{"code": null, "why": "off" | "offline" | "no_owner"}`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Assist {
    pub code: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expires: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub why: Option<String>,
}

/// The requester's role on this device.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Role {
    Admin,
    Member,
}

impl Role {
    pub fn word(self) -> &'static str {
        match self {
            Role::Admin => "admin",
            Role::Member => "member",
        }
    }
}

/// Who asks, as npf knows it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Requester {
    #[serde(deserialize_with = "number")]
    pub number: u64,
    /// its name (cleaned by npf; the peer's word, for showing)
    pub name: Option<String>,
    /// None: no pairing (a temp code's guest)
    pub role: Option<Role>,
    /// the locator of the share code it paired with
    pub via: Option<String>,
    /// came in with a session-only code (the assist code)
    pub temp: bool,
}

/// A peer asks this app for a service (`request`): answer with
/// [`crate::Link::accept`] or [`crate::Link::refuse`] within 60 s.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Request {
    /// npf's number of the service
    pub service: u32,
    /// which of this app's resources
    pub res: String,
    /// the version to speak: one of this app's protos
    pub proto: String,
    pub peer: Requester,
    /// what it was granted on `res`: act on this, never on the body
    pub can: Vec<String>,
    /// the requester app's own request (a JSON object)
    pub body: Value,
}

impl Request {
    /// `cap` was granted
    pub fn can(&self, cap: &str) -> bool {
        self.can.iter().any(|c| c == cap)
    }
}

/// Media streams of a tag the requester may open in a service.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Slot {
    /// 1..=59
    pub tag: i32,
    /// how many streams of that tag
    pub n: i32,
}

/// A media frame's information.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct FrameInfo {
    /// from 0, per stream
    pub frame_no: u32,
    pub key: bool,
    /// lost by the network since the last one delivered
    pub lost_before: u32,
    /// dropped by npf since then, this app not reading fast enough (delivery
    /// then resumed at a key frame: ask the sender for one)
    pub skipped_before: u32,
}

/// libnpf's statistics of a stream this app sends on, once a second.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct MediaStats {
    /// bytes a second the session's congestion control leaves
    pub target_rate: u32,
    pub srtt_ms: u32,
    pub min_rtt_ms: u32,
    pub frames_dropped: u32,
    pub frames_skipped: u32,
    pub fec_recovered: u32,
    pub peer_frame_delay_avg_ms: u32,
    pub peer_frame_delay_max_ms: u32,
    pub peer_jitter_ms: u32,
    #[serde(deserialize_with = "flag")]
    pub capacity_short: bool,
}

/// What became of one of this app's resources.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ResourceState {
    /// offered as declared
    Published,
    /// the admin here limited it to the admin's own devices
    AdminOnly,
    /// the admin here turned it off (npf keeps it off, and keeps the id)
    Off,
    /// npf did not take it: Denied (svc not in the manifest), Conflict,
    /// TooBig, Limit, Invalid; or the declaration failed as a whole
    Failed(crate::ErrorKind),
}

impl ResourceState {
    pub(crate) fn from_word(w: &str) -> ResourceState {
        use crate::ErrorKind::*;
        match w {
            "published" => ResourceState::Published,
            "admin_only" => ResourceState::AdminOnly,
            "off" => ResourceState::Off,
            "denied" => ResourceState::Failed(Denied),
            "conflict" => ResourceState::Failed(Conflict),
            "too_big" => ResourceState::Failed(TooBig),
            "limit" => ResourceState::Failed(Limit),
            "bad_request" => ResourceState::Failed(Invalid),
            _ => ResourceState::Failed(Proto),
        }
    }

    /// npf's word ("published", "admin_only", "off"), or the error's
    pub fn word(self) -> &'static str {
        match self {
            ResourceState::Published => "published",
            ResourceState::AdminOnly => "admin_only",
            ResourceState::Off => "off",
            ResourceState::Failed(e) => e.word(),
        }
    }
}

/// One of this app's resources.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct Resource {
    /// the id: 1..64 of a-z 0-9 - _ . ("desktop"), kept for good
    pub name: String,
    /// what people call it; None for a well-known id the clients localize
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    /// a service type in this app's manifest's provides ("rustdesk")
    pub svc: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub desc: Option<String>,
    /// its features ("view", "control")
    pub caps: Vec<String>,
    /// usable now
    pub up: bool,
}

impl Resource {
    pub fn new(name: &str, svc: &str, caps: &[&str]) -> Resource {
        Resource {
            name: name.into(),
            title: None,
            svc: svc.into(),
            desc: None,
            caps: caps.iter().map(|c| (*c).into()).collect(),
            up: true,
        }
    }
}

/// FEC of a media stream.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Fec {
    Auto,
    Off,
    On,
}

/// How a media stream sends (libnpf's npf_media_opt).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct MediaOpt {
    /// 1..=59
    pub tag: i32,
    /// 0 (first) ..= 3
    pub prio: i32,
    /// a frame not sent this long after it was given is dropped
    pub max_age_ms: i32,
    /// after a dropped frame, drop the others until a key frame
    pub drop_until_key: bool,
    pub fec: Fec,
    /// fixed parity per 100 packets; 0: adaptive
    pub fec_ratio: i32,
    /// the receiver may wait this many round trips for a frame; 0: off
    pub latency_rtt: i32,
    /// the receiver skips to the next key frame after a lost frame
    pub rcv_drop_until_key: bool,
}

impl MediaOpt {
    /// libnpf's defaults for the tag
    pub fn new(tag: i32) -> MediaOpt {
        MediaOpt {
            tag,
            prio: 1,
            max_age_ms: 500,
            drop_until_key: false,
            fec: Fec::Auto,
            fec_ratio: 0,
            latency_rtt: 0,
            rcv_drop_until_key: false,
        }
    }

    pub(crate) fn valid(&self) -> bool {
        (1..=crate::TAG_MAX).contains(&self.tag)
            && (0..=3).contains(&self.prio)
            && self.max_age_ms >= 0
            && (0..=100).contains(&self.fec_ratio)
            && self.latency_rtt >= 0
    }

    pub(crate) fn json(&self, service: u32) -> Value {
        serde_json::json!({
            "service": service,
            "tag": self.tag,
            "prio": self.prio,
            "max_age_ms": self.max_age_ms,
            "drop_until_key": self.drop_until_key as i32,
            "fec": match self.fec { Fec::Auto => -1, Fec::Off => 0, Fec::On => 1 },
            "fec_ratio": self.fec_ratio,
            "latency_rtt": self.latency_rtt,
            "rcv_drop_until_key": self.rcv_drop_until_key as i32,
        })
    }
}

/// The transport to npf.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Transport {
    Unix,
    /// the loopback control port (Windows)
    Tcp,
    /// npf's own process ([`crate::Options::dial`])
    InProc,
}

/// The events this app subscribes to (`attach`'s `want`). Each is also a
/// capability: without `requests` the app provides nothing, without `peers`
/// [`crate::Link::peers`] says State.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Want {
    pub peers: bool,
    pub assist: bool,
    pub quota: bool,
    pub requests: bool,
    /// the sharing page's state changed ([`crate::Event::Share`])
    pub share: bool,
    /// npf's own UI asks to open a session ([`crate::Event::Open`])
    pub open: bool,
}

impl Want {
    pub const ALL: Want = Want {
        peers: true,
        assist: true,
        quota: true,
        requests: true,
        share: true,
        open: true,
    };

    pub(crate) fn words(&self) -> Vec<&'static str> {
        [
            (self.peers, "peer"),
            (self.assist, "assist"),
            (self.quota, "quota"),
            (self.requests, "request"),
            (self.share, "share"),
            (self.open, "open"),
        ]
        .iter()
        .filter(|(on, _)| *on)
        .map(|(_, w)| *w)
        .collect()
    }
}
