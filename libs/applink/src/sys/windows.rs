//! Windows: applink.json's and its directory's owners and DACLs, the TCP
//! table's listener (its pid is applink.json's, its account npf's), the
//! all-users service's program (sys_win.c).

use super::{Fake, FILE_MAX};
use crate::ErrorKind;
use std::ffi::c_void;
use std::fs::File;
use std::io::Read;
use std::net::SocketAddr;
use std::os::windows::ffi::{OsStrExt, OsStringExt};
use std::os::windows::io::FromRawHandle;
use std::path::{Path, PathBuf};
use windows_sys::Win32::Foundation::{CloseHandle, GetLastError, LocalFree, BOOL, HANDLE, INVALID_HANDLE_VALUE, PSID};
use windows_sys::Win32::Globalization::{CompareStringOrdinal, CSTR_EQUAL};
use windows_sys::Win32::NetworkManagement::IpHelper::{
    GetExtendedTcpTable, MIB_TCP6TABLE_OWNER_PID, MIB_TCPTABLE_OWNER_PID, TCP_TABLE_OWNER_PID_LISTENER,
};
use windows_sys::Win32::Security::Authorization::{GetNamedSecurityInfoW, GetSecurityInfo, SE_FILE_OBJECT};
use windows_sys::Win32::Security::{
    AllocateAndInitializeSid, EqualSid, FreeSid, GetAce, GetLengthSid, GetTokenInformation, IsValidSid,
    IsWellKnownSid, TokenUser, WinBuiltinAdministratorsSid, WinCreatorOwnerRightsSid, WinLocalSystemSid,
    ACCESS_ALLOWED_ACE, ACE_HEADER, ACL, DACL_SECURITY_INFORMATION, OWNER_SECURITY_INFORMATION,
    SECURITY_NT_AUTHORITY, TOKEN_QUERY, TOKEN_USER, WELL_KNOWN_SID_TYPE,
};
use windows_sys::Win32::Storage::FileSystem::{
    CreateFileW, GetFileInformationByHandle, BY_HANDLE_FILE_INFORMATION, FILE_APPEND_DATA, FILE_ATTRIBUTE_DIRECTORY,
    FILE_ATTRIBUTE_REPARSE_POINT, FILE_DELETE_CHILD, FILE_FLAG_OPEN_REPARSE_POINT, FILE_SHARE_DELETE, FILE_SHARE_READ,
    FILE_SHARE_WRITE, FILE_WRITE_ATTRIBUTES, FILE_WRITE_DATA, FILE_WRITE_EA,
};
use windows_sys::Win32::System::Com::CoTaskMemFree;
use windows_sys::Win32::System::RemoteDesktop::{WTSGetActiveConsoleSessionId, WTSQueryUserToken};
use windows_sys::Win32::System::Threading::{
    GetCurrentProcess, OpenProcess, OpenProcessToken, QueryFullProcessImageNameW, PROCESS_QUERY_LIMITED_INFORMATION,
};
use windows_sys::Win32::UI::Shell::{FOLDERID_RoamingAppData, SHGetKnownFolderPath, KF_FLAG_DONT_VERIFY};

const DELETE: u32 = 0x0001_0000;
const READ_CONTROL: u32 = 0x0002_0000;
const WRITE_DAC: u32 = 0x0004_0000;
const WRITE_OWNER: u32 = 0x0008_0000;
const GENERIC_ALL: u32 = 0x1000_0000;
const GENERIC_WRITE: u32 = 0x4000_0000;
const GENERIC_READ: u32 = 0x8000_0000;
const OPEN_EXISTING: u32 = 3;
const ACCESS_ALLOWED_ACE_TYPE: u8 = 0;
const INHERIT_ONLY_ACE: u8 = 0x08;

/// the account npf runs as: its data directory's owner, applink.json's
/// (npf writes it at every start); service: one is SYSTEM or the
/// Administrators (the all-users npf)
#[derive(Clone, Debug)]
pub(crate) struct Owner {
    dir: Vec<u8>,
    file: Vec<u8>,
    service: bool,
}

pub(crate) const NATIVE: crate::Transport = crate::Transport::Tcp;

fn sid_vec(s: PSID) -> Vec<u8> {
    unsafe { std::slice::from_raw_parts(s as *const u8, GetLengthSid(s) as usize).to_vec() }
}

fn psid(v: &[u8]) -> PSID {
    v.as_ptr() as PSID
}

