// Everything the npf pages need from Rust, npf or RustDesk's Dart globals,
// behind one interface: [RustNpfBackend] in the app, [StubNpfBackend] with
// demo data in tests and until the Rust side is wired.

import 'package:flutter/widgets.dart';

import 'npf_backend_rust.dart';
import 'npf_model.dart';

/// What a device card button does.
enum NpfAction { desktop, file, terminal, portForward, open }

/// A connection request or session in RustDesk's connection manager.
enum NpfCmType { remote, file, terminal, camera, portForward }

/// What the Rust side adds to the client info of the connection manager for
/// a connection that came over npf (`npf` in the client JSON; see README).
class NpfCmInfo {
  final String number; // the peer's npf number
  final String name; // the peer device's name
  final String? role; // admin | member | null (assist code)
  final bool temp; // came with the assist code
  final String label; // the member's label (给谁) on this computer
  final String via; // the assist code typed, if temp
  final List<String> can; // what the share page grants, for this resource
  final List<String> allowed; // allowed this time (after accepting)
  final int? joined; // when the member paired, unix seconds
  final int? asked; // when the request came, unix seconds
  final int? since; // when it was accepted, unix seconds
  final String res; // the resource: desktop, ...

  const NpfCmInfo(
      {this.number = '',
      this.name = '',
      this.role,
      this.temp = false,
      this.label = '',
      this.via = '',
      this.can = const [],
      this.allowed = const [],
      this.joined,
      this.asked,
      this.since,
      this.res = 'desktop'});

  static NpfCmInfo? fromJson(Object? v) {
    if (v is! Map) return null;
    final j = v.cast<String, dynamic>();
    int? i(Object? x) =>
        x is num ? x.toInt() : (x is String ? int.tryParse(x) : null);
    List<String> l(Object? x) =>
        x is List ? x.map((e) => '$e').toList() : const [];
    return NpfCmInfo(
        number: '${j['number'] ?? ''}',
        name: '${j['name'] ?? ''}',
        role: j['role'] == null ? null : '${j['role']}',
        temp: j['temp'] == true,
        label: '${j['label'] ?? ''}',
        via: '${j['via'] ?? ''}',
        can: l(j['can']),
        allowed: l(j['allowed']),
        joined: i(j['joined']),
        asked: i(j['asked']),
        since: i(j['since']),
        res: '${j['res'] ?? 'desktop'}');
  }

  /// Who it is: the label the owner gave, else the device name or number.
  String get who => label.isNotEmpty
      ? label
      : (name.isNotEmpty ? name : npfGroupNumber(number));
}

/// One client of the connection manager, as the npf card needs it.
/// The controller's voice call on a connection (RustDesk's incoming_voice_call /
/// in_voice_call).
enum NpfCmVoice { none, incoming, connected }

class NpfCmClient {
  final int connId;
  final String peerId;
  final String name;
  final bool authorized;
  final bool disconnected;
  final NpfCmType type;
  final NpfCmInfo info;
  final NpfCmVoice voice;

  const NpfCmClient(
      {required this.connId,
      this.peerId = '',
      this.name = '',
      this.authorized = false,
      this.disconnected = false,
      this.type = NpfCmType.remote,
      required this.info,
      this.voice = NpfCmVoice.none});
}

abstract class NpfBackend {
  static NpfBackend? _instance;

  /// The backend of this process.
  static NpfBackend get instance => _instance ??= RustNpfBackend();
  static set instance(NpfBackend b) => _instance = b;

  DateTime now() => DateTime.now();

  // ---- state
  /// `main_npf_state()`: the JSON of README.md.
  Future<String> stateJson();

  /// Fires on the global event `npf_state`.
  Stream<void> get stateChanged;

  Future<void> assistRenew();

  /// The "最近" tab: computers I helped with an assist code.
  Future<List<NpfRecent>> recent();

  // ---- connecting
  /// The connect box: an assist code, an invite code or a device number.
  Future<void> connect(BuildContext context, String text);

  /// A device card button.
  Future<void> connectPeer(BuildContext context, NpfPeer peer,
      {NpfAction action = NpfAction.desktop, NpfService? service});

  Future<void> disconnectIncoming(String id);
  Future<void> endOutgoing(String id);
  Future<void> showOutgoing(String id);

  // ---- sharing page (npf sharing endpoints)
  Future<NpfShareData> shareData();
  Future<NpfNewCode> shareNew(
      List<NpfGrant> resources, String label, int? memberTtlS);
  /// A row of the list ([NpfMember.id]): its scope and end.
  Future<void> memberSet(int id, List<NpfGrant> resources, int? until);
  Future<void> memberRemove(int id);
  Future<void> resourceSet(String name, String access, bool on);
  Future<void> shareRevoke(String locator);

  // ---- connection manager (the controlled side's popup)
  /// Accepts with the features ticked ("view" is always among them).
  Future<void> cmApprove(NpfCmClient c, List<String> allowed);
  Future<void> cmReject(NpfCmClient c);
  Future<void> cmDisconnect(NpfCmClient c);
  Future<void> cmChat(NpfCmClient c);
  Future<void> cmClose(NpfCmClient c);
  /// The controller's voice call: answered (the microphone and the speaker
  /// on here), or ended.
  Future<void> cmVoiceAnswer(NpfCmClient c, bool accept);
  Future<void> cmVoiceEnd(NpfCmClient c);

  // ---- elsewhere
  Future<void> signIn(BuildContext context);
  Future<void> openSettings();
  Future<void> upgradePlan();
}
