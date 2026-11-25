// The npf state shown by the scheme C pages, parsed from the JSON of the
// Rust side (`main_npf_state()`, re-read on the global event `npf_state`) and
// from the sharing endpoints of npf. See README.md for the contract.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'npf_backend.dart';
import 'npf_lang.dart';

String _str(Object? v) => v == null ? '' : '$v';
String? _strOrNull(Object? v) => v == null ? null : '$v';
int? _int(Object? v) =>
    v is num ? v.toInt() : (v is String ? int.tryParse(v) : null);
bool _bool(Object? v) => v == true || v == 'true' || v == 1;
List<String> _strs(Object? v) =>
    v is List ? v.map((e) => '$e').toList() : const <String>[];
List<Map<String, dynamic>> _maps(Object? v) => v is List
    ? v.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList()
    : const [];
Map<String, dynamic>? _map(Object? v) =>
    v is Map ? v.cast<String, dynamic>() : null;

/// Unix seconds to a local [DateTime].
DateTime? npfTime(int? s) =>
    s == null ? null : DateTime.fromMillisecondsSinceEpoch(s * 1000);

/// The device number as shown: "512 330 087".
String npfGroupNumber(String n) {
  if (!RegExp(r'^\d{7,}$').hasMatch(n)) return n;
  final b = StringBuffer();
  for (var i = 0; i < n.length; i++) {
    if (i > 0 && (n.length - i) % 3 == 0) b.write(' ');
    b.write(n[i]);
  }
  return b.toString();
}

/// The assist code (a temporary share code), or why there is none.
class NpfAssist {
  final String? code;
  final int? expires; // unix seconds: valid until
  final String? why; // off | offline | no_owner

  const NpfAssist({this.code, this.expires, this.why});

  factory NpfAssist.fromJson(Map<String, dynamic>? j) => j == null
      ? const NpfAssist(why: 'offline')
      : NpfAssist(
          code: _strOrNull(j['code']),
          expires: _int(j['expires']),
          why: _strOrNull(j['why']));

  /// A new code is issued every 2 hours, each valid for 4.
  int? get renewsAt => expires == null ? null : expires! - 2 * 3600;
}

/// What a service of a peer is, for the buttons of the device card.
enum NpfServiceKind { desktop, camera, web, ssh, other }

class NpfService {
  final String res; // resource name (an identifier: desktop, cam-3f2a)
  final String title; // display name
  final String svc;
  final String proto;
  final bool up;
  final List<String> can;

  const NpfService(
      {required this.res,
      this.title = '',
      this.svc = '',
      this.proto = '',
      this.up = true,
      this.can = const []});

  factory NpfService.fromJson(Map<String, dynamic> j) => NpfService(
      res: _str(j['res']),
      title: _str(j['title']),
      svc: _str(j['svc']),
      proto: _str(j['proto']),
      up: j['up'] == null ? true : _bool(j['up']),
      can: _strs(j['can']));

  NpfServiceKind get kind {
    final s = '$res $svc $proto'.toLowerCase();
    if (res == 'desktop' || svc == 'desktop' || s.contains('rustdesk')) {
      return NpfServiceKind.desktop;
    }
    if (svc == 'camera' || s.contains('rtsp') || s.contains('onvif')) {
      return NpfServiceKind.camera;
    }
    if (proto.startsWith('http') || svc == 'web') return NpfServiceKind.web;
    if (proto == 'ssh' || svc == 'ssh') return NpfServiceKind.ssh;
    return NpfServiceKind.other;
  }
}

class NpfPeer {
  final String number;
  final String name;
  final bool mine; // I am admin there (我的设备); else a member (共享给我的)
  final bool online;
  final String? path; // p2p | relay | ws_relay | null
  final int? rttMs;
  final List<NpfService> services;
  final int? until; // member share expiry, unix seconds

  const NpfPeer(
      {required this.number,
      this.name = '',
      this.mine = false,
      this.online = false,
      this.path,
      this.rttMs,
      this.services = const [],
      this.until});

  factory NpfPeer.fromJson(Map<String, dynamic> j) => NpfPeer(
      number: _str(j['number']),
      name: _str(j['name']),
      mine: _bool(j['mine']),
      online: _bool(j['online']),
      path: _strOrNull(j['path']),
      rttMs: _int(j['rtt_ms']),
      services: _maps(j['services']).map(NpfService.fromJson).toList(),
      until: _int(j['until']));

  String get label => name.isNotEmpty ? name : npfGroupNumber(number);

  NpfService? get desktop =>
      services.where((s) => s.kind == NpfServiceKind.desktop).firstOrNull;

  bool expiredAt(DateTime now) =>
      until != null && npfTime(until)!.isBefore(now);
}

