//! Finding npf and checking that it is npf (applink.md 3.4): the data
//! directories to try, applink.json read only when it and its directory are
//! npf's account's and nobody else may write them, and the other end of a
//! connection asked of the system. These are security checks: they are
//! those of the C library's sys_posix.c and sys_win.c, kept in step.

#[cfg(unix)]
mod unix;
#[cfg(unix)]
pub(crate) use unix::*;
#[cfg(windows)]
mod windows;
#[cfg(windows)]
pub(crate) use self::windows::*;

/// Tests: the account the checks see as applink.json's owner and as the
/// connection's peer instead of the real ones (on Windows a made-up SID
/// S-1-5-21-1-2-3-N stands for N).
#[derive(Clone, Copy, Debug, Default)]
pub(crate) struct Fake {
    pub file: Option<u32>,
    pub peer: Option<u32>,
}

/// applink.json's most
pub(crate) const FILE_MAX: usize = 4096;
