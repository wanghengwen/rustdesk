// Scheme C home (prototype CHome): left "让别人连我" (assist code), right
// "我去连别人" (connect box + device cards), bars on top while connected.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'npf_backend.dart';
import 'npf_lang.dart';
import 'npf_model.dart';
import 'npf_ui.dart';

enum NpfHomeTab { mine, shared, recent }

class NpfHomePage extends StatefulWidget {
  final NpfModel? model;

  /// "邀请别人…": open the sharing page with the invite dialog.
  final VoidCallback? onInvite;
  final NpfHomeTab initialTab;

  /// RustDesk's notices (install, update, permissions) in the left panel.
  final Widget? notices;

  const NpfHomePage(
      {super.key,
      this.model,
      this.onInvite,
      this.notices,
      this.initialTab = NpfHomeTab.mine});

  @override
  State<NpfHomePage> createState() => _NpfHomePageState();
}

class _NpfHomePageState extends State<NpfHomePage> {
  late final NpfModel model = widget.model ?? NpfModel.instance;
  late NpfHomeTab tab = widget.initialTab;
  final _input = TextEditingController();
  String? _inputError;
  Timer? _tick;

  NpfBackend get backend => model.backend;

  @override
  void initState() {
    super.initState();
    model.start();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = NpfPalette.of(context);
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) {
        final s = model.state;
        return Container(
          color: p.bg,
          child: Column(children: [
            for (final c in s.incoming) _incomingBar(p, c),
            for (final c in s.outgoing) _outgoingBar(p, s, c),
            Expanded(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                _left(p, s),
                Expanded(child: _right(p, s)),
              ]),
            ),
          ]),
        );
      },
    );
  }

  // ---- bars on top

  Widget _bar(NpfPalette p,
      {required Color bg,
      required Color line,
      required Color dot,
      required List<InlineSpan> text,
      required List<Widget> buttons}) {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
          color: bg, border: Border(bottom: BorderSide(color: line))),
      child: Row(children: [
        NpfDot(dot, size: 10),
        const SizedBox(width: 12),
        Expanded(
          child: Text.rich(TextSpan(children: text),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: npfText(14, color: p.text)),
        ),
        for (final b in buttons) ...[const SizedBox(width: 12), b],
      ]),
    );
  }

  Widget _incomingBar(NpfPalette p, NpfIncoming c) {
    final since = npfTime(c.since);
    final how = c.peer.temp
        ? npfTr('by assist code')
        : (c.peer.role == 'admin' ? npfTr('my device') : npfTr('invited'));
    return _bar(p,
        bg: p.orangeSoft,
        line: p.orangeLine,
        dot: p.orange,
        text: [
          ...npfTrSpans('{name} is controlling this computer',
              {'name': c.peer.label},
              bold: {'name'}),
          TextSpan(
              text: [
            if (since != null) npfClock(model.now().difference(since)),
            how
          ].map((e) => ' · $e').join()),
        ],
        buttons: [
          NpfButton(npfTr('Disconnect'),
              kind: NpfButtonKind.danger,
              height: 34,
              fontSize: 13,
              onTap: () => backend.disconnectIncoming(c.id)),
        ]);
  }

  Widget _outgoingBar(NpfPalette p, NpfState s, NpfOutgoing c) {
    final peer = s.peer(c.peer.number);
    final name = c.peer.name.isNotEmpty
        ? c.peer.name
        : (peer?.label ?? npfGroupNumber(c.peer.number));
    final res = peer?.services.where((e) => e.res == c.res).firstOrNull;
    final text = c.res.isEmpty || c.res == 'desktop'
        ? npfTrSpans('Connected to the remote desktop of {name}', {'name': name},
            bold: {'name'})
        : npfTrSpans('Connected to {res} of {name}',
            {'name': name, 'res': res?.title ?? c.res},
            bold: {'name'});
    return _bar(p,
        bg: p.primarySoft,
        line: p.primarySoftLine,
        dot: p.primary,
        text: text,
        buttons: [
          NpfButton(npfTr('Back to the window'),
              height: 34,
              fontSize: 13,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              onTap: () => backend.showOutgoing(c.id)),
          NpfButton(npfTr('End'),
              height: 34,
              fontSize: 13,
              onTap: () => backend.endOutgoing(c.id)),
        ]);
  }

  // ---- left: let others connect to me

  Widget _left(NpfPalette p, NpfState s) {
    return Container(
      width: 300,
      decoration: BoxDecoration(
          color: p.surface, border: Border(right: BorderSide(color: p.line))),
      child: LayoutBuilder(
        builder: (context, c) => SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 20),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: c.maxHeight - 44),
            child: _leftColumn(p, s),
          ),
        ),
      ),
    );
  }

  // the top part and this computer at the bottom, apart by the free space
  Widget _leftColumn(NpfPalette p, NpfState s) {
    return Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(npfTr('Let others connect to me'),
                style: npfText(16, weight: w700, color: p.text)),
            const SizedBox(height: 14),
            ..._assist(p, s.assist),
            const SizedBox(height: 14),
            Container(height: 1, color: p.line),
            const SizedBox(height: 14),
            Text(npfTr('Let someone use it long-term'),
                style: npfText(14, weight: w600, color: p.text)),
            const SizedBox(height: 6),
            Text(npfTr('Pick what they may use and get an invite code'),
                style: npfText(12, color: p.text3, height: 1.5)),
            const SizedBox(height: 6),
            NpfButton(npfTr('Invite someone…'),
                height: 38, radius: 10, onTap: widget.onInvite),
            if (widget.notices != null) ...[
              const SizedBox(height: 14),
              widget.notices!,
            ],
            const SizedBox(height: 20),
          ]),
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(s.name, style: npfText(13, weight: w600, color: p.text)),
            const SizedBox(height: 3),
            if (s.node.isNotEmpty)
              Text(npfTr('Number {number}', {'number': npfGroupNumber(s.node)}),
                  style: npfText(12, color: p.text2)),
            const SizedBox(height: 3),
            Row(children: [
              NpfDot(s.online ? p.green : p.muted, size: 7),
              const SizedBox(width: 6),
              Text(
                  s.online
                      ? npfTr('Online')
                      : npfTr('Connecting to the platform…'),
                  style: npfText(12, color: p.text2)),
            ]),
          ]),
        ]);
  }

  List<Widget> _assist(NpfPalette p, NpfAssist a) {
    final code = a.code;
    if (code == null || code.isEmpty) {
      final (title, text, action) = switch (a.why) {
        'off' => (
            npfTr('Assist codes are off'),
            npfTr('Turn it on in settings to let a helper connect'),
            NpfButton(npfTr('Settings'),
                height: 36, radius: 10, onTap: backend.openSettings),
          ),
        'no_owner' => (
            npfTr('This computer has no owner account yet'),
            npfTr('Sign in to issue assist codes'),
            NpfButton(npfTr('Sign in'),
                kind: NpfButtonKind.primary,
                height: 36,
                radius: 10,
                onTap: () => backend.signIn(context)),
          ),
        _ => (
            npfTr('No assist code while offline'),
            npfTr('It comes back by itself once the network is back'),
            null,
          ),
      };
      return [
        Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
          decoration: BoxDecoration(
              color: p.bg, borderRadius: BorderRadius.circular(10)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: npfText(14, weight: w600, color: p.text)),
            const SizedBox(height: 4),
            Text(text, style: npfText(12, color: p.text3, height: 1.5)),
            if (action != null) ...[const SizedBox(height: 10), action],
          ]),
        ),
      ];
    }
    final renews = npfTime(a.renewsAt);
    final left = renews?.difference(model.now());
    return [
      Text(npfTr('Tell the helper your assist code'),
          style: npfText(13, color: p.text2)),
      const SizedBox(height: 6),
      FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: SelectableText(code,
            style: npfText(27, weight: w700, color: p.text, spacing: 1)),
      ),
      const SizedBox(height: 6),
      if (left != null)
        Text(
            left.isNegative
                ? npfTr('Changes soon')
                : npfTr('Changes automatically in {left}',
                    {'left': npfLeft(left)}),
            style: npfText(12, color: p.text3)),
      const SizedBox(height: 14),
      Row(children: [
        Expanded(
          child: NpfButton(npfTr('Copy'),
              kind: NpfButtonKind.primary,
              height: 40,
              radius: 10, onTap: () {
            Clipboard.setData(ClipboardData(text: code));
            _toast(npfTr('Copied'));
          }),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: NpfButton(npfTr('New code'),
              height: 40, radius: 10, onTap: model.assistRenew),
        ),
      ]),
      const SizedBox(height: 14),
      Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        decoration:
            BoxDecoration(color: p.bg, borderRadius: BorderRadius.circular(10)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final t in [
            'Remote desktop only, your other shares stay hidden',
            'You approve every connection',
          ])
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Text('· ${npfTr(t)}',
                  style: npfText(12, color: p.text2, height: 1.5)),
            ),
        ]),
      ),
    ];
  }

  void _toast(String text) {
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 1)));
  }

  // ---- right: connect to others

  static final _codeRe =
      RegExp(r'^(npf:)?([2-9A-HJKMNP-Z]{4}-?){2}[2-9A-HJKMNP-Z]{4}$', caseSensitive: false);
  static final _numberRe = RegExp(r'^(npf:)?\d{6,12}$');

  void _connect() {
    final text = _input.text.replaceAll(' ', '').trim();
    if (text.isEmpty) return;
    if (!_codeRe.hasMatch(text) && !_numberRe.hasMatch(text)) {
      setState(() => _inputError =
          npfTr('This is not an assist code, an invite code or a device number'));
      return;
    }
    setState(() => _inputError = null);
    backend.connect(context, text);
  }

  Widget _right(NpfPalette p, NpfState s) {
    final lists = {
      NpfHomeTab.mine: s.mine,
      NpfHomeTab.shared: s.shared,
    };
    final hints = {
      NpfHomeTab.mine:
          'Devices paired with the pairing password or on the same account: you can use and manage them fully',
      NpfHomeTab.shared: 'Shared with you by invite code: only what they gave you',
      NpfHomeTab.recent:
          'Computers you helped with an assist code: cannot be reconnected directly',
    };
    final cards = tab == NpfHomeTab.recent
        ? model.recent.map((r) => _recentCard(p, r)).toList()
        : lists[tab]!.map((d) => _DeviceCard(peer: d, model: model)).toList();
    final empty = switch (tab) {
      NpfHomeTab.mine =>
        'No devices yet: pair one with its pairing password, or sign in on both',
      NpfHomeTab.shared =>
        'Nothing shared with you yet: ask the owner for an invite code and type it above',
      NpfHomeTab.recent => 'Nothing yet',
    };
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(npfTr('Connect to others'),
            style: npfText(16, weight: w700, color: p.text)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: SizedBox(
              height: 44,
              child: TextField(
                controller: _input,
                onSubmitted: (_) => _connect(),
                style: npfText(15, color: p.text),
                cursorColor: p.primary,
                decoration: InputDecoration(
                  hintText:
                      npfTr('Their assist code, invite code or device number'),
                  hintStyle: npfText(15, color: p.muted),
                  filled: true,
                  fillColor: p.surface,
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(
                          color: _inputError == null ? p.input : p.red)),
                  focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: p.primary, width: 1.5)),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          NpfButton(npfTr('Connect'),
              kind: NpfButtonKind.primary,
              height: 44,
              radius: 10,
              fontSize: 15,
              padding: const EdgeInsets.symmetric(horizontal: 24),
              onTap: _connect),
        ]),
        if (_inputError != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(_inputError!, style: npfText(12, color: p.red)),
          ),
        const SizedBox(height: 18),
        Container(
          decoration:
              BoxDecoration(border: Border(bottom: BorderSide(color: p.line))),
          child: Row(children: [
            _tab(p, NpfHomeTab.mine, '${npfTr('My devices')} ${s.mine.length}'),
            const SizedBox(width: 6),
            _tab(p, NpfHomeTab.shared,
                '${npfTr('Shared with me')} ${s.shared.length}'),
            const SizedBox(width: 6),
            _tab(p, NpfHomeTab.recent, npfTr('Recent')),
          ]),
        ),
        const SizedBox(height: 12),
        Text(npfTr(hints[tab]!), style: npfText(12, color: p.text3)),
        const SizedBox(height: 12),
        if (cards.isEmpty)
          Container(
            padding: const EdgeInsets.all(20),
            decoration: npfCard(p),
            child: Text(npfTr(empty), style: npfText(13, color: p.text3)),
          )
        else
          LayoutBuilder(builder: (context, c) {
            const gap = 12.0;
            final w = (c.maxWidth - 2 * gap) / 3;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [for (final card in cards) SizedBox(width: w, child: card)],
            );
          }),
      ]),
    );
  }

  Widget _tab(NpfPalette p, NpfHomeTab t, String label) {
    final on = t == tab;
    return InkWell(
      onTap: () => setState(() => tab = t),
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
            border: Border(
                bottom: BorderSide(
                    width: 2, color: on ? p.primary : Colors.transparent))),
        child: Text(label,
            style: npfText(14,
                weight: on ? w600 : null,
                color: on ? p.primaryText : p.text2)),
      ),
    );
  }

  Widget _recentCard(NpfPalette p, NpfRecent r) {
    final at = npfTime(r.at);
    return NpfCardFrame(
      name: r.name.isNotEmpty ? r.name : npfGroupNumber(r.id),
      sub: [
        if (at != null) npfWhen(at, model.now()),
        npfTr('Helped with an assist code')
      ].join(' · '),
      bars: 0,
      link: npfTr('An assist code is good for that one time only'),
      main: npfTr('Needs a new assist code to connect again'),
      onMain: null,
      more: const [],
      menu: const [],
    );
  }
}

