# RustDesk over npf: the Rust ↔ Flutter contract

RustDesk reaches others and is reached through npf, the program that runs
on its own on this machine (npf's `docs/design/applink.md`, section 7).
Only the service process (`--server`, or the portable program itself)
talks to npf; the UI processes ask it over RustDesk's main IPC. The Rust
side is `src/npf_net` (see its `mod.rs`); the Flutter side is
`flutter/lib/npf` (its `README.md`).

All functions are in `src/flutter_ffi.rs`. Device numbers, the node's
number and `share_rev` are strings; times are Unix seconds; RustDesk
connection ids are numbers. Desktop only: on Android and iOS the
functions return empty or `unsupported` answers.

## Functions

| Function | Returns | |
|---|---|---|
| `main_npf_state() -> SyncReturn<String>` | the state JSON (below) | The first call starts watching the service process; from then on the global event `npf_state` comes on every change. |
| `main_npf_assist_renew()` | – | A new assist code ("换一个"); it arrives with the state. |
| `main_npf_disconnect(id: i32)` | – | Ends an incoming npf connection (`incoming[].id`). |
| `main_npf_call(path: String, body: String) -> String` | `{"ok": ANSWER}` or `{"error": WORD, "message", "detail"}` | npf's sharing-page requests (`share/list`, `share/new`, `share/revoke`, `member/set`, `member/remove`, `resource/set`; npf's applink.md 3.2). `body` is a JSON object, or `""`. Blocks up to ~75 s (`share/new` may wait for the platform). |
| `cm_npf_allow(conn_id: i32, allowed: String)` | – | The CM accepts an npf connection with `allowed` (a JSON list) of its `npf.can`. Replaces `cm_login_res(conn_id, true)` for npf clients. |

Connecting stays RustDesk's `connect(id)`: an assist or share code
(`XXXX-XXXX-XXXX`, any case), a device number (9 digits with npf's check
digit; spaces allowed) or anything after `npf:` goes to npf
(`npf_net::parse_target`); the conn type (remote desktop, file transfer,
terminal, port forward, camera, RDP) becomes the request's `conn_type`.

## Global event `npf_state`

`{"name": "npf_state"}` on every channel of `get_global_event_channels`,
at most 4 a second, whenever the state JSON changed. Call
`main_npf_state()` then.

## The state

```json
{
  "link": {"up": true, "why": null, "message": null},
  "node": "512330087", "name": "我的笔记本", "online": true, "account": true,
  "version": "0.9.2", "resource": "published",
  "assist": {"code": "K7QM-4XPR-9TWD", "expires": 1794100000},
  "quota": {"used": 1048576, "limit": 209715200},
  "share_rev": "17",
  "peers": [{"number": "903552118", "name": "张三的电脑", "mine": true, "online": true,
             "path": "p2p", "rtt_ms": 12, "until": null,
             "services": [{"res": "desktop", "title": null, "svc": "rustdesk",
                           "proto": "rustdesk/1", "up": true,
                           "can": ["view", "control", "file", "terminal"]}]}],
  "incoming": [{"id": 3, "peer": {"number": "903552118", "name": "张三的电脑",
                                   "role": "admin", "temp": false, "via": null},
                "res": "desktop", "conn_type": 0, "can": ["view", "control"],
                "allowed": ["view"], "authorized": true,
                "asked": 1794100000, "since": 1794100004}],
  "outgoing": [{"id": "K7QM-4XPR-9TWD", "peer": "903552118", "res": "desktop",
                "conn_type": 0, "since": 1794100000, "path": "relay", "rtt_ms": 48,
                "kbps": 2400, "loss": 0.01}]
}
```

- `link`: the service process's connection to npf. `up` false with `why`:
  `no_service` (RustDesk's service process is not running or not
  reachable), `no_npf` (npf is not running), `auth` / `denied` (npf does
  not accept this program: `npf applink allow rustdesk PATH`), `replaced`
  (another RustDesk took npf's connection), `io`, `version`. While it is
  down the rest is empty.
- `online`: npf is logged in to the platform. `account`: npf is bound to
  an account (a bool). `resource`: this computer's `desktop` as npf
  published it: `published`, `admin_only`, `off`, `failed:WORD`, or null.
- `assist`: the code with its end (`expires`), or `{"code": null, "why":
  "off" | "offline" | "no_owner"}`.
- `quota`: relay bytes used of the month's limit (numbers), or null.
- `share_rev`: changes when the sharing page's state changed (reload
  `share/list`); null before the first.
