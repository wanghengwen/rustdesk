// The controlled side (prototype CIncoming), in a page of RustDesk's
// connection manager: the request with "这次允许" check boxes limited to what
// was granted (`can`), then the small "正在被控制" panel, with the
// controller's voice call on it (answer / reject, then hang up).

import 'dart:async';

import 'package:flutter/material.dart';

import 'npf_backend.dart';
import 'npf_lang.dart';
import 'npf_model.dart';
import 'npf_ui.dart';

/// Seconds until an unanswered request is rejected.
const int kNpfAskSeconds = 30;

const _deskCaps = ['view', 'control', 'file', 'terminal'];

class NpfCmCard extends StatefulWidget {
  final NpfCmClient client;
  final NpfBackend? backend;

  const NpfCmCard({super.key, required this.client, this.backend});

  @override
  State<NpfCmCard> createState() => _NpfCmCardState();
}

class _NpfCmCardState extends State<NpfCmCard> {
  late final NpfBackend backend = widget.backend ?? NpfBackend.instance;
  late final DateTime _shown = backend.now();
  final Map<String, bool> _flip = {};
  Timer? _tick;
  bool _answered = false;

  NpfCmClient get c => widget.client;
  NpfCmInfo get info => c.info;

  /// What this request may get at most.
  List<String> get granted {
    if (info.role == 'admin') return _deskCaps;
    if (info.temp && info.can.isEmpty) return _deskCaps;
    return info.can;
  }

  bool _defaultOn(String cap) =>
      !(info.temp && (cap == 'file' || cap == 'terminal'));

  bool isOn(String cap) =>
      granted.contains(cap) &&
      (cap == 'view' || (_flip[cap] ?? _defaultOn(cap)));

  List<String> get allowed => _deskCaps.where(isOn).toList();

  DateTime get _asked => npfTime(info.asked) ?? _shown;

  int get _secondsLeft =>
      kNpfAskSeconds - backend.now().difference(_asked).inSeconds;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (!c.authorized && !_answered && _secondsLeft <= 0) _reject();
      setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  void _accept() {
    _answered = true;
    backend.cmApprove(c, c.type == NpfCmType.remote ? allowed : granted);
  }

  void _reject() {
    _answered = true;
    backend.cmReject(c);
  }

  String get _title {
    final name = {'name': info.who};
    return switch (c.type) {
      NpfCmType.file =>
        npfTr('{name} wants to transfer files with this computer', name),
      NpfCmType.terminal =>
        npfTr('{name} wants to open a terminal on this computer', name),
      NpfCmType.camera =>
        npfTr('{name} wants to view the camera of this computer', name),
      NpfCmType.portForward =>
        npfTr('{name} wants to use port forwarding on this computer', name),
      NpfCmType.remote =>
        npfTr('{name} wants to connect to this computer', name),
    };
  }

  String get _how {
    if (info.temp) {
      return info.via.isNotEmpty
          ? npfTr('Assist code {code} · temporary, this time only',
              {'code': info.via})
          : npfTr('Assist code · temporary, this time only');
    }
    if (info.role == 'admin') {
      return npfTr(
          'Owner or admin of this computer · may use everything');
    }
    final joined = npfTime(info.joined);
    return joined != null
        ? npfTr('Invited person · joined {date}', {'date': npfDate(joined)})
        : npfTr('Invited person');
  }

  String get _granted => info.temp || info.role == 'admin'
      ? npfTr(
          'With the assist code they may use all of remote desktop; you decide now what to give')
      : npfTr('What you gave them on the share page: {caps}',
          {'caps': npfCapLongList(granted)});

  @override
  Widget build(BuildContext context) {
    final p = NpfPalette.of(context);
    return Container(
      color: p.surface,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: c.disconnected
          ? _disconnected(p)
          : c.authorized
              ? _live(p)
              : _ask(p),
    );
  }

