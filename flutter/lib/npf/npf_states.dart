// Connection messages (prototype States): every case says why and what to
// do next, instead of only "connection failed".

import 'package:flutter/material.dart';

import 'npf_lang.dart';
import 'npf_ui.dart';

enum NpfStateKind {
  wait, // waiting for the other side to accept
  needLogin, // no direct path, relay needs an account
  quota, // relay quota used up
  offline,
  badCode, // wrong or expired assist code
  rejected,
  expired, // the share to me has expired
  notShared, // the feature was not granted
  needAccount, // this computer or phone has no account logged in (npf 0.9.10)
}

/// What a button of a message does.
enum NpfStateAction { close, signIn, retry, upgrade, usage, retype }

class NpfConnState {
  final NpfStateKind kind;
  final String title;
  final String text;
  final List<(String, NpfStateAction)> buttons; // first: primary

  const NpfConnState(this.kind, this.title, this.text, this.buttons);

  Color color(NpfPalette p) => switch (kind) {
        NpfStateKind.wait => p.primary,
        NpfStateKind.needLogin || NpfStateKind.quota || NpfStateKind.needAccount => p.relay,
        NpfStateKind.offline || NpfStateKind.expired => p.muted,
        _ => p.red,
      };

  static NpfConnState of(NpfStateKind kind,
      {String name = '', String limit = '200 MiB'}) {
    final who = name.isEmpty ? npfTr('the other computer') : name;
    final ok = (npfTr('OK'), NpfStateAction.close);
    return switch (kind) {
      NpfStateKind.wait => NpfConnState(
          kind,
          npfTr('Waiting for them to accept'),
          npfTr(
              'Connected to {name}, waiting for them to click "Accept". Cancelled automatically if they do not answer within 30 seconds.',
              {'name': who}),
          [(npfTr('Cancel'), NpfStateAction.close)]),
      NpfStateKind.needLogin => NpfConnState(
          kind,
          npfTr('No direct path; sign in to use the relay'),
          npfTr(
              'Neither network allows a direct connection. After signing in the platform can relay it, still end-to-end encrypted.'),
          [
            (npfTr('Sign in'), NpfStateAction.signIn),
            (npfTr('Try again'), NpfStateAction.retry)
          ]),
      NpfStateKind.quota => NpfConnState(
          kind,
          npfTr('Relay quota used up this month'),
          npfTr(
              'This connection needs the relay and this month\'s {limit} are used up. Upgrade, or wait until one side changes network and can connect directly.',
              {'limit': limit}),
          [
            (npfTr('Upgrade plan'), NpfStateAction.upgrade),
            (npfTr('View usage'), NpfStateAction.usage)
          ]),
      NpfStateKind.offline => NpfConnState(
          kind,
          npfTr('They are offline'),
          npfTr(
              '{name} is offline. It shows as online again once it is on and connected.',
              {'name': who}),
          [ok]),
      NpfStateKind.badCode => NpfConnState(
          kind,
          npfTr('Wrong or expired assist code'),
          npfTr(
              'Assist codes change every 2 hours and are valid for 4. Ask them for the latest code on the left of their main window.'),
          [(npfTr('Type again'), NpfStateAction.retype)]),
      NpfStateKind.rejected => NpfConnState(
          kind,
          npfTr('They rejected the connection'),
          npfTr('They clicked "Reject", or turned remote access off.'),
          [ok]),
      NpfStateKind.expired => NpfConnState(
          kind,
          npfTr('The share has expired'),
          npfTr(
              'What they shared with you has expired. Ask them for a new invite code.'),
          [ok]),
      NpfStateKind.notShared => NpfConnState(
          kind,
          npfTr('Not shared with you'),
          npfTr(
              'They did not give you this feature. Ask them to change it on their share page.'),
          [ok]),
      NpfStateKind.needAccount => NpfConnState(
          kind,
          npfTr('Log in to an account first'),
          npfTr(
              'This computer or phone is not logged in to an account, so it cannot connect to other devices. Log in, then try again.'),
          [
            (npfTr('Sign in'), NpfStateAction.signIn),
            (npfTr('Try again'), NpfStateAction.retry)
          ]),
    };
  }

  /// Recognises a RustDesk message box as one of the cases: the Rust side
  /// sends `npf:<kind>[:<arg>]` as the text (see README), and a few of
  /// RustDesk's own texts map too.
  static NpfConnState? fromMsgBox(String type, String title, String text,
      {String name = ''}) {
    if (type == 'wait-remote-accept-nook') {
      return of(NpfStateKind.wait, name: name);
    }
    final m = RegExp(r'^npf:([a-z_]+)(?::(.*))?$').firstMatch(text.trim());
    if (m != null) {
      final arg = m.group(2) ?? '';
      final kind = switch (m.group(1)) {
        'wait' => NpfStateKind.wait,
        'need_login' => NpfStateKind.needLogin,
        'quota' => NpfStateKind.quota,
        'offline' => NpfStateKind.offline,
        'bad_code' => NpfStateKind.badCode,
        'rejected' => NpfStateKind.rejected,
        'expired' => NpfStateKind.expired,
        'not_shared' => NpfStateKind.notShared,
        'need_account' => NpfStateKind.needAccount,
        _ => null,
      };
      if (kind == null) return null;
      return kind == NpfStateKind.quota && arg.isNotEmpty
          ? of(kind, name: name, limit: arg)
          : of(kind, name: arg.isNotEmpty ? arg : name);
    }
    switch (text) {
      case 'Remote desktop is offline':
      case 'Offline':
        return of(NpfStateKind.offline, name: name);
      case 'Connection refused':
      case 'Connection not allowed':
        return of(NpfStateKind.rejected, name: name);
    }
    return null;
  }
}

/// One message as a card (the dialog body and the States board).
class NpfStateCard extends StatelessWidget {
  final NpfConnState state;
  final void Function(NpfStateAction)? onAction;
  final bool framed;

  const NpfStateCard(
      {super.key, required this.state, this.onAction, this.framed = true});

  @override
  Widget build(BuildContext context) {
    final p = NpfPalette.of(context);
    final body = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            NpfDot(state.color(p), size: 10),
            const SizedBox(width: 10),
            Expanded(
              child: Text(state.title,
                  style: npfText(15, weight: w700, color: p.text)),
            ),
          ]),
          const SizedBox(height: 10),
          Text(state.text, style: npfText(13, color: p.text2, height: 20 / 13)),
          const SizedBox(height: 14),
          Row(children: [
            for (var i = 0; i < state.buttons.length; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              NpfButton(state.buttons[i].$1,
                  kind: i == 0 ? NpfButtonKind.primary : NpfButtonKind.secondary,
                  height: 32,
                  fontSize: 13,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  onTap: () => onAction?.call(state.buttons[i].$2)),
            ],
          ]),
        ]);
    if (!framed) return body;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: npfCard(p),
      child: body,
    );
  }
}