fn is_sid(s: PSID, t: WELL_KNOWN_SID_TYPE) -> bool {
    !s.is_null() && unsafe { IsWellKnownSid(s, t) } != 0
}

/// SYSTEM or the Administrators: the all-users install's accounts
fn is_service_sid(s: PSID) -> bool {
    is_sid(s, WinLocalSystemSid) || is_sid(s, WinBuiltinAdministratorsSid)
}

fn same(a: PSID, b: &[u8]) -> bool {
    !b.is_empty() && unsafe { IsValidSid(psid(b)) != 0 && EqualSid(a, psid(b)) != 0 }
}

/// a process's token user
fn token_sid(proc: HANDLE) -> Option<Vec<u8>> {
    unsafe {
        let mut tok: HANDLE = 0;
        if OpenProcessToken(proc, TOKEN_QUERY, &mut tok) == 0 {
            return None;
        }
        let mut b = [0u64; 16]; // TOKEN_USER and its SID, aligned
        let mut got = 0u32;
        let ok = GetTokenInformation(tok, TokenUser, b.as_mut_ptr() as *mut c_void, 128, &mut got) != 0;
        CloseHandle(tok);
        ok.then(|| sid_vec((*(b.as_ptr() as *const TOKEN_USER)).User.Sid))
    }
}

fn self_is_system() -> bool {
    token_sid(unsafe { GetCurrentProcess() }).map_or(false, |s| is_sid(psid(&s), WinLocalSystemSid))
}

/// the tests' stand-in for another account: S-1-5-21-1-2-3-uid
fn test_sid(uid: u32) -> Vec<u8> {
    unsafe {
        let mut s: PSID = std::ptr::null_mut();
        if AllocateAndInitializeSid(&SECURITY_NT_AUTHORITY, 5, 21, 1, 2, 3, uid, 0, 0, 0, &mut s) == 0 {
            return vec![];
        }
        let v = sid_vec(s);
        FreeSid(s);
        v
    }
}

pub(crate) fn own_owner() -> Owner {
    let me = token_sid(unsafe { GetCurrentProcess() }).unwrap_or_default();
    Owner {
        service: !me.is_empty() && is_sid(psid(&me), WinLocalSystemSid),
        file: me.clone(),
        dir: me,
    }
}

fn wide(p: &Path) -> Vec<u16> {
    p.as_os_str().encode_wide().chain(Some(0)).collect()
}

/// the roaming %APPDATA% of the user at the console (a service asks:
/// WTSQueryUserToken is SYSTEM's alone)
fn console_appdata() -> Option<PathBuf> {
    unsafe {
        let sid = WTSGetActiveConsoleSessionId();
        let mut tok: HANDLE = 0;
        if sid == 0xFFFF_FFFF || WTSQueryUserToken(sid, &mut tok) == 0 {
            return None;
        }
        let mut p: *mut u16 = std::ptr::null_mut();
        let r = SHGetKnownFolderPath(&FOLDERID_RoamingAppData, KF_FLAG_DONT_VERIFY as u32, tok, &mut p);
        let out = (r == 0 && !p.is_null()).then(|| {
            let n = (0..).take_while(|i| *p.add(*i) != 0).count();
            PathBuf::from(std::ffi::OsString::from_wide(std::slice::from_raw_parts(p, n)))
        });
        CoTaskMemFree(p as *const c_void);
        CloseHandle(tok);
        out
    }
}

/// this user's npf, then the all-users service's (svccheck.c's order); a
/// program running as SYSTEM (ouDesk's service) has no npf of its own: the
/// all-users service's, then that of the user at the console (npf installed
/// for that user only, applink.md 3.1). Each place as ouLink, then as npf
/// (its name up to 0.9.8, where an npf not moved yet runs: naming.md 2.2)
pub(crate) fn dirs() -> Vec<PathBuf> {
    let env = |k| std::env::var_os(k).filter(|v| !v.is_empty()).map(PathBuf::from);
    let places = if self_is_system() { [env("ProgramData"), console_appdata()] } else { [env("APPDATA"), env("ProgramData")] };
    places.iter().flatten().flat_map(|p| [p.join("ouLink"), p.join("npf")]).collect()
}

