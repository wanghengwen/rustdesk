//! Linux, macOS, Android: the Unix socket's peer uid, file owners and modes.

use super::{Fake, FILE_MAX};
use crate::ErrorKind;
use std::fs::{File, OpenOptions};
use std::io::{ErrorKind as IoKind, Read};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

/// the account npf runs as: the owner of its data directory
#[derive(Clone, Debug)]
pub(crate) struct Owner {
    uid: u32,
}

pub(crate) const NATIVE: crate::Transport = crate::Transport::Unix;

/// this process's account (unix_path, tcp_addr: npf is taken to be its own)
pub(crate) fn own_owner() -> Owner {
    Owner {
        uid: unsafe { libc::geteuid() },
    }
}

/// npf's own default (client/app): a user's is ~/.config/oulink, root's and
/// the system service's /etc/oulink (on macOS /Library/ouLink/data); each
/// place also under its name up to 0.9.8, right after the new one, where an
/// npf not moved yet runs (docs/design/naming.md 2.2; sys_posix.c alike)
pub(crate) fn dirs() -> Vec<PathBuf> {
    let root = unsafe { libc::geteuid() } == 0;
    #[allow(unused_mut)]
    let mut v = dirs_of(std::env::var_os("HOME").filter(|h| !h.is_empty() && !root).map(PathBuf::from));
    // root (ouDesk's agent at the login window, its daemon) has no npf of its
    // own there: then that of the user at the screen (npf runs as the user,
    // started by its tray)
    #[cfg(target_os = "macos")]
    if root {
        v.extend(console_home().iter().flat_map(|h| [h.join(".config/oulink"), h.join(".config/npf")]));
    }
    v
}

/// the home of the user at the screen (the owner of /dev/console), not root
#[cfg(target_os = "macos")]
fn console_home() -> Option<PathBuf> {
    use std::os::unix::ffi::OsStrExt;
    let uid = std::fs::metadata("/dev/console").ok()?.uid();
    if uid == 0 {
        return None;
    }
    let pw = unsafe { libc::getpwuid(uid) };
    if pw.is_null() || unsafe { (*pw).pw_dir }.is_null() {
        return None;
    }
    let dir = unsafe { std::ffi::CStr::from_ptr((*pw).pw_dir) };
    let p = PathBuf::from(std::ffi::OsStr::from_bytes(dir.to_bytes()));
    p.is_absolute().then_some(p)
}

pub(crate) fn dirs_of(home: Option<PathBuf>) -> Vec<PathBuf> {
    let mut v: Vec<PathBuf> = home.iter().flat_map(|h| [h.join(".config/oulink"), h.join(".config/npf")]).collect();
    v.extend(["/etc/oulink", "/etc/npf"].map(PathBuf::from));
    #[cfg(target_os = "macos")]
    v.extend(["/Library/ouLink/data", "/Library/NPF/data"].map(PathBuf::from));
    v
}

/// dir's applink.json, after checking that the directory's owner is npf's
/// account, the file is its (or root's), and nobody else may write either
pub(crate) fn read_npf(dir: &Path, fake: Fake) -> Result<(String, Owner), ErrorKind> {
    let d = File::open(dir).map_err(|_| ErrorKind::NoNpf)?;
    // the file itself, not what a link in its place points at (ELOOP: Auth)
    let mut f = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(dir.join("applink.json"))
        .map_err(|e| if e.kind() == IoKind::NotFound { ErrorKind::NoNpf } else { ErrorKind::Auth })?;
    let (ds, fs) = match (d.metadata(), f.metadata()) {
        (Ok(ds), Ok(fs)) => (ds, fs),
        _ => return Err(ErrorKind::Auth),
    };
    let fuid = fake.file.unwrap_or(fs.uid());
    if !ds.is_dir() || !fs.is_file() || ds.mode() & 0o022 != 0 || fs.mode() & 0o022 != 0 || (fuid != ds.uid() && fuid != 0)
    {
        return Err(ErrorKind::Auth);
    }
    let mut s = String::new();
    (&mut f).take(FILE_MAX as u64).read_to_string(&mut s).map_err(|_| ErrorKind::Proto)?;
    if s.len() >= FILE_MAX {
        return Err(ErrorKind::Proto);
    }
    Ok((s, Owner { uid: ds.uid() }))
}

/// the Unix socket's peer is npf's account (or root)
pub(crate) fn check_unix(s: &tokio::net::UnixStream, o: &Owner, fake: Fake) -> bool {
    let uid = fake.peer.or_else(|| s.peer_cred().ok().map(|c| c.uid()));
    uid.map_or(false, |u| u == o.uid || u == 0)
}