/// The other side of a live connection.
class NpfPeerRef {
  final String number;
  final String name;
  final String? role; // admin | member | null
  final bool temp; // came with the assist code
  final String via; // the code or how it came

  const NpfPeerRef(
      {this.number = '',
      this.name = '',
      this.role,
      this.temp = false,
      this.via = ''});

  factory NpfPeerRef.fromJson(Object? v) {
    if (v is! Map) return NpfPeerRef(number: _str(v));
    final j = v.cast<String, dynamic>();
    return NpfPeerRef(
        number: _str(j['number']),
        name: _str(j['name']),
        role: _strOrNull(j['role']),
        temp: _bool(j['temp']),
        via: _str(j['via']));
  }

  String get label => name.isNotEmpty ? name : npfGroupNumber(number);
}

/// Someone connected to this computer.
class NpfIncoming {
  final String id;
  final NpfPeerRef peer;
  final List<String> can; // granted on the share page
  final List<String> allowed; // allowed this time
  final int? since;

  const NpfIncoming(
      {required this.id,
      required this.peer,
      this.can = const [],
      this.allowed = const [],
      this.since});

  factory NpfIncoming.fromJson(Map<String, dynamic> j) => NpfIncoming(
      id: _str(j['id']),
      peer: NpfPeerRef.fromJson(j['peer']),
      can: _strs(j['can']),
      allowed: _strs(j['allowed']),
      since: _int(j['since']));
}

/// A connection of mine to another computer.
class NpfOutgoing {
  final String id;
  final NpfPeerRef peer;
  final String res;
  final int? since;
  final String? path;
  final int? rttMs;

  const NpfOutgoing(
      {required this.id,
      required this.peer,
      this.res = 'desktop',
      this.since,
      this.path,
      this.rttMs});

  factory NpfOutgoing.fromJson(Map<String, dynamic> j) => NpfOutgoing(
      id: _str(j['id']),
      peer: NpfPeerRef.fromJson(j['peer']),
      res: _str(j['res']),
      since: _int(j['since']),
      path: _strOrNull(j['path']),
      rttMs: _int(j['rtt_ms']));
}

/// Relay traffic of the account this month, bytes.
class NpfQuota {
  final int used;
  final int limit;
  const NpfQuota(this.used, this.limit);

  static NpfQuota? fromJson(Map<String, dynamic>? j) => j == null
      ? null
      : NpfQuota(_int(j['used']) ?? 0, _int(j['limit']) ?? 0);

  double get ratio => limit <= 0 ? 0 : (used / limit).clamp(0, 1).toDouble();
}

/// `main_npf_state()`.
class NpfState {
  final String node;
  final String name;
  final bool online;
  final Map<String, dynamic>? account;
  final NpfAssist assist;
  final List<NpfPeer> peers;
  final List<NpfIncoming> incoming;
  final List<NpfOutgoing> outgoing;
  final NpfQuota? quota;
  final String? shareRev; // changes with the sharing page's data

  const NpfState(
      {this.node = '',
      this.name = '',
      this.online = false,
      this.account,
      this.assist = const NpfAssist(why: 'offline'),
      this.peers = const [],
      this.incoming = const [],
      this.outgoing = const [],
      this.quota,
      this.shareRev});

  static const empty = NpfState();

  factory NpfState.fromJson(Map<String, dynamic> j) => NpfState(
      node: _str(j['node']),
      name: _str(j['name']),
      online: _bool(j['online']),
      account: _map(j['account']),
      assist: NpfAssist.fromJson(_map(j['assist'])),
      peers: _maps(j['peers']).map(NpfPeer.fromJson).toList(),
      incoming: _maps(j['incoming']).map(NpfIncoming.fromJson).toList(),
      outgoing: _maps(j['outgoing']).map(NpfOutgoing.fromJson).toList(),
      quota: NpfQuota.fromJson(_map(j['quota'])),
      shareRev: _strOrNull(j['share_rev']));

  static NpfState parse(String s) {
    if (s.isEmpty) return empty;
    try {
      final j = jsonDecode(s);
      return j is Map ? NpfState.fromJson(j.cast<String, dynamic>()) : empty;
    } catch (e) {
      debugPrint('npf state: $e');
      return empty;
    }
  }

  bool get signedIn => account != null;
  List<NpfPeer> get mine => peers.where((p) => p.mine).toList();
  List<NpfPeer> get shared => peers.where((p) => !p.mine).toList();

  NpfPeer? peer(String number) =>
      peers.where((p) => p.number == number).firstOrNull;
}

/// A computer I helped with an assist code (RustDesk's recent sessions).
class NpfRecent {
  final String id;
  final String name;
  final int? at;
  final bool assist;
  const NpfRecent(
      {required this.id, this.name = '', this.at, this.assist = true});
}