/// Nobody but these may write (or take over) the object: its DACL allows
/// writing only to the owners, SYSTEM, the Administrators and OWNER RIGHTS
unsafe fn only_owners_write(dacl: *const ACL, a: PSID, b: PSID) -> bool {
    let write = FILE_WRITE_DATA | FILE_APPEND_DATA | FILE_WRITE_EA | FILE_DELETE_CHILD | FILE_WRITE_ATTRIBUTES | DELETE
        | WRITE_DAC | WRITE_OWNER | GENERIC_WRITE | GENERIC_ALL;
    if dacl.is_null() {
        return false; // a NULL DACL: everyone may do anything
    }
    for i in 0..(*dacl).AceCount as u32 {
        let mut ace: *mut c_void = std::ptr::null_mut();
        if GetAce(dacl, i, &mut ace) == 0 {
            return false;
        }
        let h = &*(ace as *const ACE_HEADER);
        if h.AceType != ACCESS_ALLOWED_ACE_TYPE || h.AceFlags & INHERIT_ONLY_ACE != 0 {
            continue; // denials, audits, what only children get
        }
        let a_ace = &*(ace as *const ACCESS_ALLOWED_ACE);
        if a_ace.Mask & write == 0 {
            continue;
        }
        let who = &a_ace.SidStart as *const u32 as PSID;
        if !(EqualSid(who, a) != 0 || (!b.is_null() && EqualSid(who, b) != 0) || is_service_sid(who) || is_sid(who, WinCreatorOwnerRightsSid))
        {
            return false;
        }
    }
    true
}

struct Sd(*mut c_void);
impl Drop for Sd {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe { LocalFree(self.0 as _) };
        }
    }
}

/// dir's applink.json, after checking that the file is the directory
/// owner's (or the all-users service's) and only they may write either
pub(crate) fn read_npf(dir: &Path, fake: Fake) -> Result<(String, Owner), ErrorKind> {
    let wd = wide(dir);
    let wf = wide(&dir.join("applink.json"));
    unsafe {
        // the file itself, not what a link in its place points at
        let h = CreateFileW(
            wf.as_ptr(),
            GENERIC_READ | READ_CONTROL,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            std::ptr::null(),
            OPEN_EXISTING,
            FILE_FLAG_OPEN_REPARSE_POINT,
            0,
        );
        if h == INVALID_HANDLE_VALUE {
            let e = GetLastError();
            return Err(if e == 2 || e == 3 { ErrorKind::NoNpf } else { ErrorKind::Auth });
        }
        let mut f = File::from_raw_handle(h as _);
        let mut fi: BY_HANDLE_FILE_INFORMATION = std::mem::zeroed();
        let (mut downer, mut fowner): (PSID, PSID) = (std::ptr::null_mut(), std::ptr::null_mut());
        let (mut ddacl, mut fdacl): (*mut ACL, *mut ACL) = (std::ptr::null_mut(), std::ptr::null_mut());
        let (mut dsd, mut fsd) = (Sd(std::ptr::null_mut()), Sd(std::ptr::null_mut()));
        let info = OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION;
        if GetFileInformationByHandle(h, &mut fi) == 0
            || fi.dwFileAttributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY) != 0
            || GetSecurityInfo(h, SE_FILE_OBJECT, info, &mut fowner, std::ptr::null_mut(), &mut fdacl, std::ptr::null_mut(), &mut fsd.0) != 0
            || GetNamedSecurityInfoW(wd.as_ptr(), SE_FILE_OBJECT, info, &mut downer, std::ptr::null_mut(), &mut ddacl, std::ptr::null_mut(), &mut dsd.0) != 0
            || downer.is_null()
            || fowner.is_null()
        {
            return Err(ErrorKind::Auth);
        }
        let tsid = fake.file.map(test_sid);
        if let Some(t) = &tsid {
            fowner = psid(t);
        }
        if (EqualSid(fowner, downer) == 0 && !is_service_sid(fowner))
            || !only_owners_write(ddacl, downer, fowner)
            || !only_owners_write(fdacl, downer, fowner)
        {
            return Err(ErrorKind::Auth);
        }
        let mut s = String::new();
        (&mut f).take(FILE_MAX as u64).read_to_string(&mut s).map_err(|_| ErrorKind::Proto)?;
        if s.len() >= FILE_MAX {
            return Err(ErrorKind::Proto);
        }
        Ok((
            s,
            Owner {
                dir: sid_vec(downer),
                file: sid_vec(fowner),
                service: is_service_sid(downer) || is_service_sid(fowner),
            },
        ))
    }
}