- `peers[]`: devices with services for RustDesk. `mine`: this device is
  its admin; `path`: `p2p`, `relay`, `ws_relay` or null without a session;
  `until`: membership end (null: for good); `services[].proto`: the version
  both RustDesks speak, null when none (an incompatible RustDesk).
- `incoming[]`: npf connections to this computer. `id`: RustDesk's
  connection id once it logged in (null before); `conn_type`: RustDesk's
  `ConnType` (0 remote desktop, 1 file transfer, 2 port forward, 3 RDP,
  4 camera, 5 terminal); `can`: what npf granted; `allowed`: what it may
  use now (null until accepted; the CM's choice, following later permission
  switches of keyboard and file); `asked`: when the request came; `since`:
  when it was accepted.
- `outgoing[]`: npf connections made from here. `id` is the ID typed in
  RustDesk's `connect` (the session's peer id); `peer` the device's number
  (null until known); `kbps` and `loss` (0..1) of the last second's
  received media (null before).

## CM: `npf` in the client JSON

A connection that came over npf has `npf` in its CM client (the JSON
behind `Client.fromJson`); others have `"npf": null`.

```json
"npf": {"number": "903552118", "name": "张三的电脑", "role": "admin" | "member" | null,
        "temp": true, "label": null, "via": null, "joined": null,
        "can": ["view", "control"], "allowed": null,
        "asked": 1794100000, "since": null, "res": "desktop", "conn_type": 0}
```

- `temp`: it came with the assist code. RustDesk always asks then,
  whatever its approve mode. `role` `admin` (one of my devices: paired with
  the pairing password, or the same account) is accepted with no password
  and no click; members follow RustDesk's settings (password, click, both).
- `allowed` and `since` are set when it was accepted before the CM saw it
  (one of my devices, a password login); otherwise null.
- `label` (the owner's name for the member) and `joined` (when it paired)
  are always null for now: npf's applink does not give them yet.

Accept with `cm_npf_allow(conn_id, allowed)`:

- without the feature its kind needs (`view` for a remote desktop or
  camera, `file` for file transfer, `terminal`, `control` for port
  forwards and RDP) the connection is closed;
- without `control` RustDesk's keyboard (and mouse), clipboard, restart,
  block input and privacy mode are switched off; without `file` its file
  copy;
- while that remote desktop lasts, the same peer's later file-transfer,
  terminal and port-forward requests are refused when the accept left out
  what they need (the controlling side sees `npf:not_shared`);
- what `can` lacks is never possible: npf's grant is applied when the
  connection starts (RustDesk's `ConnectionMeta.control_permissions`), and
  the CM cannot switch it on later.

Reject or disconnect with RustDesk's `cm_login_res(conn_id, false)` and
`cm_close_connection`.

## Connection failures

A failed npf connection's error (RustDesk's message box text) is
`npf:KIND[:ARG]`:

| Kind | From npf's word | Arg |
|---|---|---|
| `offline` | `offline` | the peer's name, when known |
| `bad_code` | `bad_code` | |
| `rejected` | `refused` (the peer's app or person said no) | |
| `not_shared` | `not_found`, `forbidden`, `not_paired`, the peer's `no_permission` | |
| `expired` | as `not_shared`, when the membership's `until` has passed | |
| `quota` | `quota` | the month's limit, `200 MiB` |
| `need_login` | `no_relay` (a relay is needed and this device may not use one) | |
| others | the word itself: `no_service`, `no_npf`, `auth`, `denied`, `replaced`, `remote_access_off`, `unavailable`, `no_path`, `unsupported`, `version`, `timeout`, `limit` | |

Waiting for the other side to accept is RustDesk's own message
(`wait-remote-accept-nook`).

## Not there yet

- `label` and `joined` in the CM's `npf`.
- Opening a peer's other resources (web, SSH, camera) through npf.
- The account's plan page (npf's web console `/subscribe` needs npf's
  control token, which an app does not get).
