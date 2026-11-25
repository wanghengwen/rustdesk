// The hooks RustDesk's pages call: they turn RustDesk's types into the npf
// widgets' inputs. Each upstream file touches only one of these functions.

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/widgets/login.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/server_model.dart';
import 'package:get/get.dart';
import 'package:uuid/uuid.dart';

import 'npf_backend.dart';
import 'npf_cm.dart';
import 'npf_home_page.dart';
import 'npf_lang.dart';
import 'npf_model.dart';
import 'npf_quality.dart';
import 'npf_share_page.dart';
import 'npf_states.dart';

// the session toolbar's (desktop/widgets/remote_toolbar_npf.dart, a part of
// RustDesk's remote_toolbar.dart: it has no imports of its own)
export 'npf_desk_modes.dart';
export 'npf_desk_ui.dart';
export 'npf_lang.dart' show npfTr;

/// The scheme C pages replace RustDesk's home, the connection manager card
/// and some message boxes. `--dart-define=NPF_UI=false` shows RustDesk's own.
const bool kNpfUi = bool.fromEnvironment('NPF_UI', defaultValue: true);

const String kNpfTabShare = 'npf-share';

/// The device the peer's sound is played on (src/npf_audio_out.rs): the local
/// option that names it, and main_get_common's key for the list.
const String kNpfOptionAudioOutput = 'audio-output';
const String kNpfCommonAudioOutputs = 'npf-audio-outputs';

// ---- main window

/// The home tab's page (desktop_home_page.dart).
Widget npfHomePage({Widget? notices}) => NpfHomePage(
    notices: notices,
    onInvite: () {
      NpfModel.instance.inviteRequest.value = true;
      try {
        Get.find<DesktopTabController>().jumpToByKey(kNpfTabShare);
      } catch (_) {}
    });

/// The "共享" tab next to the home tab (desktop_tab_page.dart).
TabInfo npfShareTab() => TabInfo(
    key: kNpfTabShare,
    label: npfTr('Share'),
    selectedIcon: Icons.people_alt,
    unselectedIcon: Icons.people_alt_outlined,
    closable: false,
    page: const NpfSharePage(key: ValueKey(kNpfTabShare)));

// ---- connection manager

/// The npf card for a client of the connection manager, or null for a
/// connection that did not come over npf (server_page.dart).
Widget? npfConnectionCard(Client client) {
  final info = NpfCmInfo.fromJson(client.npf);
  if (!kNpfUi || info == null) return null;
  final type = switch (client.type_()) {
    ClientType.file => NpfCmType.file,
    ClientType.terminal => NpfCmType.terminal,
    ClientType.camera => NpfCmType.camera,
    ClientType.portForward => NpfCmType.portForward,
    _ => NpfCmType.remote,
  };
  return NpfCmCard(
      key: ValueKey('npf-cm-${client.id}-${client.authorized}'),
      client: NpfCmClient(
          connId: client.id,
          peerId: client.peerId,
          name: client.name,
          authorized: client.authorized,
          disconnected: client.disconnected,
          type: type,
          info: info,
          voice: client.incomingVoiceCall
              ? NpfCmVoice.incoming
              : client.inVoiceCall
                  ? NpfCmVoice.connected
                  : NpfCmVoice.none));
}

// ---- session window

/// The quality pill of the session toolbar (remote_toolbar.dart).
Widget npfQualityItem(FFI ffi) {
  final npf = NpfModel.instance..start();
  return NpfQualityButton(
    listenable: Listenable.merge([ffi.qualityMonitorModel, ffi.ffiModel, npf]),
    onUpgrade: npf.backend.upgradePlan,
    quality: () {
      final d = ffi.qualityMonitorModel.data;
      final out = npf.state.outgoing
          .where((o) => o.peer.number == ffi.id || 'npf:${o.peer.number}' == ffi.id)
          .firstOrNull;
      final direct = ffi.ffiModel.direct;
      return NpfSessionQuality.fromRustDesk(
          speed: d.speed,
          delay: d.delay,
          fps: d.fps,
          codecFormat: d.codecFormat,
          path: out?.path ?? (direct == null ? null : (direct ? 'p2p' : 'relay')),
          npfRttMs: out?.rttMs,
          quota: npf.state.quota);
    },
  );
}

/// Shows an npf connection message instead of RustDesk's message box;
/// false when [text] is not one (common.dart msgBox).
bool npfMsgBox(UuidValue sessionId, String type, String title, String text,
    OverlayDialogManager dialogManager,
    {Function(OverlayDialogManager, UuidValue, bool)? reconnect}) {
  if (!kNpfUi) return false;
  final state = NpfConnState.fromMsgBox(type, title, text);
  if (state == null) return false;
  final backend = NpfBackend.instance;
  dialogManager.show(
    (setState, close, context) {
      void act(NpfStateAction a) {
        switch (a) {
          case NpfStateAction.signIn:
            loginDialog();
          case NpfStateAction.retry:
            close();
            reconnect?.call(dialogManager, sessionId, false);
            return;
          case NpfStateAction.upgrade:
          case NpfStateAction.usage:
            backend.upgradePlan();
          case NpfStateAction.close:
          case NpfStateAction.retype:
            break;
        }
        close();
        if (desktopType != DesktopType.portForward) closeConnection();
      }

      return CustomAlertDialog(
        title: null,
        content: SizedBox(
            width: 340,
            child: NpfStateCard(state: state, onAction: act, framed: false)),
        actions: const [],
        onCancel: () => act(NpfStateAction.close),
      );
    },
    tag: '$sessionId-npf-$type-$text',
  );
  return true;
}