// ---------------------------------------------------------------------------
// sharing page

/// A resource of this computer.
class NpfResource {
  final String name; // identifier
  final String title;
  final String type; // desktop | camera | web | folder | ...
  final String svc;
  final String access; // all | admin
  final String state; // on | off | admin_only
  final List<String> caps;
  final bool isNew; // optional `new`: just installed, admin only so far

  const NpfResource(
      {required this.name,
      this.title = '',
      this.type = '',
      this.svc = '',
      this.access = 'all',
      this.state = 'on',
      this.caps = const [],
      this.isNew = false});

  factory NpfResource.fromJson(Map<String, dynamic> j) => NpfResource(
      name: _str(j['name']),
      title: _str(j['title']),
      type: _str(j['type']),
      svc: _str(j['svc']),
      access: _str(j['access']).isEmpty ? 'all' : _str(j['access']),
      state: _str(j['state']).isEmpty ? 'on' : _str(j['state']),
      caps: _strs(j['caps']),
      isNew: _bool(j['new']));

  bool get adminOnly => access == 'admin' || state == 'admin_only';
  bool get running => state != 'off';
  bool get isDesktop => type == 'desktop' || name == 'desktop';

  /// The features to grant: a resource without features has one, "use".
  List<String> get features => caps.isEmpty ? const ['use'] : caps;
}

class NpfGrant {
  final String res;
  final List<String> can;
  const NpfGrant(this.res, this.can);

  /// [all] gives the features of a resource: npf's `can` null is all of
  /// them.
  factory NpfGrant.fromJson(Map<String, dynamic> j,
          [List<String> Function(String res)? all]) =>
      NpfGrant(
          _str(j['res']),
          j['can'] == null && all != null
              ? all(_str(j['res']))
              : _strs(j['can']));

  Map<String, dynamic> toJson() => {'res': res, 'can': can};
}

/// A row of this computer's list (npf's device-account.md 2): a person (an
/// account: an admin gave the pairing password, a member an invite code,
/// with every computer and phone they log in on), or a configured peer
/// (`machine`: a key's row, machine to machine, no person). `id` names the
/// row to `member/set` and `member/remove`.
class NpfMember {
  final int id;
  final String account; // a person's account number
  final String login; // its login name, masked by the platform
  final bool machine;
  final String key; // a configured peer's key
  final String fp;
  final String label;
  final String role; // admin | member
  final int? since;
  final int? until;
  final List<NpfGrant>? scope; // null: everything
  final bool online;
  final List<String> using; // resources in use now

  const NpfMember(
      {required this.id,
      this.account = '',
      this.login = '',
      this.machine = false,
      this.key = '',
      this.fp = '',
      this.label = '',
      this.role = 'member',
      this.since,
      this.until,
      this.scope,
      this.online = false,
      this.using = const []});

  factory NpfMember.fromJson(Map<String, dynamic> j,
          [List<String> Function(String res)? all]) =>
      NpfMember(
      id: _int(j['id']) ?? 0,
      account: _str(j['account']),
      login: _str(j['login']),
      machine: _bool(j['machine']),
      key: _str(j['key']),
      fp: _str(j['fp']),
      label: _str(j['label']),
      role: _str(j['role']).isEmpty ? 'member' : _str(j['role']),
      since: _int(j['since']),
      until: _int(j['until']),
      scope: j['scope'] == null
          ? null
          : _maps(j['scope']).map((g) => NpfGrant.fromJson(g, all)).toList(),
      online: _bool(j['online']),
      using: _strs(j['using']));

  bool get admin => role == 'admin';

  /// What it is called: the name given here (an invitation's "for whom"),
  /// else the login name, else the account (a configured peer: its key's
  /// fingerprint).
  String get name {
    if (label.isNotEmpty) return label;
    if (machine) return fp;
    if (login.isNotEmpty) return login;
    return npfTr('Account {id}', {'id': account});
  }

  /// What this row may use of [r].
  List<String> canOf(NpfResource r) {
    if (r.adminOnly) return const [];
    if (scope == null) return r.features;
    final g = scope!.where((g) => g.res == r.name).firstOrNull;
    if (g == null) return const [];
    // a resource without features is granted by being in the scope
    return r.caps.isEmpty ? r.features : g.can;
  }
}

/// An unused invite code (only the locator is known after creation).
class NpfShareCode {
  final String locator;
  final String label;
  final int uses;
  final int? expires;
  final List<NpfGrant>? scope;
  final int? memberTtlS;

  const NpfShareCode(
      {required this.locator,
      this.label = '',
      this.uses = 1,
      this.expires,
      this.scope,
      this.memberTtlS});

