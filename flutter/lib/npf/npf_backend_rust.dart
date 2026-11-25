// The app's backend: RustDesk's bridge (docs/npf-flutter-api.md) and Dart
// globals. Not there yet (WIRING): opening a peer's other resources and the
// account's plan page.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/widgets/login.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/desktop/pages/desktop_tab_page.dart';
import 'package:flutter_hbb/models/chat_model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/utils/multi_window_manager.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:window_manager/window_manager.dart';

import 'npf_backend.dart';
import 'npf_lang.dart';
import 'npf_model.dart';

/// A failed sharing request: npf's error word and its text.
class NpfCallError implements Exception {
  final String word;
  final String message;
  const NpfCallError(this.word, this.message);

  @override
  String toString() => message.isNotEmpty ? '$message ($word)' : word;
}

final _shareCode = RegExp(r'^(npf:)?([2-9A-HJKMNP-Z]{4}-){2}[2-9A-HJKMNP-Z]{4}$',
    caseSensitive: false);

class RustNpfBackend extends NpfBackend {
  RustNpfBackend() {
    final lang = bind.mainGetLocalOption(key: 'lang');
    NpfLang.zh = lang.isEmpty || lang == 'default'
        ? localeName.toLowerCase().startsWith('zh')
        : lang.toLowerCase() == 'zh-cn';
    platformFFI.registerEventHandler('npf_state', 'npf_model', (_) async {
      _changed.add(null);
    });
  }

  final _changed = StreamController<void>.broadcast();

  @override
  Stream<void> get stateChanged => _changed.stream;

  @override
  Future<String> stateJson() async => bind.mainNpfState();

  @override
  Future<void> assistRenew() => bind.mainNpfAssistRenew();

  /// npf's sharing-page request [path]: its answer, or [NpfCallError]
  Future<Map<String, dynamic>> _call(String path,
      [Map<String, dynamic>? body]) async {
    final r = jsonDecode(await bind.mainNpfCall(
        path: path, body: body == null ? '' : jsonEncode(body)));
    if (r is Map && r['ok'] is Map) {
      return (r['ok'] as Map).cast<String, dynamic>();
    }
    if (r is Map && r['error'] != null) {
      throw NpfCallError('${r['error']}', '${r['message'] ?? ''}');
    }
    throw const NpfCallError('io', '');
  }

  @override
  Future<List<NpfRecent>> recent() async {
    // RustDesk's recent sessions that were made with a share code
    final peers = gFFI.recentPeersModel.peers;
    return peers
        .where((p) => _shareCode.hasMatch(p.id))
        .map((p) => NpfRecent(
            id: p.id, name: p.alias.isNotEmpty ? p.alias : p.hostname))
        .toList();
  }

  @override
  Future<void> connect(BuildContext context, String text) async {
    // assist code, invite code or device number: RustDesk's connect() and
    // the Rust side tell them apart
    connect_(context, text.trim());
  }

  @override
  Future<void> connectPeer(BuildContext context, NpfPeer peer,
      {NpfAction action = NpfAction.desktop, NpfService? service}) async {
    switch (action) {
      case NpfAction.desktop:
        connect_(context, peer.number);
      case NpfAction.file:
        connect_(context, peer.number, isFileTransfer: true);
      case NpfAction.terminal:
        connect_(context, peer.number, isTerminal: true);
      case NpfAction.portForward:
        connect_(context, peer.number, isTcpTunneling: true);
      case NpfAction.open:
        // WIRING: open a web / SSH / camera resource of the peer through npf
        showToast('${service?.title ?? ''}: ${npfTr('Not available yet')}');
    }
  }

  @override
  Future<void> disconnectIncoming(String id) async {
    final n = int.tryParse(id);
    if (n != null) await bind.mainNpfDisconnect(id: n);
  }

  /// [method] to every session window until one says yes
  Future<bool> _toWindows(String method, String id) async {
    for (final w in await rustDeskWinManager.getAllSubWindowIds()) {
      try {
        if (await DesktopMultiWindow.invokeMethod(w, method, id) == true) {
          return true;
        }
      } catch (e) {
        debugPrint('npf: window $w: $e');
      }
    }
    return false;
  }

  // Remote desktop, terminal and camera windows know `active_session`; only
  // the remote desktop's knows `npf_close_session` (remote_tab_page.dart).
  @override
  Future<void> endOutgoing(String id) async {
    if (!await _toWindows('npf_close_session', id)) {
      await _toWindows(kWindowEventActiveSession, id);
    }
  }