/// A menu entry of the "⋯" button.
class NpfMenuItem {
  final String label;
  final VoidCallback onTap;
  const NpfMenuItem(this.label, this.onTap);
}

/// The layout of a device card (prototype CHome / DeviceCard).
class NpfCardFrame extends StatelessWidget {
  final String name;
  final String sub;
  final int bars;
  final String link;
  final Color? linkColor;
  final String main;
  final VoidCallback? onMain;
  final List<(String, VoidCallback)> more;
  final List<NpfMenuItem> menu;

  const NpfCardFrame(
      {super.key,
      required this.name,
      required this.sub,
      required this.bars,
      required this.link,
      this.linkColor,
      required this.main,
      required this.onMain,
      required this.more,
      required this.menu});

  @override
  Widget build(BuildContext context) {
    final p = NpfPalette.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: npfCard(p),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: npfText(14, weight: w700, color: p.text)),
              const SizedBox(height: 3),
              Text(sub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: npfText(12, color: p.text3)),
            ]),
          ),
          const SizedBox(width: 8),
          NpfSignalBars(bars),
        ]),
        const SizedBox(height: 10),
        Text(link,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: npfText(12, color: linkColor ?? p.text2)),
        const SizedBox(height: 10),
        NpfButton(main,
            kind: NpfButtonKind.primary, height: 38, radius: 9, onTap: onMain),
        const SizedBox(height: 10),
        Row(children: [
          for (final m in more) ...[
            Expanded(
              child: NpfButton(m.$1,
                  height: 32,
                  fontSize: 12,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  borderColor: p.lineStrong,
                  onTap: m.$2),
            ),
            const SizedBox(width: 6),
          ],
          if (more.isEmpty) const Spacer(),
          _MoreButton(menu: menu),
        ]),
      ]),
    );
  }
}