  factory NpfShareCode.fromJson(Map<String, dynamic> j,
          [List<String> Function(String res)? all]) =>
      NpfShareCode(
      locator: _str(j['locator']),
      label: _str(j['label']),
      uses: _int(j['uses']) ?? 1,
      expires: _int(j['expires']),
      scope: j['scope'] == null
          ? null
          : _maps(j['scope']).map((g) => NpfGrant.fromJson(g, all)).toList(),
      memberTtlS: _int(j['member_ttl_s']));
}

/// The result of `shareNew`: the full code, shown once.
class NpfNewCode {
  final String code;
  final int? expires;
  final int uses;
  const NpfNewCode(this.code, {this.expires, this.uses = 1});
}

class NpfShareData {
  final List<NpfResource> resources;
  final List<NpfMember> members;
  final List<NpfShareCode> codes;

  const NpfShareData(
      {this.resources = const [],
      this.members = const [],
      this.codes = const []});

  static const empty = NpfShareData();

  factory NpfShareData.fromJson(Map<String, dynamic> j) {
    final resources =
        _maps(j['resources']).map(NpfResource.fromJson).toList();
    List<String> all(String res) =>
        resources.where((r) => r.name == res).firstOrNull?.caps ?? const [];
    return NpfShareData(
        resources: resources,
        members: _maps(j['members']).map((m) => NpfMember.fromJson(m, all)).toList(),
        codes: _maps(j['codes']).map((c) => NpfShareCode.fromJson(c, all)).toList());
  }

  static NpfShareData parse(String s) {
    if (s.isEmpty) return empty;
    try {
      final j = jsonDecode(s);
      return j is Map
          ? NpfShareData.fromJson(j.cast<String, dynamic>())
          : empty;
    } catch (e) {
      debugPrint('npf share: $e');
      return empty;
    }
  }

  /// The admins: accounts that gave this computer's pairing password.
  List<NpfMember> get admins =>
      members.where((m) => m.admin && !m.machine).toList();

  /// The invited: one account each, with all its computers and phones.
  List<NpfMember> get people =>
      members.where((m) => !m.admin && !m.machine).toList();

  /// The configured peers: keys' rows (machine to machine), not people.
  List<NpfMember> get machines => members.where((m) => m.machine).toList();

  NpfResource? resource(String name) =>
      resources.where((r) => r.name == name).firstOrNull;
}

// ---------------------------------------------------------------------------

/// The npf state of this process; pages listen to it.
class NpfModel extends ChangeNotifier {
  NpfModel(this.backend);

  final NpfBackend backend;
  NpfState state = NpfState.empty;
  NpfShareData share = NpfShareData.empty;
  List<NpfRecent> recent = const [];
  bool _started = false;
  StreamSubscription<void>? _sub;

  static NpfModel? _instance;

  /// The model of this process, on [NpfBackend.instance].
  static NpfModel get instance => _instance ??= NpfModel(NpfBackend.instance);
  static set instance(NpfModel m) => _instance = m;

  DateTime now() => backend.now();

  /// Set by "邀请别人…" on the home page; the sharing page opens the invite
  /// dialog and clears it.
  final inviteRequest = ValueNotifier<bool>(false);

  /// Reads the state now and again on every `npf_state` event.
  void start() {
    if (_started) return;
    _started = true;
    _sub = backend.stateChanged.listen((_) => refresh());
    refresh();
    refreshShare();
  }

  Future<void> refresh() async {
    final rev = state.shareRev;
    state = NpfState.parse(await backend.stateJson());
    if (state.shareRev != rev && _started) refreshShare();
    recent = await backend.recent();
    notifyListeners();
  }

  Future<void> refreshShare() async {
    share = await backend.shareData();
    notifyListeners();
  }

  Future<void> assistRenew() async {
    await backend.assistRenew();
    await refresh();
  }

  // sharing calls: each re-reads the sharing data
  Future<NpfNewCode> shareNew(
      List<NpfGrant> resources, String label, int? memberTtlS) async {
    final code = await backend.shareNew(resources, label, memberTtlS);
    await refreshShare();
    return code;
  }

  Future<void> memberSet(int id, List<NpfGrant> resources, int? until) async {
    await backend.memberSet(id, resources, until);
    await refreshShare();
  }

  Future<void> memberRemove(int id) async {
    await backend.memberRemove(id);
    await refreshShare();
  }

  Future<void> resourceSet(String name, String access, bool on) async {
    await backend.resourceSet(name, access, on);
    await refreshShare();
  }

  Future<void> shareRevoke(String locator) async {
    await backend.shareRevoke(locator);
    await refreshShare();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