  @override
  Future<void> showOutgoing(String id) async {
    await _toWindows(kWindowEventActiveSession, id);
  }

  @override
  Future<NpfShareData> shareData() async {
    try {
      return NpfShareData.fromJson(await _call('share/list'));
    } catch (e) {
      debugPrint('npf share/list: $e');
      return NpfShareData.empty;
    }
  }

  @override
  Future<NpfNewCode> shareNew(
      List<NpfGrant> resources, String label, int? memberTtlS) async {
    final r = await _call('share/new', {
      'scope': resources.map((g) => g.toJson()).toList(),
      if (label.isNotEmpty) 'label': label,
      if (memberTtlS != null && memberTtlS > 0) 'member_ttl_s': memberTtlS,
    });
    return NpfNewCode('${r['code']}',
        expires: r['expires'] as int?, uses: (r['uses'] as int?) ?? 1);
  }

  @override
  Future<void> memberSet(int id, List<NpfGrant> resources, int? until) =>
      _call('member/set', {
        'id': id,
        'scope': resources.map((g) => g.toJson()).toList(),
        'until': until ?? 0,
      });

  @override
  Future<void> memberRemove(int id) => _call('member/remove', {'id': id});

  @override
  Future<void> resourceSet(String name, String access, bool on) {
    // only what changes: npf takes `on` for applications' resources only
    final r = NpfModel.instance.share.resource(name);
    return _call('resource/set', {
      'name': name,
      if (r == null || r.access != access) 'access': access,
      if (r == null || r.running != on) 'on': on,
    });
  }

  @override
  Future<void> shareRevoke(String locator) =>
      _call('share/revoke', {'locator': locator});

  @override
  Future<void> cmApprove(NpfCmClient c, List<String> allowed) async {
    // the Rust side withholds what is not ticked, for this connection and
    // the session's later ones (docs/npf-flutter-api.md, CM)
    await bind.cmNpfAllow(connId: c.connId, allowed: jsonEncode(allowed));
    final client =
        gFFI.serverModel.clients.where((e) => e.id == c.connId).firstOrNull;
    if (client == null) return;
    if (c.type == NpfCmType.remote) {
      final control = allowed.contains('control');
      client.keyboard &= control;
      client.clipboard &= control;
      client.restart &= control;
      client.blockInput &= control;
      client.privacyMode &= control;
      client.file &= allowed.contains('file');
    }
    client.authorized = true;
    // as ServerModel.sendLoginResponse, without its cm_login_res
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    gFFI.serverModel.notifyListeners();
  }

  @override
  Future<void> cmReject(NpfCmClient c) async {
    final client =
        gFFI.serverModel.clients.where((e) => e.id == c.connId).firstOrNull;
    if (client != null) gFFI.serverModel.sendLoginResponse(client, false);
  }

  @override
  Future<void> cmDisconnect(NpfCmClient c) async =>
      bind.cmCloseConnection(connId: c.connId);

  @override
  Future<void> cmChat(NpfCmClient c) async =>
      gFFI.chatModel.toggleCMChatPage(MessageKey(c.peerId, c.connId));

  @override
  Future<void> cmVoiceAnswer(NpfCmClient c, bool accept) =>
      bind.cmHandleIncomingVoiceCall(id: c.connId, accept: accept);

  @override
  Future<void> cmVoiceEnd(NpfCmClient c) => bind.cmCloseVoiceCall(id: c.connId);

  @override
  Future<void> cmClose(NpfCmClient c) async {
    await bind.cmRemoveDisconnectedConnection(connId: c.connId);
    if (await bind.cmGetClientsLength() == 0) windowManager.close();
  }

  @override
  Future<void> signIn(BuildContext context) async => loginDialog();

  @override
  Future<void> openSettings() async => DesktopTabPage.onAddSetting();

  @override
  Future<void> upgradePlan() async {
    // WIRING: the account's plan page (npf's web console needs npf's
    // control token, which RustDesk does not get)
    showToast(npfTr('Not available yet'));
  }
}

// RustDesk's connect() of common.dart (the name is taken by the method).
void connect_(BuildContext context, String id,
        {bool isFileTransfer = false,
        bool isTerminal = false,
        bool isTcpTunneling = false}) =>
    connect(context, id,
        isFileTransfer: isFileTransfer,
        isTerminal: isTerminal,
        isTcpTunneling: isTcpTunneling);