class _MoreButton extends StatelessWidget {
  final List<NpfMenuItem> menu;
  const _MoreButton({required this.menu});

  @override
  Widget build(BuildContext context) {
    final p = NpfPalette.of(context);
    return Tooltip(
      message: npfTr('More actions'),
      child: Material(
        color: p.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: p.lineStrong)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: menu.isEmpty
              ? null
              : () async {
                  final box = context.findRenderObject() as RenderBox;
                  final at = box.localToGlobal(Offset(0, box.size.height + 4));
                  final i = await showMenu<int>(
                    context: context,
                    color: p.surface,
                    position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
                    items: [
                      for (var i = 0; i < menu.length; i++)
                        PopupMenuItem(
                            value: i,
                            height: 34,
                            child: Text(menu[i].label,
                                style: npfText(13, color: p.text))),
                    ],
                  );
                  if (i != null) menu[i].onTap();
                },
          child: SizedBox(
              width: 32,
              height: 32,
              child: Center(child: NpfMoreIcon(p.text2))),
        ),
      ),
    );
  }
}

/// A device of "我的设备" or "共享给我的".
class _DeviceCard extends StatelessWidget {
  final NpfPeer peer;
  final NpfModel model;
  const _DeviceCard({required this.peer, required this.model});

  @override
  Widget build(BuildContext context) {
    final p = NpfPalette.of(context);
    final b = model.backend;
    final now = model.now();
    final expired = peer.expiredAt(now);
    final bars = expired
        ? 0
        : npfBars(online: peer.online, path: peer.path, rttMs: peer.rttMs);
    final desk = peer.desktop;
    final usable = peer.services.where((s) => s.up).toList();

    void go(NpfAction a, [NpfService? s]) =>
        b.connectPeer(context, peer, action: a, service: s);

    // the main button: remote desktop, else the first service
    final String main;
    final VoidCallback? onMain;
    final more = <(String, VoidCallback)>[];
    final menu = <NpfMenuItem>[];
    final ok = peer.online && !expired;
    final others = peer.services.where((s) => s != desk).toList();
    if (desk != null) {
      main = npfTr('Remote desktop');
      onMain = ok && desk.up && desk.can.contains('view')
          ? () => go(NpfAction.desktop, desk)
          : null;
      if (desk.can.contains('file')) {
        more.add((npfTr('Files'), () => go(NpfAction.file, desk)));
      }
      if (desk.can.contains('terminal')) {
        more.add((npfTr('Terminal'), () => go(NpfAction.terminal, desk)));
      }
    } else if (peer.services.isNotEmpty) {
      final s = usable.firstOrNull ?? peer.services.first;
      others.remove(s);
      main = _serviceLabel(s, main: true);
      onMain = ok && s.up ? () => go(NpfAction.open, s) : null;
    } else {
      main = npfTr('Remote desktop');
      onMain = null;
    }
    for (final s in others) {
      final item = (_serviceLabel(s), () => go(NpfAction.open, s));
      if (more.length < 2) {
        more.add(item);
      } else {
        menu.add(NpfMenuItem(item.$1, item.$2));
      }
    }
    if (desk != null && peer.mine && ok) {
      menu.add(NpfMenuItem(
          npfTr('Port forwarding'), () => go(NpfAction.portForward, desk)));
    }
    menu.add(NpfMenuItem(npfTr('Copy device number'),
        () => Clipboard.setData(ClipboardData(text: peer.number))));

    final String sub;
    if (peer.mine) {
      sub = '${npfTr('My device')} · ${npfGroupNumber(peer.number)}';
    } else {
      final caps = (desk ?? peer.services.firstOrNull)?.can ?? const [];
      final camera = (desk ?? peer.services.firstOrNull)?.kind ==
          NpfServiceKind.camera;
      sub = [
        caps.isEmpty
            ? npfTr('Shared with you')
            : npfTr('Shared with you · {caps}',
                {'caps': npfCapList(caps, camera: camera)}),
        if (peer.until != null && !expired)
          npfTr('until {date}', {'date': npfDate(npfTime(peer.until)!)}),
      ].join(' · ');
    }

    final String link;
    Color? linkColor;
    if (expired) {
      link = npfTr('The share has expired, ask them for a new code');
      linkColor = p.warn;
    } else if (!peer.online) {
      link = npfTr('Offline');
    } else {
      final q = npfQualityWord(bars);
      link = peer.rttMs == null
          ? npfTr('{q} · {path}', {'q': q, 'path': npfPathWord(peer.path)})
          : npfTr('{q} · {path} {rtt} ms',
              {'q': q, 'path': npfPathWord(peer.path), 'rtt': peer.rttMs});
    }

    return NpfCardFrame(
      name: peer.label,
      sub: sub,
      bars: bars,
      link: link,
      linkColor: linkColor,
      main: main,
      onMain: onMain,
      more: ok ? more : more.map((m) => (m.$1, () {})).toList(),
      menu: menu,
    );
  }

  static String _serviceLabel(NpfService s, {bool main = false}) {
    switch (s.kind) {
      case NpfServiceKind.camera:
        return npfTr('View camera');
      case NpfServiceKind.ssh:
        return s.title.isNotEmpty ? s.title : 'SSH';
      default:
        final t = s.title.isNotEmpty ? s.title : s.res;
        return main ? npfTr('Open {title}', {'title': t}) : t;
    }
  }
}
