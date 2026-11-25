# npf pages (scheme C)

The desktop UI of RustDesk over npf: RustDesk is the shell, npf the network.
These files replace RustDesk's home page, add a sharing tab, restyle the
connection manager's request card, add a quality pill to the session
toolbar and give connection errors their own texts. RustDesk's own ID,
ID/relay servers and name are not shown (the code paths stay).

The design is the prototype's scheme C boards (CHome, CShare, CIncoming,
Session, Tray, States). `--dart-define=NPF_UI=false` brings RustDesk's own
pages back.

## Page map

| Prototype | Widget | Where it is hooked in |
|---|---|---|
| CHome | `NpfHomePage` (`npf_home_page.dart`) | `DesktopHomePage.build` returns `npfHomePage()` (desktop_home_page.dart; its init logic, timers and window handlers stay) |
| CHome top bars | inside `NpfHomePage` (`state.incoming` / `state.outgoing`) | – |
| 共享 tab | `NpfSharePage` (`npf_share_page.dart`), `NpfInviteDialog` | `npfShareTab()` added after the home tab (desktop_tab_page.dart); 设置 stays RustDesk's settings tab (the tab bar's menu icon) |
| CIncoming | `NpfCmCard` (`npf_cm.dart`) | `buildConnectionCard` returns `npfConnectionCard(client)` when the client JSON has `npf` (server_page.dart) |
| Session toolbar (npf's docs/design/oudesk-ui.md 7) | `NpfDeskBar`, `NpfDeskHandle`, `NpfDeskPanel` and the rows (`npf_desk_ui.dart`), the picture's modes (`npf_desk_modes.dart`) | `desktop/widgets/remote_toolbar_npf.dart`, a part of remote_toolbar.dart: `_buildToolbar` returns `_npfBuildToolbar(...)`, `_buildDraggableCollapse` returns `_npfBuildHandle(...)`, `build` adds `_npfUnder()` / `_npfOver(...)` (the panel, the states' chips), `_debouncerHideProc` returns at once (no auto-hide), `_DraggableShowHide(gripOnly: true)` is the grip; the rows are RustDesk's own lists (common/widgets/toolbar.dart). The speaker row: `src/npf_audio_out.rs` (local option `audio-output`, `main_get_common("npf-audio-outputs")`) |
| Session pill + popover | `NpfQualityButton`, `NpfQualityPill`, `NpfQualityPopover` (`npf_quality.dart`) | `npfQualityItem(ffi)`, the bar's first item |
| States | `NpfConnState`, `NpfStateCard` (`npf_states.dart`) | `msgBox` asks `npfMsgBox(...)` first (common.dart) |
| Settings | – | ID card hidden, ID/relay server hidden (`hideServer`), About: product name, no RustDesk ID / links (desktop_setting_page.dart) |
| Tray | – | none: npf-tray (npf's package) is the tray, see below |

All hooks live in `npf_glue.dart` (the only npf file that knows RustDesk's
types besides `npf_backend_rust.dart`). Upstream files change by a line or
two each; `Client` (server_model.dart) keeps the `npf` map of its JSON.

Strings: `npf_lang.dart` (`npfTr`, English keys, Simplified Chinese table,
English fallback; the language follows RustDesk's `lang` option). The
product name is `kNpfProductName` there. Colours and small widgets:
`npf_ui.dart` (light and dark palettes).

## Model and backend

`NpfModel` (`npf_model.dart`, a `ChangeNotifier`, `NpfModel.instance`) holds
`state` (`NpfState`), `share` (`NpfShareData`) and `recent`. It calls only
`NpfBackend` (`npf_backend.dart`); every Rust/FFI/RustDesk-global access is
behind that interface:

- `RustNpfBackend` (`npf_backend_rust.dart`): the app's implementation.
- `StubNpfBackend` (`npf_backend_stub.dart`): the prototype's sample people
  and devices; tests use it (`NpfBackend.instance = StubNpfBackend()`).

### State: `main_npf_state()`

Re-read on the global event `npf_state` (`platformFFI.registerEventHandler`
on `npf_state`). Numbers (device numbers) are strings; times are unix
seconds; numeric fields may come as JSON numbers or strings.

```json
{"node":"512330087","name":"我的笔记本","online":true,"account":{…}|null,
 "assist":{"code":"K7QM-4XPR-9TWD","expires":1794100000} | {"code":null,"why":"off"|"offline"|"no_owner"},
 "peers":[{"number","name","mine","online","path":"p2p"|"relay"|"ws_relay"|null,"rtt_ms",
           "services":[{"res","title","svc","proto","up","can":[…]}],"until"}],
 "incoming":[{"id","peer":{"number","name","role":"admin"|"member"|null,"temp","via"},
              "can":[…],"allowed":[…],"since"}],
 "outgoing":[{"id","peer":"NUMBER"|{"number","name"},"res","since","path","rtt_ms"}],
 "quota":{"used","limit"}|null}
```

How the pages read it:

- `assist.expires` is the end of the code's 4 h; the page shows the change
  at `expires - 2 h` ("1 小时 52 分后自动更换").
- `peers[].mine` true → 我的设备, false → 共享给我的. Signal bars from
  `rtt_ms` (≤ 50 ms 3, ≤ 150 ms 2, else 1; 0 offline); the text says
  直连 for `p2p`, 经服务器 otherwise.
- A service is the remote desktop when `res == "desktop"`, `svc ==
  "desktop"` or its `res/svc/proto` mentions `rustdesk`; a camera for
  `svc == "camera"` or rtsp/onvif; web for `proto` http(s); SSH for ssh.
  The desktop's `can` decides the 文件 / 终端 buttons; other services
  become secondary buttons (two) and "⋯" entries.
- `until` past → "共享已到期，找他要新码", buttons off.
- `incoming[].peer.temp` → "用的是协助码"; `role` admin → 我的设备,
  else 被邀请的人. `outgoing[].peer` may be a number or an object.

### Sharing data (npf's sharing endpoints)

```json
{"resources":[{"name","title","type","svc","access":"all"|"admin","state":"on"|"off"|"admin_only","caps":[…],"new"?}],
 "members":[{"id","account","login"|"machine":true,"key","fp","label","role","since","until",
             "scope":[{"res","can"}]|null,"online","using":[…]}],
 "codes":[{"locator","label","uses","expires","scope","member_ttl_s"}]}
```

- The list is by people (npf's device-account.md 2, applink.md 3.2): a row
  with `account` is one person (an account, with all its computers and
  phones; `login` its login name, masked by the platform), shown by its
  `label`, else `login`. `role == "admin"` rows are the admins (they gave the
  pairing password), shown with the owner (the account logged in here, not a
  row) as 所有者与管理员; the others are the invited, one each. Rows with
  `machine: true` (`key`, `fp`) are configured peers, machine to machine:
  listed apart, never as people. `id` names a row.
- `scope == null` means everything. A resource without `caps` is granted by
  being in the scope (its `can` is `[]`); the pages show it as "能用".
- Optional fields the pages use when present: `resources[].new` (the 新
  badge).
- Calls: `shareNew(resources, label, memberTtlS)` → `NpfNewCode(code,
  expires, uses)` (the full code, shown once), `memberSet(id, resources,
  until)` (`resources` is the full new scope), `memberRemove(id)`,
  `resourceSet(name, access, on)`, `shareRevoke(locator)`.

### Connection manager: `npf` in the client JSON

The Rust side adds an `npf` object to the CM client info (the JSON of
`Client.fromJson`) for connections that came over npf; without it the CM
shows RustDesk's own card.

```json
"npf":{"number":"903552118","name":"张三的电脑","role":"admin"|"member"|null,
       "temp":true,"label":"李四","via":"K7QM-4XPR-9TWD",
       "can":["view","control"],"allowed":[…],"joined":1793700000,
       "asked":1794100000,"since":null,"res":"desktop"}
```

- `can`: what the share page grants for this resource (for an assist code
  all of remote desktop). The card's "这次允许" boxes are limited to it;
  `view` is always on; with `temp` file and terminal start unticked.
- `asked`: when the request came (the 30 s auto-reject counts from it);
  `since`: when it was accepted (the "正在被控制" clock); `allowed`: what
  was accepted (shown after accepting); `joined`: when the member paired.
- `label` is the 给谁 name the owner typed; `role == "admin"` connections
  are not asked (my devices), the card then only shows the live panel.

### Connection messages

The Rust side reports npf failures as a message box whose text is
`npf:<kind>[:<arg>]`: `wait`, `need_login`, `quota[:200 MiB]`,
`offline[:name]`, `bad_code`, `rejected`, `expired`, `not_shared`.
RustDesk's `wait-remote-accept-nook`, "Remote desktop is offline",
"Connection refused" map too.

## The wiring

`RustNpfBackend` uses the bridge calls of `docs/npf-flutter-api.md`:

- `stateJson()` is `bind.mainNpfState()`; the global event `npf_state`
  says it changed. A new `share_rev` in the state re-reads the sharing
  data (`NpfModel.refresh`).
- `assistRenew()`, `disconnectIncoming(id)` (`incoming[].id`):
  `mainNpfAssistRenew`, `mainNpfDisconnect`.
- `showOutgoing(id)` sends RustDesk's `active_session` to the session
  windows (remote desktop, terminal, camera); `endOutgoing(id)` sends
  `npf_close_session`, which only the remote desktop window knows
  (`remote_tab_page.dart`), and else brings the window to the front.
- The sharing calls are npf's `share/list`, `share/new`, `share/revoke`,
  `member/set`, `member/remove`, `resource/set` through
  `bind.mainNpfCall`; a failure throws `NpfCallError` (npf's word and
  text). npf's `can: null` in a scope is every feature of the resource
  (parsed as the resource's `caps`); `member/set` and `member/remove` go
  by `{"id"}` (the row); `until` null is sent as 0 (no end); `resource/set`
  sends only what changes (`on` is for applications' resources only). npf
  does not give `resources[].new`.
- `cmApprove` is `bind.cmNpfAllow(connId, allowed)`: the Rust side
  withholds what is not ticked (also for the session's later file and
  terminal connections) and accepts; the Dart side then marks the client
  accepted and clears the switches it turned off.
- Not there yet: `connectPeer(..., NpfAction.open)` (web / SSH / camera
  of a peer) and `upgradePlan()` show "暂不可用".

Connecting: the connect box passes the typed text to RustDesk's
`connect(context, text)` (assist code, invite code or device number); a
device card passes the peer's number (with `isFileTransfer`, `isTerminal`,
`isTcpTunneling` for 文件 / 终端 / 端口转发). The Rust side tells them
apart.

## Tray

ouDesk shows no tray icon: npf's UI (its browser console and npf-tray,
which the ouDesk installer installs) is the shell, and ouDesk is the remote
desktop service it launches. With npf enabled RustDesk treats its tray as
`hide-tray` (`src/tray.rs`) and never starts `--tray` nor makes its
startup shortcut.

## Tests

`flutter/test/npf/`: model tests and golden screenshots with the stub
backend (`flutter test --update-goldens test/npf/`, PNGs in
`test/npf/goldens/`). A font with Chinese glyphs is loaded from
`$NPF_TEST_FONTS` (`regular.ttf:bold.ttf`), Windows' DengXian or Noto
Sans CJK.