/// the TCP table of the family (2 IPv4, 23 IPv6), listeners with their pids
fn tcp_table(family: u32) -> Option<Vec<u64>> {
    unsafe {
        let mut sz = 0u32;
        GetExtendedTcpTable(std::ptr::null_mut(), &mut sz, 0 as BOOL, family, TCP_TABLE_OWNER_PID_LISTENER, 0);
        sz += 4096;
        let mut t = vec![0u64; sz as usize / 8 + 1];
        (GetExtendedTcpTable(t.as_mut_ptr() as *mut c_void, &mut sz, 0, family, TCP_TABLE_OWNER_PID_LISTENER, 0) == 0)
            .then_some(t)
    }
}

/// the process listening where the connection goes (its own address, else every address); 0: not found
fn listener_pid(to: SocketAddr) -> u32 {
    let (mut exact, mut any) = (0, 0);
    let port = to.port().to_be() as u32;
    match to {
        SocketAddr::V4(a) => {
            let Some(t) = tcp_table(2) else { return 0 };
            let t = unsafe { &*(t.as_ptr() as *const MIB_TCPTABLE_OWNER_PID) };
            let rows = unsafe { std::slice::from_raw_parts(t.table.as_ptr(), t.dwNumEntries as usize) };
            for r in rows.iter().filter(|r| r.dwLocalPort & 0xffff == port) {
                if r.dwLocalAddr == u32::from_ne_bytes(a.ip().octets()) {
                    exact = r.dwOwningPid;
                } else if r.dwLocalAddr == 0 {
                    any = r.dwOwningPid;
                }
            }
        }
        SocketAddr::V6(a) => {
            let Some(t) = tcp_table(23) else { return 0 };
            let t = unsafe { &*(t.as_ptr() as *const MIB_TCP6TABLE_OWNER_PID) };
            let rows = unsafe { std::slice::from_raw_parts(t.table.as_ptr(), t.dwNumEntries as usize) };
            for r in rows.iter().filter(|r| r.dwLocalPort & 0xffff == port) {
                if r.ucLocalAddr == a.ip().octets() {
                    exact = r.dwOwningPid;
                } else if r.ucLocalAddr == [0; 16] {
                    any = r.dwOwningPid;
                }
            }
        }
    }
    if exact != 0 {
        exact
    } else {
        any
    }
}

/// the all-users install's program: %ProgramFiles%\ouLink\npf.exe (the installers)
fn service_program(proc: HANDLE) -> bool {
    let pf = std::env::var_os("ProgramW6432")
        .filter(|v| !v.is_empty())
        .or_else(|| std::env::var_os("ProgramFiles"))
        .filter(|v| !v.is_empty());
    let Some(pf) = pf else { return false };
    let want = wide(&PathBuf::from(pf).join("ouLink").join("npf.exe"));
    let mut have = vec![0u16; 1024];
    let mut n = have.len() as u32;
    unsafe {
        QueryFullProcessImageNameW(proc, 0, have.as_mut_ptr(), &mut n) != 0
            && CompareStringOrdinal(have.as_ptr(), n as i32, want.as_ptr(), -1, 1) == CSTR_EQUAL
    }
}

/// The listener of the connection's address is process `pid` (applink.json's)
/// of npf's account: the directory's or the file's owner, or SYSTEM for the
/// all-users service, whose program is then the installed one. None: another
/// process listens there, most likely npf restarting before it has written
/// applink.json again (worth trying again later; nothing was sent to it).
pub(crate) fn check_tcp(s: &tokio::net::TcpStream, o: &Owner, pid: u32, fake: Fake) -> Option<bool> {
    let Ok(to) = s.peer_addr() else { return Some(false) };
    let lp = listener_pid(to);
    if lp == 0 || (pid != 0 && lp != pid) {
        return None; // not the process applink.json names
    }
    unsafe {
        let proc = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, lp);
        if proc == 0 {
            return Some(false);
        }
        let sid = token_sid(proc).map(|s| fake.peer.map_or(s, test_sid));
        let ok = sid.map_or(false, |sid| {
            let s = psid(&sid);
            let system = is_sid(s, WinLocalSystemSid);
            (same(s, &o.dir) || same(s, &o.file) || (o.service && system)) && (!o.service || !system || service_program(proc))
        });
        CloseHandle(proc);
        Some(ok)
    }
}