  Widget _ask(NpfPalette p) {
    final remote = c.type == NpfCmType.remote;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(_title, style: npfText(17, weight: w700, color: p.text, height: 1.35)),
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        decoration:
            BoxDecoration(color: p.bg, borderRadius: BorderRadius.circular(10)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_how, style: npfText(13, color: p.text2, height: 1.4)),
          const SizedBox(height: 4),
          Text(_granted, style: npfText(13, color: p.text2, height: 1.4)),
        ]),
      ),
      if (remote) ...[
        const SizedBox(height: 12),
        Text(npfTr('Allow this time'),
            style: npfText(13, weight: w600, color: p.text)),
        const SizedBox(height: 4),
        for (final cap in _deskCaps) _capRow(p, cap),
        const SizedBox(height: 8),
        Text(
            info.temp
                ? npfTr('Files and terminal start unticked; give them when needed.')
                : npfTr(
                    'Only less than on the share page; to give more, change the share page.'),
            style: npfText(12, color: p.text3, height: 1.4)),
      ],
      const Spacer(),
      Text(
          npfTr('Rejected automatically in {s} s',
              {'s': _secondsLeft.clamp(0, kNpfAskSeconds)}),
          style: npfText(12, color: p.text3)),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(
          child: NpfButton(npfTr('Reject'), onTap: _answered ? null : _reject),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: NpfButton(npfTr('Accept'),
              kind: NpfButtonKind.primary, onTap: _answered ? null : _accept),
        ),
      ]),
    ]);
  }

  Widget _capRow(NpfPalette p, String cap) {
    final can = granted.contains(cap);
    final fixed = cap == 'view';
    final on = isOn(cap);
    final enabled = can && !fixed;
    final note = !can
        ? npfTr('You did not give it')
        : fixed
            ? npfTr('Always on')
            : '';
    return InkWell(
      onTap: enabled ? () => setState(() => _flip[cap] = !on) : null,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        constraints: const BoxConstraints(minHeight: 34),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(children: [
          NpfCheck(on, dashed: !enabled),
          const SizedBox(width: 10),
          Expanded(
            child: Text(npfCap(cap).long,
                style: npfText(14, color: enabled ? p.text : p.muted)),
          ),
          if (note.isNotEmpty) Text(note, style: npfText(12, color: p.muted)),
        ]),
      ),
    );
  }

  Widget _live(NpfPalette p) {
    final since = npfTime(info.since) ?? _shown;
    final caps = info.allowed.isNotEmpty ? info.allowed : allowed;
    final how = info.temp
        ? npfTr('Assist code · needs a new code to connect again')
        : info.role == 'admin'
            ? npfTr(
                'Owner or admin of this computer · may use everything')
            : npfTr('Invited person · you accepted');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        NpfDot(p.red),
        const SizedBox(width: 8),
        Expanded(
          child: Text(npfTr('Being controlled'),
              style: npfText(14, weight: w700, color: p.text)),
        ),
        Text(npfClock(backend.now().difference(since)),
            style: npfText(12, color: p.text3)),
      ]),
      const SizedBox(height: 10),
      Text(info.who, style: npfText(14, weight: w600, color: p.text)),
      const SizedBox(height: 3),
      Text(how, style: npfText(12, color: p.text2)),
      const SizedBox(height: 10),
      if (c.type == NpfCmType.remote)
        Text(npfTr('Allowed this time: {caps}', {'caps': npfCapLongList(caps)}),
            style: npfText(12, color: p.text2, height: 1.4)),
      const Spacer(),
      if (c.voice != NpfCmVoice.none) ...[_voice(p), const SizedBox(height: 10)],
      Row(children: [
        Expanded(
            child: NpfButton(npfTr('Chat'),
                height: 32, fontSize: 13, onTap: () => backend.cmChat(c))),
        const SizedBox(width: 8),
        Expanded(
            child: NpfButton(npfTr('Disconnect'),
                kind: NpfButtonKind.dangerSoft,
                height: 32,
                fontSize: 13,
                onTap: () => backend.cmDisconnect(c))),
      ]),
    ]);
  }

  /// The controller's voice call: its request with reject / answer, then
  /// "in a voice call" with hang up.
  Widget _voice(NpfPalette p) {
    final incoming = c.voice == NpfCmVoice.incoming;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration:
          BoxDecoration(color: p.bg, borderRadius: BorderRadius.circular(10)),
      child: Row(children: [
        Icon(incoming ? Icons.phone_in_talk : Icons.mic,
            size: 18, color: incoming ? p.text : p.red),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
              npfTr(incoming ? 'Voice call request' : 'In a voice call'),
              style: npfText(13, weight: w600, color: p.text)),
        ),
        if (incoming) ...[
          NpfButton(npfTr('Reject'),
              height: 30,
              fontSize: 13,
              onTap: () => backend.cmVoiceAnswer(c, false)),
          const SizedBox(width: 6),
          NpfButton(npfTr('Answer'),
              kind: NpfButtonKind.primary,
              height: 30,
              fontSize: 13,
              onTap: () => backend.cmVoiceAnswer(c, true)),
        ] else
          NpfButton(npfTr('Hang up'),
              kind: NpfButtonKind.dangerSoft,
              height: 30,
              fontSize: 13,
              onTap: () => backend.cmVoiceEnd(c)),
      ]),
    );
  }

  Widget _disconnected(NpfPalette p) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        NpfDot(p.muted),
        const SizedBox(width: 8),
        Text(npfTr('Disconnected'),
            style: npfText(14, weight: w700, color: p.text)),
      ]),
      const SizedBox(height: 10),
      Text(info.who, style: npfText(14, weight: w600, color: p.text)),
      const Spacer(),
      NpfButton(npfTr('Close'), height: 32, onTap: () => backend.cmClose(c)),
    ]);
  }
}
